"""Python 插件运行时（NDJSON）真实子进程测试。

覆盖：启动与 ping/health/list、注册后调用 prompt 工具、shell 默认拒绝、
显式放行后的真实执行、超时、并发上限、非法 JSON 不崩溃、审计文件、
stdin 关闭后退出码 0。全部本地，不依赖网络。
"""

from __future__ import annotations

import json
import os
import select
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict

import pytest

_RUNTIME = (
    Path(__file__).resolve().parent.parent
    / "backend"
    / "app"
    / "runtime"
    / "plugin_runtime.py"
)


def _spawn(tmp_path: Path, *extra: str) -> subprocess.Popen:
    env = dict(os.environ)
    env["PYTHONIOENCODING"] = "utf-8"
    return subprocess.Popen(
        [sys.executable, str(_RUNTIME), *extra],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        cwd=str(tmp_path),
        env=env,
    )


def _send(proc: subprocess.Popen, payload: Dict[str, Any]) -> None:
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
    proc.stdin.flush()


def _readline(proc: subprocess.Popen, timeout: float = 10.0) -> Dict[str, Any]:
    assert proc.stdout is not None
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    if not ready:
        raise AssertionError("等待插件运行时响应超时")
    line = proc.stdout.readline()
    if not line:
        stderr = proc.stderr.read() if proc.stderr else ""
        raise AssertionError(f"插件运行时提前退出：{stderr}")
    return json.loads(line)


def _call(
    proc: subprocess.Popen,
    payload: Dict[str, Any],
    timeout: float = 10.0,
) -> Dict[str, Any]:
    _send(proc, payload)
    return _readline(proc, timeout=timeout)


def _close(proc: subprocess.Popen) -> str:
    if proc.stdin is not None:
        try:
            proc.stdin.close()
        except (BrokenPipeError, ValueError):
            pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)
        raise
    stderr = proc.stderr.read() if proc.stderr else ""
    assert proc.returncode == 0, f"退出码 {proc.returncode}，stderr:\n{stderr}"
    return stderr


@pytest.fixture
def proc(tmp_path: Path):
    process = _spawn(tmp_path)
    yield process
    _close(process)


_ECHO_MANIFEST = {
    "id": "echo",
    "name": "Echo",
    "version": "1.0.0",
    "tools": [
        {
            "name": "echo",
            "type": "prompt",
            "description": "原样回显",
            "prompt": "echo: {text}",
        }
    ],
}


def test_ping_health_list_and_clean_exit(proc: subprocess.Popen) -> None:
    pong = _call(proc, {"id": 1, "action": "ping"})
    assert pong["id"] == 1
    assert pong["ok"] is True
    assert pong["pong"] is True

    health = _call(proc, {"id": 2, "action": "health"})
    assert health["ok"] is True
    assert health["status"] == "ok"
    assert health["plugins"] == 0
    assert health["max_concurrency"] >= 1
    assert health["protocol"] == "ndjson"

    listing = _call(proc, {"id": 3, "action": "list"})
    assert listing["ok"] is True
    assert listing["plugins"] == []


def test_register_and_invoke_prompt_tool(proc: subprocess.Popen) -> None:
    registered = _call(
        proc, {"id": "r1", "action": "register", "plugin": _ECHO_MANIFEST}
    )
    assert registered["ok"] is True
    assert registered["plugin"]["id"] == "echo"
    assert registered["plugin"]["tools"][0]["allowed"] is True

    listing = _call(proc, {"id": "r2", "action": "list"})
    assert [item["id"] for item in listing["plugins"]] == ["echo"]

    invoked = _call(
        proc,
        {
            "id": "r3",
            "action": "invoke",
            "plugin": "echo",
            "tool": "echo",
            "args": {"text": "你好"},
        },
    )
    assert invoked["ok"] is True
    assert invoked["output"] == "echo: 你好"

    duplicate = _call(
        proc, {"id": "r4", "action": "register", "plugin": _ECHO_MANIFEST}
    )
    assert duplicate["ok"] is False
    assert duplicate["code"] == "plugin_exists"

    unregistered = _call(
        proc, {"id": "r5", "action": "unregister", "plugin": "echo"}
    )
    assert unregistered["ok"] is True
    assert unregistered["removed"] == "echo"


def test_shell_tool_denied_by_default(proc: subprocess.Popen) -> None:
    manifest = {
        "id": "deny-shell",
        "tools": [
            {
                "name": "run",
                "type": "shell",
                "command": [sys.executable, "-c", "print('should-not-run')"],
            }
        ],
    }
    registered = _call(
        proc, {"id": 1, "action": "register", "plugin": manifest}
    )
    assert registered["ok"] is True
    assert registered["plugin"]["tools"][0]["allowed"] is False

    result = _call(
        proc,
        {
            "id": 2,
            "action": "invoke",
            "plugin": "deny-shell",
            "tool": "run",
            "args": {},
        },
    )
    assert result["ok"] is False
    assert result["code"] == "permission_denied"
    assert "shell" in result["error"].lower()


def test_shell_tool_runs_with_explicit_permission(proc: subprocess.Popen) -> None:
    manifest = {
        "id": "allow-shell",
        "permissions": {"shell": True},
        "tools": [
            {
                "name": "run",
                "type": "shell",
                "command": [sys.executable, "-c", "print('allowed-output')"],
            }
        ],
    }
    assert _call(
        proc, {"id": 1, "action": "register", "plugin": manifest}
    )["ok"] is True
    result = _call(
        proc,
        {"id": 2, "action": "invoke", "plugin": "allow-shell", "tool": "run"},
    )
    assert result["ok"] is True
    assert result["exit_code"] == 0
    assert "allowed-output" in result["output"]


def test_invoke_timeout_is_structured(proc: subprocess.Popen) -> None:
    manifest = {
        "id": "slow",
        "permissions": {"shell": True},
        "tools": [
            {
                "name": "sleep",
                "type": "shell",
                "command": [
                    sys.executable,
                    "-c",
                    "import time; time.sleep(5)",
                ],
            }
        ],
    }
    assert _call(
        proc, {"id": 1, "action": "register", "plugin": manifest}
    )["ok"] is True
    result = _call(
        proc,
        {
            "id": 2,
            "action": "invoke",
            "plugin": "slow",
            "tool": "sleep",
            "timeout_ms": 300,
        },
        timeout=10.0,
    )
    assert result["ok"] is False
    assert result["code"] == "timeout"


def test_concurrency_limit_returns_busy(tmp_path: Path) -> None:
    process = _spawn(tmp_path, "--max-concurrency", "1")
    try:
        manifest = {
            "id": "slow2",
            "permissions": {"shell": True},
            "tools": [
                {
                    "name": "sleep",
                    "type": "shell",
                    "command": [
                        sys.executable,
                        "-c",
                        "import time; time.sleep(1.5)",
                    ],
                }
            ],
        }
        assert _call(
            process, {"id": 1, "action": "register", "plugin": manifest}
        )["ok"] is True
        _send(
            process,
            {
                "id": "slow-job",
                "action": "invoke",
                "plugin": "slow2",
                "tool": "sleep",
                "timeout_ms": 5000,
            },
        )
        _send(
            process,
            {
                "id": "second-job",
                "action": "invoke",
                "plugin": "slow2",
                "tool": "sleep",
                "timeout_ms": 5000,
            },
        )
        responses = [_readline(process), _readline(process)]
        by_id = {str(item["id"]): item for item in responses}
        assert by_id["second-job"]["ok"] is False
        assert by_id["second-job"]["code"] == "busy"
        assert by_id["slow-job"]["ok"] is True
    finally:
        _close(process)


def test_invalid_json_does_not_crash(proc: subprocess.Popen) -> None:
    assert proc.stdin is not None
    proc.stdin.write("{not-json\n")
    proc.stdin.flush()
    error = _readline(proc)
    assert error["ok"] is False
    assert error["code"] == "invalid_json"

    assert proc.stdin is not None
    proc.stdin.write("[1, 2, 3]\n")
    proc.stdin.flush()
    invalid = _readline(proc)
    assert invalid["ok"] is False
    assert invalid["code"] == "invalid_request"

    pong = _call(proc, {"id": 9, "action": "ping"})
    assert pong["ok"] is True


def test_unknown_plugin_tool_and_action_are_structured(
    proc: subprocess.Popen,
) -> None:
    missing_plugin = _call(
        proc,
        {"id": 1, "action": "invoke", "plugin": "ghost", "tool": "x"},
    )
    assert missing_plugin["ok"] is False
    assert missing_plugin["code"] == "plugin_not_found"

    assert _call(
        proc, {"id": 2, "action": "register", "plugin": _ECHO_MANIFEST}
    )["ok"] is True
    missing_tool = _call(
        proc,
        {"id": 3, "action": "invoke", "plugin": "echo", "tool": "nope"},
    )
    assert missing_tool["ok"] is False
    assert missing_tool["code"] == "tool_not_found"

    unknown = _call(proc, {"id": 4, "action": "explode"})
    assert unknown["ok"] is False
    assert unknown["code"] == "unknown_action"


def test_audit_events_are_appended(tmp_path: Path) -> None:
    audit_path = tmp_path / "audit.jsonl"
    process = _spawn(tmp_path, "--audit", str(audit_path))
    try:
        assert _call(
            process,
            {"id": 1, "action": "register", "plugin": _ECHO_MANIFEST},
        )["ok"] is True
        assert _call(
            process,
            {
                "id": 2,
                "action": "invoke",
                "plugin": "echo",
                "tool": "echo",
                "args": {"text": "audit"},
            },
        )["ok"] is True
        health = _call(process, {"id": 3, "action": "health"})
        assert health["audit_events"] >= 2
    finally:
        _close(process)

    events = [
        json.loads(line)
        for line in audit_path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    names = [event["event"] for event in events]
    assert "register" in names
    assert "invoke" in names
