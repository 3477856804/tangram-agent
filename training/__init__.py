"""Tangram 真实训练流水线。

对外导出 :class:`QLoRAJob` / :class:`MergeJob` / :class:`Promoter` 等，
全部执行真实的数值优化与真实磁盘落盘，不产出任何占位权重。
"""

from .pipeline import (
    MergeJob,
    Promoter,
    QLoRAConfig,
    QLoRAJob,
    SFTTrace,
    TrainingError,
    load_adapter,
)

__all__ = [
    "MergeJob",
    "Promoter",
    "QLoRAConfig",
    "QLoRAJob",
    "SFTTrace",
    "TrainingError",
    "load_adapter",
]
