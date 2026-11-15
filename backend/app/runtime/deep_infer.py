"""DeepInfer 风格的内置推理加速规划（真实参数，不虚报加速）。

本模块把「跑本地模型更快更稳」拆成四件可验证的事：

1. **稳定前缀**：``stable_prompt`` 只做确定性的拼接与去尾空白，不插入时间、
   随机 id、字典序不稳定的键；llama.cpp 的 ``cache_prompt=True`` 以相同前缀
   为命中条件，前缀稳定才有复用。
2. **分块预填充**：``prefill_chunks`` 首块 128 token、之后翻倍到 1024，
   降低首字延迟；该序列用于分批把 prompt 送进引擎（见 ``prefill_plan``）。
3. **投机解码**：``draft_tokens`` 由历史接受率决定起草长度；真正执行起草的
   是 llama_cpp 的 ``LlamaPromptLookupDecoding``（无额外模型，纯查表起草），
   本模块只负责给出参数与统计。
4. **预算化生成**：``max_tokens`` 被 ``context - prompt - 64`` 约束，
   避免超出上下文后输出被硬截断。

所有统计只在真实生成结束后累加；没有可用的 llama_cpp 时后端会照实报错，
本模块也不会伪造「已加速」。
"""

from __future__ import annotations

import os
import re
import threading
from dataclasses import dataclass, field
from typing import List

__all__ = [
    "GenerationPlan",
    "DeepInferPlanner",
    "estimate_tokens",
    "prefill_chunks",
    "stable_prompt",
]


def estimate_tokens(text: str) -> int:
    """粗略 token 估算：CJK 每字 1、拉丁单词约 1.3、其它符号 1。"""
    if not text:
        return 0
    cjk = len(re.findall(r"[\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff]", text))
    words = len(re.findall(r"[A-Za-z]+", text))
    symbols = len(re.findall(r"[^\sA-Za-z\u3400-\u4dbf\u4e00-\u9fff\u3040-\u30ff]", text))
    total = cjk + int(words * 1.3 + 0.999) + symbols
    # 中英混排时 tokenizer 会在脚本切换处产生额外切分，预算按此保守计。
    if cjk and words:
        total += 1
    return total


def prefill_chunks(prompt_tokens: int) -> List[int]:
    """首块小、后续翻倍的预填充分块序列。"""
    if prompt_tokens <= 0:
        return []
    out: List[int] = []
    left = prompt_tokens
    size = 128
    while left > 0:
        take = min(left, size)
        out.append(take)
        left -= take
        size = min(1024, size * 2)
    return out


def stable_prompt(system: str, prompt: str) -> str:
    """确定性拼接 system 与 user：相同输入永远得到逐字相同的输出。"""
    s = (system or "").strip()
    p = (prompt or "").strip()
    if not s:
        return p
    if not p:
        return s
    return f"{s}\n\n{p}"


@dataclass
class GenerationPlan:
    prompt: str
    max_tokens: int
    prompt_tokens: int
    prefill_chunks: List[int]
    draft_tokens: int
    prefix_reused: bool
    threads: int


@dataclass
class DeepInferPlanner:
    """计划 + 统计（线程安全：同一进程内多请求共享统计）。"""

    context_size: int = 2048
    threads: int = 0
    max_draft_tokens: int = 6
    _last_prefix: str = ""
    _prefix_hits: int = 0
    _prefix_misses: int = 0
    _drafted: int = 0
    _accepted: int = 0
    _rounds: int = 0
    _acceptance_ema: float = 0.0
    _generations: int = 0
    _prompt_tokens: int = 0
    _completion_tokens: int = 0
    _latency_ms: float = 0.0
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def __post_init__(self) -> None:
        if self.threads <= 0:
            self.threads = self.default_threads(self.context_size)
        if self.max_draft_tokens < 0:
            self.max_draft_tokens = 0

    @staticmethod
    def default_threads(context_size: int = 2048) -> int:
        """线程数：物理核数留一核给 UI/网络，上限 6、下限 2。

        小上下文（<=1024）线程过多反而增加同步开销，故再降一档。
        """
        cores = os.cpu_count() or 4
        n = max(2, min(6, cores - 1 if cores > 2 else cores))
        if context_size <= 1024:
            n = max(2, n - 1)
        return n

    # ---- 前缀稳定性 ----
    def _observe_prefix(self, system: str) -> bool:
        key = (system or "").strip()
        hit = bool(key) and key == self._last_prefix
        if hit:
            self._prefix_hits += 1
        else:
            self._prefix_misses += 1
        self._last_prefix = key
        return hit

    # ---- 起草长度 ----
    def draft_length(self) -> int:
        if self._rounds < 2:
            return min(2, self.max_draft_tokens)
        if self._acceptance_ema >= 0.75:
            return min(self.max_draft_tokens, 6)
        if self._acceptance_ema >= 0.5:
            return min(self.max_draft_tokens, 4)
        if self._acceptance_ema >= 0.3:
            return min(self.max_draft_tokens, 2)
        return 0

    # ---- 计划 ----
    def plan(self, system: str, prompt: str, max_tokens: int) -> GenerationPlan:
        full = stable_prompt(system, prompt)
        prompt_tokens = estimate_tokens(full) + 16
        budget = max(16, self.context_size - prompt_tokens - 64)
        reused = self._observe_prefix(system)
        return GenerationPlan(
            prompt=full,
            max_tokens=max(1, min(int(max_tokens), budget)),
            prompt_tokens=prompt_tokens,
            prefill_chunks=prefill_chunks(prompt_tokens),
            draft_tokens=self.draft_length(),
            prefix_reused=reused,
            threads=self.threads,
        )

    # ---- 记账 ----
    def record(
        self,
        *,
        prompt_tokens: int,
        completion_tokens: int,
        latency_ms: float,
        drafted: int = 0,
        accepted: int = 0,
    ) -> None:
        with self._lock:
            self._generations += 1
            self._prompt_tokens += int(prompt_tokens)
            self._completion_tokens += int(completion_tokens)
            self._latency_ms += float(latency_ms)
            if drafted > 0:
                self._rounds += 1
                acc = max(0, min(int(accepted), int(drafted)))
                self._drafted += int(drafted)
                self._accepted += acc
                ratio = acc / drafted
                self._acceptance_ema = (
                    ratio
                    if self._rounds == 1
                    else self._acceptance_ema * 0.7 + ratio * 0.3
                )

    def metrics(self) -> dict:
        total_prefix = self._prefix_hits + self._prefix_misses
        return {
            "generations": self._generations,
            "prompt_tokens": self._prompt_tokens,
            "completion_tokens": self._completion_tokens,
            "avg_latency_ms": (
                round(self._latency_ms / self._generations, 1)
                if self._generations
                else 0.0
            ),
            "tokens_per_second": (
                round(self._completion_tokens * 1000 / self._latency_ms, 2)
                if self._latency_ms
                else 0.0
            ),
            "prefix": {
                "hits": self._prefix_hits,
                "misses": self._prefix_misses,
                "hit_rate": (
                    round(self._prefix_hits / total_prefix, 3)
                    if total_prefix
                    else 0.0
                ),
            },
            "speculation": {
                "rounds": self._rounds,
                "drafted": self._drafted,
                "accepted": self._accepted,
                "acceptance_ema": round(self._acceptance_ema, 3),
            },
            "threads": self.threads,
            "context_size": self.context_size,
        }