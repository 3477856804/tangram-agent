import 'message.dart';

class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });
}

class ChatRequest {
  final List<Message> messages;
  final String? model;
  final List<ToolDefinition>? tools;
  final double? temperature;
  final int? maxTokens;
  final bool? stream;
  final Map<String, dynamic>? metadata;

  /// 「深度思考」开关：true 时后端走两遍推理。
  final bool thinking;

  /// 「智能搜索」开关：true 时后端做真实 DuckDuckGo 检索并注入上下文。
  final bool search;

  const ChatRequest({
    required this.messages,
    this.model,
    this.tools,
    this.temperature,
    this.maxTokens,
    this.stream = true,
    this.metadata,
    this.thinking = false,
    this.search = false,
  });
}

class ChatResponse {
  final Message message;
  final UsageInfo? usage;

  const ChatResponse({
    required this.message,
    this.usage,
  });
}
