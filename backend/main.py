#!/usr/bin/env python3
"""Tangram 本地后端真实入口。

此前 ``scripts/run_headless.sh`` 与 ``scripts/build_backend.sh`` 都指向这个
不存在的文件，「无头对话 / 后端构建」是空壳。现在提供：

* ``--chat``            真实交互式对话 REPL（确定性能力 + 本地/云端模型）。
* ``--bridge tcp``      真实 TCP JSON 行协议，供宿主进程/调试桥接调用。
* ``--bridge stdio``    同一协议走 stdin/stdout（便于管道集成）。
* ``--status``          打印真实运行时状态（数据源 / 记忆 / 后端）。

协议（一行一个 JSON 对象，请求与响应都以换行结尾）::

    {"id": 1, "method": "chat", "params": {"text": "1+1 等于几"}}
    {"id": 1, "ok": true, "result": {"text": "..."}}

方法：chat / status / memory / tool / reset。错误如实回 ``ok:false`` +
真实错误信息，绝不返回假成功。
"""

from __future__ import annotations

import argparse
import json
import os
import socketserver
import sys
import threading
import traceback
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
_REPO_ROOT = _HERE.parent
for _p in (str(_HERE), str(_REPO_ROOT)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from app.runtime.agent_service import RuntimeService  # noqa: E402


def _build_service(args: argparse.Namespace) -> RuntimeService:
    return RuntimeService(
        data_dir=args.data,
        local_model=args.model,
        api_base=args.api_base,
        api_key=args.api_key,
        api_model=args.api_model,
    )


def handle_request(svc: RuntimeService, raw: str) -> dict:
    """处理一条真实请求，返回结构化响应。"""
    try:
        req = json.loads(raw)
    except ValueError:
        return {"id": None, "ok": False, "error": "bad-json: 请求不是合法 JSON"}
    if not isinstance(req, dict):
        return {"id": None, "ok": False, "error": "bad-request: 需要 JSON 对象"}
    rid = req.get("id")
    method = str(req.get("method") or "")
    params = req.get("params") if isinstance(req.get("params"), dict) else {}
    try:
        if method == "chat":
            text = str(params.get("text") or "")
            if not text.strip():
                return {"id": rid, "ok": False, "error": "text 为空"}
            session = str(params.get("session_id") or "default")
            answer = svc.chat(text, session_id=session)
            return {"id": rid, "ok": True, "result": {"text": answer, "session_id": session}}
        if method == "status":
            return {"id": rid, "ok": True, "result": svc.status()}
        if method == "memory":
            query = str(params.get("query") or "")
            return {"id": rid, "ok": True, "result": {
                "recent": [
                    {"role": e.role, "text": e.text, "ts": e.ts}
                    for e in svc.memory.recent(str(params.get("session_id") or "default"), k=10)
                ],
                "nearest": [
                    {"role": e.role, "text": e.text, "score": round(s, 6)}
                    for e, s in svc.memory.nearest_neighbors(query, k=4)
                ] if query else [],
                "core": [{"id": cid, "text": t} for cid, t in svc.memory.list_core()],
            }}
        if method == "tool":
            name = str(params.get("name") or "")
            result = svc.exec_tool(name, params.get("args") or {})
            return {"id": rid, "ok": True, "result": {"text": result}}
        if method == "reset":
            svc.memory.clear()
            return {"id": rid, "ok": True, "result": {"cleared": True,
                                                     "note": "已真实删除本数据目录下的对话轮次与核心记忆"}}
        return {"id": rid, "ok": False, "error": f"unknown-method:{method}"}
    except Exception as exc:  # noqa: BLE001 - 如实回传错误，不吞
        return {"id": rid, "ok": False,
                "error": f"{type(exc).__name__}: {exc}"}


def _serve_stdio(svc: RuntimeService) -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        resp = handle_request(svc, line)
        print(json.dumps(resp, ensure_ascii=False), flush=True)
    return 0


class _TCPHandler(socketserver.StreamRequestHandler):
    def handle(self) -> None:
        svc: RuntimeService = self.server.svc  # type: ignore[attr-defined]
        for raw in self.rfile:
            try:
                line = raw.decode("utf-8", "replace").strip()
            except Exception:
                continue
            if not line:
                continue
            resp = handle_request(svc, line)
            self.wfile.write((json.dumps(resp, ensure_ascii=False) + "\n").encode("utf-8"))
            self.wfile.flush()


class _ThreadedTCPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def _serve_tcp(svc: RuntimeService, host: str, port: int) -> int:
    server = _ThreadedTCPServer((host, port), _TCPHandler)
    server.svc = svc  # type: ignore[attr-defined]
    actual = server.server_address[1]
    print(f"[tangram] TCP 桥已就绪：{host}:{actual}（数据目录 {svc.data_dir}）", flush=True)
    try:
        server.serve_forever(poll_interval=0.3)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


def _serve_chat(svc: RuntimeService, host: str, port: int) -> int:
    """交互式 REPL；可选同时起 TCP 桥（run_headless.sh 的 --bridge-port）。"""
    bridge: threading.Thread | None = None
    if port:
        bridge = threading.Thread(target=_serve_tcp, args=(svc, host, port), daemon=True)
        bridge.start()

    print("Tangram 无头对话（输入 /status 看状态，/memory 看记忆，/quit 退出）", flush=True)
    print(f"运行时：{json.dumps(svc.status(), ensure_ascii=False)}", flush=True)
    while True:
        try:
            text = input("你> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not text:
            continue
        if text in ("/quit", "/exit", "quit", "exit"):
            break
        if text == "/status":
            print(json.dumps(svc.status(), ensure_ascii=False, indent=2), flush=True)
            continue
        if text == "/memory":
            print(json.dumps(handle_request(svc, json.dumps(
                {"id": 0, "method": "memory", "params": {}}))["result"],
                ensure_ascii=False, indent=2), flush=True)
            continue
        try:
            answer = svc.chat(text)
            print(f"TGA> {answer}", flush=True)
        except Exception as exc:  # noqa: BLE001 - 如实打印错误
            print(f"TGA> [错误] {type(exc).__name__}: {exc}", flush=True)
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="tangram-backend",
        description="Tangram 本地 Agent 运行时（真实推理 / 记忆 / 工具）",
    )
    p.add_argument("--chat", action="store_true", help="交互式无头对话 REPL")
    p.add_argument("--bridge", choices=["tcp", "stdio"], default="",
                   help="JSON 行协议桥接模式")
    p.add_argument("--status", action="store_true", help="打印运行时状态后退出")
    p.add_argument("--data", default=os.environ.get("TANGRAM_DATA", ""),
                   help="数据目录（默认 ~/.tangram）")
    p.add_argument("--host", default="127.0.0.1", help="TCP 桥监听地址")
    p.add_argument("--port", type=int, default=0, help="TCP 桥端口（0=系统分配）")
    p.add_argument("--bridge-port", type=int, default=0,
                   help="--chat 时同时起 TCP 桥的端口（run_headless.sh 使用）")
    p.add_argument("--model", default=os.environ.get("TANGRAM_MODEL", ""),
                   help="本地 GGUF/HF 权重路径")
    p.add_argument("--api-base", default=os.environ.get("TANGRAM_API_BASE", ""))
    p.add_argument("--api-key", default=os.environ.get("TANGRAM_API_KEY", ""))
    p.add_argument("--api-model", default=os.environ.get("TANGRAM_API_MODEL", ""))
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    svc = _build_service(args)
    if args.status:
        print(json.dumps(svc.status(), ensure_ascii=False, indent=2))
        return 0
    if args.bridge == "stdio":
        return _serve_stdio(svc)
    if args.bridge == "tcp":
        return _serve_tcp(svc, args.host, args.port)
    return _serve_chat(svc, args.host, args.bridge_port or args.port)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:  # noqa: BLE001 - 顶层兜底，打印真实堆栈
        traceback.print_exc()
        raise SystemExit(1)
