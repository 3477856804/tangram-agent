/// 本地语音后端：默认后端，无需密钥。
///
///  - STT：委托注入的平台语音识别（默认接线见 tangram_config.dart，
///    即 SpeechToTextVoiceProvider）；离线音频字节转写仍按该实现如实
///    抛 UnsupportedError，不伪造。
///  - TTS：走已实测可出音的 Edge TTS（微软 readaloud 免费端点，
///    见 services/tts_edge.dart），默认音色晓伊。
///  - 自托管 Whisper + Kokoro 是已接线的后端槽位：用户本地跑起
///    whisper-server / Kokoro 后，用
///    `OpenAiCompatibleVoiceProvider.kokoro` 或
///    `VoiceProviderRegistry.registerKokoro`（baseUrl 默认
///    http://localhost:8880/v1）构造并注册，再经 buildTangramConfig
///    的 kokoroBaseUrl / preferredVoiceBackend 启用；本轮不编造该
///    服务已存在——服务未起时调用如实抛错。本地后端默认仍是 Edge TTS。
library;

import 'dart:async';
import 'dart:typed_data';

import '../../services/tts_edge.dart';
import 'voice_provider.dart';

class LocalVoiceProvider implements VoiceProvider {
  LocalVoiceProvider({
    required VoiceProvider stt,
    this.ttsVoice = 'zh-CN-XiaoyiNeural',
  }) : _stt = stt;

  final VoiceProvider _stt;

  /// Edge TTS 音色 ShortName，如 zh-CN-XiaoyiNeural。
  final String ttsVoice;

  @override
  VoiceProviderKind get kind => VoiceProviderKind.local;

  @override
  Future<void> checkAvailable() => _stt.checkAvailable();

  @override
  Stream<VoiceEvent> get conversationEvents => _stt.conversationEvents;

  @override
  bool get isListening => _stt.isListening;

  @override
  bool get isSpeaking => _stt.isSpeaking;

  @override
  Future<void> startConversation() => _stt.startConversation();

  @override
  Future<void> stopConversation() => _stt.stopConversation();

  @override
  Future<String> transcribe(Uint8List audio) => _stt.transcribe(audio);

  @override
  Future<Uint8List> synthesize(String text) =>
      EdgeTts.synthesizeMp3(text, voice: ttsVoice);
}
