import 'message.dart';

sealed class ChatEvent {
  const ChatEvent();
}

class TextDelta extends ChatEvent {
  final String text;
  const TextDelta(this.text);
}

class TextDone extends ChatEvent {
  final String fullText;
  const TextDone(this.fullText);
}

class ToolCallStart extends ChatEvent {
  final String id;
  final String name;
  const ToolCallStart({required this.id, required this.name});
}

class ToolCallDelta extends ChatEvent {
  final String id;
  final String argumentsDelta;
  const ToolCallDelta({required this.id, required this.argumentsDelta});
}

class ToolCallEnd extends ChatEvent {
  final String id;
  const ToolCallEnd({required this.id});
}

class ThinkingStart extends ChatEvent {
  const ThinkingStart();
}

class ThinkingDelta extends ChatEvent {
  final String text;
  const ThinkingDelta(this.text);
}

class ThinkingEnd extends ChatEvent {
  const ThinkingEnd();
}

class UsageUpdate extends ChatEvent {
  final int inputTokens;
  final int outputTokens;
  final int? cacheReadTokens;
  final int? cacheCreationTokens;
  const UsageUpdate({
    required this.inputTokens,
    required this.outputTokens,
    this.cacheReadTokens,
    this.cacheCreationTokens,
  });
}

class ChatDone extends ChatEvent {
  const ChatDone();
}

class ChatError extends ChatEvent {
  final Object error;
  final StackTrace? stackTrace;
  const ChatError(this.error, [this.stackTrace]);
}

class CitationsReceived extends ChatEvent {
  final List<Citation> citations;
  const CitationsReceived(this.citations);
}

/// 后端 chat_status 热点事件的真实过程状态（问题 #4b）：
///   * phase=searching    → 联网检索开始，query 为检索词；
///   * phase=search_done  → 检索完成，results 为真实抓取到的来源（≤5 条）；
///   * phase=thinking_done→ 深度思考规划完成，points 为推理要点前 200 字。
class SearchStatus extends ChatEvent {
  final String phase;
  final String? query;
  final List<Map<String, String>> results;
  final String? points;
  const SearchStatus({
    required this.phase,
    this.query,
    this.results = const <Map<String, String>>[],
    this.points,
  });
}
