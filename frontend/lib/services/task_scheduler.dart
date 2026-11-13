import 'dart:async';

import 'package:flutter/foundation.dart';

import '../bridge/backend_client.dart';
import 'persona_store.dart';

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

  /// 启动周期检查（幂等）。
  void start() {
    _timer ??= Timer.periodic(_interval, (_) => checkNow());
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
    } on Object {
      // 后端未连接等异常：本轮静默跳过，下个周期再试（不谎报执行）。
    } finally {
      _running = false;
    }
  }

  Future<void> _runTask({
    required String id,
    required ParsedTask task,
    required String dayKey,
  }) async {
    // 先记 lastRun 再执行：失败也不会在同一天反复重试刷屏。
    persona.setTaskLastRun(id, dayKey);
    final String prompt = task.description.isEmpty
        ? '【定时任务 · ${task.name}】现在是约定时间 ${task.timeLabel}，'
            '请执行这项任务并把结果如实汇报。'
        : '【定时任务 · ${task.name}】现在是约定时间 ${task.timeLabel}。\n'
            '任务说明：${task.description}\n'
            '请执行这项任务并把结果如实汇报。';
    await backend.sendControl('chat', <String, dynamic>{
      'text': prompt,
      'session_id': 'proactive',
    });
    notifyListeners();
  }

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
