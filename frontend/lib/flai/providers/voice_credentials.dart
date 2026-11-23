/// 语音后端密钥仓库：只读写系统安全存储（生产用 FlutterSecureStorage，
/// 测试用内存 Vault），绝不落明文文件、不进日志、不进返回值、不进模型上下文。
///
/// 与 Integrations 的 SecretVault 复用同一抽象；本文件只规定语音密钥的
/// 键名与访问口径，不持有任何密钥值。
library;

import '../../harness/integration_registry.dart';
import 'voice_provider.dart';

class VoiceCredentials {
  VoiceCredentials(this._vault);

  final SecretVault _vault;

  /// 安全存储中的键名（统一加 tga. 前缀由 FlutterSecretVault 处理，
  /// 这里的键名本身不含任何密钥内容）。
  static String keyName(VoiceProviderKind kind) {
    switch (kind) {
      case VoiceProviderKind.openAiCompatible:
        return 'voice.openai.api_key';
      case VoiceProviderKind.elevenLabs:
        return 'voice.elevenlabs.api_key';
      case VoiceProviderKind.local:
        return 'voice.local.api_key';
    }
  }

  /// 该后端是否需要密钥。本地后端不需要密钥。
  static bool needsApiKey(VoiceProviderKind kind) =>
      kind != VoiceProviderKind.local;

  /// 读密钥：仅供 provider 在发起真实 HTTP 调用前一刻读取，
  /// 不缓存、不记录、不返回给调用方之外的任何人。
  Future<String?> readApiKey(VoiceProviderKind kind) async {
    if (!needsApiKey(kind)) return null;
    final String? value = await _vault.read(keyName(kind));
    final String trimmed = (value ?? '').trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<bool> hasApiKey(VoiceProviderKind kind) async =>
      await readApiKey(kind) != null;

  /// 存密钥：空值拒绝写入；本地后端拒绝存密钥（它不需要）。
  Future<void> saveApiKey(VoiceProviderKind kind, String key) async {
    if (!needsApiKey(kind)) {
      throw UnsupportedError('本地语音后端不需要 API Key');
    }
    if (key.trim().isEmpty) {
      throw ArgumentError('API Key 为空，拒绝写入');
    }
    await _vault.write(keyName(kind), key.trim());
  }

  Future<void> deleteApiKey(VoiceProviderKind kind) async {
    if (!needsApiKey(kind)) return;
    await _vault.delete(keyName(kind));
  }
}
