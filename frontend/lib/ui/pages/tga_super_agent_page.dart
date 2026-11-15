import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../ui/i18n/tga_strings.dart';

/// Super Agent 控制台（Router/Worker 调度层）。
///
/// 全部数据来自后端 `super_agent` 控制域真实返回：status/sources/triggers/
/// decisions/tickets/events/router_context/rules，动作 set_observe/set_policy/
/// inject/watchdog/stop/attach/subagent 均真实执行并把后端返回（含 ok=false
/// 的 error）原样展示在「最近操作」。默认 observe 模式只读、不派发工单，
/// 外部源未配置时如实标注未连接，绝不伪造连接或推理结果。
class TgaSuperAgentPage extends StatefulWidget {
  const TgaSuperAgentPage({super.key});

  @override
  State<TgaSuperAgentPage> createState() => _TgaSuperAgentPageState();
}

class _TgaSuperAgentPageState extends State<TgaSuperAgentPage> {
  static const List<String> _tabs = <String>[
    '概览',
    '事件源与注入',
    '工单',
    '轨迹',
  ];
  static const List<String> _sources = <String>[
    'manual',
    'im',
    'schedule',
    'github',
    'ci',
    'email',
  ];

  String _tab = '概览';
  bool _busy = false;
  String _loadError = '';
  String _lastResult = '';

  Map<String, dynamic> _status = <String, dynamic>{};
  List<Map<String, dynamic>> _sourceStates = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _triggers = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _decisions = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _tickets = <Map<String, dynamic>>[];
  List<dynamic> _events = <dynamic>[];
  List<String> _routerContext = <String>[];
  Map<String, dynamic> _rules = <String, dynamic>{};

  bool _observe = true;
  String _injectSource = 'manual';
  final TextEditingController _injectText = TextEditingController();
  final TextEditingController _injectThread = TextEditingController();
  final TextEditingController _workersCtrl = TextEditingController();
  final TextEditingController _stepsCtrl = TextEditingController();
  final TextEditingController _attachCtrl = TextEditingController();
  final TextEditingController _subagentCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _injectText.dispose();
    _injectThread.dispose();
    _workersCtrl.dispose();
    _stepsCtrl.dispose();
    _attachCtrl.dispose();
    _subagentCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _asMap(dynamic m) => m is Map
      ? m.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v))
      : <String, dynamic>{};

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map<Map<String, dynamic>>((dynamic e) => _asMap(e))
        .toList();
  }

  List<String> _stringList(dynamic raw) => raw is List
      ? raw.map((dynamic e) => e.toString()).toList()
      : <String>[];

  Future<Map<String, dynamic>> _call(
    BackendClient backend,
    String action, [
    Map<String, dynamic> extra = const <String, dynamic>{},
  ]) async {
    final env = await backend.sendControl(
        'super_agent', <String, dynamic>{'action': action, ...extra});
    return _asMap(env.payload);
  }

  String _brief(Map<String, dynamic> p) {
    final String s = p.toString();
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _busy = true);
    final BackendClient backend = context.read<BackendClient>();
    final List<String> errors = <String>[];

    Future<void> load(String label, String action,
        void Function(Map<String, dynamic> ok) apply) async {
      try {
        final Map<String, dynamic> p = await _call(backend, action);
        if (p['ok'] == true) {
          apply(p);
        } else {
          errors.add('$label：${p['error'] ?? '后端返回 ok=false'}');
        }
      } on Object catch (e) {
        errors.add('$label：$e');
      }
    }

    await load('状态', 'status', (Map<String, dynamic> p) {
      _status = p;
      _observe = p['observe'] == true;
      if (_workersCtrl.text.isEmpty) {
        _workersCtrl.text = '${p['max_workers'] ?? 2}';
      }
    });
    await load('事件源', 'sources',
        (Map<String, dynamic> p) => _sourceStates = _mapList(p['sources']));
    await load('触发事件', 'triggers',
        (Map<String, dynamic> p) => _triggers = _mapList(p['triggers']));
    await load('准入决策', 'decisions',
        (Map<String, dynamic> p) => _decisions = _mapList(p['decisions']));
    await load('工单', 'tickets',
        (Map<String, dynamic> p) => _tickets = _mapList(p['tickets']));
    await load('事件流', 'events', (Map<String, dynamic> p) {
      _events = p['events'] is List ? p['events'] as List : <dynamic>[];
    });
    await load('跨源视图', 'router_context',
        (Map<String, dynamic> p) => _routerContext = _stringList(p['context']));
    await load('过滤规则', 'rules',
        (Map<String, dynamic> p) => _rules = _asMap(p['rules']));

    if (!mounted) return;
    setState(() {
      _busy = false;
      _loadError = errors.join('；');
    });
  }

  Future<void> _act(
      String label, String action, Map<String, dynamic> extra) async {
    setState(() => _busy = true);
    final BackendClient backend = context.read<BackendClient>();
    try {
      final Map<String, dynamic> p = await _call(backend, action, extra);
      if (!mounted) return;
      setState(() => _lastResult = '[$label] ${_brief(p)}');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _lastResult = '[$label] 请求失败：$e');
    }
    await _refresh();
  }

  // ---------------------------------------------------------------- 概览

  Widget _metric(String label, String value) => Container(
        width: 108,
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: Tga.bgSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Tga.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(value,
                style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: Tga.primary)),
            const SizedBox(height: 3),
            Text(label, style: Tga.caption, maxLines: 1),
          ],
        ),
      );

  Color _statusColor(String s) => switch (s) {
        'done' => Tga.green,
        'running' => Tga.primary,
        'queued' => Tga.gold,
        'failed' || 'stalled' => Tga.red,
        'stopped' => Tga.textSub,
        _ => Tga.textSub,
      };

  List<Widget> _overviewTab() {
    final Map<String, dynamic> arch = _asMap(_status['architecture']);
    final List<List<String>> metrics = <List<String>>[
      <String>['observe', _observe ? '只读' : '可执行'],
      <String>['运行中 Worker', '${_status['running_workers'] ?? 0}'],
      <String>['最大 Worker', '${_status['max_workers'] ?? 0}'],
      <String>['工单', '${_status['tickets'] ?? 0}'],
      <String>['触发事件', '${_status['triggers'] ?? 0}'],
      <String>['准入决策', '${_status['decisions'] ?? 0}'],
      <String>['事件流', '${_status['events'] ?? 0}'],
      <String>['跨源视图', '${_status['router_context'] ?? 0}'],
    ];
    return <Widget>[
      TgaGroupTitle('Router 状态',
          trailing: TgaTag(
              _status['initialized'] == true ? '已装配' : '未装配',
              color: _status['initialized'] == true ? Tga.green : Tga.red)),
      TgaCard(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          children: <Widget>[
            for (final List<String> m in metrics) _metric(m[0], m[1]),
          ],
        ),
      ),
      TgaGroupTitle('observe 模式（默认只读）：关闭后才会派发工单'),
      TgaCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: <Widget>[
            Icon(Icons.visibility_outlined, size: 18, color: Tga.textSub),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _observe
                    ? '只读观测：记录「会接受什么」，不实际派发任务'
                    : '可执行：两级过滤判定 ACT 后创建工单并异步执行',
                style: Tga.sub,
              ),
            ),
            Switch(
              value: _observe,
              onChanged: (bool v) => unawaited(_act(
                  v ? '开启 observe' : '关闭 observe', 'set_observe',
                  <String, dynamic>{'value': v})),
            ),
          ],
        ),
      ),
      TgaGroupTitle('调度策略（set_policy）'),
      TgaCard(
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _workersCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'max_workers (1-16)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _stepsCtrl,
                    keyboardType: TextInputType.number,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '默认 max_steps (1-20)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                TgaButton(
                  label: '保存策略',
                  onTap: () {
                    final Map<String, dynamic> extra = <String, dynamic>{};
                    final int? w = int.tryParse(_workersCtrl.text.trim());
                    final int? s = int.tryParse(_stepsCtrl.text.trim());
                    if (w != null) extra['max_workers'] = w;
                    if (s != null) extra['default_max_steps'] = s;
                    if (extra.isEmpty) {
                      _toast('请填写至少一个合法数字');
                      return;
                    }
                    unawaited(_act('保存策略', 'set_policy', extra));
                  },
                ),
                const SizedBox(width: 10),
                TgaButton(
                  label: '运行 Watchdog',
                  filled: false,
                  onTap: () => unawaited(_act(
                      'Watchdog 扫描', 'watchdog', const <String, dynamic>{})),
                ),
              ],
            ),
          ],
        ),
      ),
      TgaGroupTitle('架构（Router / Worker）'),
      TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (arch.isEmpty)
              Text('架构说明加载失败（见顶部错误）', style: Tga.sub)
            else
              for (final MapEntry<String, dynamic> e in arch.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 78,
                        child: TgaTag(e.key, color: Tga.primary),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('${e.value}', style: Tga.sub),
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 8),
            Text('两级过滤：程序规则先筛 → 真实推理判断 ACT/IGNORE；'
                '无真实推理引擎时如实降级、不擅自行动。存算分离：执行在内存，'
                '状态落 HarnessStore 可恢复。Mandate 不可扩张、Subscription 按 thread 回原工单。',
                style: Tga.caption),
          ],
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------- 事件源与注入

  List<Widget> _sourcesTab() {
    return <Widget>[
      TgaGroupTitle('事件源（未配置的连接如实标注未连接）',
          trailing: TgaTag('${_sourceStates.length} 个', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _sourceStates.isEmpty
            ? const TgaEmpty('事件源列表为空或加载失败',
                icon: Icons.input_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < _sourceStates.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    TgaIconTile(
                      icon: _sourceStates[i]['connected'] == true
                          ? Icons.link_rounded
                          : Icons.link_off_rounded,
                      iconBg: _sourceStates[i]['connected'] == true
                          ? Tga.iconGreenBg
                          : Tga.iconRedBg,
                      iconColor: _sourceStates[i]['connected'] == true
                          ? Tga.iconGreen
                          : Tga.iconRed,
                      title: '${_sourceStates[i]['id'] ?? ''} '
                          '(${_sourceStates[i]['kind'] ?? ''})',
                      subtitle: '${_sourceStates[i]['note'] ?? ''} · '
                          '已接收 ${_sourceStates[i]['received'] ?? 0} · '
                          '读取位 ${_sourceStates[i]['read_position'] ?? 0}',
                      showArrow: false,
                      trailing: TgaTag(
                          _sourceStates[i]['connected'] == true
                              ? '已连接'
                              : '未连接',
                          color: _sourceStates[i]['connected'] == true
                              ? Tga.green
                              : Tga.textSub),
                    ),
                  ],
                ],
              ),
      ),
      TgaGroupTitle('注入一个环境事件（走真实两级过滤）'),
      TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Text('来源', style: TextStyle(fontSize: 12)),
                const SizedBox(width: 10),
                DropdownButton<String>(
                  value: _injectSource,
                  style: TextStyle(fontSize: 13, color: Tga.text),
                  items: <DropdownMenuItem<String>>[
                    for (final String s in _sources)
                      DropdownMenuItem<String>(value: s, child: Text(s)),
                  ],
                  onChanged: (String? v) =>
                      setState(() => _injectSource = v ?? 'manual'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _injectThread,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'thread（可空）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _injectText,
              maxLines: 3,
              style: TextStyle(fontSize: 13, color: Tga.text),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '如：请修复登录页的空指针异常',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TgaButton(
              label: '注入事件',
              onTap: () {
                final String text = _injectText.text.trim();
                if (text.isEmpty) {
                  _toast('事件内容不能为空');
                  return;
                }
                unawaited(_act('注入事件', 'inject', <String, dynamic>{
                  'text': text,
                  'source': _injectSource,
                  'thread': _injectThread.text.trim(),
                }));
              },
            ),
          ],
        ),
      ),
      TgaGroupTitle('最近触发事件（Trigger）',
          trailing: TgaTag('${_triggers.length} 条', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _triggers.isEmpty
            ? const TgaEmpty('暂无触发事件', icon: Icons.bolt_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < _triggers.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    _triggerTile(_triggers[i]),
                  ],
                ],
              ),
      ),
      TgaGroupTitle('准入决策（两级过滤结果）',
          trailing: TgaTag('${_decisions.length} 条', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _decisions.isEmpty
            ? const TgaEmpty('暂无准入决策', icon: Icons.filter_alt_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < _decisions.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    _decisionTile(_decisions[i]),
                  ],
                ],
              ),
      ),
      TgaGroupTitle('一级程序过滤规则（真实 rules）'),
      TgaCard(
        child: _rules.isEmpty
            ? Text('规则为空或加载失败', style: Tga.sub)
            : SelectableText(_rules.toString(),
                style: TextStyle(
                    fontSize: 12, fontFamily: 'monospace', color: Tga.text)),
      ),
    ];
  }

  Widget _triggerTile(Map<String, dynamic> t) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TgaTag('${t['source'] ?? ''}', color: Tga.purple),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('${t['text'] ?? ''}',
                      style: Tga.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text('${t['id'] ?? ''} · ${t['kind'] ?? ''} · '
                      'thread ${(t['thread'] ?? '').toString().isEmpty ? '—' : t['thread']} · '
                      '${t['ts'] ?? ''}',
                      style: Tga.caption),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _decisionTile(Map<String, dynamic> d) {
    final String decision = (d['decision'] ?? '').toString();
    final Color c = decision == 'accept_new_ticket'
        ? Tga.green
        : decision == 'observe_only'
            ? Tga.primary
            : decision == 'attach'
                ? Tga.gold
                : Tga.textSub;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TgaTag(decision, color: c),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('一级 ${d['stage1'] ?? ''}（${d['stage1_rule'] ?? ''}） · '
                    '二级 ${d['stage2'] ?? ''}',
                    style: Tga.sub),
                const SizedBox(height: 2),
                Text('${d['stage2_reason'] ?? ''} · '
                    '工单 ${(d['ticket_id'] ?? '').toString().isEmpty ? '—' : d['ticket_id']} · '
                    '${d['ts'] ?? ''}',
                    style: Tga.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 工单

  List<Widget> _ticketsTab() {
    return <Widget>[
      TgaGroupTitle('工单看板（Ticket / Mandate）',
          trailing: TgaTag('${_tickets.length} 个', color: Tga.textSub)),
      if (_tickets.isEmpty)
        const TgaCard(
          child: TgaEmpty('暂无工单：observe 只读模式或未通过准入过滤',
              icon: Icons.assignment_outlined),
        )
      else
        for (final Map<String, dynamic> t in _tickets) _ticketCard(t),
    ];
  }

  Widget _ticketCard(Map<String, dynamic> t) {
    final String id = (t['id'] ?? '').toString();
    final String status = (t['status'] ?? '').toString();
    final Map<String, dynamic> mandate = _asMap(t['mandate']);
    final List<String> history = _stringList(t['history']);
    final List<String> notes = _stringList(t['watchdog_notes']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text('${t['goal'] ?? ''}',
                      style: Tga.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                TgaTag(status, color: _statusColor(status)),
              ],
            ),
            const SizedBox(height: 6),
            Text('$id · 来源 ${t['source'] ?? ''} · thread ${t['thread'] ?? '—'} · '
                'steps ${t['steps'] ?? 0} · engine ${t['engine'] ?? '—'}',
                style: Tga.caption),
            const SizedBox(height: 4),
            Text('Mandate：${mandate['scope'] ?? ''} · '
                'max_steps ${mandate['max_steps'] ?? '—'} · '
                'deadline ${mandate['deadline_seconds'] ?? '—'}s',
                style: Tga.caption),
            const SizedBox(height: 4),
            Text('独立上下文 ${t['worker_session'] ?? '—'} · '
                '工作目录 ${t['work_dir'] ?? '—'}',
                style: Tga.caption),
            if ((t['result'] ?? '').toString().isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('结果：${t['result']}',
                  style: Tga.sub, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
            if (history.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('轨迹 ${history.length} 步：${history.last}',
                  style: Tga.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
            ],
            if (notes.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('Watchdog：${notes.join('；')}',
                  style: TextStyle(fontSize: 11, color: Tga.red)),
            ],
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                TgaButton(
                  label: '停止',
                  filled: false,
                  color: Tga.red,
                  onTap: () => unawaited(_act('停止 $id', 'stop',
                      <String, dynamic>{'id': id})),
                ),
                const SizedBox(width: 8),
                TgaButton(
                  label: '人工跟进',
                  filled: false,
                  onTap: () => unawaited(_showAttach(id)),
                ),
                const SizedBox(width: 8),
                TgaButton(
                  label: '派生子任务',
                  filled: false,
                  onTap: () => unawaited(_showSubagent(id)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAttach(String id) async {
    _attachCtrl.clear();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _textDialog(
        ctx,
        '人工跟进 $id',
        '把跟进内容追加进工单轨迹（attach，真实落盘）',
        _attachCtrl,
      ),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;
    await _act('跟进 $id', 'attach',
        <String, dynamic>{'id': id, 'text': text.trim()});
  }

  Future<void> _showSubagent(String id) async {
    _subagentCtrl.clear();
    final String? goal = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _textDialog(
        ctx,
        '派生子任务 $id',
        '子工单沿用父 Mandate 范围且步数不扩张（subagent）',
        _subagentCtrl,
      ),
    );
    if (goal == null || goal.trim().isEmpty || !mounted) return;
    await _act('派生子任务 $id', 'subagent',
        <String, dynamic>{'id': id, 'goal': goal.trim()});
  }

  Widget _textDialog(BuildContext ctx, String title, String hint,
      TextEditingController ctrl) {
    Tga.syncFrom(ctx);
    return AlertDialog(
      backgroundColor: Tga.card,
      title: Text(title, style: Tga.h2),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(hint, style: Tga.caption),
          const SizedBox(height: 10),
          TextField(
            controller: ctrl,
            maxLines: 3,
            style: TextStyle(fontSize: 13, color: Tga.text),
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Tga.primary, foregroundColor: Tga.onPrimary),
          onPressed: () => Navigator.pop(ctx, ctrl.text),
          child: const Text('确定'),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 轨迹

  List<Widget> _trajectoryTab() {
    return <Widget>[
      TgaGroupTitle('Router 跨源视图',
          trailing: TgaTag('${_routerContext.length} 条', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _routerContext.isEmpty
            ? const TgaEmpty('跨源视图为空', icon: Icons.hub_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < _routerContext.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(_routerContext[i], style: Tga.sub),
                      ),
                    ),
                  ],
                ],
              ),
      ),
      TgaGroupTitle('事件流（append-only，真实日志）',
          trailing: TgaTag('${_events.length} 条', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _events.isEmpty
            ? const TgaEmpty('暂无事件', icon: Icons.timeline_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < _events.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          _events[i].toString(),
                          style: TextStyle(
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              color: Tga.text),
                          maxLines: 3,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    ];
  }

  List<Widget> _lastResultCard() {
    if (_lastResult.isEmpty) return <Widget>[];
    return <Widget>[
      TgaGroupTitle('最近操作（真实后端返回）'),
      TgaCard(
        child: SelectableText(_lastResult,
            style: TextStyle(
                fontSize: 12, fontFamily: 'monospace', color: Tga.text)),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return TgaPage(
      title: context.t('superAgent.title'),
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.groupTitle),
          onPressed: _busy ? null : () => unawaited(_refresh()),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
        children: <Widget>[
          TgaSegmented<String>(
            items: _tabs,
            value: _tab,
            labelOf: (String s) => s,
            onChanged: (String v) => setState(() => _tab = v),
          ),
          const SizedBox(height: 12),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_loadError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TgaCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.error_outline_rounded, size: 16, color: Tga.red),
                    const SizedBox(width: 8),
                    Expanded(child: Text('加载异常：$_loadError', style: Tga.sub)),
                  ],
                ),
              ),
            ),
          ...switch (_tab) {
            '事件源与注入' => _sourcesTab(),
            '工单' => _ticketsTab(),
            '轨迹' => _trajectoryTab(),
            _ => _overviewTab(),
          },
          ..._lastResultCard(),
        ],
      ),
    );
  }
}
