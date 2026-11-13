import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../providers/auth_provider.dart';

class SecureAuthStorage {
  SecureAuthStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _keyAccessToken = 'flai_access_token';
  static const _keyRefreshToken = 'flai_refresh_token';
  static const _keyUser = 'flai_user';

  Future<void> saveTokens({String? accessToken, String? refreshToken}) async {
    if (accessToken != null) {
      await _storage.write(key: _keyAccessToken, value: accessToken);
    } else {
      await _storage.delete(key: _keyAccessToken);
    }
    if (refreshToken != null) {
      await _storage.write(key: _keyRefreshToken, value: refreshToken);
    } else {
      await _storage.delete(key: _keyRefreshToken);
    }
  }

  Future<void> saveUser(AuthUser user) async {
    final json = jsonEncode({
      'id': user.id,
      'email': user.email,
      'displayName': user.displayName,
      'photoUrl': user.photoUrl,
      'phoneNumber': user.phoneNumber,
      'metadata': user.metadata,
    });
    await _storage.write(key: _keyUser, value: json);
  }

  Future<({String accessToken, String? refreshToken})?> readTokens() async {
    final access = await _storage.read(key: _keyAccessToken);
    if (access == null) return null;
    final refresh = await _storage.read(key: _keyRefreshToken);
    return (accessToken: access, refreshToken: refresh);
  }

  Future<AuthUser?> readUser() async {
    final raw = await _storage.read(key: _keyUser);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return AuthUser(
        id: json['id'] as String,
        email: json['email'] as String,
        displayName: json['displayName'] as String?,
        photoUrl: json['photoUrl'] as String?,
        phoneNumber: json['phoneNumber'] as String?,
        metadata: json['metadata'] as Map<String, dynamic>?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    await Future.wait([
      _storage.delete(key: _keyAccessToken),
      _storage.delete(key: _keyRefreshToken),
      _storage.delete(key: _keyUser),
    ]);
  }

  Future<bool> hasSession() async {
    final access = await _storage.read(key: _keyAccessToken);
    return access != null;
  }
}
