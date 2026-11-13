/// 扫码登录 REST 客户端 —— 对接仓库自带真实网关 `im/serve.py`（默认 :50432）。
///
/// 真实端点（抄自 im/serve.py，不是自拟协议）：
///   GET /api/login/wechat/qr      -> image/png（腾讯 iLink `qrcode_img_content`
///                                    渲染的真二维码）或 JSON 错误/降级
///   GET /api/login/wechat/status  -> {logged_in, bot_id, login_state}
///   GET /api/login/qq/qr          -> image/png（NapCat `get_login_qrcode`）
///   GET /api/login/qq/status      -> {online, user_id, nickname}
///
/// 兼容：若网关实现的是通用 `/tga/login/qr` + JSON 票据（见
/// `login_protocol.dart` 里抄自 freestylefly / HenryXiaoYang / ClawPanel 的
/// 字段），同样能解析。二维码内容/图片**只来自网关响应**，APP 不生成。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'package:tangram/harness/login_protocol.dart';

class QrLoginClient {
  QrLoginClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  /// 通用网关端点（当配置显式指定 login_path / status_path 或通道未内置时使用）。
  static const String kGenericLoginPath = '/tga/login/qr';
  static const String kGenericStatusPath = '/tga/login/status';
  static const String kGenericCancelPath = '/tga/login/cancel';

  /// 各通道在 `im/serve.py` 里的真实端点。[0]=二维码，[1]=状态。
  ///
  /// 飞书走官方设备授权流扫码建应用：`lark_oapi.register_app()` 返回真实
  /// 验证链接，网关渲染二维码；用户飞书扫码确认后自动拿到 App ID/Secret
  /// 并建长连接。三个通道的二维码都由网关真实下发，APP 不伪造。
  static const Map<String, List<String>> kPaths = <String, List<String>>{
    'wechat': <String>['/api/login/wechat/qr', '/api/login/wechat/status'],
    'qq': <String>['/api/login/qq/qr', '/api/login/qq/status'],
    'feishu': <String>['/api/login/feishu/qr', '/api/login/feishu/status'],
  };

  static String loginPathFor(String connector, [String? override]) {
    if (override != null && override.trim().isNotEmpty) return override.trim();
    final List<String>? p = kPaths[connector];
    return p != null ? p[0] : kGenericLoginPath;
  }

  static String statusPathFor(String connector, [String? override]) {
    if (override != null && override.trim().isNotEmpty) return override.trim();
    final List<String>? p = kPaths[connector];
    return p != null ? p[1] : kGenericStatusPath;
  }

  /// 从 ws(s):// 网关地址推导 http(s) 源（丢弃 /ws 之类的 WebSocket 路径）。
  static Uri originOf(String gatewayUrl) {
    final Uri? u = Uri.tryParse(gatewayUrl.trim());
    if (u == null || u.host.isEmpty) {
      throw const QrLoginException('网关地址无效：请先填写完整的 ws(s):// 地址');
    }
    final String s = u.scheme.toLowerCase();
    if (s != 'ws' && s != 'wss' && s != 'http' && s != 'https') {
      throw const QrLoginException(
          '网关地址必须使用 ws:// / wss:// / http:// / https://');
    }
    final bool tls = s == 'wss' || s == 'https';
    return Uri(
      scheme: tls ? 'https' : 'http',
      host: u.host,
      port: u.hasPort ? u.port : null,
    );
  }

  Uri _endpoint(
    String gatewayUrl,
    String path,
    Map<String, String> query,
  ) {
    final Uri origin = originOf(gatewayUrl);
    // 加一个时间戳，避免手机/代理缓存住已过期的二维码。
    return origin.replace(
      path: path,
      queryParameters: <String, String>{...query, '_': '${DateTime.now().millisecondsSinceEpoch}'},
    );
  }

  Map<String, dynamic> _decodeJson(http.Response res) {
    try {
      final Object? d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map) return Map<String, dynamic>.from(d);
    } on Object {
      // fall through
    }
    throw const QrLoginException('网关返回的不是有效 JSON，无法解析登录响应');
  }

  void _checkHttp(http.Response res) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    String detail = '';
    try {
      final Object? d = jsonDecode(utf8.decode(res.bodyBytes));
      if (d is Map) {
        detail = (d['hint'] ?? d['error'] ?? d['reason'] ?? '').toString();
      }
    } on Object {
      detail = '';
    }
    throw QrLoginException(
      detail.isNotEmpty
          ? '网关 HTTP ${res.statusCode}：$detail'
          : '网关返回 HTTP ${res.statusCode}',
      statusCode: res.statusCode,
    );
  }

  /// 第一步：向网关申请**真实**登录二维码。
  ///
  /// `im/serve.py` 直接返回 image/png 二进制；也兼容返回 JSON 票据的通用网关。
  /// 上游没下发任何二维码时抛错，绝不本地造码。
  Future<QrLoginTicket> requestQr({
    required String gatewayUrl,
    required String connector,
    String guid = '',
    String token = '',
    String? loginPath,
  }) async {
    final String path = loginPathFor(connector, loginPath);
    final Uri uri = _endpoint(gatewayUrl, path, <String, String>{
      'connector': connector,
      if (guid.isNotEmpty) 'guid': guid,
      if (token.isNotEmpty) 'token': token,
    });
    final http.Response res = await _client.get(uri).timeout(timeout);
    final String ctype = (res.headers['content-type'] ?? '').toLowerCase();

    // 情形一：网关直接下发二维码图片（im/serve.py 的 _wechat_login_qr /
    // _qq_login_qr 走 _send(200, png, "image/png")）。
    if (ctype.contains('image/') || _looksLikePng(res.bodyBytes)) {
      if (res.bodyBytes.isEmpty) {
        throw const QrLoginException('网关返回了空的二维码图片');
      }
      return QrLoginTicket(
        // im.serve 用网关内部状态机维护登录会话，APP 无需持有 session_id。
        sessionId: '',
        connector: connector,
        qrContent: '',
        qrImageBytes: Uint8List.fromList(res.bodyBytes),
        expiresIn: 300,
      );
    }

    _checkHttp(res);
    final Map<String, dynamic> j = _decodeJson(res);

    // 情形二：网关已有登录态，无需再扫码。
    if (j['already_logged_in'] == true || j['logged_in'] == true) {
      throw const QrLoginAlreadyLoggedIn();
    }
    if (j['ok'] == false) {
      throw QrLoginException(
        (j['hint'] ?? j['error'] ?? j['reason'] ?? '网关拒绝生成二维码')
            .toString(),
      );
    }
    // 情形三：通用 JSON 票据（qr_content / qrCodeUrl / base64 图片 …）。
    final QrLoginTicket? ticket =
        QrLoginTicket.fromJson(j, connector: connector);
    if (ticket == null || !ticket.hasRenderableQr) {
      throw const QrLoginException(
        '网关未下发二维码内容。二维码必须由网关真实生成，本应用不伪造、'
        '也不会用本地占位码骗你扫。请确认网关已启动并接入微信/QQ 登录服务。',
      );
    }
    return ticket;
  }

  bool _looksLikePng(List<int> b) =>
      b.length >= 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47;

  /// 第二步：轮询扫码状态。兼容 im.serve 的 logged_in/login_state/online
  /// 以及通用网关的 status 字段。
  Future<QrLoginResult> pollStatus({
    required String gatewayUrl,
    required String sessionId,
    String connector = 'wechat',
    String? statusPath,
  }) async {
    final String path = statusPathFor(connector, statusPath);
    final Uri uri = _endpoint(gatewayUrl, path, <String, String>{
      'connector': connector,
      if (sessionId.isNotEmpty) 'session_id': sessionId,
    });
    final http.Response res = await _client.get(uri).timeout(timeout);
    _checkHttp(res);
    final Map<String, dynamic> j = _decodeJson(res);
    if (j['ok'] == false) {
      return QrLoginResult(
        status: QrLoginStatus.error,
        error: (j['hint'] ?? j['error'] ?? j['reason'] ?? '网关状态查询失败')
            .toString(),
      );
    }
    return QrLoginResult.fromJson(j);
  }

  /// 取消登录会话。im.serve 无此端点，失败静默忽略（不影响本地清理）。
  Future<void> cancel({
    required String gatewayUrl,
    required String sessionId,
    String? cancelPath,
  }) async {
    try {
      final Uri uri = _endpoint(
        gatewayUrl,
        cancelPath?.trim().isNotEmpty == true
            ? cancelPath!.trim()
            : kGenericCancelPath,
        <String, String>{'session_id': sessionId},
      );
      await _client.post(uri).timeout(timeout);
    } on Object {
      // 取消失败不影响本地状态清理。
    }
  }

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
