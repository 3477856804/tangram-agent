"""Agent 运行时服务（RuntimeService）：IM 网关 / 无头 CLI 的真实应答内核。

``im/serve.py`` 里 ``from app.runtime.agent_service import RuntimeService`` 此前
指向一个不存在的包，导致「本地 Agent 运行时」整条链路是空壳。现在：

* 确定性能力（身份 / 精确算术 / 报时 / 提醒 / 天气 / 联网检索）复用
  ``im.brain.Brain`` 的真实实现，算不出来就交给模型，绝不猜。
* 模型应答两条真实来源：``TANGRAM_MODEL`` 本地 GGUF 权重（llama.cpp /
  ctransformers / transformers），或 ``TANGRAM_API_BASE/_KEY/_MODEL`` 的
  OpenAI 兼容云端 API（真实 HTTP）。都没有时明确抛错，不伪造回复。
* 记忆真实落盘（``MemoryStore``）：每轮对话、长期笔记、词项检索都能
  跨进程重启恢复，供 ``recall_memory`` / ``remember_note`` 工具调用。
* 工具真实执行：``sandbox`` 跑真实进程，``current_time`` 读真实时钟。
"""

from __future__ import annotations

import json
import os
import subprocess
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator, Optional
from urllib.parse import urlsplit

from ..sandbox import SandboxPolicyError, safe_env, validate_command
from .local_llm import InferenceError, LocalLLMInference
from .memory import MemoryStore

__all__ = ["RuntimeService", "RuntimeNotConfigured"]


class RuntimeNotConfigured(RuntimeError):
    """没有可用的模型来源（如实报错，绝不降级成假回复）。"""


_SYSTEM = (
    "你是 TGA（Tangram），住在用户设备里的个人专属 AI Agent。"
    "用简洁、诚实的简体中文回答；能算准的精确计算，查不到就直说查不到，绝不编造。"
    "你有真实工具：sandbox（工作区 shell）、current_time（真实时钟）、"
    "recall_memory（真实历史记忆）、remember_note（写入长期记忆）、"
    "quant_research（量化研究助手：对历史收盘价做真实技术指标与风险度量计算，"
    "仅供研究学习，不推荐买卖、不承诺收益、不代客交易，回答末尾必须保留风险提示）。"
)


class RuntimeService:
    def __init__(self, data_dir: str | Path = "", *,
                 local_model: str = "", api_base: str = "", api_key: str = "",
                 api_model: str = "") -> None:
        root = Path(data_dir or os.environ.get("TANGRAM_DATA")
                    or (Path.home() / ".tangram"))
        self.data_dir = root
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self.workspace = self.data_dir / "agent_ws"
        self.workspace.mkdir(parents=True, exist_ok=True)
        self.memory = MemoryStore(self.data_dir / "memory")

        self.local_model = local_model or os.environ.get("TANGRAM_MODEL", "")
        self.api_base = (api_base or os.environ.get("TANGRAM_API_BASE", "")).rstrip("/")
        self.api_key = api_key or os.environ.get("TANGRAM_API_KEY", "")
        self.api_model = api_model or os.environ.get("TANGRAM_API_MODEL", "")
        self._llm: Optional[LocalLLMInference] = None
        self._brain = None
        self._brain_loaded = False

    # ---- 确定性能力（真实实现，非模板占位）----
    def _deterministic(self, text: str, session_key: str) -> Optional[str]:
        if not self._brain_loaded:
            self._brain_loaded = True
            try:
                from im.brain import Brain  # noqa: PLC0415 - 仓库根已在 sys.path

                self._brain = Brain(deliver=self._deliver_reminder)
            except Exception:  # noqa: BLE001 - 无该模块时跳过，不伪造能力
                self._brain = None
        if self._brain is None:
            return None
        try:
            return self._brain.handle(text, session_key)
        except Exception:  # noqa: BLE001 - 确定性层失败交给模型
            return None

    def _deliver_reminder(self, key: str, text: str) -> None:
        """提醒到点的真实出站回调（默认打印；宿主可覆盖）。"""
        print(f"[reminder] {key}: {text}", flush=True)

    # ---- 模型来源 ----
    def _cloud_config(self) -> Optional[tuple[str, str, str]]:
        if self.api_base and self.api_key and self.api_model:
            return self.api_base, self.api_key, self.api_model
        return None

    def _model_stream(self, prompt: str) -> Iterator[str]:
        cfg = self._cloud_config()
        if cfg is not None:
            yield from self._cloud_stream(cfg, prompt)
            return
        if self.local_model:
            if self._llm is None:
                self._llm = LocalLLMInference(self.local_model).load(self.local_model)
            yield from self._llm.stream(prompt, system=_SYSTEM)
            return
        raise RuntimeNotConfigured(
            "未配置任何模型：请设置 TANGRAM_MODEL（本地 GGUF 权重）或 "
            "TANGRAM_API_BASE / TANGRAM_API_KEY / TANGRAM_API_MODEL（云端 API）。"
            "不会用模板或检索式占位文本冒充模型回复。"
        )

    def _cloud_stream(self, cfg: tuple[str, str, str], prompt: str,
                      chunk_size: int = 8) -> Iterator[str]:
        """真实 HTTP 调用 OpenAI 兼容端点；优先 SSE 逐增量返回首 token。

        旧实现用 urlopen().read() 读完整响应再按字符切片，是「伪流式」：
        首 token 延迟等于整段生成时间。现在请求 stream=true，按 SSE data:
        行增量解析 delta.content 并立即 yield；若端点不支持 SSE（返回普通
        JSON），再回退一次性内容，绝不伪造数据。
        """
        base, key, model = cfg
        parsed = urlsplit(base)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise RuntimeNotConfigured("云端 API 地址必须是 http(s) 且带主机名")
        body = json.dumps({
            "model": model,
            "messages": [
                {"role": "system", "content": _SYSTEM},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.7,
            "max_tokens": 2048,
            "stream": True,
        }, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            base + "/chat/completions", data=body,
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + key,
                     "Accept": "text/event-stream, application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 - 地址来自配置
            content_type = (resp.headers.get("Content-Type") or "").lower()
            if "text/event-stream" in content_type:
                produced = False
                for raw in resp:  # 逐行增量读取，不 read() 整段
                    line = raw.decode("utf-8", errors="replace").strip()
                    if not line.startswith("data:"):
                        continue
                    data_str = line[len("data:"):].strip()
                    if not data_str or data_str == "[DONE]":
                        continue
                    try:
                        obj = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue
                    try:
                        delta = obj["choices"][0].get("delta", {}).get("content") or ""
                    except (KeyError, IndexError, TypeError):
                        continue
                    if delta:
                        produced = True
                        yield delta
                if not produced:
                    raise RuntimeNotConfigured("SSE 流未返回任何内容；不伪造回复")
                return
            # 端点不支持 SSE：回退一次性 JSON（内容仍来自真实响应）。
            data = json.loads(resp.read().decode("utf-8"))
        try:
            content = str(data["choices"][0]["message"]["content"] or "").strip()
        except (KeyError, IndexError, TypeError) as exc:
            raise RuntimeNotConfigured(f"云端 API 返回结构异常：{str(data)[:200]}") from exc
        if not content:
            raise RuntimeNotConfigured("云端 API 返回空内容；不伪造回复")
        for i in range(0, len(content), max(1, chunk_size)):
            yield content[i:i + max(1, chunk_size)]

    # ---- 对外主接口 ----
    def chat_stream(self, text: str, session_id: str = "default") -> Iterator[str]:
        """真实应答流：确定性能力 → 真实模型 → 明确报错。"""
        text = (text or "").strip()
        if not text:
            raise ValueError("空消息")
        self.memory.add_turn("user", text, session_id=session_id)

        direct = self._deterministic(text, session_id)
        if direct:
            # 确定性能力：内容短，直接落记忆后一次性返回。
            self.memory.add_turn("assistant", direct.strip(), session_id=session_id)
            yield from (direct[i:i + 12] for i in range(0, len(direct), 12))
            return

        recalled = self.memory.recall_text(text, k=4)
        recent = self.memory.recent(session_id=session_id, k=6)
        history = "\n".join(f"{e.role}: {e.text}" for e in recent)
        prompt_parts = []
        if recalled:
            prompt_parts.append("【相关历史记忆（本机真实记录）】\n" + recalled)
        if history:
            prompt_parts.append("【最近对话】\n" + history)
        prompt_parts.append("【当前用户消息】\n" + text)
        prompt = "\n\n".join(prompt_parts)

        # 真流式：逐片 yield，首 token 一到就投递，不再 list() 整段缓冲
        # （旧实现把整段生成 materialize 后才 yield，首 token 延迟=全程）。
        # 同时累积真实内容，流结束后写入记忆，保证记账不丢。
        pieces: list[str] = []
        for piece in self._model_stream(prompt):
            if not piece:
                continue
            pieces.append(piece)
            yield piece
        answer = "".join(pieces).strip()
        if not answer:
            raise RuntimeNotConfigured("本次没有拿到任何真实回复内容（不伪造）")
        self.memory.add_turn("assistant", answer, session_id=session_id)

    def chat(self, text: str, session_id: str = "default") -> str:
        return "".join(self.chat_stream(text, session_id=session_id)).strip()

    # ---- 真实工具 ----
    def exec_tool(self, name: str, args: dict) -> str:
        """供 Agent 工具循环调用；结果全部来自真实执行。"""
        if name == "current_time":
            now = datetime.now()
            utc = datetime.now(timezone.utc)
            return (f"本地时间：{now.strftime('%Y-%m-%d %H:%M:%S')} "
                    f"（星期{'一二三四五六日'[now.weekday()]}）；"
                    f"UTC：{utc.strftime('%Y-%m-%d %H:%M:%S')}")
        if name == "recall_memory":
            query = str(args.get("query") or "")
            lines = [f"- [核心记忆] {t}" for _cid, t in self.memory.list_core()
                     if not query or query[:2] in t]
            lines += [f"- {e.role}: {e.text}"
                      for e, _s in self.memory.nearest_neighbors(query, k=4)]
            return "\n".join(lines)[:2000] if lines else "没有检索到相关记忆。"
        if name == "remember_note":
            note = str(args.get("text") or "").strip()
            if not note:
                return "工具执行失败：text 为空"
            return f"已记入长期核心记忆（id={self.memory.core_commit(note)}）：{note}"
        if name == "sandbox":
            # 安全修复：命令来自不可信的聊天/桥接输入，绝不能交给 shell，
            # 也不能继承含 API Key / Token 的进程环境。这里强制走真实策略：
            # 白名单程序 + shell=False + 工作区路径约束 + 最小环境 + 超时/输出上限。
            command = str(args.get("command") or "").strip()
            if not command:
                return "工具执行失败：command 为空"
            try:
                argv, policy = validate_command(command, self.workspace)
            except SandboxPolicyError as exc:
                return f"工具执行失败：沙箱策略拒绝：{exc}"
            except (OSError, ValueError) as exc:
                # 策略文件缺失/损坏也必须拒绝执行（fail-closed），绝不回退裸 shell
                return (f"工具执行失败：沙箱策略不可用，已拒绝执行（fail-closed）："
                        f"{type(exc).__name__}: {exc}")
            timeout_s = float(policy.get("timeout_seconds", 60))
            max_out = int(policy.get("max_output_bytes", 4000))
            try:
                proc = subprocess.run(
                    argv, cwd=str(self.workspace),
                    capture_output=True, text=True, timeout=timeout_s,
                    env=safe_env(self.workspace), shell=False,
                )
            except subprocess.TimeoutExpired:
                return f"工具执行失败：命令超时（>{int(timeout_s)}s）已终止"
            except OSError as exc:
                return f"工具执行失败：{type(exc).__name__}: {exc}"
            out = ((proc.stdout or "") + (proc.stderr or "")).strip()
            if proc.returncode != 0:
                out += f"\n[exit={proc.returncode}]"
            return (out or "(无输出)")[:max_out]
        if name == "quant_research":
            # AI 量化研究助手：纯函数式真实计算，绝不接交易/下单 API。
            from .quant_research import (  # noqa: PLC0415 - 按需导入
                InsufficientDataError, analyze,
            )

            prices = args.get("prices") or []
            symbol = str(args.get("symbol") or "UNKNOWN")
            if not isinstance(prices, list) or not prices:
                return "工具执行失败：prices 必须是非空的历史收盘价数组"
            try:
                result = analyze(prices, symbol)
            except (InsufficientDataError, ValueError) as exc:
                return f"工具执行失败：{type(exc).__name__}: {exc}"
            return json.dumps(result, ensure_ascii=False)
        return f"工具执行失败：未知工具 {name}"

    def status(self) -> dict:
        return {
            "data_dir": str(self.data_dir.resolve()),
            "workspace": str(self.workspace.resolve()),
            "local_model": self.local_model,
            "cloud_configured": self._cloud_config() is not None,
            "model_backend": self._probe_backend(),
            "memory": self.memory.stats(),
            "time": time.strftime("%F %T"),
        }

    def _probe_backend(self) -> str:
        if self._cloud_config() is not None:
            return "cloud-api"
        if self.local_model:
            probe = LocalLLMInference(self.local_model)
            return probe._probe_native() or "none"
        return "none"
