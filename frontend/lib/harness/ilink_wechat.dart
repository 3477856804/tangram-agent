/// 微信 iLink Bot 官方协议直连适配（Dart 移植自本仓库
/// `im/adapters/wechat_ilink.py`，协议真源：@tencent-weixin/openclaw-weixin
/// v2.4.x dist/src/api/api.js、auth/login-qr.js、messaging/send.js）。
///
/// 端点与其一一对应：
///   POST https://ilinkai.weixin.qq.com/ilink/bot/get_bot_qrcode?bot_type=3
///        body {"local_token_list":[...], "base_info":{...}}
///        -> {"qrcode", "qrcode_img_content"}
///   GET  ilink/bot/get_qrcode_status?qrcode=
///        -> {"status": wait|scaned|confirmed, "bot_token", "ilink_bot_id"}
///   POST ilink/bot/getupdates   body {"get_updates_buf","base_info"}
///        -> {"msgs","get_updates_buf","ret"}
///   POST ilink/bot/sendmessage  body {"msg":{...},"base_info"}
///
/// 鉴权头：AuthorizationType: ilink_bot_token；登录后 Authorization:
/// Bearer <bot_token>；X-WECHAT-UIN 随机。凭据经 HarnessStore 落盘
/// weixin_ilink.json（App 私有目录，与 Python 网关同名同字段）。
///
/// 二维码是腾讯 iLink 刚下发的**真码**，5 分钟内有效；过期后重新
/// fetchQr 即可拿新码（UI 上的「要新码」按钮）。扫完在微信里给 bot 发
/// 一条消息，getupdates 长轮询即收到，走真实推理后 sendmessage 回发——
/// 这就是真链路。本文件不生成、不伪造任何二维码。
library;

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'package:tangram/harness/store.dart';

class IlinkQrTicket {
  const IlinkQrTicket({
    required this.qrcode,
    required this.scanContent,
    this.expiresIn = 300,
  });

  /// 状态轮询用的 qrcode 句柄（get_qrcode_status?qrcode=...）。
  final String qrcode;

  /// qrcode_img_content：真正要渲染成二维码给用户扫的内容。
  final String scanContent;

  /// 腾讯 iLink 真码有效期（秒），与官方一致 5 分钟。
  final int expiresIn;
}

class IlinkPollResult {
  const IlinkPollResult({
    required this.status,
    this.botToken = '',
    this.botId = '',
    this.error = '',
  });

  /// wait / scaned / confirmed / expired / error
  final String status;
  final String botToken;
  final String botId;
  final String error;

  bool get confirmed => status == 'confirmed' && botToken.isNotEmpty;
}

class IlinkInboundMessage {
  const IlinkInboundMessage({
    required this.fromUserId,
    required this.text,
    required this.contextToken,
    required this.messageId,
  });

  final String fromUserId;
  final String text;
  final String contextToken;
  final String messageId;
}

/// 与 wechat_ilink.py WeChatILinkAdapter 对应的 Dart 实现。
class IlinkWeChat {
  IlinkWeChat(this.store, {http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        base = baseUrl ?? _kDefaultBase;

  static const String _kDefaultBase = 'https://ilinkai.weixin.qq.com';
  static const String botType = '3';
  static const int _itemText = 1;
  static const int _itemVoice = 3;
  static const int _messageTypeBot = 2;
  static const int _stateFinish = 2;

  /// 凭据落盘文件：与 Python 网关 TANGRAM_DATA/weixin_ilink.json 同名同构。
  static const String credFile = 'weixin_ilink.json';

  final HarnessStore store;
  final http.Client _client;
  final String base;
  final Random _rng = Random();

  String token = '';
  String botId = '';
  String _buf = '';
  bool _credLoaded = false;

  bool get hasToken => token.isNotEmpty;

  Future<void> loadCred() async {
    if (_credLoaded) return;
    final d = await store.readJson(credFile);
    token = (d['bot_token'] ?? '').toString();
    botId = (d['ilink_bot_id'] ?? '').toString();
    _buf = (d['get_updates_buf'] ?? '').toString();
    _credLoaded = true;
  }

  Future<void> _saveCred() async {
    await store.writeJson(credFile, <String, dynamic>{
      'bot_token': token,
      'ilink_bot_id': botId,
      'get_updates_buf': _buf,
      'saved_at': DateTime.now().toIso8601String(),
    });
  }

  /// 10 位随机 UIN（对齐 Python secrets.randbelow(10**10)；Dart
  /// Random.nextInt 上限 2^32，用两段拼接）。
  String _uin() =>
      (_rng.nextInt(100000) * 100000 + _rng.nextInt(100000)).toString();

  Map<String, String> _headers() => <String, String>{
        'AuthorizationType': 'ilink_bot_token',
        'X-WECHAT-UIN': _uin(),
        'Content-Type': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  static Map<String, dynamic> _baseInfo() => <String, dynamic>{
        'channel_version': '2.4.10-tangram',
        'bot_agent': 'Tangram',
      };

  Uri _u(String pathAndQuery) => Uri.parse('$base/${pathAndQuery.replaceFirst(RegExp(r'^/+'), '')}');

  Future<Map<String, dynamic>?> _postJson(String ep, Map<String, dynamic> body,
      {Duration timeout = const Duration(seconds: 40)}) async {
    final res = await _client
        .post(_u(ep), headers: _headers(), body: jsonEncode(body))
        .timeout(timeout);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode}');
    }
    final d = jsonDecode(utf8.decode(res.bodyBytes));
    return d is Map ? Map<String, dynamic>.from(d) : null;
  }

  /// 向腾讯 iLink 申请真实登录二维码（5 分钟有效）。
  Future<IlinkQrTicket> fetchQr() async {
    await loadCred();
    final resp = await _postJson(
      'ilink/bot/get_bot_qrcode?bot_type=$botType',
      <String, dynamic>{
        'local_token_list': <String>[if (token.isNotEmpty) token],
        'base_info': _baseInfo(),
      },
    );
    final String qrcode = (resp?['qrcode'] ?? '').toString();
    final String content = (resp?['qrcode_img_content'] ?? '').toString();
    if (qrcode.isEmpty || content.isEmpty) {
      throw StateError('iLink 未返回二维码（平台侧限制或网络异常），不伪造');
    }
    return IlinkQrTicket(qrcode: qrcode, scanContent: content);
  }

  /// 轮询扫码状态；confirmed 时拿真实 bot_token 并落盘。
  Future<IlinkPollResult> pollQrStatus(String qrcode) async {
    final ep = 'ilink/bot/get_qrcode_status?qrcode=${Uri.encodeQueryComponent(qrcode)}';
    Map<String, dynamic>? resp;
    try {
      // 官方端点是长轮询：扫码前会挂住连接，超时视作继续等待。
      final res = await _client
          .get(_u(ep), headers: _headers())
          .timeout(const Duration(seconds: 40));
      final d = jsonDecode(utf8.decode(res.bodyBytes));
      resp = d is Map ? Map<String, dynamic>.from(d) : null;
    } on Object catch (e) {
      return IlinkPollResult(status: 'wait', error: '$e');
    }
    final String status = (resp?['status'] ?? 'wait').toString();
    if ((status == 'confirmed' || status == 'success') &&
        (resp?['bot_token'] ?? '').toString().isNotEmpty) {
      token = resp!['bot_token'].toString();
      botId = (resp['ilink_bot_id'] ?? '').toString();
      await _saveCred();
      return IlinkPollResult(
          status: 'confirmed', botToken: token, botId: botId);
    }
    return IlinkPollResult(status: status);
  }

  /// 长轮询接收消息（getupdates）。网络异常返回空列表，不伪造。
  Future<List<IlinkInboundMessage>> getUpdates(
      {Duration timeout = const Duration(seconds: 35)}) async {
    await loadCred();
    if (token.isEmpty) return <IlinkInboundMessage>[];
    Map<String, dynamic>? resp;
    try {
      resp = await _postJson('ilink/bot/getupdates', <String, dynamic>{
        'get_updates_buf': _buf,
        'base_info': _baseInfo(),
      }, timeout: timeout + const Duration(seconds: 5));
    } on Object {
      return <IlinkInboundMessage>[];
    }
    if (resp == null || (resp['ret'] != null && resp['ret'] != 0)) {
      return <IlinkInboundMessage>[];
    }
    final String nextBuf = (resp['get_updates_buf'] ?? _buf).toString();
    if (nextBuf.isNotEmpty && nextBuf != _buf) {
      _buf = nextBuf;
      await _saveCred();
    }
    final List<dynamic> msgs =
        resp['msgs'] is List ? resp['msgs'] as List : <dynamic>[];
    return msgs.whereType<Map>().map(_parseInbound).toList();
  }

  /// 入站归一化：官方 msgs 结构 from_user_id + item_list（text/voice）。
  IlinkInboundMessage _parseInbound(Map<dynamic, dynamic> raw) {
    final from = (raw['from_user_id'] ?? '').toString();
    final ctx = (raw['context_token'] ?? '').toString();
    final texts = <String>[];
    for (final dynamic item in (raw['item_list'] as List? ?? <dynamic>[])) {
      if (item is! Map) continue;
      final t = item['type'];
      if (t == _itemText) {
        texts.add(((item['text_item'] as Map?)?['text'] ?? '').toString());
      } else if (t == _itemVoice) {
        // 官方同款：voice_item.text 是微信内置语音转文字结果，直接采用。
        final v = (item['voice_item'] as Map?)?['text'];
        if (v != null && v.toString().isNotEmpty) texts.add(v.toString());
      }
    }
    return IlinkInboundMessage(
      fromUserId: from,
      text: texts.where((s) => s.isNotEmpty).join('\n'),
      contextToken: ctx,
      messageId: (raw['message_id'] ?? '').toString(),
    );
  }

  /// 真实出站：sendmessage 文本消息（message_type=BOT, state=FINISH）。
  Future<void> sendText(String toUserId, String text,
      {String contextToken = ''}) async {
    if (token.isEmpty) {
      throw StateError('iLink 尚未完成扫码登录（不伪造发送）');
    }
    final msg = <String, dynamic>{
      'from_user_id': '',
      'to_user_id': toUserId,
      'client_id': 'tangram-${_rng.nextInt(1 << 32).toRadixString(16)}',
      'message_type': _messageTypeBot,
      'message_state': _stateFinish,
      'item_list': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': _itemText,
          'text_item': <String, dynamic>{'text': text},
        },
      ],
      if (contextToken.isNotEmpty) 'context_token': contextToken,
    };
    final resp = await _postJson('ilink/bot/sendmessage', <String, dynamic>{
      'msg': msg,
      'base_info': _baseInfo(),
    });
    if (resp == null) throw StateError('iLink 发送无响应');
    if (resp['ret'] != null && resp['ret'] != 0) {
      throw StateError(
          'iLink 发送失败 ret=${resp['ret']}: ${(resp['errmsg'] ?? '')}');
    }
  }

  void dispose() => _client.close();
}
