"""微信 iLink Bot 官方协议适配器（照搬腾讯官方开源 openclaw-weixin 插件的协议实现）。

协议真源：@tencent-weixin/openclaw-weixin v2.4.x（dist/src/api/api.js、auth/login-qr.js、
messaging/send.js）。端点与报文结构与其一一对应：

    POST https://ilinkai.weixin.qq.com/ilink/bot/get_bot_qrcode?bot_type=3
        body {"local_token_list": [...]} -> {"qrcode", "qrcode_img_content"}
    GET  ilink/bot/get_qrcode_status?qrcode=&verify_code=
        -> {"status": wait|scaned|confirmed, "bot_token", "ilink_bot_id"}
    POST ilink/bot/getupdates   body {"get_updates_buf", "base_info"} -> {"msgs", "get_updates_buf"}
    POST ilink/bot/sendmessage  body {"msg": {...}, "base_info"}

鉴权头：AuthorizationType: ilink_bot_token；登录后 Authorization: Bearer <bot_token>；
X-WECHAT-UIN 随机。凭据保存在 TANGRAM_DATA/weixin_ilink.json（权限 0600，明文不落日志）。

仅标准库；网络在使用时惰性发生。
"""

from __future__ import annotations

import json
import os
import secrets
import urllib.parse
import time
from typing import Any, Optional

from ..gateway import Adapter, MultimodalMessage
from ..util import NetClient, now_ts

BASE_URL = os.environ.get("TANGRAM_ILINK_BASE", "https://ilinkai.weixin.qq.com")
BOT_TYPE = "3"
# 与官方 types.js 对齐的枚举
MESSAGE_TYPE_BOT = 2
ITEM_TEXT = 1
ITEM_IMAGE = 2
ITEM_VOICE = 3
STATE_FINISH = 2


class WeChatILinkAdapter(Adapter):
    name = "wechat_ilink"
    enabled = True  # 渠道可用（是否已登录由 has_token 决定，不伪造在线）

    def __init__(self, data_dir: str = "") -> None:
        self._net = NetClient(base_url=BASE_URL, timeout=40)
        self.data_dir = data_dir or os.environ.get("TANGRAM_DATA") or os.path.expanduser("~/.tangram")
        self._cred_path = os.path.join(self.data_dir, "weixin_ilink.json")
        self.token: str = ""
        self.bot_id: str = ""
        self._buf: str = ""
        self._load_cred()

    # ---- 凭据 ----
    def _load_cred(self) -> None:
        try:
            with open(self._cred_path, encoding="utf-8") as f:
                d = json.load(f)
            self.token = str(d.get("bot_token") or "")
            self.bot_id = str(d.get("ilink_bot_id") or "")
            self._buf = str(d.get("get_updates_buf") or "")
        except (OSError, ValueError):
            pass

    def _save_cred(self, data: dict[str, Any]) -> None:
        os.makedirs(self.data_dir, exist_ok=True)
        with open(self._cred_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        try:
            os.chmod(self._cred_path, 0o600)
        except OSError:
            pass

    @property
    def has_token(self) -> bool:
        return bool(self.token)

    # ---- 公共请求 ----
    def _headers(self) -> dict[str, str]:
        h = {
            "AuthorizationType": "ilink_bot_token",
            "X-WECHAT-UIN": str(secrets.randbelow(10**10)),
        }
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    @staticmethod
    def _base_info() -> dict[str, Any]:
        return {"channel_version": "2.4.10-tangram", "bot_agent": "Tangram"}

    def _post(self, endpoint: str, payload: dict[str, Any], timeout: float = 40) -> tuple[dict | None, str]:
        return self._net.post_json(f"/{endpoint}", payload, headers=self._headers())

    # ---- 登录：真实微信二维码 ----
    def fetch_qr(self) -> tuple[Optional[str], Optional[str], str]:
        """返回 (qrcode, 二维码URL, 状态说明)。qrcode_img_content 为可扫码的真实链接。"""
        resp, why = self._post(
            f"ilink/bot/get_bot_qrcode?bot_type={BOT_TYPE}",
            {"local_token_list": [self.token] if self.token else [], "base_info": self._base_info()},
        )
        if resp is None:
            return None, None, why
        return str(resp.get("qrcode") or ""), str(resp.get("qrcode_img_content") or ""), "ok"

    def poll_qr_status(self, qrcode: str, verify_code: str = "") -> dict[str, Any]:
        ep = f"ilink/bot/get_qrcode_status?qrcode={qrcode}"
        if verify_code:
            ep += f"&verify_code={verify_code}"
        resp, why = self._net.get_json(f"/{ep}", headers=self._headers())
        if resp is None:
            return {"status": "wait", "reason": why}
        status = str(resp.get("status") or "wait")
        if status in ("confirmed", "success") and resp.get("bot_token"):
            self.token = str(resp["bot_token"])
            self.bot_id = str(resp.get("ilink_bot_id") or "")
            self._save_cred({
                "bot_token": self.token,
                "ilink_bot_id": self.bot_id,
                "get_updates_buf": self._buf,
                "saved_at": now_ts(),
            })
        return resp

    # ---- 接收 ----
    def get_updates(self, timeout: float = 35) -> tuple[list[dict[str, Any]], str]:
        """长轮询 getupdates。返回 (消息列表, 新游标)；网络异常返回空列表（不伪造）。"""
        resp, why = self._post(
            "ilink/bot/getupdates",
            {"get_updates_buf": self._buf, "base_info": self._base_info()},
            timeout=timeout,
        )
        if resp is None or (resp.get("ret") not in (None, 0)):
            time.sleep(2)
            return [], self._buf
        msgs = resp.get("msgs") or []
        buf = str(resp.get("get_updates_buf") or self._buf)
        if buf != self._buf:
            self._buf = buf
            if self.token:
                self._save_cred({
                    "bot_token": self.token, "ilink_bot_id": self.bot_id,
                    "get_updates_buf": self._buf, "saved_at": now_ts(),
                })
        return msgs, self._buf

    # ---- 出站 ----
    def send_text(self, to_user_id: str, text: str, context_token: str = "") -> None:
        msg: dict[str, Any] = {
            "from_user_id": "",
            "to_user_id": to_user_id,
            "client_id": f"tangram-{secrets.token_hex(8)}",
            "message_type": MESSAGE_TYPE_BOT,
            "message_state": STATE_FINISH,
            "item_list": [{"type": ITEM_TEXT, "text_item": {"text": text}}],
        }
        if context_token:
            msg["context_token"] = context_token
        resp, why = self._post("ilink/bot/sendmessage", {"msg": msg, "base_info": self._base_info()})
        if resp is None:
            raise RuntimeError(f"ilink-send-failed:{why}")
        if resp.get("ret"):
            raise RuntimeError(f"ilink-ret:{resp.get('ret')}:{resp.get('errmsg', '')}")

    def send_outbound(self, msg: MultimodalMessage) -> None:
        if not self.has_token:
            raise RuntimeError("wechat_ilink 尚未完成扫码登录（不伪造发送）")
        ctx = ""
        if isinstance(msg.payload, dict):
            ctx = str(msg.payload.get("context_token") or "")
            body = str(msg.payload.get("text") or "")
        else:
            body = str(msg.payload)
        self.send_text(msg.user_id, body, ctx)

    # ---- 媒体上传与出站（流水线对齐官方 cdn/upload.js + send.js） ----
    CDN_BASE = os.environ.get("TANGRAM_WX_CDN", "https://novac2c.cdn.weixin.qq.com/c2c")
    UPLOAD_FILE = 3   # UploadMediaType.FILE（语音以 .mp3 文件消息下发，微信侧可直接点开播放）

    def upload_file(self, file_path: str, to_user_id: str) -> dict:
        import hashlib
        import secrets

        from cryptography.hazmat.primitives import padding
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

        plaintext = Path(file_path).read_bytes()
        rawsize = len(plaintext)
        md5 = hashlib.md5(plaintext).hexdigest()
        padded = ((rawsize + 1 + 15) // 16) * 16
        filekey = secrets.token_hex(16)
        aeskey = secrets.token_bytes(16)
        resp, why = self._post("ilink/bot/getuploadurl", {
            "filekey": filekey, "media_type": self.UPLOAD_FILE, "to_user_id": to_user_id,
            "rawsize": rawsize, "rawfilemd5": md5, "filesize": padded,
            "no_need_thumb": True, "aeskey": aeskey.hex(), "base_info": self._base_info(),
        })
        if resp is None:
            raise RuntimeError(f"getuploadurl-failed:{why}")
        full = (resp.get("upload_full_url") or "").strip()
        param = resp.get("upload_param")
        url = full or f"{self.CDN_BASE}/upload?encrypted_query_param={urllib.parse.quote(str(param or ''))}&filekey={urllib.parse.quote(filekey)}"
        if not full and not param:
            raise RuntimeError("getuploadurl-no-upload-url")
        # AES-128-ECB PKCS7
        padder = padding.PKCS7(128).padder()
        data = padder.update(plaintext) + padder.finalize()
        enc = Cipher(algorithms.AES(aeskey), modes.ECB()).encryptor()
        ct = enc.update(data) + enc.finalize()
        import urllib.request
        req = urllib.request.Request(url, data=ct, method="POST",
                                     headers={"Content-Type": "application/octet-stream"})
        with urllib.request.urlopen(req, timeout=60) as r:  # noqa: S310
            download_param = r.headers.get("x-encrypted-param")
        if not download_param:
            raise RuntimeError("cdn-missing-x-encrypted-param")
        return {"filekey": filekey, "download_param": download_param, "aeskey_hex": aeskey.hex(),
                "rawsize": rawsize}

    def send_file(self, to_user_id: str, file_path: str, caption: str = "",
                  context_token: str = "") -> None:
        import base64
        import secrets
        from pathlib import Path as P

        up = self.upload_file(file_path, to_user_id)
        items = []
        if caption:
            items.append({"type": ITEM_TEXT, "text_item": {"text": caption}})
        items.append({
            "type": 4,  # MessageItemType.FILE
            "file_item": {
                "media": {
                    "encrypt_query_param": up["download_param"],
                    # 官方实现：aes_key = base64(aeskey十六进制字符串的utf8字节)，逐字节照搬
                    "aes_key": base64.b64encode(up["aeskey_hex"].encode()).decode(),
                    "encrypt_type": 1,
                },
                "file_name": P(file_path).name,
                "len": str(up["rawsize"]),
            },
        })
        for item in items:
            msg = {"from_user_id": "", "to_user_id": to_user_id,
                   "client_id": f"tangram-{secrets.token_hex(8)}",
                   "message_type": MESSAGE_TYPE_BOT, "message_state": STATE_FINISH,
                   "item_list": [item]}
            if context_token:
                msg["context_token"] = context_token
            resp, why = self._post("ilink/bot/sendmessage",
                                   {"msg": msg, "base_info": self._base_info()})
            if resp is None or resp.get("ret"):
                raise RuntimeError(f"send-file-failed:{why}:{str(resp)[:120]}")

    # ---- 入站归一化（官方 msgs 结构：from_user_id + item_list） ----
    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        from_uid = str(raw.get("from_user_id") or "")
        context_token = str(raw.get("context_token") or "")
        texts: list[str] = []
        image = None
        voice = None
        for item in raw.get("item_list") or []:
            t = item.get("type")
            if t == ITEM_TEXT:
                texts.append(str((item.get("text_item") or {}).get("text") or ""))
            elif t == ITEM_IMAGE:
                image = item.get("image_item") or {}
            elif t == ITEM_VOICE:
                vi = item.get("voice_item") or {}
                # 官方插件同款：voice_item.text = 微信平台内置"语音转文字"结果，直接采用
                if vi.get("text"):
                    texts.append(str(vi["text"]))
                voice = vi
        text = "\n".join(x for x in texts if x)
        if voice:
            modality, payload = "voice", {"url": str(voice.get("url") or voice.get("file_url") or ""),
                                          "text": str(voice.get("text") or "") or text,
                                          "context_token": context_token}
        elif image and not text:
            modality, payload = "image", {"url": str(image.get("url") or ""),
                                          "context_token": context_token}
        else:
            modality, payload = "text", (text if not context_token else
                                         {"text": text, "context_token": context_token})
        return MultimodalMessage(
            user_id=from_uid,
            platform=self.name,
            modality=modality,
            payload=payload,
            ts=float(raw.get("create_time_ms", now_ts() * 1000)) / 1000.0,
            message_id=str(raw.get("message_id") or ""),
        )

    def connect(self, account: Any) -> None:
        return None

    def start(self) -> None:
        return None

    def stop(self) -> None:
        return None
