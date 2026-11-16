enum MessageRole { user, assistant, system, tool }

enum MessageStatus { streaming, complete, error }

class Attachment {
  final String id;
  final String name;
  final String mimeType;
  final String? url;
  final int? sizeBytes;

  const Attachment({
    required this.id,
    required this.name,
    required this.mimeType,
    this.url,
    this.sizeBytes,
  });
}

class Citation {
  final String title;
  final String? url;
  final String? snippet;

  const Citation({
    required this.title,
    this.url,
    this.snippet,
  });
}

class UsageInfo {
  final int inputTokens;
  final int outputTokens;
  final int? cacheReadTokens;
  final int? cacheCreationTokens;

  const UsageInfo({
    required this.inputTokens,
    required this.outputTokens,
    this.cacheReadTokens,
    this.cacheCreationTokens,
  });

  int get totalTokens => inputTokens + outputTokens;
}

class ToolCall {
  final String id;
  final String name;
  final String arguments;
  final String? result;
  final bool isComplete;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.result,
    this.isComplete = false,
  });

  ToolCall copyWith({
    String? id,
    String? name,
    String? arguments,
    String? result,
    bool? isComplete,
  }) {
    return ToolCall(
      id: id ?? this.id,
      name: name ?? this.name,
      arguments: arguments ?? this.arguments,
      result: result ?? this.result,
      isComplete: isComplete ?? this.isComplete,
    );
  }
}

/// 可持久化的真实过程状态（联网检索 / 深度推理）。
/// 与 chat_event.SearchStatus 字段一致，但不继承 ChatEvent，避免
/// message.dart ↔ chat_event.dart 循环依赖；供历史消息回看推理路径。
class ProcessStatus {
  final String phase;
  final String? query;
  final List<Map<String, String>> results;
  final String? points;

  const ProcessStatus({
    required this.phase,
    this.query,
    this.results = const <Map<String, String>>[],
    this.points,
  });
}

class Message {
  final String id;
  final MessageRole role;
  final String content;
  final DateTime timestamp;
  final List<Attachment>? attachments;
  final List<ToolCall>? toolCalls;
  final String? thinkingContent;
  final List<Citation>? citations;
  final MessageStatus status;
  final UsageInfo? usage;

  /// 该条消息真实的检索/推理过程，随消息落盘，历史里也能展开查看。
  final List<ProcessStatus>? processStatuses;

  const Message({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.attachments,
    this.toolCalls,
    this.thinkingContent,
    this.citations,
    this.status = MessageStatus.complete,
    this.usage,
    this.processStatuses,
  });

  Message copyWith({
    String? id,
    MessageRole? role,
    String? content,
    DateTime? timestamp,
    List<Attachment>? attachments,
    List<ToolCall>? toolCalls,
    String? thinkingContent,
    List<Citation>? citations,
    MessageStatus? status,
    UsageInfo? usage,
    List<ProcessStatus>? processStatuses,
  }) {
    return Message(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      attachments: attachments ?? this.attachments,
      toolCalls: toolCalls ?? this.toolCalls,
      thinkingContent: thinkingContent ?? this.thinkingContent,
      citations: citations ?? this.citations,
      status: status ?? this.status,
      usage: usage ?? this.usage,
      processStatuses: processStatuses ?? this.processStatuses,
    );
  }

  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
  bool get isStreaming => status == MessageStatus.streaming;
  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;
  bool get hasThinking => thinkingContent != null && thinkingContent!.isNotEmpty;
  bool get hasCitations => citations != null && citations!.isNotEmpty;
  bool get hasAttachments => attachments != null && attachments!.isNotEmpty;
}
