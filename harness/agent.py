"""TangramAgent：agent = model + harness 的装配层。

一个 agent 由两部分组成，缺一不可：
  * Model：用户训练出来的私人模型（active.json 激活指针 + 权重 + 模型卡）。
  * Harness：工作采集 + 蒸馏 + 真实执行的工作脚手架（WorkDistiller / WorkHarness）。

对外能力：
  * train()      —— 用工作轨迹训练出自己的模型（两条来源：本地基底 / API）。
  * work(task)   —— 让当前 agent 干一件真实工作（经教师/模型产出，记录轨迹）。
  * describe()   —— 自述 equation / 版本 / 模型卡 / 工作轨迹数 / 激活指针。
  * load_active()—— 从本地模型池装配已训练好的 agent。

设计约定：不假设任何具体 LLM 已加载；work() 的推理走教师真实后端，
蒸馏产出的权重由 training.pipeline 落盘并由 active.json 激活，供推理侧接管。
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .distiller import DistillConfig, DistillResult, ModelCard, WorkDistiller
from .version import PRODUCT_NAME, PRODUCT_VERSION
from .work_trace import WorkHarness, WorkLog, WorkTrace


class TangramAgentError(Exception):
    """装配 / 工作失败。"""


@dataclass
class AgentInfo:
    equation: str = "agent = model + harness"
    product: str = PRODUCT_NAME
    version: str = PRODUCT_VERSION
    teacher_kind: str = ""
    teacher_model: str = ""
    model_card: dict = field(default_factory=dict)
    active_pointer: str = ""
    work_traces: int = 0
    has_own_model: bool = False


class TangramAgent:
    """agent = model + harness。"""

    def __init__(
        self,
        distiller: WorkDistiller,
        *,
        models_root: str | Path = "models",
        work_log: WorkLog | None = None,
    ) -> None:
        self.distiller = distiller
        self.models_root = Path(models_root)
        self.work_log = work_log or distiller.work_log
        self.harness = WorkHarness(distiller.teacher, self.work_log)
        self._card: ModelCard | None = None

    # ---- 构造：两条蒸馏来源 ----
    @classmethod
    def for_local_base(
        cls,
        base_model: str,
        *,
        models_root: str | Path = "models",
        config: DistillConfig | None = None,
    ) -> "TangramAgent":
        d = WorkDistiller.from_local_base(base_model, models_root=models_root, config=config)
        return cls(d, models_root=models_root)

    @classmethod
    def for_api(
        cls,
        *,
        api_base: str = "",
        api_key: str = "",
        api_model: str = "",
        models_root: str | Path = "models",
        config: DistillConfig | None = None,
    ) -> "TangramAgent":
        d = WorkDistiller.from_api(
            api_base=api_base, api_key=api_key, api_model=api_model,
            models_root=models_root, config=config,
        )
        return cls(d, models_root=models_root)

    @classmethod
    def for_teacher(cls, teacher, *, models_root: str | Path = "models",
                    config: DistillConfig | None = None) -> "TangramAgent":
        """注入教师（测试 / 自测）：链路仍全部真实执行。"""
        d = WorkDistiller(teacher, models_root=models_root, config=config)
        return cls(d, models_root=models_root)

    # ---- agent 能力 ----
    def work(self, task: str, *, accept: bool = True, corrected: str = "") -> WorkTrace:
        """干一件真实工作：教师推理 → （可选）用户采纳 → 轨迹入库。"""
        trace = self.harness.run_task(task)
        if accept:
            self.harness.accept(trace, corrected)
        else:
            self.harness.reject(trace)
        return trace

    def train(self, traces: list[WorkTrace] | None = None) -> DistillResult:
        """工作蒸馏：产出用户自己的模型。"""
        result = self.distiller.run(traces)
        if result.ok:
            self._card = result.model_card
        return result

    def load_active(self) -> ModelCard | None:
        """从模型池里最新的一张模型卡装配已训练模型。"""
        cards = sorted((self.models_root / "cards").glob("*.model_card.json"))
        if not cards:
            return None
        try:
            data = json.loads(cards[-1].read_text(encoding="utf-8"))
            self._card = ModelCard(**{k: data[k] for k in ModelCard.__dataclass_fields__ if k in data})
            return self._card
        except (json.JSONDecodeError, OSError, TypeError):
            return None

    @property
    def model_card(self) -> ModelCard | None:
        return self._card or self.load_active()

    def describe(self) -> dict[str, Any]:
        info = self.distiller.teacher.info()
        card = self.model_card
        return {
            "equation": "agent = model + harness",
            "product": PRODUCT_NAME,
            "version": PRODUCT_VERSION,
            "model": {
                "has_own_model": card is not None,
                "card": card.name if card else "",
                "active_pointer": str(self.distiller.active_json),
                "samples": card.samples if card else 0,
            },
            "harness": {
                "teacher_kind": info.kind,
                "teacher_model": info.model,
                "work_traces": self.work_log.count(),
            },
        }

    def info(self) -> AgentInfo:
        d = self.describe()
        return AgentInfo(
            teacher_kind=d["harness"]["teacher_kind"],
            teacher_model=d["harness"]["teacher_model"],
            model_card={"name": d["model"]["card"], "samples": d["model"]["samples"]},
            active_pointer=d["model"]["active_pointer"],
            work_traces=d["harness"]["work_traces"],
            has_own_model=d["model"]["has_own_model"],
        )
