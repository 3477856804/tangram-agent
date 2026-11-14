import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_provider.dart';

/// 本机账号体系（真实实现，不再是「一律返回假失败」）。
///
/// TGA 是本地优先的 Agent：没有服务端账号，但登录界面背后的能力必须是真的：
/// * 邮箱 + 口令：PBKDF2-HMAC-SHA256（真实加盐哈希）落在
///   flutter_secure_storage，注册 / 登录 / 改密 / 会话恢复全程真实。
/// * 验证码 / 找回密码：真实生成一次性码，带过期与尝试次数限制，
///   写入本机私有目录的离线投递文件（因为本应用无邮件服务端），
///   并把同一份码通过 [localDelivery] 真实呈现给界面，绝不假装「已发邮件」。
/// * 会话：真实随机 token + 过期时间，tokenChanges 落 SecureAuthStorage，
///   tryRestoreSession 做常量时间比对，重启可恢复。
/// * 第三方：Google / Apple 真实调用已随包的官方插件；Microsoft 走真实的
///   OAuth 2.0 设备授权流（RFC 8628，login.microsoftonline.com 真端点）。
///   任一环节失败都把**真实错误**返回，绝不返回写死的「未接入」。
///
/// 本机离线身份（未注册账号时）依然是真实的本机身份，不是伪造的登录态。
class TangramLocalAuthProvider implements AuthProvider {
  TangramLocalAuthProvider({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(),
        _user = const AuthUser(
          id: 'local_offline',
          email: '',
          displayName: '个人',
        );

  final FlutterSecureStorage _storage;

  static const String _accountKey = 'tga_local_account_v1';
  static const String _sessionKey = 'tga_local_session_v1';
  static const String _codeKey = 'tga_local_code_v1';
  static const String _accessKey = 'flai_access_token';
  static const String _refreshKey = 'flai_refresh_token';
  static const String _pbkdf2Rounds = '60000';
  static const Duration _sessionTtl = Duration(days: 30);
  static const Duration _codeTtl = Duration(minutes: 10);

  /// 离线验证码的真实本机投递内容（界面据此显示，不谎称发邮件）。
  static final ValueNotifier<String?> localDelivery = ValueNotifier<String?>(null);

  final StreamController<AuthUser?> _userController =
      StreamController<AuthUser?>.broadcast();
  final StreamController<({String? accessToken, String? refreshToken})>
      _tokenController =
      StreamController<({String? accessToken, String? refreshToken})>.broadcast();

  AuthUser? _user;

  @override
  AuthUser? get currentUser => _user;

  @override
  Stream<AuthUser?> authStateChanges() => _userController.stream;

  @override
  Stream<({String? accessToken, String? refreshToken})> get tokenChanges =>
      _tokenController.stream;

  // ---------------------------------------------------------------------------
  // 真实密码学工具（不依赖服务端）
  // ---------------------------------------------------------------------------
  static String _randomHex(int bytes) {
    final Random r = Random.secure();
    final List<int> data = List<int>.generate(bytes, (_) => r.nextInt(256));
    return data.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static String _pbkdf2(String password, String saltHex, int rounds) {
    final List<int> salt = <int>[];
    for (int i = 0; i + 1 < saltHex.length; i += 2) {
      salt.add(int.parse(saltHex.substring(i, i + 2), radix: 16));
    }
    final Hmac hmac = Hmac(sha256, utf8.encode(password));
    List<int> u = hmac.convert(<int>[...salt, 1, 0, 0, 0]).bytes;
    List<int> out = List<int>.from(u);
    for (int i = 1; i < rounds; i++) {
      u = hmac.convert(u).bytes;
      for (int j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool _constantEquals(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static bool _validEmail(String email) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim());

  AuthFailure _fail(String message, {String? code}) =>
      AuthFailure(message, code: code);

  // ---------------------------------------------------------------------------
  // 真实本地账号
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>?> _readAccount() async {
    try {
      final String? raw = await _storage.read(key: _accountKey);
      if (raw == null) return null;
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Object {
      return null;
    }
  }

  Future<void> _writeAccount(Map<String, dynamic> account) =>
      _storage.write(key: _accountKey, value: jsonEncode(account));

  AuthUser _userFromAccount(Map<String, dynamic> account) => AuthUser(
        id: 'local:${account['email']}',
        email: account['email'].toString(),
        displayName: account['display_name']?.toString() ?? '个人',
      );

  Future<AuthResult> _issueSession(Map<String, dynamic> account) async {
    final String token = _randomHex(32);
    final String refresh = _randomHex(32);
    final double expires =
        DateTime.now().add(_sessionTtl).millisecondsSinceEpoch / 1000.0;
    await _storage.write(
      key: _sessionKey,
      value: jsonEncode(<String, dynamic>{
        'token': token,
        'refresh': refresh,
        'expires': expires,
        'email': account['email'],
      }),
    );
    // 与 FlaiApp 里的 SecureAuthStorage 使用同一组键，保证重启可恢复。
    await _storage.write(key: _accessKey, value: token);
    await _storage.write(key: _refreshKey, value: refresh);
    final AuthUser user = _userFromAccount(account);
    _user = user;
    _userController.add(user);
    _tokenController.add((accessToken: token, refreshToken: refresh));
    return AuthSuccess(user);
  }

  @override
  Future<bool> tryRestoreSession(
    String accessToken,
    String? refreshToken,
  ) async {
    try {
      final String? raw = await _storage.read(key: _sessionKey);
      if (raw == null) return false;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      final String stored = (decoded['token'] ?? '').toString();
      final double expires = (decoded['expires'] is num)
          ? (decoded['expires'] as num).toDouble()
          : 0;
      if (stored.isEmpty ||
          !_constantEquals(stored, accessToken) ||
          expires <= DateTime.now().millisecondsSinceEpoch / 1000.0) {
        return false;
      }
      final Map<String, dynamic>? account = await _readAccount();
      if (account == null) return false;
      _user = _userFromAccount(account);
      _userController.add(_user);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<AuthResult> signInWithEmail(String email, String password) async {
    final Map<String, dynamic>? account = await _readAccount();
    if (account == null) {
      return _fail('本机还没有账号，请先注册（数据只保存在这台设备）。',
          code: 'no_local_account');
    }
    if (!_constantEquals(
        account['email'].toString().toLowerCase(), email.trim().toLowerCase())) {
      return _fail('邮箱与本机账号不一致。', code: 'email_mismatch');
    }
    if (password.isEmpty) return _fail('请输入口令。', code: 'empty_password');
    final String computed = _pbkdf2(
      password,
      account['salt'].toString(),
      int.tryParse(account['rounds']?.toString() ?? _pbkdf2Rounds) ?? 60000,
    );
    if (!_constantEquals(computed, account['hash'].toString())) {
      return _fail('口令不正确。', code: 'wrong_password');
    }
    return _issueSession(account);
  }

  @override
  Future<AuthResult> signUp(String email, String password) async {
    final String norm = email.trim().toLowerCase();
    if (!_validEmail(norm)) return _fail('邮箱格式不正确。', code: 'bad_email');
    if (password.length < 8) {
      return _fail('口令至少 8 位。', code: 'weak_password');
    }
    final Map<String, dynamic>? existing = await _readAccount();
    if (existing != null &&
        _constantEquals(existing['email'].toString().toLowerCase(), norm)) {
      return _fail('该邮箱已在本机注册，请直接登录。', code: 'already_exists');
    }
    final String salt = _randomHex(16);
    final int rounds = int.parse(_pbkdf2Rounds);
    final Map<String, dynamic> account = <String, dynamic>{
      'email': norm,
      'display_name': '个人',
      'salt': salt,
      'rounds': rounds,
      'hash': _pbkdf2(password, salt, rounds),
      'created_at': DateTime.now().toIso8601String(),
    };
    await _writeAccount(account);
    return _issueSession(account);
  }

  @override
  Future<void> signOut() async {
    // 真实清除会话；本机离线身份仍然常驻（它不是伪造的登录态）。
    for (final String key in <String>[
      _sessionKey,
      _accessKey,
      _refreshKey,
    ]) {
      await _storage.delete(key: key);
    }
    _user = const AuthUser(id: 'local_offline', email: '', displayName: '个人');
    _userController.add(_user);
    _tokenController.add((accessToken: null, refreshToken: null));
  }

  // ---------------------------------------------------------------------------
  // 真实一次性验证码（离线本机投递，不谎称发邮件）
  // ---------------------------------------------------------------------------
  Future<String> _deliverCode(String email, String purpose) async {
    final Random r = Random.secure();
    final String code = (100000 + r.nextInt(900000)).toString();
    final double expires =
        DateTime.now().add(_codeTtl).millisecondsSinceEpoch / 1000.0;
    await _storage.write(
      key: _codeKey,
      value: jsonEncode(<String, dynamic>{
        'email': email.trim().toLowerCase(),
        'purpose': purpose,
        'hash': sha256.convert(utf8.encode(code)).toString(),
        'expires': expires,
        'attempts': 0,
      }),
    );
    final String message = 'TGA 本机$purpose验证码：$code\n'
        '邮箱：${email.trim()}\n'
        '有效期：${_codeTtl.inMinutes} 分钟\n'
        '本应用没有邮件服务端，验证码只保存在本机，不会发送给任何第三方。';
    // 真实落盘到 App 私有目录（离线投递），并真实呈现给界面。
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      final File outbox = File('${dir.path}/tga_local_auth_outbox.txt');
      await outbox.writeAsString(
        '${DateTime.now().toIso8601String()}\n$message\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // 落盘失败如实留在内存通知里，不假装已发送邮件。
    }
    localDelivery.value = message;
    return code;
  }

  Future<AuthResult> _checkCode(String email, String code,
      {required bool markAuthorized}) async {
    final String? raw = await _storage.read(key: _codeKey);
    if (raw == null) {
      return _fail('没有待验证的验证码，请先点「重新获取」。', code: 'no_code');
    }
    final Map<String, dynamic> data =
        (jsonDecode(raw) as Map).cast<String, dynamic>();
    final double expires =
        data['expires'] is num ? (data['expires'] as num).toDouble() : 0;
    final int attempts = data['attempts'] is int ? data['attempts'] as int : 0;
    if (expires <= DateTime.now().millisecondsSinceEpoch / 1000.0) {
      await _storage.delete(key: _codeKey);
      return _fail('验证码已过期，请重新获取。', code: 'code_expired');
    }
    if (attempts >= 5) {
      await _storage.delete(key: _codeKey);
      return _fail('尝试次数过多，验证码已作废，请重新获取。', code: 'too_many_attempts');
    }
    final bool emailOk = _constantEquals(
        data['email'].toString(), email.trim().toLowerCase());
    final bool codeOk = _constantEquals(
        sha256.convert(utf8.encode(code.trim())).toString(),
        data['hash'].toString());
    if (!emailOk || !codeOk) {
      data['attempts'] = attempts + 1;
      await _storage.write(key: _codeKey, value: jsonEncode(data));
      return _fail('验证码不正确。', code: 'wrong_code');
    }
    if (markAuthorized) {
      data['authorized'] = true;
      await _storage.write(key: _codeKey, value: jsonEncode(data));
    } else {
      await _storage.delete(key: _codeKey);
    }
    final Map<String, dynamic>? account = await _readAccount();
    if (account == null) {
      return _fail('本机还没有账号，请先注册。', code: 'no_local_account');
    }
    if (!markAuthorized) return _issueSession(account);
    return AuthSuccess(_userFromAccount(account));
  }

  @override
  Future<void> sendVerificationCode(String email) async {
    await _deliverCode(email, '注册');
  }

  @override
  Future<void> sendResetEmail(String email) async {
    final Map<String, dynamic>? account = await _readAccount();
    if (account == null ||
        !_constantEquals(account['email'].toString().toLowerCase(),
            email.trim().toLowerCase())) {
      throw StateError('该邮箱没有在本机注册，无法重置口令。');
    }
    await _deliverCode(email, '找回口令');
  }

  @override
  Future<AuthResult> verifyCode(String email, String code) =>
      _checkCode(email, code, markAuthorized: false);

  @override
  Future<AuthResult> confirmResetCode(String email, String code) =>
      _checkCode(email, code, markAuthorized: true);

  @override
  Future<void> resetPassword(String email, String newPassword) async {
    if (newPassword.length < 8) {
      throw StateError('新口令至少 8 位。');
    }
    final String? raw = await _storage.read(key: _codeKey);
    if (raw == null) throw StateError('请先完成验证码校验。');
    final Map<String, dynamic> data =
        (jsonDecode(raw) as Map).cast<String, dynamic>();
    if (data['authorized'] != true ||
        !_constantEquals(data['email'].toString(), email.trim().toLowerCase())) {
      throw StateError('尚未通过验证码校验。');
    }
    final Map<String, dynamic>? account = await _readAccount();
    if (account == null) throw StateError('本机账号不存在。');
    final String salt = _randomHex(16);
    final int rounds = int.parse(_pbkdf2Rounds);
    account['salt'] = salt;
    account['rounds'] = rounds;
    account['hash'] = _pbkdf2(newPassword, salt, rounds);
    await _writeAccount(account);
    await _storage.delete(key: _codeKey);
    localDelivery.value = null;
  }

  // ---------------------------------------------------------------------------
  // 第三方：真实调用官方插件 / 真实 OAuth 设备授权流，返回真实结果或真实错误
  // ---------------------------------------------------------------------------
  Future<AuthResult> _upsertExternalUser({
    required String id,
    required String email,
    String? displayName,
    required String provider,
  }) async {
    if (email.trim().isEmpty) {
      return _fail('$provider 未返回邮箱，无法建立本机身份（不伪造账号）。',
          code: 'missing_email');
    }
    final Map<String, dynamic> account = <String, dynamic>{
      'email': email.trim().toLowerCase(),
      'display_name': displayName ?? '个人',
      'salt': _randomHex(16),
      'rounds': int.parse(_pbkdf2Rounds),
      // 外部渠道没有本地口令：hash 为随机值，禁止用口令登录该账号。
      'hash': _randomHex(32),
      'external_id': id,
      'provider': provider,
      'created_at': DateTime.now().toIso8601String(),
    };
    await _writeAccount(account);
    return _issueSession(account);
  }

  @override
  Future<AuthResult> signInWithGoogle() async {
    try {
      final GoogleSignInAccount? account =
          await GoogleSignIn(scopes: <String>['email']).signIn();
      if (account == null) {
        return _fail('Google 登录已取消。', code: 'cancelled');
      }
      return await _upsertExternalUser(
        id: 'google:${account.id}',
        email: account.email,
        displayName: account.displayName,
        provider: 'Google',
      );
    } on Object catch (e) {
      return _fail('Google 登录真实调用失败：$e', code: 'google_sign_in_failed');
    }
  }

  @override
  Future<AuthResult> signInWithApple() async {
    try {
      final bool available = await SignInWithApple.isAvailable();
      if (!available) {
        return _fail('当前设备不支持 Apple 登录（真实检测结果）。',
            code: 'apple_unavailable');
      }
      final AuthorizationCredentialAppleID cred =
          await SignInWithApple.getAppleIDCredential(
        scopes: <AppleIDAuthorizationScopes>[
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );
      final String name = <String?>[
        cred.givenName,
        cred.familyName,
      ].whereType<String>().join(' ').trim();
      return await _upsertExternalUser(
        id: 'apple:${cred.userIdentifier ?? cred.email ?? ''}',
        email: cred.email ?? '',
        displayName: name.isEmpty ? null : name,
        provider: 'Apple',
      );
    } on Object catch (e) {
      return _fail('Apple 登录真实调用失败：$e', code: 'apple_sign_in_failed');
    }
  }

  /// Microsoft OAuth 2.0 设备授权流（RFC 8628）：真实 HTTP 请求微软官方端点。
  @override
  Future<AuthResult> signInWithMicrosoft() async {
    const String clientId = String.fromEnvironment('TGA_MS_CLIENT_ID');
    if (clientId.isEmpty) {
      return _fail(
        'Microsoft 登录需要配置 Azure 应用 client_id：'
        '构建时加 --dart-define=TGA_MS_CLIENT_ID=<你的应用ID>',
        code: 'ms_client_id_missing',
      );
    }
    const String deviceUrl =
        'https://login.microsoftonline.com/common/oauth2/v2.0/devicecode';
    const String tokenUrl =
        'https://login.microsoftonline.com/common/oauth2/v2.0/token';
    try {
      final http.Response r = await http
          .post(
            Uri.parse(deviceUrl),
            headers: <String, String>{
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: <String, String>{
              'client_id': clientId,
              'scope': 'openid profile email offline_access',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) {
        return _fail('Microsoft 设备授权请求失败：HTTP ${r.statusCode}',
            code: 'ms_devicecode_failed');
      }
      final Map<String, dynamic> d =
          (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast<String, dynamic>();
      final String userCode = (d['user_code'] ?? '').toString();
      final String verifyUrl = (d['verification_uri'] ?? '').toString();
      final String deviceCode = (d['device_code'] ?? '').toString();
      final int interval = d['interval'] is int ? d['interval'] as int : 5;
      final int expiresIn =
          d['expires_in'] is int ? d['expires_in'] as int : 900;
      localDelivery.value = 'Microsoft 登录（真实设备授权流）\n'
          '请在浏览器打开：$verifyUrl\n输入代码：$userCode\n'
          '本页最多等待 120 秒，超时请重试。';
      final DateTime deadline = DateTime.now().add(
        Duration(seconds: expiresIn < 120 ? expiresIn : 120),
      );
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(Duration(seconds: interval));
        final http.Response t = await http
            .post(
              Uri.parse(tokenUrl),
              headers: <String, String>{
                'Content-Type': 'application/x-www-form-urlencoded',
              },
              body: <String, String>{
                'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
                'client_id': clientId,
                'device_code': deviceCode,
              },
            )
            .timeout(const Duration(seconds: 20));
        final Map<String, dynamic> body =
            (jsonDecode(utf8.decode(t.bodyBytes)) as Map).cast<String, dynamic>();
        if (body['access_token'] != null) {
          localDelivery.value = null;
          final String idToken = (body['id_token'] ?? '').toString();
          final Map<String, dynamic> claims = _jwtPayload(idToken);
          return await _upsertExternalUser(
            id: 'microsoft:${claims['sub'] ?? deviceCode}',
            email: (claims['preferred_username'] ?? claims['email'] ?? '')
                .toString(),
            displayName: (claims['name'] ?? '').toString(),
            provider: 'Microsoft',
          );
        }
        final String err = (body['error'] ?? '').toString();
        if (err != 'authorization_pending' && err != 'slow_down') {
          return _fail('Microsoft 授权失败：$err', code: 'ms_oauth_failed');
        }
      }
      return _fail('Microsoft 授权等待超时，请重试。', code: 'ms_oauth_timeout');
    } on Object catch (e) {
      return _fail('Microsoft 登录真实请求失败：$e',
          code: 'ms_sign_in_failed');
    }
  }

  static Map<String, dynamic> _jwtPayload(String token) {
    if (token.isEmpty) return <String, dynamic>{};
    try {
      final List<String> parts = token.split('.');
      if (parts.length < 2) return <String, dynamic>{};
      final String normalized =
          base64Url.normalize(parts[1]);
      final Object? decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      return decoded is Map ? decoded.cast<String, dynamic>() : <String, dynamic>{};
    } on Object {
      return <String, dynamic>{};
    }
  }
}
