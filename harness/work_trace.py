"""工作轨迹（Work Trace）：harness 把「用户真实完成的工作」变成训练信号。

产品逻辑：agent = model + harness。用户不必标注数据集，只要让 agent 在
harness 里替自己干活（对话、写代码、整理文件、查资料……）。每一步的
「任务 → 教师/工具产出 → 用户采纳/修正」被记录为 WorkTrace；蒸馏器把
被采纳的轨迹转成 SFT (prompt, completion) 样本，训练出用户自己的模型。

真实约束：
  * 轨迹落盘为 JSONL（可审计、可回放），不是内存里的假数据。
  * 只有 accepted / 经用户修正的轨迹才进入训练集；拒绝的不进。
  * 采集来源可为：手动 record、真实工作日志 JSONL 导入、harness 自动采集。
"""

from __future__ import annotations

import json
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Iterable

WORK_SYSTEM_PROMPT = (
    "你是 tangram-agent 的工作引擎。请针对用户的真实工作任务，给出可直接采用的"
    "结果（代码、结论、步骤或文本），不要解释过程，不要寒暄。"
)


@dataclass
class WorkTrace:
    """一条工作轨迹。"""

    task: str
    completion: str
    accepted: bool = True
    corrected: str = ""              # 用户修正后的最终版本（优先作为训练目标）
    source: str = "harness"          # harness | import | manual
    meta: dict = field(default_factory=dict)
    ts: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%S"))

    @property
    def target(self) -> str:
        """最终的监督目标：用户修正优先，否则用教师产出。"""
        return (self.corrected or self.completion).strip()

    @property
    def usable(self) -> bool:
        return bool(self.task.strip()) and bool(self.target) and self.accepted


class WorkLog:
    """工作日志：真实落盘的 JSONL 轨迹仓库。"""

    def __init__(self, path: str | Path = "models/work/traces.jsonl") -> None:
        self.path = Path(path)

    def record(self, trace: WorkTrace) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(asdict(trace), ensure_ascii=False) + "\n")

    def record_many(self, traces: Iterable[WorkTrace]) -> int:
        n = 0
        for t in traces:
            self.record(t)
            n += 1
        return n

    def load(self) -> list[WorkTrace]:
        if not self.path.is_file():
            return []
        out: list[WorkTrace] = []
        with self.path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                    out.append(WorkTrace(**{k: d[k] for k in WorkTrace.__dataclass_fields__ if k in d}))
                except (json.JSONDecodeError, TypeError):
                    continue
        return out

    def import_jsonl(self, src: str | Path) -> int:
        """导入真实工作日志（每行需含 task 字段，completion/output/answer 之一）。"""
        src = Path(src)
        if not src.is_file():
            raise FileNotFoundError(f"工作日志不存在：{src}")
        count = 0
        with src.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except json.JSONDecodeError:
                    continue
                task = d.get("task") or d.get("prompt") or d.get("user") or ""
                completion = (
                    d.get("completion") or d.get("output") or d.get("answer")
                    or d.get("assistant") or ""
                )
                if not task or not completion:
                    continue
                self.record(
                    WorkTrace(
                        task=str(task),
                        completion=str(completion),
                        accepted=bool(d.get("accepted", True)),
                        corrected=str(d.get("corrected", "")),
                        source="import",
                        meta={"origin": str(src)},
                    )
                )
                count += 1
        return count

    def count(self) -> int:
        return len(self.load())


class WorkHarness:
    """Harness 侧：让教师对真实任务产出，并把采纳结果记成工作轨迹。

    teacher.complete 是真实推理（本地权重或 API）；失败抛错，不生成假轨迹。
    用户可用 accept()/correct()/reject() 表达反馈，模拟真实「在 harness 里干活」
    的人工闭环；未采纳的轨迹不会进入后续训练集。
    """

    def __init__(self, teacher, work_log: WorkLog | None = None) -> None:
        self.teacher = teacher
        self.log = work_log or WorkLog()

    def run_task(self, task: str, *, system: str = WORK_SYSTEM_PROMPT) -> WorkTrace:
        """执行一项真实工作：教师推理 → 生成轨迹（默认待用户确认）。"""
        if not task.strip():
            raise ValueError("工作任务不能为空")
        completion = self.teacher.complete(task, system)
        return WorkTrace(
            task=task.strip(),
            completion=completion,
            accepted=False,  # 待用户采纳；不是自动当训练数据
            source="harness",
            meta={"teacher": self.teacher.info().model, "teacher_kind": self.teacher.info().kind},
        )

    def accept(self, trace: WorkTrace, corrected: str = "") -> WorkTrace:
        """用户采纳（可附修正版）→ 轨迹入库，成为蒸馏样本。"""
        trace.accepted = True
        if corrected:
            trace.corrected = corrected
        self.log.record(trace)
        return trace

    def reject(self, trace: WorkTrace) -> None:
        """用户拒绝：不记录（不会污染训练集）。"""
        trace.accepted = False


def traces_to_sft(traces: Iterable[WorkTrace]) -> list[dict]:
    """把可用轨迹转成 SFT 样本（与 training.pipeline 的字段约定一致）。"""
    out: list[dict] = []
    seen: set[str] = set()
    for t in traces:
        if not t.usable:
            continue
        key = t.task.strip() + chr(0) + t.target
        if key in seen:
            continue
        seen.add(key)
        out.append(
            {
                "prompt": t.task.strip(),
                "completion": t.target,
                "meta": {"source": t.source, "teacher": t.meta.get("teacher", "")},
            }
        )
    return out
