import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 快照与备份：把 Harness 真实数据目录打成可恢复的文件快照。
///
/// 本地快照带逐文件 SHA256；恢复前自动生成「恢复前备份」，恢复时校验失败
/// 的文件不会被覆盖。加密云端同步未配置时如实展示为不可用。
class TgaSnapshotPage extends StatefulWidget {
  const TgaSnapshotPage({super.key});

  @override
  State<TgaSnapshotPage> createState() => _TgaSnapshotPageState();
}

class _TgaSnapshotPageState extends State<TgaSnapshotPage> {
  List<Map<String, dynamic>> _snapshots = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _busy = false;
  String _root = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('snapshot', <String, dynamic>{
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
        _snapshots = (r['snapshots'] is List ? r['snapshots'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _root = (r['root'] ?? '').toString();
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  Future<void> _create() async {
    final TextEditingController label = TextEditingController();
    bool workspace = false;
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('保存快照', style: Tga.h2),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: label,
                autofocus: true,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '快照说明（可选）'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: workspace,
                onChanged: (bool v) => setLocal(() => workspace = v),
                title: Text('包含工作区文件（sandbox/）', style: Tga.body),
                subtitle: Text('体积可能较大；模型权重不会被打包',
                    style: Tga.caption),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('取消', style: TextStyle(color: Tga.textSub))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true), child: const Text('创建')),
          ],
        ),
      ),
    );
    if (go != true) {
      label.dispose();
      return;
    }
    final String text = label.text.trim();
    label.dispose();
    setState(() => _busy = true);
    final Map<String, dynamic> r = await _call('create', <String, dynamic>{
      'label': text,
      'include_workspace': workspace,
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      _toast((r['error'] ?? '创建失败').toString());
      return;
    }
    final Map<String, dynamic> snap =
        Map<String, dynamic>.from(r['snapshot'] as Map);
    _toast('已保存：${snap['file_count']} 个文件 / ${_size(snap['total_bytes'])}');
    await _load();
  }

  Future<void> _restore(Map<String, dynamic> snap) async {
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('恢复快照？', style: Tga.h2),
            content: Text(
              '将用「${snap['label']}」（${_date(snap['created_at'])}）覆盖当前同名数据文件。\n'
              '恢复前会自动再做一份备份；SHA256 不匹配的文件会被拒绝覆盖。',
              style: Tga.body,
            ),
            actions: <Widget>[
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text('取消', style: TextStyle(color: Tga.textSub))),
              FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true), child: const Text('恢复')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    setState(() => _busy = true);
    final Map<String, dynamic> r =
        await _call('restore', <String, dynamic>{'id': snap['id']});
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      final List<dynamic> errors =
          r['errors'] is List ? r['errors'] as List : <dynamic>[];
      _toast(errors.isEmpty
          ? (r['error'] ?? '恢复失败').toString()
          : '恢复失败：${errors.first}');
      await _load();
      return;
    }
    _toast('已恢复 ${r['restored']} 个文件');
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> snap) async {
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('删除快照？', style: Tga.h2),
            content: Text('将删除本地快照目录「${snap['label']}」，不可恢复。',
                style: Tga.body),
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
    await _call('delete', <String, dynamic>{'id': snap['id']});
    await _load();
  }

  static String _size(dynamic bytes) {
    final int b = bytes is num ? bytes.toInt() : 0;
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1048576).toStringAsFixed(1)} MB';
  }

  static String _date(dynamic raw) =>
      raw.toString().replaceFirst('T', ' ').split('.').first;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '快照与备份',
      actions: <Widget>[
        IconButton(
          onPressed: _loading || _busy ? null : _create,
          tooltip: '保存快照',
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading || _busy ? null : _load,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
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
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(Icons.cloud_off_outlined, size: 18, color: Tga.textSub),
                          const SizedBox(width: 8),
                          Text('本地快照', style: Tga.h2),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '快照保存模型注册表、智能体、Super Agent 工单与轨迹、'
                        '知识库、工作流、日记与规则；可选包含工作区文件。\n'
                        '加密云端同步尚未配置，本页不提供假开关。',
                        style: Tga.sub,
                      ),
                    ],
                  ),
                ),
                TgaGroupTitle('快照（${_snapshots.length}）'),
                if (_snapshots.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有快照\n点右上角 + 保存当前状态',
                      icon: Icons.inventory_2_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> s in _snapshots)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Tga.iconCyanBg,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(Icons.inventory_2_rounded,
                                  size: 18, color: Tga.iconCyan),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text((s['label'] ?? '快照').toString(), style: Tga.h2),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_date(s['created_at'])} · ${s['file_count'] ?? 0} 个文件 · '
                                    '${_size(s['total_bytes'])}'
                                    '${s['include_workspace'] == true ? ' · 含工作区' : ''}'
                                    '${s['truncated'] == true ? ' · 已截断' : ''}',
                                    style: Tga.caption,
                                  ),
                                ],
                              ),
                            ),
                            TextButton(
                              onPressed: _busy ? null : () => _restore(s),
                              child: Text('恢复',
                                  style: TextStyle(color: Tga.primary, fontSize: 12)),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline_rounded,
                                  size: 18, color: Tga.red),
                              onPressed: _busy ? null : () => _delete(s),
                            ),
                          ],
                        ),
                      ),
                    ),
                if (_root.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('数据目录：$_root', style: Tga.caption),
                  ),
              ],
            ),
    );
  }
}
