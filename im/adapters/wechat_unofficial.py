"""微信非官方 Adapter：WeLink / wechatbot-webhook。**默认禁用**。

风险提示：非官方接口存在封号 / 合规风险，默认 enabled=False，
必须用户显式调用 enable() 开启并确认风险后方可使用。
- inbound：解析企业微信/wechatbot webhook 事件。
- outbound：文本 / 图片（真实 POST 到 webhook，失败抛错由网关风控记录）。
"""

from __future__ import annotations

from typing import Any

from ..gateway import Adapter, MultimodalMessage
from ..util import NetClient, now_ts

_RISK_NOTICE = (
    "wechat_unofficial 为非官方接口：可能违反平台条款、存在封号与合规风险，"
    "仅可在用户明确知晓并自负风险的前提下启用（context_isolation 默认开启）。"
)


class WeChatUnofficialAdapter(Adapter):
    name = "wechat_unofficial"
    enabled = False  # 默认禁用，需显式开启

    def __init__(self, webhook_url: str = "") -> None:
        self.webhook_url = webhook_url
        self._net = NetClient()

    def enable(self, *, acknowledged_risk: bool = False) -> None:
        """显式启用；必须确认风险，否则拒绝开启。"""
        if not acknowledged_risk:
            raise RuntimeError(_RISK_NOTICE)
        self.enabled = True

    def disable(self) -> None:
        self.enabled = False

    def connect(self, account: Any = None) -> None:
        """真实连接校验：webhook 已配置且真的能连上，不谎称可用。"""
        if not self.enabled:
            raise RuntimeError("wechat_unofficial 默认禁用，需显式开启（见 enable）")
        if isinstance(account, dict) and account.get("webhook_url"):
            self.webhook_url = str(account["webhook_url"])
        if not self.webhook_url:
            raise RuntimeError("wechat_unofficial 未配置 webhook_url，拒绝伪装已连接")
        resp, why = self._net.get_json(self.webhook_url)
        # 服务端回了 HTTP 状态码即视为链路可达（webhook 一般只收 POST）；
        # 只有网络层失败才是真的连不上。
        if resp is None and why.startswith(("network-error", "network-degraded")):
            raise RuntimeError(f"wechat-unofficial-connect-failed:{why}")

    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        if not self.enabled:
            raise RuntimeError("wechat_unofficial 已禁用")
        user_id = str(raw.get("userid") or raw.get("from") or "")
        content = raw.get("text") or raw.get("content") or ""
        modality = "text"
        payload: Any = str(content)
        if raw.get("msgtype") == "image" or raw.get("image"):
            modality = "image"
            payload = {"url": raw.get("image", {}).get("url", "") if isinstance(raw.get("image"), dict) else ""}
        return MultimodalMessage(
            user_id=user_id,
            platform=self.name,
            modality=modality,
            payload=payload,
            ts=float(raw.get("timestamp", now_ts())),
            message_id=str(raw.get("msgid", "")),
        )

    def send_outbound(self, msg: MultimodalMessage) -> None:
        if not self.enabled:
            raise RuntimeError("wechat_unofficial 已禁用")
        payload = {
            "msgtype": "text" if msg.modality == "text" else "image",
            "text": {"content": str(msg.payload)} if msg.modality == "text" else None,
            "image": {"url": (msg.payload or {}).get("url", "")} if msg.modality == "image" else None,
        }
        # 经 webhook 下发：失败必须抛错（旧实现丢弃返回值，Gateway 会
        # 误记「已发送」）；抛错后由 Gateway 风控熔断器记录。
        resp, why = self._net.post_json(self.webhook_url, payload)
        if resp is None:
            raise RuntimeError(f"wechat-unofficial-send-failed:{why}")
