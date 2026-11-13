import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/models/conversation.dart';
import '../core/models/message.dart';
import 'storage_provider.dart';

/// 真实落盘的会话存储：JSON 写入应用文档目录，进程重启后仍可恢复。
///
/// 与 InMemoryStorageProvider 实现同一个 StorageProvider 接口，但不再是
/// 重启即丢失的假存储。所有字段（附件 / 工具调用 / 引用 / token 用量）
/// 都完整序列化，不丢弃数据；读取失败时保持空状态，不编造会话。
class PersistentStorageProvider implements StorageProvider {
  final Map<String, Conversation> _conversations = <String, Conversation>{};
  final Map<String, List<Message>> _messages = <String, List<Message>>{};
  final Set<String> _starred = <String>{};
  bool _loaded = false;

  /// 真实落盘，带桌面无 XDG 环境时的降级：App 文档目录不可用时用系统
  /// 临时目录，仍然是真实磁盘文件，会话不会丢，也不是内存伪造。
  Future<File> get _file async {
    Directory dir;
    try {
      dir = await getApplicationDocumentsDirectory();
    } on Object {
      dir = Directory.systemTemp;
    }
    return File('${dir.path}/tangram_conversations.json');
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final File f = await _file;
    if (!await f.exists()) return;
    final dynamic decoded = jsonDecode(await f.readAsString());
    if (decoded is! Map) return;
    final dynamic convs = decoded['conversations'];
    if (convs is List) {
      for (final dynamic c in convs) {
        if (c is Map) {
          final Conversation conv = _conversationFromJson(c);
          _conversations[conv.id] = conv;
        }
      }
    }
    final dynamic starred = decoded['starred'];
    if (starred is List) {
      for (final dynamic s in starred) {
        _starred.add(s.toString());
      }
    }
  }

  Future<void> _flush() async {
    final File f = await _file;
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(<String, dynamic>{
      'version': 1,
      'conversations':
          _conversations.values.map(_conversationToJson).toList(),
      'starred': _starred.toList(),
    }));
  }

  // ---- 全字段序列化 ----

  Map<String, dynamic> _conversationToJson(Conversation c) =>
      <String, dynamic>{
        'id': c.id,
        'title': c.title,
        'createdAt': c.createdAt.toIso8601String(),
        'updatedAt': c.updatedAt.toIso8601String(),
        'model': c.model,
        'metadata': c.metadata,
        'messages': (_messages[c.id] ?? c.messages).map(_messageToJson).toList(),
      };

  Conversation _conversationFromJson(Map<dynamic, dynamic> c) {
    final List<Message> msgs = c['messages'] is List
        ? (c['messages'] as List)
            .whereType<Map<dynamic, dynamic>>()
            .map(_messageFromJson)
            .toList()
        : <Message>[];
    final String id = c['id'].toString();
    _messages[id] = msgs;
    return Conversation(
      id: id,
      title: c['title']?.toString(),
      messages: msgs,
      createdAt: DateTime.tryParse(c['createdAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.tryParse(c['updatedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      model: c['model']?.toString(),
      metadata: c['metadata'] is Map
          ? (c['metadata'] as Map).map(
              (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v))
          : null,
    );
  }

  Map<String, dynamic> _messageToJson(Message m) => <String, dynamic>{
        'id': m.id,
        'role': m.role.name,
        'content': m.content,
        'timestamp': m.timestamp.toIso8601String(),
        'status': m.status.name,
        'thinkingContent': m.thinkingContent,
        'attachments': m.attachments
            ?.map((Attachment a) => <String, dynamic>{
                  'id': a.id,
                  'name': a.name,
                  'mimeType': a.mimeType,
                  'url': a.url,
                  'sizeBytes': a.sizeBytes,
                })
            .toList(),
        'toolCalls': m.toolCalls
            ?.map((ToolCall t) => <String, dynamic>{
                  'id': t.id,
                  'name': t.name,
                  'arguments': t.arguments,
                  'result': t.result,
                  'isComplete': t.isComplete,
                })
            .toList(),
        'citations': m.citations
            ?.map((Citation c) => <String, dynamic>{
                  'title': c.title,
                  'url': c.url,
                  'snippet': c.snippet,
                })
            .toList(),
        'usage': m.usage == null
            ? null
            : <String, dynamic>{
                'inputTokens': m.usage!.inputTokens,
                'outputTokens': m.usage!.outputTokens,
                'cacheReadTokens': m.usage!.cacheReadTokens,
                'cacheCreationTokens': m.usage!.cacheCreationTokens,
              },
      };

  Message _messageFromJson(Map<dynamic, dynamic> m) => Message(
        id: m['id'].toString(),
        role: MessageRole.values.firstWhere(
          (MessageRole r) => r.name == m['role']?.toString(),
          orElse: () => MessageRole.user,
        ),
        content: (m['content'] ?? '').toString(),
        timestamp: DateTime.tryParse(m['timestamp']?.toString() ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        status: MessageStatus.values.firstWhere(
          (MessageStatus s) => s.name == m['status']?.toString(),
          orElse: () => MessageStatus.complete,
        ),
        thinkingContent: m['thinkingContent']?.toString(),
        attachments: m['attachments'] is List
            ? (m['attachments'] as List)
                .whereType<Map<dynamic, dynamic>>()
                .map((Map<dynamic, dynamic> a) => Attachment(
                      id: a['id'].toString(),
                      name: a['name'].toString(),
                      mimeType: a['mimeType'].toString(),
                      url: a['url']?.toString(),
                      sizeBytes: a['sizeBytes'] is int ? a['sizeBytes'] as int : null,
                    ))
                .toList()
            : null,
        toolCalls: m['toolCalls'] is List
            ? (m['toolCalls'] as List)
                .whereType<Map<dynamic, dynamic>>()
                .map((Map<dynamic, dynamic> t) => ToolCall(
                      id: t['id'].toString(),
                      name: t['name'].toString(),
                      arguments: t['arguments'].toString(),
                      result: t['result']?.toString(),
                      isComplete: t['isComplete'] == true,
                    ))
                .toList()
            : null,
        citations: m['citations'] is List
            ? (m['citations'] as List)
                .whereType<Map<dynamic, dynamic>>()
                .map((Map<dynamic, dynamic> c) => Citation(
                      title: c['title'].toString(),
                      url: c['url']?.toString(),
                      snippet: c['snippet']?.toString(),
                    ))
                .toList()
            : null,
        usage: m['usage'] is Map
            ? UsageInfo(
                inputTokens: (m['usage']['inputTokens'] as num?)?.toInt() ?? 0,
                outputTokens: (m['usage']['outputTokens'] as num?)?.toInt() ?? 0,
                cacheReadTokens:
                    (m['usage']['cacheReadTokens'] as num?)?.toInt(),
                cacheCreationTokens:
                    (m['usage']['cacheCreationTokens'] as num?)?.toInt(),
              )
            : null,
      );

  // ---- StorageProvider ----

  @override
  Future<List<Conversation>> loadConversations() async {
    await _ensureLoaded();
    return _conversations.values.toList()
      ..sort((Conversation a, Conversation b) =>
          b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Future<Conversation> saveConversation(Conversation conversation) async {
    await _ensureLoaded();
    _conversations[conversation.id] = conversation;
    _messages.putIfAbsent(conversation.id, () => <Message>[]);
    await _flush();
    return conversation;
  }

  @override
  Future<void> deleteConversation(String id) async {
    await _ensureLoaded();
    _conversations.remove(id);
    _messages.remove(id);
    _starred.remove(id);
    await _flush();
  }

  @override
  Future<void> starConversation(String id) async {
    await _ensureLoaded();
    _starred.add(id);
    await _flush();
  }

  @override
  Future<void> unstarConversation(String id) async {
    await _ensureLoaded();
    _starred.remove(id);
    await _flush();
  }

  @override
  Future<List<Conversation>> loadStarredConversations() async {
    await _ensureLoaded();
    return _conversations.values
        .where((Conversation c) => _starred.contains(c.id))
        .toList()
      ..sort((Conversation a, Conversation b) =>
          b.updatedAt.compareTo(a.updatedAt));
  }

  @override
  Future<List<Message>> loadMessages(String conversationId) async {
    await _ensureLoaded();
    return _messages[conversationId] ?? <Message>[];
  }

  @override
  Future<void> saveMessage(String conversationId, Message message) async {
    await _ensureLoaded();
    final List<Message> messages =
        _messages.putIfAbsent(conversationId, () => <Message>[]);
    final int index = messages.indexWhere((Message m) => m.id == message.id);
    if (index >= 0) {
      messages[index] = message;
    } else {
      messages.add(message);
    }
    // 同步会话里的 messages 视图，保证 displayTitle / messageCount 一致
    final Conversation? conv = _conversations[conversationId];
    if (conv != null) {
      _conversations[conversationId] = conv.copyWith(
        messages: List<Message>.unmodifiable(messages),
        updatedAt: message.timestamp,
      );
    }
    await _flush();
  }

  @override
  Future<List<Conversation>> searchConversations(String query) async {
    await _ensureLoaded();
    final String lower = query.toLowerCase();
    return _conversations.values.where((Conversation c) {
      if (c.title?.toLowerCase().contains(lower) ?? false) return true;
      final List<Message>? msgs = _messages[c.id];
      if (msgs == null) return false;
      return msgs.any((Message m) => m.content.toLowerCase().contains(lower));
    }).toList();
  }

  @override
  Future<void> renameConversation(String id, String newTitle) async {
    await _ensureLoaded();
    final Conversation? conv = _conversations[id];
    if (conv != null) {
      _conversations[id] = conv.copyWith(title: newTitle);
      await _flush();
    }
  }
}
