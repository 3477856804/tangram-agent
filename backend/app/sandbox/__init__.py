"""沙箱策略：从随包 JSON 真实读取，不内嵌假策略。"""

from __future__ import annotations

import json
from pathlib import Path

POLICY_PATH = Path(__file__).with_name("sandbox_policy.json")


def load_policy() -> dict:
    """读取真实策略文件；缺失 / 损坏一律抛错（绝不静默给宽松默认值）。"""
    data = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or "allow" not in data:
        raise ValueError("sandbox_policy.json 结构非法")
    return data


__all__ = ["POLICY_PATH", "load_policy"]
