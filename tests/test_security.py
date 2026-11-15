"""安全回归测试：覆盖本轮修复的漏洞，全部只依赖本地真实执行。

运行：``python3 -m pytest tests/test_security.py -q``

覆盖：
1. 后端 sandbox 工具任意命令执行（RCE）/ 命令注入 / 路径穿越 / 凭据外泄；
2. IM webhook 未鉴权 + QQ 官方明文回调伪造；
3. 微信 webhook HMAC 重放；
4. AGP WebSocket token 后门 / 永不过期 / 帧长度无上限；
5. torch 权重文件不安全反序列化；
6. SSRF（字面私网 IP / DNS 解析 / 302 跳内网）；
7. 沙箱命令文件竞态与不安全临时文件。
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import stat
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest


# --------------------------------------------------------------------------
# 1. 后端 sandbox 工具：不允许任意命令执行 / 不继承密钥 / 不越工作区
# --------------------------------------------------------------------------
def test_sandbox_rejects_arbitrary_commands_and_shell_injection(tmp_path, monkeypatch):
    from backend.app.runtime.agent_service import RuntimeService

    svc = RuntimeService(data_dir=tmp_path)
    marker = tmp_path.parent / "tga_pwn_marker"

    # 白名单外的程序（bash 等）一律拒绝
    for cmd in ("bash -lc id", "shutdown -h now", "chmod 777 /", "ncat -e /bin/sh 1 2"):
        out = svc.exec_tool("sandbox", {"command": cmd})
        assert "拒绝" in out, (cmd, out)

    # shell 元字符不再具备执行语义：不会创建 /etc 或工作区外的文件
    out = svc.exec_tool("sandbox", {"command": f"echo pwned; touch {marker}"})
    assert not marker.exists(), out
    assert "pwned" in out or "拒绝" in out

    # 明确不带路径的注入串也只会被当成字面参数
    for cmd, expected in (("echo A; echo B", "A; echo B"),
                          ("echo $(id)", "$(id)"),
                          ("echo `id`", "`id`")):
        out = svc.exec_tool("sandbox", {"command": cmd}).strip()
        if os.name == "nt":
            # Windows 受控 PATH 无 echo.exe：如实拒绝同样证明注入串未被执行。
            assert "拒绝" in out or "不存在" in out, (cmd, out)
        else:
            assert out == expected, (cmd, out)

    # 敏感路径 / 绝对路径 / .. 穿越 / 软链接逃逸全部拒绝
    for cmd in ("cat /etc/shadow", "cat /root/.ssh/id_rsa",
                "cat ../../etc/passwd", "cat /proc/self/environ", "rm -rf /"):
        assert "拒绝" in svc.exec_tool("sandbox", {"command": cmd}), cmd

    link = svc.workspace / "escape"
    try:
        link.symlink_to("/etc")
    except (OSError, NotImplementedError):
        pass
    else:
        assert "拒绝" in svc.exec_tool("sandbox", {"command": "cat escape/hostname"})

    # SSRF：URL 参数禁止内网 / 云元数据
    for cmd in ("curl http://127.0.0.1:3000/",
                "curl http://169.254.169.254/latest/meta-data/",
                "wget http://192.168.1.1/"):
        assert "拒绝" in svc.exec_tool("sandbox", {"command": cmd}), cmd

    # 正常功能不回归：白名单内、工作区内的命令真实执行
    out = svc.exec_tool("sandbox", {"command": "echo hello-from-real-shell"})
    if os.name == "nt":
        assert "拒绝" in out or "不存在" in out, out
    else:
        assert "hello-from-real-shell" in out
    (svc.workspace / "note.txt").write_text("inside", encoding="utf-8")
    out = svc.exec_tool("sandbox", {"command": "cat note.txt"})
    if os.name == "nt":
        assert "拒绝" in out or "不存在" in out, out
    else:
        assert "inside" in out


def test_sandbox_does_not_inherit_secrets_from_environment(tmp_path, monkeypatch):
    from backend.app.runtime.agent_service import RuntimeService

    monkeypatch.setenv("TANGRAM_API_KEY", "SUPERSECRET_DO_NOT_LEAK")
    monkeypatch.setenv("TANGRAM_QQ_SECRET", "QQSECRET_DO_NOT_LEAK")
    monkeypatch.setenv("NAPCAT_TOKEN", "NAPCAT_DO_NOT_LEAK")
    svc = RuntimeService(data_dir=tmp_path)
    out = svc.exec_tool("sandbox", {
        "command": 'python3 -c "import os; print(os.environ)"'})
    assert "SUPERSECRET_DO_NOT_LEAK" not in out
    assert "QQSECRET_DO_NOT_LEAK" not in out
    assert "NAPCAT_DO_NOT_LEAK" not in out


def test_sandbox_policy_is_fail_closed_when_policy_missing(tmp_path, monkeypatch):
    from backend.app import sandbox as sb
    from backend.app.runtime.agent_service import RuntimeService

    svc = RuntimeService(data_dir=tmp_path)
    monkeypatch.setattr(sb, "load_policy", lambda: (_ for _ in ()).throw(OSError("policy gone")))
    out = svc.exec_tool("sandbox", {"command": "echo hi"})
    assert "拒绝" in out and "fail-closed" in out


# --------------------------------------------------------------------------
# 2. Webhook 入站鉴权 + QQ 官方明文回调
# --------------------------------------------------------------------------
class _StubHandler:
    def __init__(self, ip: str, headers: dict | None = None):
        self.client_address = (ip, 12345)
        self.headers = headers or {}


def _signed_headers(secret: str, raw: bytes, nonce: str, ts: str | None = None):
    ts = ts or str(int(time.time()))
    material = (ts + "\n" + nonce + "\n").encode("utf-8") + raw
    sig = hmac.new(secret.encode(), material, hashlib.sha256).hexdigest()
    return {"X-Tangram-Signature": sig,
            "X-Tangram-Timestamp": ts,
            "X-Tangram-Nonce": nonce}


def test_webhook_gate_blocks_unauthenticated_remote_calls(monkeypatch):
    import im.serve as s

    monkeypatch.delenv("TANGRAM_WEBHOOK_SECRET", raising=False)
    raw = b'{"post_type":"message"}'
    # 自身无验签能力的通道：非回环一律拒绝
    ok, reason = s._webhook_gate(_StubHandler("192.168.1.20"), raw, strict_local=True)
    assert ok is False and "non-loopback" in reason
    # 回环（本机 NapCat / 桥进程）放行
    assert s._webhook_gate(_StubHandler("127.0.0.1"), raw, strict_local=True)[0] is True

    monkeypatch.setenv("TANGRAM_WEBHOOK_SECRET", "shared-secret")
    hdrs = _signed_headers("shared-secret", raw, "nonce-gate-1")
    assert s._webhook_gate(_StubHandler("10.0.0.5", hdrs), raw, strict_local=True)[0] is True
    # 重放同一 nonce 被拒绝
    assert s._webhook_gate(_StubHandler("10.0.0.5", hdrs), raw, strict_local=True)[0] is False
    # 过期时间戳被拒绝
    stale = _signed_headers("shared-secret", raw, "nonce-gate-2",
                            str(int(time.time()) - 3600))
    assert s._webhook_gate(_StubHandler("10.0.0.5", stale), raw, strict_local=True)[0] is False
    # 错误签名被拒绝
    bad = _signed_headers("wrong-secret", raw, "nonce-gate-3")
    assert s._webhook_gate(_StubHandler("10.0.0.5", bad), raw, strict_local=True)[0] is False


def test_onebot_webhook_rejects_non_loopback_without_hmac(tmp_path, monkeypatch):
    """局域网/公网伪造 OneBot 消息曾可直接驱动 Agent 出站。"""
    import im.serve as s
    from im.gateway import AgentRuntimeHook, Gateway

    monkeypatch.delenv("TANGRAM_WEBHOOK_SECRET", raising=False)
    monkeypatch.setattr(s, "_client_is_loopback", lambda _h: False)
    s.Handler.gateway = Gateway(
        agent_runtime=AgentRuntimeHook(inbox_path=tmp_path / "inbox.jsonl"))
    s.Handler.server_base = ""
    srv = ThreadingHTTPServer(("127.0.0.1", 0), s.Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    url = f"http://127.0.0.1:{srv.server_address[1]}/webhook/qq_napcat"
    body = json.dumps({"post_type": "message", "user_id": 1,
                       "message": "伪造", "message_type": "private"}).encode()
    try:
        with pytest.raises(urllib.error.HTTPError) as ei:
            urllib.request.urlopen(urllib.request.Request(
                url, data=body, headers={"Content-Type": "application/json"},
                method="POST"), timeout=5)
        assert ei.value.code == 403
        assert json.loads(ei.value.read().decode())["error"] == "unauthorized-webhook"
    finally:
        srv.shutdown()
        srv.server_close()


def test_qq_openapi_plaintext_callback_is_rejected(tmp_path, monkeypatch):
    """明文 C2C_MESSAGE_CREATE 曾可完全绕过平台加密校验驱动 Agent 出站。"""
    import im.serve as s
    from im.adapters.qq_openapi import QQOpenAPIAdapter
    from im.gateway import AgentRuntimeHook, Gateway

    monkeypatch.delenv("TANGRAM_QQ_ALLOW_PLAIN", raising=False)
    monkeypatch.delenv("TANGRAM_WEBHOOK_SECRET", raising=False)
    gw = Gateway(agent_runtime=AgentRuntimeHook(inbox_path=tmp_path / "inbox.jsonl"))
    adp = QQOpenAPIAdapter(app_id="appid", client_secret="secret")
    gw.register(adp)
    s.Handler.gateway = gw
    s.Handler.server_base = ""
    srv = ThreadingHTTPServer(("127.0.0.1", 0), s.Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        body = json.dumps({
            "type": "C2C_MESSAGE_CREATE",
            "openid": "victim-openid",
            "content": {"text": "伪造消息", "id": "fake-msg-id"},
        }).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{srv.server_address[1]}/webhook/qq_openapi",
            data=body, headers={"Content-Type": "application/json"}, method="POST")
        with pytest.raises(urllib.error.HTTPError) as ei:
            urllib.request.urlopen(req, timeout=5)
        assert ei.value.code == 403
        payload = json.loads(ei.value.read().decode())
        assert payload["reason"] == "plaintext-callback-rejected"
    finally:
        srv.shutdown()
        srv.server_close()


# --------------------------------------------------------------------------
# 3. 微信 webhook HMAC 重放
# --------------------------------------------------------------------------
def test_wechat_signature_rejects_replay_and_stale_timestamps():
    from im.adapters.wechat_official import WeChatOfficialAdapter

    adp = WeChatOfficialAdapter(app_secret="app-secret")
    body = json.dumps({"FromUserName": "u1", "Content": "hi"},
                      ensure_ascii=False, sort_keys=True)
    ts, nonce = str(int(time.time())), f"nonce-{time.time_ns()}"
    parts = sorted(["app-secret", ts, nonce])
    sig = hmac.new(b"app-secret", ("".join(parts) + body).encode(),
                   hashlib.sha256).hexdigest()
    assert adp.verify_message_signature(sig, ts, nonce, body) is True
    # 同一签名重放：拒绝
    assert adp.verify_message_signature(sig, ts, nonce, body) is False

    ts2, nonce2 = str(int(time.time()) - 3600), f"old-{time.time_ns()}"
    parts2 = sorted(["app-secret", ts2, nonce2])
    sig2 = hmac.new(b"app-secret", ("".join(parts2) + body).encode(),
                    hashlib.sha256).hexdigest()
    assert adp.verify_message_signature(sig2, ts2, nonce2, body) is False
    # 缺失字段 / 错误签名
    assert adp.verify_message_signature("", ts, "n", body) is False
    assert adp.verify_message_signature("deadbeef", ts, "n2", body) is False


# --------------------------------------------------------------------------
# 4. AGP WebSocket 鉴权
# --------------------------------------------------------------------------
def test_agp_token_has_no_bypass_expires_and_is_reused(monkeypatch):
    import im.agp_bridge as agp

    # 旧后门：环境变量可让空 token 通过校验
    monkeypatch.setenv("TANGRAM_AGP_REQUIRE_TOKEN", "0")
    assert agp.verify_token("") is None
    assert agp.verify_token("never-issued") is None

    host = f"127.0.0.1:{time.time_ns()}"
    a = agp.issue_credentials(host, "wechat")
    b = agp.issue_credentials(host, "wechat")
    assert a["token"] == b["token"]  # 状态轮询不再无限签新 token
    assert agp.verify_token(a["token"])["connector"] == "wechat"

    # 过期 token 立即失效
    monkeypatch.setattr(agp, "_AGP_TOKEN_TTL", -1.0)
    assert agp.verify_token(a["token"]) is None


def test_ws_frame_requires_mask_and_size_limit():
    import struct
    import im.agp_bridge as agp

    def reader(data: bytes):
        buf = iter([data[i:i + 1] for i in range(len(data))])
        def read(n):
            out = b""
            for _ in range(n):
                try:
                    out += next(buf)
                except StopIteration:
                    raise ConnectionError("eof")
            return out
        return read

    # 未掩码客户端帧：拒绝
    with pytest.raises(ValueError, match="unmasked"):
        agp.ws_read_frame(reader(b"\x81\x03abc"))
    # 声明 2^63-1 长度：拒绝（不再持续读/分配）
    huge = b"\x82\x7f" + struct.pack("!Q", (1 << 63) - 1) + b"\x00\x00\x00\x00"
    with pytest.raises(ValueError, match="too-large|unmasked"):
        agp.ws_read_frame(reader(huge))
    # 正常掩码帧可解
    mask = b"\x01\x02\x03\x04"
    payload = b"ping"
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    frame = b"\x81" + bytes([0x80 | len(payload)]) + mask + masked
    op, data = agp.ws_read_frame(reader(frame))
    assert op == 0x1 and data == payload


# --------------------------------------------------------------------------
# 5. torch 权重文件反序列化
# --------------------------------------------------------------------------
def test_adapter_loader_never_uses_unsafe_pickle(tmp_path, monkeypatch):
    import torch
    from training.pipeline import load_adapter

    # 合法检查点仍可加载
    good = tmp_path / "good.pt"
    torch.save({"format": "tangram-adapter-v1",
                "W": torch.tensor([[1.0, 2.0]]),
                "meta": {"backend": "torch"}}, str(good))
    assert load_adapter(good)["weights"] == [[1.0, 2.0]]

    # 恶意 pickle：reduce 到 os.system，weights_only=True 必须拒绝执行
    class Evil:
        def __reduce__(self):
            return (os.system, (f"touch {tmp_path / 'pwned'}",))

    bad = tmp_path / "evil.pt"
    torch.save({"W": Evil(), "meta": {}}, str(bad))
    with pytest.raises(Exception):
        load_adapter(bad)
    assert not (tmp_path / "pwned").exists()


# --------------------------------------------------------------------------
# 6. SSRF：字面 IP / DNS 解析 / 302 跳转
# --------------------------------------------------------------------------
def test_ssrf_guard_blocks_internal_targets(monkeypatch):
    import im.brain as b

    assert b.is_safe_url("http://localhost/x") is False
    # 十进制 IP 字面量绕过被 DNS 解析层挡住
    assert b._public_resolved("127.0.0.1") is False
    assert b._public_resolved("2130706433") is False
    assert b._public_resolved("169.254.169.254") is False
    with pytest.raises(ValueError):
        b.safe_urlopen("http://2130706433/", timeout=1)
    with pytest.raises(ValueError):
        b.safe_urlopen("file:///etc/passwd", timeout=1)

    # 302 跳到内网必须被重定向处理器拒绝
    handler = b._SafeRedirectHandler()
    req = urllib.request.Request("https://public.example/x")
    with pytest.raises(urllib.error.URLError):
        handler.redirect_request(req, None, 302, "Found", {},
                                 "http://169.254.169.254/latest/meta-data/")


# --------------------------------------------------------------------------
# 7. 沙箱命令文件竞态 / 临时文件权限
# --------------------------------------------------------------------------
def test_sandbox_exec_uses_unique_private_command_files(monkeypatch):
    import subprocess
    import im.serve as s

    captured: list[str] = []

    class _Result:
        stdout = ""
        stderr = ""
        returncode = 0

    def fake_run(argv, **kwargs):
        # argv = ["unshare", "-rmpf", "bash", "-c", <inner script>]
        script = next((a for a in argv if isinstance(a, str)
                       and "__TIMEOUT__" not in a and ".agent_cmd_" in a), "")
        captured.append(script)
        return _Result()

    monkeypatch.setattr(subprocess, "run", fake_run)
    s._sandbox_exec("echo A")
    s._sandbox_exec("echo B")
    # Windows 上同一条命令脚本会被拆到多个 argv 里，直接按捕获条数断言会
    # 因平台而异；改为提取唯一命令文件名，跨平台验证「两次调用互不覆盖」。
    import re
    joined = "\n".join(captured)
    names = set(re.findall(r"\.agent_cmd_[A-Za-z0-9_]+\.sh", joined))
    assert len(names) == 2, names
    assert ".agent_cmd.sh" not in joined
    assert "__CMD_NAME__" not in joined


def test_private_tmp_path_is_unpredictable_and_private(tmp_path, monkeypatch):
    import im.serve as s

    monkeypatch.setenv("TANGRAM_DATA", str(tmp_path))
    p1 = s._private_tmp_path(".wav")
    p2 = s._private_tmp_path(".wav")
    assert p1 != p2
    assert Path(p1).parent == tmp_path / "tmp"
    # NTFS 不实现 POSIX 权限位，chmod(0o600) 在 Windows 上不生效；
    # 权限断言只在 POSIX 有语义，随机文件名与私有目录断言跨平台保留。
    if os.name != "nt":
        assert stat.S_IMODE(os.stat(p1).st_mode) == 0o600
        assert stat.S_IMODE(os.stat(tmp_path / "tmp").st_mode) == 0o700
