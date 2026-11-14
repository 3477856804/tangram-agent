"""QQ NapCat Adapter：NapCat + OneBot v11 真人号（真实网络实现）。

风险提示：真人号 / NapCat 属于风险自担方案，可能违反平台条款并导致封号；
本 Adapter 默认启用（由用户自行评估），但连接、监听与出站全部是真实网络
行为，且出站受 Gateway 风控守卫约束。

- 传输：OneBot v11 HTTP API（真实 POST/GET）+ 可选正向 WebSocket 事件监听。
- inbound：解析 OneBot v11 message 事件（消息段数组）。
- outbound：send_private_msg / send_group_msg（真实 HTTP 调用，失败抛错）。
- connect()：真实调用 ``get_login_info`` 校验凭据与 NapCat 在线状态。
- start()：惰性导入 ``websocket-client`` 建立真实正向 WS 监听；依赖缺失时
  如实打印提示并保持 HTTP webhook 模式，绝不假装「已连上」。
"""

from __future__ import annotations

import json
import threading
import time
from typing import Any, Callable, Optional
from urllib.parse import urlparse, urlunparse

from ..gateway import Adapter, MultimodalMessage
from ..util import NetClient, now_ts

_RISK_NOTICE = (
    "qq_napcat 为 NapCat + OneBot v11 真人号方案：风险自担，可能违反平台条款并导致封号；"
    "请勿用于违反平台规则或法律法规的场景，且多账号上下文默认隔离。"
)


def build_voice_payload(file_path: str) -> dict:
    """OneBot v11 语音消息段（NapCat 支持本地绝对路径）。"""
    return {"type": "record", "file": str(file_path)}


class QQNapCatAdapter(Adapter):
    name = "qq_napcat"
    enabled = True  # 默认启用，但风险自担（见 _RISK_NOTICE）

    def __init__(self, onebot_base: str = "http://127.0.0.1:3000", access_token: str = "") -> None:
        self._onebot_base = onebot_base.rstrip("/")
        self.access_token = access_token
        self._net = NetClient(base_url=self._onebot_base)
        self._ws = None                       # 真实 websocket-client 连接对象
        self._ws_thread: Optional[threading.Thread] = None
        self._ws_stop = threading.Event()
        self._event_handler: Optional[Callable[[dict], None]] = None
        self.connected = False
        self.login_info: dict = {}

    # onebot_base 变更时同步 NetClient 基址（build_gateway 会覆盖默认值）。
    @property
    def onebot_base(self) -> str:
        return self._onebot_base

    @onebot_base.setter
    def onebot_base(self, value: str) -> None:
        self._onebot_base = (value or "").rstrip("/")
        self._net.base_url = self._onebot_base

    def _headers(self) -> Optional[dict[str, str]]:
        return {"Authorization": f"Bearer {self.access_token}"} if self.access_token else None

    # ---- 真实连接校验 ----
    def connect(self, account: Any = None) -> None:
        """真实请求 OneBot get_login_info；拿不到在线账号就抛错，不谎称已连接。"""
        if isinstance(account, dict):
            if account.get("onebot_base"):
                self.onebot_base = str(account["onebot_base"])
            if account.get("access_token"):
                self.access_token = str(account["access_token"])
        resp, why = self._net.get_json("/get_login_info", headers=self._headers())
        if resp is None:
            self.connected = False
            raise RuntimeError(f"napcat-connect-failed:{why}（请确认 NapCat 已启动并放行 HTTP API）")
        if isinstance(resp, dict):
            retcode = resp.get("retcode")
            status = resp.get("status")
            if (retcode is not None and retcode != 0) or status == "failed":
                self.connected = False
                raise RuntimeError(f"napcat-connect-rejected:{str(resp)[:160]}")
            data = resp.get("data") if isinstance(resp.get("data"), dict) else resp
            self.login_info = dict(data or {})
            if not self.login_info.get("user_id"):
                self.connected = False
                raise RuntimeError("napcat-connect-failed:get_login_info 未返回 user_id")
        self.connected = True

    def set_event_handler(self, handler: Callable[[dict], None]) -> None:
        """注入真实 WS 事件回调（由 Gateway 路由到 Agent）。"""
        self._event_handler = handler

    # ---- inbound 规范化（OneBot v11 message 事件） ----
    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        """解析 OneBot v11 上报事件。

        raw 常见字段：user_id / group_id / message_type / message（消息段数组）
        / time / message_id。
        """
        user_id = str(raw.get("user_id", ""))
        group_id = raw.get("group_id")
        segments = raw.get("message") or []
        # 合并文本段，提取首个图片段/语音段
        text_parts: list[str] = []
        image_url = ""
        record_url = ""
        for seg in segments:
            if isinstance(seg, dict):
                if seg.get("type") == "text":
                    text_parts.append(str(seg.get("data", {}).get("text", "")))
                elif seg.get("type") == "image":
                    image_url = image_url or seg.get("data", {}).get("url", "")
                elif seg.get("type") == "record":
                    record_url = record_url or seg.get("data", {}).get("url", "")
        if record_url:
            modality = "voice"
            payload = {"url": record_url, "text": "".join(text_parts)}
        elif image_url:
            modality = "image"
            payload = {"url": image_url}
        else:
            modality = "text"
            payload = "".join(text_parts)
        return MultimodalMessage(
            user_id=user_id,
            platform=self.name,
            modality=modality,
            payload=payload,
            ts=float(raw.get("time", now_ts())),
            message_id=str(raw.get("message_id", "")),
        )

    # ---- outbound 规范化 ----
    def send_outbound(self, msg: MultimodalMessage) -> None:
        # 目标：user_id 指向私聊；消息携带 group_id 时走群发。
        user_id = msg.user_id
        group_id = getattr(msg, "group_id", None)
        if isinstance(msg.payload, dict) and msg.payload.get("group_id"):
            group_id = msg.payload.get("group_id")
        if msg.modality == "text":
            text = msg.payload.get("text") if isinstance(msg.payload, dict) else msg.payload
            self._onebot_send(user_id, group_id, "text", str(text))
        elif msg.modality == "image":
            media = msg.payload if isinstance(msg.payload, dict) else {}
            self._onebot_send(user_id, group_id, "image", media.get("url", ""))
        elif msg.modality == "voice":
            media = msg.payload if isinstance(msg.payload, dict) else {}
            self._onebot_send(user_id, group_id, "record", media.get("file", ""))
        else:
            raise ValueError(f"unsupported modality: {msg.modality}")

    def _onebot_send(self, user_id: str, group_id: Any, kind: str, content: str):
        """调用 OneBot v11 send_private_msg / send_group_msg（真实 HTTP）。"""
        action = "send_group_msg" if group_id else "send_private_msg"
        if kind == "record":
            message: Any = [{"type": "record", "file": content}]
        elif kind == "image":
            message = [{"type": "image", "file": content}]
        else:
            message = content
        params = {"message": message}
        if group_id:
            params["group_id"] = int(group_id)
        else:
            params["user_id"] = int(user_id)
        headers = self._headers()
        # OneBot v11 标准路径 /{action}；带前缀的协议端回退兼容。
        resp, why = self._net.post_json(f"/{action}", params, headers=headers)
        if resp is None:
            resp, why = self._net.post_json(f"/onebot/v11/{action}", params, headers=headers)
        # 两条路径都失败必须抛错：旧实现把 (None, why) 返回给 send_outbound
        # 后被丢弃，Gateway 会误记「已发送」。
        if resp is None:
            raise RuntimeError(f"napcat-send-failed:{why}")
        if isinstance(resp, dict) and resp.get("status") not in (None, "ok") and resp.get("retcode") not in (None, 0):
            raise RuntimeError(f"napcat-send-rejected:{str(resp)[:160]}")
        return resp, why

    # ---- 真实正向 WebSocket 事件监听 ----
    def _ws_url(self) -> str:
        u = urlparse(self._onebot_base)
        scheme = "wss" if u.scheme == "https" else "ws"
        path = "/onebot/v11/ws"  # NapCat/OneBot 正向 WS 常见端点
        query = f"access_token={self.access_token}" if self.access_token else ""
        return urlunparse((scheme, u.netloc, path, "", query, ""))

    def start(self) -> None:
        """惰性导入 websocket-client 建立真实 WS 监听；缺依赖如实提示。"""
        if self._ws_thread is not None and self._ws_thread.is_alive():
            return
        try:
            import websocket  # noqa: PLC0415 - 可选依赖，缺失时不假装已连接
        except ImportError:
            print("[qq_napcat] 未安装 websocket-client：保持 OneBot HTTP webhook "
                  "入站模式（不启动 WS 监听，也不谎称已连上）。", flush=True)
            return
        self._ws_stop.clear()
        self._ws_thread = threading.Thread(target=self._ws_loop, daemon=True,
                                           name="napcat-ws")
        self._ws_thread.start()

    def _ws_loop(self) -> None:
        import websocket  # noqa: PLC0415

        url = self._ws_url()
        backoff = 1.0
        while not self._ws_stop.is_set():
            try:
                ws = websocket.create_connection(url, timeout=10)
                self._ws = ws
                backoff = 1.0
                print(f"[qq_napcat] WS 已连接：{url}", flush=True)
                while not self._ws_stop.is_set():
                    raw = ws.recv()
                    if not raw:
                        continue
                    try:
                        event = json.loads(raw)
                    except ValueError:
                        continue
                    if isinstance(event, dict) and event.get("post_type") == "message":
                        if self._event_handler is not None:
                            self._event_handler(event)
            except Exception as exc:  # noqa: BLE001 - 断线如实记录并重连
                if not self._ws_stop.is_set():
                    print(f"[qq_napcat] WS 断开（{type(exc).__name__}: {exc}），"
                          f"{backoff:.0f}s 后重连", flush=True)
            finally:
                try:
                    if self._ws is not None:
                        self._ws.close()
                except Exception:
                    pass
                self._ws = None
            if self._ws_stop.wait(backoff):
                break
            backoff = min(backoff * 2, 30.0)

    def stop(self) -> None:
        self._ws_stop.set()
        if self._ws is not None:
            try:
                self._ws.close()
            except Exception:
                pass
            self._ws = None
        if self._ws_thread is not None:
            self._ws_thread.join(timeout=2.0)
            self._ws_thread = None
