import 'dart:async';

import 'auth_provider.dart';

/// 本地离线模式：TGA 没有账号体系，身份只保存在本机。
///
/// 「个人」是**真实的本机身份**，不是伪造的登录态；因此不存在需要恢复的
/// 会话、也不存在 token。所有外部认证（Apple / Google / Microsoft / 邮箱 /
/// 验证码 / 重置密码）当前**未接入**，一律返回明确的失败，绝不返回假成功。
class TangramLocalAuthProvider implements AuthProvider {
  TangramLocalAuthProvider()
    : _user = const AuthUser(
        id: 'local_offline',
        email: '',
        displayName: '个人',
      );

  final AuthUser _user;

  static const String _notConfigured =
      '未接入外部账号体系：本应用无账号、无服务端认证，身份仅保存在本机。';

  AuthFailure get _failure =>
      const AuthFailure(_notConfigured, code: 'auth_not_configured');

  @override
  AuthUser? get currentUser => _user;

  @override
  Stream<AuthUser?> authStateChanges() => Stream<AuthUser?>.value(_user);

  @override
  Stream<({String? accessToken, String? refreshToken})> get tokenChanges =>
      const Stream<({String? accessToken, String? refreshToken})>.empty();

  @override
  Future<bool> tryRestoreSession(
    String accessToken,
    String? refreshToken,
  ) async =>
      false; // 本机身份没有可恢复的外部会话

  @override
  Future<AuthResult> signInWithApple() async => _failure;

  @override
  Future<AuthResult> signInWithGoogle() async => _failure;

  @override
  Future<AuthResult> signInWithMicrosoft() async => _failure;

  @override
  Future<AuthResult> signInWithEmail(String email, String password) async =>
      _failure;

  @override
  Future<AuthResult> signUp(String email, String password) async => _failure;

  @override
  Future<void> sendResetEmail(String email) async =>
      throw UnsupportedError(_notConfigured);

  @override
  Future<AuthResult> confirmResetCode(String email, String code) async =>
      _failure;

  @override
  Future<void> resetPassword(String email, String newPassword) async =>
      throw UnsupportedError(_notConfigured);

  @override
  Future<void> sendVerificationCode(String email) async =>
      throw UnsupportedError(_notConfigured);

  @override
  Future<AuthResult> verifyCode(String email, String code) async => _failure;

  @override
  Future<void> signOut() async {
    // 本机身份常驻，没有外部会话可退出；不做任何伪造的状态切换。
  }
}
