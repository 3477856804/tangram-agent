/// 插件分级与能力令牌（T0–T3）。
///
/// 设计来源：NewAgentUniverseByDeepSeek（MIT）的分级 + fail-closed 纪律
/// ——「未声明的能力一律拒绝，未实现的能力类型化拒绝」。
/// 本文件只引入「声明与判定」，**不改变既有插件行为**：`caps` 为空＝不限制，
/// 只有显式标成 T3 的第三方插件才要求声明能力。
library;

/// 插件分级。
enum PluginTier {
  /// T0：内核自带（聊天、设置、关于）。
  system('T0'),

  /// T1：官方签名（仓库内置插件默认这一级）。
  official('T1'),

  /// T2：用户自建（本机校验 checksum）。
  user('T2'),

  /// T3：第三方（默认禁网禁写，能力必须显式声明）。
  thirdParty('T3');

  const PluginTier(this.wire);

  /// 清单与日志里的线上写法。
  final String wire;

  /// 解析清单里的 tier；未知值兜底为 [official]，不静默升为 [system]。
  static PluginTier parse(Object? raw) {
    if (raw is PluginTier) return raw;
    final String s = (raw ?? '').toString().trim();
    for (final PluginTier t in PluginTier.values) {
      if (t.wire == s || t.name == s) return t;
    }
    return PluginTier.official;
  }
}

/// 能力令牌被拒：未声明，或被分级策略禁止。
class CapabilityDenied implements Exception {
  CapabilityDenied(this.pluginId, this.capability, this.reason);

  final String pluginId;
  final String capability;
  final String reason;

  @override
  String toString() => 'CapabilityDenied($pluginId, $capability): $reason';
}

/// 能力判定：`caps` 为空＝不限制（兼容既有插件）；
/// T3 第三方插件的 `caps` 为空＝未声明，一律拒绝（fail-closed）。
bool seamAllowed(PluginTier tier, List<String> caps, String seam) {
  if (caps.isEmpty) return tier != PluginTier.thirdParty;
  return caps.contains(seam);
}

/// 地址函数（借 NORP-Agent 的 `pkg.mod:attr` 语义）：非法即抛，不猜。
({String scheme, String path}) parsePluginAddress(String raw) {
  final String s = raw.trim();
  if (s.isEmpty) {
    throw const FormatException('地址为空');
  }
  final int i = s.indexOf(':');
  if (i <= 0) {
    throw FormatException('地址缺 scheme: $s');
  }
  final String scheme = s.substring(0, i);
  final String rest = s.substring(i + 1);
  if (scheme.contains(RegExp(r'[^A-Za-z0-9+.-]')) || rest.isEmpty) {
    throw FormatException('地址非法: $s');
  }
  return (scheme: scheme, path: rest);
}
