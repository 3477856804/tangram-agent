"""教师模型（Teacher）：工作蒸馏时产出监督信号的两条真实来源。

  * LocalTeacher：加载本地下载的基底模型（GGUF / HuggingFace 目录），
    经 backend.app.runtime.local_llm.LocalLLMInference 做真实自回归推理。
  * ApiTeacher：调用 OpenAI 兼容 /chat/completions（urllib 真实 HTTP），
    支持自定义 base_url / api_key / model，绝不伪造响应。

共同契约：complete(prompt) -> str；失败抛 TeacherError（明确报错，不返回假答案）。
无权重 / 无后端 / 无 API 凭据时，两条路径都会诚实失败，让调用方知道需要
先下载基底模型或配置 API，而不是把模板占位当成「教师输出」。
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Callable


class TeacherError(Exception):
    """教师不可用或推理失败。"""


@dataclass
class TeacherInfo:
    """教师自述（写入模型卡，便于追溯蒸馏来源）。"""

    kind: str                       # local | api
    model: str
    detail: str = ""
    product_version: str = ""


class BaseTeacher:
    kind = "base"

    def info(self) -> TeacherInfo:  # pragma: no cover - 抽象
        raise NotImplementedError

    def complete(self, prompt: str, system: str = "") -> str:  # pragma: no cover
        raise NotImplementedError

    def available(self) -> bool:
        try:
            self.complete("ping")
            return True
        except Exception:
            return False


class LocalTeacher(BaseTeacher):
    """本地基底模型教师：真实权重 + 真实推理后端。

    model_path 指向 BaseModelManager 下载/登记的 GGUF 或 HF 目录。
    推理完全复用项目已有的 LocalLLMInference 真实后端（transformers /
    llama_cpp / ctransformers 惰性探测）；没有任何一个可用时抛 TeacherError，
    明确提示「先安装推理后端或改用 API 路径」。
    """

    kind = "local"

    def __init__(self, model_path: str, max_tokens: int = 256) -> None:
        self.model_path = model_path
        self.max_tokens = max_tokens
        self._llm = None

    def info(self) -> TeacherInfo:
        return TeacherInfo(
            kind="local",
            model=os.path.basename(self.model_path),
            detail=f"本地权重 {self.model_path}（LocalLLMInference 真实推理）",
        )

    def _engine(self):
        if self._llm is not None:
            return self._llm
        # 允许 backend 以两种 sys.path 形态被导入（仓库根 / backend 根）
        try:
            from backend.app.runtime.local_llm import LocalLLMInference
        except ImportError:
            try:
                from app.runtime.local_llm import LocalLLMInference  # type: ignore
            except ImportError as exc:
                raise TeacherError(
                    "无法导入 LocalLLMInference；请从仓库根运行或检查 backend 路径"
                ) from exc
        self._llm = LocalLLMInference(gguf_path=self.model_path)
        self._llm.load(self.model_path)
        return self._llm

    def complete(self, prompt: str, system: str = "") -> str:
        if not os.path.exists(self.model_path):
            raise TeacherError(
                f"本地基底模型不存在：{self.model_path}；请先 download 基底模型"
            )
        llm = self._engine()
        if not llm.config.has_native and llm.config.mock:
            raise TeacherError(
                "本机没有可用的推理后端（llama_cpp / ctransformers / transformers）"
                "或权重格式不匹配；请安装依赖，或改用 --source api 走 API 蒸馏"
            )
        text = self._call_real(llm, prompt, system)
        if text is None:
            raise TeacherError(
                "本地教师本次推理未产出文本（后端加载失败或权重不兼容）；"
                "不伪造监督信号，请检查权重/后端"
            )
        return text

    @staticmethod
    def _call_real(llm, prompt: str, system: str) -> str | None:
        """调用真实生成路径；只接受真实输出，不接受检索式/占位回答。"""
        full = f"{system}\n\n{prompt}".strip() if system else prompt
        backend = llm._probe_native()
        if backend is None:
            return None
        model_path = llm.config.gguf_path or ""
        if not model_path:
            return None
        return llm._real_infer(backend, model_path, full, llm.config.max_tokens)


class ApiTeacher(BaseTeacher):
    """OpenAI 兼容 API 教师：真实 HTTP 调用 /chat/completions。

    参数优先级：显式构造参数 > 环境变量（TANGRAM_API_BASE / TANGRAM_API_KEY /
    TANGRAM_API_MODEL）> 内置默认。缺 key 不静默降级，直接抛 TeacherError。
    """

    kind = "api"

    def __init__(
        self,
        base_url: str = "",
        api_key: str = "",
        model: str = "",
        max_tokens: int = 256,
        timeout: float = 60.0,
        extra_headers: dict | None = None,
    ) -> None:
        self.base_url = (
            base_url or os.environ.get("TANGRAM_API_BASE") or "https://api.openai.com/v1"
        ).rstrip("/")
        self.api_key = api_key or os.environ.get("TANGRAM_API_KEY", "")
        self.model = model or os.environ.get("TANGRAM_API_MODEL", "gpt-4o-mini")
        self.max_tokens = max_tokens
        self.timeout = timeout
        self.extra_headers = extra_headers or {}

    def info(self) -> TeacherInfo:
        return TeacherInfo(
            kind="api",
            model=self.model,
            detail=f"OpenAI 兼容端点 {self.base_url}/chat/completions",
        )

    def complete(self, prompt: str, system: str = "") -> str:
        if not self.api_key:
            raise TeacherError(
                "API 蒸馏需要密钥：设置 TANGRAM_API_KEY 或传入 --api-key"
            )
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        body = json.dumps(
            {
                "model": self.model,
                "messages": messages,
                "max_tokens": self.max_tokens,
                "temperature": 0.2,
            }
        ).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {self.api_key}",
            "User-Agent": "tangram-agent/0.0.1",
        }
        headers.update(self.extra_headers)
        req = urllib.request.Request(
            f"{self.base_url}/chat/completions",
            data=body,
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except (urllib.error.URLError, OSError) as exc:
            raise TeacherError(f"API 教师请求失败：{exc}") from exc
        try:
            data = json.loads(raw.decode("utf-8"))
            text = data["choices"][0]["message"]["content"]
        except (KeyError, IndexError, ValueError, TypeError) as exc:
            raise TeacherError(f"API 返回结构无法解析：{raw[:200]!r}") from exc
        if not isinstance(text, str) or not text.strip():
            raise TeacherError("API 教师返回空内容；不伪造监督信号")
        return text.strip()


class CallableTeacher(BaseTeacher):
    """注入式教师（仅用于测试 / 离线自测）。

    用真实的 Python 可调用对象充当教师，便于在没有外网权重与 API 凭据时
    端到端验证「采集 → 蒸馏 → 训练 → 产出 model」链路确实是真实执行的。
    它在模型卡里明确标注 kind=callable，不会被冒充成真实基座/API。
    """

    kind = "callable"

    def __init__(self, fn: Callable[[str, str], str], label: str = "injected") -> None:
        self._fn = fn
        self._label = label

    def info(self) -> TeacherInfo:
        return TeacherInfo(
            kind="callable",
            model=self._label,
            detail="测试/自测注入的教师函数（非真实模型权重，来源可追溯）",
        )

    def complete(self, prompt: str, system: str = "") -> str:
        out = self._fn(prompt, system)
        if not isinstance(out, str) or not out.strip():
            raise TeacherError("注入教师返回空内容")
        return out.strip()


def teacher_from_source(
    source: str,
    *,
    base_model: str = "",
    models_root: str = "models",
    api_base: str = "",
    api_key: str = "",
    api_model: str = "",
) -> BaseTeacher:
    """按来源构造教师：local（下载/登记的基底模型）或 api。"""
    if source == "local":
        if not base_model:
            raise TeacherError("--source local 需要 --base-model 指定已下载基底模型")
        from .base_model import BaseModelManager

        path = BaseModelManager(models_root).resolve(base_model)
        return LocalTeacher(str(path))
    if source == "api":
        return ApiTeacher(base_url=api_base, api_key=api_key, model=api_model)
    raise TeacherError(f"未知蒸馏来源 {source!r}；可选 local | api")
