"""QQ 官方机器人 APIv2 适配器（websocket 长连接模式，无需公网回调）。

协议真源：腾讯官方开源 SDK tencent-connect/botpy master
（robot.py / gateway.py / api.py / flags.py），端点 2026-11 curl 实测可达：

    POST https://bots.qq.com/app/getAppAccessToken
         body {"appId","clientSecret"} -> {"access_token","expires_in"}
         失败返回 {"code","message"}（如 10004 机器人不存在）——原样上报，
         绝不伪造验证成功。
    GET  https://api.sgroup.qq.com/gateway      （沙箱：sandbox.api.sgroup.qq.com）
         头 Authorization: "QQBot <access_token>" + X-Union-Appid
         -> {"url": "wss://api.sgroup.qq.com/websocket"}
    wss  握手（与 botpy gateway.py 逐字段对齐）：
         op10 HELLO(d.heartbeat_interval ms) -> op2 IDENTIFY
         d {"token":"QQBot <at>","intents":1<<25,"shard":[0,1]} -> op0 READY
         op1 心跳(d=last_seq)/op11 ACK；op7 要求重连；op9 会话失效重新鉴权。
         intents 1<<25 = botpy flags.py public_messages（群@消息 + C2C 私聊）。
    被动回复（botpy api.py post_c2c_message / post_group_message）：
         POST /v2/users/{openid}/messages | /v2/groups/{group_openid}/messages
         body {"msg_type":0,"content":text,"msg_id":事件顶层 id}
         msg_id 官方限 20 分钟内有效（被动回复窗口）。

与 qq_openapi.py（HTTP 加密回调模式）互补：本适配器走 wss 长连接收事件，
两者共用同一套官方 token / 消息 API。凭据来自环境变量
TANGRAM_QQ_APPID / TANGRAM_QQ_SECRET（或构造参数）；未配置时 ready=False、
enabled=False——不伪造在线。

实现约束：仅标准库（urllib + socket/ssl 手写 RFC 6455 客户端帧），
网络全部在使用时惰性发生；凭据落 TANGRAM_DATA/qq_official.json（0600）。
"""

from __future__ import annotations

import base64
import json
import os
import secrets
import socket
import ssl
import struct
import threading
import time
from typing import Any, Callable, Optional
from urllib.parse import urlparse

from ..gateway import Adapter, MultimodalMessage
from ..util import now_ts

TOKEN_URL = "https://bots.qq.com/app/getAppAccessToken"
API_BASE = "https://api.sgroup.qq.com"
SANDBOX_API_BASE = "https://sandbox.api.sgroup.qq.com"
INTENTS_PUBLIC_MESSAGES = 1 << 25  # botpy flags.public_messages

_C2C_EVENT = "C2C_MESSAGE_CREATE"
_GROUP_EVENT = "GROUP_AT_MESSAGE_CREATE"


def _http_json(method: str, url: str, body: Optional[dict] = None,
               headers: Optional[dict] = None, timeout: float = 15.0) -> tuple[int, dict]:
    """真实 HTTP JSON 请求；返回 (状态码, 解析后的响应体)。

    与 util.NetClient 不同：错误响应体（官方 code/message）必须原样带回，
    验证失败时 UI/日志才能转述「机器人不存在」这类真实原因。
    """
    import urllib.error
    import urllib.request

    data = json.dumps(body).encode("utf-8") if body is not None else None
    hdrs = {"Accept": "application/json", "Content-Type": "application/json"}
    if headers:
        hdrs.update(headers)
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            raw = resp.read().decode("utf-8", "replace")
            code = resp.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        code = exc.code
    try:
        parsed = json.loads(raw)
        if not isinstance(parsed, dict):
            parsed = {"data": parsed}
    except ValueError:
        parsed = {"message": raw[:200]}
    return code, parsed


class _MiniWsClient:
    """极简 RFC 6455 websocket 客户端（仅标准库，文本帧）。

    只做 QQ 网关握手/收发所需的最小集合：掩码发送、分片接收、ping/pong、
    close 帧感知。读超时由 settimeout 驱动上层心跳节奏。
    """

    def __init__(self, url: str, timeout: float = 60.0) -> None:
        u = urlparse(url)
        if u.scheme not in ("wss", "ws"):
            raise ValueError(f"unsupported ws scheme: {u.scheme}")
        host = u.hostname or ""
        port = u.port or (443 if u.scheme == "wss" else 80)
        path = (u.path or "/") + (("?" + u.query) if u.query else "")
        sock = socket.create_connection((host, port), timeout=timeout)
        if u.scheme == "wss":
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
        sock.settimeout(timeout)
        self._sock = sock
        self._send_lock = threading.Lock()
        self._buf = b""
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        handshake = (
            f"GET {path} HTTP/1.1\r\nHost: {host}\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode()
        sock.sendall(handshake)
        # 读握手响应直到 \r\n\r\n
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake closed")
            resp += chunk
            if len(resp) > 65536:
                raise ConnectionError("websocket handshake too large")
        head, rest = resp.split(b"\r\n\r\n", 1)
        status_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
        if "101" not in status_line:
            raise ConnectionError(f"websocket handshake failed: {status_line}")
        self._buf = rest

    def _recv_exact(self, n: int) -> bytes:
        while len(self._buf) < n:
            chunk = self._sock.recv(max(4096, n - len(self._buf)))
            if not chunk:
                raise ConnectionError("websocket closed")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def send_text(self, text: str) -> None:
        payload = text.encode("utf-8")
        head = bytearray([0x81])  # FIN + text
        mask = secrets.token_bytes(4)  # 客户端帧必须掩码（RFC 6455）
        n = len(payload)
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126)
            head += struct.pack("!H", n)
        else:
            head.append(0x80 | 127)
            head += struct.pack("!Q", n)
        head += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        with self._send_lock:
            self._sock.sendall(bytes(head) + masked)

    def recv(self) -> tuple[int, bytes]:
        """返回 (opcode, payload)；自动拼接分片、回应 ping。"""
        while True:
            h = self._recv_exact(2)
            fin = bool(h[0] & 0x80)
            opcode = h[0] & 0x0F
            n = h[1] & 0x7F
            if n == 126:
                n = struct.unpack("!H", self._recv_exact(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self._recv_exact(8))[0]
            masked = bool(h[1] & 0x80)
            mask = self._recv_exact(4) if masked else b""
            data = self._recv_exact(n) if n else b""
            if masked:
                data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
            if opcode == 0x9:  # ping -> pong
                self._send_masked(0xA, data)
                continue
            if opcode == 0x8:  # close
                raise ConnectionError("websocket close frame")
            if opcode == 0xA:  # pong
                continue
            if not fin:  # 分片：继续收 continuation
                while True:
                    h2 = self._recv_exact(2)
                    fin2 = bool(h2[0] & 0x80)
                    n2 = h2[1] & 0x7F
                    if n2 == 126:
                        n2 = struct.unpack("!H", self._recv_exact(2))[0]
                    elif n2 == 127:
                        n2 = struct.unpack("!Q", self._recv_exact(8))[0]
                    m2 = bool(h2[1] & 0x80)
                    mask2 = self._recv_exact(4) if m2 else b""
                    d2 = self._recv_exact(n2) if n2 else b""
                    if m2:
                        d2 = bytes(b ^ mask2[i % 4] for i, b in enumerate(d2))
                    data += d2
                    if fin2:
                        break
            if opcode == 0x1:
                return opcode, data

    def _send_masked(self, opcode: int, payload: bytes) -> None:
        head = bytearray([0x80 | opcode])
        mask = secrets.token_bytes(4)
        n = len(payload)
        if n < 126:
            head.append(0x80 | n)
        else:
            head.append(0x80 | 126)
            head += struct.pack("!H", n)
        head += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        with self._send_lock:
            self._sock.sendall(bytes(head) + masked)

    def close(self) -> None:
        try:
            self._send_masked(0x8, b"")
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass


class QQOfficialAdapter(Adapter):
    name = "qq_official"
    enabled = False  # 配好 appid/secret 且显式 start 才启用（不伪造在线）

    def __init__(self, app_id: str = "", client_secret: str = "",
                 sandbox: Optional[bool] = None, data_dir: str = "") -> None:
        self.app_id = app_id or os.environ.get("TANGRAM_QQ_APPID", "")
        self.client_secret = client_secret or os.environ.get("TANGRAM_QQ_SECRET", "")
        if sandbox is None:
            sandbox = os.environ.get("TANGRAM_QQ_SANDBOX", "") == "1"
        self.sandbox = bool(sandbox)
        self.data_dir = data_dir or os.environ.get("TANGRAM_DATA") or os.path.expanduser("~/.tangram")
        self._cred_path = os.path.join(self.data_dir, "qq_official.json")
        self._token = ""
        self._token_exp = 0.0
        self._ws: Optional[_MiniWsClient] = None
        self._thread: Optional[threading.Thread] = None
        self._running = False
        self._connected = False  # 仅当收到官方 READY 才为 True
        self._last_seq = 0
        self._on_event: Optional[Callable[[dict], None]] = None
        self.last_error = ""
        self.inbound_count = 0
        self.outbound_count = 0
        self._load_cred()

    # ---- 凭据 ----
    @property
    def ready(self) -> bool:
        return bool(self.app_id and self.client_secret)

    @property
    def api_base(self) -> str:
        return SANDBOX_API_BASE if self.sandbox else API_BASE

    def _load_cred(self) -> None:
        try:
            with open(self._cred_path, encoding="utf-8") as f:
                d = json.load(f)
            self.app_id = self.app_id or str(d.get("app_id") or "")
            self.client_secret = self.client_secret or str(d.get("client_secret") or "")
            self._token = str(d.get("access_token") or "")
            self._token_exp = float(d.get("expires_at") or 0.0)
        except (OSError, ValueError):
            pass

    def _save_cred(self) -> None:
        try:
            os.makedirs(self.data_dir, exist_ok=True)
            with open(self._cred_path, "w", encoding="utf-8") as f:
                json.dump({
                    "app_id": self.app_id,
                    "client_secret": self.client_secret,
                    "access_token": self._token,
                    "expires_at": self._token_exp,
                    "sandbox": self.sandbox,
                    "saved_at": now_ts(),
                }, f, ensure_ascii=False)
            os.chmod(self._cred_path, 0o600)
        except OSError:
            pass

    # ---- token 换取 ----
    def fetch_access_token(self) -> str:
        if not self.ready:
            raise RuntimeError("未配置 TANGRAM_QQ_APPID/TANGRAM_QQ_SECRET（不伪造连接）")
        code, resp = _http_json("POST", TOKEN_URL, {
            "appId": self.app_id, "clientSecret": self.client_secret,
        })
        token = str(resp.get("access_token") or "")
        if code != 200 or not token:
            # 官方失败体如 {"code":10004,"message":"机器人不存在"}：原样抛出。
            raise RuntimeError(
                f"qq-token-failed:{code}:{resp.get('code', '')}:{resp.get('message', '')}")
        self._token = token
        try:
            exp = float(resp.get("expires_in") or 3600)
        except (TypeError, ValueError):
            exp = 3600.0
        self._token_exp = time.time() + exp
        self._save_cred()
        return token

    def _ensure_token(self) -> str:
        if not self._token or time.time() >= self._token_exp - 60:
            return self.fetch_access_token()
        return self._token

    def _auth_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"QQBot {self._ensure_token()}",
            "X-Union-Appid": self.app_id,
        }

    # ---- 网关 ----
    def gateway_url(self) -> str:
        code, resp = _http_json("GET", f"{self.api_base}/gateway", headers=self._auth_headers())
        if code != 200 or not resp.get("url"):
            raise RuntimeError(
                f"qq-gateway-failed:{code}:{resp.get('code', '')}:{resp.get('message', '')}")
        return str(resp["url"])

    def set_event_handler(self, fn: Callable[[dict], None]) -> None:
        self._on_event = fn

    def connect(self, account: Any) -> None:
        return None

    def start(self) -> None:
        if not self.ready or self._thread is not None:
            return
        self._running = True
        self.enabled = True
        self._thread = threading.Thread(target=self._run_forever, daemon=True,
                                        name="qq-official-ws")
        self._thread.start()

    def stop(self) -> None:
        self._running = False
        self._connected = False
        ws = self._ws
        if ws is not None:
            ws.close()
        self._ws = None

    def _run_forever(self) -> None:
        backoff = 2.0
        while self._running:
            try:
                self._session()
                backoff = 2.0  # 正常断开（如 op7 要求重连）重置退避
            except Exception as exc:
                self.last_error = str(exc)
                self._connected = False
                print(f"[qq-official] 网关会话结束：{exc}（{backoff:.0f}s 后重连）", flush=True)
            if not self._running:
                break
            time.sleep(backoff)
            backoff = min(backoff * 2, 60.0)

    def _session(self) -> None:
        url = self.gateway_url()
        ws = _MiniWsClient(url, timeout=30.0)
        self._ws = ws
        hb_interval = 45.0
        next_hb = 0.0
        identified = False
        try:
            while self._running:
                try:
                    _, raw = ws.recv()
                except socket.timeout:
                    # 读超时：按官方心跳间隔发 op1（d=last_seq），保活。
                    if time.time() >= next_hb:
                        ws.send_text(json.dumps({"op": 1, "d": self._last_seq or None}))
                        next_hb = time.time() + hb_interval
                    continue
                try:
                    msg = json.loads(raw.decode("utf-8", "replace"))
                except ValueError:
                    continue
                if not isinstance(msg, dict):
                    continue
                op = msg.get("op")
                s = msg.get("s")
                if isinstance(s, int) and s > 0:
                    self._last_seq = s
                if op == 10:  # HELLO
                    d = msg.get("d") or {}
                    interval_ms = d.get("heartbeat_interval") or 45000
                    hb_interval = max(float(interval_ms) / 1000.0 - 5.0, 1.0)
                    ws.send_text(json.dumps({
                        "op": 2,
                        "d": {
                            "token": f"QQBot {self._ensure_token()}",
                            "intents": INTENTS_PUBLIC_MESSAGES,
                            "shard": [0, 1],
                        },
                    }))
                    identified = True
                    next_hb = time.time() + hb_interval
                elif op == 9:  # INVALID_SESSION：重新鉴权
                    if identified:
                        ws.send_text(json.dumps({
                            "op": 2,
                            "d": {
                                "token": f"QQBot {self._ensure_token()}",
                                "intents": INTENTS_PUBLIC_MESSAGES,
                                "shard": [0, 1],
                            },
                        }))
                        next_hb = time.time() + hb_interval
                elif op == 7:  # RECONNECT：结束本会话，由外层重连
                    return
                elif op == 0:  # DISPATCH
                    event = str(msg.get("t") or "")
                    if event == "READY":
                        self._connected = True
                        self.last_error = ""
                        print(f"[qq-official] 网关 READY（appid={self.app_id}）", flush=True)
                    elif event in (_C2C_EVENT, _GROUP_EVENT):
                        d = msg.get("d")
                        if isinstance(d, dict) and self._on_event is not None:
                            payload = dict(d)
                            payload["type"] = event
                            self.inbound_count += 1
                            try:
                                self._on_event(payload)
                            except Exception as exc:
                                print(f"[qq-official] 事件处理失败：{exc}", flush=True)
        finally:
            self._connected = False
            ws.close()
            self._ws = None

    # ---- 出站（被动回复） ----
    def send_text(self, scope: str, target_id: str, text: str, msg_id: str) -> dict:
        if not self.ready:
            raise RuntimeError("qq_official 未配置凭据")
        if scope not in ("users", "groups") or not target_id:
            raise RuntimeError(f"qq_official 非法回复目标: {scope}/{target_id}")
        body: dict[str, Any] = {"msg_type": 0, "content": text}
        if msg_id:
            body["msg_id"] = msg_id
        code, resp = _http_json(
            "POST", f"{self.api_base}/v2/{scope}/{target_id}/messages",
            body, headers=self._auth_headers())
        if code != 200 or resp.get("code"):
            raise RuntimeError(
                f"qq-send-failed:{code}:{resp.get('code', '')}:{resp.get('message', '')}")
        self.outbound_count += 1
        return resp

    def send_outbound(self, msg: MultimodalMessage) -> None:
        meta = msg.payload if isinstance(msg.payload, dict) else {}
        text = str(meta.get("text") or msg.payload or "")
        self.send_text(str(meta.get("scope") or "users"), msg.user_id, text,
                       str(meta.get("msg_id") or ""))

    # ---- 入站归一化（dispatch d + type，字段与 qq_openapi.py 回调模式一致） ----
    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        etype = str(raw.get("type") or "")
        content = raw.get("content") or {}
        text = str(content.get("text") or "").strip()
        if etype == _C2C_EVENT:
            uid, scope = str(raw.get("openid") or ""), "users"
        elif etype == _GROUP_EVENT:
            uid, scope = str(raw.get("group_openid") or ""), "groups"
        else:
            raise ValueError(f"未支持的 QQ 事件类型: {etype or '(空)'}")
        return MultimodalMessage(
            user_id=uid,
            platform=self.name,
            modality="text",
            payload={"text": text, "msg_id": str(raw.get("id") or ""), "scope": scope},
            ts=float(content.get("timestamp") or raw.get("timestamp") or now_ts()),
            message_id=str(raw.get("id") or ""),
        )

    # ---- 真实状态快照（供 /api/status；一切来自真实网络结果） ----
    def status(self) -> dict[str, Any]:
        return {
            "configured": self.ready,
            "token_valid": bool(self._token) and time.time() < self._token_exp - 60,
            "gateway_connected": self._connected,
            "sandbox": self.sandbox,
            "last_error": self.last_error,
            "inbound": self.inbound_count,
            "outbound": self.outbound_count,
        }
