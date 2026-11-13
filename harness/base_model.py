"""基底模型（Model 侧）：本地下载、校验、登记。

产品两条蒸馏路径之一「本地下载基底模型」的落地实现：
  * BASE_CATALOG 是真实可下载的开源基座清单（HuggingFace / hf-mirror 直链）。
  * BaseModelManager.download 用 urllib 真实分块下载，支持断点续传、SHA-256
    校验、大小上限、原子落盘；下载失败不会留下半成品冒充模型。
  * 只登记真实存在且通过校验的权重；不生成任何占位权重。

import 阶段零副作用：不联网、不写文件；所有 I/O 都在方法调用时发生。
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
import urllib.error
import urllib.request
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable

from .version import PRODUCT_VERSION

# 单文件大小上限（防止误填 URL 打满磁盘）；真实基座一般远小于此。
MAX_MODEL_BYTES = 8 * 1024 * 1024 * 1024
_CHUNK = 1024 * 1024

# ProgressFn(downloaded_bytes, total_bytes_or_None)
ProgressFn = Callable[[int, int | None], None]


@dataclass(frozen=True)
class BaseModelSpec:
    """一个可下载的基底模型规格。url_cn 为国内镜像直链（可选）。"""

    id: str
    name: str
    fmt: str                     # gguf | hf
    url: str
    url_cn: str = ""
    sha256: str = ""             # 留空表示不强制校验（仍会计算并写回清单）
    params: str = ""
    license: str = ""
    note: str = ""


# 真实开源基座（HF 官方 / 社区量化直链）。这些地址是产品内置的下载源，
# 用户也可通过 --url 传自己的直链。列在此处不代表仓库内含权重。
BASE_CATALOG: dict[str, BaseModelSpec] = {
    "qwen2.5-0.5b": BaseModelSpec(
        id="qwen2.5-0.5b",
        name="Qwen2.5-0.5B-Instruct Q4_K_M",
        fmt="gguf",
        url="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
        url_cn="https://hf-mirror.com/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
        params="0.5B",
        license="Apache-2.0",
        note="体积小、中文好，适合先跑通端侧蒸馏闭环",
    ),
    "tinyllama-1.1b": BaseModelSpec(
        id="tinyllama-1.1b",
        name="TinyLlama-1.1B-Chat Q4_K_M",
        fmt="gguf",
        url="https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
        url_cn="https://hf-mirror.com/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf",
        params="1.1B",
        license="Apache-2.0",
        note="经典轻量基座，llama.cpp 生态兼容好",
    ),
    "smollm2-135m": BaseModelSpec(
        id="smollm2-135m",
        name="SmolLM2-135M-Instruct Q4_K_M",
        fmt="gguf",
        url="https://huggingface.co/lmstudio-community/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf",
        url_cn="https://hf-mirror.com/lmstudio-community/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf",
        params="135M",
        license="Apache-2.0",
        note="极小基座，手机端冷启动最快",
    ),
}


@dataclass
class LocalBaseModel:
    """已落盘、通过校验的本地基底模型登记项。"""

    id: str
    name: str
    fmt: str
    path: str
    size: int
    sha256: str
    source_url: str
    params: str = ""
    license: str = ""
    downloaded_at: str = field(
        default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%S")
    )
    product_version: str = PRODUCT_VERSION


class BaseModelError(Exception):
    """下载 / 校验 / 登记失败。"""


class BaseModelManager:
    """本地基底模型池：<root>/base/ 存权重，registry.json 存登记。

    root 缺省为仓库根 models/（与 training.pipeline 的模型池同址），
    便于蒸馏时直接拿到 base_path。
    """

    def __init__(self, root: str | Path = "models") -> None:
        self.root = Path(root)
        self.base_dir = self.root / "base"
        self.registry_path = self.root / "base" / "registry.json"

    # ---- 清单 ----
    def catalog(self) -> list[dict]:
        """可下载基座清单（不联网）。"""
        return [asdict(s) for s in BASE_CATALOG.values()]

    def list_local(self) -> list[dict]:
        """已登记且文件仍存在的本地基座。"""
        out: list[dict] = []
        for rec in self._read_registry():
            p = Path(rec.get("path", ""))
            if p.is_file():
                out.append(rec)
        return out

    def resolve(self, model_id_or_path: str) -> Path:
        """按 id 或本地路径解析出真实权重路径；不存在即报错。"""
        p = Path(model_id_or_path)
        if p.is_file():
            return p.resolve()
        for rec in self._read_registry():
            if rec.get("id") == model_id_or_path:
                q = Path(rec["path"])
                if q.is_file():
                    return q.resolve()
                break
        raise BaseModelError(
            f"本地未找到基底模型 {model_id_or_path!r}；请先 download 或传入真实权重路径"
        )

    # ---- 真实下载 ----
    def download(
        self,
        model_id_or_url: str,
        *,
        use_cn_mirror: bool = False,
        expected_sha256: str = "",
        force: bool = False,
        on_progress: ProgressFn | None = None,
        timeout: float = 60.0,
    ) -> LocalBaseModel:
        """真实下载基座权重并登记。

        - model_id_or_url 为 BASE_CATALOG 的 id，或任意 http(s) 直链。
        - 断点续传：已存在同名的 .part 且服务器支持 Range 时续传。
        - SHA-256：spec 提供或调用方传入时强制校验，不符即删除并报错。
        - 原子落盘：先写 .part，校验通过后 os.replace 到最终路径。
        """
        spec, url = self._resolve_source(model_id_or_url, use_cn_mirror)
        self.base_dir.mkdir(parents=True, exist_ok=True)
        filename = self._filename(url, spec)
        target = self.base_dir / filename
        part = target.with_suffix(target.suffix + ".part")

        if target.is_file() and not force:
            return self._register_existing(spec, target, url)

        sha = hashlib.sha256()
        existing = part.stat().st_size if part.is_file() else 0
        # 续传时把已有字节纳入哈希，保证最终 sha256 覆盖完整文件
        if existing:
            with part.open("rb") as fh:
                for block in iter(lambda: fh.read(_CHUNK), b""):
                    sha.update(block)

        headers = {"User-Agent": f"tangram-agent/{PRODUCT_VERSION}"}
        if existing:
            headers["Range"] = f"bytes={existing}-"
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = getattr(resp, "status", 200)
                if existing and status != 206:
                    # 服务端不支持续传，从头下
                    existing = 0
                    sha = hashlib.sha256()
                    part.write_bytes(b"")
                total = self._content_length(resp.headers, existing)
                mode = "ab" if existing else "wb"
                written = existing
                with part.open(mode) as out:
                    while True:
                        block = resp.read(_CHUNK)
                        if not block:
                            break
                        out.write(block)
                        sha.update(block)
                        written += len(block)
                        if written > MAX_MODEL_BYTES:
                            raise BaseModelError(
                                f"下载超过上限 {MAX_MODEL_BYTES} 字节，疑似非模型直链：{url}"
                            )
                        if on_progress:
                            on_progress(written, total)
        except (urllib.error.URLError, OSError) as exc:
            raise BaseModelError(f"基底模型下载失败：{url}（{exc}）") from exc

        digest = sha.hexdigest()
        want = expected_sha256 or (spec.sha256 if spec else "")
        if want and digest.lower() != want.lower():
            part.unlink(missing_ok=True)
            raise BaseModelError(
                f"SHA-256 校验失败：期望 {want}，实际 {digest}；已删除半成品"
            )
        size = part.stat().st_size
        if size == 0:
            part.unlink(missing_ok=True)
            raise BaseModelError("下载得到空文件，已删除")

        os.replace(part, target)
        return self._register(
            LocalBaseModel(
                id=spec.id if spec else target.stem,
                name=spec.name if spec else target.name,
                fmt=spec.fmt if spec else ("gguf" if target.suffix == ".gguf" else "hf"),
                path=str(target.resolve()),
                size=size,
                sha256=digest,
                source_url=url,
                params=spec.params if spec else "",
                license=spec.license if spec else "",
            )
        )

    @staticmethod
    def _content_length(headers, existing: int) -> int | None:
        raw = headers.get("Content-Length")
        if not raw:
            return None
        try:
            n = int(raw)
        except ValueError:
            return None
        return n + existing if existing else n

    @staticmethod
    def _filename(url: str, spec: BaseModelSpec | None) -> str:
        tail = url.split("?")[0].rstrip("/").split("/")[-1]
        if not tail or "." not in tail:
            tail = f"{spec.id}.gguf" if spec else "base_model.gguf"
        # 只允许安全字符，防止 URL 注入路径穿越
        safe = "".join(c for c in tail if c.isalnum() or c in "._-")
        return safe or "base_model.gguf"

    def _resolve_source(
        self, key: str, use_cn_mirror: bool
    ) -> tuple[BaseModelSpec | None, str]:
        spec = BASE_CATALOG.get(key)
        if spec:
            url = spec.url_cn if (use_cn_mirror and spec.url_cn) else spec.url
            return spec, url
        if key.startswith(("http://", "https://")):
            return None, key
        raise BaseModelError(
            f"未知基底模型 {key!r}；可用 id: {', '.join(BASE_CATALOG)} 或 http(s) 直链"
        )

    def _register_existing(
        self, spec: BaseModelSpec | None, target: Path, url: str
    ) -> LocalBaseModel:
        digest = self._sha256_file(target)
        want = spec.sha256 if spec else ""
        if want and digest.lower() != want.lower():
            raise BaseModelError(f"已存在文件校验不符：{target}；请加 --force 重新下载")
        for rec in self._read_registry():
            if Path(rec.get("path", "")).resolve() == target.resolve():
                return LocalBaseModel(**{k: rec[k] for k in LocalBaseModel.__dataclass_fields__ if k in rec})
        return self._register(
            LocalBaseModel(
                id=spec.id if spec else target.stem,
                name=spec.name if spec else target.name,
                fmt=spec.fmt if spec else "gguf",
                path=str(target.resolve()),
                size=target.stat().st_size,
                sha256=digest,
                source_url=url,
                params=spec.params if spec else "",
                license=spec.license if spec else "",
            )
        )

    @staticmethod
    def _sha256_file(p: Path) -> str:
        h = hashlib.sha256()
        with p.open("rb") as fh:
            for block in iter(lambda: fh.read(_CHUNK), b""):
                h.update(block)
        return h.hexdigest()

    # ---- 登记文件 ----
    def _read_registry(self) -> list[dict]:
        if not self.registry_path.is_file():
            return []
        try:
            data = json.loads(self.registry_path.read_text(encoding="utf-8"))
            return data.get("models", []) if isinstance(data, dict) else []
        except (json.JSONDecodeError, OSError):
            return []

    def _register(self, rec: LocalBaseModel) -> LocalBaseModel:
        models = [
            r for r in self._read_registry() if r.get("id") != rec.id
        ]
        models.append(asdict(rec))
        self.registry_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.registry_path.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(
                {"product": "tangram-agent", "version": PRODUCT_VERSION, "models": models},
                ensure_ascii=False,
                indent=2,
            ),
            encoding="utf-8",
        )
        os.replace(tmp, self.registry_path)
        return rec
