/// 飞书直连 —— 复刻官方 lark_oapi SDK `register_app()` 设备授权流（RFC 8628）
/// 的真实 HTTP 协议，让手机不经网关也能「点一下直接出真二维码」。
///
/// 协议依据（逐行读自 lark-oapi 1.7.1 wheel 包
/// `lark_oapi/scene/registration/__init__.py`，与本仓库 `im/feishu_bot.py`
/// 的调用方式一致）：
///  * 端点：`POST {domain}/oauth/v1/app/registration`，
///    `Content-Type: application/x-www-form-urlencoded`；
///    domain 默认 `https://accounts.feishu.cn`（轮询发现
///    `user_info.tenant_brand == "lark"` 时切 `https://accounts.larksuite.com`
///    继续轮询，同 SDK `_handle_poll_response`）。
///  * `action=init` → `supported_auth_methods` 必须含 `client_secret`；
///  * `action=begin`（`archetype=PersonalAgent`、`auth_method=client_secret`、
///    `request_user_info=open_id`）→ `device_code` / `interval`(默认 5s) /
///    `expires_in`(默认 600s) / `verification_uri_complete`；
///  * 二维码内容 = `verification_uri_complete` 追加 query：`from=sdk`、
///    `tp=sdk`、`source=dart-sdk/<source>`、app_preset 的 `name`/`desc`、
///    `addons`（JSON → gzip(mtime=0) → base64url 去填充，同 SDK
///    `_encode_addons`）。这是官方验证链接，飞书扫码即可创建应用；
///  * `action=poll&device_code=...` → 成功返回 `client_id`/`client_secret`
///    （可选 `user_info`）；`error` 字段 `authorization_pending`（等扫码）/
///    `slow_down`（interval+5s）/ `access_denied`（拒绝）/
///    `expired_token`（过期）。
///
/// 诚实原则：拿不到官方返回的 `verification_uri_complete`/`device_code`
/// 就抛 [FeishuDirectException]，绝不伪造二维码。确认成功后凭据经官方
/// `POST https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal`
/// 真实验证（端点出处：lark_oapi/core/token/create_self_tenant_token_request.py）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// 直连过程中的如实错误（网络不可达、官方端点未返回验证链接等）。
class FeishuDirectException implements Exception {
  const FeishuDirectException(this.message, {this.code = ''});
  final String message;
  final String code;

  @override
  String toString() => code.isEmpty ? message : '$code: $message';
}

/// 单次 `action=poll` 的结果，映射 SDK `_handle_poll_response` 的分支。
enum FeishuPollOutcome {
  pending,
  slowDown,
  domainSwitched,
  success,
  accessDenied,
  expired,
  error,
}

class FeishuPollResult {
  const FeishuPollResult(
    this.outcome, {
    this.clientId = '',
    this.clientSecret = '',
    this.userInfo,
    this.error = '',
    this.errorDescription = '',
  });

  final FeishuPollOutcome outcome;
  final String clientId;
  final String clientSecret;
  final Map<String, dynamic>? userInfo;
  final String error;
  final String errorDescription;
}

/// `action=begin` 的成功产物：真实设备码 + 官方验证 URL（二维码内容）。
class FeishuDirectTicket {
  const FeishuDirectTicket({
    required this.deviceCode,
    required this.verificationUrl,
    required this.intervalSeconds,
    required this.expiresIn,
  });

  final String deviceCode;

  /// 官方 verification_uri_complete（追加 preset/addons 参数后）——
  /// 飞书 App 扫这个码即可创建应用，内容 100% 来自官方端点。
  final String verificationUrl;
  final int intervalSeconds;
  final int expiresIn;
}

/// 一次直连登录对应一个 flow 实例（内部持有当前授权域名与 http client）。
class FeishuDirectFlow {
  FeishuDirectFlow({
    http.Client? client,
    this.source = 'tangram-app',
    this.domain = kAccountsFeishuDomain,
    this.larkDomain = kAccountsLarkDomain,
    this.appName,
    this.appDesc,
    this.addons,
    this.timeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _base = domain;

  static const String kAccountsFeishuDomain = 'https://accounts.feishu.cn';
  static const String kAccountsLarkDomain = 'https://accounts.larksuite.com';
  static const String kOpenApiBase = 'https://open.feishu.cn';
  static const String _endpoint = '/oauth/v1/app/registration';

  final http.Client _client;
  final bool _ownsClient;
  final String source;
  final String domain;
  final String larkDomain;
  final String? appName;
  final String? appDesc;
  final Map<String, dynamic>? addons;
  final Duration timeout;

  /// 当前生效域名：poll 发现 lark 国际版租户时切换（同 SDK `_base_url`）。
  String _base;
  bool _disposed = false;

  /// 第一步：init + begin，拿真实 device_code 与官方验证 URL。
  /// 任何一环拿不到就抛错，绝不返回可渲染的假码。
  Future<FeishuDirectTicket> begin() async {
    final Map<String, dynamic> init = await _post(<String, String>{
      'action': 'init',
    });
    final List<String> methods =
        (init['supported_auth_methods'] as List?)?.map((dynamic e) => e.toString()).toList() ??
            const <String>[];
    if (!methods.contains('client_secret')) {
      throw const FeishuDirectException(
        '飞书开放平台未提供 client_secret 授权方式，直连不可用',
        code: 'unsupported_auth_method',
      );
    }

    final Map<String, dynamic> begin = await _post(<String, String>{
      'action': 'begin',
      'archetype': 'PersonalAgent',
      'auth_method': 'client_secret',
      'request_user_info': 'open_id',
    });
    final String deviceCode = (begin['device_code'] ?? '').toString();
    final String verification =
        (begin['verification_uri_complete'] ?? '').toString();
    if (deviceCode.isEmpty ||
        verification.isEmpty ||
        Uri.tryParse(verification)?.hasScheme != true) {
      throw const FeishuDirectException(
        '飞书官方端点未返回真实 device_code / verification_uri_complete，'
        '本应用拒绝伪造二维码',
        code: 'no_verification_uri',
      );
    }
    final int interval = _asInt(begin['interval'], 5);
    final int expiresIn = _asInt(begin['expires_in'], 600);
    return FeishuDirectTicket(
      deviceCode: deviceCode,
      verificationUrl: _buildQrUrl(verification),
      intervalSeconds: interval < 1 ? 5 : interval,
      expiresIn: expiresIn <= 0 ? 600 : expiresIn,
    );
  }

  /// 第二步：轮询一次授权状态（由调用方按 interval 循环，直到终态/取消）。
  Future<FeishuPollResult> poll(String deviceCode) async {
    final Map<String, dynamic> j = await _post(<String, String>{
      'action': 'poll',
      'device_code': deviceCode,
    });
    return _handlePollResponse(j);
  }

  FeishuPollResult _handlePollResponse(Map<String, dynamic> data) {
    final String cid = (data['client_id'] ?? '').toString();
    final String secret = (data['client_secret'] ?? '').toString();
    final Map<String, dynamic>? userInfo = data['user_info'] is Map
        ? Map<String, dynamic>.from(data['user_info'] as Map)
        : null;

    // 成功：官方返回了完整凭据。
    if (cid.isNotEmpty && secret.isNotEmpty) {
      return FeishuPollResult(
        FeishuPollOutcome.success,
        clientId: cid,
        clientSecret: secret,
        userInfo: userInfo,
      );
    }

    // 租户是 Lark 国际版：切域名继续轮询（同 SDK，只切一次）。
    if (userInfo?['tenant_brand']?.toString().toLowerCase() == 'lark' &&
        _base != larkDomain) {
      _base = larkDomain;
      return FeishuPollResult(FeishuPollOutcome.domainSwitched, userInfo: userInfo);
    }

    final String error = (data['error'] ?? '').toString();
    final String desc = (data['error_description'] ?? '').toString();
    switch (error) {
      case 'authorization_pending':
        return const FeishuPollResult(FeishuPollOutcome.pending);
      case 'slow_down':
        return const FeishuPollResult(FeishuPollOutcome.slowDown);
      case 'access_denied':
        return FeishuPollResult(
          FeishuPollOutcome.accessDenied,
          error: error,
          errorDescription: desc,
        );
      case 'expired_token':
        return FeishuPollResult(
          FeishuPollOutcome.expired,
          error: error,
          errorDescription: desc,
        );
    }
    return FeishuPollResult(
      FeishuPollOutcome.error,
      error: error.isEmpty ? 'unknown_error' : error,
      errorDescription: desc,
    );
  }

  /// 用官方凭据真实验证一次：POST tenant_access_token/internal
  /// （端点抄自 lark_oapi/core/token/create_self_tenant_token_request.py）。
  /// 返回是否验证通过；网络失败返回 false，不谎报。
  Future<bool> verifyCredentials(String clientId, String clientSecret) async {
    try {
      final http.Response res = await _client
          .post(
            Uri.parse('$kOpenApiBase/open-apis/auth/v3/tenant_access_token/internal'),
            headers: const <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonEncode(<String, String>{
              'app_id': clientId,
              'app_secret': clientSecret,
            }),
          )
          .timeout(timeout);
      final Object? d = jsonDecode(utf8.decode(res.bodyBytes));
      return d is Map &&
          d['code'] == 0 &&
          (d['tenant_access_token'] ?? '').toString().isNotEmpty;
    } on Object {
      return false;
    }
  }

  /// 复刻 SDK `_build_qr_url`：在验证 URL 的 query 上追加来源与预置参数
  /// （urlencode doseq 语义 = 同名多值；这里用 queryParametersAll 等价实现）。
  String _buildQrUrl(String verificationUriComplete) {
    final Uri u = Uri.parse(verificationUriComplete);
    final Map<String, List<String>> params =
        Map<String, List<String>>.from(u.queryParametersAll);
    params['from'] = const <String>['sdk'];
    params['tp'] = const <String>['sdk'];
    params['source'] = <String>['dart-sdk/$source'];
    final String? name = appName;
    final String? desc = appDesc;
    if (name != null && name.trim().isNotEmpty) {
      params['name'] = <String>[name.trim()];
    }
    if (desc != null && desc.trim().isNotEmpty) {
      params['desc'] = <String>[desc.trim()];
    }
    final Map<String, dynamic>? a = addons;
    if (a != null) params['addons'] = <String>[encodeAddons(a)];
    return u.replace(queryParameters: params).toString();
  }

  /// 复刻 SDK `_encode_addons`：JSON → gzip(mtime=0) → base64url 去 '='。
  static String encodeAddons(Map<String, dynamic> addons) {
    final List<int> compressed = gzip.encode(utf8.encode(jsonEncode(addons)));
    return base64Url.encode(compressed).replaceAll('=', '');
  }

  Future<Map<String, dynamic>> _post(Map<String, String> form) async {
    final http.Response res;
    try {
      res = await _client
          .post(
            Uri.parse('$_base$_endpoint'),
            headers: const <String, String>{
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: form,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const FeishuDirectException(
        '连接飞书开放平台超时，拿不到真实验证链接',
        code: 'timeout',
      );
    }
    // 同 SDK：不依赖 HTTP 状态码判成败，以 JSON 里的 error/凭据字段为准。
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(res.bodyBytes));
    } on Object {
      decoded = null;
    }
    if (decoded is! Map) {
      throw FeishuDirectException(
        '飞书开放平台返回 HTTP ${res.statusCode} 且响应不是 JSON，'
        '无法解析设备授权流',
        code: 'bad_response',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  static int _asInt(Object? v, int fallback) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? fallback;
    return fallback;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_ownsClient) _client.close();
  }
}
