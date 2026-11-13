/// 扫码登录 REST 契约（纯 Dart）。
///
/// 协议来源 —— 全部抄自 OpenClaw 通道真实实现，不是自拟格式：
///
///  * `freestylefly/openclaw-wechat` `src/proxy-client.ts`
///    `POST /v1/iPadLogin` -> `{ qrCodeUrl, wId }`；
///    `POST /v1/getIPadLoginInfo` -> `status: logged_in | need_verify | waiting`，
///    登录轮询 60 次 × 5s = 5 分钟（即「真码 5 分钟有效」）。
///  * `HenryXiaoYang/wechat-openclaw-channel` `auth/wechat-qr-poll.ts`
///    微信开放平台 `qrconnect` -> `uuid` -> `/connect/qrcode/{uuid}` 图片，
///    长轮询 `wx_errcode`: 408 等待 / 404 已扫待确认 / 405 已确认 / 403·402 过期。
///  * `ClawPanel` `web/src/lib/api.ts`（QQ 侧 / NapCat）
///    `POST /napcat/qrcode`、`POST /napcat/login-status`、`GET /wechat/login-url`、
///    `GET /status` 10s 轮询（看门狗自愈）。
///
/// 设计原则与 harness 一致：**二维码内容只能来自网关真实下发**。
/// 本文件不生成、不拼接、不猜测任何二维码内容；上游没给就解析失败并如实报错。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 扫码登录状态机（合并了三套上游的状态词）。
enum QrLoginStatus {
  idle,
  waiting,
  scanned,
  confirmed,
  expired,
  needVerify,
  error,
}

extension QrLoginStatusWire on QrLoginStatus {
  String get wire => switch (this) {
        QrLoginStatus.idle => 'idle',
        QrLoginStatus.waiting => 'waiting',
        QrLoginStatus.scanned => 'scanned',
        QrLoginStatus.confirmed => 'confirmed',
        QrLoginStatus.expired => 'expired',
        QrLoginStatus.needVerify => 'need_verify',
        QrLoginStatus.error => 'error',
      };

  bool get isTerminal => this == QrLoginStatus.confirmed ||
      this == QrLoginStatus.expired ||
      this == QrLoginStatus.error;

  /// 兼容解析上游各种状态词，未知一律 error（不猜、不谎报成功）。
  static QrLoginStatus parse(Object? v) {
    final s = (v ?? '').toString().trim().toLowerCase();
    return switch (s) {
      'idle' || 'none' || 'init' => QrLoginStatus.idle,
      'waiting' || 'pending' || 'wait' || 'not_logged_in' || 'qr_ready' ||
      '408' => QrLoginStatus.waiting,
      'scanned' || 'scaned' || 'scanned_wait_confirm' || '404' =>
        QrLoginStatus.scanned,
      'confirmed' || 'logged_in' || 'login_success' || 'success' || 'ok' ||
      'online' || '405' => QrLoginStatus.confirmed,
      'expired' || 'timeout' || 'qr_expired' || '403' || '402' =>
        QrLoginStatus.expired,
      'need_verify' || 'verify' || 'needverify' || 'need_authentication' =>
        QrLoginStatus.needVerify,
      'error' || 'failed' || 'failure' || _ => QrLoginStatus.error,
    };
  }
}

/// 从网关响应里取第一个非空字符串字段。
String? _firstString(Map<String, dynamic> j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
  }
  return null;
}

int? _firstInt(Map<String, dynamic> j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) {
      final n = int.tryParse(v.trim());
      if (n != null) return n;
    }
  }
  return null;
}

/// 解 base64 / data URL 二维码图片。失败返回 null（不伪造图片）。
Uint8List? _decodeImage(Object? raw) {
  if (raw == null) return null;
  String s = raw.toString().trim();
  if (s.isEmpty) return null;
  final comma = s.indexOf(',');
  if (s.startsWith('data:') && comma > 0) s = s.substring(comma + 1);
  try {
    final Uint8List bytes = base64Decode(s.replaceAll(RegExp(r'\s'), ''));
    return bytes.isEmpty ? null : bytes;
  } on Object {
    return null;
  }
}

/// `POST /tga/login/qr` 的响应 —— 网关下发的登录二维码票据。
class QrLoginTicket {
  const QrLoginTicket({
    required this.sessionId,
    required this.connector,
    required this.qrContent,
    this.qrImageBytes,
    this.qrUrl,
    this.expiresIn = 300,
    this.verifyUrl,
  });

  /// 会话标识（对应 freestylefly 的 `wId`、微信 qrconnect 的 `uuid`）。
  final String sessionId;

  final String connector;

  /// **二维码真实内容**（授权 URL / 登录串）。由网关下发，APP 只负责渲染。
  /// 绝不允许为空 —— 为空意味着上游没给码，必须报错而不是本地编一个。
  final String qrContent;

  /// 网关直接下发的二维码图片（部分上游只给图片不给内容）。
  final Uint8List? qrImageBytes;

  /// 二维码图片 URL（可作为 qrContent 的可读来源 / 刷新用）。
  final String? qrUrl;

  /// 有效期（秒）。对齐上游的 5 分钟真码。
  final int expiresIn;

  final String? verifyUrl;

  bool get hasRenderableQr => qrContent.isNotEmpty || qrImageBytes != null;

  /// 兼容三套上游字段命名。解析不出二维码内容时返回 null。
  static QrLoginTicket? fromJson(
    Map<String, dynamic> j, {
    String connector = 'wechat',
  }) {
    // 上游可能把字段嵌在 data / result / payload 里。
    final Map<String, dynamic> body = _unwrap(j);

    // 会话 ID 可为空：`im/serve.py` 由网关内部状态机维护登录会话，
    // 二维码图片本身就是凭证，APP 不需要持有 session_id。
    final String session = _firstString(body, <String>[
          'session_id', 'sessionId', 'session', 'wId', 'wid', 'uuid',
          'login_id', 'loginId', 'state', 'qr_id', 'qrId',
        ]) ??
        '';

    // 二维码内容：可能直接给授权串，也可能给二维码图片 URL（可直接渲染成码）。
    String? content = _firstString(body, <String>[
      'qr_content', 'qrContent', 'qr_data', 'qrData', 'qrcode_content',
      'qr_text', 'qrText', 'auth_url', 'authUrl', 'qrconnect_url',
      'login_url', 'loginUrl', 'qr_code', 'qrCode', 'qrcode', 'content', 'url',
    ]);
    String? url = _firstString(body, <String>[
      'qr_code_url', 'qrCodeUrl', 'qrcode_url', 'qrcodeUrl', 'qr_url', 'qrUrl',
      'image_url', 'imageUrl',
    ]);

    // freestylefly 的 `qrCodeUrl` 本身就是可扫的二维码内容/图片地址。
    if ((content == null || content.isEmpty) && url != null) content = url;
    // 微信 qrconnect 的 uuid 可拼出二维码图片地址，但内容仍需上游确认。
    // 这里不做拼接：只把 uuid 当 sessionId，二维码以下发内容/图片为准。

    final Uint8List? image = _decodeImage(
      body['qr_image_base64'] ??
          body['qrImageBase64'] ??
          body['qr_image'] ??
          body['qrImage'] ??
          body['qrcode_base64'] ??
          body['image_base64'] ??
          body['image'] ??
          body['qrcodeImage'],
    );

    if ((content == null || content.isEmpty) && image == null) {
      // 上游没下发任何二维码 —— 拒绝伪造。
      return null;
    }

    final int ttl = _firstInt(body, <String>[
      'expires_in', 'expiresIn', 'expire', 'expire_in', 'ttl', 'timeout',
      'valid_seconds',
    ]) ?? 300;

    return QrLoginTicket(
      sessionId: session,
      connector: (body['connector'] ?? connector).toString(),
      qrContent: content ?? '',
      qrImageBytes: image,
      qrUrl: url,
      expiresIn: ttl <= 0 ? 300 : ttl,
      verifyUrl: _firstString(body, <String>[
        'verify_url', 'verifyUrl', 'verification_url',
      ]),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'session_id': sessionId,
        'connector': connector,
        'qr_content': qrContent,
        'expires_in': expiresIn,
        if (qrUrl != null) 'qr_url': qrUrl,
        if (verifyUrl != null) 'verify_url': verifyUrl,
        if (qrImageBytes != null) 'qr_image_bytes': qrImageBytes!.length,
      };
}

/// `GET /tga/login/status` 的响应 —— 扫码结果，成功时携带 AGP 连接凭据。
class QrLoginResult {
  const QrLoginResult({
    required this.status,
    this.wsUrl,
    this.guid,
    this.token,
    this.nickname,
    this.verifyUrl,
    this.code,
    this.error,
  });

  final QrLoginStatus status;

  /// 登录成功后网关下发的真实 AGP WebSocket 地址与凭据。
  final String? wsUrl;
  final String? guid;
  final String? token;
  final String? nickname;
  final String? verifyUrl;

  /// 微信 OAuth code（部分上游只回 code，由网关再换 token）。
  final String? code;
  final String? error;

  /// confirmed 是否具备建立真实连接所需的最小凭据。
  bool get hasCredentials =>
      status == QrLoginStatus.confirmed &&
      wsUrl != null &&
      wsUrl!.trim().isNotEmpty;

  static QrLoginResult fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> body = _unwrap(j);
    final Object? rawStatus = body['status'] ?? body['state'] ??
        body['login_status'] ?? body['loginStatus'] ?? body['wx_errcode'];
    QrLoginStatus st = QrLoginStatusWire.parse(rawStatus);
    final String? err = _firstString(body, <String>['error', 'message', 'msg']);
    final String? reason = _firstString(body, <String>['hint', 'reason']);

    // `im/serve.py` 的真实状态响应：
    //   微信 {logged_in, bot_id, login_state: idle|waiting_scan|scanned|logged_in}
    //   QQ   {online, user_id, nickname} 或 {online:false, reason}
    final bool loggedIn =
        body['logged_in'] == true || body['already_logged_in'] == true;
    final bool online = body['online'] == true;
    final String loginState =
        (body['login_state'] ?? '').toString().trim().toLowerCase();
    if (loggedIn || online) {
      st = QrLoginStatus.confirmed;
    } else if (loginState == 'scanned' || loginState == 'scaned') {
      st = QrLoginStatus.scanned;
    } else if (loginState == 'expired' || loginState == 'timeout') {
      st = QrLoginStatus.expired;
    } else if (loginState == 'waiting_scan' || loginState == 'idle') {
      st = QrLoginStatus.waiting;
    }

    // 上游只回 code / token 而没回 status 时，按真实凭据判定成功。
    final String? code = _firstString(body, <String>['code', 'wx_code', 'wxCode']);
    final String? ws = _firstString(body, <String>[
      'ws_url', 'wsUrl', 'wss_url', 'websocket_url', 'wechatWsUrl',
      'gateway_url', 'gatewayUrl', 'agent_ws',
    ]);
    final String? problem = err ?? reason;
    if (st != QrLoginStatus.confirmed && (ws != null || code != null) &&
        problem == null) {
      st = QrLoginStatus.confirmed;
    }
    // 只有显式 error/message/msg 才把状态置为失败；hint/reason 仅作展示文本，
    // 避免网关「等待 NapCat 启动」之类提示被误判成接入失败。
    if (err != null && st != QrLoginStatus.confirmed) {
      st = QrLoginStatus.error;
    }

    return QrLoginResult(
      status: st,
      wsUrl: ws,
      guid: _firstString(body, <String>[
        'guid', 'device_guid', 'deviceGuid', 'device_id',
      ]),
      token: _firstString(body, <String>[
        'token', 'channel_token', 'openclaw_channel_token', 'jwt_token',
        'jwtToken', 'access_token',
      ]),
      nickname: _firstString(body, <String>[
        'nickname', 'nickName', 'nick_name', 'user_name', 'wcId', 'bot_id',
      ]),
      verifyUrl: _firstString(body, <String>[
        'verify_url', 'verifyUrl', 'verification_url',
      ]),
      code: code,
      error: st == QrLoginStatus.error ? (problem ?? '登录状态异常') : null,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'status': status.wire,
        if (wsUrl != null) 'ws_url': wsUrl,
        if (guid != null) 'guid': guid,
        if (token != null) 'token': token,
        if (nickname != null) 'nickname': nickname,
        if (verifyUrl != null) 'verify_url': verifyUrl,
        if (code != null) 'code': code,
        if (error != null) 'error': error,
      };
}

/// 上游常把有效载荷包一层，这里统一剥开（不改变字段语义）。
Map<String, dynamic> _unwrap(Map<String, dynamic> j) {
  for (final k in <String>['data', 'result', 'payload', 'resp']) {
    final v = j[k];
    if (v is Map) {
      final Map<String, dynamic> inner = Map<String, dynamic>.from(v);
      if (inner.isNotEmpty) return <String, dynamic>{...j, ...inner};
    }
  }
  return j;
}

/// 网关返回错误 / 未下发二维码时抛出，供 UI 如实展示。
class QrLoginException implements Exception {
  const QrLoginException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 网关已有登录态、无需再扫码。`im/serve.py` 的 `_wechat_login_qr` 在
/// `wx.has_token` 为真时返回 `{ok:true, already_logged_in:true}`。
/// 调用方应跳过二维码展示，直接走状态确认与连接流程。
class QrLoginAlreadyLoggedIn implements Exception {
  const QrLoginAlreadyLoggedIn();

  @override
  String toString() => '网关已登录';
}
