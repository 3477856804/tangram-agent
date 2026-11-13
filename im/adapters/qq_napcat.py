"""QQ NapCat Adapter：NapCat + OneBot v11 真人号。

风险提示：真人号 / NapCat 属于风险自担方案，可能违反平台
条款并导致封号；本 Adapter 默认启用（由用户自行评估），但所有网络与监听
均为占位，且出站受 Gateway 风控守卫约束。

- 传输：OneBot v11 通过 WebSocket（正向/反向）或 HTTP 轮询（占位）。
- inbound：解析 OneBot v11 message 事件（消息段数组）。
- outbound：send_private_msg / send_group_msg（文本 / 图片，占位）。
"""

from __future__ import annotations

from typing import Any

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
        # onebot_base：本地 NapCat 提供的 OneBot v11 地址（ws/http 占位）。
        self.onebot_base = onebot_base
        self.access_token = access_token
        self._net = NetClient(base_url=onebot_base)
        self._ws = None  # 正向 WS 占位，惰性导入

    def connect(self, account: Any) -> None:
        # 占位：真实实现建立 WS / 校验 access_token。
        return None

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
        # 目标：user_id 指向私聊；若消息携带 group_id 则走群发（占位）。
        user_id = msg.user_id
        group_id = getattr(msg, "group_id", None)
        if msg.modality == "text":
            self._onebot_send(user_id, group_id, "text", str(msg.payload))
        elif msg.modality == "image":
            media = msg.payload if isinstance(msg.payload, dict) else {}
            self._onebot_send(user_id, group_id, "image", media.get("url", ""))
        elif msg.modality == "voice":
            media = msg.payload if isinstance(msg.payload, dict) else {}
            self._onebot_send(user_id, group_id, "record", media.get("file", ""))
        else:
            raise ValueError(f"unsupported modality: {msg.modality}")

    def _onebot_send(self, user_id: str, group_id: Any, kind: str, content: str) -> None:
        """调用 OneBot v11 send_private_msg / send_group_msg。"""
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
        headers = {"Authorization": f"Bearer {self.access_token}"} if self.access_token else None
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

    # ---- WS 监听占位（风险自担，默认不主动拉起） ----
    def start(self) -> None:
        # 占位：真实实现惰性导入 websocket-client 并建立反向 WS 监听。
        return None

    def stop(self) -> None:
        if self._ws is not None:
            try:
                self._ws.close()
            except Exception:
                pass
            self._ws = None
