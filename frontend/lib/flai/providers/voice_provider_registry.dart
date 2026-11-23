/// 语音后端注册表：多后端可注册、可切换，默认本地，切换失败回落本地。
///
/// 规则：
/// - `switchTo` 先对目标后端做 `checkAvailable()` 自检（只查配置在位与否，
///   不发起网络调用、不消耗配额）；自检失败时留在当前后端（若当前不是本地，
///   则回落本地），并把真实原因记在 [lastFallbackReason]，绝不静默切换、
///   绝不伪装成已切换成功。
/// - 注册表本身不持有任何密钥；密钥只存在 [VoiceCredentials] 背后的
///   安全存储里，切换原因与返回值里永不出现密钥明文。
library;

import 'voice_provider.dart';

class VoiceProviderRegistry {
  VoiceProviderRegistry({VoiceProvider? defaultProvider})
      : _current = defaultProvider;

  final Map<VoiceProviderKind, VoiceProvider> _providers =
      <VoiceProviderKind, VoiceProvider>{};
  VoiceProvider? _current;

  /// 最近一次回落/切换失败的原因（provider 自检抛出的原样消息，不含密钥）。
  String? lastFallbackReason;

  /// 最近一次回落/切换失败的时间。
  DateTime? lastFallbackAt;

  void register(VoiceProvider provider) {
    _providers[provider.kind] = provider;
    _current ??= provider;
  }

  List<VoiceProviderKind> get registeredKinds =>
      _providers.keys.toList(growable: false);

  bool get hasLocal => _providers.containsKey(VoiceProviderKind.local);

  VoiceProvider get current {
    final VoiceProvider? provider =
        _current ?? _providers[VoiceProviderKind.local];
    if (provider == null) {
      throw StateError('语音注册表为空：请先注册至少一个后端（建议本地）');
    }
    return provider;
  }
  VoiceProviderKind get currentKind => current.kind;

  /// 各后端当前是否可用（只做配置自检，不走网络）。返回 kind → 是否可用。
  Future<Map<VoiceProviderKind, bool>> availability() async {
    final Map<VoiceProviderKind, bool> out = <VoiceProviderKind, bool>{};
    for (final MapEntry<VoiceProviderKind, VoiceProvider> e
        in _providers.entries) {
      try {
        await e.value.checkAvailable();
        out[e.key] = true;
      } on Object {
        out[e.key] = false;
      }
    }
    return out;
  }

  /// 切换到目标后端；自检失败时回落本地（若本地也未注册则留在当前后端），
  /// 记录原因并返回实际生效的后端。调用方应以返回值为准，不要假设切换成功。
  Future<VoiceProvider> switchTo(VoiceProviderKind kind) async {
    final VoiceProvider? target = _providers[kind];
    if (target == null) {
      _recordFallback('目标语音后端未注册：${kind.label}');
      return _fallback();
    }
    try {
      await target.checkAvailable();
    } on Object catch (e) {
      _recordFallback('$e');
      return _fallback();
    }
    _current = target;
    return target;
  }

  VoiceProvider _fallback() {
    final VoiceProvider? local = _providers[VoiceProviderKind.local];
    if (local != null) {
      _current = local;
      return local;
    }
    // 本地后端未注册：留在当前后端（若也没有当前后端，current 会抛明确错误）。
    return current;
  }

  void _recordFallback(String reason) {
    lastFallbackReason = reason;
    lastFallbackAt = DateTime.now();
  }
}
