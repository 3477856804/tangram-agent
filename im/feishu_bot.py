"""飞书 bot 扫码一键接入（可选依赖 lark-oapi，缺失时如实降级）。

接入方式采用飞书官方「扫码一键创建应用」能力（OAuth 2.0 Device
Authorization Grant / RFC 8628）：

1. ``start_login()`` 在后台线程调用 ``lark_oapi.register_app()``，其
   ``on_qr_code`` 回调给出官方验证 URL（本服务渲染成 PNG 二维码，不伪造）；
2. 用户用飞书扫码并在网页确认后，SDK 返回 ``client_id``(App ID) 与
   ``client_secret``(App Secret)，权限/事件订阅已由 ``app_preset`` 预置；
3. 凭据落盘到 ``TANGRAM_DATA/feishu_bot.json``（权限 0600），随后用
   ``lark_oapi`` 长连接（WebSocket，无需公网回调）收发消息，接入 Gateway。

设计约束：
- 模块导入本身只用标准库；``lark-oapi`` 惰性导入，未安装时所有入口返回
  可读提示，绝不编造「已连接」或假二维码。
- 主动发送不依赖 ``lark-oapi``：``send_text()`` 直接用标准库走飞书官方
  OpenAPI（``tenant_access_token/internal`` 取 token +
  ``im/v1/messages`` 发消息，与 Dart 侧 ``FeishuBotApi.sendText`` 同款端点
  与字段），凭据复用扫码后落盘的 ``feishu_bot.json``；官方 code/msg
  原样回传，绝不静默当成成功。
- 真正扫码需用户持有飞书账号并在真实环境完成，本机无法代扫；本模块的
  自测 ``self_check()`` 只验证「依赖探测 + 状态机 + 落盘」，不触发真实 OAuth。
- 凭据是用户扫码后自己生成的，不写死、不回显到日志。
"""

from __future__ import annotations

import json
import os
import threading
import time
from pathlib import Path
from typing import Any, Callable, Optional

_DATA_DIR = Path(os.environ.get("TANGRAM_DATA", str(Path.home() / ".tangram")))
_CRED_PATH = _DATA_DIR / "feishu_bot.json"
_MIN_VERSION = "1.5.5"

# 飞书官方 OpenAPI 基址（与 Dart 侧 FeishuBotApi.kOpenApiBase 一致）；
# TANGRAM_FEISHU_BASE 仅供自测指向本地桩，与 iLink 的 TANGRAM_ILINK_BASE 同款约定。
OPEN_API_BASE = os.environ.get("TANGRAM_FEISHU_BASE", "https://open.feishu.cn")


def sdk_available() -> tuple[bool, str]:
    """探测 lark-oapi 是否安装且满足最低版本；返回 (可用, 说明)。"""
    try:
        import importlib.metadata
        import importlib.util

        if importlib.util.find_spec("lark_oapi") is None:
            return False, (
                f"飞书接入需要 lark-oapi>={_MIN_VERSION}，当前未安装。"
                "请运行：python -m pip install 'lark-oapi>=" + _MIN_VERSION + "'"
            )
        # lark_oapi 模块未导出 __version__，用发行元数据读取真实版本。
        version = importlib.metadata.version("lark-oapi")

        def _vt(v: str) -> tuple[int, ...]:
            out: list[int] = []
            for p in str(v).split(".")[:3]:
                try:
                    out.append(int(p))
                except ValueError:
                    out.append(0)
            return tuple(out) or (0,)

        if _vt(version) < _vt(_MIN_VERSION):
            return False, (
                f"lark-oapi 版本过低（{version}），需 >={_MIN_VERSION}，"
                "请运行：python -m pip install -U lark-oapi"
            )
        return True, f"lark-oapi {version}"
    except Exception as exc:  # noqa: BLE001
        return False, f"飞书 SDK 探测失败：{exc}"


def load_credentials() -> Optional[dict[str, str]]:
    """读取扫码后落盘的飞书应用凭据；不存在或损坏返回 None。"""
    try:
        data = json.loads(_CRED_PATH.read_text(encoding="utf-8"))
        if data.get("client_id") and data.get("client_secret"):
            return {"client_id": data["client_id"],
                    "client_secret": data["client_secret"]}
    except (OSError, ValueError, AttributeError):
        pass
    return None


def _save_credentials(client_id: str, client_secret: str) -> None:
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    _CRED_PATH.write_text(
        json.dumps({"client_id": client_id, "client_secret": client_secret},
                   ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    try:
        os.chmod(_CRED_PATH, 0o600)
    except OSError:
        pass  # Windows 不支持 POSIX 权限位，凭据仍在用户私有目录


def clear_credentials() -> bool:
    """删除已保存凭据（换号）。仅移除本项目自己的凭据文件。"""
    try:
        _CRED_PATH.unlink(missing_ok=True)
        return True
    except OSError:
        return False


def _http_json(method: str, url: str, body: Optional[dict] = None,
               headers: Optional[dict] = None, timeout: float = 15.0) -> tuple[int, dict]:
    """真实 HTTP JSON 请求；返回 (状态码, 解析后的响应体)。

    与 util.NetClient 不同：错误响应体（官方 code/msg）必须原样带回，
    发送失败时调用方才能转述真实原因（与 qq_official._http_json 同款约定）。
    网络层异常（不可达/超时）如实抛给调用方，不伪造响应。
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


def fetch_tenant_token(client_id: str, client_secret: str,
                       timeout: float = 15.0) -> str:
    """取 tenant_access_token（官方端点，与 Dart 侧 FeishuBotApi 同款）。

    失败时把官方 code/msg 原样放进异常，绝不谎称已拿到 token。
    """
    code, body = _http_json(
        "POST",
        f"{OPEN_API_BASE}/open-apis/auth/v3/tenant_access_token/internal",
        {"app_id": client_id, "app_secret": client_secret},
        timeout=timeout,
    )
    token = str(body.get("tenant_access_token") or "")
    if body.get("code") != 0 or not token:
        raise RuntimeError(
            f"feishu-token-failed:http={code}:code={body.get('code')}:"
            f"{body.get('msg', body.get('message', ''))}"
        )
    return token


def send_text(receive_id: str, text: str, receive_id_type: str = "open_id",
              timeout: float = 15.0) -> str:
    """主动发一条文本消息；成功返回官方 message_id。

    凭据只从扫码后落盘的 ``feishu_bot.json`` 读取（复用现有 session 的
    凭据流程），绝不写死、绝不接受调用方传入的明文凭据；未登录时诚实报错。
    ``receive_id_type`` 取 open_id / chat_id / user_id / email（官方枚举）。
    官方错误（code/msg）原样放进异常，不静默当成成功。
    """
    if not receive_id or not receive_id.strip():
        raise ValueError("feishu-send: 缺少接收方（open_id / chat_id）")
    if not text or not text.strip():
        raise ValueError("feishu-send: 消息内容为空")
    cred = load_credentials()
    if cred is None:
        raise RuntimeError("feishu-send: 尚未完成飞书扫码登录（无凭据，不伪造发送）")
    token = fetch_tenant_token(cred["client_id"], cred["client_secret"], timeout=timeout)
    code, body = _http_json(
        "POST",
        f"{OPEN_API_BASE}/open-apis/im/v1/messages?receive_id_type={receive_id_type}",
        {
            "receive_id": receive_id,
            "msg_type": "text",
            "content": json.dumps({"text": text}, ensure_ascii=False),
        },
        headers={"Authorization": f"Bearer {token}"},
        timeout=timeout,
    )
    if body.get("code") == 0:
        data = body.get("data") or {}
        return str(data.get("message_id") or "")
    raise RuntimeError(
        f"feishu-send-failed:http={code}:code={body.get('code')}:"
        f"{body.get('msg', body.get('message', ''))}"
    )


class FeishuBotSession:
    """飞书扫码登录 + 长连接的会话状态机（供 Handler 线程安全访问）。"""

    # app_preset 只接受 name / desc / avatar（见 lark_oapi.scene.registration）
    _APP_PRESET = {
        "name": "TGA {user} 的助手",
        "desc": "由 Tangram Agent 扫码创建，权限与事件已自动预置",
    }

    # scopes / events / callbacks 必须放 addons，结构经 SDK _normalize_addons 校验
    _ADDONS = {
        "scopes": {
            "tenant": [
                "im:message:send_as_bot", "im:message:readonly",
                "im:message.p2p_msg:readonly", "im:message.group_at_msg:readonly",
                "im:resource", "application:bot.basic_info:read",
            ],
        },
        "events": {"items": {"tenant": ["im.message.receive_v1"]}},
        "callbacks": {"items": ["card.action.trigger"]},
    }

    def __init__(self, on_connected: Optional[Callable[[dict[str, str]], None]] = None) -> None:
        self._lock = threading.Lock()
        self.state = "idle"
        self.qr_url = ""
        self.expire_in = 0
        self.error = ""
        self._thread: Optional[threading.Thread] = None
        self._on_connected = on_connected

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "ok": True,
                "status": {"idle": "waiting", "waiting_scan": "waiting",
                           "scanned": "scanned", "logged_in": "confirmed",
                           "expired": "expired", "error": "error"}.get(self.state, "waiting"),
                "login_state": self.state,
                "qr_url": self.qr_url,
                "expire_in": self.expire_in,
                "error": self.error,
                "logged_in": self.state == "logged_in",
            }

    def begin(self) -> dict[str, Any]:
        """发起扫码登录；返回给 APP 的票据（含官方验证 URL）。"""
        ok, msg = sdk_available()
        if not ok:
            with self._lock:
                self.state, self.error = "error", msg
            return {"ok": False, "reason": msg, "hint": msg}

        cred = load_credentials()
        if cred is not None:
            with self._lock:
                self.state, self.error = "logged_in", ""
            self._connect_long_lived(cred)
            return {"ok": True, "already_logged_in": True}

        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return self.snapshot()
            self.state, self.error, self.qr_url = "waiting_scan", "", ""
            self._thread = threading.Thread(
                target=self._register, daemon=True, name="feishu-register")
            self._thread.start()
        # 等待 on_qr_code 回填 URL（最多 8 秒）
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            with self._lock:
                if self.qr_url or self.state == "error":
                    return self.snapshot()
            time.sleep(0.1)
        return self.snapshot()

    def send_text(self, receive_id: str, text: str,
                  receive_id_type: str = "open_id", timeout: float = 15.0) -> str:
        """主动发一条文本消息；成功返回官方 message_id。

        复用模块级 ``send_text``（标准库直调官方 OpenAPI，不依赖 lark-oapi
        长连接）；凭据只读落盘文件，未登录/官方错误均如实抛异常。
        """
        return send_text(receive_id, text, receive_id_type=receive_id_type,
                         timeout=timeout)

    def _register(self) -> None:
        """后台跑官方设备授权流，阻塞轮询直到扫码确认/过期。"""
        try:
            import lark_oapi as lark  # type: ignore

            def on_qr(info: dict) -> None:
                with self._lock:
                    self.qr_url = str(info.get("url", ""))
                    self.expire_in = int(info.get("expire_in", 0) or 0)
                    self.state = "waiting_scan"

            def on_status(info: dict) -> None:
                s = str(info.get("status", ""))
                with self._lock:
                    if s == "scanned":
                        self.state = "scanned"

            result = lark.register_app(
                on_qr_code=on_qr, on_status_change=on_status,
                source="tangram-gateway", app_preset=self._APP_PRESET,
                addons=self._ADDONS,
            )
            cid = str(result.get("client_id", ""))
            sec = str(result.get("client_secret", ""))
            if not cid or not sec:
                raise RuntimeError("飞书未返回完整 App ID / App Secret")
            _save_credentials(cid, sec)
            with self._lock:
                self.state, self.error = "logged_in", ""
            self._connect_long_lived({"client_id": cid, "client_secret": sec})
        except Exception as exc:  # noqa: BLE001
            with self._lock:
                self.state = "error"
                self.error = str(exc)[:300]
                self._thread = None

    def _connect_long_lived(self, cred: dict[str, str]) -> None:
        """拿到凭据后启动长连接接收消息（回调交给上层接 Gateway）。"""
        if self._on_connected is not None:
            try:
                self._on_connected(cred)
            except Exception:  # noqa: BLE001
                pass


def self_check() -> dict:
    """离线自测：依赖探测 + 状态机 + 凭据落盘（不触发真实 OAuth、不联网扫码）。"""
    ok, msg = sdk_available()
    session = FeishuBotSession()
    snap = session.snapshot()
    saved = load_credentials()
    return {
        "sdk_available": ok,
        "sdk_message": msg,
        "initial_state": snap["status"],
        "no_fake_qr": snap["qr_url"] == "",
        "credentials_present": saved is not None,
        "cred_path": str(_CRED_PATH),
    }


if __name__ == "__main__":
    print(json.dumps(self_check(), ensure_ascii=False))
