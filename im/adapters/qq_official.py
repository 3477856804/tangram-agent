"""QQ 官方 Adapter：OpenClaw QQ 机器人官方。

接入方式：QQ 开放平台官方机器人（OpenClaw）；bot 注册 + 事件回调。
- inbound：解析官方回调事件（C2C / 群组 文本 / 图片）。
- outbound：经官方 API 下发文本 / 图片（占位：由服务端代理或 SDK 完成）。

凭据（appid / token）由服务端持有，本 Adapter 仅构造签名请求与事件解析。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import time
from typing import Any, Optional

from ..gateway import Adapter, MultimodalMessage
from ..util import NetClient, now_ts


class QQOfficialAdapter(Adapter):
    name = "qq_official"
    enabled = True  # 官方渠道，默认启用

    def __init__(self, server_base: str = "", app_secret: str = "") -> None:
        self.server_base = server_base
        self._app_secret = app_secret
        self._net = NetClient(base_url=server_base)
        self.bot_appid: Optional[str] = None

    # ---- bot 注册（占位） ----
    def connect(self, account: Any) -> None:
        """bot 注册 / 鉴权（占位：真实实现由官方 SDK 完成）。"""
        self.bot_appid = getattr(account, "handle", None)
        return None

    def register_bot(self, appid: str, token: str) -> tuple[Optional[Any], str]:
        """向服务端代理注册官方机器人（带 HMAC 签名）。"""
        ts = str(int(time.time()))
        nonce = hashlib.sha256((appid + ts).encode()).hexdigest()[:16]
        signature = hmac.new(
            self._app_secret.encode("utf-8"),
            f"{appid}{ts}{nonce}".encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        body, status = self._net.post_json(
            "/api/im/qq/register_bot",
            {"appid": appid, "token": token, "timestamp": ts, "nonce": nonce, "signature": signature},
        )
        return body, status

    def verify_message_signature(
        self, signature: str, timestamp: str, nonce: str, body: bytes | str = b""
    ) -> bool:
        """校验官方机器人回调 webhook 签名（base64(HMAC-SHA256)）。

        与 server.social.QQSocial.make/verify_bot_signature 同款算法，
        保证 Adapter 侧能在本地先做一层校验再交给后端。
        """
        if not self._app_secret:
            return False
        raw = body if isinstance(body, bytes) else body.encode("utf-8")
        message = raw
        if timestamp or nonce:
            message = f"{timestamp}{nonce}".encode("utf-8") + raw
        mac = hmac.new(
            self._app_secret.encode("utf-8"), message, hashlib.sha256
        ).digest()
        expected = base64.b64encode(mac).decode("ascii")
        return hmac.compare_digest(expected, str(signature))

    # ---- inbound 规范化 ----
    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        """解析官方回调事件（docusaurus/频道机器人事件结构）。"""
        user_id = str(raw.get("user_id") or raw.get("openid") or "")
        msg_type = str(raw.get("message_type") or raw.get("msg_type") or "text").lower()
        if msg_type in ("image", "file"):
            modality = "image" if msg_type == "image" else "file"
            attachments = raw.get("attachments") or []
            url = attachments[0].get("url", "") if attachments else raw.get("url", "")
            payload = {"url": url, "media_id": raw.get("media_id", "")}
        else:
            modality = "text"
            payload = str(raw.get("message") or raw.get("content") or "")
        return MultimodalMessage(
            user_id=user_id,
            platform=self.name,
            modality=modality,
            payload=payload,
            ts=float(raw.get("timestamp", now_ts())),
            message_id=str(raw.get("id") or raw.get("msg_id") or ""),
        )

    # ---- outbound 规范化 ----
    def send_outbound(self, msg: MultimodalMessage) -> None:
        if msg.modality == "text":
            self._server_send_text(msg.user_id, str(msg.payload))
        elif msg.modality in ("image", "file"):
            media = msg.payload if isinstance(msg.payload, dict) else {}
            self._server_send_media(msg.user_id, media.get("url", ""), media.get("media_id", ""))
        else:
            raise ValueError(f"unsupported modality: {msg.modality}")

    def _server_send_text(self, openid: str, text: str) -> None:
        # 失败必须抛错：旧实现丢弃 (None, why)，Gateway 会误记「已发送」。
        resp, why = self._net.post_json("/api/im/qq/send_text", {"openid": openid, "text": text})
        if resp is None:
            raise RuntimeError(f"qq-official-send-failed:{why}")

    def _server_send_media(self, openid: str, url: str, media_id: str) -> None:
        resp, why = self._net.post_json(
            "/api/im/qq/send_media", {"openid": openid, "url": url, "media_id": media_id}
        )
        if resp is None:
            raise RuntimeError(f"qq-official-send-media-failed:{why}")
