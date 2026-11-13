enum AuthState {
  unknown,

  authenticated,

  unauthenticated,
}

class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    this.displayName,
    this.photoUrl,
    this.phoneNumber,
    this.metadata,
  });

  final String id;
  final String email;
  final String? displayName;
  final String? photoUrl;
  final String? phoneNumber;
  final Map<String, dynamic>? metadata;

  AuthUser copyWith({
    String? id,
    String? email,
    String? displayName,
    String? photoUrl,
    String? phoneNumber,
    Map<String, dynamic>? metadata,
  }) {
    return AuthUser(
      id: id ?? this.id,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      photoUrl: photoUrl ?? this.photoUrl,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      metadata: metadata ?? this.metadata,
    );
  }
}

sealed class AuthResult {
  const AuthResult();
}

class AuthSuccess extends AuthResult {
  const AuthSuccess(this.user);
  final AuthUser user;
}

class AuthFailure extends AuthResult {
  const AuthFailure(this.message, {this.code});
  final String message;
  final String? code;
}

class AuthNeedsVerification extends AuthResult {
  const AuthNeedsVerification(this.email);
  final String email;
}

abstract class AuthProvider {
  Future<AuthResult> signInWithApple();
  Future<AuthResult> signInWithGoogle();
  Future<AuthResult> signInWithMicrosoft();

  Future<AuthResult> signInWithEmail(String email, String password);
  Future<AuthResult> signUp(String email, String password);

  Future<void> sendResetEmail(String email);
  Future<AuthResult> confirmResetCode(String email, String code);
  Future<void> resetPassword(String email, String newPassword);

  Future<void> sendVerificationCode(String email);
  Future<AuthResult> verifyCode(String email, String code);

  Future<void> signOut();
  Stream<AuthUser?> authStateChanges();
  AuthUser? get currentUser;

  Future<bool> tryRestoreSession(
    String accessToken,
    String? refreshToken,
  ) async =>
      false;

  Stream<({String? accessToken, String? refreshToken})> get tokenChanges =>
      const Stream.empty();
}
