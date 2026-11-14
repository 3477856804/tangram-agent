import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../providers/auth_provider.dart';
import 'auth_flow_config.dart';

enum AuthScreen {
  loginLanding,
  emailEntry,
  passwordEntry,
  forgotPassword,
  verificationCode,
  resetPassword,
}

enum VerificationReason { signUp, resetPassword }

class AuthController extends ChangeNotifier {
  AuthController({
    required AuthProvider provider,
    required AuthFlowConfig config,
    this.onAuthenticated,
    this.onGuestContinue,
  })  : _provider = provider,
        _config = config;

  final AuthProvider _provider;
  final AuthFlowConfig _config;

  final void Function(AuthUser user)? onAuthenticated;

  final VoidCallback? onGuestContinue;

  AuthScreen _currentScreen = AuthScreen.loginLanding;
  bool _isLoading = false;
  String? _errorMessage;
  String _email = '';
  VerificationReason _verificationReason = VerificationReason.signUp;
  bool _isSignUpMode = false;

  AuthScreen get currentScreen => _currentScreen;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String get email => _email;
  AuthFlowConfig get config => _config;
  VerificationReason get verificationReason => _verificationReason;
  bool get isSignUpMode => _isSignUpMode;


  void goTo(AuthScreen screen) {
    _errorMessage = null;
    _currentScreen = screen;
    notifyListeners();
  }

  void goToEmailEntry({required bool isSignUp}) {
    _isSignUpMode = isSignUp;
    goTo(AuthScreen.emailEntry);
  }

  void goBack() {
    _errorMessage = null;
    switch (_currentScreen) {
      case AuthScreen.loginLanding:
        break; // Already at root
      case AuthScreen.emailEntry:
        _currentScreen = AuthScreen.loginLanding;
      case AuthScreen.passwordEntry:
        _currentScreen = AuthScreen.emailEntry;
      case AuthScreen.forgotPassword:
        _currentScreen = AuthScreen.passwordEntry;
      case AuthScreen.verificationCode:
        _currentScreen = _verificationReason == VerificationReason.resetPassword
            ? AuthScreen.forgotPassword
            : AuthScreen.emailEntry;
      case AuthScreen.resetPassword:
        _currentScreen = AuthScreen.verificationCode;
    }
    notifyListeners();
  }


  void submitEmail(String email) {
    _email = email;
    _errorMessage = null;
    _currentScreen = AuthScreen.passwordEntry;
    notifyListeners();
  }

  Future<void> signInWithEmail(String password) async {
    await _runAsync(() async {
      final result = await _provider.signInWithEmail(_email, password);
      _handleResult(result);
    });
  }

  Future<void> signUp(String password) async {
    await _runAsync(() async {
      final result = await _provider.signUp(_email, password);
      _handleResult(result);
    });
  }

  Future<void> signInWithSocial(SocialAuthType type) async {
    await _runAsync(() async {
      final result = switch (type) {
        SocialAuthType.apple => await _provider.signInWithApple(),
        SocialAuthType.google => await _provider.signInWithGoogle(),
        SocialAuthType.microsoft => await _provider.signInWithMicrosoft(),
        // 本机账号体系没有手机号 + 短信服务端：如实说明可用渠道，
        // 不抛未捕获异常让界面崩溃，也绝不伪造登录成功。
        SocialAuthType.phone => const AuthFailure(
          '本应用无短信服务端，不支持手机号登录；请使用邮箱与口令，'
          '或 Google / Apple / Microsoft 登录。',
          code: 'phone_not_supported',
        ),
      };
      _handleResult(result);
    });
  }

  Future<void> sendResetEmail() async {
    await _runAsync(() async {
      await _provider.sendResetEmail(_email);
      _verificationReason = VerificationReason.resetPassword;
      _currentScreen = AuthScreen.verificationCode;
    });
  }

  Future<void> verifyCode(String code) async {
    await _runAsync(() async {
      final result = await _provider.verifyCode(_email, code);
      switch (result) {
        case AuthSuccess(:final user):
          if (_verificationReason == VerificationReason.resetPassword) {
            _currentScreen = AuthScreen.resetPassword;
          } else {
            onAuthenticated?.call(user);
          }
        case AuthFailure(:final message):
          _errorMessage = message;
        case AuthNeedsVerification():
          break; // Stay on verification screen
      }
    });
  }

  Future<void> resendCode() async {
    await _runAsync(() async {
      await _provider.sendVerificationCode(_email);
    });
  }

  Future<void> resetPassword(String newPassword) async {
    await _runAsync(() async {
      await _provider.resetPassword(_email, newPassword);
      final result = await _provider.signInWithEmail(_email, newPassword);
      _handleResult(result);
    });
  }


  void _handleResult(AuthResult result) {
    switch (result) {
      case AuthSuccess(:final user):
        onAuthenticated?.call(user);
      case AuthFailure(:final message):
        _errorMessage = message;
      case AuthNeedsVerification(:final email):
        _email = email;
        _verificationReason = VerificationReason.signUp;
        _currentScreen = AuthScreen.verificationCode;
    }
  }

  Future<void> _runAsync(Future<void> Function() action) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
