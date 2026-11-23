"""语音能力包：真实 ASR（语音转文字）实现。

不提供任何伪造/占位的识别结果。后端不可用时报错或返回 None，由调用方
如实向上层报告，绝不返回假文字。
"""

from .asr import AsrUnavailable, transcribe_audio, whisper_transcriber
from .provider import (
    BaseVoiceProvider,
    ElevenLabsVoiceProvider,
    LocalVoiceProvider,
    OpenAiCompatibleVoiceProvider,
    VoiceNotConfigured,
    VoiceProviderKind,
    VoiceProviderRegistry,
)

__all__ = [
    "AsrUnavailable",
    "transcribe_audio",
    "whisper_transcriber",
    "BaseVoiceProvider",
    "ElevenLabsVoiceProvider",
    "LocalVoiceProvider",
    "OpenAiCompatibleVoiceProvider",
    "VoiceNotConfigured",
    "VoiceProviderKind",
    "VoiceProviderRegistry",
]
