"""录音文件转文字（ASR）真实契约测试。

不依赖真实 whisper 模型/网络：用 monkeypatch 注入一个「假转写函数」验证
网关端点的载荷校验与成功/失败契约；同时验证无后端时如实报错、绝不伪造。
"""

from __future__ import annotations

import base64
import io
import json
import wave

import pytest

from backend.voice import asr as asr_mod
from backend.voice.asr import AsrUnavailable, transcribe_audio


def _wav_bytes(frames: int = 1600) -> bytes:
    """生成一段 16k/mono/s16 的静音 WAV（纯结构，不代表识别内容）。"""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\x00\x00" * frames)
    return buf.getvalue()


class _FakeHandler:
    """最小 BaseHTTPRequestHandler 替身，只提供 _asr_transcribe 所需接口。"""

    def __init__(self, loopback: bool = True, headers: dict | None = None):
        self.client_address = ("127.0.0.1" if loopback else "203.0.113.9", 12345)
        self.headers = headers or {}
        self.sent: tuple[int, dict] | None = None

    def bind(self):
        """把真实 Handler._asr_transcribe 绑定到替身实例上。"""
        import im.serve as serve
        self._asr_transcribe = serve.Handler._asr_transcribe.__get__(self, serve.Handler)
        return self

    def _json(self, obj, code=200):
        self.sent = (code, obj)


def test_decode_wav_to_pcm16k():
    pcm = asr_mod._decode_to_pcm16k(_wav_bytes(100))
    assert pcm is not None
    assert len(pcm) == 100 * 2  # s16 mono


def test_no_backend_raises_honest_error(monkeypatch):
    monkeypatch.setattr(asr_mod, "whisper_transcriber", lambda: None)
    with pytest.raises(AsrUnavailable) as ei:
        transcribe_audio(b"anything")
    msg = str(ei.value)
    assert "TANGRAM_ASR_API_BASE" in msg or "faster-whisper" in msg


def test_fake_transcriber_contract(monkeypatch):
    """注入假转写器，验证 transcribe_audio 原样返回真实链路文字。"""
    monkeypatch.setattr(asr_mod, "whisper_transcriber", lambda: (lambda b: "你好世界"))
    assert transcribe_audio(b"audio") == "你好世界"


def test_asr_endpoint_success_with_injected_backend(monkeypatch):
    import im.serve as serve

    monkeypatch.setattr(
        serve, "module_asr", lambda: (lambda b: "今天天气很好")
    )
    # _asr_transcribe 直接调用 backend.voice.asr.transcribe_audio，需一并注入
    monkeypatch.setattr(
        asr_mod, "whisper_transcriber", lambda: (lambda b: "今天天气很好")
    )
    h = _FakeHandler(loopback=True).bind()
    payload = {"audio_b64": base64.b64encode(_wav_bytes(50)).decode()}
    h._asr_transcribe(payload)
    code, body = h.sent
    assert code == 200
    assert body["ok"] is True
    assert body["text"] == "今天天气很好"


def test_asr_endpoint_empty_audio():
    import im.serve as serve

    h = _FakeHandler(loopback=True).bind()
    h._asr_transcribe({})
    code, body = h.sent
    assert code == 400
    assert body["ok"] is False
    assert body["error"] == "empty-audio"


def test_asr_endpoint_bad_base64():
    import im.serve as serve

    h = _FakeHandler(loopback=True).bind()
    h._asr_transcribe({"audio_b64": "!!!not-base64!!!"})
    code, body = h.sent
    assert code == 400
    assert body["error"] == "bad-base64"


def test_asr_endpoint_non_loopback_requires_secret(monkeypatch):
    import im.serve as serve

    monkeypatch.delenv("TANGRAM_WEBHOOK_SECRET", raising=False)
    h = _FakeHandler(loopback=False).bind()
    h._asr_transcribe({"audio_b64": base64.b64encode(b"x").decode()})
    code, body = h.sent
    assert code == 403
    assert body["error"] == "unauthorized"


def test_asr_endpoint_no_backend_returns_hint(monkeypatch):
    """无真实后端时返回 asr-unavailable + 安装指引，不返回假文字。"""
    import im.serve as serve

    monkeypatch.setattr(asr_mod, "whisper_transcriber", lambda: None)
    h = _FakeHandler(loopback=True).bind()
    h._asr_transcribe({"audio_b64": base64.b64encode(_wav_bytes(10)).decode()})
    code, body = h.sent
    assert code == 503
    assert body["error"] == "asr-unavailable"
    assert "text" not in body
    assert "hint" in body and "whisper" in body["hint"]
