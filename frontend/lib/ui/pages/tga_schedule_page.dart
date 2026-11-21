import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/routine_service.dart';

/// 新建 / 编辑对话框返回的草稿；不直接落库，保存失败可停留在页面提示。
class _RoutineDraft {
  const _RoutineDraft({
    required this.name,
    required this.prompt,
    required this.crons,
    required this.timezone,
    required this.active,
    required this.preserveSchedule,
  });

  final String name;
  final String prompt;
  final List<String> crons;
  final String timezone;
  final bool active;

  /// 一次性 Routine 的时间表由对话创建，编辑时原样保留。
  final bool preserveSchedule;
}

/// 定时例程页（对照 Rakazo Routines）：
///   * 多时间表（每小时 / 每天 / 工作日 / 每周 / 每月 / 间隔 / 高级 cron）；
///   * 时区（设备本地 / UTC / 固定偏移 / 常用 IANA）；
///   * 每条 Routine 的真实运行历史（状态、耗时、迟到、结果 / 错误）；
///   * 启用 / 暂停 / 立即运行 / 复制 / 删除。
///
/// 所有数据经 `routine` 控制域读写；`next_run_at` 由后端按 cron + 时区计算。
/// 调度仍只随 App 进程存活：内置 TaskScheduler 每 30 秒触发一次到期例程，
/// 页面打开时也会补检；后台被系统杀死后不会执行，界面如实标注。
class TgaSchedulePage extends StatefulWidget {
  const TgaSchedulePage({super.key});

  @override
  State<TgaSchedulePage> createState() => _TgaSchedulePageState();
}

class _TgaSchedulePageState extends State<TgaSchedulePage>
    with WidgetsBindingObserver {
  static const Duration _tickInterval = Duration(seconds: 30);

  final List<Map<String, dynamic>> _routines = <Map<String, dynamic>>[];
  final Set<String> _running = <String>{};

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
      unawaited(_checkDue());
    }
  }

  // ------------------------------------------------------------ 后端调用

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> extra = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final dynamic env = await backend.sendControl('routine', <String, dynamic>{
      'action': action,
      ...extra,
    });
    final dynamic payload = env.payload;
    if (payload is Map) {
      return payload.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      );
    }
    return <String, dynamic>{'ok': false, 'error': '后端返回了非预期结构'};
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await _call('list');
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() {
          _loading = false;
          _error = '${r['error'] ?? '读取 Routine 失败'}';
        });
        return;
      }
      final List<dynamic> items =
          (r['routines'] as List?) ?? const <dynamic>[];
      setState(() {
        _routines
          ..clear()
          ..addAll(items.whereType<Map>().map(
            (Map e) => e.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          ));
        _loading = false;
        _error = '';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取 Routine 失败：$e';
      });
    }
  }

  /// 前台补检：到点则真实执行并刷新列表；后端会再次校验并推进 next_run。
  Future<void> _checkDue() async {
    if (_checking || _loading || !_foreground) return;
    _checking = true;
    try {
      final Map<String, dynamic> due = await _call('due');
      if (due['ok'] == true) {
        final List<dynamic> items =
            (due['due'] as List?) ?? const <dynamic>[];
        for (final dynamic raw in items) {
          if (raw is! Map) continue;
          final String id = '${raw['id'] ?? ''}';
          if (id.isEmpty) continue;
          // 不等待推理完成：后端会先推进 next_run 并检查是否到点，
          // 即使下一轮 tick 也不会重复执行；页面立即刷新显示新的计划时间。
          unawaited(
            _call('run', <String, dynamic>{
              'id': id,
              'scheduled': true,
            }).catchError(
              (Object _) => <String, dynamic>{'ok': false},
            ),
          );
        }
      }
      await _load();
      if (mounted) setState(() => _lastChecked = DateTime.now());
    } on Object {
      // 后端暂不可用：本轮跳过，下个周期重试，不伪造执行。
    } finally {
      _checking = false;
    }
  }

  Future<void> _runNow(Map<String, dynamic> routine) async {
    final String id = '${routine['id'] ?? ''}';
    if (id.isEmpty || _running.contains(id)) return;
    setState(() => _running.add(id));
    try {
      final Map<String, dynamic> r = await _call('run', <String, dynamic>{
        'id': id,
      });
      if (!mounted) return;
      if (r['ok'] == true) {
        if (r['skipped'] == true) {
          _snack('未执行：${r['reason'] ?? '当前不需要运行'}');
        } else {
          _snack('「${routine['name']}」已执行');
        }
      } else {
        _snack('执行失败：${r['error'] ?? '未知错误'}', error: true);
      }
    } finally {
      if (mounted) {
        setState(() => _running.remove(id));
        await _load();
      }
    }
  }

  Future<void> _toggle(Map<String, dynamic> routine) async {
    final bool enabled = routine['active'] != true;
    final Map<String, dynamic> r = await _call('toggle', <String, dynamic>{
      'id': '${routine['id']}',
      'enabled': enabled,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _snack('${r['error'] ?? '切换失败'}', error: true);
      return;
    }
    await _load();
  }

  Future<void> _duplicate(Map<String, dynamic> routine) async {
    final Map<String, dynamic> r = await _call('duplicate', <String, dynamic>{
      'id': '${routine['id']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _snack('${r['error'] ?? '复制失败'}', error: true);
      return;
    }
    await _load();
    _snack('已复制为暂停状态');
  }

  Future<void> _delete(Map<String, dynamic> routine) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return AlertDialog(
          backgroundColor: Tga.card,
          title: Text('删除 Routine', style: Tga.h2),
          content: Text(
            '确定删除「${routine['name']}」？运行历史会一并移除，且不可恢复。',
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
    final Map<String, dynamic> r = await _call('delete', <String, dynamic>{
      'id': '${routine['id']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _snack('${r['error'] ?? '删除失败'}', error: true);
      return;
    }
    await _load();
    _snack('已删除「${routine['name']}」');
  }

  // ------------------------------------------------------------ 编辑流程

  Future<void> _editTask([Map<String, dynamic>? existing]) async {
    final TextEditingController nameCtrl = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    final TextEditingController promptCtrl = TextEditingController(
      text: (existing?['prompt'] ?? '').toString(),
    );
    final TextEditingController timeCtrl = TextEditingController(text: '09:00');
    final TextEditingController cronCtrl = TextEditingController();
    final List<String> crons = existing == null
        ? <String>['0 9 * * *']
        : (existing['crons'] as List? ?? const <dynamic>[])
              .map((dynamic e) => e.toString())
              .toList();
    final bool oneShot = crons.length == 1 && crons.first.trim() == onceCron;
    String timezone = (existing?['timezone'] ?? 'local').toString();
    bool active = existing == null ? true : existing['active'] == true;
    CronFreq freq = CronFreq.daily;
    CronUnit unit = CronUnit.minutes;
    int intervalN = 30;
    String dialogError = '';

    final _RoutineDraft? draft = await showDialog<_RoutineDraft>(
      context: context,
      builder: (BuildContext ctx) {
        return StatefulBuilder(
          builder: (BuildContext ctx, StateSetter setLocal) {
            Tga.syncFrom(ctx);

            void addSchedule() {
              final CronPreset preset;
              switch (freq) {
                case CronFreq.hourly:
                  preset = const CronPreset(freq: CronFreq.hourly);
                case CronFreq.interval:
                  preset = CronPreset(
                    freq: CronFreq.interval,
                    n: intervalN,
                    unit: unit,
                  );
                case CronFreq.advanced:
                  preset = CronPreset(
                    freq: CronFreq.advanced,
                    cron: cronCtrl.text.trim(),
                  );
                default:
                  final RegExpMatch? m =
                      RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(
                    timeCtrl.text.trim(),
                  );
                  if (m == null) {
                    setLocal(() => dialogError = '时间格式应为 HH:mm');
                    return;
                  }
                  final int hour = int.tryParse(m.group(1)!) ?? -1;
                  final int minute = int.tryParse(m.group(2)!) ?? -1;
                  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
                    setLocal(() => dialogError = '时间需在 00:00 - 23:59 之间');
                    return;
                  }
                  preset = CronPreset(
                    freq: freq,
                    hour: hour,
                    minute: minute,
                  );
              }
              final String cron = cronFromPreset(preset);
              if (!CronExpression.isValid(cron)) {
                setLocal(() => dialogError = 'cron 表达式无效：$cron');
                return;
              }
              if (crons.contains(cron)) {
                setLocal(() => dialogError = '这个时间表已经添加过了');
                return;
              }
              setLocal(() {
                crons.add(cron);
                dialogError = '';
              });
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

            Widget scheduleInput() {
              final List<Widget> children = <Widget>[];
              if (freq == CronFreq.interval) {
                children.add(
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: DropdownButton<int>(
                          value: intervalN,
                          isExpanded: true,
                          items: cronIntervalAmounts(unit).map((int n) {
                            return DropdownMenuItem<int>(
                              value: n,
                              child: Text('每 $n'),
                            );
                          }).toList(),
                          onChanged: (int? value) {
                            if (value == null) return;
                            setLocal(() => intervalN = value);
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButton<CronUnit>(
                          value: unit,
                          isExpanded: true,
                          items: CronUnit.values.map((CronUnit u) {
                            return DropdownMenuItem<CronUnit>(
                              value: u,
                              child: Text(_unitLabel(u)),
                            );
                          }).toList(),
                          onChanged: (CronUnit? value) {
                            if (value == null) return;
                            setLocal(() {
                              unit = value;
                              final List<int> allowed =
                                  cronIntervalAmounts(unit);
                              if (!allowed.contains(intervalN)) {
                                intervalN = allowed.first;
                              }
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                );
              } else if (freq == CronFreq.advanced) {
                children.add(
                  field(
                    cronCtrl,
                    'cron 表达式',
                    hint: '分 时 日 月 周，例如 */15 * * * *',
                  ),
                );
              } else if (freq != CronFreq.hourly) {
                children.add(
                  field(
                    timeCtrl,
                    '执行时间',
                    hint: 'HH:mm，例如 09:30',
                    keyboard: TextInputType.datetime,
                  ),
                );
              }
              children.add(const SizedBox(height: 8));
              children.add(
                Align(
                  alignment: Alignment.centerLeft,
                  child: TgaButton(
                    label: '添加时间表',
                    icon: Icons.add_rounded,
                    onTap: addSchedule,
                  ),
                ),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              );
            }

            return AlertDialog(
              backgroundColor: Tga.card,
              title: Text(
                existing == null ? '新建 Routine' : '编辑 Routine',
                style: Tga.h2,
              ),
              content: SizedBox(
                width: 480,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      field(nameCtrl, '名称', hint: '例如：每日简报'),
                      const SizedBox(height: 10),
                      field(
                        promptCtrl,
                        '提示词',
                        hint: '到点后交给 Agent 执行的完整指令',
                        minLines: 3,
                        maxLines: 6,
                      ),
                      const SizedBox(height: 12),
                      Text('时间表', style: Tga.body),
                      const SizedBox(height: 6),
                      if (oneShot)
                        Text(
                          '这是一次性 Routine，运行时刻由创建时的对话确定，'
                          '此处不能修改。',
                          style: Tga.caption,
                        )
                      else ...<Widget>[
                        if (crons.isEmpty)
                          Text('还没有时间表，至少添加一个。', style: Tga.caption)
                        else
                          for (final String cron in crons)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Tga.bgSoft,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        formatCron(cron),
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: Tga.text,
                                        ),
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '移除',
                                    onPressed: () {
                                      setLocal(() {
                                        crons.remove(cron);
                                        dialogError = '';
                                      });
                                    },
                                    icon: Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                      color: Tga.textDim,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        const SizedBox(height: 4),
                        DropdownButton<CronFreq>(
                          value: freq,
                          isExpanded: true,
                          items: const <CronFreq>[
                            CronFreq.hourly,
                            CronFreq.daily,
                            CronFreq.weekdays,
                            CronFreq.weekly,
                            CronFreq.monthly,
                            CronFreq.interval,
                            CronFreq.advanced,
                          ].map((CronFreq f) {
                            return DropdownMenuItem<CronFreq>(
                              value: f,
                              child: Text(_freqLabel(f)),
                            );
                          }).toList(),
                          onChanged: (CronFreq? value) {
                            if (value == null) return;
                            setLocal(() {
                              freq = value;
                              dialogError = '';
                            });
                          },
                        ),
                        const SizedBox(height: 8),
                        scheduleInput(),
                      ],
                      const SizedBox(height: 12),
                      Text('时区', style: Tga.body),
                      const SizedBox(height: 6),
                      DropdownButton<String>(
                        value: RoutineZone.isSupported(timezone)
                            ? timezone
                            : 'local',
                        isExpanded: true,
                        items: <String>[
                          if (RoutineZone.isSupported(timezone) &&
                              !RoutineZone.selectable.contains(timezone))
                            timezone,
                          ...RoutineZone.selectable,
                        ].map((String zone) {
                          return DropdownMenuItem<String>(
                            value: zone,
                            child: Text(_zoneLabel(zone)),
                          );
                        }).toList(),
                        onChanged: (String? value) {
                          if (value == null) return;
                          setLocal(() => timezone = value);
                        },
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '仅 App 进程存活时执行；被系统杀死或强制退出后不会后台唤醒。',
                        style: Tga.caption,
                      ),
                      const SizedBox(height: 4),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('启用', style: Tga.body),
                        value: active,
                        onChanged: (bool value) {
                          setLocal(() => active = value);
                        },
                      ),
                      if (dialogError.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
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
                    if (nameCtrl.text.trim().isEmpty) {
                      setLocal(() => dialogError = '请填写名称');
                      return;
                    }
                    if (promptCtrl.text.trim().isEmpty) {
                      setLocal(() => dialogError = '请填写提示词');
                      return;
                    }
                    if (!oneShot && crons.isEmpty) {
                      setLocal(() => dialogError = '至少添加一个时间表');
                      return;
                    }
                    Navigator.of(ctx).pop(_RoutineDraft(
                      name: nameCtrl.text.trim(),
                      prompt: promptCtrl.text.trim(),
                      crons: List<String>.of(crons),
                      timezone: timezone,
                      active: active,
                      preserveSchedule: oneShot,
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

    nameCtrl.dispose();
    promptCtrl.dispose();
    timeCtrl.dispose();
    cronCtrl.dispose();
    if (draft == null || !mounted) return;

    final Map<String, dynamic> payload = <String, dynamic>{
      'name': draft.name,
      'prompt': draft.prompt,
      'timezone': draft.timezone,
      'active': draft.active,
      if (!draft.preserveSchedule) 'crons': draft.crons,
    };
    final Map<String, dynamic> r = existing == null
        ? await _call('create', payload)
        : await _call('update', <String, dynamic>{
            'id': '${existing['id']}',
            ...payload,
          });
    if (!mounted) return;
    if (r['ok'] != true) {
      _snack('${r['error'] ?? '保存失败'}', error: true);
      return;
    }
    await _load();
    _snack(existing == null ? '已创建 Routine' : '已保存修改');
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

  List<Map<String, dynamic>> get _filtered {
    if (_filter == 'on') {
      return _routines
          .where((Map<String, dynamic> r) => r['active'] == true)
          .toList();
    }
    if (_filter == 'off') {
      return _routines
          .where((Map<String, dynamic> r) => r['active'] != true)
          .toList();
    }
    return _routines;
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final int activeCount =
        _routines.where((Map<String, dynamic> r) => r['active'] == true).length;
    final List<Map<String, dynamic>> visible = _filtered;
    return TgaPage(
      title: '定时',
      actions: <Widget>[
        IconButton(
          tooltip: '立即检查',
          onPressed: _checking ? null : () => unawaited(_checkDue()),
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
        IconButton(
          tooltip: '新建 Routine',
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
                      value: '${_routines.length}',
                      label: 'Routine 总数',
                      color: Tga.primary,
                      icon: Icons.event_note_rounded,
                    ),
                    const SizedBox(width: 10),
                    TgaStatCard(
                      value: '$activeCount',
                      label: '已启用',
                      color: Tga.green,
                      icon: Icons.play_circle_outline_rounded,
                    ),
                  ],
                ),
                TgaGroupTitle(
                  'Routine',
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
                    _routines.isEmpty
                        ? '还没有 Routine，点右上角「+」新建一个'
                        : '当前筛选下没有 Routine',
                    icon: Icons.schedule_rounded,
                  )
                else
                  for (final Map<String, dynamic> routine in visible)
                    _routineCard(routine),
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
              Text('仅 App 进程存活时执行', style: Tga.body),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '内置调度器每 30 秒检查一次到期 Routine；页面打开时也会补检。'
            '应用被系统杀死或强制退出后不会后台唤醒。'
            '数据保存在本机 routines/ 目录。',
            style: Tga.caption,
          ),
          if (checked != null) ...<Widget>[
            const SizedBox(height: 6),
            Text('上次检查：${_formatWhen(checked)}', style: Tga.caption),
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

  Widget _routineCard(Map<String, dynamic> routine) {
    final String id = '${routine['id'] ?? ''}';
    final bool active = routine['active'] == true;
    final List<String> crons = (routine['crons'] as List? ?? const <dynamic>[])
        .map((dynamic e) => e.toString())
        .toList();
    final DateTime? next = DateTime.tryParse('${routine['next_run_at'] ?? ''}');
    final DateTime? last = DateTime.tryParse('${routine['last_run_at'] ?? ''}');
    final String name = (routine['name'] ?? '未命名 Routine').toString();
    final String prompt = (routine['prompt'] ?? '').toString().trim();
    final String timezone = (routine['timezone'] ?? 'local').toString();
    final bool running = _running.contains(id);
    final bool delayed = active &&
        next != null &&
        routineScheduleDelayed(true, next, DateTime.now());
    final bool oneShot = crons.length == 1 && crons.first.trim() == onceCron;

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
                    name,
                    style: Tga.h2,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                TgaTag(
                  oneShot ? '一次性' : _shortSchedule(crons),
                  color: Tga.cyan,
                ),
                const SizedBox(width: 6),
                TgaTag(
                  active ? '已启用' : '已暂停',
                  color: active ? Tga.green : Tga.textDim,
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
            const SizedBox(height: 8),
            Text(
              '${formatCrons(crons)} · ${_zoneLabel(timezone)}',
              style: Tga.caption,
            ),
            const SizedBox(height: 10),
            _infoRow(
              '下次执行',
              !active
                  ? '已暂停'
                  : (next == null ? '未安排' : _formatWhen(next.toLocal())),
              color: delayed
                  ? Tga.orange
                  : (active ? Tga.primary : Tga.textDim),
            ),
            const SizedBox(height: 4),
            _infoRow(
              '上次执行',
              last == null ? '尚未执行' : _formatWhen(last.toLocal()),
              color: Tga.textSub,
            ),
            if (delayed) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '已超过计划时间 5 分钟以上，可能是应用未运行；下次启动会补跑。',
                style: TextStyle(fontSize: 11.5, color: Tga.orange, height: 1.4),
              ),
            ],
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
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                TgaButton(
                  label: '运行',
                  icon: Icons.play_arrow_rounded,
                  onTap: running ? () {} : () => unawaited(_runNow(routine)),
                ),
                TgaButton(
                  label: '历史',
                  icon: Icons.history_rounded,
                  filled: false,
                  onTap: () => unawaited(_openHistory(routine)),
                ),
                TgaButton(
                  label: '编辑',
                  icon: Icons.edit_outlined,
                  filled: false,
                  onTap: () => unawaited(_editTask(routine)),
                ),
                TgaButton(
                  label: active ? '暂停' : '启用',
                  icon: active
                      ? Icons.pause_circle_outline_rounded
                      : Icons.play_circle_outline_rounded,
                  filled: false,
                  color: active ? Tga.orange : Tga.green,
                  onTap: () => unawaited(_toggle(routine)),
                ),
                TgaButton(
                  label: '复制',
                  icon: Icons.copy_rounded,
                  filled: false,
                  onTap: oneShot ? () {} : () => unawaited(_duplicate(routine)),
                ),
                TgaButton(
                  label: '删除',
                  icon: Icons.delete_outline_rounded,
                  filled: false,
                  color: Tga.red,
                  onTap: () => unawaited(_delete(routine)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openHistory(Map<String, dynamic> routine) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _RoutineHistoryPage(
          routineId: '${routine['id']}',
          routineName: '${routine['name'] ?? 'Routine'}',
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, {required Color color}) {
    return Row(
      children: <Widget>[
        SizedBox(width: 66, child: Text(label, style: Tga.caption)),
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

/// 运行历史页：真实分页，不合并、不伪造。
class _RoutineHistoryPage extends StatefulWidget {
  const _RoutineHistoryPage({
    required this.routineId,
    required this.routineName,
  });

  final String routineId;
  final String routineName;

  @override
  State<_RoutineHistoryPage> createState() => _RoutineHistoryPageState();
}

class _RoutineHistoryPageState extends State<_RoutineHistoryPage> {
  final List<Map<String, dynamic>> _runs = <Map<String, dynamic>>[];
  Map<String, dynamic>? _cursor;
  bool _loading = true;
  bool _loadingMore = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> extra = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final dynamic env = await backend.sendControl('routine', <String, dynamic>{
      'action': action,
      'id': widget.routineId,
      ...extra,
    });
    final dynamic payload = env.payload;
    if (payload is Map) {
      return payload.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      );
    }
    return <String, dynamic>{'ok': false, 'error': '后端返回了非预期结构'};
  }

  Future<void> _load({bool more = false}) async {
    if (more) {
      if (_loadingMore || _cursor == null) return;
      setState(() => _loadingMore = true);
    }
    try {
      final Map<String, dynamic> r = await _call('history', <String, dynamic>{
        'limit': 20,
        if (more && _cursor != null) 'before': _cursor,
      });
      if (!mounted) return;
      if (r['ok'] != true) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _error = '${r['error'] ?? '读取运行历史失败'}';
        });
        return;
      }
      final List<dynamic> items =
          (r['runs'] as List?) ?? const <dynamic>[];
      setState(() {
        if (!more) _runs.clear();
        _runs.addAll(items.whereType<Map>().map(
          (Map e) => e.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        ));
        _cursor = r['next_cursor'] is Map
            ? Map<String, dynamic>.from(r['next_cursor'] as Map)
            : null;
        _loading = false;
        _loadingMore = false;
        _error = '';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '读取运行历史失败：$e';
      });
    }
  }

  int get _successCount =>
      _runs.where((Map<String, dynamic> r) => r['status'] == 'success').length;
  int get _failureCount =>
      _runs.where((Map<String, dynamic> r) => r['status'] == 'failure').length;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return TgaPage(
      title: '${widget.routineName} · 运行历史',
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
                12,
                Tga.pagePad,
                40,
              ),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    TgaStatCard(
                      value: '${_runs.length}',
                      label: '已加载',
                      color: Tga.primary,
                      icon: Icons.list_alt_rounded,
                    ),
                    const SizedBox(width: 10),
                    TgaStatCard(
                      value: '$_successCount',
                      label: '成功',
                      color: Tga.green,
                      icon: Icons.check_circle_outline_rounded,
                    ),
                    const SizedBox(width: 10),
                    TgaStatCard(
                      value: '$_failureCount',
                      label: '失败',
                      color: Tga.red,
                      icon: Icons.error_outline_rounded,
                    ),
                  ],
                ),
                if (_error.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  TgaCard(
                    child: Text(
                      _error,
                      style: TextStyle(color: Tga.red, fontSize: 12),
                    ),
                  ),
                ],
                const TgaGroupTitle('运行记录'),
                if (_runs.isEmpty)
                  TgaEmpty('这条 Routine 还没有运行记录', icon: Icons.history_rounded)
                else
                  for (final Map<String, dynamic> run in _runs)
                    _runCard(run),
                if (_cursor != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Center(
                    child: _loadingMore
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Tga.primary,
                            ),
                          )
                        : TgaButton(
                            label: '加载更多',
                            icon: Icons.expand_more_rounded,
                            filled: false,
                            onTap: () => unawaited(_load(more: true)),
                          ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _runCard(Map<String, dynamic> run) {
    final String status = '${run['status'] ?? 'unknown'}';
    final DateTime? created =
        DateTime.tryParse('${run['created_at'] ?? ''}');
    final String duration = '${run['duration_label'] ?? ''}';
    final String late = '${run['late_label'] ?? ''}';
    final String result = '${run['result'] ?? ''}'.trim();
    final String error = '${run['error'] ?? ''}'.trim();
    final Color color = switch (status) {
      'success' => Tga.green,
      'failure' => Tga.red,
      'running' => Tga.primary,
      _ => Tga.textDim,
    };
    final String label = switch (status) {
      'success' => '成功',
      'failure' => '失败',
      'running' => '执行中',
      'skipped' => '已跳过',
      _ => status,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(
                  created == null ? '未知时间' : _formatWhen(created.toLocal()),
                  style: Tga.body,
                ),
                const SizedBox(width: 8),
                TgaTag(label, color: color),
                if (duration.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 6),
                  TgaTag(duration, color: Tga.textSub),
                ],
                if (late.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 6),
                  TgaTag(late, color: Tga.orange),
                ],
              ],
            ),
            if (result.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                result,
                style: TextStyle(fontSize: 12.5, color: Tga.textSub, height: 1.45),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (error.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                error,
                style: TextStyle(fontSize: 12.5, color: Tga.red, height: 1.45),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _freqLabel(CronFreq freq) {
  switch (freq) {
    case CronFreq.hourly:
      return '每小时';
    case CronFreq.daily:
      return '每天';
    case CronFreq.weekdays:
      return '工作日';
    case CronFreq.weekly:
      return '每周一';
    case CronFreq.monthly:
      return '每月 1 日';
    case CronFreq.interval:
      return '间隔';
    case CronFreq.advanced:
      return '高级 cron';
    case CronFreq.once:
      return '一次性';
  }
}

String _unitLabel(CronUnit unit) {
  switch (unit) {
    case CronUnit.minutes:
      return '分钟';
    case CronUnit.hours:
      return '小时';
    case CronUnit.days:
      return '天';
  }
}

String _zoneLabel(String zone) {
  if (zone == 'local') return '设备本地';
  return zone;
}

String _shortSchedule(List<String> crons) {
  if (crons.isEmpty) return '无时间表';
  if (crons.length == 1) return formatCron(crons.first);
  return '${formatCron(crons.first)} 等 ${crons.length} 条';
}

String _formatWhen(DateTime value) {
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
