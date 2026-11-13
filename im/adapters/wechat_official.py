"""微信官方 Adapter：iLink ClawBot 官方一对一。

接入方式：iLink ClawBot 官方一对一；code -> openid 走服务端验签
（客户端不换 token，符合社交凭证只存服务端约定）。
- inbound：解析微信公众平台/ClawBot webhook 事件。
- outbound：经服务端代理下发文本 / 图片（真实下发由后端服务完成）。

网络与加密均惰性导入 + 降级：本 Adapter 不直接持有 token，仅构造
带 HMAC 签名的请求体交由服务端验签代理。
"""

from __future__ import annotations

import hashlib
import hmac
import time
from typing import Any, Optional

from ..gateway import Adapter, MultimodalMessage
from ..util import NetClient, now_ts


class WeChatOfficialAdapter(Adapter):
    name = "wechat_official"
    enabled = True  # 官方渠道，默认启用

    def __init__(self, server_base: str = "", app_secret: str = "") -> None:
        # server_base：服务端验签代理基址；app_secret：仅用于本地签名，不落盘。
        self.server_base = server_base
        self._app_secret = app_secret
        self._net = NetClient(base_url=server_base)

    # ---- 连接（占位） ----
    def connect(self, account: Any) -> None:
        # 官方一对一无需本地长连接；凭据由服务端持有。
        return None

    def verify_message_signature(
        self, signature: str, timestamp: str, nonce: str, body: str = ""
    ) -> bool:
        """校验服务端转发来的消息签名（HMAC-SHA256，凭证仅服务端）。

        signature = HMAC-SHA256(app_secret, sorted(token, timestamp, nonce) 拼接 + body)
        通过后才接受入站事件，防伪造 webhook。
        """
        if not self._app_secret:
            return False
        parts = sorted([self._app_secret, str(timestamp), str(nonce)])
        material = "".join(parts) + str(body)
        digest = hmac.new(
            self._app_secret.encode("utf-8"),
            material.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        return hmac.compare_digest(digest, str(signature))

    # ---- code -> openid（服务端验签） ----
    def verify_code(self, code: str) -> tuple[Optional[str], str]:
        """用服务端验签换取 openid（客户端不换 token）。

        请求结构（POST {server_base}/api/im/wechat/code2openid）：
            {code, timestamp, nonce, signature}
        其中 signature = HMAC-SHA256(app_secret, f"{code}{timestamp}{nonce}")。
        """
        ts = str(int(time.time()))
        nonce = hashlib.sha256((code + ts).encode()).hexdigest()[:16]
        signature = hmac.new(
            self._app_secret.encode("utf-8"),
            f"{code}{ts}{nonce}".encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        body, status = self._net.post_json(
            "/api/im/wechat/code2openid",
            {"code": code, "timestamp": ts, "nonce": nonce, "signature": signature},
        )
        if status != "ok" or not body:
            return None, status
        return body.get("openid"), "ok"

    # ---- inbound 规范化 ----
    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        """解析微信 webhook 事件为统一多模态消息。

        raw 常见字段：FromUserName / MsgType / Content / MediaId / PicUrl /
        CreateTime / MsgId（XML 已由上游反序列化为 dict）。
        """
        user_id = str(raw.get("FromUserName", ""))
        msg_type = str(raw.get("MsgType", "text")).lower()
        if msg_type == "image":
            modality = "image"
            payload = {"media_id": raw.get("MediaId", ""), "url": raw.get("PicUrl", "")}
        elif msg_type == "voice":
            modality = "voice"
            payload = {"media_id": raw.get("MediaId", ""), "recognition": raw.get("Recognition", "")}
        else:
            modality = "text"
            payload = str(raw.get("Content", ""))
        ts = float(raw.get("CreateTime", now_ts()))
        return MultimodalMessage(
            user_id=user_id,
            platform=self.name,
            modality=modality,
            payload=payload,
            ts=ts,
            message_id=str(raw.get("MsgId", "")),
        )

    # ---- outbound 规范化 ----
    def send_outbound(self, msg: MultimodalMessage) -> None:
        """经服务端代理下发文本 / 图片。"""
        if msg.modality == "text":
            self._server_send_text(msg.user_id, str(msg.payload))
        elif msg.modality == "image":
            media = msg.payload if isinstance(msg.payload, dict) else {}
            self._server_send_image(msg.user_id, media.get("media_id", ""), media.get("url", ""))
        else:
            raise ValueError(f"unsupported modality: {msg.modality}")

    def _server_send_text(self, openid: str, text: str) -> None:
        # 失败必须抛错：旧实现丢弃 (None, why)，Gateway 会误记「已发送」。
        resp, why = self._net.post_json(
            "/api/im/wechat/send_text", {"openid": openid, "text": text}
        )
        if resp is None:
            raise RuntimeError(f"wechat-official-send-failed:{why}")

    def _server_send_image(self, openid: str, media_id: str, url: str) -> None:
        resp, why = self._net.post_json(
            "/api/im/wechat/send_image", {"openid": openid, "media_id": media_id, "url": url}
        )
        if resp is None:
            raise RuntimeError(f"wechat-official-send-image-failed:{why}")
