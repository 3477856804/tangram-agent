/// QQ 官方机器人 APIv2 直连适配（纯 Dart，协议真源：腾讯官方开源 SDK
/// tencent-connect/botpy master，与 Python 侧 im/adapters/qq_official.py
/// 同协议；端点已于 2026-11 用 curl 实测可达）：
///
///   POST https://bots.qq.com/app/getAppAccessToken
///        body {"appId", "clientSecret"}
///        -> {"access_token", "expires_in"}（失败返回 {"code","message"}，
///           如 10004 机器人不存在 —— 原样上报，绝不伪造成功）
///   GET  https://api.sgroup.qq.com/gateway   （沙箱：sandbox.api.sgroup.qq.com）
///        -> {"url": "wss://api.sgroup.qq.com/websocket"}
///        鉴权头 Authorization: "QQBot <access_token>" + X-Union-Appid
///   wss  握手（botpy gateway.py 逐字段对齐）：
///        op10 HELLO(d.heartbeat_interval ms) -> op2 IDENTIFY
///        d {"token":"QQBot <at>","intents":1<<25,"shard":[0,1]} -> op0 READY
///        心跳 op1 d=last_seq；op11 ACK；op7 重连；op9 会话失效重新鉴权
///   POST https://api.sgroup.qq.com/v2/users/{openid}/messages      （C2C 被动回复）
///   POST https://api.sgroup.qq.com/v2/groups/{group_openid}/messages（群 @ 被动回复）
///        body {"msg_type":0,"content":text,"msg_id":事件 id}
///        msg_id 为入站事件顶层 id，官方限 20 分钟内被动回复。
///
/// intents 1<<25 = botpy flags.py public_messages（群@消息 + C2C 私聊）。
/// 凭据经 HarnessStore 落盘 qq_official.json（App 私有目录，与 Python 网关
/// TANGRAM_DATA/qq_official.json 同名同字段）。连接状态只来自真实 HTTP 应答
/// 与真实 wss READY 事件：拿不到就是拿不到，UI 上绝不出现假绿。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:tangram/harness/store.dart';

/// 官方机器人网关连接状态（全部由真实网络事件驱动）。
enum QqGatewayState {
  disconnected,
  connecting,
  ready, // 收到官方 READY 事件，事件流已建立
}

/// 官方 DISPATCH 事件归一化后的入站消息。
class QqInboundMessage {
  const QqInboundMessage({
    required this.targetId,
    required this.scope, // users=C2C 私聊 / groups=群
    required this.text,
    required this.msgId,
  });

  final String targetId;
  final String scope;
  final String text;
  final String msgId;
}

/// 与 botpy Token/BotWebSocket/BotAPI 对应的 Dart 实现。
class QQOfficial {
  QQOfficial(this.store, {http.Client? client, WebSocketChannel Function(Uri)? wsConnector})
      : _client = client ?? http.Client(),
        _wsConnector = wsConnector ?? WebSocketChannel.connect {
    _events = StreamController<QqInboundMessage>.broadcast();
  }

  static const String tokenUrl = 'https://bots.qq.com/app/getAppAccessToken';
  static const String apiBase = 'https://api.sgroup.qq.com';
  static const String sandboxApiBase = 'https://sandbox.api.sgroup.qq.com';
  static const int intentsPublicMessages = 1 << 25;

  /// 凭据落盘文件：与 Python 网关 TANGRAM_DATA/qq_official.json 同名同构。
  static const String credFile = 'qq_official.json';

  final HarnessStore store;
  final http.Client _client;
  final WebSocketChannel Function(Uri) _wsConnector;
  late final StreamController<QqInboundMessage> _events;

  String appId = '';
  String clientSecret = '';
  String accessToken = '';
  double expiresAt = 0; // epoch 秒
  bool sandbox = false; // true=沙箱环境（未发布 bot 用 sandbox.api.sgroup.qq.com）

  QqGatewayState _state = QqGatewayState.disconnected;
  String lastError = '';
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _heartbeat;
  int _lastSeq = 0;
  bool _manualStop = false;

  Stream<QqInboundMessage> get onEvent => _events.stream;
  QqGatewayState get gatewayState => _state;
  bool get gatewayReady => _state == QqGatewayState.ready;

  /// 本机是否存有官方机器人凭据。
  bool get hasCred => appId.isNotEmpty && clientSecret.isNotEmpty;

  /// access_token 是否仍在官方签发的有效期内（真实值，不做乐观外推）。
  bool get tokenValid =>
      accessToken.isNotEmpty &&
      DateTime.now().millisecondsSinceEpoch / 1000 < expiresAt - 60;

  String get apiRoot => sandbox ? sandboxApiBase : apiBase;

  bool _credLoaded = false;

  Future<void> loadCred() async {
    if (_credLoaded) return;
    final d = await store.readJson(credFile);
    appId = (d['app_id'] ?? '').toString();
    clientSecret = (d['client_secret'] ?? '').toString();
    accessToken = (d['access_token'] ?? '').toString();
    expiresAt = (d['expires_at'] is num) ? (d['expires_at'] as num).toDouble() : 0;
    sandbox = d['sandbox'] == true;
    _credLoaded = true;
  }

  Future<void> _saveCred() async {
    await store.writeJson(credFile, <String, dynamic>{
      'app_id': appId,
      'client_secret': clientSecret,
      'access_token': accessToken,
      'expires_at': expiresAt,
      'sandbox': sandbox,
      'saved_at': DateTime.now().toIso8601String(),
    });
  }

  Map<String, String> _authHeaders() => <String, String>{
        'Authorization': 'QQBot $accessToken',
        'X-Union-Appid': appId,
        'Content-Type': 'application/json',
      };

  /// 官方错误体如实转述：{"code":10004,"message":"机器人不存在"} 之类。
  static String _platformError(String body) {
    try {
      final d = jsonDecode(body);
      if (d is Map) {
        final code = d['code'];
        final msg = (d['message'] ?? '').toString();
        if (code != null || msg.isNotEmpty) {
          return '官方返回 ${code ?? '?'}：${msg.isEmpty ? body : msg}';
        }
      }
    } on Object {
      // 非 JSON 响应体，原样带出。
    }
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  /// 1) token 换取：POST bots.qq.com/app/getAppAccessToken。
  ///    成功返回 access_token 并落盘；失败抛 StateError（带官方 code/message）。
  Future<String> fetchAccessToken() async {
    if (appId.isEmpty || clientSecret.isEmpty) {
      throw StateError('未填写 AppID/AppSecret');
    }
    final res = await _client
        .post(Uri.parse(tokenUrl),
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, String>{
              'appId': appId,
              'clientSecret': clientSecret,
            }))
        .timeout(const Duration(seconds: 15));
    final body = utf8.decode(res.bodyBytes);
    Map<String, dynamic>? d;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) d = Map<String, dynamic>.from(decoded);
    } on Object {
      d = null;
    }
    final token = (d?['access_token'] ?? '').toString();
    if (res.statusCode != 200 || token.isEmpty) {
      throw StateError(_platformError(body));
    }
    accessToken = token;
    final exp = d?['expires_in'];
    final seconds = exp is num
        ? exp.toDouble()
        : double.tryParse(exp?.toString() ?? '') ?? 3600;
    expiresAt = DateTime.now().millisecondsSinceEpoch / 1000 + seconds;
    await _saveCred();
    return accessToken;
  }

  /// token 失效则真实重新换取（对齐 botpy Token.check_token）。
  Future<void> _ensureToken() async {
    if (!tokenValid) await fetchAccessToken();
  }

  /// 2) 网关地址：GET {apiRoot}/gateway -> {"url":"wss://..."}。
  Future<String> fetchGatewayUrl() async {
    await _ensureToken();
    final res = await _client
        .get(Uri.parse('$apiRoot/gateway'), headers: _authHeaders())
        .timeout(const Duration(seconds: 15));
    final body = utf8.decode(res.bodyBytes);
    if (res.statusCode != 200) {
      throw StateError(_platformError(body));
    }
    final d = jsonDecode(body);
    final url = (d is Map ? d['url'] : null)?.toString() ?? '';
    if (url.isEmpty) throw StateError('官方网关未返回 wss 地址：$body');
    return url;
  }

  /// 3) 建立 wss 长连接：HELLO→IDENTIFY→READY。任何一步失败都如实置
  ///    disconnected + lastError，不谎称已连接。
  Future<void> connectGateway() async {
    if (_state == QqGatewayState.connecting || _state == QqGatewayState.ready) {
      return;
    }
    _manualStop = false;
    _setState(QqGatewayState.connecting);
    try {
      final wsUrl = await fetchGatewayUrl();
      final channel = _wsConnector(Uri.parse(wsUrl));
      await channel.ready.timeout(const Duration(seconds: 12));
      _channel = channel;
      _wsSub = channel.stream.listen(
        _onWsFrame,
        onError: (Object e) {
          lastError = '网关连接错误：$e';
          _onWsClosed();
        },
        onDone: _onWsClosed,
        cancelOnError: true,
      );
    } on Object catch (e) {
      lastError = '$e';
      await _cleanupSocket();
      _setState(QqGatewayState.disconnected);
      rethrow;
    }
  }

  void _setState(QqGatewayState s) => _state = s;

  void _onWsClosed() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _cleanupSocket();
    if (_state != QqGatewayState.disconnected) _setState(QqGatewayState.disconnected);
  }

  Future<void> _cleanupSocket() async {
    await _wsSub?.cancel();
    _wsSub = null;
    try {
      await _channel?.sink.close();
    } on Object {
      // 已断开 socket 的关闭异常无需上报。
    }
    _channel = null;
  }

  void _sendOp(int op, Object? d) {
    final ch = _channel;
    if (ch == null) return;
    ch.sink.add(jsonEncode(<String, dynamic>{'op': op, 'd': d}));
  }

  void _onWsFrame(dynamic raw) {
    final text = raw is String ? raw : utf8.decode(raw as List<int>);
    Map<String, dynamic> msg;
    try {
      final d = jsonDecode(text);
      if (d is! Map) return;
      msg = Map<String, dynamic>.from(d);
    } on Object {
      return;
    }
    final op = (msg['op'] as num?)?.toInt() ?? -1;
    final s = (msg['s'] as num?)?.toInt() ?? 0;
    if (s > 0) _lastSeq = s;
    switch (op) {
      case 10: // HELLO：拿心跳间隔后立即 IDENTIFY
        final hello = msg['d'];
        final intervalMs =
            (hello is Map ? hello['heartbeat_interval'] : null) as num? ?? 45000;
        _startHeartbeat(Duration(milliseconds: intervalMs.toInt()));
        unawaited(_identify());
      case 11: // HEARTBEAT_ACK
        break;
      case 7: // RECONNECT：官方要求重连
        unawaited(_reconnect());
      case 9: // INVALID_SESSION：会话失效，重新鉴权
        unawaited(_identify());
      case 0: // DISPATCH
        final event = (msg['t'] ?? '').toString();
        if (event == 'READY') {
          _setState(QqGatewayState.ready);
          lastError = '';
        } else if (event == 'RESUMED') {
          _setState(QqGatewayState.ready);
        } else if (event == 'C2C_MESSAGE_CREATE' ||
            event == 'GROUP_AT_MESSAGE_CREATE') {
          final d = msg['d'];
          if (d is Map) {
            final inbound = QqInboundMessage(
              targetId: (event == 'C2C_MESSAGE_CREATE'
                      ? d['openid']
                      : d['group_openid'])
                  .toString(),
              scope: event == 'C2C_MESSAGE_CREATE' ? 'users' : 'groups',
              text: ((d['content'] is Map)
                          ? (d['content'] as Map)['text']
                          : null)
                      .toString(),
              msgId: (d['id'] ?? '').toString(),
            );
            if (!_events.isClosed) _events.add(inbound);
          }
        }
    }
  }

  Future<void> _identify() async {
    try {
      await _ensureToken();
      _sendOp(2, <String, dynamic>{
        'token': 'QQBot $accessToken',
        'intents': intentsPublicMessages,
        'shard': <int>[0, 1],
      });
    } on Object catch (e) {
      lastError = '鉴权失败：$e';
      await _cleanupSocket();
      _setState(QqGatewayState.disconnected);
    }
  }

  void _startHeartbeat(Duration interval) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(interval, (_) {
      if (_channel != null) _sendOp(1, _lastSeq);
    });
  }

  Future<void> _reconnect() async {
    await _cleanupSocket();
    _setState(QqGatewayState.disconnected);
    if (!_manualStop) {
      try {
        await connectGateway();
      } on Object {
        // connectGateway 已记录 lastError。
      }
    }
  }

  /// 主动断开（保留凭据，重开 App 可恢复）。
  Future<void> disconnectGateway() async {
    _manualStop = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    await _cleanupSocket();
    _setState(QqGatewayState.disconnected);
  }

  /// 4) 被动回复（官方 v2 消息 API；msg_id 取入站事件顶层 id）。
  ///    失败抛 StateError 带官方 code/message，由上层如实展示。
  Future<void> replyText({
    required String scope,
    required String targetId,
    required String text,
    required String msgId,
  }) async {
    if (targetId.isEmpty) {
      throw StateError('缺少回复目标（openid/group_openid）');
    }
    await _ensureToken();
    final res = await _client
        .post(Uri.parse('$apiRoot/v2/$scope/$targetId/messages'),
            headers: _authHeaders(),
            body: jsonEncode(<String, dynamic>{
              'msg_type': 0,
              'content': text,
              'msg_id': msgId,
            }))
        .timeout(const Duration(seconds: 15));
    final body = utf8.decode(res.bodyBytes);
    Map<String, dynamic>? d;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) d = Map<String, dynamic>.from(decoded);
    } on Object {
      d = null;
    }
    final ok = res.statusCode >= 200 &&
        res.statusCode < 300 &&
        (d == null || (d['code'] == null && d['message'] == null));
    if (!ok) {
      throw StateError(_platformError(body));
    }
  }

  /// 状态快照：一切字段来自真实 HTTP/wss 结果。
  Map<String, dynamic> status() => <String, dynamic>{
        'has_cred': hasCred,
        'app_id': appId,
        'sandbox': sandbox,
        'token_valid': tokenValid,
        'token_expires_at': expiresAt,
        'gateway_state': _state.name,
        'gateway_ready': gatewayReady,
        'last_error': lastError,
      };

  void dispose() {
    _heartbeat?.cancel();
    _wsSub?.cancel();
    _channel?.sink.close();
    _events.close();
    _client.close();
  }
}
