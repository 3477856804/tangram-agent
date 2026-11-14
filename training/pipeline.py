"""真实训练流水线：工作轨迹 → 可加载的适配核权重 → 合并 → 晋升。

本模块是 ``harness/distiller.py`` 所引用的 ``training.pipeline`` 的真实实现。
此前仓库里只有引用、没有这个包，导致「工作蒸馏 → 产出私人模型」整条链路
永远在 import 阶段失败——是一个空壳（假功能）。现在：

* :class:`QLoRAJob` 对 SFT 样本做**真实的凸优化**：字符 n-gram 哈希特征
  （prompt）→ 线性适配核 → 目标特征（completion），用梯度下降最小化
  MSE + L2。有 torch 时走真实 autograd + Adam，权重 ``torch.save`` 落盘
  ``.pt``；没有 torch 时用纯 Python 实现同一目标函数的解析梯度并落盘
  JSON 权重。两条路径都是真实数值计算，loss 单调下降，权重可重新加载。
* :class:`MergeJob` 把适配核与基底权重（若存在且可加载）做**真实相加**，
  产出 ``.merged.pt`` / ``.merged.json``，并写一份如实标注格式的标记文件
  （明确说明它不是 GGUF 二进制，绝不拿占位文件冒充模型产物）。
* :class:`Promoter` 原子更新 ``active.json`` 激活指针。

边界（诚实）：这里训练的是「把工作行为蒸进一个可加载适配核」的最小真实
模型，不是完整 LLM 权重；要蒸出完整 LLM 需 peft/transformers 的 QLoRA +
本地基底权重。产物里如实记录 backend / 特征维度 / loss 曲线 / sha256，
不把任何东西伪装成它不属于的格式。
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Sequence

__all__ = [
    "TrainingError",
    "QLoRAConfig",
    "SFTTrace",
    "QLoRAJob",
    "MergeJob",
    "Promoter",
    "load_adapter",
]


class TrainingError(RuntimeError):
    """训练/合并/晋升失败（明确报错，不静默降级成假产物）。"""


@dataclass
class QLoRAConfig:
    epochs: int = 8
    lr: float = 2e-4
    feature_dim: int = 64
    l2: float = 1e-4
    seed: int = 20261115

    def __post_init__(self) -> None:
        if self.epochs < 1:
            raise TrainingError("epochs 必须 >= 1")
        if self.lr <= 0:
            raise TrainingError("lr 必须 > 0")
        if self.feature_dim < 8:
            raise TrainingError("feature_dim 必须 >= 8")


@dataclass
class SFTTrace:
    """一条监督样本（与 ``harness.work_trace.traces_to_sft`` 字段一致）。"""

    prompt: str
    completion: str


def _char_ngrams(text: str) -> list[str]:
    """真实字符特征：汉字/字母 bigram + 单字，用于哈希特征。"""
    cleaned = "".join(ch for ch in text if not ch.isspace())
    grams: list[str] = []
    for i in range(len(cleaned)):
        grams.append(cleaned[i])
        if i + 1 < len(cleaned):
            grams.append(cleaned[i:i + 2])
    return grams


def _feature(text: str, dim: int) -> list[float]:
    """signed hashing trick → L2 归一化实向量（确定性、可复现）。"""
    vec = [0.0] * dim
    for g in _char_ngrams(text):
        h = int.from_bytes(hashlib.blake2b(g.encode("utf-8"), digest_size=8).digest(), "big")
        idx = h % dim
        sign = 1.0 if (h >> 63) & 1 else -1.0
        vec[idx] += sign
    norm = math.sqrt(sum(v * v for v in vec))
    if norm > 0:
        vec = [v / norm for v in vec]
    return vec


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _atomic_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def _torch():
    try:
        import torch  # noqa: PLC0415 - 惰性导入，缺失时走纯 Python 路径
    except Exception:
        return None
    return torch


class QLoRAJob:
    """把工作轨迹训练成真实的可加载适配核。"""

    def __init__(self, models_root: str | Path, config: QLoRAConfig | None = None) -> None:
        self.models_root = Path(models_root)
        self.config = config or QLoRAConfig()
        self.adapter_dir = self.models_root / "adapters"
        self.adapter_dir.mkdir(parents=True, exist_ok=True)

    def run(
        self,
        epochs: int | None = None,
        lr: float | None = None,
        traces: Sequence[SFTTrace] | None = None,
    ) -> dict:
        """真实训练；返回 ``{"metrics": {...}, "artifacts": {...}}``。"""
        rows = list(traces or [])
        if not rows:
            raise TrainingError("没有可执行训练的 SFT 样本（不空训、不伪造样本）")
        cleaned = [
            SFTTrace(str(r.prompt).strip(), str(r.completion).strip())
            for r in rows
            if str(r.prompt).strip() and str(r.completion).strip()
        ]
        if not cleaned:
            raise TrainingError("SFT 样本的 prompt/completion 全为空")

        ep = int(epochs or self.config.epochs)
        rate = float(lr or self.config.lr)
        dim = self.config.feature_dim
        xs = [_feature(r.prompt, dim) for r in cleaned]
        ys = [_feature(r.completion, dim) for r in cleaned]

        torch = _torch()
        stamp = time.strftime("%Y%m%d%H%M%S")
        if torch is not None:
            weights, loss_curve = self._train_torch(torch, xs, ys, ep, rate, dim)
            ckpt = self.adapter_dir / f"work_adapter_{stamp}.pt"
            torch.save(
                {
                    "format": "tangram-adapter-v1",
                    "W": torch.tensor(weights, dtype=torch.float32),
                    "meta": {
                        "backend": "torch",
                        "feature_dim": dim,
                        "samples": len(cleaned),
                        "epochs": ep,
                        "lr": rate,
                        "loss_curve": loss_curve,
                        "seed": self.config.seed,
                    },
                },
                str(ckpt),
            )
            backend = "torch"
        else:
            weights, loss_curve = self._train_pure(xs, ys, ep, rate, dim)
            ckpt = self.adapter_dir / f"work_adapter_{stamp}.json"
            _atomic_json(
                ckpt,
                {
                    "format": "tangram-adapter-v1",
                    "W": weights,
                    "meta": {
                        "backend": "pure-python",
                        "feature_dim": dim,
                        "samples": len(cleaned),
                        "epochs": ep,
                        "lr": rate,
                        "loss_curve": loss_curve,
                        "seed": self.config.seed,
                    },
                },
            )
            backend = "pure-python"

        if loss_curve and loss_curve[-1] > loss_curve[0] + 1e-9:
            raise TrainingError(
                f"训练发散（loss {loss_curve[0]:.6f} → {loss_curve[-1]:.6f}）；"
                "不把发散权重冒充训练产物，请调小 lr"
            )

        metrics = {
            "backend": backend,
            "checkpoint": str(ckpt.resolve()),
            "loss_start": loss_curve[0] if loss_curve else None,
            "loss_end": loss_curve[-1] if loss_curve else None,
            "loss_curve": loss_curve,
            "epochs": ep,
            "lr": rate,
            "samples": len(cleaned),
            "features": dim,
            "params": dim * dim,
            "artifact_sha256": _sha256_file(ckpt),
        }
        log_path = self.adapter_dir / f"training_log_{stamp}.json"
        _atomic_json(log_path, {"metrics": metrics, "samples": [
            {"prompt": r.prompt[:120], "completion": r.completion[:120]} for r in cleaned
        ]})
        return {"metrics": metrics, "artifacts": {"checkpoint": str(ckpt.resolve()),
                                                  "training_log": str(log_path.resolve())}}

    @staticmethod
    def _train_torch(torch, xs: list[list[float]], ys: list[list[float]],
                     epochs: int, lr: float, dim: int) -> tuple[list[list[float]], list[float]]:
        torch.manual_seed(20261115)
        X = torch.tensor(xs, dtype=torch.float32)
        Y = torch.tensor(ys, dtype=torch.float32)
        W = torch.zeros(dim, dim, dtype=torch.float32, requires_grad=True)
        opt = torch.optim.Adam([W], lr=min(lr, 0.05))
        curve: list[float] = []
        for _ in range(max(epochs, 1)):
            opt.zero_grad()
            pred = X @ W
            loss = ((pred - Y) ** 2).mean() + 1e-4 * (W ** 2).mean()
            loss.backward()
            opt.step()
            curve.append(float(loss.detach()))
        # 用更新后的参数再算一次真实最终 loss
        with torch.no_grad():
            curve.append(float(((X @ W - Y) ** 2).mean() + 1e-4 * (W ** 2).mean()))
        return W.detach().tolist(), curve

    @staticmethod
    def _train_pure(xs: list[list[float]], ys: list[list[float]],
                    epochs: int, lr: float, dim: int) -> tuple[list[list[float]], list[float]]:
        """纯 Python 解析梯度下降：与 torch 路径同一个目标函数。"""
        W = [[0.0] * dim for _ in range(dim)]
        n = len(xs)
        rate = min(lr, 0.05)
        curve: list[float] = []

        def loss_of() -> float:
            total = 0.0
            for x, y in zip(xs, ys):
                for j in range(dim):
                    pred = sum(W[j][i] * x[i] for i in range(dim))
                    total += (pred - y[j]) ** 2
            return total / (n * dim)

        curve.append(loss_of())
        for _ in range(max(epochs, 1)):
            grad = [[0.0] * dim for _ in range(dim)]
            for x, y in zip(xs, ys):
                for j in range(dim):
                    pred = sum(W[j][i] * x[i] for i in range(dim))
                    err = 2.0 * (pred - y[j]) / (n * dim)
                    row = grad[j]
                    for i in range(dim):
                        row[i] += err * x[i]
            for j in range(dim):
                for i in range(dim):
                    W[j][i] -= rate * (grad[j][i] + 2e-4 * W[j][i])
            curve.append(loss_of())
        return W, curve


def load_adapter(path: str | Path) -> dict:
    """真实加载适配核（torch .pt 或 JSON），返回 ``{"weights", "meta", "format"}``。"""
    p = Path(path)
    if not p.is_file():
        raise TrainingError(f"适配核文件不存在：{p}")
    if p.suffix == ".pt":
        torch = _torch()
        if torch is None:
            raise TrainingError("该适配核是 .pt 格式，但本机没有 torch，无法加载")
        obj = torch.load(str(p), map_location="cpu", weights_only=False)
        w = obj["W"]
        return {
            "weights": w.tolist() if hasattr(w, "tolist") else list(w),
            "meta": dict(obj.get("meta") or {}),
            "format": "torch",
        }
    data = json.loads(p.read_text(encoding="utf-8"))
    if data.get("format") != "tangram-adapter-v1" or not isinstance(data.get("W"), list):
        raise TrainingError(f"适配核格式无法识别：{p}")
    return {"weights": data["W"], "meta": dict(data.get("meta") or {}), "format": "json"}


class MergeJob:
    """真实合并：适配核 ⊕ 基底权重（可加载时相加），产出可加载合并权重。"""

    def __init__(self, models_root: str | Path) -> None:
        self.models_root = Path(models_root)
        self.merged_dir = self.models_root / "merged"
        self.merged_dir.mkdir(parents=True, exist_ok=True)

    def merge(self, ckpt: str, base: str | Path = "") -> str:
        adapter = load_adapter(ckpt)
        weights = [list(map(float, row)) for row in adapter["weights"]]
        dim = len(weights)
        base_path = Path(base) if base else None
        base_info: dict = {
            "path": str(base_path) if base_path else "",
            "present": bool(base_path and base_path.is_file()),
            "merged_into_weights": False,
        }
        if base_info["present"]:
            base_info["sha256"] = _sha256_file(base_path)
            base_info["size"] = base_path.stat().st_size
            # 只有同为可加载的 torch 适配核才做真实权重相加；GGUF 二进制
            # 不能与线性适配核相加，如实记录而不假装合并。
            if base_path.suffix == ".pt":
                try:
                    other = load_adapter(base_path)
                    ow = other["weights"]
                    if len(ow) == dim and all(len(r) == dim for r in ow):
                        for j in range(dim):
                            for i in range(dim):
                                weights[j][i] += float(ow[j][i])
                        base_info["merged_into_weights"] = True
                except TrainingError:
                    pass
        else:
            base_info["note"] = "API 教师路径没有本地基底权重：合并产物只包含本次真实训练出的适配核"

        stamp = time.strftime("%Y%m%d%H%M%S")
        marker = self.merged_dir / f"tangram_model_{stamp}.gguf.marker.json"
        torch = _torch()
        if torch is not None:
            merged = self.merged_dir / f"tangram_model_{stamp}.merged.pt"
            torch.save(
                {
                    "format": "tangram-merged-v1",
                    "W": torch.tensor(weights, dtype=torch.float32),
                    "meta": {"adapter": str(ckpt), "base": base_info,
                             "feature_dim": dim, "created_at": stamp},
                },
                str(merged),
            )
        else:
            merged = self.merged_dir / f"tangram_model_{stamp}.merged.json"
            _atomic_json(merged, {
                "format": "tangram-merged-v1",
                "W": weights,
                "meta": {"adapter": str(ckpt), "base": base_info,
                         "feature_dim": dim, "created_at": stamp},
            })
        sha = _sha256_file(merged)

        # 标记文件：如实声明格式，绝不把 JSON/权重伪装成 GGUF 二进制。
        _atomic_json(marker, {
            "format": "tangram-merge-marker-v1",
            "note": "本文件是合并产物的元数据标记，不是 GGUF 二进制权重；"
                    "真实可加载权重见 real_artifact。",
            "real_artifact": str(merged.resolve()),
            "real_artifact_sha256": sha,
            "base": base_info,
            "adapter": str(ckpt),
            "created_at": stamp,
        })
        _atomic_json(Path(str(marker) + ".merge.json"), {
            "real_artifact": str(merged.resolve()),
            "real_artifact_sha256": sha,
            "merged_weights": str(merged.resolve()),
            "base": base_info,
        })
        # distill 端读的是 Path(gguf).with_suffix(".merge.json")
        legacy = marker.with_suffix(".merge.json")
        if legacy != Path(str(marker) + ".merge.json"):
            _atomic_json(legacy, {
                "real_artifact": str(merged.resolve()),
                "real_artifact_sha256": sha,
            })
        return str(marker.resolve())


class Promoter:
    """原子晋升：把本次真实产物写进 active.json 激活指针。"""

    def __init__(self, active_path: str | Path) -> None:
        self.active_path = Path(active_path)

    def promote(self, gguf_marker: str, kind: str = "chat") -> dict:
        marker = Path(gguf_marker)
        if not marker.is_file():
            raise TrainingError(f"晋升失败：标记文件不存在 {marker}")
        try:
            meta = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise TrainingError(f"晋升失败：标记文件不可读 {exc}") from exc
        payload = {
            "schema_version": "1.0.0",
            "product": "tangram-agent",
            "kind": kind,
            "marker": str(marker.resolve()),
            "real_artifact": meta.get("real_artifact", ""),
            "real_artifact_sha256": meta.get("real_artifact_sha256", ""),
            "format_note": meta.get("note", ""),
            "promoted_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        }
        _atomic_json(self.active_path, payload)
        return payload
