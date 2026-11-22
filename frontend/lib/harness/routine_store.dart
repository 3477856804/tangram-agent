/// Routine 持久化仓储：纯 Dart，真实落盘到 App 私有目录，不依赖 Flutter。
///
/// 产品语义对照 Rakazo `packages/contracts/src/routines/routine.ts`：
///   * 一条 Routine 有多条 cron 时间表、时区、启用状态、通知开关、模型固定；
///   * `next_run_at` 由仓储按真实 cron + 时区计算，不由 UI 猜；
///   * 每次执行写一条 Run 记录（状态 / 开始 / 结束 / 迟到 / 错误 / 结果摘要）；
///   * 一次性 Routine（`@once`）必须显式给出运行时刻，执行后自动停用。
///
/// 存储布局：
///   `routines/routines.json` —— `{"routines": [...]}`
///   `routines/runs.json`     —— `{"runs": [...]}`（最多 [maxRuns] 条）
/// 所有写操作串行执行，先写 `.tmp` 再原子改名，避免半个 JSON。
///
/// 本批次只实现「时间表触发 + 手动触发」；webhook / 邮件 / GitHub / 变更
/// 触发字段保留在记录里，但未接通前不允许作为唯一触发条件，避免假能力。
///
/// 失败重试与崩溃对账（对照 Rakazo 的运行模型）：一次运行失败后记录保留
/// attempts 与 nextAttemptAt，由调度器到点重跑，最多 3 次；进程被杀时
/// 残留的 running 记录在下次启动时由 reconcileStaleRuns 改为失败并安排
/// 重试，绝不静默丢弃。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'routine_schedule.dart';

/// 名称上限与 Rakazo 一致。
const int routineNameMaxLength = 80;

/// 一次 Routine 运行记录。
///
/// 失败重试（对照 Rakazo 的运行模型「先执行、失败则由持久化备份任务兜底」）：
/// 一次运行失败后不会静默消失——记录保留 `attempts`（已失败次数）与
/// `nextAttemptAt`（下次重试时刻，指数退避 60s / 300s / 900s，最多 3 次），
/// 调度器到点重跑；进程被杀时残留的 `running` 记录由
/// `reconcileStaleRuns` 在下次启动时改为失败并安排重试，而不是丢弃。
class RoutineRunRecord {
  const RoutineRunRecord({
    required this.id,
    required this.routineId,
    required this.trigger,
    required this.status,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
    this.lateSince,
    this.error = '',
    this.result = '',
    this.attempts = 0,
    this.nextAttemptAt,
  });

  final String id;
  final String routineId;
  final String trigger;
  final String status;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? lateSince;
  final String error;
  final String result;

  /// 已失败次数（成功为 0）。达到 [RoutineStore.maxRetries] 后不再重试。
  final int attempts;

  /// 下次重试时刻；为 null 表示不重试（成功、或已达最大重试次数）。
  final DateTime? nextAttemptAt;

  /// 失败后是否还应重试（attempts 记失败次数：首跑失败为 1，
  /// 第 3 次重试失败为 4，此时不再重试）。
  bool get retryDue =>
      status == 'failure' &&
      attempts <= RoutineStore.maxRetries &&
      nextAttemptAt != null;

  int? get durationMs => startedAt == null || completedAt == null
      ? null
      : completedAt!.difference(startedAt!).inMilliseconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'routine_id': routineId,
    'trigger': trigger,
    'status': status,
    'created_at': createdAt.toIso8601String(),
    'started_at': startedAt?.toIso8601String(),
    'completed_at': completedAt?.toIso8601String(),
    'late_since': lateSince?.toIso8601String(),
    'error': error,
    'result': result,
    'attempts': attempts,
    'next_attempt_at': nextAttemptAt?.toIso8601String(),
  };

  static RoutineRunRecord? tryParse(Map<String, dynamic> raw) {
    final String id = (raw['id'] ?? '').toString().trim();
    final String routineId = (raw['routine_id'] ?? '').toString().trim();
    if (id.isEmpty || routineId.isEmpty) return null;
    final DateTime? created = DateTime.tryParse('${raw['created_at']}');
    if (created == null) return null;
    final String status = (raw['status'] ?? '').toString();
    if (!const <String>[
      'queued',
      'running',
      'success',
      'failure',
      'skipped',
    ].contains(status)) {
      return null;
    }
    return RoutineRunRecord(
      id: id,
      routineId: routineId,
      trigger: (raw['trigger'] ?? 'schedule').toString(),
      status: status,
      createdAt: created,
      startedAt: DateTime.tryParse('${raw['started_at']}'),
      completedAt: DateTime.tryParse('${raw['completed_at']}'),
      lateSince: DateTime.tryParse('${raw['late_since']}'),
      error: (raw['error'] ?? '').toString(),
      result: (raw['result'] ?? '').toString(),
      // 旧记录没有这两个字段时默认 0 / null，不影响历史读取。
      attempts: raw['attempts'] is num
          ? (raw['attempts'] as num).toInt()
          : int.tryParse('${raw['attempts']}') ?? 0,
      nextAttemptAt: DateTime.tryParse('${raw['next_attempt_at']}'),
    );
  }
}

/// 一条 Routine。
class RoutineRecord {
  const RoutineRecord({
    required this.id,
    required this.name,
    required this.prompt,
    required this.crons,
    required this.timezone,
    required this.active,
    required this.notify,
    required this.inChat,
    required this.webhookEnabled,
    required this.githubEnabled,
    required this.messageProvider,
    required this.emailSenders,
    required this.modelProvider,
    required this.modelId,
    required this.thinkingLevel,
    required this.createdAt,
    required this.updatedAt,
    this.anchorAt,
    this.lastRunAt,
    this.nextRunAt,
  });

  final String id;
  final String name;
  final String prompt;
  final List<String> crons;
  final String timezone;
  final bool active;
  final bool notify;
  final bool inChat;
  final bool webhookEnabled;
  final bool githubEnabled;
  final String? messageProvider;
  final String? emailSenders;
  final String? modelProvider;
  final String? modelId;
  final String? thinkingLevel;

  /// 间隔相位锚点：非整除步长从这次计划触发开始递推。
  final DateTime? anchorAt;
  final DateTime? lastRunAt;
  final DateTime? nextRunAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get oneShot => isOneShotCrons(crons);

  RoutineRecord copyWith({
    String? name,
    String? prompt,
    List<String>? crons,
    String? timezone,
    bool? active,
    bool? notify,
    bool? inChat,
    bool? webhookEnabled,
    bool? githubEnabled,
    String? messageProvider,
    bool? clearMessageProvider,
    String? emailSenders,
    bool? clearEmailSenders,
    String? modelProvider,
    bool? clearModelProvider,
    String? modelId,
    bool? clearModelId,
    String? thinkingLevel,
    bool? clearThinkingLevel,
    DateTime? anchorAt,
    bool? clearAnchor,
    DateTime? lastRunAt,
    DateTime? nextRunAt,
    bool? clearNextRun,
    DateTime? updatedAt,
  }) {
    return RoutineRecord(
      id: id,
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      crons: crons ?? this.crons,
      timezone: timezone ?? this.timezone,
      active: active ?? this.active,
      notify: notify ?? this.notify,
      inChat: inChat ?? this.inChat,
      webhookEnabled: webhookEnabled ?? this.webhookEnabled,
      githubEnabled: githubEnabled ?? this.githubEnabled,
      messageProvider: clearMessageProvider == true
          ? null
          : (messageProvider ?? this.messageProvider),
      emailSenders: clearEmailSenders == true
          ? null
          : (emailSenders ?? this.emailSenders),
      modelProvider: clearModelProvider == true
          ? null
          : (modelProvider ?? this.modelProvider),
      modelId: clearModelId == true ? null : (modelId ?? this.modelId),
      thinkingLevel: clearThinkingLevel == true
          ? null
          : (thinkingLevel ?? this.thinkingLevel),
      anchorAt: clearAnchor == true ? null : (anchorAt ?? this.anchorAt),
      lastRunAt: lastRunAt ?? this.lastRunAt,
      nextRunAt: clearNextRun == true ? null : (nextRunAt ?? this.nextRunAt),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'prompt': prompt,
    'crons': crons,
    'timezone': timezone,
    'active': active,
    'notify': notify,
    'in_chat': inChat,
    'webhook_enabled': webhookEnabled,
    'github_enabled': githubEnabled,
    'message_provider': messageProvider,
    'email_senders': emailSenders,
    'model_provider': modelProvider,
    'model_id': modelId,
    'thinking_level': thinkingLevel,
    'anchor_at': anchorAt?.toIso8601String(),
    'last_run_at': lastRunAt?.toIso8601String(),
    'next_run_at': nextRunAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  static RoutineRecord? tryParse(Map<String, dynamic> raw) {
    final String id = (raw['id'] ?? '').toString().trim();
    final String name = (raw['name'] ?? '').toString().trim();
    final String prompt = (raw['prompt'] ?? '').toString().trim();
    if (id.isEmpty || name.isEmpty || prompt.isEmpty) return null;
    final List<String> crons = raw['crons'] is List
        ? (raw['crons'] as List)
              .map((dynamic e) => e.toString().trim())
              .where((String e) => e.isNotEmpty)
              .toList()
        : <String>[];
    if (crons.isEmpty) return null;
    final DateTime? created = DateTime.tryParse('${raw['created_at']}');
    final DateTime? updated = DateTime.tryParse('${raw['updated_at']}');
    if (created == null || updated == null) return null;
    return RoutineRecord(
      id: id,
      name: name,
      prompt: prompt,
      crons: crons,
      timezone: (raw['timezone'] ?? 'local').toString(),
      active: raw['active'] == true,
      notify: raw['notify'] != false,
      inChat: raw['in_chat'] == true,
      webhookEnabled: raw['webhook_enabled'] == true,
      githubEnabled: raw['github_enabled'] == true,
      messageProvider: _nullable(raw['message_provider']),
      emailSenders: _nullable(raw['email_senders']),
      modelProvider: _nullable(raw['model_provider']),
      modelId: _nullable(raw['model_id']),
      thinkingLevel: _nullable(raw['thinking_level']),
      anchorAt: DateTime.tryParse('${raw['anchor_at']}'),
      lastRunAt: DateTime.tryParse('${raw['last_run_at']}'),
      nextRunAt: DateTime.tryParse('${raw['next_run_at']}'),
      createdAt: created,
      updatedAt: updated,
    );
  }

  static String? _nullable(dynamic value) {
    if (value == null) return null;
    final String text = value.toString().trim();
    return text.isEmpty ? null : text;
  }
}

/// Routine 仓储。
class RoutineStore {
  RoutineStore(this.root);

  final Directory root;

  /// 全局最多保留的运行记录条数。
  static const int maxRuns = 500;

  /// 失败重试的最大次数（与 TaskRetryPolicy 的 3 次一致）。
  static const int maxRetries = 3;

  /// 第 1/2/3 次失败后的等待秒数（与 TaskRetryPolicy.backoffSeconds 一致，
  /// 此处单独定义以免 harness 层反向依赖 services 层造成循环引用）。
  static const List<int> retryBackoffSeconds = <int>[60, 300, 900];

  /// 第 [attempts] 次失败（从 1 开始）后的下次重试时刻；
  /// attempts 已达上限时返回 null，表示不再重试。
  static DateTime? nextRetryAt(int attempts, DateTime now) {
    if (attempts < 1 || attempts > retryBackoffSeconds.length) return null;
    return now.add(Duration(seconds: retryBackoffSeconds[attempts - 1]));
  }

  Future<void> _tail = Future<void>.value();

  Directory get _dir => Directory('${root.path}/routines');
  File get _indexFile => File('${_dir.path}/routines.json');
  File get _runsFile => File('${_dir.path}/runs.json');

  /// 所有写操作串行执行，避免并发创建/推进 next_run 时互相覆盖。
  Future<T> _guard<T>(Future<T> Function() work) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await work());
      } on Object catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  String _newId(String prefix) {
    final int now = DateTime.now().microsecondsSinceEpoch;
    final int salt = Random.secure().nextInt(1 << 32);
    return '$prefix-${now.toRadixString(36)}-${salt.toRadixString(36)}';
  }

  Future<List<RoutineRecord>> _readIndex() async {
    if (!await _indexFile.exists()) return <RoutineRecord>[];
    try {
      final dynamic decoded = jsonDecode(await _indexFile.readAsString());
      if (decoded is Map && decoded['routines'] is List) {
        final List<RoutineRecord> out = <RoutineRecord>[];
        for (final dynamic item in decoded['routines'] as List) {
          if (item is! Map) continue;
          final RoutineRecord? record = RoutineRecord.tryParse(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          );
          if (record != null) out.add(record);
        }
        return out;
      }
    } on Object {
      // 损坏的索引不冒充数据；list 会返回空并标记损坏。
    }
    throw const FormatException('routines.json 无法解析');
  }

  Future<void> _writeIndex(List<RoutineRecord> routines) async {
    if (!await _dir.exists()) await _dir.create(recursive: true);
    await _writeJson(_indexFile, <String, dynamic>{
      'routines': routines.map((RoutineRecord r) => r.toJson()).toList(),
    });
  }

  Future<List<RoutineRunRecord>> _readRuns() async {
    if (!await _runsFile.exists()) return <RoutineRunRecord>[];
    try {
      final dynamic decoded = jsonDecode(await _runsFile.readAsString());
      if (decoded is Map && decoded['runs'] is List) {
        final List<RoutineRunRecord> out = <RoutineRunRecord>[];
        for (final dynamic item in decoded['runs'] as List) {
          if (item is! Map) continue;
          final RoutineRunRecord? record = RoutineRunRecord.tryParse(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          );
          if (record != null) out.add(record);
        }
        return out;
      }
    } on Object {
      // 运行历史损坏时保持空态，不影响 Routine 本身。
    }
    return <RoutineRunRecord>[];
  }

  Future<void> _writeRuns(List<RoutineRunRecord> runs) async {
    if (!await _dir.exists()) await _dir.create(recursive: true);
    final List<RoutineRunRecord> trimmed = runs.length > maxRuns
        ? runs.sublist(runs.length - maxRuns)
        : runs;
    await _writeJson(_runsFile, <String, dynamic>{
      'runs': trimmed.map((RoutineRunRecord r) => r.toJson()).toList(),
    });
  }

  Future<void> _writeJson(File file, Object? value) async {
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(file.path);
  }

  // ---------------------------------------------------------------- 校验

  /// 校验一组 cron + 时区；返回 null 表示合法，否则返回中文错误。
  static String? validateSchedule(List<String> crons, String timezone) {
    if (crons.isEmpty) return '至少设置一个时间表';
    if (hasMixedOneShotSchedule(crons)) {
      return '一次性时间表不能和其它时间表同时使用';
    }
    if (!RoutineZone.isSupported(timezone)) {
      return '暂不支持该时区：$timezone';
    }
    for (final String cron in crons) {
      if (isOneShotCron(cron)) continue;
      try {
        CronExpression.parse(cron);
      } on FormatException catch (e) {
        return '时间表无效（$cron）：${e.message}';
      }
    }
    return null;
  }

  static List<String> normalizeCrons(List<dynamic> raw) {
    final List<String> out = <String>[];
    for (final dynamic item in raw) {
      final String cron = item.toString().trim();
      if (cron.isEmpty || out.contains(cron)) continue;
      out.add(cron);
    }
    return out;
  }

  // ---------------------------------------------------------------- 查询

  /// 列表；`activeOnly` 只返回启用中的 Routine。
  Future<Map<String, dynamic>> list({
    String query = '',
    bool activeOnly = false,
  }) async {
    try {
      final List<RoutineRecord> all = await _readIndex();
      final String q = query.trim().toLowerCase();
      final List<RoutineRecord> matched = all.where((RoutineRecord r) {
        if (activeOnly && !r.active) return false;
        if (q.isEmpty) return true;
        return r.name.toLowerCase().contains(q) ||
            r.prompt.toLowerCase().contains(q);
      }).toList();
      matched.sort((RoutineRecord a, RoutineRecord b) {
        if (a.active != b.active) return a.active ? -1 : 1;
        final DateTime? an = a.nextRunAt;
        final DateTime? bn = b.nextRunAt;
        if (an != null && bn != null && an != bn) return an.compareTo(bn);
        if (an != null) return -1;
        if (bn != null) return 1;
        return a.createdAt.compareTo(b.createdAt);
      });
      return <String, dynamic>{
        'ok': true,
        'routines': matched.map((RoutineRecord r) => r.toJson()).toList(),
        'skipped': all.length - matched.length,
      };
    } on Object catch (e) {
      return _err('读取 Routine 失败：$e');
    }
  }

  Future<Map<String, dynamic>> get(String id) async {
    try {
      final List<RoutineRecord> all = await _readIndex();
      final List<RoutineRecord> foundList =
          all.where((RoutineRecord r) => r.id == id).toList();
      final RoutineRecord? found =
          foundList.isEmpty ? null : foundList.first;
      if (found == null) return _err('Routine 不存在：$id');
      return <String, dynamic>{'ok': true, 'routine': found.toJson()};
    } on Object catch (e) {
      return _err('读取 Routine 失败：$e');
    }
  }

  /// 到点且启用中的 Routine。
  Future<Map<String, dynamic>> due({DateTime? now}) async {
    try {
      final DateTime at = (now ?? DateTime.now()).toUtc();
      final List<RoutineRecord> all = await _readIndex();
      final List<RoutineRecord> due = all
          .where(
            (RoutineRecord r) =>
                r.active &&
                r.nextRunAt != null &&
                !r.nextRunAt!.isAfter(at),
          )
          .toList();
      return <String, dynamic>{
        'ok': true,
        'due': due.map((RoutineRecord r) => r.toJson()).toList(),
      };
    } on Object catch (e) {
      return _err('读取到期 Routine 失败：$e');
    }
  }

  // ---------------------------------------------------------------- 写入

  /// 创建 Routine。`oneShotAt` 仅用于 `@once`。
  Future<Map<String, dynamic>> create({
    required String name,
    required String prompt,
    required List<String> crons,
    String timezone = 'local',
    bool active = true,
    bool notify = true,
    bool inChat = false,
    String? modelProvider,
    String? modelId,
    String? thinkingLevel,
    DateTime? oneShotAt,
  }) async {
    return _guard(() async {
      final String n = name.trim();
      final String p = prompt.trim();
      if (n.isEmpty) return _err('请填写 Routine 名称');
      if (n.length > routineNameMaxLength) {
        return _err('名称不能超过 $routineNameMaxLength 个字符');
      }
      if (p.isEmpty) return _err('请填写提示词');
      final List<String> normalized = normalizeCrons(crons);
      final String? invalid = validateSchedule(normalized, timezone);
      if (invalid != null) return _err(invalid);
      final DateTime now = DateTime.now().toUtc();
      DateTime? next;
      DateTime? anchor;
      if (isOneShotCrons(normalized)) {
        if (oneShotAt == null) return _err('一次性 Routine 必须指定运行时刻');
        final DateTime at = oneShotAt.toUtc();
        if (!at.isAfter(now)) return _err('一次性 Routine 的运行时刻必须晚于当前时间');
        next = active ? at : null;
        if (active) anchor = at;
      } else if (active) {
        try {
          final RoutineZone zone = RoutineZone.parse(timezone);
          anchor = nextCronDateAcrossStrict(normalized, now, zone);
          next = nextRoutineRunDateAcross(normalized, anchor!, now, zone);
        } on FormatException catch (e) {
          return _err(e.message);
        }
        if (next == null) return _err('时间表没有未来的触发时间');
      }
      final RoutineRecord record = RoutineRecord(
        id: _newId('routine'),
        name: n,
        prompt: p,
        crons: normalized,
        timezone: timezone,
        active: active,
        notify: notify,
        inChat: inChat,
        webhookEnabled: false,
        githubEnabled: false,
        messageProvider: null,
        emailSenders: null,
        modelProvider: modelProvider,
        modelId: modelId,
        thinkingLevel: thinkingLevel,
        anchorAt: anchor,
        lastRunAt: null,
        nextRunAt: next,
        createdAt: now,
        updatedAt: now,
      );
      final List<RoutineRecord> all = await _readIndex();
      all.add(record);
      await _writeIndex(all);
      return <String, dynamic>{'ok': true, 'routine': record.toJson()};
    }).catchError((Object e) => _err('创建 Routine 失败：$e'));
  }

  /// 更新 Routine；时间表 / 时区 / 启用状态变化时重算下次运行。
  Future<Map<String, dynamic>> update(
    String id, {
    String? name,
    String? prompt,
    List<String>? crons,
    String? timezone,
    bool? active,
    bool? notify,
    bool? inChat,
    String? modelProvider,
    bool clearModelProvider = false,
    String? modelId,
    bool clearModelId = false,
    String? thinkingLevel,
    bool clearThinkingLevel = false,
    DateTime? oneShotAt,
  }) async {
    return _guard(() async {
      final List<RoutineRecord> all = await _readIndex();
      final int index =
          all.indexWhere((RoutineRecord r) => r.id == id);
      if (index < 0) return _err('Routine 不存在：$id');
      final RoutineRecord current = all[index];
      final String n = name == null ? current.name : name.trim();
      final String p = prompt == null ? current.prompt : prompt.trim();
      if (n.isEmpty) return _err('请填写 Routine 名称');
      if (n.length > routineNameMaxLength) {
        return _err('名称不能超过 $routineNameMaxLength 个字符');
      }
      if (p.isEmpty) return _err('请填写提示词');
      final List<String> nextCrons =
          crons == null ? current.crons : normalizeCrons(crons);
      final String zoneName = timezone ?? current.timezone;
      final bool nextActive = active ?? current.active;
      final String? invalid = validateSchedule(nextCrons, zoneName);
      if (invalid != null) return _err(invalid);

      final DateTime now = DateTime.now().toUtc();
      final bool scheduleChanged =
          crons != null ||
          (timezone != null && timezone != current.timezone) ||
          (active != null && active != current.active);

      DateTime? anchor = current.anchorAt;
      DateTime? next = current.nextRunAt;
      if (scheduleChanged) {
        if (!nextActive) {
          next = null;
          anchor = null;
        } else if (isOneShotCrons(nextCrons)) {
          final DateTime? at =
              oneShotAt?.toUtc() ?? current.nextRunAt ?? current.anchorAt;
          if (at == null) return _err('一次性 Routine 必须指定运行时刻');
          if (!at.isAfter(now)) return _err('一次性 Routine 的运行时刻必须晚于当前时间');
          next = at;
          anchor = at;
        } else {
          try {
            final RoutineZone zone = RoutineZone.parse(zoneName);
            anchor = nextCronDateAcrossStrict(nextCrons, now, zone);
            next = nextRoutineRunDateAcross(nextCrons, anchor!, now, zone);
          } on FormatException catch (e) {
            return _err(e.message);
          }
          if (next == null) return _err('时间表没有未来的触发时间');
        }
      }

      final RoutineRecord updated = current.copyWith(
        name: n,
        prompt: p,
        crons: nextCrons,
        timezone: zoneName,
        active: nextActive,
        notify: notify,
        inChat: inChat,
        modelProvider: modelProvider,
        clearModelProvider: clearModelProvider,
        modelId: modelId,
        clearModelId: clearModelId,
        thinkingLevel: thinkingLevel,
        clearThinkingLevel: clearThinkingLevel,
        anchorAt: anchor,
        clearAnchor: anchor == null,
        nextRunAt: next,
        clearNextRun: next == null,
        updatedAt: now,
      );
      all[index] = updated;
      await _writeIndex(all);
      return <String, dynamic>{'ok': true, 'routine': updated.toJson()};
    }).catchError((Object e) => _err('更新 Routine 失败：$e'));
  }

  Future<Map<String, dynamic>> setActive(String id, bool active) =>
      update(id, active: active);

  Future<Map<String, dynamic>> delete(String id) async {
    return _guard(() async {
      final List<RoutineRecord> all = await _readIndex();
      final int before = all.length;
      all.removeWhere((RoutineRecord r) => r.id == id);
      if (all.length == before) return _err('Routine 不存在：$id');
      await _writeIndex(all);
      final List<RoutineRunRecord> runs = await _readRuns();
      runs.removeWhere((RoutineRunRecord r) => r.routineId == id);
      await _writeRuns(runs);
      return <String, dynamic>{'ok': true, 'deleted': id};
    }).catchError((Object e) => _err('删除 Routine 失败：$e'));
  }

  /// 复制为暂停状态，避免与原 Routine 同时运行；一次性 Routine 不支持复制。
  Future<Map<String, dynamic>> duplicate(String id, {String? name}) async {
    return _guard(() async {
      final List<RoutineRecord> all = await _readIndex();
      final List<RoutineRecord> sourceList =
          all.where((RoutineRecord r) => r.id == id).toList();
      final RoutineRecord? source =
          sourceList.isEmpty ? null : sourceList.first;
      if (source == null) return _err('Routine 不存在：$id');
      if (source.oneShot) return _err('一次性 Routine 不支持复制');
      final String copyName = (name ?? '${source.name} 副本').trim();
      final DateTime now = DateTime.now().toUtc();
      final RoutineRecord copy = RoutineRecord(
        id: _newId('routine'),
        name: copyName.length > routineNameMaxLength
            ? copyName.substring(0, routineNameMaxLength)
            : copyName,
        prompt: source.prompt,
        crons: List<String>.of(source.crons),
        timezone: source.timezone,
        active: false,
        notify: source.notify,
        inChat: source.inChat,
        webhookEnabled: false,
        githubEnabled: false,
        messageProvider: null,
        emailSenders: null,
        modelProvider: source.modelProvider,
        modelId: source.modelId,
        thinkingLevel: source.thinkingLevel,
        anchorAt: null,
        lastRunAt: null,
        nextRunAt: null,
        createdAt: now,
        updatedAt: now,
      );
      all.add(copy);
      await _writeIndex(all);
      return <String, dynamic>{'ok': true, 'routine': copy.toJson()};
    }).catchError((Object e) => _err('复制 Routine 失败：$e'));
  }

  // ---------------------------------------------------------------- 运行记录

  /// 开始一次运行：推进 last/next，写入 running 记录。
  ///
  /// 对一次性 Routine，开始即停用（即使最终失败，也不会再次误触发）。
  Future<Map<String, dynamic>> startRun(
    String id, {
    String trigger = 'schedule',
    DateTime? now,
  }) async {
    return _guard(() async {
      final List<RoutineRecord> all = await _readIndex();
      final int index = all.indexWhere((RoutineRecord r) => r.id == id);
      if (index < 0) return _err('Routine 不存在：$id');
      final RoutineRecord routine = all[index];
      final DateTime started = (now ?? DateTime.now()).toUtc();
      final DateTime? lateSince = routine.nextRunAt;
      DateTime? next = routine.nextRunAt;
      DateTime? anchor = routine.anchorAt;
      bool active = routine.active;
      // 手动运行暂停中的 Routine 只执行一次，不替用户重新启用或改期。
      if (!active) {
        next = routine.nextRunAt;
        anchor = routine.anchorAt;
      } else if (routine.oneShot) {
        active = false;
        next = null;
        anchor = null;
      } else {
        try {
          final RoutineZone zone = RoutineZone.parse(routine.timezone);
          next = nextRoutineRunDateAcross(
            routine.crons,
            anchor ?? started,
            started,
            zone,
          );
        } on FormatException {
          next = null;
        }
      }
      final RoutineRecord updated = routine.copyWith(
        active: active,
        nextRunAt: next,
        clearNextRun: next == null,
        anchorAt: anchor,
        clearAnchor: anchor == null,
        lastRunAt: started,
        updatedAt: started,
      );
      all[index] = updated;
      await _writeIndex(all);

      final RoutineRunRecord run = RoutineRunRecord(
        id: _newId('run'),
        routineId: id,
        trigger: trigger,
        status: 'running',
        createdAt: started,
        startedAt: started,
        lateSince: lateSince,
      );
      final List<RoutineRunRecord> runs = await _readRuns();
      runs.add(run);
      await _writeRuns(runs);
      return <String, dynamic>{
        'ok': true,
        'run': run.toJson(),
        'routine': updated.toJson(),
      };
    }).catchError((Object e) => _err('启动 Routine 失败：$e'));
  }

  /// 结束一次运行：写 success / failure 与结果摘要。
  ///
  /// 失败时如实记 attempts + 1，并按退避安排下次重试（最多 [maxRetries]
  /// 次）；成功或已达上限时 nextAttemptAt 为 null，不再重试。
  Future<Map<String, dynamic>> finishRun(
    String runId, {
    required bool ok,
    String result = '',
    String error = '',
    DateTime? now,
  }) async {
    return _guard(() async {
      final List<RoutineRunRecord> runs = await _readRuns();
      final int index =
          runs.indexWhere((RoutineRunRecord r) => r.id == runId);
      if (index < 0) return _err('运行记录不存在：$runId');
      final RoutineRunRecord current = runs[index];
      final DateTime finished = (now ?? DateTime.now()).toUtc();
      final int attempts = ok ? current.attempts : current.attempts + 1;
      final DateTime? nextAttemptAt = ok
          ? null
          : nextRetryAt(attempts, finished);
      final RoutineRunRecord updated = RoutineRunRecord(
        id: current.id,
        routineId: current.routineId,
        trigger: current.trigger,
        status: ok ? 'success' : 'failure',
        createdAt: current.createdAt,
        startedAt: current.startedAt,
        completedAt: finished,
        lateSince: current.lateSince,
        error: error.length > 1000 ? '${error.substring(0, 1000)}…' : error,
        result: result.length > 2000 ? '${result.substring(0, 2000)}…' : result,
        attempts: attempts,
        nextAttemptAt: nextAttemptAt,
      );
      runs[index] = updated;
      await _writeRuns(runs);
      return <String, dynamic>{'ok': true, 'run': updated.toJson()};
    }).catchError((Object e) => _err('记录运行结果失败：$e'));
  }

  /// 取一条运行记录。
  Future<Map<String, dynamic>> getRun(String runId) async {
    final List<RoutineRunRecord> runs = await _readRuns();
    final List<RoutineRunRecord> found =
        runs.where((RoutineRunRecord r) => r.id == runId).toList();
    if (found.isEmpty) return _err('运行记录不存在：$runId');
    return <String, dynamic>{'ok': true, 'run': found.first.toJson()};
  }

  /// 把一条失败运行恢复为 running，准备重跑。
  ///
  /// 仅接受 status == 'failure' 且未达最大重试次数的记录；重跑本身不推进
  /// next_run（首跑时已推进），只更新开始时间并清空上次错误。
  Future<Map<String, dynamic>> resumeRun(
    String runId, {
    DateTime? now,
  }) async {
    return _guard(() async {
      final List<RoutineRunRecord> runs = await _readRuns();
      final int index =
          runs.indexWhere((RoutineRunRecord r) => r.id == runId);
      if (index < 0) return _err('运行记录不存在：$runId');
      final RoutineRunRecord current = runs[index];
      if (current.status != 'failure') {
        return _err('该运行不可重跑（状态：${current.status}）');
      }
      if (current.attempts > maxRetries) {
        return _err('该运行已达最大重试次数，不再重跑');
      }
      final DateTime started = (now ?? DateTime.now()).toUtc();
      final RoutineRunRecord updated = RoutineRunRecord(
        id: current.id,
        routineId: current.routineId,
        trigger: current.trigger,
        status: 'running',
        createdAt: current.createdAt,
        startedAt: started,
        completedAt: null,
        lateSince: current.lateSince,
        error: '',
        result: current.result,
        attempts: current.attempts,
        nextAttemptAt: null,
      );
      runs[index] = updated;
      await _writeRuns(runs);
      return <String, dynamic>{'ok': true, 'run': updated.toJson()};
    }).catchError((Object e) => _err('恢复运行失败：$e'));
  }

  /// 把一条失败运行标记为跳过（Routine 已停用等原因，不再重跑）。
  Future<Map<String, dynamic>> skipRun(
    String runId, {
    DateTime? now,
  }) async {
    return _guard(() async {
      final List<RoutineRunRecord> runs = await _readRuns();
      final int index =
          runs.indexWhere((RoutineRunRecord r) => r.id == runId);
      if (index < 0) return _err('运行记录不存在：$runId');
      final RoutineRunRecord current = runs[index];
      if (current.status != 'failure') {
        return _err('该运行不可跳过（状态：${current.status}）');
      }
      final RoutineRunRecord updated = RoutineRunRecord(
        id: current.id,
        routineId: current.routineId,
        trigger: current.trigger,
        status: 'skipped',
        createdAt: current.createdAt,
        startedAt: current.startedAt,
        completedAt: (now ?? DateTime.now()).toUtc(),
        lateSince: current.lateSince,
        error: current.error,
        result: current.result,
        attempts: current.attempts,
        nextAttemptAt: null,
      );
      runs[index] = updated;
      await _writeRuns(runs);
      return <String, dynamic>{'ok': true, 'run': updated.toJson()};
    }).catchError((Object e) => _err('跳过运行失败：$e'));
  }

  /// 已到重试时刻的失败运行（最早到期的在前），供调度器重跑。
  Future<Map<String, dynamic>> dueRetries({
    DateTime? now,
    int limit = 10,
  }) async {
    try {
      final DateTime at = (now ?? DateTime.now()).toUtc();
      final List<RoutineRunRecord> due = (await _readRuns())
          .where((RoutineRunRecord r) =>
              r.status == 'failure' &&
              r.attempts <= maxRetries &&
              r.nextAttemptAt != null &&
              !r.nextAttemptAt!.isAfter(at))
          .toList()
        ..sort((RoutineRunRecord a, RoutineRunRecord b) =>
            a.nextAttemptAt!.compareTo(b.nextAttemptAt!));
      final List<RoutineRunRecord> capped =
          due.length <= limit ? due : due.sublist(0, limit);
      return <String, dynamic>{
        'ok': true,
        'retries': capped.map((RoutineRunRecord r) => r.toJson()).toList(),
      };
    } on Object catch (e) {
      return _err('读取待重试运行失败：$e');
    }
  }

  /// 崩溃对账：进程被杀时残留的 `running` 记录，在下次启动时改为失败
  /// 并安排重试（而不是丢弃）；已达最大重试次数的则不再安排。
  /// 返回本次对账的条数。进程启动后调用一次即可。
  Future<Map<String, dynamic>> reconcileStaleRuns({
    DateTime? now,
  }) async {
    return _guard(() async {
      final DateTime at = (now ?? DateTime.now()).toUtc();
      final List<RoutineRunRecord> runs = await _readRuns();
      int reconciled = 0;
      for (int i = 0; i < runs.length; i++) {
        final RoutineRunRecord r = runs[i];
        if (r.status != 'running') continue;
        final int attempts = r.attempts + 1;
        runs[i] = RoutineRunRecord(
          id: r.id,
          routineId: r.routineId,
          trigger: r.trigger,
          status: 'failure',
          createdAt: r.createdAt,
          startedAt: r.startedAt,
          completedAt: at,
          lateSince: r.lateSince,
          error: '上次运行被进程中断，未完成',
          result: r.result,
          attempts: attempts,
          nextAttemptAt: nextRetryAt(attempts, at),
        );
        reconciled++;
      }
      if (reconciled > 0) await _writeRuns(runs);
      return <String, dynamic>{'ok': true, 'reconciled': reconciled};
    }).catchError((Object e) => _err('对账残留运行失败：$e'));
  }

  /// 运行历史，按时间倒序；`before` 为上一页最后一条的 `{created_at,id}`。
  Future<Map<String, dynamic>> history(
    String id, {
    Map<String, dynamic>? before,
    int limit = 30,
  }) async {
    try {
      final int size = limit.clamp(1, 100);
      final List<RoutineRunRecord> runs = (await _readRuns())
          .where((RoutineRunRecord r) => r.routineId == id)
          .toList()
        ..sort((RoutineRunRecord a, RoutineRunRecord b) {
          final int byTime = b.createdAt.compareTo(a.createdAt);
          return byTime != 0 ? byTime : b.id.compareTo(a.id);
        });
      final DateTime? cursorAt =
          DateTime.tryParse('${before?['created_at'] ?? ''}');
      final String cursorId = '${before?['id'] ?? ''}';
      List<RoutineRunRecord> page = runs;
      if (cursorAt != null) {
        page = runs.where((RoutineRunRecord r) {
          if (r.createdAt.isBefore(cursorAt)) return true;
          if (r.createdAt.isAfter(cursorAt)) return false;
          return r.id.compareTo(cursorId) < 0;
        }).toList();
      }
      final bool more = page.length > size;
      final List<RoutineRunRecord> visible =
          more ? page.sublist(0, size) : page;
      return <String, dynamic>{
        'ok': true,
        'runs': visible.map((RoutineRunRecord r) => r.toJson()).toList(),
        'next_cursor': more && visible.isNotEmpty
            ? <String, dynamic>{
                'created_at': visible.last.createdAt.toIso8601String(),
                'id': visible.last.id,
              }
            : null,
      };
    } on Object catch (e) {
      return _err('读取运行历史失败：$e');
    }
  }

  /// 运行记录（含 duration 与迟到信息），供页面展示。
  Future<Map<String, dynamic>> historyDetailed(
    String id, {
    Map<String, dynamic>? before,
    int limit = 30,
  }) async {
    final Map<String, dynamic> raw = await history(
      id,
      before: before,
      limit: limit,
    );
    if (raw['ok'] != true) return raw;
    final List<dynamic> runs = (raw['runs'] as List?) ?? const <dynamic>[];
    return <String, dynamic>{
      ...raw,
      'runs': runs.whereType<Map>().map((Map run) {
        final DateTime? started = DateTime.tryParse('${run['started_at']}');
        final DateTime? completed =
            DateTime.tryParse('${run['completed_at']}');
        final DateTime? lateSince = DateTime.tryParse('${run['late_since']}');
        final int? duration = started == null || completed == null
            ? null
            : completed.difference(started).inMilliseconds;
        final ({String unit, int count})? late =
            routineRunLateness(lateSince, started);
        return <String, dynamic>{
          ...run,
          'duration_ms': duration,
          'duration_label': compactDuration(duration),
          'late_label': late == null ? null : '迟到 ${late.count} ${late.unit}',
        };
      }).toList(),
    };
  }

  static Map<String, dynamic> _err(String message) =>
      <String, dynamic>{'ok': false, 'error': message};
}
