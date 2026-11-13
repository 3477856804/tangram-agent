/// 真实 IM 网关客户端（纯 Dart / WebSocket）。
///
/// 移植自 OpenClaw 通道实现：
///  - `openclaw-onebot/src/gateway.ts`：指数退避重连、每会话消息批处理、
///    abort 时清理缓冲区；
///  - `wechat-openclaw-channel/websocket/*`：AGP 信封收发、msg_id 幂等、
///    连接状态机、心跳、上行 session.update / session.promptResponse。
///
/// 全部为真实网络行为：连不上就是连不上，绝不伪造「已连接」。
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'agp_protocol.dart';

/// 连接状态机，与 AGP WebSocketClientConfig.ConnectionState 对齐。
enum ImConnectionState { disconnected, connecting, connected, reconnecting }

/// 重连退避序列（毫秒），抄自 openclaw-onebot gateway.ts。
const List<int> kReconnectDelaysMs = <int>[
  1000, 2000, 5000, 10000, 30000, 60000,
];

/// 消息批处理参数（抄自 openclaw-onebot）。
const int kBatchGapMs = 1500;
const int kBatchMaxMessages = 12;
const int kBatchMaxChars = 50000;

class ImGatewayConfig {
  const ImGatewayConfig({
    required this.url,
    this.guid = '',
    this.userId = '',
    this.token = '',
    this.heartbeat = const Duration(minutes: 4),
    this.maxReconnectAttempts = 0,
    this.connector = 'wechat',
  });

  final String url;
  final String guid;
  final String userId;
  final String token;
  final Duration heartbeat;
  /// 0 = 无限重连。
  final int maxReconnectAttempts;
  final String connector;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'guid': guid,
        'user_id': userId,
        'token': token,
        'connector': connector,
        'heartbeat_seconds': heartbeat.inSeconds,
      };

  static ImGatewayConfig fromJson(Map<String, dynamic> m) => ImGatewayConfig(
        url: (m['url'] ?? '').toString(),
        guid: (m['guid'] ?? '').toString(),
        userId: (m['user_id'] ?? m['userId'] ?? '').toString(),
        token: (m['token'] ?? '').toString(),
        connector: (m['connector'] ?? 'wechat').toString(),
        heartbeat: Duration(seconds: _asInt(m['heartbeat_seconds'], 240)),
        maxReconnectAttempts: _asInt(m['max_reconnect_attempts'], 0),
      );

  static int _asInt(dynamic v, int f) => v is num ? v.toInt() : int.tryParse('$v') ?? f;
}

/// 网关收到的用户指令。
class InboundPrompt {
  const InboundPrompt({
    required this.msgId,
    required this.prompt,
    required this.guid,
    required this.userId,
    required this.receivedAt,
  });
  final String msgId;
  final PromptPayload prompt;
  final String guid;
  final String userId;
  final DateTime receivedAt;
}

/// AGP WebSocket 网关客户端。
///
/// 使用方式：
/// ```dart
/// final gw = ImGateway(cfg, onPrompt: (p) async => '回复内容');
/// await gw.connect();
/// ```
/// 回复通过 [sendChunk] / [sendPromptResponse] 真实发回网关。
class ImGateway {
  ImGateway(this.config, {this.onPromptText, this.onLog});

  ImGatewayConfig config;
  Future<String> Function(InboundPrompt prompt)? onPromptText;
  void Function(String line)? onLog;

  final StreamController<ImConnectionState> _stateController =
      StreamController<ImConnectionState>.broadcast();
  final StreamController<InboundPrompt> _promptController =
      StreamController<InboundPrompt>.broadcast();
  final MsgIdCache _msgIds = MsgIdCache();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  final Map<String, _Batch> _batches = <String, _Batch>{};

  ImConnectionState _state = ImConnectionState.disconnected;
  int _reconnectAttempts = 0;
  bool _manualStop = false;
  String? _lastError;
  int _inboundCount = 0;
  int _outboundCount = 0;

  Stream<ImConnectionState> get onState => _stateController.stream;
  Stream<InboundPrompt> get onPrompt => _promptController.stream;
  ImConnectionState get state => _state;
  String? get lastError => _lastError;
  int get inboundCount => _inboundCount;
  int get outboundCount => _outboundCount;
  bool get isConnected => _state == ImConnectionState.connected;

  void _log(String s) => onLog?.call(s);

  void _setState(ImConnectionState s) {
    if (_state == s) return;
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  /// 建立真实 WebSocket 连接。URL 为空则如实抛错，不假装成功。
  Future<void> connect() async {
    if (_state == ImConnectionState.connected ||
        _state == ImConnectionState.connecting) {
      return;
    }
    _manualStop = false;
    final uri = Uri.tryParse(config.url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      _lastError = '网关地址无效：${config.url.isEmpty ? '(未配置)' : config.url}';
      throw StateError(_lastError!);
    }
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      _lastError = '网关地址必须使用 ws:// 或 wss://';
      throw StateError(_lastError!);
    }
    _setState(ImConnectionState.connecting);
    _log('[agp] 连接 ${config.url}');

    // 查询参数与 openclaw 微信通道客户端一致：guid / user_id / token。
    final endpoint = uri.replace(queryParameters: <String, String>{
      ...uri.queryParameters,
      if (config.guid.isNotEmpty) 'guid': config.guid,
      if (config.userId.isNotEmpty) 'user_id': config.userId,
      if (config.token.isNotEmpty) 'token': config.token,
    });

    try {
      _channel = WebSocketChannel.connect(endpoint);
      await _channel!.ready.timeout(const Duration(seconds: 12));
    } on Object catch (e) {
      _lastError = '连接失败：$e';
      _log('[agp] $_lastError');
      await _cleanupSocket();
      _setState(ImConnectionState.disconnected);
      _scheduleReconnect();
      return;
    }

    _lastError = null;
    _reconnectAttempts = 0;
    _setState(ImConnectionState.connected);
    _log('[agp] 已连接');
    _startHeartbeat();

    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (Object e) {
        _lastError = '连接错误：$e';
        _log('[agp] $_lastError');
        _onDisconnected();
      },
      onDone: _onDisconnected,
      cancelOnError: true,
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(config.heartbeat, (_) {
      if (isConnected) {
        _sendRaw(AgpEnvelope(
          msgId: AgpEnvelope.newId(),
          method: AgpMethod.ping,
          payload: <String, dynamic>{'ts': DateTime.now().millisecondsSinceEpoch},
          guid: config.guid,
          userId: config.userId,
        ).toJson());
      }
    });
  }

  void _onDisconnected() {
    _cleanupSocket();
    if (_manualStop) {
      _setState(ImConnectionState.disconnected);
      return;
    }
    _setState(ImConnectionState.reconnecting);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_manualStop) return;
    final max = config.maxReconnectAttempts;
    if (max > 0 && _reconnectAttempts >= max) {
      _log('[agp] 达到最大重连次数，停止重连');
      _setState(ImConnectionState.disconnected);
      return;
    }
    final idx = _reconnectAttempts.clamp(0, kReconnectDelaysMs.length - 1);
    final delay = Duration(milliseconds: kReconnectDelaysMs[idx]);
    _reconnectAttempts++;
    _setState(ImConnectionState.reconnecting);
    _log('[agp] ${delay.inMilliseconds}ms 后第 $_reconnectAttempts 次重连');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_manualStop) unawaited(connect());
    });
  }

  void _onMessage(dynamic raw) {
    final text = raw is String ? raw : (raw is List<int> ? utf8.decode(raw) : '$raw');
    final env = AgpEnvelope.decodeText(text);
    if (env == null) {
      _log('[agp] 忽略无法解析的消息');
      return;
    }
    if (!_msgIds.checkAndAdd(env.msgId)) {
      _log('[agp] 丢弃重复 msg_id=${env.msgId}');
      return;
    }
    switch (env.method) {
      case AgpMethod.sessionPrompt:
        _handlePrompt(env);
      case AgpMethod.sessionCancel:
        final c = CancelPayload.fromMap(env.payload);
        _batches.remove('${c.sessionId}/${c.promptId}');
        _log('[agp] 取消 prompt_id=${c.promptId}');
      case AgpMethod.ping:
        break;
      case AgpMethod.sessionUpdate:
      case AgpMethod.sessionPromptResponse:
        // 上行消息由网关消费，客户端忽略回环。
        break;
    }
  }

  void _handlePrompt(AgpEnvelope env) {
    final p = PromptPayload.fromMap(env.payload);
    if (p.promptId.isEmpty) {
      _log('[agp] 丢弃无 prompt_id 的指令');
      return;
    }
    _inboundCount++;
    _log('[agp] 收到指令 session=${p.sessionId} prompt=${p.promptId} '
        'len=${p.text.length}');
    if (!_promptController.isClosed) {
      _promptController.add(InboundPrompt(
        msgId: env.msgId,
        prompt: p,
        guid: env.guid ?? config.guid,
        userId: env.userId ?? config.userId,
        receivedAt: DateTime.now(),
      ));
    }
    _bufferForReply(env, p);
  }

  /// 每会话消息批处理：AGG 窗口内合并短消息，对齐 onebot gateway.ts。
  void _bufferForReply(AgpEnvelope env, PromptPayload p) {
    final key = '${p.sessionId}/${p.promptId}';
    final existing = _batches[key];
    if (existing != null) {
      existing.items.add(p.text);
      existing.chars += p.text.length;
      existing.timer.cancel();
    } else {
      _batches[key] = _Batch()..items.add(p.text)..chars = p.text.length;
    }
    final batch = _batches[key]!;
    final bool flushNow = batch.items.length >= kBatchMaxMessages ||
        batch.chars >= kBatchMaxChars;
    if (flushNow) {
      _flush(key, env, p);
      return;
    }
    batch.timer = Timer(const Duration(milliseconds: kBatchGapMs), () {
      _flush(key, env, p);
    });
  }

  void _flush(String key, AgpEnvelope env, PromptPayload p) {
    final batch = _batches.remove(key);
    if (batch == null) return;
    batch.timer.cancel();
    final merged = batch.items.join('\n');
    unawaited(_runTurn(env, p, merged));
  }

  Future<void> _runTurn(AgpEnvelope env, PromptPayload p, String text) async {
    final handler = onPromptText;
    if (handler == null) {
      await sendPromptResponse(
        sessionId: p.sessionId,
        promptId: p.promptId,
        stopReason: StopReason.error,
        error: 'APP 未注册对话处理器',
        guid: env.guid,
        userId: env.userId,
      );
      return;
    }
    try {
      final inbound = InboundPrompt(
        msgId: env.msgId,
        prompt: PromptPayload(
          sessionId: p.sessionId,
          promptId: p.promptId,
          agentApp: p.agentApp,
          content: <ContentBlock>[ContentBlock(text: text)],
        ),
        guid: env.guid ?? config.guid,
        userId: env.userId ?? config.userId,
        receivedAt: DateTime.now(),
      );
      final reply = await handler(inbound);
      if (reply.isNotEmpty) {
        await sendChunk(
          sessionId: p.sessionId,
          promptId: p.promptId,
          text: reply,
          guid: env.guid,
          userId: env.userId,
        );
      }
      await sendPromptResponse(
        sessionId: p.sessionId,
        promptId: p.promptId,
        stopReason: StopReason.endTurn,
        content: reply.isEmpty
            ? null
            : <ContentBlock>[ContentBlock(text: reply)],
        guid: env.guid,
        userId: env.userId,
      );
    } on Object catch (e) {
      _log('[agp] Turn 执行失败：$e');
      await sendPromptResponse(
        sessionId: p.sessionId,
        promptId: p.promptId,
        stopReason: StopReason.error,
        error: '$e',
        guid: env.guid,
        userId: env.userId,
      );
    }
  }

  /// 上行流式增量（真实发送）。
  Future<void> sendChunk({
    required String sessionId,
    required String promptId,
    required String text,
    String? guid,
    String? userId,
  }) async {
    if (!isConnected) return;
    final u = UpdatePayload(
      sessionId: sessionId,
      promptId: promptId,
      updateType: UpdateType.messageChunk,
      content: ContentBlock(text: text),
    );
    _sendRaw(AgpEnvelope(
      msgId: AgpEnvelope.newId(),
      method: AgpMethod.sessionUpdate,
      payload: u.toJson(),
      guid: guid ?? config.guid,
      userId: userId ?? config.userId,
    ).toJson());
  }

  /// 上行工具调用状态。
  Future<void> sendToolCall({
    required String sessionId,
    required String promptId,
    required ToolCall call,
    bool update = false,
  }) async {
    if (!isConnected) return;
    final u = UpdatePayload(
      sessionId: sessionId,
      promptId: promptId,
      updateType: update ? UpdateType.toolCallUpdate : UpdateType.toolCall,
      toolCall: call,
    );
    _sendRaw(AgpEnvelope(
      msgId: AgpEnvelope.newId(),
      method: AgpMethod.sessionUpdate,
      payload: u.toJson(),
      guid: config.guid,
      userId: config.userId,
    ).toJson());
  }

  /// 上行 Turn 结束回执（真实发送）。
  Future<void> sendPromptResponse({
    required String sessionId,
    required String promptId,
    required StopReason stopReason,
    List<ContentBlock>? content,
    String? error,
    String? guid,
    String? userId,
  }) async {
    if (!isConnected) return;
    final r = PromptResponsePayload(
      sessionId: sessionId,
      promptId: promptId,
      stopReason: stopReason,
      content: content,
      error: error,
    );
    _sendRaw(AgpEnvelope(
      msgId: AgpEnvelope.newId(),
      method: AgpMethod.sessionPromptResponse,
      payload: r.toJson(),
      guid: guid ?? config.guid,
      userId: userId ?? config.userId,
    ).toJson());
  }

  void _sendRaw(Map<String, dynamic> envelope) {
    final ch = _channel;
    if (ch == null || !isConnected) return;
    try {
      ch.sink.add(jsonEncode(envelope));
      _outboundCount++;
    } on Object catch (e) {
      _lastError = '发送失败：$e';
      _log('[agp] $_lastError');
    }
  }

  Future<void> _cleanupSocket() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close();
    } on Object {
      // 关闭已断开的 socket 时的异常无需上报。
    }
    _channel = null;
  }

  /// 主动断开（清理所有批处理缓冲，对齐 openclaw abort 语义）。
  Future<void> disconnect() async {
    _manualStop = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    for (final b in _batches.values) {
      b.timer.cancel();
    }
    _batches.clear();
    await _cleanupSocket();
    _setState(ImConnectionState.disconnected);
    _log('[agp] 已断开');
  }

  void updateConfig(ImGatewayConfig next) {
    config = next;
  }

  Map<String, dynamic> status() => <String, dynamic>{
        'connected': isConnected,
        'state': _state.name,
        'url': config.url,
        'connector': config.connector,
        'guid': config.guid,
        'last_error': _lastError,
        'inbound': _inboundCount,
        'outbound': _outboundCount,
        'reconnect_attempts': _reconnectAttempts,
        'pending_batches': _batches.length,
      };

  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
    await _promptController.close();
  }
}

class _Batch {
  final List<String> items = <String>[];
  int chars = 0;
  Timer timer = Timer(Duration.zero, () {});
}
