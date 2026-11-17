import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 工作区域目录映射：授权宿主目录 → 沙箱文件同步映射。
///
/// 移动端不是内核 bind mount，而是真实文件同步；敏感目录默认拒绝。
/// 只读映射禁止回写宿主，所有操作结果如实展示。
class TgaMappingPage extends StatefulWidget {
  const TgaMappingPage({super.key});

  @override
  State<TgaMappingPage> createState() => _TgaMappingPageState();
}

class _TgaMappingPageState extends State<TgaMappingPage> {
  List<Map<String, dynamic>> _mappings = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('workspace_mapping', <String, dynamic>{
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
        _loading = false;
        _mappings = (r['mappings'] is List ? r['mappings'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取映射失败：$e';
      });
    }
  }

  Future<void> _add() async {
    final String? dir = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要映射到沙箱的目录',
    );
    if (dir == null) return;
    if (!mounted) return;
    final TextEditingController name = TextEditingController(
        text: dir.split(Platform.pathSeparator).last);
    bool readOnly = false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('映射目录', style: Tga.h2),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(dir, style: Tga.caption, maxLines: 2),
              TextField(
                controller: name,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '映射名称'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: readOnly,
                onChanged: (bool v) => setLocal(() => readOnly = v),
                title: Text('只读（禁止回写宿主目录）', style: Tga.body),
              ),
              Text('敏感目录（.ssh/.gnupg/系统目录）会被拒绝；'
                  '同步上限 5000 个文件 / 200MB。', style: Tga.caption),
            ],
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('取消', style: TextStyle(color: Tga.textSub))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true), child: const Text('映射')),
          ],
        ),
      ),
    );
    final String n = name.text.trim();
    name.dispose();
    if (ok != true) return;
    setState(() => _busy = true);
    final Map<String, dynamic> r = await _call('add', <String, dynamic>{
      'host_path': dir,
      'name': n,
      'mode': readOnly ? 'ro' : 'rw',
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      _toast((r['error'] ?? '映射失败').toString());
      return;
    }
    await _load();
    _toast('已创建映射；可执行「同步到沙箱」');
  }

  Future<void> _sync(Map<String, dynamic> m, bool toSandbox) async {
    setState(() => _busy = true);
    final Map<String, dynamic> r = await _call(
      toSandbox ? 'sync_to_sandbox' : 'sync_to_host',
      <String, dynamic>{'id': m['id']},
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      final List<dynamic> errors =
          r['errors'] is List ? r['errors'] as List : <dynamic>[];
      _toast(errors.isEmpty
          ? (r['error'] ?? '同步失败').toString()
          : '同步失败：${errors.first}');
    } else {
      _toast('同步完成：${r['files'] ?? 0} 个文件 / ${r['bytes'] ?? 0} 字节');
    }
    await _load();
  }

  Future<void> _preview(Map<String, dynamic> m) async {
    final Map<String, dynamic> r =
        await _call('preview', <String, dynamic>{'id': m['id']});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '预览失败').toString());
      return;
    }
    final List<dynamic> entries =
        r['entries'] is List ? r['entries'] as List : <dynamic>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Tga.card,
      builder: (BuildContext ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (BuildContext _, ScrollController sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text('${m['name']} · 沙箱预览', style: Tga.h1),
            Text(m['sandbox_rel'].toString(), style: Tga.caption),
            if (entries.isEmpty)
              TgaEmpty('还没有同步文件', icon: Icons.folder_open_outlined)
            else
              for (final dynamic raw in entries)
                if (raw is Map)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      raw['is_dir'] == true
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 17,
                      color: Tga.textSub,
                    ),
                    title: Text(raw['path'].toString(), style: Tga.body),
                    trailing: raw['is_dir'] == true
                        ? null
                        : Text('${raw['size']} B', style: Tga.caption),
                  ),
            if (r['truncated'] == true)
              Text('仅展示前 200 项', style: Tga.caption),
          ],
        ),
      ),
    );
  }

  Future<void> _remove(Map<String, dynamic> m) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('移除映射「${m['name']}」？', style: Tga.h2),
        content: Text('默认保留沙箱内已同步文件；可勾选同时删除。宿主源目录不会删除。',
            style: Tga.body),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('移除', style: TextStyle(color: Tga.red))),
        ],
      ),
    );
    if (ok != true) return;
    final Map<String, dynamic> r =
        await _call('remove', <String, dynamic>{'id': m['id']});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '移除失败').toString());
      return;
    }
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
      title: '目录映射',
      actions: <Widget>[
        IconButton(
          onPressed: _loading || _busy ? null : _add,
          tooltip: '添加映射',
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
                if (_error.isNotEmpty)
                  TgaCard(child: Text(_error, style: Tga.body.copyWith(color: Tga.red)))
                else
                  TgaCard(
                    child: Text(
                      '授权宿主目录后，文件会真实同步到沙箱 sandbox/mounts/。\n'
                      '移动端为文件同步映射，不是内核 bind mount；只读映射禁止回写。',
                      style: Tga.sub,
                    ),
                  ),
                TgaGroupTitle('已映射目录（${_mappings.length}）'),
                if (_mappings.isEmpty)
                  TgaCard(
                      child: TgaEmpty('还没有目录映射\n点右上角 + 选择宿主目录',
                          icon: Icons.folder_copy_outlined))
                else
                  for (final Map<String, dynamic> m in _mappings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Icon(Icons.folder_copy_outlined,
                                    size: 18, color: Tga.primary),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(m['name'].toString(), style: Tga.h2),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Tga.bgSoft,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    m['mode'] == 'ro' ? '只读' : '读写',
                                    style: Tga.caption,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text('宿主：${m['host_path']}', style: Tga.caption),
                            Text('沙箱：${m['sandbox_rel']}', style: Tga.caption),
                            Text(
                              '${m['file_count'] ?? 0} 个文件 · ${m['bytes'] ?? 0} 字节'
                              '${(m['last_sync_at'] ?? '').toString().isEmpty ? ' · 尚未同步' : ' · ${m['last_sync_at'].toString().replaceFirst('T', ' ').split('.').first}'}',
                              style: Tga.caption,
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: <Widget>[
                                TgaButton(
                                    label: '同步到沙箱',
                                    icon: Icons.download_rounded,
                                    onTap: _busy ? () {} : () => _sync(m, true)),
                                TgaButton(
                                    label: '回写宿主',
                                    icon: Icons.upload_rounded,
                                    filled: false,
                                    onTap: _busy || m['mode'] == 'ro'
                                        ? () {}
                                        : () => _sync(m, false)),
                                TgaButton(
                                    label: '预览',
                                    filled: false,
                                    onTap: () => _preview(m)),
                                TgaButton(
                                    label: '移除',
                                    color: Tga.red,
                                    filled: false,
                                    onTap: () => _remove(m)),
                              ],
                            ),
                            if (m['mode'] == 'ro')
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text('只读映射禁止回写宿主目录',
                                    style: Tga.caption.copyWith(color: Tga.orange)),
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
