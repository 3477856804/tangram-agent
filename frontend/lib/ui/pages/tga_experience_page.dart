import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/experience_transfer.dart';
import '../../harness/store.dart';

/// 经验库：真实成功经验沉淀、本地检索、类比迁移与结果回写。
///
/// 只调用 [ExperienceLibrary]：支持手工录入、从成功工单 / 成功工作流运行
/// 导入、BM25 检索、迁移（可注入真实 chat；缺模型时如实标注 heuristic）、
/// 记录真实使用结果。页面不生成任何示例数据。
class TgaExperiencePage extends StatefulWidget {
  const TgaExperiencePage({super.key, this.library, this.chat});

  /// 构造时可注入服务；测试/预览可传自定义实例。
  final ExperienceLibrary? library;

  /// 可选真实推理回调；为空时迁移走确定性 heuristic。
  final ExperienceChat? chat;

  @override
  State<TgaExperiencePage> createState() => _TgaExperiencePageState();
}

class _TgaExperiencePageState extends State<TgaExperiencePage> {
  final TextEditingController _query = TextEditingController();

  ExperienceLibrary? _library;
  ExperienceChat? _chat;
  List<Map<String, dynamic>> _patterns = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _hits = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _busy = false;
  bool _searched = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final BackendClient backend = context.read<BackendClient>();
      final ExperienceLibrary lib =
          widget.library ?? ExperienceLibrary(await HarnessStore.instance());
      final List<Map<String, dynamic>> patterns = await lib.list();
      if (!mounted) return;
      setState(() {
        _library = lib;
        _chat = widget.chat ??
            (Map<String, dynamic> p) => backend.sendControl('chat', p).then(
                (dynamic env) => env.payload is Map
                    ? Map<String, dynamic>.from(env.payload as Map)
                    : <String, dynamic>{'ok': false, 'error': '返回格式异常'});
        _patterns = patterns;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '经验库读取失败：$e';
      });
    }
  }

  Future<void> _refresh() async {
    final ExperienceLibrary? lib = _library;
    if (lib == null) return;
    final List<Map<String, dynamic>> patterns = await lib.list();
    if (!mounted) return;
    setState(() => _patterns = patterns);
    if (_searched) await _search();
  }

  Future<void> _import(String kind) async {
    final ExperienceLibrary? lib = _library;
    if (lib == null || _busy) return;
    setState(() => _busy = true);
    final Map<String, dynamic> r = kind == 'ticket'
        ? await lib.importFromTickets()
        : await lib.importFromRuns();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(r['ok'] == true
        ? '导入 ${r['imported'] ?? 0} 条，跳过 ${r['skipped'] ?? 0} 条'
        : (r['error'] ?? '导入失败').toString());
    await _refresh();
  }

  Future<void> _search() async {
    final ExperienceLibrary? lib = _library;
    if (lib == null) return;
    final String query = _query.text.trim();
    if (query.isEmpty) {
      setState(() {
        _hits = <Map<String, dynamic>>[];
        _searched = false;
      });
      return;
    }
    final List<Map<String, dynamic>> hits = await lib.search(query, 8);
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _searched = true;
    });
  }

  Future<void> _add() async {
    final ExperienceLibrary? lib = _library;
    if (lib == null) return;
    final TextEditingController name = TextEditingController();
    final TextEditingController task = TextEditingController();
    final TextEditingController approach = TextEditingController();
    final TextEditingController tags = TextEditingController();
    final TextEditingController steps = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('录入经验', style: Tga.h2),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: name,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '经验名称'),
              ),
              TextField(
                controller: task,
                minLines: 2,
                maxLines: 4,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '原场景 / 问题'),
              ),
              TextField(
                controller: approach,
                minLines: 3,
                maxLines: 8,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '当时真实有效的方案'),
              ),
              TextField(
                controller: tags,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '标签，用逗号分隔（可选）'),
              ),
              TextField(
                controller: steps,
                minLines: 2,
                maxLines: 6,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '可复用步骤，每行一条（可选）'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final Map<String, dynamic> r = go == true
        ? await lib.addManual(
            name: name.text,
            task: task.text,
            approach: approach.text,
            tags: _split(tags.text, comma: true),
            steps: _split(steps.text),
          )
        : <String, dynamic>{'ok': false, 'error': '已取消'};
    name.dispose();
    task.dispose();
    approach.dispose();
    tags.dispose();
    steps.dispose();
    if (!mounted) return;
    _toast(r['ok'] == true ? '已保存经验' : (r['error'] ?? '保存失败').toString());
    if (r['ok'] == true) await _refresh();
  }

  Future<void> _adapt(Map<String, dynamic> pattern) async {
    final ExperienceLibrary? lib = _library;
    if (lib == null) return;
    final TextEditingController task = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('迁移「${pattern['name']}」', style: Tga.h2),
        content: TextField(
          controller: task,
          minLines: 3,
          maxLines: 8,
          style: TextStyle(color: Tga.text),
          decoration: const InputDecoration(hintText: '输入新任务，生成可复用方案'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('生成迁移方案'),
          ),
        ],
      ),
    );
    final String text = task.text;
    task.dispose();
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    final Map<String, dynamic> r = await lib.adapt(
      (pattern['id'] ?? '').toString(),
      text,
      chat: _chat,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      _toast((r['error'] ?? '迁移失败').toString());
      return;
    }
    await _showAdapt(r);
  }

  Future<void> _showAdapt(Map<String, dynamic> r) async {
    final bool heuristic = (r['engine'] ?? '').toString() == 'heuristic';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Tga.card,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        maxChildSize: 0.94,
        builder: (BuildContext _, ScrollController sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('迁移方案', style: Tga.h1),
                const SizedBox(width: 8),
                TgaTag(
                  heuristic ? 'heuristic' : (r['engine'] ?? 'model').toString(),
                  color: heuristic ? Tga.orange : Tga.green,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '场景相似度 '
              '${(((r['similarity'] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(1)}%'
              '${heuristic ? ' · 本地确定性规则，未调用模型' : ' · 真实模型输出'}',
              style: Tga.caption,
            ),
            if ((r['note'] ?? '').toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text((r['note'] ?? '').toString(),
                    style: Tga.caption.copyWith(color: Tga.orange)),
              ),
            const SizedBox(height: 12),
            SelectableText((r['plan'] ?? '').toString(), style: Tga.body),
            const TgaGroupTitle('迁移检查清单'),
            for (final dynamic item
                in (r['checklist'] is List ? r['checklist'] as List : <dynamic>[]))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.check_circle_outline_rounded,
                        size: 15, color: Tga.primary),
                    const SizedBox(width: 6),
                    Expanded(child: Text(item.toString(), style: Tga.sub)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _record(Map<String, dynamic> pattern) async {
    final ExperienceLibrary? lib = _library;
    if (lib == null) return;
    bool success = true;
    final TextEditingController notes = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('记录「${pattern['name']}」的结果', style: Tga.h2),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: success,
                onChanged: (bool v) => setLocal(() => success = v),
                title: Text(success ? '本次迁移成功' : '本次迁移失败', style: Tga.body),
              ),
              TextField(
                controller: notes,
                minLines: 2,
                maxLines: 5,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '备注（可选）'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('记录'),
            ),
          ],
        ),
      ),
    );
    final Map<String, dynamic> r = go == true
        ? await lib.recordOutcome(
            (pattern['id'] ?? '').toString(), success, notes.text)
        : <String, dynamic>{'ok': false};
    notes.dispose();
    if (!mounted || go != true) return;
    _toast(r['ok'] == true
        ? '已记录：使用 ${r['uses']} 次，成功 ${r['successes']} 次'
        : (r['error'] ?? '记录失败').toString());
    if (r['ok'] == true) await _refresh();
  }

  List<String> _split(String text, {bool comma = false}) {
    final List<String> raw = comma ? text.split(',') : text.split('\n');
    return raw.map((String s) => s.trim()).where((String s) => s.isNotEmpty).toList();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  String _sourceLabel(String source) => switch (source) {
        'ticket' => '成功工单',
        'workflow' => '工作流',
        _ => '手工',
      };

  Color _sourceColor(String source) => switch (source) {
        'ticket' => Tga.green,
        'workflow' => Tga.purple,
        _ => Tga.primary,
      };

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '经验库',
      actions: <Widget>[
        IconButton(
          tooltip: '从成功工单导入',
          onPressed: _loading || _busy ? null : () => _import('ticket'),
          icon: Icon(Icons.confirmation_number_outlined, color: Tga.primary),
        ),
        IconButton(
          tooltip: '从成功工作流导入',
          onPressed: _loading || _busy ? null : () => _import('workflow'),
          icon: Icon(Icons.account_tree_outlined, color: Tga.primary),
        ),
        IconButton(
          tooltip: '手工录入',
          onPressed: _loading || _busy ? null : _add,
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Tga.primary),
              ),
            )
          : ListView(
              padding:
                  const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                if (_error.isNotEmpty)
                  TgaCard(
                    child:
                        Text(_error, style: Tga.sub.copyWith(color: Tga.red)),
                  ),
                TgaCard(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TgaSearchField(
                          hint: '检索经验（问题 / 方案 / 标签）',
                          controller: _query,
                          onChanged: (String value) {
                            if (value.trim().isEmpty) {
                              setState(() {
                                _hits = <Map<String, dynamic>>[];
                                _searched = false;
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      TgaButton(
                        label: '检索',
                        icon: Icons.search_rounded,
                        onTap: _search,
                      ),
                    ],
                  ),
                ),
                if (_searched) ...<Widget>[
                  TgaGroupTitle('检索结果（${_hits.length}）'),
                  if (_hits.isEmpty)
                    TgaCard(
                      child: TgaEmpty('没有真实命中，试试更短的关键词',
                          icon: Icons.search_off_rounded),
                    )
                  else
                    for (final Map<String, dynamic> hit in _hits)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: TgaCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text((hit['name'] ?? '').toString(),
                                        style: Tga.h2),
                                  ),
                                  TgaTag('${hit['score']}'),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text((hit['snippet'] ?? '').toString(),
                                  style: Tga.sub),
                              const SizedBox(height: 6),
                              Text(
                                '来源 ${_sourceLabel((hit['source'] ?? '').toString())}'
                                ' · 使用 ${hit['uses'] ?? 0} 次'
                                ' · 成功率 ${(((hit['success_rate'] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(0)}%',
                                style: Tga.caption,
                              ),
                            ],
                          ),
                        ),
                      ),
                ],
                TgaGroupTitle('经验模式（${_patterns.length}）'),
                if (_patterns.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有经验\n可手工录入，或从成功工单 / 工作流导入',
                      icon: Icons.auto_stories_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> p in _patterns)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text((p['name'] ?? '').toString(),
                                      style: Tga.h2),
                                ),
                                TgaTag(
                                  _sourceLabel((p['source'] ?? '').toString()),
                                  color: _sourceColor(
                                      (p['source'] ?? '').toString()),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              (p['task'] ?? '').toString(),
                              style: Tga.sub,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              (p['approach'] ?? '').toString(),
                              style: Tga.caption,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: <Widget>[
                                Text(
                                  '使用 ${p['uses'] ?? 0} 次 · 成功 ${p['successes'] ?? 0} 次'
                                  ' · ${(((p['success_rate'] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(0)}%',
                                  style: Tga.caption,
                                ),
                                const Spacer(),
                                TgaButton(
                                  label: '迁移',
                                  filled: false,
                                  icon: Icons.compare_arrows_rounded,
                                  onTap: () => _adapt(p),
                                ),
                                const SizedBox(width: 8),
                                TgaButton(
                                  label: '结果',
                                  filled: false,
                                  icon: Icons.fact_check_outlined,
                                  onTap: () => _record(p),
                                ),
                              ],
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
