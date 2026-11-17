/// Tangram Super Agent —— 对标 DeepSeek Harness《Super-agent 设计探索》与
/// Claude Code subagents / Codex 并行线程 / WorkBuddy 定时任务。
///
/// 核心不是"更长的系统提示词"，而是把会话管理、授权、任务状态与执行分开：
///  * **Router**：常驻的全局协调节点（Main Session）。统一接收多源 Trigger，
///    维护跨源视图，做准入决策，派发授权工作，长任务不阻塞接收新事件。
///  * **Worker**：每个 Ticket 一个隔离执行上下文（独立 session + 工作目录 +
///    历史），异步执行，可接收跟进消息、报告进度、必要时派生 Subagent。
///  * **两级过滤**：程序规则先筛掉绝大多数无关消息，再由大模型判断是否行动；
///    无人 @ 也能识别潜在缺陷。模型不可用时如实标记降级、绝不假装判断。
///  * **Ticket / Mandate / Subscription**：工单保留授权范围（不可自我扩张）
///    与订阅；后续评论、CI 结果按 thread 映射回同一工单，而不是另起会话。
///  * **Watchdog**：独立检查步数/超时/重复输出/无进展，判定 stalled 并尝试
///    一次 re-plan，否则如实标记失败。
///  * **存算分离**：执行循环在内存，Tickets/Decisions/Events/上下文全部落到
///    HarnessStore；重启 load() 恢复，本地只留轻量 daemon。
///  * **observe 模式**：只记录"会接受什么"，不实际派发（对齐原型 begin in observe）。
///
/// 红线：GitHub / CI / 飞书 / 邮件等外部 Source 未配置凭据时如实标注未连接，
/// 绝不假装监听；Worker 只走真实推理链路，缺模型用内置 AgentLoop 的真实回复
/// 并如实标注 engine，绝不编造"已完成"；Mandate 越界一律拒绝。

import 'dart:async';
import 'dart:convert';

import 'package:tangram/harness/plugin_kernel.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/services/agent_memory.dart';

// ---------------------------------------------------------------------------
// 领域模型
// ---------------------------------------------------------------------------

/// 环境事件（群聊消息 / GitHub issue / CI 结果 / 邮件 / 定时 / 手动注入）。
class SuperTrigger {
  SuperTrigger({
    required this.id,
    required this.source,
    required this.kind,
    required this.text,
    this.thread = '',
    this.author = '',
    this.meta = const <String, dynamic>{},
    String? ts,
  }) : ts = ts ?? DateTime.now().toIso8601String();

  final String id;
  final String source;
  final String kind;
  final String text;
  final String thread;
  final String author;
  final Map<String, dynamic> meta;
  final String ts;

  String get dedupKey => '$source|$thread|$kind|${text.trim().toLowerCase()}';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'source': source,
        'kind': kind,
        'text': text,
        'thread': thread,
        'author': author,
        'meta': meta,
        'ts': ts,
      };

  static SuperTrigger fromJson(Map<String, dynamic> m) => SuperTrigger(
        id: (m['id'] ?? '').toString(),
        source: (m['source'] ?? '').toString(),
        kind: (m['kind'] ?? '').toString(),
        text: (m['text'] ?? '').toString(),
        thread: (m['thread'] ?? '').toString(),
        author: (m['author'] ?? '').toString(),
        meta: m['meta'] is Map
            ? Map<String, dynamic>.from(m['meta'] as Map)
            : <String, dynamic>{},
        ts: (m['ts'] ?? '').toString(),
      );
}

/// 授权范围：一旦签发不可自我扩张。
class Mandate {
  Mandate({
    required this.scope,
    required this.maxSteps,
    required this.deadlineSeconds,
    this.allowedTools = const <String>['chat'],
  });
  final String scope;
  final int maxSteps;
  final int deadlineSeconds;
  final List<String> allowedTools;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'scope': scope,
        'max_steps': maxSteps,
        'deadline_seconds': deadlineSeconds,
        'allowed_tools': allowedTools,
      };

  static Mandate fromJson(Map<String, dynamic> m) => Mandate(
        scope: (m['scope'] ?? '').toString(),
        maxSteps: (m['max_steps'] is num) ? (m['max_steps'] as num).toInt() : 3,
        deadlineSeconds: (m['deadline_seconds'] is num)
            ? (m['deadline_seconds'] as num).toInt()
            : 180,
        allowedTools: (m['allowed_tools'] is List)
            ? (m['allowed_tools'] as List)
                .map((dynamic e) => e.toString())
                .toList()
            : const <String>['chat'],
      );
}

enum TicketStatus { queued, running, done, failed, stopped, stalled, paused }

/// 任务工单：独立上下文、订阅、授权、进度、隔离工作目录。
class SuperTicket {
  SuperTicket({
    required this.id,
    required this.goal,
    required this.source,
    required this.thread,
    required this.mandate,
    this.parentId,
    this.priority = 5,
    this.notBefore,
    this.status = TicketStatus.queued,
    String? createdAt,
    String? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now().toIso8601String(),
        updatedAt = updatedAt ?? DateTime.now().toIso8601String();

  final String id;
  final String goal;
  final String source;
  final String thread;
  final Mandate mandate;
  final String? parentId;

  /// 用户可协商的工单优先级（0 最低、9 最高，默认 5）。
  /// 只影响排队顺序，不放大授权范围。
  int priority = 5;

  /// 延后执行的最早时间（ISO8601）；为空表示立即可调度。
  String? notBefore;
  TicketStatus status;
  final String createdAt;
  String updatedAt;
  final List<String> history = <String>[];
  final List<String> subscriptions = <String>[];
  final List<String> watchdogNotes = <String>[];
  final List<Map<String, dynamic>> reviews = <Map<String, dynamic>>[];
  /// Inline/Spill 分级存储：活跃上下文留在 [history]，低频历史压成
  /// [contextSummary] 并保留事件引用 [spillRefs]，避免上下文无限膨胀。
  String contextSummary = '';
  final List<int> spillRefs = <int>[];
  String result = '';
  String engine = '';
  int steps = 0;
  String workerSession = '';
  String workDir = '';
  bool replanned = false;

  /// 绑定的角色子 Agent（可选）：独立记忆文件、角色名与记忆作用域。
  String agentId = '';
  String agentName = '';
  String agentMemoryScope = 'isolated';

  /// 子工单的人格设定（name/identity/personality/audience）与角色说明。
  /// 只影响 Worker prompt 的表达方式，不改变 Mandate 授权范围。
  final Map<String, dynamic> persona = <String, dynamic>{};
  String role = '';

  /// 风险扫描 / 澄清结论的工单级注入项：只有真实产生时才会出现在 prompt。
  final List<String> riskNotes = <String>[];
  final List<String> clarifications = <String>[];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'goal': goal,
        'source': source,
        'thread': thread,
        'parent': parentId,
        'priority': priority,
        'not_before': notBefore,
        'status': status.name,
        'mandate': mandate.toJson(),
        'created_at': createdAt,
        'updated_at': updatedAt,
        'history': List<String>.of(history),
        'subscriptions': List<String>.of(subscriptions),
        'watchdog_notes': List<String>.of(watchdogNotes),
        'reviews': reviews.map((Map<String, dynamic> r) => Map<String, dynamic>.of(r)).toList(),
        'context_summary': contextSummary,
        'spill_refs': List<int>.of(spillRefs),
        'result': result,
        'engine': engine,
        'steps': steps,
        'worker_session': workerSession,
        'work_dir': workDir,
        'replanned': replanned,
        'persona': Map<String, dynamic>.of(persona),
        'role': role,
        'risk_notes': List<String>.of(riskNotes),
        'clarifications': List<String>.of(clarifications),
        'agent_id': agentId,
        'agent_name': agentName,
        'agent_memory_scope': agentMemoryScope,
      };

  static SuperTicket fromJson(Map<String, dynamic> m) {
    final SuperTicket t = SuperTicket(
      id: (m['id'] ?? '').toString(),
      goal: (m['goal'] ?? '').toString(),
      source: (m['source'] ?? '').toString(),
      thread: (m['thread'] ?? '').toString(),
      parentId: m['parent']?.toString(),
      priority: (m['priority'] is num) ? (m['priority'] as num).toInt().clamp(0, 9) : 5,
      notBefore: m['not_before']?.toString(),
      mandate: Mandate.fromJson(m['mandate'] is Map
          ? Map<String, dynamic>.from(m['mandate'] as Map)
          : <String, dynamic>{}),
      status: TicketStatus.values.firstWhere(
        (TicketStatus s) => s.name == (m['status'] ?? '').toString(),
        orElse: () => TicketStatus.queued,
      ),
      createdAt: (m['created_at'] ?? '').toString(),
      updatedAt: (m['updated_at'] ?? '').toString(),
    );
    t.history.addAll((m['history'] is List)
        ? (m['history'] as List).map((dynamic e) => e.toString())
        : <String>[]);
    t.subscriptions.addAll((m['subscriptions'] is List)
        ? (m['subscriptions'] as List).map((dynamic e) => e.toString())
        : <String>[]);
    t.watchdogNotes.addAll((m['watchdog_notes'] is List)
        ? (m['watchdog_notes'] as List).map((dynamic e) => e.toString())
        : <String>[]);
    t.reviews.addAll((m['reviews'] is List)
        ? (m['reviews'] as List).whereType<Map>().map(
            (Map e) => Map<String, dynamic>.from(e))
        : <Map<String, dynamic>>[]);
    t.contextSummary = (m['context_summary'] ?? '').toString();
    t.spillRefs.addAll((m['spill_refs'] is List)
        ? (m['spill_refs'] as List)
            .whereType<num>()
            .map((num e) => e.toInt())
        : <int>[]);
    t.result = (m['result'] ?? '').toString();
    t.engine = (m['engine'] ?? '').toString();
    t.steps = (m['steps'] is num) ? (m['steps'] as num).toInt() : 0;
    t.workerSession = (m['worker_session'] ?? '').toString();
    t.workDir = (m['work_dir'] ?? '').toString();
    t.replanned = m['replanned'] == true;
    if (m['persona'] is Map) {
      t.persona.addAll((m['persona'] as Map).map(
          (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)));
    }
    t.role = (m['role'] ?? '').toString();
    t.riskNotes.addAll((m['risk_notes'] is List)
        ? (m['risk_notes'] as List).map((dynamic e) => e.toString())
        : <String>[]);
    t.clarifications.addAll((m['clarifications'] is List)
        ? (m['clarifications'] as List).map((dynamic e) => e.toString())
        : <String>[]);
    t.agentId = (m['agent_id'] ?? '').toString();
    t.agentName = (m['agent_name'] ?? '').toString();
    t.agentMemoryScope =
        (m['agent_memory_scope'] ?? 'isolated').toString() == 'shared'
            ? 'shared'
            : 'isolated';
    return t;
  }
}

/// 两级过滤的审计决策（可查、只追加）。
class FilterDecision {
  FilterDecision({
    required this.id,
    required this.triggerId,
    required this.stage1,
    required this.stage1Rule,
    required this.stage2,
    required this.stage2Reason,
    required this.decision,
    this.ticketId = '',
    String? ts,
  }) : ts = ts ?? DateTime.now().toIso8601String();

  final String id;
  final String triggerId;
  final String stage1; // pass / drop
  final String stage1Rule;
  final String stage2; // act / ignore / degraded / skipped
  final String stage2Reason;
  final String decision; // accept_new_ticket / attach / stop / ignore / observe_only
  final String ticketId;
  final String ts;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'trigger_id': triggerId,
        'stage1': stage1,
        'stage1_rule': stage1Rule,
        'stage2': stage2,
        'stage2_reason': stage2Reason,
        'decision': decision,
        'ticket_id': ticketId,
        'ts': ts,
      };
}

/// 一个具名事件源的状态（read position / 是否真实连接）。
class SourceState {
  SourceState(this.id, this.kind, this.connected, this.note);
  final String id;
  final String kind;
  final bool connected;
  final String note;
  int readPosition = 0;
  int received = 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind,
        'connected': connected,
        'note': note,
        'read_position': readPosition,
        'received': received,
      };
}

// ---------------------------------------------------------------------------
// Super Agent 主控
// ---------------------------------------------------------------------------

typedef SuperAgentChat = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> p);

class SuperAgent {
  SuperAgent({
    required this.store,
    required this.chat,
    this.kernel,
    this.onEvent,
  });

  final HarnessStore store;
  final SuperAgentChat chat;
  final PluginKernel? kernel;
  final void Function(String topic, Map<String, dynamic> data)? onEvent;

  bool _initialized = false;
  bool observe = true; // 默认 observe：只记录会接受什么，不擅自行动
  int maxWorkers = 3;
  int defaultMaxSteps = 3;
  int defaultDeadlineSeconds = 180;

  /// 长任务收尾时自动做一次阶段复盘（真实推理，失败不影响交付）。
  bool autoReview = true;
  int _seq = 0;

  final Map<String, SuperTicket> _tickets = <String, SuperTicket>{};
  final List<SuperTrigger> _triggers = <SuperTrigger>[];
  final List<FilterDecision> _decisions = <FilterDecision>[];
  final List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _clarifications = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _options = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> _decisionLog = <Map<String, dynamic>>[];
  final List<String> _routerContext = <String>[];
  final Map<String, SourceState> _sources = <String, SourceState>{};
  final Set<String> _seenDedup = <String>{};
  final Set<String> _runningWorkers = <String>{};

  Map<String, dynamic> _rules = <String, dynamic>{
    'min_length': 4,
    'deny_keywords': <String>['广告', 'spam', '拼团'],
    'allow_keywords': <String>[],
    'allowed_sources': <String>['manual', 'im', 'schedule'],
  };

  bool get initialized => _initialized;
  int get runningCount => _runningWorkers.length;

  /// 从磁盘恢复全部状态（存算分离：执行循环在内存，状态落盘）。
  Future<void> init() async {
    if (_initialized) return;
    final Map<String, dynamic> cfg = await store.readJson('super_config.json');
    // 默认 observe（只读、不擅自行动）只在磁盘显式写过 observe 时才被恢复值覆盖。
    // 首次启动无配置文件时必须保持 true，避免 `null == true` 把默认值踩成 false。
    observe = cfg.containsKey('observe') ? cfg['observe'] == true : true;
    maxWorkers = (cfg['max_workers'] is num)
        ? (cfg['max_workers'] as num).toInt()
        : 3;
    defaultMaxSteps = (cfg['default_max_steps'] is num)
        ? (cfg['default_max_steps'] as num).toInt()
        : 3;
    defaultDeadlineSeconds = (cfg['default_deadline_seconds'] is num)
        ? (cfg['default_deadline_seconds'] as num).toInt()
        : 180;
    autoReview = cfg.containsKey('auto_review') ? cfg['auto_review'] == true : true;
    if (cfg['rules'] is Map) {
      _rules = Map<String, dynamic>.from(cfg['rules'] as Map);
    }
    _seq = (cfg['seq'] is num) ? (cfg['seq'] as num).toInt() : 0;

    _triggers.addAll((await store.readRecords('super_triggers'))
        .map(SuperTrigger.fromJson));
    for (final SuperTrigger t in _triggers) {
      _seenDedup.add(t.dedupKey);
    }
    for (final Map<String, dynamic> m
        in await store.readRecords('super_tickets')) {
      final SuperTicket t = SuperTicket.fromJson(m);
      _tickets[t.id] = t;
    }
    _events.addAll(await store.readRecords('super_events'));
    _clarifications.addAll(await store.readRecords('super_clarifications'));
    _options.addAll(await store.readRecords('super_options'));
    _decisionLog.addAll(await store.readRecords('super_decision_log'));
    final List<dynamic> ctx = await store.readList('super_router_context.json');
    _routerContext.addAll(ctx.map((dynamic e) => e.toString()));

    // 真实源清单：manual 永远可用（本地注入，确实连着）；其余如实标注未配置。
    final Map<String, dynamic> savedSources =
        await store.readJson('super_sources.json');
    _sources['manual'] = SourceState('manual', 'local', true, '本地注入通道，真实可用');
    _sources['im'] = SourceState('im', 'gateway', false,
        '需在「更多通信」完成真实扫码/凭据连接后由网关转发入站消息');
    _sources['schedule'] = SourceState('schedule', 'timer', true,
        '读取 proactive_rules 真实规则；由 Router 按需触发');
    _sources['github'] =
        SourceState('github', 'webhook', false, '未配置仓库/令牌，不假装监听');
    _sources['ci'] = SourceState('ci', 'webhook', false, '未配置 CI 回调，不假装监听');
    _sources['email'] =
        SourceState('email', 'imap', false, '未配置邮箱凭据，不假装监听');
    for (final MapEntry<String, SourceState> e in _sources.entries) {
      final dynamic s = savedSources[e.key];
      if (s is Map) {
        e.value.readPosition =
            (s['read_position'] is num) ? (s['read_position'] as num).toInt() : 0;
        e.value.received = (s['received'] is num) ? (s['received'] as num).toInt() : 0;
      }
    }
    _initialized = true;
    _log('super.agent.init', <String, dynamic>{
      'observe': observe,
      'restored_tickets': _tickets.length,
      'restored_triggers': _triggers.length,
    });
  }

  void _log(String topic, Map<String, dynamic> data) {
    final Map<String, dynamic> ev = <String, dynamic>{
      'seq': ++_seq,
      'topic': topic,
      'ts': DateTime.now().toIso8601String(),
      ...data,
    };
    _events.add(ev);
    unawaited(_persistLog(ev));
    final void Function(String, Map<String, dynamic>)? cb = onEvent;
    if (cb != null) cb(topic, ev);
    final PluginKernel? k = kernel;
    if (k != null) k.emit(topic, 'super-agent', data);
  }

  /// 轨迹落盘尽力而为：内存 _events 已真实追加，回调与内核事件照常派发；
  /// 一次磁盘异常不得变成未捕获异步异常崩掉常驻 Router。事件量大，失败
  /// 不逐条记账以免刷屏；状态类落盘失败由 _safeWrite 如实记录。
  Future<void> _persistLog(Map<String, dynamic> ev) async {
    try {
      await store.insert('super_events', ev);
    } on Object {
      // 如实吞掉，见上方注释。
    }
  }

  /// 状态落盘失败如实记账（内存状态是主状态，磁盘只是可恢复副本）。
  final List<String> _persistErrors = <String>[];

  /// 所有状态落盘统一走这里：数据目录被清理 / 只读 / 空间不足时，
  /// 绝不让 fire-and-forget 变成未捕获异步异常崩掉常驻 Router。
  Future<void> _safeWrite(Future<void> Function() op, String what) async {
    try {
      await op();
    } on Object catch (e) {
      if (_persistErrors.length < 50) {
        _persistErrors.add('$what 落盘失败：$e');
      }
    }
  }

  Future<void> _insert(String key, Map<String, dynamic> record) =>
      _safeWrite(() async {
        await store.insert(key, record);
      }, key);

  /// 只追加记录：落盘后把真实自增 id 回填到内存记录；失败如实记账。
  Future<void> _appendRecord(String key, Map<String, dynamic> record) async {
    try {
      final int id = await store.insert(key, record);
      record['id'] = id;
    } on Object catch (e) {
      if (_persistErrors.length < 50) {
        _persistErrors.add('$key 落盘失败：$e');
      }
    }
  }

  /// 从模型回复中提取严格 JSON 对象。解析失败返回空 map，绝不脑补字段。
  Map<String, dynamic> _parseJsonObject(String reply) {
    final String text = reply.trim();
    if (text.isEmpty) return <String, dynamic>{};
    final List<String> candidates = <String>[];
    final RegExpMatch? fenced =
        RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (fenced != null) candidates.add(fenced.group(1)!.trim());
    candidates.add(text);
    final RegExpMatch? braced = RegExp(r'\{[\s\S]*\}').firstMatch(text);
    if (braced != null) candidates.add(braced.group(0)!);
    for (final String c in candidates) {
      if (c.isEmpty) continue;
      try {
        final dynamic decoded = jsonDecode(c);
        if (decoded is Map) {
          return decoded.map(
              (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v));
        }
      } on Object {
        // 该候选不是合法 JSON，继续尝试下一个。
      }
    }
    return <String, dynamic>{};
  }

  /// 把任意值规整成字符串数组（只接受列表/字符串，其它形态不臆测）。
  List<String> _stringList(dynamic v) {
    if (v is List) {
      return v
          .map((dynamic e) => e.toString().trim())
          .where((String s) => s.isNotEmpty)
          .toList();
    }
    if (v is String) {
      final String s = v.trim();
      return s.isEmpty ? <String>[] : <String>[s];
    }
    return <String>[];
  }

  /// 内置兜底 / 远端失败不算真实模型推理，调用方据此如实标注。
  bool _engineDegraded(Map<String, dynamic> r) {
    final String engine = (r['engine'] ?? '').toString();
    return r['ok'] == false ||
        engine.isEmpty ||
        engine == 'builtin-agent-loop' ||
        engine == 'remote-failed';
  }

  String _truncate(String s, int max) =>
      s.length > max ? '${s.substring(0, max)}…' : s;

  Map<String, dynamic> _sanitizePersona(dynamic raw) {
    if (raw is! Map) return <String, dynamic>{};
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final String key in <String>[
      'name',
      'identity',
      'personality',
      'audience',
    ]) {
      final String v = (raw[key] ?? '').toString().trim();
      if (v.isNotEmpty) out[key] = v;
    }
    return out;
  }

  /// 统一走真实 chat 回调；调用异常如实回传 error，不伪造引擎名。
  Future<Map<String, dynamic>> _chatFor(String prompt, String session) async {
    try {
      return await chat(<String, dynamic>{'text': prompt, 'session_id': session});
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'engine': 'error', 'error': '$e'};
    }
  }

  // ---- L3 认知闭环：澄清 / 隐性目标 / 风险扫描 / 路线对比 / 决策日志 ----

  /// 澄清目标：产出问题清单、隐性目标、缺失条件与验收标准。
  Future<Map<String, dynamic>> _clarify(Map<String, dynamic> p) async {
    final String goal = (p['goal'] ?? '').toString().trim();
    if (goal.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '目标内容为空'};
    }
    final String context = (p['context'] ?? '').toString().trim();
    final StringBuffer b = StringBuffer()
      ..writeln('你是 Super Agent 的需求澄清器（clarify），只输出一个 JSON 对象，不要解释。')
      ..writeln('硬性要求：缺失的信息必须写进 questions 或 missing_conditions；'
          '禁止脑补假设，不得把猜测写成 acceptance_criteria。')
      ..writeln('目标：$goal');
    if (context.isNotEmpty) b.writeln('已知上下文：$context');
    b.writeln('JSON 字段：questions(string[])、implicit_goal(string)、'
        'missing_conditions(string[])、acceptance_criteria(string[])。');
    final Map<String, dynamic> r = await _chatFor(b.toString(), 'super-clarify');
    final String engine = (r['engine'] ?? '').toString();
    final String reply = (r['reply'] ?? r['error'] ?? '').toString();
    final Map<String, dynamic> parsed = _parseJsonObject(reply);
    final bool structured = parsed.isNotEmpty;
    final List<String> questions = _stringList(parsed['questions']);
    final String implicitGoal = (parsed['implicit_goal'] ?? '').toString().trim();
    final List<String> missing = _stringList(parsed['missing_conditions']);
    final List<String> acceptance = _stringList(parsed['acceptance_criteria']);
    final Map<String, dynamic> record = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'goal': goal,
      'engine': engine,
      'degraded': _engineDegraded(r),
      'structured': structured,
      'questions': questions,
      'implicit_goal': implicitGoal,
      'missing_conditions': missing,
      'acceptance_criteria': acceptance,
      'raw': _truncate(reply, 1200),
    };
    await _appendRecord('super_clarifications', record);
    _clarifications.add(record);
    _log('super.cognitive.clarify', <String, dynamic>{
      'goal': goal,
      'structured': structured,
      'questions': questions.length,
      'engine': engine,
    });
    return <String, dynamic>{
      'ok': true,
      'engine': engine,
      'degraded': record['degraded'],
      'structured': structured,
      'questions': questions,
      'implicit_goal': implicitGoal,
      'missing_conditions': missing,
      'acceptance_criteria': acceptance,
      'clarification': record,
    };
  }

  /// 隐性目标：区分表层指令与真实意图，并列出必须人工确认的点。
  Future<Map<String, dynamic>> _implicitGoal(Map<String, dynamic> p) async {
    final String goal = (p['goal'] ?? '').toString().trim();
    if (goal.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '目标内容为空'};
    }
    final String context = (p['context'] ?? '').toString().trim();
    final StringBuffer b = StringBuffer()
      ..writeln('你是 Super Agent 的隐性目标分析器（implicit_goal），只输出一个 JSON 对象，不要解释。')
      ..writeln('要求：只依据目标文字与已知上下文；不确定的推断必须放进 confirm_points，'
          '禁止把猜测当成事实。')
      ..writeln('目标：$goal');
    if (context.isNotEmpty) b.writeln('已知上下文：$context');
    b.writeln('JSON 字段：surface_instruction(string)、implicit_goal(string)、'
        'confirm_points(string[])。');
    final Map<String, dynamic> r = await _chatFor(b.toString(), 'super-implicit');
    final String engine = (r['engine'] ?? '').toString();
    final String reply = (r['reply'] ?? r['error'] ?? '').toString();
    final Map<String, dynamic> parsed = _parseJsonObject(reply);
    final String parsedSurface =
        (parsed['surface_instruction'] ?? '').toString().trim();
    final String surface = parsedSurface.isEmpty ? goal : parsedSurface;
    final String implicit = (parsed['implicit_goal'] ?? '').toString().trim();
    final List<String> confirm = _stringList(parsed['confirm_points']);
    final Map<String, dynamic> entry = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'kind': 'implicit_goal',
      'goal': goal,
      'engine': engine,
      'degraded': _engineDegraded(r),
      'structured': parsed.isNotEmpty,
      'surface_instruction': surface,
      'implicit_goal': implicit,
      'confirm_points': confirm,
      'raw': _truncate(reply, 1200),
    };
    await _appendRecord('super_decision_log', entry);
    _decisionLog.add(entry);
    _log('super.cognitive.implicit_goal', <String, dynamic>{
      'goal': goal,
      'structured': entry['structured'],
      'engine': engine,
    });
    return <String, dynamic>{
      'ok': true,
      'engine': engine,
      'degraded': entry['degraded'],
      'structured': entry['structured'],
      'surface_instruction': surface,
      'implicit_goal': implicit,
      'confirm_points': confirm,
      'entry': entry,
    };
  }

  /// 确定性风险规则：纯文本匹配 + Mandate 越界检查，不依赖模型。
  List<Map<String, dynamic>> _deterministicRisks(
    String goal,
    Map<String, dynamic>? mandate,
    List<String> requestedTools,
  ) {
    final String text = goal.toLowerCase();
    final List<Map<String, dynamic>> risks = <Map<String, dynamic>>[];
    List<String> hits(List<String> words) =>
        words.where((String w) => text.contains(w.toLowerCase())).toList();
    void add(String level, String type, String detail, String mitigation,
        List<String> matched) {
      if (matched.isEmpty) return;
      risks.add(<String, dynamic>{
        'level': level,
        'type': type,
        'detail': '$detail（命中：${matched.join("、")}）',
        'mitigation': mitigation,
        'source': 'rule',
      });
    }

    final List<String> destructive = hits(<String>[
      '删除',
      '清空',
      '销毁',
      'rm -rf',
      'delete',
      'truncate',
      'drop table',
      'destroy',
      'erase',
    ]);
    add('high', 'destructive', '涉及破坏性删除/清空操作',
        '先在隔离副本演练，确认可回滚备份后再执行', destructive);
    add('medium', 'overwrite', '涉及覆盖/覆写既有内容',
        '保留旧版本备份，并确认覆盖范围与回滚方式',
        hits(<String>['覆盖', '覆写', 'overwrite']));
    final List<String> publishHits =
        hits(<String>['发布', '上线', '部署', 'publish', 'deploy', 'release']);
    final bool production =
        hits(<String>['生产环境', '生产', 'prod', '线上环境']).isNotEmpty;
    add(
        production ? 'high' : 'medium',
        'publish',
        production ? '涉及生产环境发布/上线' : '涉及发布或部署动作',
        '灰度发布并准备回滚预案；生产发布必须人工二次确认',
        publishHits);
    add('high', 'secrets', '涉及密钥/密码/凭据操作',
        '仅使用受控密钥引用，不写入日志与上下文，必要时先轮换',
        hits(<String>[
          '密钥',
          '密码',
          '私钥',
          '凭据',
          'token',
          'api key',
          'apikey',
          'secret',
          'credential',
        ]));
    add('high', 'disk', '涉及磁盘/分区/格式化等底层操作',
        '先确认磁盘与快照，限制写入路径与配额',
        hits(<String>['磁盘', '硬盘', '分区', '格式化', 'mkfs', 'fdisk', 'dd if=']));
    add('medium', 'gpu', '涉及显存/GPU 资源占用',
        '评估显存峰值，分批加载并准备回退',
        hits(<String>['显存', 'gpu', 'vram', 'cuda', '显卡']));
    add('high', 'permission', '涉及权限变更/提权',
        '遵循最小权限；越权操作必须人工重新签发 Mandate',
        hits(<String>['权限', 'chmod', 'chown', 'sudo', 'root', '提权']));
    add(destructive.isNotEmpty ? 'high' : 'medium', 'batch', '涉及批量/全量操作',
        '分批执行并设置中止阈值，先小范围验证',
        hits(<String>['批量', '全部', '所有', '全量', 'bulk', 'all files']));

    final List<String> allowed = (mandate?['allowed_tools'] is List)
        ? (mandate!['allowed_tools'] as List)
            .map((dynamic e) => e.toString())
            .toList()
        : <String>['chat'];
    final List<String> overreach =
        requestedTools.where((String t) => !allowed.contains(t)).toList();
    if (overreach.isNotEmpty) {
      risks.add(<String, dynamic>{
        'level': 'high',
        'type': 'mandate',
        'detail': '请求工具 ${overreach.join("、")} 超出 Mandate 授权范围'
            '（允许：${allowed.join("、")}）',
        'mitigation': '需人工重新签发授权；系统不会自动放权',
        'source': 'rule',
      });
    }
    return risks;
  }

  List<Map<String, dynamic>> _normalizeModelRisks(dynamic raw) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    if (raw is! List) return out;
    for (final dynamic e in raw) {
      if (e is! Map) continue;
      final String level = (e['level'] ?? '').toString().toLowerCase();
      final String type = (e['type'] ?? '').toString().trim();
      final String detail = (e['detail'] ?? '').toString().trim();
      if (type.isEmpty && detail.isEmpty) continue;
      out.add(<String, dynamic>{
        'level': <String>['low', 'medium', 'high', 'critical'].contains(level)
            ? level
            : 'unknown',
        'type': type.isEmpty ? 'unspecified' : type,
        'detail': detail,
        'mitigation': (e['mitigation'] ?? '').toString().trim(),
        'source': 'model',
      });
    }
    return out;
  }

  /// 风险扫描：确定性规则先行，模型只补充规则未覆盖的风险。
  /// 高危自动写审计事件；Mandate 一律不改写、不放权。
  Future<Map<String, dynamic>> _riskScan(Map<String, dynamic> p) async {
    final String goal = (p['goal'] ?? '').toString().trim();
    if (goal.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '目标内容为空'};
    }
    final Map<String, dynamic>? mandate = p['mandate'] is Map
        ? Map<String, dynamic>.from(p['mandate'] as Map)
        : null;
    final List<String> tools = _stringList(p['tools']);
    final List<Map<String, dynamic>> deterministic =
        _deterministicRisks(goal, mandate, tools);
    final StringBuffer b = StringBuffer()
      ..writeln('你是 Super Agent 的风险扫描器（risk_scan），只输出一个 JSON 对象，不要解释。')
      ..writeln('要求：只补充下面程序规则未覆盖的风险；没有新增就返回空数组，禁止编造。')
      ..writeln('目标：$goal');
    if (mandate != null) b.writeln('授权 Mandate：${jsonEncode(mandate)}');
    if (tools.isNotEmpty) b.writeln('拟使用工具：${tools.join("、")}');
    b.writeln('程序规则已识别风险：${jsonEncode(deterministic)}');
    b.writeln('JSON 字段：risks[{level(low|medium|high)、type、detail、mitigation}]。');
    final Map<String, dynamic> r = await _chatFor(b.toString(), 'super-risk');
    final String engine = (r['engine'] ?? '').toString();
    final String reply = (r['reply'] ?? r['error'] ?? '').toString();
    final Map<String, dynamic> parsed = _parseJsonObject(reply);
    final List<Map<String, dynamic>> modelRisks =
        _normalizeModelRisks(parsed['risks']);
    final List<Map<String, dynamic>> risks =
        <Map<String, dynamic>>[...deterministic];
    final Set<String> seen = risks
        .map((Map<String, dynamic> x) => '${x['type']}|${x['detail']}')
        .toSet();
    for (final Map<String, dynamic> m in modelRisks) {
      if (seen.add('${m['type']}|${m['detail']}')) risks.add(m);
    }
    final bool highRisk = risks.any((Map<String, dynamic> x) =>
        x['level'] == 'high' || x['level'] == 'critical');
    int audited = 0;
    for (final Map<String, dynamic> risk in risks
        .where((Map<String, dynamic> x) =>
            x['level'] == 'high' || x['level'] == 'critical')
        .take(10)) {
      final Map<String, dynamic> audit = <String, dynamic>{
        'ts': DateTime.now().toIso8601String(),
        'goal': goal,
        'level': risk['level'],
        'type': risk['type'],
        'detail': risk['detail'],
        'mitigation': risk['mitigation'],
        'source': risk['source'],
      };
      await _appendRecord('super_audit_events', audit);
      _log('super.risk.audit', audit);
      audited += 1;
    }
    _log('super.cognitive.risk_scan', <String, dynamic>{
      'goal': goal,
      'risks': risks.length,
      'high_risk': highRisk,
      'engine': engine,
    });
    return <String, dynamic>{
      'ok': true,
      'engine': engine,
      'degraded': _engineDegraded(r),
      'model_structured': parsed.isNotEmpty,
      'risks': risks,
      'deterministic': deterministic,
      'model_risks': modelRisks,
      'high_risk': highRisk,
      'audit_logged': audited > 0,
      'audit_count': audited,
      'mandate_unchanged': true,
    };
  }

  /// 路线对比：要求模型给出 2-3 条路线及推荐，严格 JSON。
  /// 模型给少了不补齐（绝不编造），用 meets_route_range 如实标记。
  Future<Map<String, dynamic>> _optionsAction(Map<String, dynamic> p) async {
    final String goal = (p['goal'] ?? '').toString().trim();
    if (goal.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '目标内容为空'};
    }
    final String context = (p['context'] ?? '').toString().trim();
    final List<String> constraints = _stringList(p['constraints']);
    final StringBuffer b = StringBuffer()
      ..writeln('你是 Super Agent 的路线设计器（options），只输出一个 JSON 对象，不要解释。')
      ..writeln('请给出 2-3 条互不相同的路线，每条必须包含 benefits/costs/risks/fit/tradeoff。')
      ..writeln('不得虚构未知事实；信息不足时在 fit 中说明需要补充的条件。')
      ..writeln('目标：$goal');
    if (context.isNotEmpty) b.writeln('已知上下文：$context');
    if (constraints.isNotEmpty) b.writeln('约束：${constraints.join("；")}');
    b.writeln('JSON 字段：options[{name、benefits(string[])、costs(string[])、'
        'risks(string[])、fit(string)、tradeoff(string)}]、recommendation(string)。');
    final Map<String, dynamic> r = await _chatFor(b.toString(), 'super-options');
    final String engine = (r['engine'] ?? '').toString();
    final String reply = (r['reply'] ?? r['error'] ?? '').toString();
    final Map<String, dynamic> parsed = _parseJsonObject(reply);
    final List<Map<String, dynamic>> options = <Map<String, dynamic>>[];
    final dynamic raw = parsed['options'];
    if (raw is List) {
      for (final dynamic e in raw) {
        if (e is! Map) continue;
        options.add(<String, dynamic>{
          'name': (e['name'] ?? e['title'] ?? '').toString().trim(),
          'benefits': _stringList(e['benefits']),
          'costs': _stringList(e['costs']),
          'risks': _stringList(e['risks']),
          'fit': (e['fit'] ?? '').toString().trim(),
          'tradeoff': (e['tradeoff'] ?? '').toString().trim(),
        });
        if (options.length >= 3) break;
      }
    }
    final String recommendation =
        (parsed['recommendation'] ?? '').toString().trim();
    final Map<String, dynamic> record = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'goal': goal,
      'engine': engine,
      'degraded': _engineDegraded(r),
      'structured': parsed.isNotEmpty,
      'options': options,
      'recommendation': recommendation,
      'raw': _truncate(reply, 1600),
    };
    await _appendRecord('super_options', record);
    _options.add(record);
    _log('super.cognitive.options', <String, dynamic>{
      'goal': goal,
      'structured': record['structured'],
      'routes': options.length,
      'engine': engine,
    });
    return <String, dynamic>{
      'ok': true,
      'engine': engine,
      'degraded': record['degraded'],
      'structured': record['structured'],
      'options': options,
      'recommendation': recommendation,
      'meets_route_range': options.length >= 2 && options.length <= 3,
      'report': record,
    };
  }

  /// 追加式决策日志：choice / options_considered / reason / constraints /
  /// rejected / ticket_id，落盘 super_decision_log。
  Future<Map<String, dynamic>> _logDecision(Map<String, dynamic> p) async {
    final String choice = (p['choice'] ?? '').toString().trim();
    if (choice.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': 'choice 不能为空'};
    }
    final Map<String, dynamic> entry = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'kind': 'decision',
      'choice': choice,
      'options_considered': _stringList(p['options_considered']),
      'reason': (p['reason'] ?? '').toString().trim(),
      'constraints': _stringList(p['constraints']),
      'rejected': _stringList(p['rejected']),
      'ticket_id': (p['ticket_id'] ?? '').toString().trim(),
    };
    await _appendRecord('super_decision_log', entry);
    _decisionLog.add(entry);
    _log('super.decision.log', <String, dynamic>{
      'choice': choice,
      'ticket': entry['ticket_id'],
    });
    return <String, dynamic>{'ok': true, 'entry': entry};
  }

  /// 决策视图：汇总 decisions / reviews / options / clarifications /
  /// decision_log 的最近记录（每条最多 limit 条）。
  Map<String, dynamic> _decisionLogView(Map<String, dynamic> p) {
    final int limit = p['limit'] is num
        ? (p['limit'] as num).toInt().clamp(1, 100)
        : 20;
    final List<Map<String, dynamic>> reviews = <Map<String, dynamic>>[];
    for (final SuperTicket t in _tickets.values) {
      for (final Map<String, dynamic> r in t.reviews) {
        reviews.add(<String, dynamic>{'ticket': t.id, ...r});
      }
    }
    return <String, dynamic>{
      'ok': true,
      'limit': limit,
      'decisions':
          _decisions.reversed.take(limit).map((FilterDecision d) => d.toJson()).toList(),
      'reviews': reviews.reversed.take(limit).toList(),
      'options': _options.reversed.take(limit).toList(),
      'clarifications': _clarifications.reversed.take(limit).toList(),
      'decision_log': _decisionLog.reversed.take(limit).toList(),
    };
  }

  /// 人工修订：追加反馈并按需重新入队。running 工单拒绝改动，
  /// 避免破坏正在累加的步数账本；重入队保留既有 steps 记录。
  Future<Map<String, dynamic>> _revise(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final SuperTicket? t = _tickets[id];
    if (t == null) {
      return <String, dynamic>{'ok': false, 'error': '工单不存在'};
    }
    final String feedback =
        (p['feedback'] ?? p['text'] ?? '').toString().trim();
    if (feedback.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '反馈内容为空'};
    }
    if (t.status == TicketStatus.running || _runningWorkers.contains(id)) {
      return <String, dynamic>{
        'ok': false,
        'error': '运行中的工单不可修订入队（避免破坏步数账本），请先暂停',
      };
    }
    final bool wantRequeue = p['requeue'] != false;
    const Set<TicketStatus> requeueable = <TicketStatus>{
      TicketStatus.done,
      TicketStatus.failed,
      TicketStatus.paused,
      TicketStatus.stalled,
      TicketStatus.stopped,
      TicketStatus.queued,
    };
    if (wantRequeue && !requeueable.contains(t.status)) {
      return <String, dynamic>{
        'ok': false,
        'error': '当前状态 ${t.status.name} 不可修订入队',
      };
    }
    t.history.add('[人工修订] $feedback');
    t.riskNotes.addAll(_stringList(p['risk_hints']));
    t.clarifications.addAll(_stringList(p['clarifications']));
    t.updatedAt = DateTime.now().toIso8601String();
    bool requeued = false;
    if (wantRequeue) {
      t.status = TicketStatus.queued;
      t.notBefore = null;
      t.replanned = false;
      t.history.add('[人工修订入队] 重置为 queued，保留既有步数账本');
      requeued = true;
    }
    await _persistTickets();
    _log('super.ticket.revise', <String, dynamic>{
      'ticket': id,
      'requeued': requeued,
    });
    if (requeued) await _drainQueue();
    return <String, dynamic>{
      'ok': true,
      'id': id,
      'status': t.status.name,
      'requeued': requeued,
      'ticket': t.toJson(),
    };
  }

  Future<void> _persistConfig() => _safeWrite(() async {
        await store.writeJson('super_config.json', <String, dynamic>{
          'observe': observe,
          'max_workers': maxWorkers,
          'default_max_steps': defaultMaxSteps,
          'default_deadline_seconds': defaultDeadlineSeconds,
          'auto_review': autoReview,
          'rules': _rules,
          'seq': _seq,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }, 'super_config');

  Future<void> _persistSources() => _safeWrite(() async {
        await store.writeJson('super_sources.json',
            _sources.map((String k, SourceState v) =>
                MapEntry<String, dynamic>(k, v.toJson())));
      }, 'super_sources');

  Future<void> _persistTickets() => _safeWrite(() async {
        await store.writeRecords('super_tickets',
            _tickets.values.map((SuperTicket t) => t.toJson()).toList());
      }, 'super_tickets');

  Future<void> _persistRouterContext() => _safeWrite(() async {
        await store.writeJson('super_router_context.json', _routerContext);
      }, 'super_router_context');

  // ---- 两级过滤 ----

  /// 第一级：程序规则（去重/长度/黑白名单/来源准入/频率）。快速、确定性。
  (String, String) _stage1(SuperTrigger t) {
    if (t.text.trim().length < ((_rules['min_length'] as num?)?.toInt() ?? 4)) {
      return ('drop', 'too_short');
    }
    if (_seenDedup.contains(t.dedupKey)) {
      return ('drop', 'duplicate');
    }
    final List<dynamic> deny =
        _rules['deny_keywords'] is List ? _rules['deny_keywords'] as List : <dynamic>[];
    for (final dynamic k in deny) {
      if (t.text.toLowerCase().contains(k.toString().toLowerCase())) {
        return ('drop', 'deny_keyword:$k');
      }
    }
    final List<dynamic> allowed =
        _rules['allowed_sources'] is List
            ? _rules['allowed_sources'] as List
            : <dynamic>[];
    if (allowed.isNotEmpty && !allowed.contains(t.source)) {
      return ('drop', 'source_not_allowed:${t.source}');
    }
    final List<dynamic> allow =
        _rules['allow_keywords'] is List ? _rules['allow_keywords'] as List : <dynamic>[];
    if (allow.isNotEmpty &&
        !allow.any((dynamic k) => t.text.toLowerCase().contains(k.toString().toLowerCase()))) {
      return ('drop', 'no_allow_keyword');
    }
    return ('pass', 'rules_ok');
  }

  /// 第二级：大模型判断是否值得行动。
  /// 真实调用 _chat；若引擎是内置兜底或远端失败，如实标记 degraded 并保守不行动，
  /// 绝不假装模型做了判断。返回 (stage2, reason, shouldAct)。
  Future<(String, String, bool)> _stage2(SuperTrigger t) async {
    const String judge = '你是 Super Agent 的准入过滤器。仅依据下面这条环境事件判断'
        '是否需要 AI 主动介入处理（如明确的缺陷报告、修复请求、任务分派）。'
        '只回答一个词：ACT 或 IGNORE。不要解释。\n事件：';
    Map<String, dynamic> r;
    try {
      r = await chat(<String, dynamic>{'text': '$judge${t.text}'});
    } on Object catch (e) {
      return ('degraded', '推理调用异常：$e', false);
    }
    final String engine = (r['engine'] ?? '').toString();
    final String reply = (r['reply'] ?? '').toString();
    // 内置 AgentLoop 兜底 / 远端失败 ≠ 真实模型判断，如实降级。
    if (engine == 'builtin-agent-loop' || engine == 'remote-failed' ||
        engine.isEmpty || r['ok'] == false) {
      return ('degraded', '无真实推理引擎（engine=$engine），保守不行动', false);
    }
    final bool act = reply.toUpperCase().contains('ACT') &&
        !reply.toUpperCase().contains('IGNORE');
    return (act ? 'act' : 'ignore', 'model engine=$engine', act);
  }

  // ---- Router：接收 Trigger → 两级过滤 → 决策 ----

  /// 注入一个环境事件并异步走完整 Router 决策链。
  Future<Map<String, dynamic>> ingest(SuperTrigger t) async {
    await init();
    _triggers.add(t);
    await _insert('super_triggers', t.toJson());
    final SourceState? src = _sources[t.source];
    if (src != null) {
      src.received += 1;
      src.readPosition += 1;
      await _persistSources();
    }
    _routerContext.add('[${t.ts}] ${t.source}/${t.kind} from ${t.author}: ${t.text}');
    if (_routerContext.length > 200) _routerContext.removeAt(0);
    await _persistRouterContext();

    // 去重判定必须基于「本次事件之前」的历史：先把本次 key 加进去再判定会让
    // 每条事件都命中 duplicate（自己撞自己）。判定结束后才登记，供后续去重。
    final (String s1, String rule) = _stage1(t);
    _seenDedup.add(t.dedupKey);
    if (s1 == 'drop') {
      return await _recordDecision(t, 'drop', rule, 'ignored', 'ignore');
    }

    // observe 模式：记录"会接受什么"，但绝不实际派发。
    if (observe) {
      return await _recordDecision(t, 'pass', rule, 'skipped', 'observe_only',
          reason: 'observe 模式：仅记录，不派发');
    }

    final (String s2, String reason, bool shouldAct) = await _stage2(t);
    if (s2 == 'degraded' || !shouldAct) {
      return await _recordDecision(t, 'pass', rule, s2, 'ignore', reason: reason);
    }

    // 同一 thread 已有活动工单 → attach 跟进消息（订阅回原工单）。
    final SuperTicket? existing = _activeTicketForThread(t.thread);
    if (existing != null) {
      existing.history.add('[跟进·${t.source}] ${t.text}');
      existing.subscriptions.add(t.id);
      existing.updatedAt = DateTime.now().toIso8601String();
      await _persistTickets();
      _log('super.router.attach', <String, dynamic>{
        'ticket': existing.id,
        'trigger': t.id,
      });
      return await _recordDecision(t, 'pass', rule, s2, 'attach',
          ticketId: existing.id, reason: reason);
    }

    // 达到并发上限 → 如实排队（不谎称已在跑）。
    if (_runningWorkers.length >= maxWorkers) {
      final SuperTicket queued = await _createTicket(t);
      return await _recordDecision(t, 'pass', rule, s2, 'accept_new_ticket',
          ticketId: queued.id, reason: '$reason；并发已满，工单排队');
    }

    final SuperTicket ticket = await _createTicket(t);
    unawaited(_runWorker(ticket.id));
    return await _recordDecision(t, 'pass', rule, s2, 'accept_new_ticket',
        ticketId: ticket.id, reason: reason);
  }

  Future<Map<String, dynamic>> _recordDecision(
    SuperTrigger t,
    String stage1,
    String stage1Rule,
    String stage2,
    String decision, {
    String ticketId = '',
    String reason = '',
  }) async {
    final FilterDecision d = FilterDecision(
      id: 'dec-${++_seq}',
      triggerId: t.id,
      stage1: stage1,
      stage1Rule: stage1Rule,
      stage2: stage2,
      stage2Reason: reason,
      decision: decision,
      ticketId: ticketId,
    );
    _decisions.add(d);
    await _insert('super_decisions', d.toJson());
    _log('super.router.decision', <String, dynamic>{
      'trigger': t.id,
      'decision': decision,
      'stage2': stage2,
    });
    return <String, dynamic>{
      'ok': true,
      'decision': d.toJson(),
    };
  }

  SuperTicket? _activeTicketForThread(String thread) {
    if (thread.isEmpty) return null;
    for (final SuperTicket t in _tickets.values) {
      if (t.thread == thread &&
          (t.status == TicketStatus.running ||
              t.status == TicketStatus.queued ||
              t.status == TicketStatus.stalled)) {
        return t;
      }
    }
    return null;
  }

  Future<SuperTicket> _createTicket(SuperTrigger t) async {
    final String id = 'ticket-${++_seq}';
    final SuperTicket ticket = SuperTicket(
      id: id,
      goal: t.text,
      source: t.source,
      thread: t.thread.isEmpty ? 'thread-${t.id}' : t.thread,
      priority: t.meta['priority'] is num
          ? (t.meta['priority'] as num).toInt().clamp(0, 9)
          : 5,
      mandate: Mandate(
        scope: 'source=${t.source};kind=${t.kind}（不可自我扩张）',
        maxSteps: defaultMaxSteps,
        deadlineSeconds: defaultDeadlineSeconds,
      ),
    );
    ticket.history.add('[目标·${t.source}] ${t.text}');
    ticket.subscriptions.add(t.id);
    ticket.workerSession = 'worker-$id';
    ticket.workDir = 'sandbox/super_agent/$id';
    _tickets[id] = ticket;
    await _persistTickets();
    _log('super.ticket.created', <String, dynamic>{
      'ticket': id,
      'source': t.source,
      'max_steps': ticket.mandate.maxSteps,
    });
    return ticket;
  }

  /// 快捷建任务：直接用目标文本建单，不经过 Trigger 注入与两级过滤。
  /// mandate 可选，缺省用默认策略；任何越界值按 clamp 收敛，绝不放大权限。
  Future<SuperTicket> _createTicketDirect({
    required String goal,
    required String source,
    required String thread,
    Map<String, dynamic>? mandate,
    int priority = 5,
    String? notBefore,
    List<String> riskHints = const <String>[],
    List<String> clarifications = const <String>[],
  }) async {
    final String id = 'ticket-${++_seq}';
    int maxSteps = defaultMaxSteps;
    int deadline = defaultDeadlineSeconds;
    String scope = 'source=$source;kind=direct（不可自我扩张）';
    List<String> allowedTools = const <String>['chat'];
    if (mandate != null) {
      if (mandate['max_steps'] is num) {
        maxSteps = (mandate['max_steps'] as num).toInt().clamp(1, 20);
      }
      if (mandate['deadline_seconds'] is num) {
        deadline = (mandate['deadline_seconds'] as num).toInt().clamp(1, 86400);
      }
      if ((mandate['scope'] ?? '').toString().isNotEmpty) {
        scope = '${mandate['scope']}（不可自我扩张）';
      }
      if (mandate['allowed_tools'] is List) {
        final List<String> tools = (mandate['allowed_tools'] as List)
            .map((dynamic e) => e.toString())
            .where((String s) => s.isNotEmpty)
            .toList();
        if (tools.isNotEmpty) allowedTools = tools;
      }
    }
    final SuperTicket ticket = SuperTicket(
      id: id,
      goal: goal,
      source: source,
      thread: thread.isEmpty ? 'direct-$id' : thread,
      priority: priority.clamp(0, 9),
      notBefore: notBefore,
      mandate: Mandate(
        scope: scope,
        maxSteps: maxSteps,
        deadlineSeconds: deadline,
        allowedTools: allowedTools,
      ),
    );
    ticket.history.add('[快捷建任务·$source] $goal');
    ticket.riskNotes.addAll(riskHints);
    ticket.clarifications.addAll(clarifications);
    ticket.workerSession = 'worker-$id';
    ticket.workDir = 'sandbox/super_agent/$id';
    _tickets[id] = ticket;
    await _persistTickets();
    _log('super.ticket.created_direct', <String, dynamic>{
      'ticket': id,
      'source': source,
      'max_steps': ticket.mandate.maxSteps,
    });
    return ticket;
  }

  // ---- Worker：隔离上下文、异步执行、真实推理、有限步 ----

  Future<void> _runWorker(String ticketId) async {
    final SuperTicket? ticket = _tickets[ticketId];
    if (ticket == null) return;
    if (_runningWorkers.contains(ticketId)) return;
    _runningWorkers.add(ticketId);
    ticket.status = TicketStatus.running;
    ticket.updatedAt = DateTime.now().toIso8601String();
    await _persistTickets();
    _log('super.worker.start', <String, dynamic>{'ticket': ticketId});

    String lastOutput = '';
    int repeated = 0;
    try {
      for (int step = 0; step < ticket.mandate.maxSteps; step++) {
        if (ticket.status == TicketStatus.stopped ||
            ticket.status == TicketStatus.paused) {
          break;
        }
        // Mandate 不可自我扩张：步数与方法都受签发范围约束。
        if (!ticket.mandate.allowedTools.contains('chat')) {
          ticket.watchdogNotes.add('Mandate 拒绝：chat 不在允许工具内');
          ticket.status = TicketStatus.failed;
          break;
        }
        final String prompt = await _workerPrompt(ticket, step);
        Map<String, dynamic> r;
        try {
          r = await chat(<String, dynamic>{
            'text': prompt,
            'session_id': ticket.workerSession,
          });
        } on Object catch (e) {
          ticket.watchdogNotes.add('推理异常：$e');
          ticket.status = TicketStatus.failed;
          break;
        }
        final String reply = (r['reply'] ?? r['error'] ?? '').toString();
        ticket.engine = (r['engine'] ?? '').toString();
        ticket.steps = step + 1;
        ticket.history.add('[step ${step + 1}·${ticket.engine}] $reply');
        ticket.result = reply;
        ticket.updatedAt = DateTime.now().toIso8601String();
        // 绑定角色 Agent 时，把本步结果写入其独立记忆（isolated 不串 Agent）。
        if (ticket.agentId.isNotEmpty) {
          try {
            await AgentMemory(store, ticket.agentId,
                    memoryScope: ticket.agentMemoryScope)
                .append('assistant', reply,
                    <String, dynamic>{'ticket': ticketId, 'step': step + 1});
          } on Object {
            // 记忆写入失败不改变工单交付，watchdog 记录可查。
            ticket.watchdogNotes.add('角色记忆写入失败（不影响本步结果）');
          }
        }
        // Inline/Spill：每步后把低频历史归档为摘要 + 事件引用，抑制上下文膨胀。
        _compactHistory(ticket);
        _log('super.worker.step', <String, dynamic>{
          'ticket': ticketId,
          'step': ticket.steps,
          'engine': ticket.engine,
          'inline_history': ticket.history.length,
          'spill_refs': ticket.spillRefs.length,
        });
        await _persistTickets();

        // Watchdog 输入：检测重复输出（无效循环的信号）。
        if (reply.trim().isNotEmpty && reply.trim() == lastOutput.trim()) {
          repeated += 1;
        } else {
          repeated = 0;
        }
        lastOutput = reply;
        if (repeated >= 1) {
          final bool recovered = await _watchdog(ticket, '重复输出');
          if (!recovered) break;
        }
      }
      // 阶段复盘检查点：长任务（≥2 步）收尾时自动做一次自检纠偏。
      // 复盘失败只记录，不影响已完成的交付；判定目标偏离才触发 Watchdog。
      if (autoReview &&
          ticket.status == TicketStatus.running &&
          ticket.steps >= 2) {
        await _reviewTicket(ticket, automatic: true);
      }
    } finally {
      if (ticket.status == TicketStatus.running) {
        // 内置兜底同样如实：engine 标注，不谎称真实模型自主完成。
        ticket.status = TicketStatus.done;
        ticket.updatedAt = DateTime.now().toIso8601String();
      }
      _runningWorkers.remove(ticketId);
      await _persistTickets();
      _log('super.worker.end', <String, dynamic>{
        'ticket': ticketId,
        'status': ticket.status.name,
        'steps': ticket.steps,
        'engine': ticket.engine,
      });
      await _drainQueue();
    }
  }

  /// Inline/Spill 分级存储：活跃历史留在会话内（Inline），低频历史压成
  /// 摘要并保留事件流引用（Spill）。摘要按条数截断，永远不会无限增长。
  void _compactHistory(SuperTicket t) {
    const int inlineLimit = 14;
    const int spillThreshold = 18;
    if (t.history.length <= spillThreshold) return;
    final int spillCount = t.history.length - inlineLimit;
    final List<String> spilled = t.history.sublist(0, spillCount);
    t.history.removeRange(0, spillCount);
    final StringBuffer buf = StringBuffer(t.contextSummary);
    for (final String line in spilled) {
      final String one = line.replaceAll('\n', ' ').trim();
      buf.writeln('· ${one.length > 180 ? '${one.substring(0, 180)}…' : one}');
    }
    String summary = buf.toString();
    if (summary.length > 4000) {
      summary = summary.substring(summary.length - 4000);
    }
    t.contextSummary = summary;
    _log('super.context.spill', <String, dynamic>{
      'ticket': t.id,
      'spilled': spilled.length,
      'inline': t.history.length,
    });
    // 引用刚落盘的事件序号，供按线索链回溯原始上下文。
    t.spillRefs.add(_seq);
    t.watchdogNotes.add(
        '上下文归档：${spilled.length} 条历史转入 Spill（ref #${t.spillRefs.last}）');
  }

  Future<String> _workerPrompt(SuperTicket t, int step) async {
    final StringBuffer b = StringBuffer();
    b.writeln('你是 Super Agent 的 Worker，处理一个隔离工单。');
    b.writeln('授权范围（Mandate，不可扩张）：${t.mandate.scope}，'
        '最多 ${t.mandate.maxSteps} 步，允许工具 ${t.mandate.allowedTools.join(",")}。');
    b.writeln('请针对目标给出本步真实的分析/处理结果；不要声称已完成未做的事。');
    if (t.role.trim().isNotEmpty) {
      b.writeln('角色设定：${t.role.trim()}（只在授权范围内行动，不得自行扩张权限）');
    }
    if (t.persona.isNotEmpty) {
      const Map<String, String> labels = <String, String>{
        'name': '姓名',
        'identity': '身份',
        'personality': '性格',
        'audience': '受众',
      };
      final List<String> parts = <String>[];
      labels.forEach((String key, String label) {
        final String v = (t.persona[key] ?? '').toString().trim();
        if (v.isNotEmpty) parts.add('$label=$v');
      });
      if (parts.isNotEmpty) b.writeln('人格设定：${parts.join('；')}');
    }
    if (t.agentId.isNotEmpty) {
      b.writeln('角色 Agent：${t.agentName.isEmpty ? t.agentId : t.agentName}'
          '（独立记忆作用域 ${t.agentMemoryScope}）');
      try {
        final AgentMemory memory = AgentMemory(store, t.agentId,
            memoryScope: t.agentMemoryScope);
        final List<Map<String, dynamic>> recent = await memory.recent(6);
        if (recent.isNotEmpty) {
          b.writeln('【该角色的独立记忆（最近 ${recent.length} 条）】');
          for (final Map<String, dynamic> e in recent) {
            final String text = (e['text'] ?? '').toString().trim();
            if (text.isEmpty) continue;
            b.writeln('- ${e['role']}: ${text.length > 240 ? '${text.substring(0, 240)}…' : text}');
          }
        }
      } on Object {
        b.writeln('（该角色记忆暂不可读，按无记忆继续）');
      }
    }
    if (t.riskNotes.isNotEmpty) {
      b.writeln('【风险提示】以下风险来自扫描或人工修订，执行时必须规避：');
      for (final String r in t.riskNotes.take(8)) {
        b.writeln('- $r');
      }
    }
    if (t.clarifications.isNotEmpty) {
      b.writeln('【澄清结论】以下条件已确认，不得再脑补假设：');
      for (final String c in t.clarifications.take(8)) {
        b.writeln('- $c');
      }
    }
    b.writeln('--- 工单上下文（独立 session ${t.workerSession}）---');
    if (t.contextSummary.trim().isNotEmpty) {
      final String s = t.contextSummary.trim();
      b.writeln('【已归档历史摘要 · Spill refs '
          '${t.spillRefs.isEmpty ? "-" : t.spillRefs.join(",")}】');
      b.writeln(s.length > 1600 ? s.substring(s.length - 1600) : s);
    }
    for (final String line in t.history.skip(
        t.history.length > 12 ? t.history.length - 12 : 0)) {
      b.writeln(line);
    }
    b.writeln('--- 第 ${step + 1} 步 ---');
    return b.toString();
  }

  /// 阶段复盘：读取目标与执行轨迹，检查是否偏离、是否遗漏约束、
  /// 是否有更优路径。要求模型输出严格 JSON；解析失败如实标记 unstructured。
  Future<Map<String, dynamic>> _reviewTicket(
    SuperTicket t, {
    bool automatic = false,
  }) async {
    final StringBuffer b = StringBuffer()
      ..writeln('你是 Super Agent 的阶段复盘器，只输出一个 JSON 对象，不要解释。')
      ..writeln('目标：${t.goal}')
      ..writeln('授权范围：${t.mandate.scope}')
      ..writeln('已执行 ${t.steps} 步，最近结果：${t.result}');
    if (t.contextSummary.trim().isNotEmpty) {
      b.writeln('历史摘要：${t.contextSummary.trim()}');
    }
    for (final String line in t.history.skip(
        t.history.length > 8 ? t.history.length - 8 : 0)) {
      b.writeln(line);
    }
    b.writeln('JSON 字段：goal_match(bool), drift(bool), constraint_violation(bool),'
        ' errors(string[]), better_path(string), confidence(0-1)。');
    Map<String, dynamic> r = <String, dynamic>{};
    try {
      r = await chat(<String, dynamic>{
        'text': b.toString(),
        'session_id': '${t.workerSession}-review',
      });
    } on Object catch (e) {
      r = <String, dynamic>{'ok': false, 'error': '$e'};
    }
    final String engine = (r['engine'] ?? '').toString();
    final String reply = (r['reply'] ?? r['error'] ?? '').toString();
    Map<String, dynamic> parsed = <String, dynamic>{};
    final RegExpMatch? m = RegExp(r'\{[\s\S]*\}').firstMatch(reply);
    if (m != null) {
      try {
        final dynamic decoded = jsonDecode(m.group(0)!);
        if (decoded is Map) {
          parsed = decoded.map(
              (dynamic k, dynamic v) => MapEntry(k.toString(), v));
        }
      } on Object {
        parsed = <String, dynamic>{};
      }
    }
    final bool structured = parsed.isNotEmpty;
    final bool drift = parsed['drift'] == true ||
        parsed['goal_match'] == false ||
        parsed['constraint_violation'] == true;
    final Map<String, dynamic> review = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'automatic': automatic,
      'engine': engine,
      'structured': structured,
      'verdict': structured ? (drift ? 'drift' : 'ok') : 'unstructured',
      'detail': parsed,
      'raw': reply.length > 1200 ? '${reply.substring(0, 1200)}…' : reply,
      'step': t.steps,
    };
    t.reviews.add(review);
    _log('super.ticket.review', <String, dynamic>{
      'ticket': t.id,
      'verdict': review['verdict'],
      'automatic': automatic,
    });
    if (structured && drift && !t.replanned) {
      await _watchdog(t, '阶段复盘判定目标偏离');
    }
    await _persistTickets();
    return <String, dynamic>{
      'ok': true,
      'review': review,
      'ticket_status': t.status.name,
      'replanned': t.replanned,
    };
  }

  /// Watchdog：判定 stalled，尝试一次 re-plan（真实追加跟进），否则如实失败。
  Future<bool> _watchdog(SuperTicket t, String reason) async {
    t.watchdogNotes.add('${DateTime.now().toIso8601String()} 触发：$reason');
    _log('super.watchdog', <String, dynamic>{'ticket': t.id, 'reason': reason});
    if (t.replanned) {
      t.status = TicketStatus.failed;
      t.watchdogNotes.add('已尝试 re-plan 仍无进展，如实标记 failed');
      return false;
    }
    t.replanned = true;
    t.status = TicketStatus.stalled;
    t.history.add('[Watchdog re-plan] 检测到$reason，请换一种思路重新分析目标，'
        '给出与上一轮不同的结果。');
    await _persistTickets();
    // 返回 true 让循环继续多跑一步（re-plan 是真实跟进，不是伪造恢复）。
    return true;
  }

  Future<void> _drainQueue() async {
    if (_runningWorkers.length >= maxWorkers) return;
    // 优先级协商：高优先级先跑；同优先级按创建时间先来先服务。
    // 延后（notBefore 未到）的工单保持 queued，不占用 Worker。
    final double now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final List<SuperTicket> queued = _tickets.values
        .where((SuperTicket t) =>
            t.status == TicketStatus.queued && !_runningWorkers.contains(t.id))
        .toList()
      ..sort((SuperTicket a, SuperTicket b) {
        final int byPriority = b.priority.compareTo(a.priority);
        if (byPriority != 0) return byPriority;
        return a.createdAt.compareTo(b.createdAt);
      });
    for (final SuperTicket t in queued) {
      final double? notBefore = DateTime.tryParse(t.notBefore ?? '')
          ?.millisecondsSinceEpoch
          .toDouble();
      if (notBefore != null && notBefore / 1000.0 > now) continue;
      unawaited(_runWorker(t.id));
      if (_runningWorkers.length >= maxWorkers) break;
    }
  }

  // ---- 控制域动作分发（super_agent）----

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    await init();
    switch (action) {
      case 'describe':
      case 'status':
        return <String, dynamic>{
          'ok': true,
          'initialized': _initialized,
          'observe': observe,
          'running_workers': _runningWorkers.length,
          'max_workers': maxWorkers,
          'queued': _tickets.values
              .where((SuperTicket t) => t.status == TicketStatus.queued)
              .length,
          'paused': _tickets.values
              .where((SuperTicket t) => t.status == TicketStatus.paused)
              .length,
          'auto_review': autoReview,
          'tickets': _tickets.length,
          'triggers': _triggers.length,
          'decisions': _decisions.length,
          'clarifications': _clarifications.length,
          'options': _options.length,
          'decision_log': _decisionLog.length,
          'events': _events.length,
          'router_context': _routerContext.length,
          'persist_errors': _persistErrors.length,
          'architecture': <String, dynamic>{
            'router': '常驻协调节点，维护跨源视图与准入决策',
            'worker': '每 Ticket 隔离上下文 + 独立工作目录，异步并行',
            'filter': '两级：程序规则 + 真实推理判断（缺模型如实降级）',
            'ticket': 'Mandate 不可扩张 + Subscription 按 thread 回原工单',
            'watchdog': '检测重复/超时/无进展，re-plan 一次后如实失败',
            'context': 'Inline/Spill 分级：活跃留在会话，低频归档为摘要 + 事件引用',
            'review': '长任务收尾阶段复盘，结构化判定偏离并触发纠偏',
            'priority': '工单优先级 0-9 可协商，队列按优先级 + 先来先服务调度',
            'cognition': '澄清/隐性目标/风险扫描/路线对比/决策日志的 L3 认知闭环',
            'storage': '存算分离：执行在内存，状态落 HarnessStore，可恢复',
          },
        };
      case 'sources':
        return <String, dynamic>{
          'ok': true,
          'sources': _sources.values.map((SourceState s) => s.toJson()).toList(),
        };
      case 'triggers':
        return <String, dynamic>{
          'ok': true,
          'triggers': _triggers.reversed
              .take(50)
              .map((SuperTrigger t) => t.toJson())
              .toList(),
        };
      case 'decisions':
        return <String, dynamic>{
          'ok': true,
          'decisions': _decisions.reversed
              .take(100)
              .map((FilterDecision d) => d.toJson())
              .toList(),
        };
      case 'tickets': {
        // 可选过滤：query 模糊匹配 id/goal/source/thread/status/engine；
        // status 精确匹配 TicketStatus.name。无过滤时返回全部（向后兼容）。
        final String query = (p['query'] ?? '').toString().trim().toLowerCase();
        final String statusFilter =
            (p['status'] ?? '').toString().trim().toLowerCase();
        final List<Map<String, dynamic>> all = _tickets.values
            .map((SuperTicket t) => t.toJson())
            .toList();
        final List<Map<String, dynamic>> filtered =
            all.where((Map<String, dynamic> t) {
          if (statusFilter.isNotEmpty &&
              (t['status'] ?? '').toString().toLowerCase() != statusFilter) {
            return false;
          }
          if (query.isEmpty) return true;
          return <String>[
            (t['id'] ?? '').toString(),
            (t['goal'] ?? '').toString(),
            (t['source'] ?? '').toString(),
            (t['thread'] ?? '').toString(),
            (t['status'] ?? '').toString(),
            (t['engine'] ?? '').toString(),
          ].any((String v) => v.toLowerCase().contains(query));
        }).toList();
        return <String, dynamic>{
          'ok': true,
          'tickets': filtered,
          'total': all.length,
          'filtered': filtered.length,
        };
      }
      case 'ticket':
        final SuperTicket? t = _tickets[(p['id'] ?? '').toString()];
        return t == null
            ? <String, dynamic>{'ok': false, 'error': '工单不存在'}
            : <String, dynamic>{'ok': true, 'ticket': t.toJson()};
      case 'create_direct': {
        // 用户主动快捷建任务：绕过 Trigger 注入与两级过滤，直接建单并入队执行。
        // 与 subagent 同语义，不检查 observe；返回真实 id 与真实状态。
        final String goal = (p['goal'] ?? '').toString().trim();
        if (goal.isEmpty) {
          return <String, dynamic>{'ok': false, 'error': '目标内容为空'};
        }
        final String source = (p['source'] ?? '').toString().trim();
        final String thread = (p['thread'] ?? '').toString().trim();
        final Map<String, dynamic>? mandate = p['mandate'] is Map
            ? Map<String, dynamic>.from(p['mandate'] as Map)
            : null;
        final int priority = p['priority'] is num
            ? (p['priority'] as num).toInt()
            : 5;
        final String? notBefore = (p['not_before'] ?? '').toString().trim().isEmpty
            ? null
            : (p['not_before']).toString();
        final SuperTicket directTicket = await _createTicketDirect(
          goal: goal,
          source: source.isEmpty ? 'manual' : source,
          thread: thread,
          mandate: mandate,
          priority: priority,
          notBefore: notBefore,
          riskHints: _stringList(p['risk_hints']),
          clarifications: _stringList(p['clarifications']),
        );
        await _drainQueue();
        return <String, dynamic>{
          'ok': true,
          'id': directTicket.id,
          'ticket': directTicket.toJson(),
        };
      }
      case 'retry': {
        final String id = (p['id'] ?? '').toString();
        final SuperTicket? retryTicket = _tickets[id];
        if (retryTicket == null) {
          return <String, dynamic>{'ok': false, 'error': '工单不存在'};
        }
        if (retryTicket.status != TicketStatus.failed &&
            retryTicket.status != TicketStatus.stalled &&
            retryTicket.status != TicketStatus.stopped) {
          return <String, dynamic>{
            'ok': false,
            'error':
                '仅 failed/stalled/stopped 工单可重试，当前状态 ${retryTicket.status.name}',
          };
        }
        final TicketStatus before = retryTicket.status;
        retryTicket.status = TicketStatus.queued;
        retryTicket.replanned = false;
        retryTicket.updatedAt = DateTime.now().toIso8601String();
        retryTicket.history.add('[人工重试] 由 ${before.name} 重置为 queued 重新入队');
        await _persistTickets();
        _log('super.ticket.retry', <String, dynamic>{
          'ticket': id,
          'from': before.name,
        });
        await _drainQueue();
        return <String, dynamic>{
          'ok': true,
          'id': id,
          'status': retryTicket.status.name,
          'ticket': retryTicket.toJson(),
        };
      }
      case 'batch_stop': {
        final dynamic idsRaw = p['ids'];
        if (idsRaw is! List) {
          return <String, dynamic>{'ok': false, 'error': 'ids 必须为列表'};
        }
        final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
        int succeeded = 0;
        int failed = 0;
        bool changed = false;
        for (final dynamic raw in idsRaw) {
          final String id = raw.toString();
          final SuperTicket? stopTicket = _tickets[id];
          if (stopTicket == null) {
            results.add(<String, dynamic>{
              'id': id,
              'ok': false,
              'error': '工单不存在',
            });
            failed += 1;
            continue;
          }
          stopTicket.status = TicketStatus.stopped;
          stopTicket.updatedAt = DateTime.now().toIso8601String();
          results.add(<String, dynamic>{
            'id': id,
            'ok': true,
            'status': stopTicket.status.name,
          });
          succeeded += 1;
          changed = true;
          _log('super.ticket.stop', <String, dynamic>{'ticket': id});
        }
        if (changed) await _persistTickets();
        return <String, dynamic>{
          'ok': true,
          'succeeded': succeeded,
          'failed': failed,
          'all_ok': failed == 0,
          'results': results,
        };
      }
      case 'events':
        return <String, dynamic>{
          'ok': true,
          'events': _events.reversed.take(200).toList(),
        };
      case 'router_context':
        return <String, dynamic>{
          'ok': true,
          'context': List<String>.of(_routerContext),
        };
      case 'inject':
        final String text = (p['text'] ?? '').toString().trim();
        if (text.isEmpty) {
          return <String, dynamic>{'ok': false, 'error': '事件内容为空'};
        }
        final String source = (p['source'] ?? 'manual').toString();
        final SuperTrigger t = SuperTrigger(
          id: 'trg-${++_seq}',
          source: source,
          kind: (p['kind'] ?? 'message').toString(),
          text: text,
          thread: (p['thread'] ?? '').toString(),
          author: (p['author'] ?? 'user').toString(),
          meta: p['meta'] is Map
              ? Map<String, dynamic>.from(p['meta'] as Map)
              : <String, dynamic>{},
        );
        return await ingest(t);
      case 'set_observe':
        observe = p['value'] == true;
        await _persistConfig();
        _log('super.config', <String, dynamic>{'observe': observe});
        return <String, dynamic>{'ok': true, 'observe': observe};
      case 'set_policy':
        if (p['max_workers'] is num) {
          maxWorkers = (p['max_workers'] as num).toInt().clamp(1, 16);
        }
        if (p['default_max_steps'] is num) {
          defaultMaxSteps = (p['default_max_steps'] as num).toInt().clamp(1, 20);
        }
        if (p['rules'] is Map) {
          _rules = Map<String, dynamic>.from(p['rules'] as Map);
        }
        if (p.containsKey('auto_review')) {
          autoReview = p['auto_review'] == true;
        }
        await _persistConfig();
        _log('super.config', <String, dynamic>{
          'max_workers': maxWorkers,
          'max_steps': defaultMaxSteps,
          'auto_review': autoReview,
        });
        return <String, dynamic>{
          'ok': true,
          'observe': observe,
          'max_workers': maxWorkers,
          'default_max_steps': defaultMaxSteps,
          'auto_review': autoReview,
          'rules': _rules,
        };
      case 'rules':
        return <String, dynamic>{'ok': true, 'rules': _rules};
      case 'queue': {
        // 队列协商视图：真实排队顺序、并发占用与影响预估。
        // 顺带触发一次调度，让延后到点的工单无需等新事件即可开始。
        await _drainQueue();
        final List<SuperTicket> queued = _tickets.values
            .where((SuperTicket t) => t.status == TicketStatus.queued)
            .toList()
          ..sort((SuperTicket a, SuperTicket b) {
            final int byPriority = b.priority.compareTo(a.priority);
            return byPriority != 0
                ? byPriority
                : a.createdAt.compareTo(b.createdAt);
          });
        return <String, dynamic>{
          'ok': true,
          'running': _runningWorkers.toList(),
          'capacity': maxWorkers,
          'queued': queued.asMap().entries.map((MapEntry<int, SuperTicket> e) {
            final double? nb =
                DateTime.tryParse(e.value.notBefore ?? '')?.millisecondsSinceEpoch
                    .toDouble();
            return <String, dynamic>{
              'id': e.value.id,
              'goal': e.value.goal,
              'priority': e.value.priority,
              'position': e.key + 1,
              'not_before': e.value.notBefore,
              'eligible': nb == null ||
                  nb / 1000.0 <=
                      DateTime.now().millisecondsSinceEpoch / 1000.0,
            };
          }).toList(),
        };
      }
      case 'set_priority': {
        final SuperTicket? t = _tickets[(p['id'] ?? '').toString()];
        if (t == null) {
          return <String, dynamic>{'ok': false, 'error': '工单不存在'};
        }
        if (p['priority'] is! num) {
          return <String, dynamic>{'ok': false, 'error': 'priority 必须为 0-9 的数字'};
        }
        final int before = t.priority;
        t.priority = (p['priority'] as num).toInt().clamp(0, 9);
        t.updatedAt = DateTime.now().toIso8601String();
        await _persistTickets();
        _log('super.ticket.priority', <String, dynamic>{
          'ticket': t.id,
          'before': before,
          'after': t.priority,
        });
        // 影响预估：排在该工单前面（更高优先级）的数量 + 当前并发占用。
        int ahead = 0;
        for (final SuperTicket other in _tickets.values) {
          if (other.id == t.id || other.status != TicketStatus.queued) continue;
          if (other.priority > t.priority ||
              (other.priority == t.priority &&
                  other.createdAt.compareTo(t.createdAt) < 0)) {
            ahead += 1;
          }
        }
        final String impact = t.status == TicketStatus.running
            ? '运行中的工单不改步数，仅影响后续调度'
            : (ahead + _runningWorkers.length >= maxWorkers
                ? '需等待前面 ${ahead} 个工单完成，当前并发 ${_runningWorkers.length}/$maxWorkers'
                : '预计下一轮调度即可开始（前方 $ahead 个，并发 '
                    '${_runningWorkers.length}/$maxWorkers）');
        await _drainQueue();
        return <String, dynamic>{
          'ok': true,
          'id': t.id,
          'priority': t.priority,
          'queue_position': ahead + 1,
          'impact': impact,
          'ticket': t.toJson(),
        };
      }
      case 'pause': {
        final SuperTicket? t = _tickets[(p['id'] ?? '').toString()];
        if (t == null) {
          return <String, dynamic>{'ok': false, 'error': '工单不存在'};
        }
        if (t.status == TicketStatus.done ||
            t.status == TicketStatus.failed ||
            t.status == TicketStatus.stopped) {
          return <String, dynamic>{
            'ok': false,
            'error': '已结束工单不可暂停（${t.status.name}）',
          };
        }
        t.status = TicketStatus.paused;
        t.updatedAt = DateTime.now().toIso8601String();
        t.history.add('[人工暂停] 工单暂停，可在任意时间恢复');
        await _persistTickets();
        _log('super.ticket.pause', <String, dynamic>{'ticket': t.id});
        return <String, dynamic>{'ok': true, 'id': t.id, 'status': t.status.name};
      }
      case 'resume': {
        final SuperTicket? t = _tickets[(p['id'] ?? '').toString()];
        if (t == null) {
          return <String, dynamic>{'ok': false, 'error': '工单不存在'};
        }
        if (t.status != TicketStatus.paused &&
            t.status != TicketStatus.stalled &&
            !(t.status == TicketStatus.queued && t.notBefore != null)) {
          return <String, dynamic>{
            'ok': false,
            'error': '仅 paused/stalled 或已延后的 queued 工单可恢复，当前 ${t.status.name}',
          };
        }
        t.status = TicketStatus.queued;
        t.notBefore = null;
        t.replanned = false;
        t.updatedAt = DateTime.now().toIso8601String();
        t.history.add('[人工恢复] 重新入队');
        await _persistTickets();
        _log('super.ticket.resume', <String, dynamic>{'ticket': t.id});
        await _drainQueue();
        return <String, dynamic>{'ok': true, 'id': t.id, 'status': t.status.name};
      }
      case 'defer': {
        final SuperTicket? t = _tickets[(p['id'] ?? '').toString()];
        if (t == null) {
          return <String, dynamic>{'ok': false, 'error': '工单不存在'};
        }
        if (t.status != TicketStatus.queued &&
            t.status != TicketStatus.paused &&
            t.status != TicketStatus.stalled) {
          return <String, dynamic>{
            'ok': false,
            'error': '仅 queued/paused/stalled 工单可延后，运行中请先暂停',
          };
        }
        final int seconds =
            (p['seconds'] is num) ? (p['seconds'] as num).toInt().clamp(0, 604800) : 3600;
        final DateTime at =
            DateTime.now().add(Duration(seconds: seconds));
        t.status = TicketStatus.queued;
        t.notBefore = at.toIso8601String();
        t.updatedAt = DateTime.now().toIso8601String();
        t.history.add('[人工延后] $seconds 秒后（$at）再调度');
        await _persistTickets();
        _log('super.ticket.defer', <String, dynamic>{
          'ticket': t.id,
          'seconds': seconds,
        });
        return <String, dynamic>{
          'ok': true,
          'id': t.id,
          'not_before': t.notBefore,
          'status': t.status.name,
        };
      }
      case 'context': {
        final String id = (p['id'] ?? '').toString();
        if (id.isNotEmpty) {
          final SuperTicket? t = _tickets[id];
          if (t == null) {
            return <String, dynamic>{'ok': false, 'error': '工单不存在'};
          }
          return <String, dynamic>{
            'ok': true,
            'ticket': id,
            'inline': t.history.length,
            'summary_chars': t.contextSummary.length,
            'spill_refs': t.spillRefs,
            'summary': t.contextSummary,
          };
        }
        int inline = 0;
        int spill = 0;
        for (final SuperTicket t in _tickets.values) {
          inline += t.history.length;
          spill += t.spillRefs.length;
        }
        return <String, dynamic>{
          'ok': true,
          'inline_total': inline,
          'spill_total': spill,
          'tickets': _tickets.length,
        };
      }
      case 'review': {
        final SuperTicket? t = _tickets[(p['id'] ?? '').toString()];
        if (t == null) {
          return <String, dynamic>{'ok': false, 'error': '工单不存在'};
        }
        return await _reviewTicket(t);
      }
      case 'reviews':
        return <String, dynamic>{
          'ok': true,
          'reviews': _tickets.values
              .expand((SuperTicket t) => t.reviews.map(
                  (Map<String, dynamic> r) => <String, dynamic>{'ticket': t.id, ...r}))
              .toList()
              .reversed
              .take(100)
              .toList(),
        };
      case 'clarify':
        return await _clarify(p);
      case 'implicit_goal':
        return await _implicitGoal(p);
      case 'risk_scan':
        return await _riskScan(p);
      case 'options':
        return await _optionsAction(p);
      case 'log_decision':
        return await _logDecision(p);
      case 'decision_log':
        return _decisionLogView(p);
      case 'revise':
        return await _revise(p);
      case 'watchdog':
        return await _scanWatchdog();
      case 'stop':
        final SuperTicket? t = _tickets[(p['id'] ?? '').toString()];
        if (t == null) {
          return <String, dynamic>{'ok': false, 'error': '工单不存在'};
        }
        t.status = TicketStatus.stopped;
        t.updatedAt = DateTime.now().toIso8601String();
        await _persistTickets();
        _log('super.ticket.stop', <String, dynamic>{'ticket': t.id});
        return <String, dynamic>{'ok': true, 'status': t.status.name};
      case 'attach':
        final SuperTicket? t = _tickets[(p['id'] ?? '').toString()];
        final String text = (p['text'] ?? '').toString().trim();
        if (t == null || text.isEmpty) {
          return <String, dynamic>{'ok': false, 'error': '工单不存在或跟进内容为空'};
        }
        t.history.add('[人工跟进] $text');
        t.updatedAt = DateTime.now().toIso8601String();
        await _persistTickets();
        return <String, dynamic>{'ok': true, 'history': t.history.length};
      case 'subagent':
        return await _spawnSubagent(
          (p['id'] ?? '').toString(),
          (p['goal'] ?? '').toString(),
          persona: p['persona'] is Map
              ? Map<String, dynamic>.from(p['persona'] as Map)
              : null,
          role: (p['role'] ?? '').toString(),
          agent: p['agent'] is Map
              ? Map<String, dynamic>.from(p['agent'] as Map)
              : null,
        );
      default:
        return <String, dynamic>{'ok': false, 'error': '未知 Super Agent 动作：$action'};
    }
  }

  /// 独立 Watchdog 扫描：超时 / stalled / 无进展。
  Future<Map<String, dynamic>> _scanWatchdog() async {
    final List<String> flagged = <String>[];
    final double now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    for (final SuperTicket t in _tickets.values) {
      if (t.status != TicketStatus.running && t.status != TicketStatus.stalled) {
        continue;
      }
      final double created = DateTime.tryParse(t.createdAt)?.millisecondsSinceEpoch
              .toDouble() ??
          0;
      final bool timedOut = created > 0 &&
          (now - created / 1000.0) > t.mandate.deadlineSeconds;
      if (timedOut && !t.replanned) {
        await _watchdog(t, '超过 Mandate 时限 ${t.mandate.deadlineSeconds}s');
        flagged.add(t.id);
      } else if (timedOut) {
        t.status = TicketStatus.failed;
        t.watchdogNotes.add('超过时限且已 re-plan，如实标记 failed');
        flagged.add(t.id);
      }
    }
    await _persistTickets();
    return <String, dynamic>{'ok': true, 'flagged': flagged};
  }

  /// Subagent：Worker 派生独立子工单，共享 Router、隔离 session。
  /// persona/role 只用于 Worker prompt 的角色表达；Mandate 仍沿用父级，不可扩张。
  Future<Map<String, dynamic>> _spawnSubagent(
    String parentId,
    String goal, {
    Map<String, dynamic>? persona,
    String role = '',
    Map<String, dynamic>? agent,
  }) async {
    final SuperTicket? parent = _tickets[parentId];
    if (parent == null) {
      return <String, dynamic>{'ok': false, 'error': '父工单不存在'};
    }
    if (goal.trim().isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '子任务目标为空'};
    }
    final String agentId = (agent?['id'] ?? '').toString().trim();
    if (agentId.isNotEmpty && agent?['executionEnabled'] != true) {
      return <String, dynamic>{
        'ok': false,
        'error': '该角色 Agent 未开启独立执行（executionEnabled=false）',
      };
    }
    // Mandate 不可自我扩张：子工单沿用父授权范围或更窄，绝不放宽。
    final String id = 'ticket-${++_seq}';
    final SuperTicket child = SuperTicket(
      id: id,
      goal: goal,
      source: parent.source,
      thread: parent.thread,
      parentId: parentId,
      priority: parent.priority,
      mandate: Mandate(
        scope: '${parent.mandate.scope} / subagent（沿用不扩张）',
        maxSteps: parent.mandate.maxSteps > 1 ? parent.mandate.maxSteps - 1 : 1,
        deadlineSeconds: parent.mandate.deadlineSeconds,
        allowedTools: parent.mandate.allowedTools,
      ),
    );
    child.persona.addAll(_sanitizePersona(persona));
    child.role = role.trim();
    if (agentId.isNotEmpty) {
      child.agentId = agentId;
      child.agentName = (agent?['name'] ?? '').toString();
      child.agentMemoryScope =
          (agent?['memoryScope'] ?? 'isolated').toString() == 'shared'
              ? 'shared'
              : 'isolated';
      if (child.role.isEmpty) {
        child.role = (agent?['role'] ?? '').toString();
      }
    }
    // 风险与澄清结论随父工单继承，避免子任务在同样风险上重复踩坑。
    child.riskNotes.addAll(parent.riskNotes);
    child.clarifications.addAll(parent.clarifications);
    child.workerSession = 'worker-$id';
    child.workDir = 'sandbox/super_agent/$id';
    child.history.add('[子任务·由 $parentId 派生] $goal');
    if (child.role.isNotEmpty) {
      child.history.add('[角色] ${child.role}');
    }
    _tickets[id] = child;
    await _persistTickets();
    _log('super.subagent.spawn', <String, dynamic>{
      'parent': parentId,
      'child': id,
      'role': child.role,
      'persona_keys': child.persona.keys.toList(),
    });
    unawaited(_runWorker(id));
    return <String, dynamic>{'ok': true, 'ticket': child.toJson()};
  }
}
