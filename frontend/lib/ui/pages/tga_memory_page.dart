import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 记忆：三层记忆的可见管理面。
///
/// * 会话要点（短期）：开关是否从对话学习；可按会话查看 / 清空。
/// * 事实库（长期）：只有显式保存才写入；支持搜索 / 删除 / 共享标记。
/// * 所有写入都真实落盘；凭据类内容会被后端拒绝。
class TgaMemoryPage extends StatefulWidget {
  const TgaMemoryPage({super.key});

  @override
  State<TgaMemoryPage> createState() => _TgaMemoryPageState();
}

class _TgaMemoryPageState extends State<TgaMemoryPage> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _session = TextEditingController(text: 'default');
  List<Map<String, dynamic>> _facts = <Map<String, dynamic>>[];
  List<String> _points = <String>[];
  Map<String, dynamic> _stats = <String, dynamic>{};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _session.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('memory', <String, dynamic>{
      'action': action,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    final Map<String, dynamic> status = await _call('status');
    final Map<String, dynamic> facts = await _call('facts');
    final Map<String, dynamic> summary = await _call('summary', <String, dynamic>{
      'session': _session.text.trim().isEmpty ? 'default' : _session.text.trim(),
    });
    if (!mounted) return;
    setState(() {
      _stats = status;
      _facts = (facts['facts'] is List ? facts['facts'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
      _points = (summary['points'] is List ? summary['points'] as List : <dynamic>[])
          .map((dynamic e) => '$e')
          .toList();
      _loading = false;
    });
  }

  Future<void> _searchFacts() async {
    final String q = _search.text.trim();
    final Map<String, dynamic> r = q.isEmpty
        ? await _call('facts')
        : await _call('search', <String, dynamic>{'query': q});
    if (!mounted) return;
    setState(() {
      _facts = (r['facts'] is List ? r['facts'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
    });
  }

  Future<void> _toggle(String key, bool value) async {
    final Map<String, dynamic> r = await _call(key, <String, dynamic>{
      'enabled': value,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '设置失败'}');
      return;
    }
    setState(() => _stats = <String, dynamic>{..._stats, ...r});
  }

  Future<void> _add() async {
    final TextEditingController text = TextEditingController();
    final TextEditingController source = TextEditingController(text: '手动');
    final TextEditingController tags = TextEditingController();
    bool shared = false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('记住一条事实', style: Tga.h2),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: text,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 6,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '要长期记住的事实'),
                ),
                TextField(
                  controller: source,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(labelText: '来源'),
                ),
                TextField(
                  controller: tags,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                    labelText: '标签（逗号分隔，可选）',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: Tga.primary,
                  value: shared,
                  title: Text('共享给其它 bot', style: Tga.body),
                  subtitle: Text('默认 private；开启后记为 shared', style: Tga.caption),
                  onChanged: (bool v) => setLocal(() => shared = v),
                ),
                Text('包含凭据/密钥的内容会被拒绝保存。', style: Tga.caption),
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
      ),
    );
    final String body = text.text.trim();
    final String src = source.text.trim();
    final List<String> tagList = tags.text
        .split(RegExp(r'[,，\s]+'))
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();
    text.dispose();
    source.dispose();
    tags.dispose();
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('save', <String, dynamic>{
      'text': body,
      'source': src,
      'tags': tagList,
      'shared': shared,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '保存失败'}');
      return;
    }
    await _load();
  }

  Future<void> _forget(Map<String, dynamic> fact) async {
    final Map<String, dynamic> r = await _call('forget', <String, dynamic>{
      'id': '${fact['id']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '删除失败'}');
      return;
    }
    await _load();
  }

  Future<void> _loadSummary() async {
    final String session = _session.text.trim().isEmpty
        ? 'default'
        : _session.text.trim();
    final Map<String, dynamic> r =
        await _call('summary', <String, dynamic>{'session': session});
    if (!mounted) return;
    setState(() {
      _points = (r['points'] is List ? r['points'] as List : <dynamic>[])
          .map((dynamic e) => '$e')
          .toList();
    });
  }

  Future<void> _clearSummary() async {
    final String session = _session.text.trim().isEmpty
        ? 'default'
        : _session.text.trim();
    final Map<String, dynamic> r =
        await _call('clear_summary', <String, dynamic>{'session': session});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '清空失败'}');
      return;
    }
    setState(() => _points = <String>[]);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '记忆',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _add,
          tooltip: '记住一条事实',
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Tga.primary,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '事实 ${_stats['facts'] ?? 0} 条'
                        ' · 共享 ${_stats['shared_facts'] ?? 0} 条'
                        ' · 会话 ${_stats['sessions'] ?? 0} 个'
                        ' · 要点 ${_stats['points'] ?? 0} 条',
                        style: Tga.sub,
                      ),
                      const Divider(height: 18),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        activeTrackColor: Tga.primary,
                        value: _stats['learn'] == true,
                        title: Text('从对话学习会话要点', style: Tga.body),
                        subtitle: Text('只存截断后的要点，不存全文', style: Tga.caption),
                        onChanged: (bool v) => _toggle('learn', v),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        activeTrackColor: Tga.primary,
                        value: _stats['remember'] == true,
                        title: Text('允许显式写入长期事实', style: Tga.body),
                        subtitle: Text('关闭后 memory_save 会被拒绝', style: Tga.caption),
                        onChanged: (bool v) => _toggle('remember', v),
                      ),
                    ],
                  ),
                ),
                TgaGroupTitle('长期事实（${_facts.length}）'),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        controller: _search,
                        style: TextStyle(color: Tga.text),
                        decoration: const InputDecoration(
                          hintText: '搜索事实',
                          isDense: true,
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                        onSubmitted: (String _) => _searchFacts(),
                      ),
                    ),
                    IconButton(
                      onPressed: _searchFacts,
                      icon: Icon(Icons.arrow_forward_rounded, color: Tga.primary),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_facts.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有长期事实\n点右上角 + 显式保存',
                      icon: Icons.psychology_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> f in _facts)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TgaCard(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(
                              f['scope'] == 'shared'
                                  ? Icons.people_outline_rounded
                                  : Icons.lock_outline_rounded,
                              size: 18,
                              color: f['scope'] == 'shared'
                                  ? Tga.primary
                                  : Tga.textSub,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('${f['text']}', style: Tga.body),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${f['source'] == null || '${f['source']}'.isEmpty ? '未标来源' : f['source']}'
                                    ' · ${f['scope'] == 'shared' ? 'shared' : 'private'}'
                                    '${(f['tags'] is List && (f['tags'] as List).isNotEmpty) ? ' · ${(f['tags'] as List).join('、')}' : ''}',
                                    style: Tga.caption,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline_rounded,
                                  size: 18, color: Tga.red),
                              onPressed: () => _forget(f),
                            ),
                          ],
                        ),
                      ),
                    ),
                TgaGroupTitle('会话要点'),
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _session,
                              style: TextStyle(color: Tga.text),
                              decoration: const InputDecoration(
                                labelText: '会话 id',
                                isDense: true,
                              ),
                              onSubmitted: (String _) => _loadSummary(),
                            ),
                          ),
                          TextButton(
                            onPressed: _loadSummary,
                            child: Text('读取',
                                style: TextStyle(color: Tga.primary, fontSize: 12)),
                          ),
                          TextButton(
                            onPressed: _clearSummary,
                            child: Text('清空',
                                style: TextStyle(color: Tga.red, fontSize: 12)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      if (_points.isEmpty)
                        Text('这个会话还没有要点。', style: Tga.sub)
                      else
                        for (final String p in _points)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('• $p', style: Tga.body),
                          ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
