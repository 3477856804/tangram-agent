import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 本地产物：工作区、Pages 版本与 Team Computer 文件。
///
/// 列表、预览、删除、分享全部针对真实文件；图片直接预览，文本读取上限
/// 由后端控制。没有产物时显示空态，不生成示例。
class TgaArtifactsPage extends StatefulWidget {
  const TgaArtifactsPage({super.key});

  @override
  State<TgaArtifactsPage> createState() => _TgaArtifactsPageState();
}

class _TgaArtifactsPageState extends State<TgaArtifactsPage> {
  final TextEditingController _query = TextEditingController();
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  Map<String, int> _groups = <String, int>{};
  String _source = '';
  bool _loading = true;

  static const Map<String, String> _sources = <String, String>{
    'work': '工作区',
    'page': 'Pages',
    'computer': '电脑',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('artifact', <String, dynamic>{
      'action': action,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    final Map<String, dynamic> r = await _call('list', <String, dynamic>{
      'source': _source,
      'query': _query.text.trim(),
    });
    if (!mounted) return;
    setState(() {
      _items = (r['artifacts'] is List ? r['artifacts'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
      _groups = r['groups'] is Map
          ? (r['groups'] as Map).map(
              (dynamic k, dynamic v) => MapEntry('$k', v is num ? v.toInt() : 0))
          : <String, int>{};
      _loading = false;
    });
  }

  Future<void> _preview(Map<String, dynamic> a) async {
    final String kind = '${a['kind']}';
    if (kind == 'image') {
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('${a['name']}', style: Tga.h2),
          content: SizedBox(
            width: 560,
            height: 420,
            child: Image.file(
              File('${a['absolute']}'),
              fit: BoxFit.contain,
              errorBuilder: (BuildContext _, Object __, StackTrace? ___) =>
                  Center(child: Text('图片无法解码或已被移动', style: Tga.sub)),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('关闭', style: TextStyle(color: Tga.textSub)),
            ),
          ],
        ),
      );
      return;
    }
    final Map<String, dynamic> r = await _call('read', <String, dynamic>{
      'id': '${a['id']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '无法预览'}');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('${a['name']}', style: Tga.h2),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText('${r['text']}', style: Tga.body),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('关闭', style: TextStyle(color: Tga.textSub)),
          ),
        ],
      ),
    );
  }

  Future<void> _share(Map<String, dynamic> a) async {
    try {
      await Share.shareXFiles(
        <XFile>[XFile('${a['absolute']}')],
        text: '${a['name']}',
      );
    } on Object catch (e) {
      if (mounted) _toast('分享失败：$e');
    }
  }

  Future<void> _delete(Map<String, dynamic> a) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('删除「${a['name']}」？', style: Tga.h2),
        content: Text('文件会从磁盘真实删除，无法恢复。', style: Tga.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Tga.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('delete', <String, dynamic>{
      'id': '${a['id']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '删除失败'}');
      return;
    }
    await _load();
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
      title: '产物',
      actions: <Widget>[
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
                  child: TextField(
                    controller: _query,
                    style: TextStyle(color: Tga.text),
                    decoration: const InputDecoration(
                      hintText: '按文件名筛选',
                      prefixIcon: Icon(Icons.filter_alt_outlined),
                    ),
                    onSubmitted: (String _) => _load(),
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      _chip(
                        '全部${_items.length}',
                        selected: _source.isEmpty,
                        onTap: () {
                          setState(() => _source = '');
                          _load();
                        },
                      ),
                      const SizedBox(width: 8),
                      for (final MapEntry<String, String> e in _sources.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _chip(
                            '${e.value}${_groups[e.key] == null ? '' : ' ${_groups[e.key]}'}',
                            selected: _source == e.key,
                            onTap: () {
                              setState(() => _source = e.key);
                              _load();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                if (_items.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有产物\nAgent 生成的文件会出现在这里',
                      icon: Icons.inventory_2_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> a in _items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TgaCard(
                        onTap: () => _preview(a),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: <Widget>[
                            Icon(_icon('${a['kind']}'),
                                size: 20, color: Tga.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '${a['name']}',
                                    style: Tga.body,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${_sources[a['source']] ?? a['source']} · '
                                    '${_size(a['size'])} · ${_modified(a['modified'])}',
                                    style: Tga.caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.ios_share_rounded,
                                  size: 18, color: Tga.textSub),
                              onPressed: () => _share(a),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline_rounded,
                                  size: 18, color: Tga.red),
                              onPressed: () => _delete(a),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }

  Widget _chip(String label, {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Tga.primary : Tga.bgSoft,
          borderRadius: BorderRadius.circular(Tga.rChip),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected ? Tga.onPrimary : Tga.text,
          ),
        ),
      ),
    );
  }

  static IconData _icon(String kind) => switch (kind) {
        'image' => Icons.image_outlined,
        'audio' => Icons.audiotrack_outlined,
        'video' => Icons.movie_outlined,
        'page' => Icons.description_outlined,
        'code' => Icons.code_rounded,
        'text' => Icons.article_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  static String _size(dynamic value) {
    final int n = value is num ? value.toInt() : 0;
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _modified(dynamic value) {
    final String raw = '${value ?? ''}';
    if (raw.isEmpty) return '';
    return raw.replaceFirst('T', ' ').split('.').first;
  }
}
