
import 'package:flutter/foundation.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/bridge/bridge_protocol.dart';

class ChatMessage {
  ChatMessage({
    required this.role,
    this.content = '',
    this.kind = 'text',
    this.streaming = false,
    this.error = false,
  });

  final String role;

  String content;

  final String kind;

  bool streaming;

  bool error;
}

class ChatStreamController extends ChangeNotifier {
  ChatStreamController([this._backend]);

  final BackendClient? _backend;
  final List<ChatMessage> messages = <ChatMessage>[];

  ChatMessage? _active;

  bool _busy = false;
  bool get busy => _busy;

  String? _error;
  String? get error => _error;

  void init() {
    _backend?.onHotPath
        .where(
          (e) =>
              e.channel == BridgeChannel.hotPath && e.topic == 'stream_token',
        )
        .listen((e) {
          final tok = (e.payload is Map)
              ? (e.payload['token'] as String? ?? '')
              : '';
          if (tok.isNotEmpty) ingestToken(tok);
        });
  }

  void appendToken(String token) {
    if (token.isEmpty) return;
    if (_active == null || !_active!.streaming) {
      _active = ChatMessage(role: 'assistant', streaming: true);
      messages.add(_active!);
    }
    _active!.content += token;
    notifyListeners();
  }

  void ingestToken(String token) => appendToken(token);

  void ingestFinal(String full) {
    if (_active == null) {
      _active = ChatMessage(role: 'assistant', content: full);
      messages.add(_active!);
    } else {
      _active!.content = full;
    }
    _active!.streaming = false;
    _active = null;
    notifyListeners();
  }

  void addBubble(String role, String content, [String kind = 'text']) {
    messages.add(ChatMessage(role: role, content: content, kind: kind));
    if (role != 'user') _active = null;
    notifyListeners();
  }

  void addError(String message) {
    messages.add(ChatMessage(role: 'system', content: message, error: true));
    notifyListeners();
  }

  void clear() {
    messages.clear();
    _active = null;
    notifyListeners();
  }

  Future<void> send(String text, {String sessionId = ''}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    addBubble('user', trimmed);
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      await _backend?.sendControl('agent_command', {
        'action': 'chat',
        'text': trimmed,
        'session_id': sessionId,
      });
    } on Object catch (e) {
      _error = '发送失败：$e';
      addError(_error!);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void beginStream() {
    _busy = true;
    _error = null;
    notifyListeners();
  }

  void endStream() {
    _busy = false;
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _active = null;
    super.dispose();
  }
}
