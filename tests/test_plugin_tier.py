"""插件分级与能力声明（fail-closed）测试。

对应 0.0.41 架构融合：T0–T3 分级、T3 必须显式声明 caps、未知 tier 兜底 T1。
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backend.app.runtime.plugin_runtime import (  # noqa: E402
    ToolError,
    _normalize_manifest,
)

_BASE = {
    "id": "demo",
    "version": "0.0.1",
    "tools": [{"name": "echo", "type": "prompt", "prompt": "echo: {text}"}],
}


def _manifest(**extra):
    m = dict(_BASE)
    m.update(extra)
    return _normalize_manifest(m)


def test_default_tier_is_official():
    m = _manifest()
    assert m["tier"] == "T1"
    assert m["caps"] == []


def test_tier_accepts_wire_and_alias():
    assert _manifest(tier="T0")["tier"] == "T0"
    assert _manifest(tier="third_party", caps=["net:fetch"])["tier"] == "T3"
    assert _manifest(tier="user")["tier"] == "T2"


def test_unknown_tier_falls_back_to_official():
    assert _manifest(tier="T9")["tier"] == "T1"
    assert _manifest(tier="weird")["tier"] == "T1"


def test_caps_dedup_and_sorted():
    assert _manifest(caps=["b", "a", "a"])["caps"] == ["a", "b"]


def test_t3_requires_caps_fail_closed():
    with pytest.raises(ToolError) as exc:
        _manifest(tier="T3")
    assert "caps" in str(exc.value)


def test_caps_must_be_string_list():
    with pytest.raises(ToolError):
        _manifest(caps="net:fetch")
    with pytest.raises(ToolError):
        _manifest(caps=["ok", 1])


def test_t3_with_caps_is_accepted():
    m = _manifest(tier="T3", caps=["net:fetch"])
    assert m["tier"] == "T3"
    assert m["caps"] == ["net:fetch"]
