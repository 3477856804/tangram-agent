"""端侧 / 本地模型真实推理后端（LocalLLMInference）。

被 ``harness/teachers.py`` 的 LocalTeacher 与 ``im/serve.py`` 的本地运行时引用。
此前仓库里只有 import 语句、没有这个模块，本地教师蒸馏与本地 GGUF 应答
全是空壳。现在按以下真实优先级探测本机推理后端：

1. ``llama_cpp``（llama-cpp-python，GGUF 原生推理）
2. ``ctransformers``（GGUF 原生推理）
3. ``transformers``（本地 HF 目录 / GGUF 转换加载，真实自回归 generate）

三者都不可用或权重不兼容时抛 RuntimeError，由调用方明确报错。
**绝不返回模板/检索式占位文本冒充模型输出**；``config.mock`` 只在
「本机确实没有任何可用后端」时为 True，调用方据此拒绝冒充。
"""

from __future__ import annotations

import os
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Optional

__all__ = ["LLMConfig", "LocalLLMInference", "InferenceError"]


class InferenceError(RuntimeError):
    """本地推理不可用 / 失败（明确报错，不伪造输出）。"""


@dataclass
class LLMConfig:
    gguf_path: str = ""
    max_tokens: int = 256
    context_size: int = 2048
    threads: int = 4
    has_native: bool = False
    mock: bool = False
    backend: str = ""
    extra: dict = field(default_factory=dict)


class LocalLLMInference:
    """真实加载权重并生成文本；单例式复用已加载模型。"""

    def __init__(self, gguf_path: str = "", max_tokens: int = 256) -> None:
        self.config = LLMConfig(
            gguf_path=os.path.abspath(gguf_path) if gguf_path else "",
            max_tokens=max_tokens,
        )
        self._lock = threading.Lock()
        self._backend: Optional[str] = None
        self._model = None
        self._tokenizer = None
        self._load_error: str = ""

    # ---- 后端探测（惰性 import，import 阶段零副作用）----
    def _probe_native(self) -> Optional[str]:
        """返回第一个真实可用的推理后端名；没有则 None。"""
        if self._backend is not None:
            return self._backend or None
        import importlib.util

        for name in ("llama_cpp", "ctransformers", "transformers"):
            try:
                if importlib.util.find_spec(name) is not None:
                    self._backend = name
                    return name
            except (ImportError, ValueError):
                continue
        self._backend = ""
        return None

    def load(self, model_path: str = "") -> "LocalLLMInference":
        """校验权重真实存在并探测后端；不加载权重进显存（推理时惰性加载）。"""
        path = os.path.abspath(model_path or self.config.gguf_path)
        if not path:
            raise InferenceError("未指定本地权重路径（TANGRAM_MODEL / model_path）")
        p = Path(path)
        if not p.exists():
            raise InferenceError(f"本地权重不存在：{p}")
        if p.is_file() and p.stat().st_size < 1024 * 1024:
            raise InferenceError(f"权重文件不完整（{p.stat().st_size}B），请重新下载：{p}")
        backend = self._probe_native()
        self.config.gguf_path = path
        self.config.backend = backend or ""
        self.config.has_native = backend is not None
        self.config.mock = backend is None
        self._load_error = "" if backend else (
            "本机没有可用的推理后端（llama_cpp / ctransformers / transformers）；"
            "请 pip install 其中之一，或改用云端 API 路径"
        )
        return self

    # ---- 真实推理 ----
    def _real_infer(self, backend: str, model_path: str, prompt: str,
                    max_tokens: int = 256) -> str:
        """真正调用后端生成文本；任何失败抛 InferenceError，绝不降级成假答案。"""
        if backend == "llama_cpp":
            return self._infer_llama_cpp(model_path, prompt, max_tokens)
        if backend == "ctransformers":
            return self._infer_ctransformers(model_path, prompt, max_tokens)
        if backend == "transformers":
            return self._infer_transformers(model_path, prompt, max_tokens)
        raise InferenceError(f"未知推理后端：{backend!r}")

    def _model_obj(self, backend: str, model_path: str):
        """惰性加载并复用模型对象（加锁，避免并发重复加载）。"""
        with self._lock:
            if self._model is not None:
                return self._model, self._tokenizer
            if backend == "llama_cpp":
                from llama_cpp import Llama  # noqa: PLC0415

                self._model = Llama(
                    model_path=model_path,
                    n_ctx=self.config.context_size,
                    n_threads=self.config.threads,
                    verbose=False,
                )
                self._tokenizer = None
            elif backend == "ctransformers":
                from ctransformers import AutoModelForCausalLM  # noqa: PLC0415

                self._model = AutoModelForCausalLM.from_pretrained(
                    model_path,
                    model_type=self._guess_model_type(model_path),
                    context_length=self.config.context_size,
                    threads=self.config.threads,
                )
                self._tokenizer = None
            elif backend == "transformers":
                self._model, self._tokenizer = self._load_hf(model_path)
            else:
                raise InferenceError(f"未知推理后端：{backend!r}")
            return self._model, self._tokenizer

    @staticmethod
    def _guess_model_type(path: str) -> str:
        name = os.path.basename(path).lower()
        for key in ("qwen", "llama", "mistral", "gpt2", "phi", "gemma"):
            if key in name:
                return key
        return "llama"

    @staticmethod
    def _load_hf(model_path: str):
        """加载本地 HF 目录或单个 GGUF 文件（transformers 的 gguf_file 转换）。"""
        from transformers import AutoModelForCausalLM, AutoTokenizer  # noqa: PLC0415

        p = Path(model_path)
        if p.is_dir():
            tok = AutoTokenizer.from_pretrained(str(p), local_files_only=True)
            model = AutoModelForCausalLM.from_pretrained(str(p), local_files_only=True)
            return model, tok
        # 单个 GGUF：同目录需有 config.json/tokenizer；否则如实报错
        parent = p.parent
        if not (parent / "config.json").is_file():
            raise InferenceError(
                "transformers 加载单个 GGUF 需要同目录的 config.json 与 tokenizer；"
                f"未找到 {parent / 'config.json'}。请改用 llama_cpp / ctransformers"
            )
        tok = AutoTokenizer.from_pretrained(str(parent), local_files_only=True)
        model = AutoModelForCausalLM.from_pretrained(
            str(parent), gguf_file=p.name, local_files_only=True
        )
        return model, tok

    def _infer_llama_cpp(self, model_path: str, prompt: str, max_tokens: int) -> str:
        model, _ = self._model_obj("llama_cpp", model_path)
        out = model(prompt, max_tokens=max_tokens, temperature=0.7, top_p=0.9)
        try:
            return str(out["choices"][0]["text"]).strip()
        except (KeyError, IndexError, TypeError) as exc:
            raise InferenceError(f"llama_cpp 返回结构异常：{str(out)[:200]}") from exc

    def _infer_ctransformers(self, model_path: str, prompt: str, max_tokens: int) -> str:
        model, _ = self._model_obj("ctransformers", model_path)
        text = model(prompt, max_new_tokens=max_tokens, temperature=0.7, top_p=0.9)
        if not isinstance(text, str):
            text = str(text)
        # ctransformers 通常返回含 prompt 的全文，去掉前缀
        if text.startswith(prompt):
            text = text[len(prompt):]
        return text.strip()

    def _infer_transformers(self, model_path: str, prompt: str, max_tokens: int) -> str:
        import torch  # noqa: PLC0415 - transformers 生成需要张量后端

        model, tok = self._model_obj("transformers", model_path)
        encoded = tok(prompt, return_tensors="pt")
        with torch.no_grad():
            generated = model.generate(
                **encoded,
                max_new_tokens=max_tokens,
                do_sample=True,
                temperature=0.7,
                top_p=0.9,
                pad_token_id=getattr(tok, "eos_token_id", None),
            )
        new_tokens = generated[0][encoded["input_ids"].shape[-1]:]
        return tok.decode(new_tokens, skip_special_tokens=True).strip()

    # ---- 对外契约 ----
    def generate(self, prompt: str, system: str = "", max_tokens: Optional[int] = None) -> str:
        """真实生成；无权重 / 无后端 / 推理失败一律抛错。"""
        if not self.config.gguf_path:
            raise InferenceError("尚未 load() 任何本地权重")
        backend = self._probe_native()
        if backend is None:
            raise InferenceError(self._load_error or "没有可用的本地推理后端")
        full = f"{system}\n\n{prompt}".strip() if system else prompt
        text = self._real_infer(backend, self.config.gguf_path, full,
                                int(max_tokens or self.config.max_tokens))
        if not text:
            raise InferenceError("本地模型本次没有产出任何文本（不伪造输出）")
        return text

    def stream(self, prompt: str, system: str = "", max_tokens: Optional[int] = None,
               chunk_size: int = 8) -> Iterator[str]:
        """把真实生成结果按可见字符分片投递（内容全部来自真实模型输出）。
        
        llama_cpp 支持原生流式时优先用原生 token 流，否则对完整真实输出切片。
        """
        if not self.config.gguf_path:
            raise InferenceError("尚未 load() 任何本地权重")
        backend = self._probe_native()
        if backend is None:
            raise InferenceError(self._load_error or "没有可用的本地推理后端")
        full = f"{system}\n\n{prompt}".strip() if system else prompt
        limit = int(max_tokens or self.config.max_tokens)
        if backend == "llama_cpp":
            model, _ = self._model_obj("llama_cpp", self.config.gguf_path)
            try:
                for part in model(full, max_tokens=limit, temperature=0.7,
                                  stream=True):
                    piece = str(part["choices"][0].get("text", ""))
                    if piece:
                        yield piece
                return
            except Exception:  # noqa: BLE001 - 原生流不可用时回退完整真实输出
                pass
        text = self._real_infer(backend, self.config.gguf_path, full, limit)
        if not text:
            raise InferenceError("本地模型本次没有产出任何文本（不伪造输出）")
        for i in range(0, len(text), max(1, chunk_size)):
            yield text[i:i + max(1, chunk_size)]

    def dispose(self) -> None:
        with self._lock:
            self._model = None
            self._tokenizer = None
