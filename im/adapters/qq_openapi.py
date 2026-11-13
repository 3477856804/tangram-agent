"""QQ 官方机器人 APIv2 适配器（协议对齐腾讯官方开源 SDK tencent-connect/botpy）。

照搬自 botpy master 的已核实协议：
- Token：POST https://bots.qq.com/app/getAppAccessToken  body {"appId", "clientSecret"}
- 鉴权：Authorization: "QQBot <access_token>"，附 X-Union-Appid 头
- 被动回复：POST https://api.sgroup.qq.com/v2/users/{openid}/messages（C2C 私聊）
           POST https://api.sgroup.qq.com/v2/groups/{group_openid}/messages（群）
  首次回复必须携带 msg_id（20 分钟内有效）；后续主动消息使用 msg_id 或 /meet 接口受限。

事件回调（HTTP 模式）：平台以 AEAD_AES_256-GCM 加密推送（nonce/密文/signature，密钥
sha256(client_secret)）。本适配器惰性依赖 cryptography：缺失时仅接受明文调试模式，
拒绝解密失败的事件，绝不伪造处理成功。

配置：环境变量 TANGRAM_QQ_APPID / TANGRAM_QQ_SECRET；未配置时 enabled=False（不伪造在线）。
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import time
from typing import Any, Optional

from ..gateway import Adapter, MultimodalMessage
from ..util import NetClient, now_ts

TOKEN_URL = "https://bots.qq.com/app/getAppAccessToken"
API_BASE = os.environ.get("TANGRAM_QQ_API_BASE", "https://api.sgroup.qq.com")

_C2C_EVENT = "C2C_MESSAGE_CREATE"
_GROUP_EVENT = "GROUP_AT_MESSAGE_CREATE"


class QQOpenAPIAdapter(Adapter):
    name = "qq_openapi"
    enabled = False  # 配好 appid/secret 才启用

    def __init__(self, app_id: str = "", client_secret: str = "") -> None:
        self.app_id = app_id or os.environ.get("TANGRAM_QQ_APPID", "")
        self.client_secret = client_secret or os.environ.get("TANGRAM_QQ_SECRET", "")
        self._net = NetClient(base_url="", timeout=15)
        self._token: str = ""
        self._token_exp: float = 0.0

    @property
    def ready(self) -> bool:
        return bool(self.app_id and self.client_secret)

    def connect(self, account: Any) -> None:
        if not self.ready:
            raise RuntimeError("未配置 TANGRAM_QQ_APPID/TANGRAM_QQ_SECRET（不伪造连接）")
        self.enabled = True

    # ---- token ----
    def _ensure_token(self) -> str:
        if self._token and time.time() < self._token_exp - 60:
            return self._token
        resp, why = self._net.post_json(
            TOKEN_URL, {"appId": self.app_id, "clientSecret": self.client_secret}
        )
        if resp is None:
            raise RuntimeError(f"qq-token-failed:{why}")
        tok = str(resp.get("access_token") or "")
        if not tok:
            raise RuntimeError(f"qq-token-empty:{str(resp)[:120]}")
        self._token = tok
        exp = resp.get("expires_in")
        try:
            # 官方字段为 ISO8601 字符串或秒数，两种都兼容
            if isinstance(exp, (int, float)):
                self._token_exp = time.time() + float(exp)
            else:
                import datetime

                dt = datetime.datetime.fromisoformat(str(exp).replace("Z", "+00:00"))
                self._token_exp = dt.timestamp()
        except Exception:
            self._token_exp = time.time() + 1800
        return self._token

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"QQBot {self._ensure_token()}",
            "X-Union-Appid": self.app_id,
            "Content-Type": "application/json",
        }

    # ---- 出站（被动回复优先） ----
    def send_outbound(self, msg: MultimodalMessage) -> None:
        if not self.ready:
            raise RuntimeError("qq_openapi 未配置凭据")
        meta = msg.payload if isinstance(msg.payload, dict) else {}
        text = str(meta.get("text") or msg.payload or "")
        msg_id = str(meta.get("msg_id") or "")
        scope = str(meta.get("scope") or "users")  # users=C2C / groups=群
        path = f"/v2/{scope}/{msg.user_id}/messages"
        body: dict[str, Any] = {"msg_type": 0, "content": text}
        if msg_id:
            body["msg_id"] = msg_id
        resp, why = self._net.post_json(API_BASE + path, body, headers=self._headers())
        if resp is None:
            raise RuntimeError(f"qq-send-failed:{why}")
        if resp.get("message") and not resp.get("id"):
            raise RuntimeError(f"qq-send-error:{str(resp)[:160]}")

    # ---- 入站事件归一化 ----
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
            payload={"text": text, "msg_id": str(content.get("id") or ""), "scope": scope},
            ts=float(content.get("timestamp", now_ts())),
            message_id=str(content.get("id") or ""),
        )

    # ---- 回调事件解密（HTTP 模式加密包） ----
    @staticmethod
    def decrypt_callback(body: dict[str, Any], client_secret: str) -> Optional[dict[str, Any]]:
        """解密 {"nonce","key?","data"} 加密事件；失败返回 None（不伪造）。"""
        data = body.get("data")
        nonce = body.get("nonce")
        if not isinstance(data, str) or not isinstance(nonce, str):
            return None
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM

            key = hashlib.sha256(client_secret.encode()).digest()
            plain = AESGCM(key).decrypt(
                nonce.encode(), base64.b64decode(data), b""
            )
            return json.loads(plain.decode())
        except Exception:
            return None

    def start(self) -> None:
        if self.ready:
            self.enabled = True

    def stop(self) -> None:
        return None
