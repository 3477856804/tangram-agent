"""Telegram Adapter：Bot API 长轮询 + sendMessage 出站（OpenClaw 同款渠道）。

- 仅标准库（urllib via NetClient），token 从环境变量 TANGRAM_TG_TOKEN 或构造参数注入。
- getUpdates 长轮询在独立线程执行；解析 message -> MultimodalMessage。
- 出站 sendMessage(chat_id, text)。
- API base 可配（TELEGRAM_API_BASE），支持自建 Bot API server（大陆网络环境常用方案）。
- 未配置 token 时 enabled 保持 False：不伪造在线。
"""

from __future__ import annotations

import os
import threading
import time
from typing import Any, Callable, Optional

from ..gateway import Adapter, MultimodalMessage
from ..util import NetClient, now_ts


class TelegramBotAdapter(Adapter):
    name = "telegram"
    enabled = False  # 有 token 才启用（serve 装配时置 True）

    def __init__(self, token: str = "", api_base: str = "") -> None:
        self.token = token or os.environ.get("TANGRAM_TG_TOKEN", "")
        base = api_base or os.environ.get("TELEGRAM_API_BASE", "https://api.telegram.org")
        self.api_base = base.rstrip("/")
        self._net = NetClient(base_url="", timeout=45)
        self._offset: Optional[int] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()

    # ---- 基础调用 ----
    def _call(self, method: str, payload: dict[str, Any]) -> tuple[dict | None, str]:
        url = f"{self.api_base}/bot{self.token}/{method}"
        return self._net.post_json(url, payload)

    @property
    def ready(self) -> bool:
        return bool(self.token)

    def connect(self, account: Any) -> None:
        if not self.ready:
            raise RuntimeError("未配置 TANGRAM_TG_TOKEN，Telegram 渠道不可用（不伪造连接）")
        self.enabled = True

    # ---- inbound 解析 ----
    def parse_inbound(self, raw: dict[str, Any]) -> MultimodalMessage:
        msg = raw.get("message") or raw.get("edited_message") or {}
        chat = msg.get("chat") or {}
        text = str(msg.get("text") or msg.get("caption") or "")
        return MultimodalMessage(
            user_id=str(chat.get("id") or msg.get("from", {}).get("id", "")),
            platform=self.name,
            modality="text" if text else "file",
            payload=text,
            ts=float(msg.get("date", now_ts())),
            message_id=str(msg.get("message_id", "")),
        )

    # ---- outbound ----
    def send_outbound(self, msg: MultimodalMessage) -> None:
        resp, why = self._call(
            "sendMessage", {"chat_id": msg.user_id, "text": str(msg.payload)}
        )
        if resp is None or not resp.get("ok", False):
            raise RuntimeError(f"telegram-send-failed:{why}:{str(resp)[:120]}")

    # ---- 长轮询线程 ----
    def poll_loop(self, on_message: Callable[[dict], None]) -> None:
        """阻塞式轮询 getUpdates；每条新 update 回调 on_message(raw)。"""
        while not self._stop.is_set() and self.ready:
            payload: dict[str, Any] = {"timeout": 25}
            if self._offset is not None:
                payload["offset"] = self._offset + 1
            resp, why = self._call("getUpdates", payload)
            if resp is None or not resp.get("ok", False):
                time.sleep(3)  # 网络/令牌异常退避，不中断线程
                continue
            for upd in resp.get("result", []):
                self._offset = max(self._offset or 0, int(upd.get("update_id", 0)))
                if upd.get("message") or upd.get("edited_message"):
                    on_message(upd)

    def start_polling(self, on_message: Callable[[dict], None]) -> bool:
        if not self.ready or self._thread is not None:
            return False
        self._stop.clear()
        self._thread = threading.Thread(
            target=self.poll_loop, args=(on_message,), daemon=True, name="tg-poll"
        )
        self._thread.start()
        return True

    def start(self) -> None:
        return None

    def stop(self) -> None:
        self._stop.set()
