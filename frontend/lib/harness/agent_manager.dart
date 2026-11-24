/// Super agent 管理其他 agent 的受限工具集（round-11，Rakazo 深度机制 #9）。
///
/// 对照 Rakazo「Super agent 管其他 agent」的产品语义，端侧的真实落地
/// （clean-room，只借鉴设计，未复制任何第三方源码）：
///  * Super agent 可列出 / 分组 / 改指令 / 改模型 / 给其他 agent 排例程；
///  * 子 agent 没有任何管理工具——注册表能证明某 agent 是否持有管理权，
///    管理工具只对 super agent 开放；
///  * 改他人指令必须弹审批卡且不可跳过：走现有 `ApprovalGate` 的审批语义，
///    默认 Ask；审批分类 `agent_instruction` 不在门的可设分类里，策略上
///    永远无法被设为 auto，批准只能是一次性的（10 分钟内、同一目标与
///    同一指令版本只放行一次），拒绝则不改；
///  * 指令编辑带版本号乐观锁：版本号不匹配拒绝写入并返回明确错误；
///  * 绝不碰密钥：指令 / 参数中出现疑似密钥内容时拒绝并只记审计元数据
///    （目标、版本、长度、命中模式名），绝不记内容本身；脱敏规则与
///    `audit_log.dart` 的 SecretRedactor / `im/audit.py` 同源。
///
/// 纯 Dart，不依赖 Flutter，便于独立回归测试与 Dart VM 断言。
/// 本文件不直接依赖 `AuditLog` / `RoutineStore`，而是通过注入的
/// [AgentAuditSink] 与 [RoutineScheduler] 解耦：接线层传入真实实现，
/// 测试与 Dart VM 断言脚本传入内存替身。

import 'dart:async';
import 'dart:math';

// ignore: avoid_relative_lib_imports
import 'approval_gate.dart';

/// 子 agent 状态。
enum SubAgentStatus { active, paused, stopped }

/// 一条子 agent 的元数据：id、名称、模型、指令版本、状态。
class SubAgentRecord {
  SubAgentRecord({
    required this.id,
    required this.name,
    required this.model,
    this.group = 'default',
    this.instruction = '',
    this.instructionVersion = 1,
    this.status = SubAgentStatus.active,
    this.isSuper = false,
    String? createdAt,
    String? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toIso8601String(),
        updatedAt = updatedAt ?? DateTime.now().toIso8601String();

  final String id;
  String name;
  String model;
  String group;

  /// 当前指令文本（写时已过密钥扫描；列表默认不返回正文，只返回版本）。
  String instruction;

  /// 指令版本号：每次成功改指令 +1；编辑时必须带期望版本做乐观锁。
  int instructionVersion;
  SubAgentStatus status;

  /// 是否持有管理权：只有 super agent 为 true；注册表以此证明
  /// 某 agent 是否持有管理工具。
  final bool isSuper;

  final String createdAt;
  String updatedAt;

  /// 摘要：不含指令正文，只含元数据（列表/分组用，避免正文外泄）。
  Map<String, dynamic> toSummary() => <String, dynamic>{
        'id': id,
        'name': name,
        'model': model,
        'group': group,
        'instruction_version': instructionVersion,
        'status': status.name,
        'is_super': isSuper,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        ...toSummary(),
        'instruction': instruction,
      };

  static SubAgentRecord fromJson(Map<String, dynamic> m) {
    final SubAgentRecord r = SubAgentRecord(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      model: (m['model'] ?? '').toString(),
      group: (m['group'] ?? 'default').toString(),
      instruction: (m['instruction'] ?? '').toString(),
      instructionVersion: (m['instruction_version'] is num)
          ? (m['instruction_version'] as num).toInt()
          : 1,
      status: SubAgentStatus.values.firstWhere(
        (SubAgentStatus s) => s.name == (m['status'] ?? '').toString(),
        orElse: () => SubAgentStatus.active,
      ),
      isSuper: m['is_super'] == true,
      createdAt: (m['created_at'] ?? '').toString(),
      updatedAt: (m['updated_at'] ?? '').toString(),
    );
    return r;
  }
}

/// 疑似密钥扫描结果：只报告命中模式名，不回传任何原文片段。
class SecretScanResult {
  const SecretScanResult(this.found, this.pattern);
  final bool found;

  /// 命中的模式名（如 `bearer_auth` / `secret_key_value`），未命中为空串。
  final String pattern;
}

/// 疑似密钥扫描器：与项目内 `audit_log.dart` 的 SecretRedactor /
/// `im/audit.py` 的 SecretRedactor 同规则（只替换敏感值），另加常见
/// 令牌前缀与 PEM 私钥头——命中即拒绝写入，绝不把原文记进审计。
abstract final class SecretScanner {
  static final RegExp _authScheme = RegExp(
    r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=\-]+',
    caseSensitive: false,
  );

  static final RegExp _secretKeyValue = RegExp(
    r'''(?<![A-Za-z0-9_])(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|pwd|secret|client[_-]?secret|authorization)(["']?\s*[:=]\s*["']?)(?!Bearer\b|Basic\b)([^"'\s,;&}\]]+)''',
    caseSensitive: false,
  );

  static final RegExp _tokenPrefix = RegExp(
    r'\b(sk-[A-Za-z0-9]{8,}|ghp_[A-Za-z0-9]{8,}|gho_[A-Za-z0-9]{8,}|xox[baprs]-[A-Za-z0-9\-]{8,})\b',
  );

  static final RegExp _privateKeyHeader = RegExp(
    r'-----BEGIN (?:[A-Z ]*)PRIVATE KEY-----',
  );

  /// 扫描 [text]；命中返回 (true, 模式名)，未命中返回 (false, '')。
  static SecretScanResult scan(String text) {
    if (text.isEmpty) return const SecretScanResult(false, '');
    if (_authScheme.hasMatch(text)) {
      return const SecretScanResult(true, 'bearer_auth');
    }
    if (_secretKeyValue.hasMatch(text)) {
      return const SecretScanResult(true, 'secret_key_value');
    }
    if (_tokenPrefix.hasMatch(text)) {
      return const SecretScanResult(true, 'token_prefix');
    }
    if (_privateKeyHeader.hasMatch(text)) {
      return const SecretScanResult(true, 'private_key');
    }
    return const SecretScanResult(false, '');
  }
}

/// 审计接收端：接线层传入真实 `AuditLog.append`，测试传入内存替身。
/// 只收元数据（detail 由调用方拼好，绝不含指令/参数原文）。
typedef AgentAuditSink = Future<void> Function({
  required String action,
  required String decision,
  required String actor,
  required String detail,
});

/// 例程调度器抽象：接线层传入真实 `RoutineService`，测试传入内存替身。
abstract class RoutineScheduler {
  Future<Map<String, dynamic>> createRoutine({
    required String name,
    required String prompt,
    required List<String> crons,
    String? modelId,
    String timezone = 'local',
  });
}

/// 子 agent 注册表：列出 / 分组 / 注册 / 注销，并证明管理权归属。
class AgentRegistry {
  AgentRegistry({required this.superAgentId});

  /// Super agent 的 id：唯一持有管理权的 agent。
  final String superAgentId;

  final Map<String, SubAgentRecord> _agents = <String, SubAgentRecord>{};

  /// 注册表内是否已登记某 agent。
  bool contains(String id) => _agents.containsKey(id);

  SubAgentRecord? get(String id) => _agents[id];

  /// 某 agent 是否持有管理权：只有 super agent 为 true；子 agent 一律 false。
  /// 注册表以此证明管理工具的归属。
  bool hasManagementRights(String agentId) =>
      agentId == superAgentId && _agents[agentId]?.isSuper == true;

  /// Super agent 的受限管理工具集名。子 agent 调用 [toolsFor] 拿到的
  /// 是空列表——子 agent 没有任何管理工具。
  static const List<String> managementTools = <String>[
    'listAgents',
    'groupAgents',
    'updateInstruction',
    'updateModel',
    'scheduleRoutine',
  ];

  /// 某 agent 可用的管理工具：super agent 拿全集，子 agent 拿空集。
  List<String> toolsFor(String agentId) =>
      hasManagementRights(agentId) ? List<String>.of(managementTools) : <String>[];

  /// 注册一条子 agent：只有 super agent 或系统引导（actorId == 'system'）
  /// 可以注册；重复 id、空 id、空名一律拒绝。
  Map<String, dynamic> register(SubAgentRecord agent,
      {required String actorId}) {
    if (actorId != superAgentId && actorId != 'system') {
      return <String, dynamic>{
        'ok': false,
        'error': '无管理权：只有 super agent 可以注册子 agent',
      };
    }
    if (agent.id.trim().isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '子 agent id 不能为空'};
    }
    if (agent.name.trim().isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '子 agent 名称不能为空'};
    }
    if (agent.isSuper && agent.id != superAgentId) {
      return <String, dynamic>{
        'ok': false,
        'error': '只有 super agent 本身可以持有管理权，子 agent 不可登记为 super',
      };
    }
    if (_agents.containsKey(agent.id)) {
      return <String, dynamic>{
        'ok': false,
        'error': '子 agent ${agent.id} 已注册',
      };
    }
    _agents[agent.id] = agent;
    return <String, dynamic>{'ok': true, 'agent': agent.toSummary()};
  }

  /// 注销一条子 agent：只有 super agent 可以注销；super 自身不可注销。
  Map<String, dynamic> unregister(String id, {required String actorId}) {
    if (actorId != superAgentId) {
      return <String, dynamic>{
        'ok': false,
        'error': '无管理权：只有 super agent 可以注销子 agent',
      };
    }
    if (id == superAgentId) {
      return <String, dynamic>{'ok': false, 'error': 'super agent 不可注销自身'};
    }
    final SubAgentRecord? removed = _agents.remove(id);
    if (removed == null) {
      return <String, dynamic>{'ok': false, 'error': '子 agent $id 不存在'};
    }
    return <String, dynamic>{'ok': true, 'agent': removed.toSummary()};
  }

  /// 列出子 agent 摘要（默认不含指令正文）；可按分组过滤。
  List<Map<String, dynamic>> list({String? group}) {
    final List<SubAgentRecord> all = _agents.values.toList()
      ..sort((SubAgentRecord a, SubAgentRecord b) => a.id.compareTo(b.id));
    return all
        .where((SubAgentRecord a) => group == null || a.group == group)
        .map((SubAgentRecord a) => a.toSummary())
        .toList();
  }

  /// 按分组归集子 agent 摘要：{group: [摘要, ...]}，组内按 id 排序。
  Map<String, List<Map<String, dynamic>>> groupBy() {
    final Map<String, List<Map<String, dynamic>>> out =
        <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> s in list()) {
      final String g = (s['group'] ?? 'default').toString();
      out.putIfAbsent(g, () => <Map<String, dynamic>>[]).add(s);
    }
    return out;
  }

  List<Map<String, dynamic>> toJson() =>
      _agents.values.map((SubAgentRecord a) => a.toJson()).toList();

  void loadJson(List<Map<String, dynamic>> items) {
    _agents.clear();
    for (final Map<String, dynamic> m in items) {
      final SubAgentRecord r = SubAgentRecord.fromJson(m);
      if (r.id.isNotEmpty) _agents[r.id] = r;
    }
  }
}

/// Super agent 的受限管理工具集：listAgents / groupAgents /
/// updateInstruction / updateModel / scheduleRoutine。
///
/// 硬边界全部在此 enforced，不依赖调用方自觉：
///  * 非 super agent 调用任何管理方法都返回无管理权错误；
///  * 改他人指令默认 Ask，走 [ApprovalGate] 的一次性批准，拒绝则不改；
///    审批分类 `agent_instruction` 不在门的可设分类里，永远无法被设为
///    auto，审批不可跳过；
///  * 指令编辑带版本号乐观锁；
///  * 指令 / 参数命中疑似密钥一律拒绝，只记审计元数据。
class AgentManager {
  AgentManager({
    required this.registry,
    required this.gate,
    required this.audit,
    this.scheduler,
    this.superAgentId = 'super',
    this.superAgentName = 'Super Agent',
    this.superAgentModel = '',
  }) {
    // 构造即登记 super agent 自身（isSuper=true），管理权归属有据可查。
    registry.register(
      SubAgentRecord(
        id: superAgentId,
        name: superAgentName,
        model: superAgentModel,
        group: 'super',
        isSuper: true,
      ),
      actorId: 'system',
    );
  }

  /// 改他人指令的审批分类：默认 Ask；因不在 [ApprovalGate] 的可设分类
  /// 清单里，策略上永远无法被设为 auto——审批卡不可跳过。
  static const String categoryAgentInstruction = 'agent_instruction';

  final AgentRegistry registry;
  final ApprovalGate gate;
  final AgentAuditSink audit;
  final RoutineScheduler? scheduler;
  final String superAgentId;
  final String superAgentName;
  final String superAgentModel;

  String _newId() {
    final int now = DateTime.now().microsecondsSinceEpoch;
    final int salt = Random.secure().nextInt(1 << 32);
    return 'agent-${now.toRadixString(36)}-$salt';
  }

  Map<String, dynamic> _noRights(String tool) => <String, dynamic>{
        'ok': false,
        'error': '无管理权：$tool 只对 super agent 开放，子 agent 没有任何管理工具',
      };

  Future<void> _audit(
    String action,
    String decision,
    String actor,
    String detail,
  ) async {
    try {
      await audit(
        action: action,
        decision: decision,
        actor: actor,
        detail: detail,
      );
    } on Object {
      // 审计失败不阻断管理动作本身（与项目内审计门面同规则）。
    }
  }

  /// 注册一条子 agent（super agent 专属）。指令写时同样过密钥扫描。
  Future<Map<String, dynamic>> registerAgent({
    required String callerId,
    required String name,
    required String model,
    String group = 'default',
    String instruction = '',
  }) async {
    if (!registry.hasManagementRights(callerId)) {
      return _noRights('registerAgent');
    }
    final SecretScanResult secret = SecretScanner.scan(instruction);
    if (secret.found) {
      await _audit('agent.register', 'denied', callerId,
          'name_len=${name.length} secret_pattern=${secret.pattern}');
      return <String, dynamic>{
        'ok': false,
        'error': '指令含疑似密钥内容（${secret.pattern}），已拒绝注册并记审计',
      };
    }
    final SubAgentRecord agent = SubAgentRecord(
      id: _newId(),
      name: name.trim(),
      model: model.trim(),
      group: group.trim().isEmpty ? 'default' : group.trim(),
      instruction: instruction,
    );
    final Map<String, dynamic> r =
        registry.register(agent, actorId: callerId);
    if (r['ok'] == true) {
      await _audit('agent.register', 'allowed', callerId,
          'target=${agent.id} group=${agent.group} model=${agent.model}');
    }
    return r;
  }

  /// 注销一条子 agent（super agent 专属）。
  Future<Map<String, dynamic>> unregisterAgent({
    required String callerId,
    required String targetId,
  }) async {
    if (!registry.hasManagementRights(callerId)) {
      return _noRights('unregisterAgent');
    }
    final Map<String, dynamic> r =
        registry.unregister(targetId, actorId: callerId);
    if (r['ok'] == true) {
      await _audit('agent.unregister', 'allowed', callerId,
          'target=$targetId');
    }
    return r;
  }

  /// 列出子 agent（super agent 专属；默认只返回摘要，不含指令正文）。
  Map<String, dynamic> listAgents(String callerId, {String? group}) {
    if (!registry.hasManagementRights(callerId)) {
      return _noRights('listAgents');
    }
    return <String, dynamic>{
      'ok': true,
      'agents': registry.list(group: group),
    };
  }

  /// 按分组列出子 agent（super agent 专属）。
  Map<String, dynamic> groupAgents(String callerId) {
    if (!registry.hasManagementRights(callerId)) {
      return _noRights('groupAgents');
    }
    return <String, dynamic>{'ok': true, 'groups': registry.groupBy()};
  }

  /// 改他人指令（super agent 专属，默认 Ask，不可跳过）：
  ///  1. 密钥扫描命中 → 拒绝 + 审计元数据；
  ///  2. 版本号不匹配 → 拒绝写入，返回明确的版本冲突错误；
  ///  3. 无一次性批准 → 记一条待审批并返回 needs_approval + approval_id，
  ///     不改指令；
  ///  4. 持有同一目标 + 同一版本的一次性批准 → 消耗后写入，版本 +1。
  /// 批准是一次性的：只放行下一次同一（目标、版本）的写入，10 分钟内
  /// 有效，过期作废；重启后失效。
  Future<Map<String, dynamic>> updateInstruction({
    required String callerId,
    required String targetId,
    required String newInstruction,
    required int expectedVersion,
  }) async {
    if (!registry.hasManagementRights(callerId)) {
      return _noRights('updateInstruction');
    }
    final SubAgentRecord? target = registry.get(targetId);
    if (target == null) {
      return <String, dynamic>{'ok': false, 'error': '子 agent $targetId 不存在'};
    }
    if (targetId == superAgentId) {
      return <String, dynamic>{
        'ok': false,
        'error': '不可通过管理工具改 super agent 自身的指令',
      };
    }
    final SecretScanResult secret = SecretScanner.scan(newInstruction);
    if (secret.found) {
      await _audit('agent.update_instruction', 'denied', callerId,
          'target=$targetId version=$expectedVersion '
          'len=${newInstruction.length} secret_pattern=${secret.pattern}');
      return <String, dynamic>{
        'ok': false,
        'error': '新指令含疑似密钥内容（${secret.pattern}），已拒绝并记审计',
      };
    }
    if (expectedVersion != target.instructionVersion) {
      return <String, dynamic>{
        'ok': false,
        'error': '指令版本冲突：期望 v$expectedVersion，当前 '
            'v${target.instructionVersion}，请刷新后重试',
        'expected_version': expectedVersion,
        'current_version': target.instructionVersion,
      };
    }
    final String subject = 'instruction-v$expectedVersion';
    final bool approved = await gate.consumeApproval(
      categoryAgentInstruction,
      key: targetId,
      subject: subject,
    );
    if (!approved) {
      final Map<String, dynamic> pending = await gate.requestApproval(
        category: categoryAgentInstruction,
        key: targetId,
        subject: subject,
        // 待审批只放元数据：目标、版本、新指令长度，绝不放指令正文。
        detail: 'target=$targetId version=$expectedVersion '
            'new_len=${newInstruction.length}',
        actor: callerId,
      );
      await _audit('agent.update_instruction', 'needs_approval', callerId,
          'target=$targetId version=$expectedVersion '
          'approval_id=${pending['id'] ?? ''}');
      return <String, dynamic>{
        'ok': false,
        'needs_approval': true,
        'approval_id': pending['id'],
        'error': '改他人指令需审批：已生成审批卡 ${pending['id'] ?? ''}，'
            '批准后请用同一版本号重试',
        'target': targetId,
        'expected_version': expectedVersion,
      };
    }
    target.instruction = newInstruction;
    target.instructionVersion += 1;
    target.updatedAt = DateTime.now().toIso8601String();
    await _audit('agent.update_instruction', 'allowed', callerId,
        'target=$targetId version=$expectedVersion '
        'new_version=${target.instructionVersion} '
        'len=${newInstruction.length}');
    return <String, dynamic>{
      'ok': true,
      'target': targetId,
      'instruction_version': target.instructionVersion,
    };
  }

  /// 改他人模型（super agent 专属；模型名同样过密钥扫描，审计记元数据）。
  Future<Map<String, dynamic>> updateModel({
    required String callerId,
    required String targetId,
    required String model,
  }) async {
    if (!registry.hasManagementRights(callerId)) {
      return _noRights('updateModel');
    }
    final SubAgentRecord? target = registry.get(targetId);
    if (target == null) {
      return <String, dynamic>{'ok': false, 'error': '子 agent $targetId 不存在'};
    }
    final String next = model.trim();
    if (next.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '模型名不能为空'};
    }
    final SecretScanResult secret = SecretScanner.scan(next);
    if (secret.found) {
      await _audit('agent.update_model', 'denied', callerId,
          'target=$targetId secret_pattern=${secret.pattern}');
      return <String, dynamic>{
        'ok': false,
        'error': '模型名含疑似密钥内容（${secret.pattern}），已拒绝并记审计',
      };
    }
    final String previous = target.model;
    target.model = next;
    target.updatedAt = DateTime.now().toIso8601String();
    await _audit('agent.update_model', 'allowed', callerId,
        'target=$targetId from=$previous to=$next');
    return <String, dynamic>{
      'ok': true,
      'target': targetId,
      'model': next,
      'previous_model': previous,
    };
  }

  /// 给他人排例程（super agent 专属）：例程提示词过密钥扫描后，
  /// 经注入的 [RoutineScheduler] 真实创建，模型固定为目标 agent 当前模型。
  Future<Map<String, dynamic>> scheduleRoutine({
    required String callerId,
    required String targetId,
    required String name,
    required String prompt,
    required List<String> crons,
    String timezone = 'local',
  }) async {
    if (!registry.hasManagementRights(callerId)) {
      return _noRights('scheduleRoutine');
    }
    final SubAgentRecord? target = registry.get(targetId);
    if (target == null) {
      return <String, dynamic>{'ok': false, 'error': '子 agent $targetId 不存在'};
    }
    final RoutineScheduler? sched = scheduler;
    if (sched == null) {
      return <String, dynamic>{'ok': false, 'error': '未接入例程调度器，无法排例程'};
    }
    final SecretScanResult secret = SecretScanner.scan(prompt);
    if (secret.found) {
      await _audit('agent.schedule_routine', 'denied', callerId,
          'target=$targetId secret_pattern=${secret.pattern}');
      return <String, dynamic>{
        'ok': false,
        'error': '例程提示词含疑似密钥内容（${secret.pattern}），已拒绝并记审计',
      };
    }
    if (crons.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '例程时间表不能为空'};
    }
    final Map<String, dynamic> created = await sched.createRoutine(
      name: name,
      prompt: prompt,
      crons: crons,
      modelId: target.model,
      timezone: timezone,
    );
    if (created['ok'] != true) {
      await _audit('agent.schedule_routine', 'denied', callerId,
          'target=$targetId reason=${created['error'] ?? 'create failed'}');
      return <String, dynamic>{
        'ok': false,
        'error': '创建例程失败：${created['error'] ?? '未知错误'}',
      };
    }
    final Map<String, dynamic> routine =
        created['routine'] is Map ? Map<String, dynamic>.from(created['routine'] as Map) : <String, dynamic>{};
    await _audit('agent.schedule_routine', 'allowed', callerId,
        'target=$targetId routine=${routine['id'] ?? ''} model=${target.model}');
    return <String, dynamic>{
      'ok': true,
      'target': targetId,
      'routine': routine,
    };
  }

  /// 列出当前待审批（供审批卡 UI 读取；只读代理，不改审批状态）。
  Future<List<Map<String, dynamic>>> listPendingApprovals() =>
      gate.listPending();
}
