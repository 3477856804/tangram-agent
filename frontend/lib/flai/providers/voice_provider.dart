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
