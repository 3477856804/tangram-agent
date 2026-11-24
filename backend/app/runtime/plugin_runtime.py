"""Python 插件运行时：NDJSON stdin/stdout 事件循环（真实生命周期，无 eval）。

协议
----
每行输入一个 JSON 对象：``{"id": <任意>, "action": "...", ...}``；
每行输出一个 JSON 对象：``{"id": <同一个>, "ok": true/false, ...}``。
stdin 关闭即退出（返回码 0）。非法 JSON 只回结构化错误，不崩溃、不退出。

支持动作
--------
* ``ping`` / ``health``：存活与运行状态。
* ``register``：注册插件（manifest 见下）。
* ``unregister`` / ``list``：卸载 / 列出插件与工具。
* ``invoke``：调用插件工具，支持 ``timeout_ms``；并发超过上限返回 ``busy``。
* ``shutdown``：回包后退出。

manifest 形态::

    {
      "id": "echo",
      "name": "Echo",
      "version": "1.0.0",
      "permissions": {
        "shell": false,                 # 默认拒绝 shell，必须显式 true
        "http_hosts": ["example.com"],  # http 工具必须声明允许的主机
        "allow_dynamic_argv": false     # 默认只允许 manifest 固定 command
      },
      "tools": [
        {"name": "echo", "type": "prompt", "prompt": "echo: {text}"},
        {"name": "fetch", "type": "http", "url": "https://example.com"},
        {"name": "run", "type": "shell", "command": ["/bin/echo", "hi"]}
      ]
    }

安全红线：不 ``eval`` / ``exec`` / ``pickle``，不执行压缩包；shell 工具默认
拒绝，放行后也用 ``shell=False`` + 最小环境 + 超时；HTTP 工具只允许 manifest
显式声明的主机，并拒绝私网/回环地址。

审计：所有注册、卸载、调用、拒绝、超时都追加审计事件；``--audit PATH``
时逐行写入 JSONL 文件，内存中也保留最近事件供 ``health`` 查询。
"""

from __future__ import annotations

import argparse
import concurrent.futures
import ipaddress
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

__all__ = ["PluginRuntime", "ToolError", "main"]

_ALLOWED_TOOL_TYPES = ("prompt", "http", "shell")
_ID_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")

# 插件分级（T0 内核 / T1 官方 / T2 用户自建 / T3 第三方）
_TIERS = ("T0", "T1", "T2", "T3")
_TIER_ALIASES = {
    "system": "T0",
    "official": "T1",
    "user": "T2",
    "third_party": "T3",
    "thirdparty": "T3",
}
_MAX_OUTPUT = 4000
_MAX_AUDIT_EVENTS = 5000
_ACTIONS = (
    "ping",
    "health",
    "register",
    "unregister",
    "list",
    "invoke",
    "shutdown",
)


class ToolError(Exception):
    """带稳定错误码的结构化插件错误。"""

    def __init__(
        self, code: str, message: str, details: Optional[Any] = None
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _stringify(value: Any) -> str:
    if isinstance(value, str):
        return value
    if value is None:
        return ""
    try:
        return json.dumps(value, ensure_ascii=False)
    except (TypeError, ValueError):
        return str(value)


def _safe_env() -> Dict[str, str]:
    """shell 工具的最小环境，不继承 API Key / Token 等敏感变量。"""
    return {
        "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", "/tmp"),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
    }


def _positive_float(value: Any, default: float) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return default
    return max(0.1, min(300.0, parsed))


def def _normalize_tier(raw: Any) -> str:
    """解析插件分级；未知值兜底 T1（官方），不静默升为 T0。"""
    if isinstance(raw, str):
        s = raw.strip()
        if s.upper() in _TIERS:
            return s.upper()
        low = s.lower()
        if low in _TIER_ALIASES:
            return _TIER_ALIASES[low]
    return "T1"


def _normalize_manifest(raw: Any) -> Dict[str, Any]:
    if not isinstance(raw, dict):
        raise ToolError("invalid_manifest", "plugin manifest 必须是 JSON 对象")
    plugin_id = str(raw.get("id") or raw.get("name") or "").strip()
    if not _ID_RE.fullmatch(plugin_id):
        raise ToolError(
            "invalid_manifest",
            "plugin id 必须匹配 [A-Za-z0-9_.-]{1,64}",
        )

    permissions_raw = raw.get("permissions")
    if permissions_raw is None:
        permissions_raw = {}
    if not isinstance(permissions_raw, dict):
        raise ToolError("invalid_manifest", "permissions 必须是对象")

    shell_allowed = (
        permissions_raw.get("shell") is True or raw.get("allow_shell") is True
    )
    hosts_raw = permissions_raw.get("http_hosts")
    if isinstance(hosts_raw, str):
        http_hosts = [hosts_raw.strip().lower()] if hosts_raw.strip() else []
    elif isinstance(hosts_raw, list):
        http_hosts = [
            str(host).strip().lower()
            for host in hosts_raw
            if str(host).strip()
        ]
    elif hosts_raw is None:
        http_hosts = []
    else:
        raise ToolError("invalid_manifest", "permissions.http_hosts 必须是字符串或数组")

    permissions = {
        "shell": shell_allowed,
        "http_hosts": http_hosts,
        "allow_dynamic_argv": permissions_raw.get("allow_dynamic_argv") is True,
    }

    caps_raw = raw.get("caps")
    if caps_raw is None:
        caps_raw = []
    if not isinstance(caps_raw, list) or not all(
        isinstance(item, str) and item.strip() for item in caps_raw
    ):
        raise ToolError("invalid_manifest", "caps 必须是字符串数组")
    caps = sorted({item.strip() for item in caps_raw})
    tier = _normalize_tier(raw.get("tier"))
    if tier == "T3" and not caps:
        raise ToolError(
            "invalid_manifest",
            "T3 第三方插件必须显式声明 caps（fail-closed：未声明能力即拒绝加载）",
        )

    tools_raw = raw.get("tools")
    if tools_raw is None:
        tools_raw = []
    if not isinstance(tools_raw, list):
        raise ToolError("invalid_manifest", "tools 必须是数组")

    tools: Dict[str, Dict[str, Any]] = {}
    for item in tools_raw:
        if not isinstance(item, dict):
            raise ToolError("invalid_manifest", "每个 tool 必须是对象")
        name = str(item.get("name") or "").strip()
        if not _ID_RE.fullmatch(name):
            raise ToolError(
                "invalid_manifest",
                f"tool name 非法：{name!r}（需匹配 [A-Za-z0-9_.-]{{1,64}}）",
            )
        if name in tools:
            raise ToolError("invalid_manifest", f"tool 重名：{name}")
        tool_type = str(item.get("type") or "").strip().lower()
        if tool_type not in _ALLOWED_TOOL_TYPES:
            raise ToolError(
                "invalid_manifest",
                f"tool {name} 类型非法：{tool_type!r}（prompt/http/shell）",
            )
        tool: Dict[str, Any] = {
            "name": name,
            "type": tool_type,
            "description": str(item.get("description") or ""),
            "allowed": True,
        }
        if tool_type == "prompt":
            template = item.get("prompt", item.get("template"))
            if not isinstance(template, str) or not template.strip():
                raise ToolError(
                    "invalid_manifest", f"prompt 工具 {name} 缺少非空 prompt 模板"
                )
            tool["template"] = template
        elif tool_type == "http":
            url = str(item.get("url") or "").strip()
            parsed = urllib.parse.urlsplit(url)
            if parsed.scheme not in ("http", "https") or not parsed.hostname:
                raise ToolError(
                    "invalid_manifest",
                    f"http 工具 {name} 的 url 必须是 http(s) 且带主机名",
                )
            headers = item.get("headers") or {}
            if not isinstance(headers, dict):
                raise ToolError(
                    "invalid_manifest", f"http 工具 {name} 的 headers 必须是对象"
                )
            tool["url"] = url
            tool["method"] = str(item.get("method") or "GET").upper()
            tool["headers"] = {
                str(key): str(value) for key, value in headers.items()
            }
            tool["timeout_s"] = _positive_float(item.get("timeout_s"), 10.0)
        else:
            command = item.get("command")
            if command is not None:
                if (
                    not isinstance(command, list)
                    or not command
                    or not all(isinstance(part, str) for part in command)
                ):
                    raise ToolError(
                        "invalid_manifest",
                        f"shell 工具 {name} 的 command 必须是非空字符串数组",
                    )
                tool["command"] = list(command)
            else:
                tool["command"] = []
            tool["timeout_s"] = _positive_float(item.get("timeout_s"), 10.0)
            if not shell_allowed:
                tool["allowed"] = False
                tool["denied_reason"] = (
                    "shell 工具默认被拒绝；需 manifest permissions.shell=true 显式放行"
                )
        tools[name] = tool

    return {
        "id": plugin_id,
        "name": str(raw.get("name") or plugin_id),
        "version": str(raw.get("version") or "0.0.0"),
        "permissions": permissions,
        "tools": tools,
        "tier": tier,
        "caps": caps,
        "registered_at": _now(),
    }


def _describe_plugin(plugin: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": plugin["id"],
        "name": plugin["name"],
        "version": plugin["version"],
        "tier": plugin.get("tier", "T1"),
        "caps": list(plugin.get("caps", [])),
        "registered_at": plugin["registered_at"],
        "permissions": {
            "shell": plugin["permissions"]["shell"],
            "http_hosts": list(plugin["permissions"]["http_hosts"]),
            "allow_dynamic_argv": plugin["permissions"]["allow_dynamic_argv"],
        },
        "tools": [
            {
                "name": tool["name"],
                "type": tool["type"],
                "description": tool["description"],
                "allowed": tool["allowed"],
            }
            for tool in plugin["tools"].values()
        ],
    }


class PluginRuntime:
    """插件注册表 + 有并发上限的 NDJSON 事件循环。"""

    def __init__(
        self,
        *,
        max_concurrency: int = 4,
        audit_path: Optional[str] = None,
        default_timeout_ms: int = 5000,
    ) -> None:
        self.max_concurrency = max(1, int(max_concurrency))
        self.default_timeout_ms = max(1, int(default_timeout_ms))
        self.audit_path = audit_path or ""
        self._plugins: Dict[str, Dict[str, Any]] = {}
        self._plugins_lock = threading.Lock()
        self._audit_events: List[Dict[str, Any]] = []
        self._audit_lock = threading.Lock()
        self._out_lock = threading.Lock()
        self._slots = threading.BoundedSemaphore(self.max_concurrency)
        self._inflight = 0
        self._inflight_lock = threading.Lock()
        self._started = time.monotonic()
        self._pool = concurrent.futures.ThreadPoolExecutor(
            max_workers=self.max_concurrency,
            thread_name_prefix="plugin-rt",
        )

    # ---- 输出 / 审计 ----
    @staticmethod
    def _write(stdout: Any, payload: Dict[str, Any]) -> None:
        line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
        stdout.write(line + "\n")
        stdout.flush()

    def _emit(self, stdout: Any, payload: Dict[str, Any]) -> None:
        with self._out_lock:
            try:
                self._write(stdout, payload)
            except (BrokenPipeError, ValueError, OSError):
                # 对端已关闭：不再写，也不影响主循环收尾。
                pass

    def _audit(self, event: str, **fields: Any) -> None:
        record = {"event": event, "ts": _now(), **fields}
        with self._audit_lock:
            self._audit_events.append(record)
            if len(self._audit_events) > _MAX_AUDIT_EVENTS:
                del self._audit_events[: len(self._audit_events) - _MAX_AUDIT_EVENTS]
            path = self.audit_path
            if path:
                try:
                    with open(path, "a", encoding="utf-8") as handle:
                        handle.write(
                            json.dumps(record, ensure_ascii=False) + "\n"
                        )
                except OSError as exc:
                    print(
                        f"[plugin_runtime] audit 写入失败：{exc}",
                        file=sys.stderr,
                        flush=True,
                    )

    def _inc_inflight(self, delta: int) -> None:
        with self._inflight_lock:
            self._inflight += delta

    # ---- 生命周期 ----
    def serve(self, stdin: Any = None, stdout: Any = None) -> int:
        stdin = stdin or sys.stdin
        stdout = stdout or sys.stdout
        for raw_line in stdin:
            line = raw_line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except json.JSONDecodeError as exc:
                self._emit(
                    stdout,
                    {
                        "id": None,
                        "ok": False,
                        "error": f"非法 JSON：{exc.msg}（line {exc.lineno} "
                        f"col {exc.colno}）",
                        "code": "invalid_json",
                    },
                )
                self._audit("protocol_error", code="invalid_json")
                continue
            if not isinstance(request, dict):
                self._emit(
                    stdout,
                    {
                        "id": None,
                        "ok": False,
                        "error": "每行输入必须是 JSON 对象",
                        "code": "invalid_request",
                    },
                )
                self._audit("protocol_error", code="invalid_request")
                continue

            action = str(request.get("action") or "").strip().lower()
            request_id = request.get("id")
            if action == "shutdown":
                self._emit(
                    stdout, {"id": request_id, "ok": True, "action": "shutdown"}
                )
                self._audit("shutdown")
                break
            if action == "invoke":
                self._start_invoke(request, stdout)
                continue
            try:
                response = self._handle_sync(action, request)
            except ToolError as exc:
                response = {
                    "id": request_id,
                    "ok": False,
                    "error": exc.message,
                    "code": exc.code,
                }
                if exc.details is not None:
                    response["details"] = exc.details
            except Exception as exc:  # noqa: BLE001 - 不因单个请求崩掉常驻循环
                response = {
                    "id": request_id,
                    "ok": False,
                    "error": f"运行时异常：{type(exc).__name__}: {exc}",
                    "code": "runtime_error",
                }
            self._emit(stdout, response)

        self.shutdown()
        return 0

    def shutdown(self) -> None:
        # stdin 关闭后先让已接收的 invoke 跑完（每个 invoke 自身有超时上限），
        # 避免父进程已经拿到请求却收不到响应的半途状态。
        self._pool.shutdown(wait=True)

    # ---- 同步动作 ----
    def _handle_sync(
        self, action: str, request: Dict[str, Any]
    ) -> Dict[str, Any]:
        request_id = request.get("id")
        if action == "ping":
            return {
                "id": request_id,
                "ok": True,
                "pong": True,
                "time": _now(),
                "uptime_s": round(time.monotonic() - self._started, 3),
            }
        if action == "health":
            with self._plugins_lock:
                plugin_ids = list(self._plugins.keys())
            with self._inflight_lock:
                inflight = self._inflight
            with self._audit_lock:
                audit_count = len(self._audit_events)
            return {
                "id": request_id,
                "ok": True,
                "status": "ok",
                "pid": os.getpid(),
                "uptime_s": round(time.monotonic() - self._started, 3),
                "plugins": len(plugin_ids),
                "plugin_ids": plugin_ids,
                "inflight": inflight,
                "max_concurrency": self.max_concurrency,
                "audit_events": audit_count,
                "protocol": "ndjson",
                "actions": list(_ACTIONS),
            }
        if action == "list":
            with self._plugins_lock:
                plugins = [
                    _describe_plugin(plugin)
                    for plugin in self._plugins.values()
                ]
            return {"id": request_id, "ok": True, "plugins": plugins}
        if action == "register":
            raw = request.get("plugin")
            if raw is None:
                raw = request.get("manifest")
            plugin = _normalize_manifest(raw)
            with self._plugins_lock:
                if plugin["id"] in self._plugins:
                    raise ToolError(
                        "plugin_exists", f"插件 {plugin['id']} 已注册"
                    )
                self._plugins[plugin["id"]] = plugin
            self._audit(
                "register",
                plugin=plugin["id"],
                tools=[tool["name"] for tool in plugin["tools"].values()],
                shell_allowed=plugin["permissions"]["shell"],
            )
            return {
                "id": request_id,
                "ok": True,
                "plugin": _describe_plugin(plugin),
            }
        if action == "unregister":
            plugin_id = str(request.get("plugin") or "").strip()
            with self._plugins_lock:
                removed = self._plugins.pop(plugin_id, None)
            if removed is None:
                raise ToolError(
                    "plugin_not_found", f"插件 {plugin_id} 未注册"
                )
            self._audit("unregister", plugin=plugin_id)
            return {"id": request_id, "ok": True, "removed": plugin_id}
        if action == "actions":
            return {"id": request_id, "ok": True, "actions": list(_ACTIONS)}
        raise ToolError(
            "unknown_action",
            f"未知动作：{action or '(空)'}",
            {"actions": list(_ACTIONS)},
        )

    # ---- 异步 invoke ----
    def _start_invoke(self, request: Dict[str, Any], stdout: Any) -> None:
        request_id = request.get("id")
        plugin_id = str(request.get("plugin") or "").strip()
        tool_name = str(request.get("tool") or "").strip()
        args = request.get("args")
        if not isinstance(args, dict):
            args = {}
        timeout_s = self._timeout_seconds(request.get("timeout_ms"))
        if not self._slots.acquire(blocking=False):
            self._emit(
                stdout,
                {
                    "id": request_id,
                    "ok": False,
                    "error": f"并发已达上限（{self.max_concurrency}），请稍后重试",
                    "code": "busy",
                },
            )
            self._audit(
                "invoke_rejected",
                plugin=plugin_id,
                tool=tool_name,
                reason="busy",
            )
            return
        self._inc_inflight(1)
        future = self._pool.submit(
            self._invoke_job,
            request_id,
            plugin_id,
            tool_name,
            args,
            timeout_s,
            stdout,
        )
        future.add_done_callback(lambda _future: self._invoke_finished())

    def _invoke_finished(self) -> None:
        self._inc_inflight(-1)
        self._slots.release()

    def _timeout_seconds(self, raw: Any) -> float:
        if raw is None:
            return self.default_timeout_ms / 1000.0
        try:
            value = float(raw) / 1000.0
        except (TypeError, ValueError):
            return self.default_timeout_ms / 1000.0
        return max(0.05, min(120.0, value))

    def _invoke_job(
        self,
        request_id: Any,
        plugin_id: str,
        tool_name: str,
        args: Dict[str, Any],
        timeout_s: float,
        stdout: Any,
    ) -> None:
        started = time.monotonic()
        try:
            with self._plugins_lock:
                plugin = self._plugins.get(plugin_id)
            if plugin is None:
                raise ToolError(
                    "plugin_not_found", f"插件 {plugin_id} 未注册"
                )
            tool = plugin["tools"].get(tool_name)
            if tool is None:
                raise ToolError(
                    "tool_not_found",
                    f"插件 {plugin_id} 没有工具 {tool_name}",
                )
            if not tool["allowed"]:
                raise ToolError(
                    "permission_denied",
                    tool.get("denied_reason")
                    or f"工具 {tool_name} 未获 manifest 授权",
                )
            result = self._call_with_timeout(plugin, tool, args, timeout_s)
            duration_ms = round((time.monotonic() - started) * 1000, 2)
            response: Dict[str, Any] = {
                "id": request_id,
                "ok": True,
                "plugin": plugin_id,
                "tool": tool_name,
            }
            response.update(result)
            self._audit(
                "invoke",
                plugin=plugin_id,
                tool=tool_name,
                ok=True,
                duration_ms=duration_ms,
            )
        except ToolError as exc:
            duration_ms = round((time.monotonic() - started) * 1000, 2)
            response = {
                "id": request_id,
                "ok": False,
                "error": exc.message,
                "code": exc.code,
            }
            if exc.details is not None:
                response["details"] = exc.details
            self._audit(
                "invoke",
                plugin=plugin_id,
                tool=tool_name,
                ok=False,
                code=exc.code,
                duration_ms=duration_ms,
            )
        except Exception as exc:  # noqa: BLE001 - 结构化返回，不崩守护进程
            duration_ms = round((time.monotonic() - started) * 1000, 2)
            response = {
                "id": request_id,
                "ok": False,
                "error": f"插件执行异常：{type(exc).__name__}: {exc}",
                "code": "execution_error",
            }
            self._audit(
                "invoke",
                plugin=plugin_id,
                tool=tool_name,
                ok=False,
                code="execution_error",
                duration_ms=duration_ms,
            )
        self._emit(stdout, response)

    def _call_with_timeout(
        self,
        plugin: Dict[str, Any],
        tool: Dict[str, Any],
        args: Dict[str, Any],
        timeout_s: float,
    ) -> Dict[str, Any]:
        box: Dict[str, Any] = {}

        def target() -> None:
            try:
                box["value"] = self._execute(plugin, tool, args, timeout_s)
            except BaseException as exc:  # noqa: BLE001 - 回传主线程统一结构化
                box["error"] = exc

        worker = threading.Thread(
            target=target, name="plugin-tool", daemon=True
        )
        worker.start()
        worker.join(timeout=timeout_s)
        if worker.is_alive():
            raise ToolError(
                "timeout", f"插件工具执行超时（>{timeout_s:.2f}s）"
            )
        if "error" in box:
            exc = box["error"]
            if isinstance(exc, ToolError):
                raise exc
            if isinstance(exc, subprocess.TimeoutExpired):
                raise ToolError(
                    "timeout", f"插件工具执行超时（>{timeout_s:.2f}s）"
                )
            raise exc
        value = box.get("value")
        return value if isinstance(value, dict) else {}

    # ---- 工具执行 ----
    def _execute(
        self,
        plugin: Dict[str, Any],
        tool: Dict[str, Any],
        args: Dict[str, Any],
        timeout_s: float,
    ) -> Dict[str, Any]:
        tool_type = tool["type"]
        if tool_type == "prompt":
            return self._execute_prompt(plugin, tool, args)
        if tool_type == "http":
            return self._execute_http(plugin, tool, args, timeout_s)
        if tool_type == "shell":
            return self._execute_shell(plugin, tool, args, timeout_s)
        raise ToolError(
            "invalid_tool_type", f"未知工具类型：{tool_type}"
        )

    @staticmethod
    def _execute_prompt(
        plugin: Dict[str, Any],
        tool: Dict[str, Any],
        args: Dict[str, Any],
    ) -> Dict[str, Any]:
        template = tool["template"]
        output = template
        values = {
            "text": _stringify(args.get("text", args.get("input", ""))),
            "input": _stringify(args.get("input", "")),
            "query": _stringify(args.get("query", "")),
            "plugin": plugin["id"],
            "tool": tool["name"],
            "args": _stringify(args),
        }
        for key, value in values.items():
            output = output.replace("{" + key + "}", value)
        return {"output": output, "type": "prompt"}

    @staticmethod
    def _execute_http(
        plugin: Dict[str, Any],
        tool: Dict[str, Any],
        args: Dict[str, Any],
        timeout_s: float,
    ) -> Dict[str, Any]:
        url = tool["url"]
        parsed = urllib.parse.urlsplit(url)
        host = (parsed.hostname or "").lower()
        if parsed.scheme not in ("http", "https") or not host:
            raise ToolError("invalid_url", f"http 工具 URL 非法：{url}")
        allowed_hosts = plugin["permissions"]["http_hosts"]
        if host not in allowed_hosts:
            raise ToolError(
                "permission_denied",
                f"HTTP 主机 {host} 未在 manifest permissions.http_hosts 中允许",
                {"allowed_hosts": allowed_hosts},
            )
        try:
            literal_ip = ipaddress.ip_address(host)
        except ValueError:
            literal_ip = None
        if literal_ip is not None and (
            literal_ip.is_private
            or literal_ip.is_loopback
            or literal_ip.is_link_local
            or literal_ip.is_reserved
        ):
            raise ToolError(
                "permission_denied", f"拒绝访问私网/回环地址：{host}"
            )

        method = tool.get("method") or "GET"
        headers = dict(tool.get("headers") or {})
        data: Optional[bytes] = None
        if method in ("POST", "PUT", "PATCH"):
            payload = args.get("body")
            if payload is None:
                payload = {"text": args.get("text", "")}
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            headers.setdefault("Content-Type", "application/json")
        params = args.get("params")
        if isinstance(params, dict) and params:
            separator = "&" if parsed.query else "?"
            url = url + separator + urllib.parse.urlencode(
                {str(key): str(value) for key, value in params.items()}
            )

        request = urllib.request.Request(
            url, data=data, headers=headers, method=method
        )
        request_timeout = min(
            timeout_s, float(tool.get("timeout_s") or timeout_s)
        )
        try:
            with urllib.request.urlopen(  # noqa: S310 - 主机已按 manifest 白名单校验
                request, timeout=max(0.1, request_timeout)
            ) as response:
                raw = response.read(8192)
                charset = response.headers.get_content_charset() or "utf-8"
                text = raw.decode(charset, errors="replace")
                return {
                    "output": text[:_MAX_OUTPUT],
                    "status": response.status,
                    "type": "http",
                }
        except urllib.error.HTTPError as exc:
            raise ToolError(
                "http_error", f"HTTP {exc.code}: {exc.reason}"
            ) from exc
        except urllib.error.URLError as exc:
            raise ToolError(
                "network_error", f"HTTP 请求失败：{exc.reason}"
            ) from exc
        except TimeoutError as exc:
            raise ToolError(
                "timeout", f"HTTP 请求超时（>{request_timeout:.2f}s）"
            ) from exc

    @staticmethod
    def _execute_shell(
        plugin: Dict[str, Any],
        tool: Dict[str, Any],
        args: Dict[str, Any],
        timeout_s: float,
    ) -> Dict[str, Any]:
        if not plugin["permissions"]["shell"]:
            raise ToolError(
                "permission_denied",
                "shell 工具默认被拒绝；需 manifest permissions.shell=true 显式放行",
            )
        argv_raw = args.get("argv")
        if argv_raw is not None:
            if not plugin["permissions"]["allow_dynamic_argv"]:
                raise ToolError(
                    "permission_denied",
                    "manifest 未允许动态 argv；只能执行固定 command",
                )
            if (
                not isinstance(argv_raw, list)
                or not argv_raw
                or not all(isinstance(part, str) for part in argv_raw)
            ):
                raise ToolError(
                    "invalid_args", "argv 必须是非空字符串数组"
                )
            command = list(argv_raw)
        else:
            command = list(tool.get("command") or [])
        if not command:
            raise ToolError(
                "invalid_args", f"shell 工具 {tool['name']} 没有可执行 command"
            )
        run_timeout = min(
            timeout_s, float(tool.get("timeout_s") or timeout_s)
        )
        try:
            completed = subprocess.run(  # noqa: S603 - shell=False + 显式 argv
                command,
                capture_output=True,
                text=True,
                timeout=max(0.1, run_timeout),
                shell=False,
                env=_safe_env(),
            )
        except subprocess.TimeoutExpired as exc:
            raise ToolError(
                "timeout", f"shell 工具执行超时（>{run_timeout:.2f}s）"
            ) from exc
        except OSError as exc:
            raise ToolError(
                "execution_error", f"shell 启动失败：{exc}"
            ) from exc
        return {
            "output": (completed.stdout or "")[:_MAX_OUTPUT],
            "stderr": (completed.stderr or "")[:_MAX_OUTPUT],
            "exit_code": completed.returncode,
            "type": "shell",
        }


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Tangram Python 插件运行时（NDJSON stdin/stdout）"
    )
    parser.add_argument(
        "--audit",
        default=os.environ.get("TANGRAM_PLUGIN_AUDIT", ""),
        help="审计事件 JSONL 追加文件（默认仅内存保留）",
    )
    parser.add_argument(
        "--max-concurrency",
        type=int,
        default=int(os.environ.get("TANGRAM_PLUGIN_CONCURRENCY", "4")),
        help="并发 invoke 上限（默认 4）",
    )
    parser.add_argument(
        "--timeout-ms",
        type=int,
        default=int(os.environ.get("TANGRAM_PLUGIN_TIMEOUT_MS", "5000")),
        help="invoke 默认超时毫秒（默认 5000）",
    )
    args = parser.parse_args(argv)
    runtime = PluginRuntime(
        max_concurrency=args.max_concurrency,
        audit_path=args.audit or None,
        default_timeout_ms=args.timeout_ms,
    )
    return runtime.serve()


if __name__ == "__main__":
    sys.exit(main())
