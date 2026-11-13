"""共享契约加载（Python 侧读取 bridge_contract.json）。"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

_CONTRACT_PATH = Path(__file__).resolve().parent / "bridge_contract.json"


@lru_cache(maxsize=1)
def load_contract() -> dict:
    """加载 PythonBridge 契约（与 frontend/lib/bridge/bridge_protocol.dart 语义一致）。"""
    return json.loads(_CONTRACT_PATH.read_text(encoding="utf-8"))


def control_domains() -> list[str]:
    return load_contract()["control"]["method_domains"]


def hotpath_topics() -> list[str]:
    return load_contract()["hot_path"]["topics"]
