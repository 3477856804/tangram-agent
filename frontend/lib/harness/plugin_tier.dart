/// 插件分级与能力令牌（T0–T3）。
///
/// 设计来源：NewAgentUniverseByDeepSeek（MIT）的分级 + fail-closed 纪律
/// ——「未声明的能力一律拒绝，未实现的能力类型化拒绝」。
/// 本文件只引入「声明与判定」，**不改变既有插件行为**：`caps` 为空＝不限制，
/// 只有显式标成 T3 的第三方插件才要求声明能力。
library;

import 'kernel_guard.dart';

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
  /// 接受线上写法（T0–T3）、枚举名（system/official/user/thirdParty），
  /// 以及下划线别名 third_party / thirdparty（与 Python 侧
  /// _TIER_ALIASES 对齐，清单里最常见的第三方写法）。
  static PluginTier parse(Object? raw) {
    if (raw is PluginTier) return raw;
    final String s = (raw ?? '').toString().trim();
    for (final PluginTier t in PluginTier.values) {
      if (t.wire == s || t.name == s) return t;
    }
    if (s == 'third_party' || s == 'thirdparty') {
      return PluginTier.thirdParty;
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

/// 能力判定：`caps` 有两种既有写法，都认：接缝名（插件清单的声明口径，
/// 如 'core/im'）与能力令牌（调用仲裁的口径，如 'channel:send'，
/// 见 [defaultSeamCaps]）。只认其中一种会让另一处的测试与调用静默失败——
/// 此前 kernel_guard_test 用令牌写法期望放行、plugin_tier_test 用接缝名
/// 写法期望放行，实现只认接缝名，两处期望不可能同时成立。
///
/// round13 收紧：`caps` 为空时，T3 一律拒绝（不变）；T0–T2 也不再默认
/// 放行高危接缝（[kHighRiskSeams]：core/sandbox、core/im、core/scheduler
/// 必须显式声明）。非高危接缝仍沿用空 caps 不限制的兼容语义——
/// 内建插件除已声明 caps 的 5 个外仍为空 caps，收紧面若扩到全部接缝，
/// boot 时 15 个内建插件会挂载失败。
bool seamAllowed(PluginTier tier, List<String> caps, String seam) {
  if (caps.isEmpty) {
    if (tier == PluginTier.thirdParty) return false;
    return !kHighRiskSeams.contains(seam);
  }
  if (caps.contains(seam)) return true;
  final List<String> need = defaultSeamCaps()[seam] ?? const <String>[];
  return need.any(caps.contains);
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
