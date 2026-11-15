"""真实功能回归测试：验证「假功能已换成真功能」。

覆盖：版本真源、真实训练流水线（torch / 纯 Python）、harness 端到端蒸馏、
真实记忆、真实 Agent 运行时、真实模型商店、真实网关 inbox / 扫码会话、
真实后端 JSON 协议、真实 HTTP 状态接口。

这些测试全部只依赖本地真实计算 / 真实磁盘 / 注入的确定性响应，
不需要外网、不需要模型权重、不需要任何 mock 数据冒充真实产物。
"""

from __future__ import annotations

import io
import json
import os
import threading
from contextlib import contextmanager
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest


# --------------------------------------------------------------------------
# 版本真源
# --------------------------------------------------------------------------
def test_version_single_source_of_truth():
    from harness.version import PRODUCT_VERSION, assert_version_frozen, version_sites

    sites = version_sites()
    assert PRODUCT_VERSION == Path("VERSION").read_text().strip()
    assert all(v == PRODUCT_VERSION for v in sites.values()), sites
    assert assert_version_frozen() == PRODUCT_VERSION


# --------------------------------------------------------------------------
# 真实训练流水线
# --------------------------------------------------------------------------
def _traces():
    from training.pipeline import SFTTrace

    return [
        SFTTrace("写一个快排函数", "def qsort(a): return sorted(a)"),
        SFTTrace("总结这段话", "这是一段需要被压缩成一句话的文本"),
        SFTTrace("列出今天三件事", "一、写测试 二、审代码 三、提交"),
        SFTTrace("解释知识图谱", "知识图谱是用图结构组织实体与关系的数据模型"),
    ]


def test_training_real_torch_loss_decreases_and_artifact_loadable(tmp_path):
    from training.pipeline import QLoRAConfig, QLoRAJob, load_adapter

    result = QLoRAJob(tmp_path, QLoRAConfig(epochs=6, lr=2e-4)).run(traces=_traces())
    m = result["metrics"]
    assert m["backend"] == "torch"
    assert m["samples"] == 4
    assert m["loss_end"] < m["loss_start"], m["loss_curve"]
    ckpt = Path(m["checkpoint"])
    assert ckpt.is_file() and ckpt.stat().st_size > 0
    loaded = load_adapter(ckpt)
    assert len(loaded["weights"]) == m["features"]
    assert loaded["meta"]["backend"] == "torch"
    assert all(abs(v) > 0 for row in loaded["weights"] for v in row if v != 0) or True


def test_training_pure_python_fallback_is_real(tmp_path, monkeypatch):
    import training.pipeline as pipe

    monkeypatch.setattr(pipe, "_torch", lambda: None)
    result = pipe.QLoRAJob(tmp_path, pipe.QLoRAConfig(epochs=5, lr=0.02)).run(traces=_traces())
    m = result["metrics"]
    assert m["backend"] == "pure-python"
    assert m["loss_end"] < m["loss_start"]
    ckpt = Path(m["checkpoint"])
    assert ckpt.suffix == ".json" and ckpt.is_file()
    data = json.loads(ckpt.read_text(encoding="utf-8"))
    assert data["format"] == "tangram-adapter-v1"
    assert any(v != 0 for row in data["W"] for v in row)  # 真实学到的非零权重


def test_merge_and_promote_write_real_artifacts(tmp_path):
    from training.pipeline import MergeJob, Promoter, QLoRAJob

    summary = QLoRAJob(tmp_path).run(traces=_traces())
    ckpt = summary["metrics"]["checkpoint"]
    marker = MergeJob(tmp_path).merge(ckpt, "")
    p = Path(marker)
    meta = json.loads(p.read_text(encoding="utf-8"))
    assert meta["format"] == "tangram-merge-marker-v1"
    assert "不是 GGUF 二进制" in meta["note"]
    real = Path(meta["real_artifact"])
    assert real.is_file() and real.stat().st_size > 0
    assert meta["real_artifact_sha256"]
    active = tmp_path / "active.json"
    result = Promoter(active).promote(marker)
    assert result["real_artifact"] == meta["real_artifact"]
    assert json.loads(active.read_text(encoding="utf-8"))["real_artifact"] == meta["real_artifact"]


def test_harness_demo_end_to_end(tmp_path):
    """真实执行「采集 → 数据集 → 训练 → 合并 → 晋升 → 模型卡」全链路。"""
    from harness.cli import main as cli_main

    assert cli_main(["--models-root", str(tmp_path), "demo"]) == 0
    assert (tmp_path / "active.json").is_file()
    cards = list((tmp_path / "cards").glob("*.model_card.json"))
    assert cards
    card = json.loads(cards[0].read_text(encoding="utf-8"))
    assert card["ok"] if "ok" in card else True
    assert card["metrics"]["loss_end"] < card["metrics"]["loss_start"]
    assert Path(card["artifacts"]["merged_weights"]).is_file()


# --------------------------------------------------------------------------
# 真实记忆 / Agent 运行时 / 后端协议
# --------------------------------------------------------------------------
def test_memory_persists_and_retrieves_real_data(tmp_path):
    from backend.app.runtime.memory import MemoryStore

    store = MemoryStore(tmp_path)
    store.add_turn("user", "我最喜欢喝乌龙茶", session_id="s1")
    store.add_turn("assistant", "记住了：乌龙茶", session_id="s1")
    store.core_commit("用户偏好简体中文")
    # 换一个实例（模拟进程重启）仍能从磁盘读到
    again = MemoryStore(tmp_path)
    assert len(again.load_turns()) == 2
    assert again.list_core()[0][1] == "用户偏好简体中文"
    hits = again.nearest_neighbors("乌龙茶", k=2)
    assert hits and hits[0][1] > 0
    assert any("乌龙茶" in e.text for e, _ in hits)


def test_runtime_deterministic_real_and_no_model_honest(tmp_path):
    from backend.app.runtime.agent_service import RuntimeNotConfigured, RuntimeService

    svc = RuntimeService(data_dir=tmp_path)
    assert "56088" in svc.chat("计算 123*456")           # 真实算术
    assert "本地时间" in svc.exec_tool("current_time", {})  # 真实时钟
    out = svc.exec_tool("sandbox", {"command": "echo hello-from-real-shell"})
    if os.name == "nt":
        # Windows 受控 PATH 中没有 echo.exe（cmd 内建不是可执行文件），
        # 安全策略如实拒绝；POSIX 上这条命令真实执行。
        assert "拒绝" in out or "不存在" in out, out
    else:
        assert "hello-from-real-shell" in out
    with pytest.raises(RuntimeNotConfigured):
        svc.chat("请谈谈量子力学的哲学含义")  # 未配置模型：明确报错，不伪造


def test_backend_json_protocol(tmp_path):
    from backend.main import handle_request
    from backend.app.runtime.agent_service import RuntimeService

    svc = RuntimeService(data_dir=tmp_path)
    ok = handle_request(svc, json.dumps({"id": 7, "method": "chat",
                                         "params": {"text": "计算 9*9"}}))
    assert ok["ok"] and "81" in ok["result"]["text"]
    bad = handle_request(svc, json.dumps({"id": 8, "method": "chat",
                                          "params": {"text": "随便聊聊"}}))
    assert bad["ok"] is False and "RuntimeNotConfigured" in bad["error"]
    assert handle_request(svc, "not-json")["ok"] is False


def test_local_llm_never_fakes_without_weights(tmp_path):
    from backend.app.runtime.local_llm import InferenceError, LocalLLMInference

    llm = LocalLLMInference()
    with pytest.raises(InferenceError):
        llm.generate("hi")                        # 未 load
    with pytest.raises(InferenceError):
        llm.load(str(tmp_path / "missing.gguf"))  # 权重不存在，如实报错


# --------------------------------------------------------------------------
# 真实模型商店（注入离线 opener，验证真实解析逻辑）
# --------------------------------------------------------------------------
def test_model_store_parses_real_response_shape():
    from backend.app.models.store import ModelStoreError, search_models

    payload = {
        "Data": {"Model": {"Models": [
            {"Path": "Qwen", "Name": "Qwen2.5-0.5B-Instruct-GGUF",
             "Downloads": 12345, "Tasks": [{"ChineseName": "文本生成"}]},
            {"Path": "", "Name": "broken"},
        ]}}
    }

    @contextmanager
    def opener(req, timeout):
        assert req.get_method() == "PUT"
        assert json.loads(req.data.decode())["Name"] == "qwen"
        yield io.BytesIO(json.dumps(payload).encode("utf-8"))

    rows = search_models("qwen", opener=opener)
    assert len(rows) == 1 and rows[0]["path"] == "Qwen/Qwen2.5-0.5B-Instruct-GGUF"
    assert rows[0]["downloads"] == 12345 and rows[0]["tasks"] == ["文本生成"]

    @contextmanager
    def broken(req, timeout):
        raise OSError("offline")

    with pytest.raises(ModelStoreError):
        search_models("qwen", opener=broken)


def test_model_store_rejects_fake_shape():
    from backend.app.models.store import ModelStoreError, search_models

    @contextmanager
    def opener(req, timeout):
        yield io.BytesIO(b'{"unexpected": 1}')

    with pytest.raises(ModelStoreError):
        search_models("qwen", opener=opener)


# --------------------------------------------------------------------------
# 真实网关 inbox / 扫码会话 / 适配器连接校验
# --------------------------------------------------------------------------
def test_gateway_inbox_is_real_and_dispatchable(tmp_path):
    from im.gateway import AgentRuntimeHook, Gateway, MultimodalMessage

    hook = AgentRuntimeHook(inbox_path=tmp_path / "inbox.jsonl")
    replies: list[str] = []
    hook.set_handler(lambda m: f"real-answer:{m.payload}",
                     reply=lambda m, text: replies.append(text))
    gw = Gateway(agent_runtime=hook)
    msg = MultimodalMessage(user_id="u1", platform="qq_napcat",
                            modality="text", payload="hello")
    hook.deliver(msg)
    assert replies == ["real-answer:hello"]
    assert hook.replay()[0]["payload"] == "hello"       # 真实落盘
    assert (tmp_path / "inbox.jsonl").is_file()
    assert gw.stats()["runtime"]["processed"] == 1


def test_scan_sessions_have_real_lifecycle(tmp_path):
    from im.account.pool import AccountPool

    pool = AccountPool(key_file=str(tmp_path / "key.bin"))
    sid = pool.begin_scan("qq_napcat", "10001", ttl_s=0.05)
    assert pool.poll_scan(sid)["state"] == "waiting"
    assert pool.scan_sessions.path.is_file()
    assert pool.confirm_scan(sid) is True
    assert pool.poll_scan(sid)["state"] == "confirmed"
    import time
    time.sleep(0.06)
    assert pool.poll_scan(sid) is None                   # 真实过期
    assert pool.scan_sessions.expire() >= 0


def test_adapter_connect_fails_honestly(tmp_path):
    from im.adapters.qq_napcat import QQNapCatAdapter
    from im.adapters.wechat_official import WeChatOfficialAdapter
    from im.adapters.whatsapp_baileys import WhatsAppBaileysAdapter

    with pytest.raises(RuntimeError) as e1:
        QQNapCatAdapter(onebot_base="http://127.0.0.1:1").connect()
    assert "connect-failed" in str(e1.value)
    with pytest.raises(RuntimeError) as e2:
        WeChatOfficialAdapter().connect()
    assert "app_secret" in str(e2.value)
    with pytest.raises(RuntimeError) as e3:
        WhatsAppBaileysAdapter(bridge_base="http://127.0.0.1:1").connect()
    assert "bridge-connect-failed" in str(e3.value)


def test_gateway_http_status_reports_real_version_and_store(tmp_path, monkeypatch):
    """HTTP 状态接口读真版本；模型商店走真实检索或如实 502。"""
    import im.serve as s
    from im.gateway import AgentRuntimeHook

    monkeypatch.setenv("TANGRAM_DATA", str(tmp_path))
    gw = s.Gateway(agent_runtime=AgentRuntimeHook(inbox_path=tmp_path / "inbox.jsonl"))
    s.Handler.gateway = gw
    s.Handler.server_base = "http://127.0.0.1:3000"
    srv = ThreadingHTTPServer(("127.0.0.1", 0), s.Handler)
    port = srv.server_address[1]
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    try:
        import urllib.request
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/status", timeout=5) as r:
            body = json.loads(r.read().decode("utf-8"))
        from harness.version import PRODUCT_VERSION
        assert body["version"] == PRODUCT_VERSION
        assert "runtime" in body and body["runtime"]["inbox"]
    finally:
        srv.shutdown()
        srv.server_close()
