"""AGP WebSocket 桥：让 TGA 手机 APP 用端侧小模型处理微信/QQ 消息。

协议与 `frontend/lib/harness/agp_protocol.dart` / `im_gateway.dart` 一一对应：

    网关 -> APP   {"msg_id", "method":"session.prompt",
                   "payload":{"session_id","prompt_id","agent_app",
                              "content":[{"type":"text","text":...}]}}
    APP  -> 网关  session.update(message_chunk) / session.promptResponse /
                  ping

设计（纯标准库 + 纯线程，不引入 asyncio，直接复用 im/serve.py 的
ThreadingHTTPServer）：
  * `im/serve.py` 的 webhook 收到微信/QQ 消息时调用 `AgpHub.prompt()`，
    该方法把消息转成 session.prompt 推给已连接的 APP，并等待
    session.promptResponse；拿到回复后由 webhook 原样发回 IM。
  * APP 不在线 / 超时 / 报错时 `prompt()` 返回 None，webhook 回落网关
    本地 Agent，绝不编造回复。
  * 登录成功后 `issue_credentials()` 签发真实 guid/token/ws_url，
    WebSocket 握手时由 `verify_token()` 校验。

二维码本身不在这里生成 —— 由 `im/adapters/wechat_ilink.py`（腾讯 iLink）
与 NapCat 真实下发，见 im/serve.py 的 /api/login/*/qr。
"""

from __future__ import annotations

import json
import os
import secrets
import socket
import struct
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

WS_MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# WebSocket 单帧上限（1 MiB）：防止对端声明超大长度耗尽服务端内存。
WS_MAX_FRAME_BYTES = 1 << 20

# token -> {guid, connector, ts}。进程内有效，网关重启后需重新扫码/取状态。
AGP_TOKENS: dict[str, dict[str, Any]] = {}
_TOKENS_LOCK = threading.Lock()

# 安全修复：
#  * 早期``TANGRAM_AGP_REQUIRE_TOKEN=0``会让**空 token** 直接通过校验，
#    等于一行环境变量就能关掉整条 WebSocket 鉴权（CWE-306）；已移除该后门。
#  * 早期 token 永不过期、且不限制数量，而 /api/login/*/status 每次轮询都会
#    新签一枚：既可被无限重放，也能把进程内存撑爆（CWE-613 / CWE-400）。
#    现在 token 有 TTL、有总量上限，并按 (host, connector) 复用同一枚凭据。
_AGP_TOKEN_TTL = float(os.environ.get("TANGRAM_AGP_TOKEN_TTL", str(24 * 3600)))
_AGP_MAX_TOKENS = 1024
_AGP_GRANTS: dict[tuple[str, str], dict[str, Any]] = {}


def _evict_expired_locked(now: float) -> None:
    for tok, rec in list(AGP_TOKENS.items()):
        if now - float(rec.get("ts", 0)) > _AGP_TOKEN_TTL:
            AGP_TOKENS.pop(tok, None)


def issue_credentials(host: str, connector: str) -> dict[str, str]:
    """登录成功后签发真实 AGP 连接凭据（不是伪造的登录态）。

    同一 (host, connector) 在有效期内复用同一枚凭据，避免状态轮询接口
    每 8 秒就签一枚新 token 造成无界增长。
    """
    scheme = "wss" if os.environ.get("TANGRAM_AGP_WSS") == "1" else "ws"
    ws_url = f"{scheme}://{host}/ws"
    key = (host, connector)
    now = time.time()
    with _TOKENS_LOCK:
        _evict_expired_locked(now)
        cached = _AGP_GRANTS.get(key)
        if (cached and (now - float(cached["ts"])) < _AGP_TOKEN_TTL
                and cached["token"] in AGP_TOKENS):
            return {"ws_url": ws_url, "guid": cached["guid"],
                    "token": cached["token"]}
        if len(AGP_TOKENS) >= _AGP_MAX_TOKENS:
            oldest = min(AGP_TOKENS,
                         key=lambda t: float(AGP_TOKENS[t].get("ts", 0)))
            AGP_TOKENS.pop(oldest, None)
        token = secrets.token_urlsafe(32)
        guid = f"tga-{secrets.token_hex(8)}"
        AGP_TOKENS[token] = {"guid": guid, "connector": connector, "ts": now}
        _AGP_GRANTS[key] = {"guid": guid, "token": token, "ts": now}
    return {"ws_url": ws_url, "guid": guid, "token": token}


def verify_token(token: str) -> Optional[dict[str, Any]]:
    """校验 AGP token：必须非空、已签发、且未过期。"""
    if not token:
        return None
    with _TOKENS_LOCK:
        rec = AGP_TOKENS.get(token)
        if rec is None:
            return None
        if time.time() - float(rec.get("ts", 0)) > _AGP_TOKEN_TTL:
            AGP_TOKENS.pop(token, None)
            return None
        return dict(rec)


# --------------------------------------------------------------------------
# WebSocket 帧（RFC 6455）：服务端发不掩码，客户端帧必须掩码
# --------------------------------------------------------------------------
def ws_frame(opcode: int, payload: bytes) -> bytes:
    head = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head.append(n)
    elif n < 65536:
        head.append(126)
        head += struct.pack("!H", n)
    else:
        head.append(127)
        head += struct.pack("!Q", n)
    return bytes(head) + payload


def ws_text_frame(payload: bytes) -> bytes:
    return ws_frame(0x1, payload)


def _recv_exact(read: Callable[[int], bytes], n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = read(n - len(buf))
        if not chunk:
            raise ConnectionError("websocket closed")
        buf += chunk
    return buf


def ws_read_frame(read: Callable[[int], bytes],
                  max_payload: int = WS_MAX_FRAME_BYTES) -> tuple[int, bytes]:
    """返回 (opcode, payload)。read 通常传 `handler.rfile.read`。

    安全修复：早期既不要求客户端帧掩码、也不限制帧长度，对端可声明
    2^63-1 字节的长度让服务端持续读取 / 分配内存（CWE-400），且未掩码帧
    违反 RFC 6455。现在强制掩码 + 单帧上限，超限抛 ValueError 由调用方断开。
    """
    h = _recv_exact(read, 2)
    b1, b2 = h[0], h[1]
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    n = b2 & 0x7F
    if n == 126:
        n = struct.unpack("!H", _recv_exact(read, 2))[0]
    elif n == 127:
        n = struct.unpack("!Q", _recv_exact(read, 8))[0]
    if not masked:
        raise ValueError("unmasked-client-frame：RFC 6455 要求客户端帧必须掩码")
    if n > max_payload:
        raise ValueError(f"websocket-frame-too-large：{n} > {max_payload}")
    mask = _recv_exact(read, 4)
    data = _recv_exact(read, n) if n else b""
    data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    return opcode, data


def ws_accept(key: str) -> str:
    import base64
    import hashlib

    # SHA1 是 RFC 6455 握手规定的固定算法，并非用于安全签名；
    # usedforsecurity=False 明确标注这一点（也避免审计工具误报）。
    digest = hashlib.sha1((key + WS_MAGIC).encode(),
                          usedforsecurity=False).digest()
    return base64.b64encode(digest).decode()


# --------------------------------------------------------------------------
# Hub：入站转发 + 回复回收
# --------------------------------------------------------------------------
@dataclass
class _Turn:
    event: threading.Event = field(default_factory=threading.Event)
    chunks: list[str] = field(default_factory=list)
    reply: str = ""
    error: str = ""


class AgpHub:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        # connector -> [(socket, send_lock)]
        self._clients: dict[str, list[tuple[socket.socket, threading.Lock]]] = {}
        self._pending: dict[str, _Turn] = {}

    def has_client(self, connector: str = "") -> bool:
        with self._lock:
            if connector:
                return bool(self._clients.get(connector))
            return any(self._clients.values())

    def register(
        self, connector: str, sock: socket.socket, lock: threading.Lock
    ) -> None:
        with self._lock:
            self._clients.setdefault(connector, []).append((sock, lock))
        print(f"[agp] APP 已接入 connector={connector}", flush=True)

    def unregister(
        self, connector: str, sock: socket.socket, lock: threading.Lock
    ) -> None:
        with self._lock:
            lst = self._clients.get(connector, [])
            self._clients[connector] = [x for x in lst if x[0] is not sock]
        print(f"[agp] APP 断开 connector={connector}", flush=True)

    def client_count(self) -> int:
        with self._lock:
            return sum(len(v) for v in self._clients.values())

    def _send_to(self, connector: str, env: dict[str, Any]) -> bool:
        raw = ws_text_frame(json.dumps(env, ensure_ascii=False).encode("utf-8"))
        with self._lock:
            targets = list(self._clients.get(connector, []))
            if not targets:
                targets = [c for v in self._clients.values() for c in v]
        sent = False
        for sock, lock in targets:
            try:
                with lock:
                    sock.sendall(raw)
                sent = True
            except OSError:
                self.unregister(connector, sock, lock)
        return sent

    def prompt(
        self,
        text: str,
        connector: str,
        target: str,
        timeout: float = 180.0,
    ) -> Optional[str]:
        """把一条 IM 消息交给手机 APP 推理，返回真实回复；不可用返回 None。"""
        if not text or not self.has_client(connector):
            return None
        prompt_id = uuid.uuid4().hex
        turn = _Turn()
        with self._lock:
            self._pending[prompt_id] = turn
        env = {
            "msg_id": str(uuid.uuid4()),
            "method": "session.prompt",
            "payload": {
                "session_id": f"{connector}:{target}",
                "prompt_id": prompt_id,
                "agent_app": "tga",
                "content": [{"type": "text", "text": text}],
            },
        }
        if not self._send_to(connector, env):
            with self._lock:
                self._pending.pop(prompt_id, None)
            return None
        ok = turn.event.wait(timeout)
        with self._lock:
            self._pending.pop(prompt_id, None)
        if not ok or turn.error:
            return None
        return turn.reply or "\n".join(turn.chunks) or None

    def on_app_message(self, env: dict[str, Any]) -> None:
        method = str(env.get("method") or "")
        payload = env.get("payload") or {}
        if not isinstance(payload, dict):
            return
        prompt_id = str(payload.get("prompt_id") or "")
        if not prompt_id:
            return
        if method == "session.update":
            content = payload.get("content") or {}
            text = str(content.get("text") or "") if isinstance(content, dict) else ""
            with self._lock:
                turn = self._pending.get(prompt_id)
                if turn is not None and text:
                    turn.chunks.append(text)
        elif method == "session.promptResponse":
            parts = payload.get("content") or []
            text = "\n".join(
                str(x.get("text") or "")
                for x in parts
                if isinstance(x, dict)
            )
            with self._lock:
                turn = self._pending.get(prompt_id)
            if turn is not None:
                turn.reply = text
                turn.error = str(payload.get("error") or "")
                turn.event.set()


AGP_HUB = AgpHub()
