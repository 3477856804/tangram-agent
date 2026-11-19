import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/store.dart';

/// 定时任务草稿（对话框确认后返回给页面，不直接落库）。
class _ScheduleDraft {
  const _ScheduleDraft({
    required this.title,
    required this.prompt,
    required this.cron,
  });

  final String title;
  final String prompt;

  /// 简单表达式：每日「HH:mm」或间隔「every:N」（N 为分钟）。
  final String cron;
}

/// 定时任务页（LocModel 风格的本机任务管理）。
///
/// 任务真实持久化到 [HarnessStore] 的 `schedules.json`，字段：
/// id / title / prompt / cron / enabled / last_run / next_run /
/// last_result / last_error。
///
/// 调度只发生在**本页面打开且应用处于前台**时：initState 起
/// [Timer.periodic] 每 30 秒检查一次到期任务，到点经
/// `BackendClient.sendControl('agent_command', {'action': 'chat', 'text': prompt})`
/// 真实执行，并把上次执行时间、结果摘要或错误写回文件。
/// 本页不注册系统闹钟/AlarmManager，应用退到后台或被杀后不会执行，
/// 因此界面明确标注「仅应用在前台时执行」，绝不假装后台定时。
class TgaSchedulePage extends StatefulWidget {
  const TgaSchedulePage({super.key});

  @override
  State<TgaSchedulePage> createState() => _TgaSchedulePageState();
}

class _TgaSchedulePageState extends State<TgaSchedulePage>
    with WidgetsBindingObserver {
  static const String _storeKey = 'schedules';
  static const Duration _tickInterval = Duration(seconds: 30);

  static final RegExp _dailyPattern = RegExp(r'^(\d{1,2}):(\d{2})$');
  static final RegExp _intervalPattern = RegExp(r'^every:(\d{1,4})$');

  final List<Map<String, dynamic>> _tasks = <Map<String, dynamic>>[];
  final Set<int> _running = <int>{};

  HarnessStore? _store;
  Timer? _timer;
  bool _loading = true;
  bool _checking = false;
  String _error = '';
  String _filter = 'all';
  DateTime? _lastChecked;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  bool get _foreground => _lifecycle == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
    // 前台调度入口：每 30 秒检查一次到期任务。
    _timer = Timer.periodic(_tickInterval, (_) => unawaited(_checkDue()));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) {
      // 回到前台立即补检一次，避免等待下一个 30 秒周期。
      unawaited(_checkDue());
    }
  }

  // ------------------------------------------------------------ 存储读写

  Future<void> _load() async {
    try {
      final HarnessStore store = _store ?? await HarnessStore.instance();
      final List<Map<String, dynamic>> records =
          await store.readRecords(_storeKey);
      final DateTime now = DateTime.now();
      bool dirty = false;
      for (final Map<String, dynamic> task in records) {
        if (task['enabled'] == true &&
            _parseDate(task['next_run']) == null) {
          final DateTime? next =
              _nextAfter((task['cron'] ?? '').toString(), now);
          if (next != null) {
            task['next_run'] = next.toIso8601String();
            dirty = true;
          }
        }
      }
      if (dirty) {
        try {
          await store.writeRecords(_storeKey, records);
        } on Object {
          // 补写失败不影响本次展示，下一轮仍会重新计算。
        }
      }
      records.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
          _idOf(a).compareTo(_idOf(b)));
      if (!mounted) return;
      setState(() {
        _store = store;
        _tasks
          ..clear()
          ..addAll(records);
        _loading = false;
        _error = '';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取定时任务失败：$e';
      });
    }
  }

  /// 更新单条任务：先写盘，再同步内存；写盘失败如实提示。
  Future<void> _patchTask(int id, Map<String, dynamic> patch) async {
    final HarnessStore? store = _store;
    if (store == null) return;
    try {
      await store.update(_storeKey, id, patch);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = '保存任务失败：$e');
      }
    }
    for (final Map<String, dynamic> task in _tasks) {
      if (_idOf(task) == id) task.addAll(patch);
    }
  }

  Future<void> _saveTask(_ScheduleDraft draft, {int? id}) async {
    final HarnessStore? store = _store;
    if (store == null) return;
    final DateTime now = DateTime.now();
    final String nextRun =
        _nextAfter(draft.cron, now)?.toIso8601String() ?? '';
    try {
      if (id == null) {
        await store.insert(_storeKey, <String, dynamic>{
          'title': draft.title,
          'prompt': draft.prompt,
          'cron': draft.cron,
          'enabled': true,
          'last_run': '',
          'next_run': nextRun,
          'last_result': '',
          'last_error': '',
        });
      } else {
        await store.update(_storeKey, id, <String, dynamic>{
          'title': draft.title,
          'prompt': draft.prompt,
          'cron': draft.cron,
          'next_run': nextRun,
        });
      }
      await _load();
    } on Object catch (e) {
      if (!mounted) return;
      _snack('保存失败：$e', error: true);
    }
  }

  Future<void> _toggle(Map<String, dynamic> task) async {
    final int id = _idOf(task);
    final bool enabled = task['enabled'] != true;
    final String nextRun = enabled
        ? (_nextAfter((task['cron'] ?? '').toString(), DateTime.now())
                ?.toIso8601String() ??
            '')
        : (task['next_run'] ?? '').toString();
    await _patchTask(id, <String, dynamic>{
      'enabled': enabled,
      'next_run': nextRun,
    });
    if (mounted) setState(() {});
  }

  Future<void> _delete(Map<String, dynamic> task) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return AlertDialog(
          backgroundColor: Tga.card,
          title: Text('删除定时任务', style: Tga.h2),
          content: Text(
            '确定删除「${task['title']}」？删除后不再执行，历史记录一并移除。',
            style: Tga.sub,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    final HarnessStore? store = _store;
    if (store == null) return;
    try {
      await store.remove(_storeKey, _idOf(task));
      await _load();
      if (!mounted) return;
      _snack('已删除「${task['title']}」');
    } on Object catch (e) {
      if (!mounted) return;
      _snack('删除失败：$e', error: true);
    }
  }

  // ------------------------------------------------------------ 前台调度

  /// 检查一轮到期任务；同一时间只允许一轮，避免 30 秒重叠。
  Future<void> _checkDue() async {
    if (_checking || _loading || !_foreground || _store == null) return;
    _checking = true;
    try {
      final DateTime now = DateTime.now();
      final List<Map<String, dynamic>> due = <Map<String, dynamic>>[];
      for (final Map<String, dynamic> task in _tasks) {
        if (task['enabled'] != true) continue;
        final int id = _idOf(task);
        if (id <= 0 || _running.contains(id)) continue;
        final DateTime? next = _parseDate(task['next_run']);
        if (next == null || next.isAfter(now)) continue;
        due.add(task);
      }
      for (final Map<String, dynamic> task in due) {
        await _runTask(task);
      }
      if (mounted) {
        setState(() => _lastChecked = DateTime.now());
      }
    } finally {
      _checking = false;
    }
  }

  /// 真实执行一条任务：先推进 next_run 再调用后端，结果写回文件。
  Future<void> _runTask(Map<String, dynamic> task) async {
    if (!mounted) return;
    final int id = _idOf(task);
    final String prompt = (task['prompt'] ?? '').toString().trim();
    if (id <= 0 || prompt.isEmpty) return;
    final BackendClient backend = context.read<BackendClient>();
    final DateTime startedAt = DateTime.now();
    final String nextRun =
        _nextAfter((task['cron'] ?? '').toString(), startedAt)
                ?.toIso8601String() ??
            '';
    _running.add(id);
    // 先落 last_run / next_run，避免下一轮重复触发同一条任务。
    await _patchTask(id, <String, dynamic>{
      'last_run': startedAt.toIso8601String(),
      'next_run': nextRun,
      'last_result': '执行中…',
      'last_error': '',
    });
    if (mounted) setState(() {});

    String result = '';
    String error = '';
    try {
      final dynamic env = await backend.sendControl(
        'agent_command',
        <String, dynamic>{'action': 'chat', 'text': prompt},
      );
      final dynamic payload = env.payload;
      if (payload is Map && payload['ok'] == true) {
        final String reply =
            (payload['reply'] ?? payload['text'] ?? '').toString().trim();
        result = reply.isEmpty ? '已执行（后端未返回文本）' : _summarize(reply);
      } else {
        error = payload is Map
            ? (payload['error'] ?? 'ok=false').toString()
            : '后端返回了非预期结构';
      }
    } on Object catch (e) {
      error = '执行失败：$e';
    }

    await _patchTask(id, <String, dynamic>{
      'last_result': result,
      'last_error': error,
    });
    _running.remove(id);
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------ 表达式工具

  static int _idOf(Map<String, dynamic> task) {
    final dynamic raw = task['id'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    return int.tryParse('${raw ?? ''}') ?? 0;
  }

  static DateTime? _parseDate(Object? raw) {
    final String text = (raw ?? '').toString().trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  /// 返回严格晚于 [now] 的下一个触发时间；表达式非法返回 null。
  static DateTime? _nextAfter(String cron, DateTime now) {
    final String text = cron.trim();
    final RegExpMatch? daily = _dailyPattern.firstMatch(text);
    if (daily != null) {
      final int hour = int.tryParse(daily.group(1)!) ?? -1;
      final int minute = int.tryParse(daily.group(2)!) ?? -1;
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
      DateTime candidate =
          DateTime(now.year, now.month, now.day, hour, minute);
      if (!candidate.isAfter(now)) {
        candidate = candidate.add(const Duration(days: 1));
      }
      return candidate;
    }
    final RegExpMatch? interval = _intervalPattern.firstMatch(text);
    if (interval != null) {
      final int minutes = int.tryParse(interval.group(1)!) ?? 0;
      if (minutes < 1) return null;
      return now.add(Duration(minutes: minutes));
    }
    return null;
  }

  static String _cronLabel(String cron) {
    final int? minutes =
        int.tryParse(_intervalPattern.firstMatch(cron.trim())?.group(1) ?? '');
    if (minutes != null && minutes > 0) {
      return minutes >= 60 && minutes % 60 == 0
          ? '每 ${minutes ~/ 60} 小时'
          : '每 $minutes 分钟';
    }
    final RegExpMatch? daily = _dailyPattern.firstMatch(cron.trim());
    if (daily != null) {
      final int hour = int.tryParse(daily.group(1)!) ?? 0;
      final int minute = int.tryParse(daily.group(2)!) ?? 0;
      return '每日 ${hour.toString().padLeft(2, '0')}:'
          '${minute.toString().padLeft(2, '0')}';
    }
    return '表达式无效';
  }

  static String _formatWhen(DateTime value) {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime day = DateTime(value.year, value.month, value.day);
    final int diff = day.difference(today).inDays;
    final String clock = '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return '今天 $clock';
    if (diff == 1) return '明天 $clock';
    if (diff == -1) return '昨天 $clock';
    return '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')} $clock';
  }

  static String _summarize(String text) {
    final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 120) return oneLine;
    return '${oneLine.substring(0, 120)}…';
  }

  // ------------------------------------------------------------ 新增 / 编辑

  Future<void> _editTask([Map<String, dynamic>? existing]) async {
    final TextEditingController titleCtrl = TextEditingController(
      text: (existing?['title'] ?? '').toString(),
    );
    final TextEditingController promptCtrl = TextEditingController(
      text: (existing?['prompt'] ?? '').toString(),
    );
    final String rawCron = (existing?['cron'] ?? '').toString().trim();
    final int? existingMinutes =
        int.tryParse(_intervalPattern.firstMatch(rawCron)?.group(1) ?? '');
    bool dailyMode = existingMinutes == null;
    final TextEditingController timeCtrl = TextEditingController(
      text: dailyMode && _dailyPattern.hasMatch(rawCron)
          ? rawCron
          : '09:00',
    );
    final TextEditingController intervalCtrl = TextEditingController(
      text: existingMinutes == null ? '30' : existingMinutes.toString(),
    );
    String dialogError = '';

    final _ScheduleDraft? draft = await showDialog<_ScheduleDraft>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setLocal) {
            Tga.syncFrom(ctx);

            String? validate() {
              if (titleCtrl.text.trim().isEmpty) return '请填写任务标题';
              if (promptCtrl.text.trim().isEmpty) return '请填写提示词';
              if (dailyMode) {
                final RegExpMatch? m =
                    _dailyPattern.firstMatch(timeCtrl.text.trim());
                if (m == null) return '时间格式应为 HH:mm';
                final int hour = int.tryParse(m.group(1)!) ?? -1;
                final int minute = int.tryParse(m.group(2)!) ?? -1;
                if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
                  return '时间需在 00:00 - 23:59 之间';
                }
              } else {
                final int? minutes =
                    int.tryParse(intervalCtrl.text.trim());
                if (minutes == null || minutes < 1 || minutes > 1440) {
                  return '间隔需为 1 - 1440 分钟';
                }
              }
              return null;
            }

            Widget field(
              TextEditingController controller,
              String label, {
              String hint = '',
              int minLines = 1,
              int maxLines = 1,
              TextInputType? keyboard,
            }) {
              return TextField(
                controller: controller,
                minLines: minLines,
                maxLines: maxLines,
                keyboardType: keyboard,
                style: TextStyle(color: Tga.text, fontSize: 13.5),
                decoration: InputDecoration(
                  labelText: label,
                  hintText: hint.isEmpty ? null : hint,
                  filled: true,
                  fillColor: Tga.bgSoft,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              );
            }

            return AlertDialog(
              backgroundColor: Tga.card,
              title: Text(
                existing == null ? '新建定时任务' : '编辑定时任务',
                style: Tga.h2,
              ),
              content: SizedBox(
                width: 430,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      TgaSegmented<String>(
                        items: const <String>['daily', 'interval'],
                        value: dailyMode ? 'daily' : 'interval',
                        labelOf: (String item) =>
                            item == 'daily' ? '每日时间' : '间隔分钟',
                        onChanged: (String item) {
                          setLocal(() {
                            dailyMode = item == 'daily';
                            dialogError = '';
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      field(titleCtrl, '任务标题', hint: '例如：每日简报'),
                      const SizedBox(height: 10),
                      field(
                        promptCtrl,
                        '提示词',
                        hint: '到点后发送给 Agent 的完整指令',
                        minLines: 3,
                        maxLines: 5,
                      ),
                      const SizedBox(height: 10),
                      if (dailyMode)
                        field(
                          timeCtrl,
                          '每日执行时间',
                          hint: 'HH:mm，例如 09:30',
                          keyboard: TextInputType.datetime,
                        )
                      else
                        field(
                          intervalCtrl,
                          '执行间隔（分钟）',
                          hint: '1 - 1440',
                          keyboard: TextInputType.number,
                        ),
                      const SizedBox(height: 10),
                      Text(
                        '仅应用在前台时执行：页面打开期间每 30 秒检查一次。',
                        style: Tga.caption,
                      ),
                      if (dialogError.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          dialogError,
                          style: TextStyle(color: Tga.red, fontSize: 12),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text('取消', style: TextStyle(color: Tga.textSub)),
                ),
                FilledButton(
                  onPressed: () {
                    final String? message = validate();
                    if (message != null) {
                      setLocal(() => dialogError = message);
                      return;
                    }
                    final String cron = dailyMode
                        ? _normalizeClock(timeCtrl.text.trim())
                        : 'every:${int.parse(intervalCtrl.text.trim())}';
                    Navigator.of(ctx).pop(_ScheduleDraft(
                      title: titleCtrl.text.trim(),
                      prompt: promptCtrl.text.trim(),
                      cron: cron,
                    ));
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );

    titleCtrl.dispose();
    promptCtrl.dispose();
    timeCtrl.dispose();
    intervalCtrl.dispose();
    if (draft == null || !mounted) return;
    await _saveTask(
      draft,
      id: existing == null ? null : _idOf(existing),
    );
  }

  static String _normalizeClock(String text) {
    final RegExpMatch? m = _dailyPattern.firstMatch(text);
    final int hour = int.tryParse(m?.group(1) ?? '') ?? 0;
    final int minute = int.tryParse(m?.group(2) ?? '') ?? 0;
    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  // ------------------------------------------------------------ UI

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Tga.red : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  List<Map<String, dynamic>> get _filteredTasks {
    if (_filter == 'on') {
      return _tasks
          .where((Map<String, dynamic> t) => t['enabled'] == true)
          .toList();
    }
    if (_filter == 'off') {
      return _tasks
          .where((Map<String, dynamic> t) => t['enabled'] != true)
          .toList();
    }
    return _tasks;
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final int enabledCount =
        _tasks.where((Map<String, dynamic> t) => t['enabled'] == true).length;
    final List<Map<String, dynamic>> visible = _filteredTasks;
    return TgaPage(
      title: '定时',
      actions: <Widget>[
        IconButton(
          tooltip: '立即检查',
          onPressed: _checking ? null : () => unawaited(_checkDue()),
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
        IconButton(
          tooltip: '新建任务',
          onPressed: _loading ? null : () => unawaited(_editTask()),
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Tga.primary,
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(
                Tga.pagePad,
                4,
                Tga.pagePad,
                40,
              ),
              children: <Widget>[
                _noticeCard(),
                const TgaGroupTitle('概览'),
                Row(
                  children: <Widget>[
                    TgaStatCard(
                      value: '${_tasks.length}',
                      label: '任务总数',
                      color: Tga.primary,
                      icon: Icons.event_note_rounded,
                    ),
                    const SizedBox(width: 10),
                    TgaStatCard(
                      value: '$enabledCount',
                      label: '已启用',
                      color: Tga.green,
                      icon: Icons.play_circle_outline_rounded,
                    ),
                  ],
                ),
                TgaGroupTitle(
                  '任务',
                  trailing: TgaButton(
                    label: '新建',
                    icon: Icons.add_rounded,
                    onTap: () => unawaited(_editTask()),
                  ),
                ),
                TgaSegmented<String>(
                  items: const <String>['all', 'on', 'off'],
                  value: _filter,
                  labelOf: (String item) {
                    switch (item) {
                      case 'on':
                        return '已启用';
                      case 'off':
                        return '已暂停';
                      default:
                        return '全部';
                    }
                  },
                  onChanged: (String item) => setState(() => _filter = item),
                ),
                const SizedBox(height: 10),
                if (_error.isNotEmpty) _errorCard(),
                if (visible.isEmpty)
                  TgaEmpty(
                    _tasks.isEmpty
                        ? '还没有定时任务，点右上角「+」新建一个'
                        : '当前筛选下没有任务',
                    icon: Icons.schedule_rounded,
                  )
                else
                  for (final Map<String, dynamic> task in visible)
                    _taskCard(task),
              ],
            ),
    );
  }

  Widget _noticeCard() {
    final DateTime? checked = _lastChecked;
    return TgaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.info_outline_rounded, size: 16, color: Tga.orange),
              const SizedBox(width: 6),
              Text('仅应用在前台时执行', style: Tga.body),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '本页打开且应用处于前台时，每 30 秒检查一次到期任务；'
            '切到后台或退出应用即停止，不会在系统后台唤醒。'
            '任务保存在本机 schedules.json。',
            style: Tga.caption,
          ),
          if (checked != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              '上次检查：${_formatWhen(checked)}',
              style: Tga.caption,
            ),
          ],
        ],
      ),
    );
  }

  Widget _errorCard() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline_rounded, size: 16, color: Tga.red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error,
                style: TextStyle(fontSize: 12, color: Tga.red, height: 1.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _taskCard(Map<String, dynamic> task) {
    final int id = _idOf(task);
    final bool enabled = task['enabled'] == true;
    final String cron = (task['cron'] ?? '').toString();
    final DateTime? next = _parseDate(task['next_run']);
    final DateTime? last = _parseDate(task['last_run']);
    final String result = (task['last_result'] ?? '').toString().trim();
    final String error = (task['last_error'] ?? '').toString().trim();
    final String title = (task['title'] ?? '未命名任务').toString();
    final String prompt = (task['prompt'] ?? '').toString().trim();
    final bool running = _running.contains(id);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: Tga.h2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                TgaTag(_cronLabel(cron), color: Tga.cyan),
                const SizedBox(width: 6),
                TgaTag(
                  enabled ? '已启用' : '已暂停',
                  color: enabled ? Tga.green : Tga.textDim,
                ),
              ],
            ),
            if (prompt.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                prompt,
                style: Tga.sub,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            _infoRow(
              '下次执行',
              enabled
                  ? (next == null ? '未安排' : _formatWhen(next))
                  : '已暂停',
              color: enabled ? Tga.primary : Tga.textDim,
            ),
            const SizedBox(height: 4),
            _infoRow(
              '上次执行',
              last == null ? '尚未执行' : _formatWhen(last),
              color: Tga.textSub,
            ),
            if (running) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: Tga.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('正在执行…', style: Tga.caption),
                ],
              ),
            ] else if (error.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '上次结果：失败 · ${_summarize(error)}',
                style: TextStyle(fontSize: 12, color: Tga.red, height: 1.45),
              ),
            ] else if (result.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '上次结果：$result',
                style: TextStyle(
                  fontSize: 12,
                  color: Tga.textSub,
                  height: 1.45,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                TgaButton(
                  label: '编辑',
                  icon: Icons.edit_outlined,
                  filled: false,
                  onTap: () => unawaited(_editTask(task)),
                ),
                TgaButton(
                  label: enabled ? '暂停' : '启用',
                  icon: enabled
                      ? Icons.pause_circle_outline_rounded
                      : Icons.play_circle_outline_rounded,
                  filled: false,
                  color: enabled ? Tga.orange : Tga.green,
                  onTap: () => unawaited(_toggle(task)),
                ),
                TgaButton(
                  label: '删除',
                  icon: Icons.delete_outline_rounded,
                  filled: false,
                  color: Tga.red,
                  onTap: () => unawaited(_delete(task)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, {required Color color}) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 66,
          child: Text(label, style: Tga.caption),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}
