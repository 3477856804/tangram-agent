import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 自动化工作流：可视化步骤编排 + 真实执行 + 批量输入 + 每日定时触发。
///
/// 步骤类型：
///  * 对话：走当前模型推理；
///  * 命令：走当前沙箱真实 shell（退出码非 0 判失败）；
///  * 知识库：检索私有知识库并注入上下文。
/// 步骤输出用 `{{变量名}}` 在后续步骤引用，`save_as` 保存输出。
class TgaWorkflowPage extends StatefulWidget {
  const TgaWorkflowPage({super.key});

  @override
  State<TgaWorkflowPage> createState() => _TgaWorkflowPageState();
}

class _TgaWorkflowPageState extends State<TgaWorkflowPage> {
  List<Map<String, dynamic>> _workflows = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _templates = <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('workflow', <String, dynamic>{
      'action': action,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await _call('list');
      if (!mounted) return;
      setState(() {
        _workflows = (r['workflows'] is List ? r['workflows'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _templates = (r['templates'] is List ? r['templates'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('工作流读取失败：$e');
    }
  }

  Future<void> _openEditor([Map<String, dynamic>? wf]) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (BuildContext _) => _WorkflowEditorPage(workflow: wf),
      ),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(Map<String, dynamic> wf) async {
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('删除工作流「${wf['name']}」？', style: Tga.h2),
            content: Text('仅删除定义，历史运行记录保留。', style: Tga.body),
            actions: <Widget>[
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text('取消', style: TextStyle(color: Tga.textSub))),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text('删除', style: TextStyle(color: Tga.red))),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await _call('delete', <String, dynamic>{'id': wf['id']});
    await _load();
  }

  Future<void> _run(Map<String, dynamic> wf) async {
    final TextEditingController input = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('运行「${wf['name']}」', style: Tga.h2),
        content: TextField(
          controller: input,
          minLines: 3,
          maxLines: 8,
          style: TextStyle(color: Tga.text),
          decoration: const InputDecoration(
            hintText: '输入参数（可选，步骤里用 {{input}} 引用）。'
                '多行会按行批量运行。',
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('运行')),
        ],
      ),
    );
    if (go != true) {
      input.dispose();
      return;
    }
    final String text = input.text.trim();
    input.dispose();
    _toast('正在运行…');
    final Map<String, dynamic> r;
    if (text.contains('\n')) {
      final List<String> inputs = text
          .split('\n')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .toList();
      r = await _call('batch', <String, dynamic>{'id': wf['id'], 'inputs': inputs});
    } else {
      r = await _call('run', <String, dynamic>{'id': wf['id'], 'input': text});
    }
    if (!mounted) return;
    await _load();
    await _showRunResult(r);
  }

  Future<void> _showRunResult(Map<String, dynamic> r) async {
    final List<Map<String, dynamic>> runs = <Map<String, dynamic>>[];
    if (r['run'] is Map) {
      runs.add(Map<String, dynamic>.from(r['run'] as Map));
    }
    if (r['runs'] is List) {
      for (final dynamic e in r['runs'] as List) {
        if (e is Map && e['run'] is Map) {
          runs.add(Map<String, dynamic>.from(e['run'] as Map));
        }
      }
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Tga.card,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.94,
        builder: (BuildContext _, ScrollController sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(r['ok'] == true ? '运行完成' : '运行结果', style: Tga.h1),
            if (r['error'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(r['error'].toString(),
                    style: Tga.sub.copyWith(color: Tga.red)),
              ),
            if (runs.isEmpty)
              Text('没有返回运行记录', style: Tga.sub)
            else
              for (final Map<String, dynamic> run in runs) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  '${run['workflow_name'] ?? ''} · ${run['status'] ?? ''}',
                  style: Tga.h2,
                ),
                for (final dynamic raw in (run['outputs'] is List
                    ? run['outputs'] as List
                    : <dynamic>[]))
                  if (raw is Map)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Tga.bgSoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                raw['ok'] == true
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.error_outline_rounded,
                                size: 15,
                                color: raw['ok'] == true ? Tga.green : Tga.red,
                              ),
                              const SizedBox(width: 6),
                              Text('${raw['step'] ?? ''} · ${raw['type'] ?? ''}',
                                  style: Tga.sub.copyWith(fontWeight: FontWeight.w600)),
                              const Spacer(),
                              Text('${raw['ms'] ?? 0}ms', style: Tga.caption),
                            ],
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            (raw['output'] ?? '').toString(),
                            style: Tga.body,
                          ),
                        ],
                      ),
                    ),
              ],
          ],
        ),
      ),
    );
  }

  Future<void> _showRuns() async {
    final Map<String, dynamic> r = await _call('runs');
    if (!mounted) return;
    final List<dynamic> runs =
        r['runs'] is List ? r['runs'] as List : <dynamic>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Tga.card,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.94,
        builder: (BuildContext _, ScrollController sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text('运行记录', style: Tga.h1),
            if (runs.isEmpty)
              TgaEmpty('还没有运行记录', icon: Icons.history_rounded)
            else
              for (final dynamic raw in runs)
                if (raw is Map)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      raw['status'] == 'done'
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      color: raw['status'] == 'done' ? Tga.green : Tga.red,
                    ),
                    title: Text('${raw['workflow_name'] ?? ''}', style: Tga.body),
                    subtitle: Text(
                      '${(raw['started_at'] ?? '').toString().replaceFirst('T', ' ').split('.').first}'
                      ' · ${(raw['outputs'] is List) ? (raw['outputs'] as List).length : 0} 步'
                      '${(raw['error'] ?? '').toString().isEmpty ? '' : ' · ${raw['error']}'}',
                      style: Tga.caption,
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Future<void> _importJson() async {
    final TextEditingController ctrl = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('导入工作流 JSON', style: Tga.h2),
        content: TextField(
          controller: ctrl,
          minLines: 6,
          maxLines: 14,
          style: TextStyle(color: Tga.text, fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(hintText: '{ "name": "...", "steps": [...] }'),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('导入')),
        ],
      ),
    );
    if (go != true) {
      ctrl.dispose();
      return;
    }
    final Map<String, dynamic> r =
        await _call('import', <String, dynamic>{'json': ctrl.text});
    ctrl.dispose();
    if (!mounted) return;
    _toast(r['ok'] == true ? '已导入' : (r['error'] ?? '导入失败').toString());
    await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '自动化工作流',
      actions: <Widget>[
        IconButton(
          tooltip: '运行记录',
          onPressed: _loading ? null : _showRuns,
          icon: Icon(Icons.history_rounded, color: Tga.primary),
        ),
        IconButton(
          tooltip: '导入 JSON',
          onPressed: _loading ? null : _importJson,
          icon: Icon(Icons.file_download_outlined, color: Tga.primary),
        ),
        IconButton(
          tooltip: '新建工作流',
          onPressed: _loading ? null : () => _openEditor(),
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Tga.primary)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaGroupTitle('我的工作流（${_workflows.length}）'),
                if (_workflows.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有工作流\n可新建，或从下方模板一键创建',
                      icon: Icons.account_tree_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> wf in _workflows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: Tga.iconPurpleBg,
                                    borderRadius: BorderRadius.circular(11),
                                  ),
                                  child: Icon(Icons.account_tree_rounded,
                                      size: 18, color: Tga.iconPurple),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(wf['name'].toString(), style: Tga.h2),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${(wf['steps'] is List) ? (wf['steps'] as List).length : 0} 步'
                                        '${(wf['description'] ?? '').toString().isEmpty ? '' : ' · ${wf['description']}'}'
                                        '${(wf['triggers'] is Map && (wf['triggers'] as Map)['schedule'] != null && (wf['triggers'] as Map)['schedule'].toString().isNotEmpty) ? ' · 每日 ${(wf['triggers'] as Map)['schedule']}' : ''}',
                                        style: Tga.caption,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  color: Tga.card,
                                  onSelected: (String v) {
                                    if (v == 'edit') _openEditor(wf);
                                    if (v == 'delete') _delete(wf);
                                  },
                                  itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                                    PopupMenuItem<String>(
                                        value: 'edit',
                                        child: Text('编辑', style: TextStyle(color: Tga.text))),
                                    PopupMenuItem<String>(
                                        value: 'delete',
                                        child: Text('删除', style: TextStyle(color: Tga.red))),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: <Widget>[
                                Text(
                                  (wf['last_run_at'] ?? '').toString().isEmpty
                                      ? '尚未运行'
                                      : '最近：${wf['last_run_at'].toString().replaceFirst('T', ' ').split('.').first}'
                                          ' · ${wf['last_status'] ?? ''}',
                                  style: Tga.caption,
                                ),
                                const Spacer(),
                                TgaButton(
                                  label: '运行',
                                  icon: Icons.play_arrow_rounded,
                                  onTap: () => _run(wf),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                TgaGroupTitle('模板'),
                for (final Map<String, dynamic> t in _templates)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TgaCard(
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.auto_awesome_outlined,
                              size: 19, color: Tga.primary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(t['name'].toString(), style: Tga.h2),
                                Text(t['description'].toString(), style: Tga.caption),
                              ],
                            ),
                          ),
                          TgaButton(
                            label: '使用',
                            filled: false,
                            onTap: () => _openEditor(<String, dynamic>{
                              'name': t['name'],
                              'description': t['description'],
                              'steps': t['steps'],
                              'triggers': <String, dynamic>{'manual': true, 'schedule': ''},
                            }),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _WorkflowEditorPage extends StatefulWidget {
  const _WorkflowEditorPage({this.workflow});

  final Map<String, dynamic>? workflow;

  @override
  State<_WorkflowEditorPage> createState() => _WorkflowEditorPageState();
}

class _WorkflowEditorPageState extends State<_WorkflowEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _schedule;
  final List<Map<String, dynamic>> _steps = <Map<String, dynamic>>[];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? w = widget.workflow;
    _name = TextEditingController(text: (w?['name'] ?? '').toString());
    _desc = TextEditingController(text: (w?['description'] ?? '').toString());
    final Map<String, dynamic> triggers =
        (w?['triggers'] is Map) ? Map<String, dynamic>.from(w!['triggers'] as Map) : <String, dynamic>{};
    _schedule =
        TextEditingController(text: (triggers['schedule'] ?? '').toString());
    final dynamic steps = w?['steps'];
    if (steps is List && steps.isNotEmpty) {
      for (final dynamic s in steps) {
        if (s is Map) {
          _steps.add(<String, dynamic>{
            'name': (s['name'] ?? '步骤').toString(),
            'type': (s['type'] ?? 'prompt').toString(),
            'input': (s['input'] ?? '').toString(),
            'save_as': (s['save_as'] ?? '').toString(),
            'continue_on_error': s['continue_on_error'] == true,
          });
        }
      }
    } else {
      _steps.add(<String, dynamic>{
        'name': '对话',
        'type': 'prompt',
        'input': '{{input}}',
        'save_as': '',
        'continue_on_error': false,
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _schedule.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('workflow', <String, dynamic>{
      'action': action,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final Map<String, dynamic> r = await _call('save', <String, dynamic>{
      'workflow': <String, dynamic>{
        'id': widget.workflow?['id'] ?? '',
        'name': _name.text.trim(),
        'description': _desc.text.trim(),
        'steps': _steps,
        'triggers': <String, dynamic>{
          'manual': true,
          'schedule': _schedule.text.trim(),
        },
      },
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (r['ok'] == true) {
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text((r['error'] ?? '保存失败').toString())));
    }
  }

  void _addStep() {
    setState(() {
      _steps.add(<String, dynamic>{
        'name': '第 ${_steps.length + 1} 步',
        'type': 'prompt',
        'input': '',
        'save_as': '',
        'continue_on_error': false,
      });
    });
  }

  void _move(int index, int delta) {
    final int to = index + delta;
    if (to < 0 || to >= _steps.length) return;
    setState(() {
      final Map<String, dynamic> s = _steps.removeAt(index);
      _steps.insert(to, s);
    });
  }

  Future<void> _editStep(int index) async {
    final Map<String, dynamic> step = _steps[index];
    final TextEditingController name =
        TextEditingController(text: step['name'].toString());
    final TextEditingController input =
        TextEditingController(text: step['input'].toString());
    final TextEditingController saveAs =
        TextEditingController(text: step['save_as'].toString());
    String type = step['type'].toString();
    bool cont = step['continue_on_error'] == true;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('编辑步骤 ${index + 1}', style: Tga.h2),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: name,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '步骤名称'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: type,
                  dropdownColor: Tga.card,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(labelText: '类型'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(value: 'prompt', child: Text('对话推理')),
                    DropdownMenuItem<String>(value: 'shell', child: Text('沙箱命令')),
                    DropdownMenuItem<String>(value: 'knowledge', child: Text('知识库检索')),
                  ],
                  onChanged: (String? v) => setLocal(() => type = v ?? 'prompt'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: input,
                  minLines: 3,
                  maxLines: 8,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                    hintText: '内容。可用 {{input}}、{{上一步save_as}} 引用变量',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: saveAs,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '保存为变量名（可选）'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: cont,
                  onChanged: (bool v) => setLocal(() => cont = v),
                  title: Text('失败也继续后续步骤', style: Tga.body),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('取消', style: TextStyle(color: Tga.textSub))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true), child: const Text('保存')),
          ],
        ),
      ),
    );
    if (ok == true) {
      setState(() {
        step['name'] = name.text.trim().isEmpty ? '步骤 ${index + 1}' : name.text.trim();
        step['type'] = type;
        step['input'] = input.text;
        step['save_as'] = saveAs.text.trim();
        step['continue_on_error'] = cont;
      });
    }
    name.dispose();
    input.dispose();
    saveAs.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: widget.workflow == null ? '新建工作流' : '编辑工作流',
      actions: <Widget>[
        IconButton(
          onPressed: _saving ? null : _save,
          tooltip: '保存',
          icon: _saving
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Tga.primary))
              : Icon(Icons.check_rounded, color: Tga.primary),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          TgaCard(
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _name,
                  style: TextStyle(color: Tga.text, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(hintText: '工作流名称'),
                ),
                TextField(
                  controller: _desc,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '用途说明（可选）'),
                ),
                TextField(
                  controller: _schedule,
                  style: TextStyle(color: Tga.text),
                  keyboardType: TextInputType.datetime,
                  decoration: const InputDecoration(
                    hintText: '每日定时 HH:mm（可选，留空仅手动运行）',
                  ),
                ),
              ],
            ),
          ),
          TgaGroupTitle('步骤（${_steps.length}）', trailing: TextButton(
            onPressed: _addStep,
            child: Text('+ 添加步骤', style: TextStyle(color: Tga.primary, fontSize: 12)),
          )),
          for (int i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TgaCard(
                onTap: () => _editStep(i),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Tga.iconBlueBg,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      alignment: Alignment.center,
                      child: Text('${i + 1}',
                          style: TextStyle(
                              color: Tga.iconBlue, fontWeight: FontWeight.w700)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '${_steps[i]['name']} · ${_typeLabel(_steps[i]['type'].toString())}',
                            style: Tga.body,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _steps[i]['input'].toString().replaceAll('\n', ' '),
                            style: Tga.caption,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.arrow_upward_rounded, size: 17, color: Tga.textSub),
                      onPressed: i == 0 ? null : () => _move(i, -1),
                    ),
                    IconButton(
                      icon: Icon(Icons.arrow_downward_rounded, size: 17, color: Tga.textSub),
                      onPressed: i == _steps.length - 1 ? null : () => _move(i, 1),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline_rounded, size: 17, color: Tga.red),
                      onPressed: _steps.length <= 1
                          ? null
                          : () => setState(() => _steps.removeAt(i)),
                    ),
                  ],
                ),
              ),
            ),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('变量与批量', style: Tga.h2),
                const SizedBox(height: 4),
                Text(
                  '· 运行时可填一个参数，步骤中用 {{input}} 引用；\n'
                  '· 多行输入会按行批量运行；\n'
                  '· 任一步设置「保存为变量」，后续步骤可用 {{变量名}} 引用；\n'
                  '· 填了每日时间后，由前台调度器到点真实执行。',
                  style: Tga.sub,
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    TgaButton(
                      label: '复制 JSON',
                      filled: false,
                      icon: Icons.copy_rounded,
                      onTap: () {
                        Clipboard.setData(ClipboardData(
                            text: const JsonEncoder.withIndent('  ').convert(
                          <String, dynamic>{
                            'name': _name.text.trim(),
                            'description': _desc.text.trim(),
                            'steps': _steps,
                            'triggers': <String, dynamic>{
                              'manual': true,
                              'schedule': _schedule.text.trim(),
                            },
                          },
                        )));
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制工作流 JSON')));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _typeLabel(String type) => switch (type) {
        'shell' => '沙箱命令',
        'knowledge' => '知识库',
        _ => '对话推理',
      };
}
