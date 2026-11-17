import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/backend_client.dart';
import '../harness/account_ops.dart';
import '../harness/embedded_backend.dart';
import 'persona_store.dart';

/// 定时任务失败重试策略（纯逻辑，便于单元测试）。
class TaskRetryPolicy {
  const TaskRetryPolicy._();

  /// 第 1/2/3 次重试前的等待秒数。
  static const List<int> backoffSeconds = <int>[60, 300, 900];

  /// runHistory 最多保留的条数。
  static const int maxRunHistory = 100;

  /// 返回第 [attempt] 次重试（从 1 开始）前的等待秒数；
  /// attempt > 3 时返回 null，表示不再重试。
  static int? delayForAttempt(int attempt) {
    if (attempt < 1 || attempt > backoffSeconds.length) return null;
    return backoffSeconds[attempt - 1];
  }

  /// 追加一条运行记录并按上限裁剪（纯逻辑；超出时丢弃最旧记录）。
  static void appendRunHistory(
    List<Map<String, dynamic>> history,
    Map<String, dynamic> entry,
  ) {
    history.add(entry);
    while (history.length > maxRunHistory) {
      history.removeAt(0);
    }
  }
}

/// 定时任务标题约定：后端 proactive_task 的 add 只收 title，
/// 因此前端把每日执行时间与说明编码进 title：
///   第一行「任务名 @HH:mm」，第二行起为任务说明（可为空）。
@immutable
class ParsedTask {
  const ParsedTask({
    required this.name,
    required this.hour,
    required this.minute,
    required this.description,
  });

  final String name;
  final int hour;
  final int minute;
  final String description;

  /// 「HH:mm」展示串。
  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// 定时任务真实调度器。
///
/// 后端只负责把规则落库（list/add/toggle/delete），不执行任何触发；
/// 这里每 30 秒轮询一次 proactive_task list，解析标题里的每日「@HH:mm」，
/// 到点就经 chat 控制域真实执行一次（结果按普通对话写入 turns 记录，
/// 因此也会真实出现在「我的日记」里），并用 [PersonaStore.taskLastRun]
/// 记录最近执行日防止同一天重复触发。
class TaskScheduler extends ChangeNotifier {
  TaskScheduler({required this.backend, required this.persona});

  final BackendClient backend;
  final PersonaStore persona;

  static const Duration _interval = Duration(seconds: 30);

  /// 解析「任务名 @HH:mm（第二行起为说明）」；不符合约定返回 null（不会被调度）。
  static ParsedTask? parseTitle(String title) {
    final List<String> lines = title.split('\n');
    final RegExpMatch? m =
        RegExp(r'^(.*?)\s*@(\d{1,2}):(\d{2})\s*$').firstMatch(lines.first);
    if (m == null) return null;
    final int hour = int.tryParse(m.group(2) ?? '') ?? -1;
    final int minute = int.tryParse(m.group(3) ?? '') ?? -1;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    final String name = (m.group(1) ?? '').trim();
    if (name.isEmpty) return null;
    final String desc = lines.skip(1).join('\n').trim();
    return ParsedTask(
        name: name, hour: hour, minute: minute, description: desc);
  }

  /// 组装落库 title：第一行「任务名 @HH:mm」，说明另起一行。
  static String encodeTitle(String name, String timeLabel, String description) {
    final String head = '${name.trim()} @$timeLabel';
    return description.trim().isEmpty ? head : '$head\n${description.trim()}';
  }

  Timer? _timer;
  bool _running = false;

  /// 运行历史（最近 [TaskRetryPolicy.maxRunHistory] 条）。
  /// 元素字段：id / name / attempt / ok / error / ts / outcome；
  /// outcome 取 'success' | 'failure' | 'retry_scheduled'，attempt 为 1 基尝试次数。
  final List<Map<String, dynamic>> _runHistory = <Map<String, dynamic>>[];

  List<Map<String, dynamic>> get runHistory =>
      List<Map<String, dynamic>>.unmodifiable(_runHistory);

  /// 失败重试队列，key 为 '$id@$dayKey'。
  final Map<String, _RetryState> _retries = <String, _RetryState>{};

  /// 持久化文件（相对 HarnessStore 根目录）。
  static const String _statePath = 'scheduler/state.json';
  Future<void>? _loadFuture;
  Future<void> _persistChain = Future<void>.value();

  /// 最近一次「定时发布到期草稿」的真实结果（失败原因原样保留以供排查）。
  /// 只在本 App 进程内累积，作为给 UI 的日志/通知，不伪造发布成功。
  String _lastPublishNote = '';
  final List<String> _publishLog = <String>[];

  String get lastPublishNote => _lastPublishNote;
  List<String> get publishLog => List<String>.unmodifiable(_publishLog);

  /// 启动周期检查（幂等）。
  void start() {
    _timer ??= Timer.periodic(_interval, (_) => checkNow());
    // 启动后懒加载重试队列与运行历史（后端此时通常已连接）。
    unawaited(_ensureStateLoaded());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  /// 立即检查一轮：UI 新建/修改任务后也可调用它让状态尽快生效。
  Future<void> checkNow() async {
    if (_running) return;
    _running = true;
    try {
      await _ensureStateLoaded();
      // 先处理已到点的重试：直接执行，不再走 dayKey / 触发点判断，
      // 避免被首次失败时写入的 taskLastRun 拦住。
      await _processDueRetries();
      final env = await backend.sendControl(
          'proactive_task', <String, dynamic>{'action': 'list'});
      final dynamic payload = env.payload;
      if (payload is! Map || payload['ok'] != true) return;
      final List<dynamic> rules =
          (payload['rules'] as List?) ?? const <dynamic>[];
      final DateTime now = DateTime.now();
      final String today = _dayKey(now);
      for (final dynamic r in rules) {
        if (r is! Map) continue;
        if (r['enabled'] != true) continue;
        final ParsedTask? task = parseTitle('${r['title'] ?? r['name'] ?? ''}');
        if (task == null) continue;
        final String id = '${r['id'] ?? ''}';
        if (id.isEmpty) continue;
        // 同一天已执行过 → 跳过。
        if (persona.taskLastRun[id] == today) continue;
        final DateTime scheduled =
            DateTime(now.year, now.month, now.day, task.hour, task.minute);
        if (now.isBefore(scheduled)) continue;
        // 创建时间晚于今天的触发点（如 10 点建了个 9 点的任务）→
        // 不立刻补跑，等明天到点再说。
        final dynamic ts = r['ts'];
        if (ts is num) {
          final DateTime created =
              DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
          if (created.isAfter(scheduled)) continue;
        }
        await _runTask(id: id, task: task, dayKey: today);
      }
      // 自动化工作流的每日定时触发：由 workflow.due 真实判定到点且今天未跑，
      // 逐个调用 run；执行结果与状态由工作流引擎落盘。
      final env2 = await backend.sendControl(
          'workflow', <String, dynamic>{'action': 'due'});
      final dynamic wp = env2.payload;
      if (wp is Map && wp['ok'] == true) {
        final List<dynamic> due =
            (wp['due'] as List?) ?? const <dynamic>[];
        for (final dynamic raw in due) {
          if (raw is! Map) continue;
          final String id = '${raw['id'] ?? ''}';
          if (id.isEmpty) continue;
          await backend.sendControl('workflow', <String, dynamic>{
            'action': 'run',
            'id': id,
          });
          notifyListeners();
        }
      }
      // Super Agent：周期性触发一次队列调度，让延后到点的工单按时开始。
      try {
        await backend.sendControl(
            'super_agent', <String, dynamic>{'action': 'queue'});
      } on Object {
        // Super Agent 未就绪不影响定时任务。
      }
      // 账号运营：发布「approved + 已到点」的定时草稿。
      // 如实说明：Timer 只随 App 进程存活而运行；进程被系统杀死/退到后台
      // 停止执行时不会发布，重新启动后的下一轮检查会补发已到期草稿。
      // 放在 workflow / super_agent 调度之后并整体 try/catch，失败绝不抛出、
      // 也不阻塞前两者；结果写入 publishLog 供 UI 展示。
      await _publishDueDrafts();
    } on Object {
      // 后端未连接等异常：本轮静默跳过，下个周期再试（不谎报执行）。
    } finally {
      _running = false;
    }
  }

  /// 调用 AccountOps.publishDue 发布到期草稿；不自动审批任何草稿。
  /// 单轮最多 5 条，20 秒超时，避免占用调度循环太久。
  Future<void> _publishDueDrafts() async {
    // 仅 inProcess 内嵌后端能拿到真实发布通道（accountOps）；其它桥接模式
    // 没有可用的 send，如实跳过而不是伪造发布。
    final EmbeddedBackend? embedded = backend.embeddedBackend;
    if (embedded == null) return;
    try {
      final AccountOps ops = embedded.accountOps();
      final Map<String, dynamic> r = await ops
          .publishDue(limit: 5)
          .timeout(const Duration(seconds: 20));
      if (r['ok'] != true) {
        _recordPublishNote('定时发布失败：${r['error'] ?? 'ok=false'}');
        return;
      }
      final int published =
          (r['published'] is num) ? (r['published'] as num).toInt() : 0;
      final int failed =
          (r['failed'] is num) ? (r['failed'] as num).toInt() : 0;
      final int skipped =
          (r['skipped'] is num) ? (r['skipped'] as num).toInt() : 0;
      if (published == 0 && failed == 0 && skipped == 0) return;
      _recordPublishNote(
          '定时发布：成功 $published，失败 $failed，跳过 $skipped');
    } on Object catch (e) {
      _recordPublishNote('定时发布异常：$e');
    }
  }

  void _recordPublishNote(String note) {
    final String short = note.length > 200 ? '${note.substring(0, 200)}…' : note;
    _lastPublishNote = '${DateTime.now().toIso8601String()} $short';
    _publishLog.add(_lastPublishNote);
    if (_publishLog.length > 20) _publishLog.removeAt(0);
    debugPrint('[TaskScheduler] $short');
    notifyListeners();
  }

  /// 执行一次任务并判定成败。
  /// [attempt] 为本次执行前的重试序号：0 表示首次执行，1 表示第 1 次重试。
  /// 历史记录中的 attempt 存 1 基的尝试次数（attempt + 1）。
  Future<void> _runTask({
    required String id,
    required ParsedTask task,
    required String dayKey,
    int attempt = 0,
  }) async {
    // 先记 lastRun 再执行：每日触发不会在同一天被重复调度；
    // 失败重试由重试队列直接执行，不受这个标记拦截。
    persona.setTaskLastRun(id, dayKey);
    final String prompt = task.description.isEmpty
        ? '【定时任务 · ${task.name}】现在是约定时间 ${task.timeLabel}，'
            '请执行这项任务并把结果如实汇报。'
        : '【定时任务 · ${task.name}】现在是约定时间 ${task.timeLabel}。\n'
            '任务说明：${task.description}\n'
            '请执行这项任务并把结果如实汇报。';
    String error = '';
    bool ok = false;
    try {
      final env = await backend.sendControl('chat', <String, dynamic>{
        'text': prompt,
        'session_id': 'proactive',
      });
      final dynamic payload = env.payload;
      ok = payload is Map && payload['ok'] == true;
      if (!ok) {
        error = payload is Map
            ? '${payload['error'] ?? 'ok=false'}'
            : '后端返回了非预期结构';
      }
    } on Object catch (e) {
      error = '$e';
    }

    if (ok) {
      // 成功：清空该任务的重试安排并记录 success。
      _retries.removeWhere((String _, _RetryState s) => s.id == id);
      _appendHistory(id, task.name, attempt, true, '', 'success');
      _schedulePersist();
      notifyListeners();
      return;
    }

    // 失败（含异常/超时）：如实记录 failure。
    _appendHistory(id, task.name, attempt, false, error, 'failure');
    final int? delay = TaskRetryPolicy.delayForAttempt(attempt + 1);
    if (delay == null) {
      _schedulePersist();
      notifyListeners();
      return;
    }
    // 加入/更新重试队列，等 nextAt 到点由 tick 直接执行。
    _retries['$id@$dayKey'] = _RetryState(
      id: id,
      dayKey: dayKey,
      attempt: attempt + 1,
      nextAt: DateTime.now().add(Duration(seconds: delay)),
      task: task,
    );
    _appendHistory(id, task.name, attempt, false, error, 'retry_scheduled');
    _recordPublishNote(
        '定时任务 ${task.name} 第 ${attempt + 1} 次失败，${delay}s 后重试：$error');
    _schedulePersist();
    notifyListeners();
  }

  /// 执行 nextAt 已到的重试。直接执行，不参与每日触发点/延迟补跑判断。
  Future<void> _processDueRetries() async {
    if (_retries.isEmpty) return;
    final DateTime now = DateTime.now();
    final List<_RetryState> due = _retries.values
        .where((_RetryState s) => !s.nextAt.isAfter(now))
        .toList(growable: false);
    for (final _RetryState state in due) {
      _retries.remove(state.key);
      await _runTask(
        id: state.id,
        task: state.task,
        dayKey: state.dayKey,
        attempt: state.attempt,
      );
    }
  }

  void _appendHistory(
    String id,
    String name,
    int attempt,
    bool ok,
    String error,
    String outcome,
  ) {
    TaskRetryPolicy.appendRunHistory(_runHistory, <String, dynamic>{
      'id': id,
      'name': name,
      'attempt': attempt + 1,
      'ok': ok,
      'error': error,
      'ts': DateTime.now().toIso8601String(),
      'outcome': outcome,
    });
  }

  /// 懒加载 scheduler/state.json。embeddedBackend 为 null 时仅内存运行：
  /// 不读盘也不落盘，等后端就绪后的下一轮再加载。
  Future<void> _ensureStateLoaded() {
    final EmbeddedBackend? embedded = backend.embeddedBackend;
    if (embedded == null) return Future<void>.value();
    // 记录同一个 Future：并发触发的检查会等首次加载完成，避免读到空态后覆盖落盘。
    return _loadFuture ??= _loadState(embedded);
  }

  Future<void> _loadState(EmbeddedBackend embedded) async {
    try {
      final Map<String, dynamic> raw = await embedded.store.readJson(_statePath);
      final List<dynamic> rawRetries =
          (raw['retries'] as List?) ?? const <dynamic>[];
      for (final dynamic r in rawRetries) {
        final _RetryState? state = _RetryState.fromJson(r);
        if (state != null) _retries[state.key] = state;
      }
      final List<dynamic> rawHistory =
          (raw['history'] as List?) ?? const <dynamic>[];
      for (final dynamic h in rawHistory) {
        if (h is Map) {
          _runHistory.add(
              h.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)));
        }
      }
      while (_runHistory.length > TaskRetryPolicy.maxRunHistory) {
        _runHistory.removeAt(0);
      }
      if (_retries.isNotEmpty || _runHistory.isNotEmpty) notifyListeners();
    } on Object {
      // 读取失败保持空态，不伪造历史；下一轮仍可正常调度。
    }
  }

  /// 变更后落盘（串行，避免并发写同一临时文件）。
  /// 失败静默：内存中的重试/历史仍真实，不谎报已持久化。
  void _schedulePersist() {
    _persistChain = _persistChain.then((_) => _persistState());
  }

  Future<void> _persistState() async {
    // 仅内存运行：没有内嵌后端就没有可写的真实数据目录。
    final EmbeddedBackend? embedded = backend.embeddedBackend;
    if (embedded == null) return;
    try {
      await embedded.store.writeJson(_statePath, <String, dynamic>{
        'retries': _retries.values.map((_RetryState s) => s.toJson()).toList(),
        'history': _runHistory,
      });
    } on Object {
      // 落盘失败不影响调度，也不改写内存状态。
    }
  }

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 单条失败重试状态（随 scheduler/state.json 持久化）。
class _RetryState {
  _RetryState({
    required this.id,
    required this.dayKey,
    required this.attempt,
    required this.nextAt,
    required this.task,
  });

  final String id;
  final String dayKey;

  /// 下一次重试序号（1 基）。
  final int attempt;
  final DateTime nextAt;
  final ParsedTask task;

  String get key => '$id@$dayKey';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'day_key': dayKey,
        'attempt': attempt,
        'next_at': nextAt.toIso8601String(),
        'task': <String, dynamic>{
          'name': task.name,
          'hour': task.hour,
          'minute': task.minute,
          'description': task.description,
        },
      };

  static _RetryState? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final String id = '${raw['id'] ?? ''}';
    final String dayKey = '${raw['day_key'] ?? ''}';
    final dynamic rawAttempt = raw['attempt'];
    final DateTime? nextAt = DateTime.tryParse('${raw['next_at'] ?? ''}');
    final dynamic t = raw['task'];
    if (id.isEmpty || dayKey.isEmpty || rawAttempt is! num || nextAt == null) {
      return null;
    }
    if (t is! Map) return null;
    final String name = '${t['name'] ?? ''}';
    final dynamic rawHour = t['hour'];
    final dynamic rawMinute = t['minute'];
    if (name.isEmpty || rawHour is! num || rawMinute is! num) return null;
    final int attempt = rawAttempt.toInt();
    if (attempt < 1) return null;
    return _RetryState(
      id: id,
      dayKey: dayKey,
      attempt: attempt,
      nextAt: nextAt,
      task: ParsedTask(
        name: name,
        hour: rawHour.toInt(),
        minute: rawMinute.toInt(),
        description: '${t['description'] ?? ''}',
      ),
    );
  }
}
