import 'dart:typed_data';

sealed class VoiceEvent {
  const VoiceEvent();
}

class VoiceTranscript extends VoiceEvent {
  const VoiceTranscript(this.text);
  final String text;
}

class VoiceAudio extends VoiceEvent {
  const VoiceAudio(this.audio);
  final Uint8List audio;
}

/// 录音中的实时声级：平台真实麦克风声级归一化到 0.0（静音）~ 1.0（满幅）。
/// 只由真正采集到麦克风声级的实现发出；没有声级来源时不发本事件，
/// 界面继续如实显示「振幅未接入」，绝不用合成数据冒充。
class VoiceAmplitude extends VoiceEvent {
  const VoiceAmplitude(this.level);
  final double level;
}

class VoiceConversationDone extends VoiceEvent {
  const VoiceConversationDone();
}

class VoiceError extends VoiceEvent {
  const VoiceError(this.message);
  final String message;
}

/// 语音后端种类：TTS / STT 可插拔的后端标识。
///
/// 与 Rakazo「语音层抽象成 VoiceProvider 接口」（ElevenLabs / OpenAI /
/// 自托管 Whisper+Kokoro 可换）对齐的轻量 Dart 实现，不搬重型栈。
enum VoiceProviderKind {
  /// 本地：STT 走平台语音识别，TTS 走已实测的 Edge TTS（免密钥）。
  local('本地', '无需配置，开箱即用'),

  /// OpenAI 兼容：/audio/transcriptions 与 /audio/speech，密钥存安全存储。
  openAiCompatible('OpenAI 兼容', '需在安全存储中配置 API Key 与 Base URL'),

  /// ElevenLabs：仅 TTS（本实现未接 Scribe 转写），密钥存安全存储。
  elevenLabs('ElevenLabs', '需在安全存储中配置 API Key');

  const VoiceProviderKind(this.label, this.configHint);
  final String label;
  final String configHint;

  static VoiceProviderKind? tryParse(String raw) {
    for (final VoiceProviderKind kind in VoiceProviderKind.values) {
      if (kind.name == raw) return kind;
    }
    return null;
  }
}

/// 语音后端未配置：无密钥 / 无 Base URL 时的诚实错误。
///
/// message 里只含后端名与修复指引，绝不含密钥明文；调用方应原样展示，
/// 不伪造成功。
class VoiceNotConfiguredException implements Exception {
  VoiceNotConfiguredException(this.providerLabel, this.hint);
  final String providerLabel;
  final String hint;

  @override
  String toString() => '$providerLabel 未配置：$hint';
}

/// 语音转文字（STT）能力：只做转写，不含会话状态。
abstract class VoiceStt {
  Future<String> transcribe(Uint8List audio);
}

/// 语音合成（TTS）能力：只做合成，不含会话状态。
abstract class VoiceTts {
  Future<Uint8List> synthesize(String text);
}

abstract class VoiceProvider implements VoiceStt, VoiceTts {
  /// 本后端种类，供注册表按 kind 查找与切换。
  VoiceProviderKind get kind;

  /// 快速自检：后端当前是否可用（密钥是否已配、本地能力是否在位）。
  /// 不可用时抛 [VoiceNotConfiguredException] 或 [UnsupportedError]，
  /// 绝不返回「可用」假象；不发起真实网络调用、不消耗配额。
  Future<void> checkAvailable();

  @override
  Future<String> transcribe(Uint8List audio);

  @override
  Future<Uint8List> synthesize(String text);

  Future<void> startConversation();

  Future<void> stopConversation();

  Stream<VoiceEvent> get conversationEvents;

  bool get isListening;

  bool get isSpeaking;
}
