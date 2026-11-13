"""WhatsApp Adapter：对接同仓 Baileys 桥接进程（OpenClaw 同款 WhatsApp Web 多设备协议）。

- 入站：桥进程把消息 POST 到网关 /webhook/whatsapp，本 Adapter 归一化。
- 出站：POST 桥进程 /send {to, text}（真实下发由 Baileys 会话完成）。
- 扫码：二维码 PNG 由桥进程落盘（QR 为 WhatsApp 真实配对码，非伪造）。

约束：仅标准库；桥进程地址可配（默认 http://127.0.0.1:50433）。
"""

from __future__ import annotations

from typing import Any

from ..gateway import Adapter, MultimodalMessage
from ..util import NetClient, now_ts


class WhatsAppBaileysAdapter(Adapter):
    name = "whatsapp_baileys"
    enabled = True

    def __init__(self, bridge_base: str = "http://127.0.0.1:50433") -> None:
        self.bridge_base = bridge_base
        self._net = NetClient(base_url=bridge_base)

    def connect(self, account: Any) -> None:
        return None

    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        user_id = str(raw.get("user_id", ""))
        text = str(raw.get("text") or "")
        if not text and raw.get("has_image"):
            return MultimodalMessage(
                user_id=user_id,
                platform=self.name,
                modality="image",
                payload={"url": "", "message_id": str(raw.get("message_id", ""))},
                ts=float(raw.get("timestamp", now_ts())),
                message_id=str(raw.get("message_id", "")),
            )
        return MultimodalMessage(
            user_id=user_id,
            platform=self.name,
            modality="text",
            payload=text,
            ts=float(raw.get("timestamp", now_ts())),
            message_id=str(raw.get("message_id", "")),
        )

    def send_outbound(self, msg: MultimodalMessage) -> None:
        if msg.modality not in ("text",):
            raise ValueError(f"whatsapp adapter 暂只支持文本出站: {msg.modality}")
        resp, why = self._net.post_json("/send", {"to": msg.user_id, "text": str(msg.payload)})
        if resp is None:
            raise RuntimeError(f"bridge-unreachable:{why}")

    # ---- 桥进程状态查询（供面板/状态接口使用） ----
    def bridge_status(self) -> tuple[dict | None, str]:
        return self._net.get_json("/status")

    def start(self) -> None:
        return None

    def stop(self) -> None:
        return None
