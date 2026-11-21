/// 生产环境的凭据仓库：只写 FlutterSecureStorage（Android Keystore /
/// iOS Keychain / 桌面安全存储），绝不落明文文件，也不进入模型上下文。

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../harness/integration_registry.dart';

class FlutterSecretVault implements SecretVault {
  const FlutterSecretVault();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static String _key(String key) => 'tga.$key';

  @override
  Future<String?> read(String key) => _storage.read(key: _key(key));

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: _key(key), value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: _key(key));
}
