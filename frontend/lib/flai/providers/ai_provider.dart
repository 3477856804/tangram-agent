import '../core/models/chat_event.dart';
import '../core/models/chat_request.dart';

abstract class AiProvider {
  Stream<ChatEvent> streamChat(ChatRequest request);

  Future<ChatResponse> chat(ChatRequest request);

  Future<void> cancel();

  bool get supportsToolUse;
  bool get supportsVision;
  bool get supportsStreaming;
  bool get supportsThinking;
}
