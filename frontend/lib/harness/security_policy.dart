/// 权限策略 —— 纯 Dart 的「工具 / 路径 / 参数」三要素判定。
///
/// 参考 Claude Code 的权限模型，把每次工具调用抽象成一条规则匹配：
///  * `tool` / `path` / `args` 都是**正则字符串**，空串表示该维度不限制；
///  * 规则按声明顺序求值，**首个匹配的规则生效**，都不匹配时用 `fallback`；
///  * 非法正则不抛异常，按「不匹配」处理，避免坏规则把整条策略链打断。
///
/// 默认策略只内置项目里真实存在的工具名（`shell` / `file_read` /
/// `file_write` / `read_file` / `write_file` / `recall` 等），规则内容也都
/// 是可直接解释的通用安全约束：私钥与凭证拒绝读取、破坏性命令拒绝执行、
/// 系统目录写入需确认、普通读取放行。这里只做判定，不冒充「已拦截」——
/// 真正的拦截由调用方在拿到 `PolicyDecision` 后执行。

enum PolicyDecision { allow, ask, deny }

/// 解析字符串为决策；未知值（含空串）一律回落为 [PolicyDecision.ask]，
/// 宁可多问一次也不默认放行。
PolicyDecision parsePolicyDecision(String value) {
  switch (value.trim().toLowerCase()) {
    case 'allow':
      return PolicyDecision.allow;
    case 'deny':
      return PolicyDecision.deny;
    case 'ask':
      return PolicyDecision.ask;
    default:
      return PolicyDecision.ask;
  }
}

/// 单条权限规则。
class PermissionRule {
  PermissionRule({
    required this.id,
    required this.tool,
    this.path = '',
    this.args = '',
    this.decision = PolicyDecision.ask,
    this.enabled = true,
    this.note = '',
  });

  final String id;

  /// 工具名正则，空串匹配任意工具。
  final String tool;

  /// 目标路径正则，空串匹配任意路径（含未提供路径的调用）。
  final String path;

  /// 参数正则，空串匹配任意参数。
  final String args;

  final PolicyDecision decision;
  final bool enabled;

  /// 人类可读的规则说明，便于 UI 展示「为什么被拦」。
  final String note;

  /// 三个维度同时匹配才算命中；正则非法时安全捕获并视为不匹配。
  bool matches({required String tool, String path = '', String args = ''}) {
    if (!enabled) return false;
    return _safeMatch(this.tool, tool) &&
        _safeMatch(this.path, path) &&
        _safeMatch(this.args, args);
  }

  static bool _safeMatch(String pattern, String input) {
    if (pattern.isEmpty) return true;
    try {
      return RegExp(pattern).hasMatch(input);
    } on Object {
      // 非法正则（括号不配对、量词错误等）只让本条规则失效，不向上抛。
      return false;
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'tool': tool,
        'path': path,
        'args': args,
        'decision': decision.name,
        'enabled': enabled,
        'note': note,
      };

  /// 容错解析：缺失或类型不符的字段用默认值补齐，绝不让一条坏规则
  /// 导致整份策略读取失败。
  factory PermissionRule.fromJson(Map<String, dynamic> json) {
    final Object? enabled = json['enabled'];
    return PermissionRule(
      id: json['id']?.toString() ?? '',
      tool: json['tool']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      args: json['args']?.toString() ?? '',
      decision: parsePolicyDecision(json['decision']?.toString() ?? ''),
      enabled: enabled is bool ? enabled : true,
      note: json['note']?.toString() ?? '',
    );
  }
}

/// 一组有序规则 + 兜底决策。
class PermissionPolicy {
  PermissionPolicy({
    List<PermissionRule>? rules,
    this.fallback = PolicyDecision.ask,
  }) : rules = List<PermissionRule>.of(rules ?? const <PermissionRule>[]);

  /// 内置默认策略：只描述通用安全边界，不虚构额外能力。
  factory PermissionPolicy.withDefaults() => PermissionPolicy(
        rules: <PermissionRule>[
          PermissionRule(
            id: 'default-deny-private-key',
            tool: r'^(file_read|read_file|file_write|write_file|workspace\.(read|write|copy|mkdir))$',
            path: r'(^|/)\.ssh(/|$)|\.pem$',
            decision: PolicyDecision.deny,
            note: '拒绝读取或改写 SSH 私钥与 *.pem 证书',
          ),
          PermissionRule(
            id: 'default-deny-secret-file',
            tool: r'^(file_read|read_file|workspace\.(read|write|copy|mkdir))$',
            path: r'(^|/)\.env(\.|$)|(^|/)(id_rsa|id_ed25519|credentials\.json|\.netrc)$',
            decision: PolicyDecision.deny,
            note: '拒绝读取 .env、凭证与私钥文件',
          ),
          PermissionRule(
            id: 'default-ask-computer-write',
            tool: r'^computer_write$',
            decision: PolicyDecision.ask,
            note: 'Team Computer 写入需确认（round13 补齐写工具覆盖）',
          ),
          PermissionRule(
            id: 'default-ask-integration-call',
            tool: r'^integration_call$',
            decision: PolicyDecision.ask,
            note: '外部集成调用（MCP/OpenAPI/GraphQL）需确认（round13 补齐写工具覆盖）',
          ),
          PermissionRule(
            id: 'default-allow-workspace',
            tool: r'^workspace\.(mkdir|read|copy|write|search|list)$',
            decision: PolicyDecision.allow,
            note: '授权映射目录内的常规文件操作直接放行（敏感文件仍由 deny 规则优先拦截）',
          ),
          PermissionRule(
            id: 'default-deny-destructive-shell',
            tool: r'^shell$',
            args: r'\brm\s+-(?:[a-zA-Z]*[rR][a-zA-Z]*[fF]|[a-zA-Z]*[fF][a-zA-Z]*[rR])|\bmkfs|\bdd\s+if=',
            decision: PolicyDecision.deny,
            note: '拒绝 rm -rf / mkfs / dd 等破坏性命令',
          ),
          PermissionRule(
            id: 'default-ask-system-write',
            tool: r'^(file_write|write_file|shell)$',
            path: r'^/(etc|usr|bin|sbin|boot|sys|proc|dev|var/lib)(/|$)',
            decision: PolicyDecision.ask,
            note: '写入系统目录前必须确认',
          ),
          PermissionRule(
            id: 'default-allow-shell',
            tool: r'^shell$',
            decision: PolicyDecision.allow,
            note: '普通 shell 命令直接放行（破坏性命令与系统目录写入仍由前置规则拦截）',
          ),
          PermissionRule(
            id: 'default-allow-read',
            tool: r'^(file_read|read_file|recall|list_models|current_time|capabilities|evaluate)$',
            decision: PolicyDecision.allow,
            note: '普通读取与只读查询直接放行',
          ),
        ],
      );

  final List<PermissionRule> rules;
  final PolicyDecision fallback;

  /// 按顺序取首个命中的规则；全部落空时返回 [fallback]。
  PolicyDecision evaluate({
    required String tool,
    String path = '',
    String args = '',
  }) {
    for (final PermissionRule rule in rules) {
      if (rule.matches(tool: tool, path: path, args: args)) {
        return rule.decision;
      }
    }
    return fallback;
  }

  /// 首个命中规则的 id；无规则命中（走 fallback）时返回 ''。
  ///
  /// deny 预检的唯一真源：调用方先用 [evaluate] 判定是否为 deny，再用
  /// 本方法取规则 id 记入审计。两次求值同顺序、同策略实例，结果一致。
  /// 本方法只返回 id，不做任何放行/拦截判定。
  String matchedRuleId({
    required String tool,
    String path = '',
    String args = '',
  }) {
    for (final PermissionRule rule in rules) {
      if (rule.matches(tool: tool, path: path, args: args)) {
        return rule.id;
      }
    }
    return '';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'rules': rules.map((PermissionRule r) => r.toJson()).toList(),
        'fallback': fallback.name,
      };

  factory PermissionPolicy.fromJson(Map<String, dynamic> json) {
    final List<PermissionRule> parsed = <PermissionRule>[];
    final Object? rawRules = json['rules'];
    if (rawRules is List) {
      for (final Object? raw in rawRules) {
        if (raw is Map) {
          parsed.add(PermissionRule.fromJson(
            raw.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
          ));
        }
      }
    }
    return PermissionPolicy(
      rules: parsed,
      fallback: parsePolicyDecision(json['fallback']?.toString() ?? ''),
    );
  }

  /// 合并策略：`other` 中新增的规则排在最前（优先级最高）；同名 id 的规则
  /// 用 `other` 的版本原位替换（保留基础策略的顺序与敏感路径优先级）；
  /// 兜底决策以 `other` 为准。
  PermissionPolicy merge(PermissionPolicy other) {
    final Set<String> baseIds = rules.map((PermissionRule r) => r.id).toSet();
    final Map<String, PermissionRule> overrides = <String, PermissionRule>{
      for (final PermissionRule r in other.rules)
        if (r.id.isNotEmpty && baseIds.contains(r.id)) r.id: r,
    };
    final List<PermissionRule> merged = <PermissionRule>[
      for (final PermissionRule r in other.rules)
        if (r.id.isEmpty || !baseIds.contains(r.id)) r,
      for (final PermissionRule r in rules)
        overrides[r.id] ?? r,
    ];
    return PermissionPolicy(rules: merged, fallback: other.fallback);
  }
}
