"""语音后端注册表（Python 侧，与 Dart 的 VoiceProviderRegistry 对齐）。

Rakazo 机制 #2「语音层抽象成 VoiceProvider 接口」的轻量 Python 镜像：
TTS / STT 可插拔后端，默认本地，切换失败回落本地并记原因。

- LocalVoiceProvider：STT 走真实的 backend.voice.asr（本地 faster-whisper /
  openai-whisper / 在线 OpenAI 兼容）；TTS 在后端未接线，如实报错，
  不伪造音频（TTS 真实链路在 Dart 侧走 Edge TTS）。
- OpenAiCompatibleVoiceProvider：STT 走 /audio/transcriptions，TTS 走
  /audio/speech（标准库 urllib，无新依赖）。
- ElevenLabsVoiceProvider：仅 TTS（未接 Scribe），接口层 + 配置。

密钥规则（与 Dart 侧一致）：
- 只从环境变量读取（TANGRAM_VOICE_OPENAI_API_KEY /
  TANGRAM_VOICE_ELEVENLABS_API_KEY），每次调用前一刻才读，不缓存为属性、
  不进日志、不进异常消息、不进 repr；无密钥时抛 VoiceNotConfigured，
  绝不伪造成功。
"""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
import uuid
from enum import Enum
from typing import Callable, Optional

from . import asr as _asr


class VoiceNotConfigured(RuntimeError):
    """语音后端未配置：无密钥 / 无 Base URL。消息里绝不含密钥明文。"""


class VoiceProviderKind(str, Enum):
    LOCAL = "local"
    OPENAI_COMPATIBLE = "openai_compatible"
    ELEVENLABS = "elevenlabs"

    @property
    def label(self) -> str:
        return {
            VoiceProviderKind.LOCAL: "本地",
            VoiceProviderKind.OPENAI_COMPATIBLE: "OpenAI 兼容",
            VoiceProviderKind.ELEVENLABS: "ElevenLabs",
        }[self]


class BaseVoiceProvider:
    """语音后端基类：STT 与 TTS 分离，子类只实现自己真实有的能力。"""

    kind: VoiceProviderKind

    def check_available(self) -> None:
        """快速自检：只查配置在位，不发起网络调用、不消耗配额。"""
        return None

    def transcribe(self, audio: bytes) -> str:
        raise NotImplementedError("该后端未提供语音转文字")

    def synthesize(self, text: str) -> bytes:
        raise NotImplementedError("该后端未提供语音合成")

    def __repr__(self) -> str:  # 绝不含密钥：密钥从不存为属性
        return f"{type(self).__name__}(kind={self.kind.value})"


class LocalVoiceProvider(BaseVoiceProvider):
    """本地后端：STT 走真实 ASR；TTS 后端未接线，如实报错。"""

    kind = VoiceProviderKind.LOCAL

    def __init__(
        self,
        transcriber: Optional[Callable[[bytes], str]] = None,
    ) -> None:
        # 测试可注入假转写函数；默认走真实 asr.transcribe_audio。
        self._transcriber = transcriber

    def transcribe(self, audio: bytes) -> str:
        if not audio:
            raise ValueError("待转写音频为空")
        fn = self._transcriber or _asr.transcribe_audio
        return fn(audio)

    def synthesize(self, text: str) -> bytes:
        raise NotImplementedError(
            "后端本地 TTS 未接线：语音合成请走 Dart 侧 LocalVoiceProvider"
            "（Edge TTS）或配置 OpenAI 兼容 / ElevenLabs 后端"
        )


def _post_multipart(
    url: str,
    fields: dict[str, str],
    file_bytes: bytes,
    headers: dict[str, str],
    timeout: int = 90,
) -> dict:
    boundary = "----tangram-voice-" + uuid.uuid4().hex
    chunks: list[bytes] = []
    for name, value in fields.items():
        chunks.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"'
            f"\r\n\r\n{value}\r\n".encode("utf-8")
        )
    chunks.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
        'filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode("utf-8")
    )
    chunks.append(file_bytes)
    chunks.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
    body = b"".join(chunks)
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            **headers,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"语音请求失败：HTTP {e.code}") from e


def _post_bytes(
    url: str,
    payload: dict,
    headers: dict[str, str],
    timeout: int = 60,
) -> bytes:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={**headers, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise RuntimeError("语音服务密钥无效或已过期，请重新配置") from e
        raise RuntimeError(f"语音请求失败：HTTP {e.code}") from e


class OpenAiCompatibleVoiceProvider(BaseVoiceProvider):
    """OpenAI 兼容后端：STT /audio/transcriptions，TTS /audio/speech。"""

    kind = VoiceProviderKind.OPENAI_COMPATIBLE

    def __init__(
        self,
        base_url: Optional[str] = None,
        stt_model: str = "whisper-1",
        tts_model: str = "tts-1",
        tts_voice: str = "alloy",
    ) -> None:
        self.base_url = (base_url or os.environ.get(
            "TANGRAM_VOICE_OPENAI_BASE_URL", "")).strip().rstrip("/")
        self.stt_model = stt_model
        self.tts_model = tts_model
        self.tts_voice = tts_voice

    def _api_key(self) -> str:
        # 每次调用前一刻才从环境变量读，不缓存、不记录、不进异常消息。
        key = (os.environ.get("TANGRAM_VOICE_OPENAI_API_KEY") or "").strip()
        if not key:
            raise VoiceNotConfigured(
                "OpenAI 兼容语音未配置：请设置 TANGRAM_VOICE_OPENAI_API_KEY"
            )
        return key

    def check_available(self) -> None:
        if not self.base_url:
            raise VoiceNotConfigured(
                "OpenAI 兼容语音未配置：请设置 TANGRAM_VOICE_OPENAI_BASE_URL"
            )
        self._api_key()

    def transcribe(self, audio: bytes) -> str:
        if not audio:
            raise ValueError("待转写音频为空")
        key = self._api_key()
        result = _post_multipart(
            f"{self.base_url}/audio/transcriptions",
            {"model": self.stt_model},
            audio,
            {"Authorization": f"Bearer {key}"},
        )
        text = str(result.get("text") or "").strip()
        if not text:
            raise RuntimeError("语音转写返回空文字")
        return text

    def synthesize(self, text: str) -> bytes:
        if not text.strip():
            raise ValueError("合成文本为空")
        key = self._api_key()
        data = _post_bytes(
            f"{self.base_url}/audio/speech",
            {
                "model": self.tts_model,
                "input": text,
                "voice": self.tts_voice,
                "response_format": "mp3",
            },
            {"Authorization": f"Bearer {key}"},
        )
        if not data:
            raise RuntimeError("语音合成返回空音频")
        return data


class ElevenLabsVoiceProvider(BaseVoiceProvider):
    """ElevenLabs 后端：仅 TTS（未接 Scribe 转写）。"""

    kind = VoiceProviderKind.ELEVENLABS

    # ElevenLabs 公开的示例音色 Rachel；用户应换成自己的音色 ID。
    def __init__(
        self,
        voice_id: str = "21m00Tcm4TlvDq8ikWAM",
        model_id: str = "eleven_multilingual_v2",
    ) -> None:
        self.voice_id = voice_id
        self.model_id = model_id

    def _api_key(self) -> str:
        # 每次调用前一刻才从环境变量读，不缓存、不记录、不进异常消息。
        key = (os.environ.get("TANGRAM_VOICE_ELEVENLABS_API_KEY") or "").strip()
        if not key:
            raise VoiceNotConfigured(
                "ElevenLabs 语音未配置：请设置 TANGRAM_VOICE_ELEVENLABS_API_KEY"
            )
        return key

    def check_available(self) -> None:
        self._api_key()

    def transcribe(self, audio: bytes) -> str:
        raise NotImplementedError(
            "ElevenLabs 本实现只提供语音合成，未接 Scribe 转写"
        )

    def synthesize(self, text: str) -> bytes:
        if not text.strip():
            raise ValueError("合成文本为空")
        key = self._api_key()
        data = _post_bytes(
            f"https://api.elevenlabs.io/v1/text-to-speech/{self.voice_id}",
            {"text": text, "model_id": self.model_id},
            {"xi-api-key": key, "Accept": "audio/mpeg"},
        )
        if not data:
            raise RuntimeError("ElevenLabs 合成返回空音频")
        return data


class VoiceProviderRegistry:
    """语音后端注册表：默认本地；切换自检失败时回落本地并记原因。"""

    def __init__(self, default: Optional[BaseVoiceProvider] = None) -> None:
        self._providers: dict[VoiceProviderKind, BaseVoiceProvider] = {}
        self._current: Optional[BaseVoiceProvider] = default
        self.last_fallback_reason: Optional[str] = None

    def register(self, provider: BaseVoiceProvider) -> None:
        self._providers[provider.kind] = provider
        if self._current is None:
            self._current = provider

    @property
    def current(self) -> BaseVoiceProvider:
        provider = self._current or self._providers.get(
            VoiceProviderKind.LOCAL
        )
        if provider is None:
            raise RuntimeError("语音注册表为空：请先注册至少一个后端（建议本地）")
        return provider

    @property
    def current_kind(self) -> VoiceProviderKind:
        return self.current.kind

    def availability(self) -> dict[VoiceProviderKind, bool]:
        out: dict[VoiceProviderKind, bool] = {}
        for kind, provider in self._providers.items():
            try:
                provider.check_available()
                out[kind] = True
            except Exception:
                out[kind] = False
        return out

    def switch_to(self, kind: VoiceProviderKind) -> BaseVoiceProvider:
        """切换后端；自检失败回落本地并记原因，返回实际生效的后端。"""
        target = self._providers.get(kind)
        if target is None:
            self.last_fallback_reason = f"目标语音后端未注册：{kind.label}"
            return self._fallback()
        try:
            target.check_available()
        except Exception as e:
            self.last_fallback_reason = str(e)
            return self._fallback()
        self._current = target
        return target

    def _fallback(self) -> BaseVoiceProvider:
        local = self._providers.get(VoiceProviderKind.LOCAL)
        if local is not None:
            self._current = local
        return self.current
