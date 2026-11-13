import 'message.dart';

class Conversation {
  final String id;
  final String? title;
  final List<Message> messages;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? model;
  final Map<String, dynamic>? metadata;

  const Conversation({
    required this.id,
    this.title,
    this.messages = const [],
    required this.createdAt,
    required this.updatedAt,
    this.model,
    this.metadata,
  });

  Message? get lastMessage => messages.isEmpty ? null : messages.last;

  String get displayTitle {
    if (title != null) return title!;
    if (lastMessage != null && lastMessage!.content.isNotEmpty) {
      final content = lastMessage!.content;
      return content.length > 50 ? content.substring(0, 50) : content;
    }
    return 'New Conversation';
  }

  int get messageCount => messages.length;

  Conversation copyWith({
    String? id,
    String? title,
    List<Message>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? model,
    Map<String, dynamic>? metadata,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      messages: messages ?? this.messages,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      model: model ?? this.model,
      metadata: metadata ?? this.metadata,
    );
  }
}
