"""IM 网关发送接线测试：飞书真实发送路径 + 微信 iLink 默认注册。

全部用 fake/mock，绝不联网、绝不用真实凭据：
- 飞书凭据写进 tmp 的 feishu_bot.json（假 app_id/secret），HTTP 层整体
  monkeypatch 掉 im.feishu_bot._http_json，只断言发出的请求与官方错误回传。
- iLink 凭据文件指向空 tmp 目录；出站走 gateway.reply，网络层 monkeypatch
  掉 adapter._post，只断言报文与门控行为。
"""

from __future__ import annotations

import json

import pytest

from im import feishu_bot
from im.adapters.wechat_ilink import WeChatILinkAdapter
from im.gateway import AgentRuntimeHook, Gateway


# ---------- 飞书发送路径 ----------

def _write_fake_feishu_creds(monkeypatch, tmp_path):
    cred_path = tmp_path / "feishu_bot.json"
    cred_path.write_text(
        json.dumps({"client_id": "cli_fake_app", "client_secret": "sec_fake"},
                   ensure_ascii=False),
        encoding="utf-8",
    )
    monkeypatch.setattr(feishu_bot, "_CRED_PATH", cred_path)
    return cred_path


def test_feishu_send_no_credentials_honest_error(monkeypatch, tmp_path):
    """无凭据文件时诚实报错，不伪造发送。"""
    monkeypatch.setattr(feishu_bot, "_CRED_PATH", tmp_path / "feishu_bot.json")
    with pytest.raises(RuntimeError, match="扫码"):
        feishu_bot.send_text("ou_someone", "hello")


def test_feishu_send_empty_args_rejected(monkeypatch, tmp_path):
    _write_fake_feishu_creds(monkeypatch, tmp_path)
    with pytest.raises(ValueError, match="接收方"):
        feishu_bot.send_text("  ", "hello")
    with pytest.raises(ValueError, match="内容为空"):
        feishu_bot.send_text("ou_someone", "  ")


def test_feishu_send_success_posts_official_endpoints(monkeypatch, tmp_path):
    """成功路径：先取 tenant token，再调 im/v1/messages，返回官方 message_id。"""
    _write_fake_feishu_creds(monkeypatch, tmp_path)
    calls = []

    def fake_http(method, url, body=None, headers=None, timeout=15.0):
        calls.append({"method": method, "url": url, "body": body, "headers": headers})
        if "tenant_access_token" in url:
            return 200, {"code": 0, "tenant_access_token": "t_fake_token",
                         "expire": 7200}
        return 200, {"code": 0, "data": {"message_id": "om_fake_mid"}}

    monkeypatch.setattr(feishu_bot, "_http_json", fake_http)
    mid = feishu_bot.send_text("ou_someone", "你好，飞书")

    assert mid == "om_fake_mid"
    assert len(calls) == 2
    token_call, msg_call = calls
    assert token_call["url"].endswith("/open-apis/auth/v3/tenant_access_token/internal")
    assert token_call["body"] == {"app_id": "cli_fake_app", "app_secret": "sec_fake"}
    assert msg_call["url"].endswith("/open-apis/im/v1/messages?receive_id_type=open_id")
    assert msg_call["headers"]["Authorization"] == "Bearer t_fake_token"
    assert msg_call["body"]["receive_id"] == "ou_someone"
    assert msg_call["body"]["msg_type"] == "text"
    assert json.loads(msg_call["body"]["content"]) == {"text": "你好，飞书"}


def test_feishu_send_chat_id_receive_type(monkeypatch, tmp_path):
    _write_fake_feishu_creds(monkeypatch, tmp_path)
    urls = []

    def fake_http(method, url, body=None, headers=None, timeout=15.0):
        urls.append(url)
        if "tenant_access_token" in url:
            return 200, {"code": 0, "tenant_access_token": "t_fake_token"}
        return 200, {"code": 0, "data": {"message_id": "om_x"}}

    monkeypatch.setattr(feishu_bot, "_http_json", fake_http)
    assert feishu_bot.send_text("oc_group", "hi", receive_id_type="chat_id") == "om_x"
    assert urls[1].endswith("?receive_id_type=chat_id")


def test_feishu_token_error_passed_through_verbatim(monkeypatch, tmp_path):
    """取 token 时官方 code/msg 原样进异常。"""
    _write_fake_feishu_creds(monkeypatch, tmp_path)

    def fake_http(method, url, body=None, headers=None, timeout=15.0):
        return 200, {"code": 10014, "msg": "app_id 不存在"}

    monkeypatch.setattr(feishu_bot, "_http_json", fake_http)
    with pytest.raises(RuntimeError) as ei:
        feishu_bot.send_text("ou_someone", "hello")
    assert "10014" in str(ei.value) and "app_id 不存在" in str(ei.value)


def test_feishu_message_error_passed_through_verbatim(monkeypatch, tmp_path):
    """发消息时官方 code/msg 原样进异常。"""
    _write_fake_feishu_creds(monkeypatch, tmp_path)

    def fake_http(method, url, body=None, headers=None, timeout=15.0):
        if "tenant_access_token" in url:
            return 200, {"code": 0, "tenant_access_token": "t_fake_token"}
        return 200, {"code": 230001, "msg": "receive_id 无效"}

    monkeypatch.setattr(feishu_bot, "_http_json", fake_http)
    with pytest.raises(RuntimeError) as ei:
        feishu_bot.send_text("ou_bad", "hello")
    assert "230001" in str(ei.value) and "receive_id 无效" in str(ei.value)


def test_feishu_session_send_text_delegates(monkeypatch, tmp_path):
    """FeishuBotSession.send_text 复用同一发送路径。"""
    _write_fake_feishu_creds(monkeypatch, tmp_path)

    def fake_http(method, url, body=None, headers=None, timeout=15.0):
        if "tenant_access_token" in url:
            return 200, {"code": 0, "tenant_access_token": "t_fake_token"}
        return 200, {"code": 0, "data": {"message_id": "om_session_mid"}}

    monkeypatch.setattr(feishu_bot, "_http_json", fake_http)
    session = feishu_bot.FeishuBotSession()
    assert session.send_text("ou_someone", "hi") == "om_session_mid"


# ---------- 微信 iLink 默认注册 ----------

def _gateway_with_defaults(monkeypatch, tmp_path):
    """TANGRAM_DATA 指向空 tmp 目录，避免读到真实凭据文件。"""
    monkeypatch.setenv("TANGRAM_DATA", str(tmp_path))
    gw = Gateway(agent_runtime=AgentRuntimeHook(inbox_path=tmp_path / "inbox.jsonl"))
    gw.register_default_adapters()
    return gw


def test_register_default_adapters_includes_ilink(monkeypatch, tmp_path):
    gw = _gateway_with_defaults(monkeypatch, tmp_path)
    assert set(gw.adapters) == {
        "wechat_official", "wechat_unofficial", "qq_official",
        "qq_napcat", "wechat_ilink",
    }
    ilink = gw.adapters["wechat_ilink"]
    assert isinstance(ilink, WeChatILinkAdapter)
    assert ilink.enabled is True  # 类默认：登录态由 has_token 决定
    assert ilink.has_token is False  # 空 tmp 目录，无凭据，不伪造在线
    assert gw.adapters["wechat_unofficial"].enabled is False  # 既有禁用惯例不变


def test_ilink_send_outbound_no_token_honest_failure(monkeypatch, tmp_path):
    """未扫码登录时经网关出站诚实失败，且不触网。"""
    gw = _gateway_with_defaults(monkeypatch, tmp_path)
    ok, reason = gw.reply("wechat_ilink", "wxid_u1", "hello")
    assert ok is False
    assert reason.startswith("send-error")
    assert "扫码" in reason


def test_ilink_send_outbound_via_gateway_mocked(monkeypatch, tmp_path):
    """有 token 时经 risk 门控真实下发 sendmessage 报文（网络层 mock）。"""
    gw = _gateway_with_defaults(monkeypatch, tmp_path)
    ilink = gw.adapters["wechat_ilink"]
    ilink.token = "fake_bot_token"
    posted = []

    def fake_post(endpoint, payload, timeout=40):
        posted.append((endpoint, payload))
        return {"ret": 0}, "ok"

    monkeypatch.setattr(ilink, "_post", fake_post)
    ok, reason = gw.reply("wechat_ilink", "wxid_u1", "你好，微信")

    assert (ok, reason) == (True, "sent")
    assert len(posted) == 1
    endpoint, payload = posted[0]
    assert endpoint == "ilink/bot/sendmessage"
    msg = payload["msg"]
    assert msg["to_user_id"] == "wxid_u1"
    assert msg["item_list"] == [{"type": 1, "text_item": {"text": "你好，微信"}}]
    assert gw.stats()["outbound"] == 1


def test_ilink_send_outbound_official_error_reported(monkeypatch, tmp_path):
    """官方 ret 非零时经网关如实返回 send-error，不谎称已发。"""
    gw = _gateway_with_defaults(monkeypatch, tmp_path)
    ilink = gw.adapters["wechat_ilink"]
    ilink.token = "fake_bot_token"
    monkeypatch.setattr(
        ilink, "_post",
        lambda endpoint, payload, timeout=40: ({"ret": 1001, "errmsg": "官方拒绝"}, "ok"),
    )
    ok, reason = gw.reply("wechat_ilink", "wxid_u1", "hello")
    assert ok is False
    assert "1001" in reason and "官方拒绝" in reason


def test_ilink_disabled_blocks_without_network(monkeypatch, tmp_path):
    """禁用后出站被门控拦截，网络层一次也不碰。"""
    gw = _gateway_with_defaults(monkeypatch, tmp_path)
    ilink = gw.adapters["wechat_ilink"]
    ilink.token = "fake_bot_token"

    def _boom(*a, **k):
        raise AssertionError("disabled adapter must not touch network")

    monkeypatch.setattr(ilink, "_post", _boom)
    gw.set_adapter_enabled("wechat_ilink", False)
    ok, reason = gw.reply("wechat_ilink", "wxid_u1", "hello")
    assert (ok, reason) == (False, "adapter-disabled:wechat_ilink")
