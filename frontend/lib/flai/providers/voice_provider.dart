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

abstract class VoiceProvider {
  Future<String> transcribe(Uint8List audio);

  Future<Uint8List> synthesize(String text);

  Future<void> startConversation();

  Future<void> stopConversation();

  Stream<VoiceEvent> get conversationEvents;

  bool get isListening;

  bool get isSpeaking;
}
