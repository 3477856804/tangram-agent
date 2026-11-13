"""工作蒸馏器（WorkDistiller）：把工作轨迹真正训练成用户自己的模型。

链路（全部真实执行，非占位）：
  WorkLog 轨迹 → traces_to_sft → JSONL 数据集落盘
    → training.pipeline.QLoRAJob.run(traces=...)（torch 真实梯度下降，落盘 .pt）
    → MergeJob.merge(.pt adapter, base)（真实合并权重 .merged.pt + GGUF 标记）
    → Promoter.promote(...)(原子更新 active.json 激活指针)
    → 模型卡 model_card.json（记录 lineage / 指标 / 版本 / agent=model+harness）

两条入口：
  * from_local_base()：本地下载基底模型 → LocalTeacher → 工作蒸馏 → 私人 model
  * from_api()：调用 API → ApiTeacher → 工作蒸馏 → 私人 model

诚实边界：训练用的是真实的 bag-of-chars 特征 + torch 线性适配核（凸优化，
loss 单调下降、权重真实落盘）。它是「把工作行为蒸进一个可加载适配核」的
最小真实实现；要蒸出完整 LLM 权重需接入 peft/transformers 的 QLoRA（本机
有权重与 GPU 时由 training.pipeline 的原生路径接管）。二者都不伪造产物。
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from .version import PRODUCT_NAME, PRODUCT_VERSION
from .work_trace import WorkLog, WorkTrace, traces_to_sft

logger = logging.getLogger(__name__)


@dataclass
class DistillConfig:
    """一次蒸馏作业的配置。"""

    epochs: int = 8
    lr: float = 2e-4
    model_name: str = "my-agent"
    promote: bool = True                 # 训练成功后晋升为 active
    min_samples: int = 1                # 少于此数量直接失败（不空训）
    seed_tasks: list[str] = field(default_factory=list)


@dataclass
class ModelCard:
    """用户私人模型的模型卡（真实产物清单 + 血缘）。"""

    name: str
    version: str
    equation: str = "agent = model + harness"
    teacher: dict = field(default_factory=dict)
    base_model: str = ""
    samples: int = 0
    metrics: dict = field(default_factory=dict)
    artifacts: dict = field(default_factory=dict)
    dataset: str = ""
    active_pointer: str = ""
    created_at: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%S"))


@dataclass
class DistillResult:
    ok: bool
    model_card: ModelCard | None = None
    error: str = ""
    stages: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "error": self.error,
            "stages": self.stages,
            "model_card": asdict(self.model_card) if self.model_card else None,
        }


class WorkDistiller:
    """工作蒸馏引擎：agent 的 harness 侧核心。"""

    def __init__(
        self,
        teacher,
        *,
        models_root: str | Path = "models",
        config: DistillConfig | None = None,
        work_log: WorkLog | None = None,
    ) -> None:
        self.teacher = teacher
        self.models_root = Path(models_root)
        self.config = config or DistillConfig()
        self.work_log = work_log or WorkLog(self.models_root / "work" / "traces.jsonl")
        self.active_json = self.models_root / "active.json"

    # ---- 两条产品入口 ----
    @classmethod
    def from_local_base(
        cls,
        base_model: str,
        *,
        models_root: str | Path = "models",
        config: DistillConfig | None = None,
    ) -> "WorkDistiller":
        from .teachers import teacher_from_source

        teacher = teacher_from_source(
            "local", base_model=base_model, models_root=str(models_root)
        )
        return cls(teacher, models_root=models_root, config=config)

    @classmethod
    def from_api(
        cls,
        *,
        api_base: str = "",
        api_key: str = "",
        api_model: str = "",
        models_root: str | Path = "models",
        config: DistillConfig | None = None,
    ) -> "WorkDistiller":
        from .teachers import teacher_from_source

        teacher = teacher_from_source(
            "api", api_base=api_base, api_key=api_key, api_model=api_model
        )
        return cls(teacher, models_root=models_root, config=config)

    # ---- 主流程 ----
    def run(self, traces: list[WorkTrace] | None = None) -> DistillResult:
        """执行完整蒸馏。任何一步失败都返回 ok=False 与明确原因。"""
        stages: list[str] = []
        try:
            all_traces = list(traces or []) + self.work_log.load()
            sft = traces_to_sft(all_traces)
            if len(sft) < self.config.min_samples:
                return DistillResult(
                    False,
                    error=(
                        f"可用工作轨迹不足：需要 >= {self.config.min_samples} 条，"
                        f"实际 {len(sft)} 条。请先在 harness 里完成并采纳工作，"
                        "或导入真实工作日志（不空训、不伪造样本）"
                    ),
                    stages=stages,
                )

            dataset_path = self._write_dataset(sft)
            stages.append(f"dataset:{dataset_path}:{len(sft)}")

            summary = self._train(sft)
            metrics = summary.get("metrics", {})
            stages.append(f"train:{metrics.get('backend', 'unknown')}")

            ckpt = self._find_checkpoint(summary)
            merge = self._merge(ckpt)
            stages.append(f"merge:{merge['gguf']}")

            if self.config.promote:
                self._promote(merge["gguf"])
                stages.append("promoted")

            card = self._write_card(sft, metrics, merge, dataset_path)
            stages.append(f"card:{card.artifacts.get('card', '')}")
            return DistillResult(True, model_card=card, stages=stages)
        except Exception as exc:  # noqa: BLE001 - 统一返回明确错误
            logger.exception("工作蒸馏失败")
            return DistillResult(False, error=f"{type(exc).__name__}: {exc}", stages=stages)

    # ---- 各阶段（均真实落盘）----
    def _write_dataset(self, sft: list[dict]) -> str:
        d = self.models_root / "datasets"
        d.mkdir(parents=True, exist_ok=True)
        p = d / f"work_sft_{time.strftime('%Y%m%d%H%M%S')}.jsonl"
        with p.open("w", encoding="utf-8") as fh:
            for row in sft:
                fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        return str(p.resolve())

    def _train(self, sft: list[dict]) -> dict:
        from training.pipeline import QLoRAJob, QLoRAConfig, SFTTrace

        job = QLoRAJob(
            self.models_root,
            QLoRAConfig(epochs=self.config.epochs, lr=self.config.lr),
        )
        traces = [SFTTrace(prompt=r["prompt"], completion=r["completion"]) for r in sft]
        return job.run(epochs=self.config.epochs, lr=self.config.lr, traces=traces)

    @staticmethod
    def _find_checkpoint(summary: dict) -> str:
        m = summary.get("metrics", {})
        ckpt = m.get("checkpoint")
        if ckpt and Path(ckpt).is_file():
            return ckpt
        # 无 torch 的模拟分支：没有真实权重，明确失败，不拿占位文件冒充产物
        raise RuntimeError(
            "训练未产出真实权重 .pt（torch 不可用或未落盘）；"
            "本产品不把模拟产物冒充用户模型，请安装 torch 后重试"
        )

    def _merge(self, ckpt: str) -> dict:
        from training.pipeline import MergeJob

        teacher_info = self.teacher.info()
        base = (
            self._base_path()
            if teacher_info.kind == "local"
            else self.active_json.parent / "base" / "api_distill_base.placeholder"
        )
        # API 路径没有本地基座权重：MergeJob 只做标记，仍会真实落盘合并权重 .merged.pt
        gguf = MergeJob(self.models_root).merge(ckpt, base)
        marker = Path(gguf).with_suffix(".merge.json")
        real_artifact = ""
        if marker.is_file():
            try:
                real_artifact = json.loads(marker.read_text(encoding="utf-8")).get(
                    "real_artifact", ""
                ) or ""
            except (json.JSONDecodeError, OSError):
                pass
        return {
            "gguf": gguf,
            "real_artifact": real_artifact,
            "adapter": ckpt,
        }

    def _base_path(self) -> str:
        info = self.teacher.info()
        # LocalTeacher 的 model 字段是文件名；真实路径从登记项里取
        try:
            from .base_model import BaseModelManager

            recs = BaseModelManager(self.models_root).list_local()
            for r in recs:
                if os.path.basename(r.get("path", "")) == info.model:
                    return r["path"]
        except Exception:
            pass
        return str(self.models_root / "base" / info.model)

    def _promote(self, gguf: str) -> None:
        from training.pipeline import Promoter

        # 只在本次作业的模型池内写 active.json，绝不回退改写仓库内的只读挂载，
        # 保证 demo / 多用户训练互不污染、换机器可复现。
        active = self.models_root / "active.json"
        active.parent.mkdir(parents=True, exist_ok=True)
        Promoter(active).promote(gguf, kind="chat")
        self.active_json = active

    def _write_card(
        self, sft: list[dict], metrics: dict, merge: dict, dataset_path: str
    ) -> ModelCard:
        info = self.teacher.info()
        cards = self.models_root / "cards"
        cards.mkdir(parents=True, exist_ok=True)
        card_path = cards / f"{self.config.model_name}-{int(time.time())}.model_card.json"
        card = ModelCard(
            name=self.config.model_name,
            version=PRODUCT_VERSION,
            teacher=asdict(info),
            base_model=info.model if info.kind == "local" else "(api teacher, no local base)",
            samples=len(sft),
            metrics=metrics,
            artifacts={
                "adapter": merge["adapter"],
                "merged_weights": merge["real_artifact"],
                "gguf_marker": merge["gguf"],
                "card": str(card_path.resolve()),
            },
            dataset=dataset_path,
            active_pointer=str(self.active_json.resolve()),
        )
        payload = asdict(card)
        payload["product"] = PRODUCT_NAME
        card_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        return card
