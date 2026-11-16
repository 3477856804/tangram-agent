"""真实语音转文字（ASR）。

设计原则（与全项目一致）：
- 绝不伪造识别结果。任何一条路径无法产出真实文字时，明确抛错或返回 None，
  并给出可执行的修复指引（装哪个包 / 配哪个环境变量）。
- 三条真实后端，按可用性自动选择，也可由环境变量强制：
    1) 本地 faster-whisper（推荐，CPU 可跑，TANGRAM_ASR_BACKEND=faster）
    2) 本地 openai-whisper（TANGRAM_ASR_BACKEND=whisper）
    3) 在线 OpenAI 兼容 /audio/transcriptions（配置了 TANGRAM_ASR_API_BASE
       时优先使用，兼容硅基流动 / 本地 whisper-server / OpenAI 等）
- 输入统一为「音频字节」；解码成 16k mono PCM 由网关 im/serve.py 的
  to_pcm16k 完成，这里同时兼容直接接收 PCM 与原始音频字节。

环境变量：
    TANGRAM_ASR_BACKEND      auto | faster | whisper | online
    TANGRAM_ASR_MODEL        faster/whisper 模型名，默认 base
    TANGRAM_ASR_LANG         语言，默认 zh；空串表示自动检测
    TANGRAM_ASR_API_BASE     在线 ASR base URL（如 https://api.siliconflow.cn/v1）
    TANGRAM_ASR_API_KEY      在线 ASR key
    TANGRAM_ASR_MODEL        在线模式同时用作 model 名
"""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import wave
from typing import Callable, Optional

# transcribe(bytes) -> str，由 whisper_transcriber 返回
Transcriber = Callable[[bytes], str]


class AsrUnavailable(RuntimeError):
    """没有可用的真实 ASR 后端。携带可执行的安装/配置指引。"""


def _decode_to_pcm16k(data: bytes) -> Optional[bytes]:
    """把常见音频容器解码为 16kHz / 单声道 / 16-bit PCM。失败返回 None。"""
    if not data:
        return None
    # WAV：标准库直接解，无需外部依赖
    if data[:4] in (b"RIFF", b"RF64"):
        try:
            with wave.open(io.BytesIO(data)) as w:
                if (w.getframerate() == 16000 and w.getnchannels() == 1
                        and w.getsampwidth() == 2):
                    return w.readframes(w.getnframes())
        except Exception:
            pass
    # 其他容器（mp3/m4a/ogg/webm...）交给 ffmpeg
    if shutil.which("ffmpeg"):
        try:
            proc = subprocess.run(
                ["ffmpeg", "-loglevel", "error", "-i", "pipe:0",
                 "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"],
                input=data, capture_output=True, timeout=60,
            )
            if proc.returncode == 0 and proc.stdout:
                return proc.stdout
        except (OSError, subprocess.SubprocessError):
            pass
    return None


def _pcm_to_wav(pcm: bytes) -> bytes:
    """16k mono s16le PCM 包成 WAV（whisper 在线/本地接口通用输入）。"""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(pcm)
    return buf.getvalue()


def _online_transcriber() -> Optional[Transcriber]:
    """OpenAI 兼容 /audio/transcriptions 的真实在线转写器。"""
    base = (os.environ.get("TANGRAM_ASR_API_BASE") or "").strip()
    key = (os.environ.get("TANGRAM_ASR_API_KEY") or "").strip()
    if not base:
        return None
    try:
        import urllib.request
        import uuid
    except ImportError:  # pragma: no cover - 标准库必存在
        return None

    model = (os.environ.get("TANGRAM_ASR_MODEL") or "whisper-1").strip()
    lang = (os.environ.get("TANGRAM_ASR_LANG") or "").strip()
    endpoint = base.rstrip("/") + "/audio/transcriptions"

    def _call(data: bytes) -> str:
        pcm = _decode_to_pcm16k(data)
        wav = _pcm_to_wav(pcm) if pcm else data
        boundary = "----tangram-asr-" + uuid.uuid4().hex
        fields: list[tuple[str, str]] = [("model", model)]
        if lang:
            fields.append(("language", lang))
        chunks: list[bytes] = []
        for name, value in fields:
            chunks.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n".encode("utf-8")
            )
        chunks.append(
            f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
            'filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'.encode("utf-8")
        )
        chunks.append(wav)
        chunks.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
        body = b"".join(chunks)
        headers = {
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        }
        if key:
            headers["Authorization"] = f"Bearer {key}"
        req = urllib.request.Request(endpoint, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=90) as resp:
            import json
            result = json.loads(resp.read().decode("utf-8", "replace"))
        text = str(result.get("text") or "").strip()
        if not text:
            raise RuntimeError("在线 ASR 返回空文字")
        return text

    return _call


def whisper_transcriber(
    model_size: str = "base",
    language: Optional[str] = "zh",
) -> Optional[Transcriber]:
    """构造一个真实可用的本地 ASR 转写函数；无可用后端返回 None。

    供 im/serve.py 的 module_asr() 使用，保持原有调用签名。
    """
    backend = (os.environ.get("TANGRAM_ASR_BACKEND") or "auto").strip().lower()

    # 在线优先（显式配置时）
    if backend in ("auto", "online"):
        online = _online_transcriber()
        if online is not None:
            return online
        if backend == "online":
            return None

    model = (model_size or "base").strip()
    lang = (language or "").strip() or None

    # faster-whisper：CPU/int8 可跑，质量与速度均衡
    if backend in ("auto", "faster"):
        try:
            from faster_whisper import WhisperModel  # type: ignore

            model_obj = WhisperModel(model, device="cpu", compute_type="int8")

            def _faster(data: bytes) -> str:
                pcm = _decode_to_pcm16k(data)
                if pcm is None:
                    raise RuntimeError("音频解码失败：需要 WAV(16k/mono/s16) 或可用的 ffmpeg")
                import numpy as np
                audio = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
                segments, _info = model_obj.transcribe(
                    audio, language=lang, beam_size=5, vad_filter=True
                )
                text = "".join(seg.text for seg in segments).strip()
                if not text:
                    raise RuntimeError("本地 ASR 未识别出文字（可能是静音或噪声）")
                return text

            return _faster
        except ImportError:
            if backend == "faster":
                return None

    # openai-whisper：纯 PyTorch，体积大但兼容广
    if backend in ("auto", "whisper"):
        try:
            import whisper  # type: ignore

            model_obj = whisper.load_model(model)

            def _whisper(data: bytes) -> str:
                wav = _pcm_to_wav(_decode_to_pcm16k(data) or data)
                tmp = f"/tmp/_tga_asr_{os.getpid()}.wav"
                with open(tmp, "wb") as f:
                    f.write(wav)
                try:
                    result = model_obj.transcribe(tmp, language=lang, fp16=False)
                finally:
                    try:
                        os.remove(tmp)
                    except OSError:
                        pass
                text = str(result.get("text") or "").strip()
                if not text:
                    raise RuntimeError("本地 ASR 未识别出文字（可能是静音或噪声）")
                return text

            return _whisper
        except ImportError:
            if backend == "whisper":
                return None

    return None


def transcribe_audio(data: bytes) -> str:
    """转写音频字节；无真实后端时抛 AsrUnavailable（含修复指引）。"""
    fn = whisper_transcriber()
    if fn is None:
        raise AsrUnavailable(
            "没有可用的语音转文字后端。请任选其一：\n"
            "  1) 在线：设置 TANGRAM_ASR_API_BASE / TANGRAM_ASR_API_KEY"
            "（OpenAI 兼容 /audio/transcriptions，如硅基流动 SenseVoice）\n"
            "  2) 本地：pip install faster-whisper（推荐，CPU int8 可跑）\n"
            "  3) 本地：pip install openai-whisper（需 PyTorch，体积较大）\n"
            "安装后重试；音频解码另需系统 ffmpeg。"
        )
    return fn(data)
