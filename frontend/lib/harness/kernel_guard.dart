/// 内核守卫与内核态快照（0.0.41）。
///
/// 解决审计报告里的三处「只有声明、没有执行」：
///   * G2 仲裁：`invoke` 之前必须过 [InvokeGuard] 与能力令牌（seamCaps）。
///   * G5 回退：内核态（节点树 / seam 激活项 / 服务 / 模式）可快照与恢复，
///     不再只回退磁盘数据。
///   * G4 地址：`parsePluginAddress` 在挂载时真实校验 `Plugin.address`。
///
/// 纪律：默认值保持既有语义（root 调用方 = UI；未配置 seamCaps 的接缝不限制），
/// 但**一旦配置就必须强制**，绝不「配置了却不执行」。
library;

/// 根调用方：用户自己的 UI（老板本人操作），默认拥有全部能力。
const String kRootCaller = 'ui';

/// 未表明身份的调用方：控制消息里没传 caller 时的默认值。
/// 绝不默认给 root——任何省略身份的发送方都只能拿到这个身份，
/// 再由能力令牌与调用守卫决定能不能调（高危接缝一律拒绝）。
const String kUntrustedCaller = 'untrusted';

/// 调用守卫：返回 false 即拒绝本次接缝调用（可审计、可否决）。
typedef InvokeGuard = Future<bool> Function(
  String seam,
  String method,
  Map<String, dynamic> args,
  String caller,
);

/// 内核态快照：只记「装配结果」，不复制文件。
class KernelSnapshot {
  KernelSnapshot({
    required this.id,
    required this.label,
    required this.at,
    required this.nodes,
    required this.seams,
    required this.services,
    required this.mode,
    required this.seq,
  });

  final String id;
  final String label;
  final String at;
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> seams;
  final List<String> services;
  final String mode;
  final int seq;

  Set<String> get nodeIds =>
      nodes.map((Map<String, dynamic> n) => (n['id'] ?? '').toString()).toSet();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'at': at,
        'nodes': nodes,
        'seams': seams,
        'services': services,
        'mode': mode,
        'seq': seq,
      };

  static KernelSnapshot fromJson(Map<String, dynamic> j) => KernelSnapshot(
        id: (j['id'] ?? '').toString(),
        label: (j['label'] ?? '').toString(),
        at: (j['at'] ?? '').toString(),
        nodes: (j['nodes'] is List)
            ? (j['nodes'] as List).whereType<Map>().map(
                (Map<dynamic, dynamic> m) => Map<String, dynamic>.from(m)).toList()
            : <Map<String, dynamic>>[],
        seams: (j['seams'] is List)
            ? (j['seams'] as List).whereType<Map>().map(
                (Map<dynamic, dynamic> m) => Map<String, dynamic>.from(m)).toList()
            : <Map<String, dynamic>>[],
        services: (j['services'] is List)
            ? (j['services'] as List).map((dynamic e) => e.toString()).toList()
            : <String>[],
        mode: (j['mode'] ?? '').toString(),
        seq: (j['seq'] is num) ? (j['seq'] as num).toInt() : 0,
      );
}

/// 默认能力要求：高权限接缝必须显式声明令牌才能调用。
/// UI（root）不受限；插件调用方必须带对应 cap。
/// 覆盖全部已注册接缝（见 builtin_plugins.dart 的 provideSeamProvider 调用）：
/// 只覆盖 3 条会让其余接缝对非 root 调用方零令牌可调。
Map<String, List<String>> defaultSeamCaps() => <String, List<String>>{
      'core/sandbox': <String>['sandbox:exec'],
      'core/im': <String>['channel:send'],
      'core/mcp': <String>['net:fetch'],
      'core/storage': <String>['storage:write'],
      'core/model': <String>['model:invoke'],
      'core/scheduler': <String>['scheduler:schedule'],
      'core/skills': <String>['skill:invoke'],
      'core/skills/recorded': <String>['skill:invoke'],
      'core/agent-loop': <String>['agent:run'],
      'core/trajectory': <String>['trajectory:write'],
      'ext/hooks': <String>['hooks:invoke'],
      'ui/pages': <String>['ui:open'],
    };

/// 高危接缝（round13）：即使 T0–T2 插件 `caps` 为空也不再默认放行，
/// 必须显式声明对应能力。只含其提供方插件已声明 caps 的接缝——
/// 否则内建插件挂载即失败（先声明 caps、后收紧，顺序不可颠倒）。
/// 其它接缝仍沿用既有兼容语义（空 caps 不限制）。
const Set<String> kHighRiskSeams = <String>{
  'core/sandbox',
  'core/im',
  'core/scheduler',
};

/// 插件经 facade 可发布的事件 topic 白名单（round13）。
/// 插件只能发自己业务的观测事件；内核/接缝/插件生命周期事件
/// （kernel.*/seam.*/plugin.*）一律不得由插件伪造发出——
/// 那些事件只由内核自己在真实状态变化时发出。
/// 集中定义于此，便于扩展：新增合法 topic 只改这一处。
const Set<String> kPluginEmitTopics = <String>{
  'session.cell',
  'model.chat',
  'sandbox.exec',
  'agent-loop.observe',
};

/// 插件 emit 是否放行：白名单内且不在禁发前缀内。
bool pluginEmitAllowed(String topic) {
  if (topic.startsWith('kernel.') ||
      topic.startsWith('seam.') ||
      topic.startsWith('plugin.')) {
    return false;
  }
  return kPluginEmitTopics.contains(topic);
}
