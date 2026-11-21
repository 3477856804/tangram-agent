/// 本地产物：Agent 真实产生的文件（工作区、Pages 版本、Team Computer 文件）。
///
/// 列表只读取磁盘上真实存在的文件；读取文本有大小上限；删除只允许
/// 白名单目录内的普通文件，并拒绝 `..` 与浏览器 profile。没有产物时
/// 返回空列表，不生成示例文件。
library;

import 'dart:convert';
import 'dart:io';

class ArtifactService {
  ArtifactService(Directory root) : _root = root;

  final Directory _root;

  static const int maxList = 800;
  static const int maxReadBytes = 1024 * 1024;

  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> p,
  ) async {
    switch (action) {
      case 'list':
        return _list(p);
      case 'read':
        return _read(p);
      case 'delete':
        return _delete(p);
      default:
        return <String, dynamic>{'ok': false, 'error': '未知产物动作：$action'};
    }
  }

  Future<Map<String, dynamic>> _list(Map<String, dynamic> p) async {
    final String source = (p['source'] ?? '').toString();
    final String query = (p['query'] ?? '').toString().toLowerCase();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    if (source.isEmpty || source == 'work') {
      await _scanDir(Directory('${_root.path}/work'), 'work', out);
    }
    if (source.isEmpty || source == 'page') {
      await _scanPages(out);
    }
    if (source.isEmpty || source == 'computer') {
      final Directory homes = Directory('${_root.path}/computer/homes');
      if (await homes.exists()) {
        await for (final FileSystemEntity e in homes.list(followLinks: false)) {
          if (e is! Directory) continue;
          await _scanDir(e, 'computer', out);
          if (out.length >= maxList) break;
        }
      }
    }
    final List<Map<String, dynamic>> filtered = query.isEmpty
        ? out
        : out
            .where((Map<String, dynamic> a) =>
                '${a['name']}'.toLowerCase().contains(query) ||
                '${a['id']}'.toLowerCase().contains(query))
            .toList();
    filtered.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        '${b['modified']}'.compareTo('${a['modified']}'));
    final int total = filtered.length;
    final List<Map<String, dynamic>> limited =
        total > maxList ? filtered.sublist(0, maxList) : filtered;
    final Map<String, int> bySource = <String, int>{};
    for (final Map<String, dynamic> a in filtered) {
      bySource['${a['source']}'] = (bySource['${a['source']}'] ?? 0) + 1;
    }
    return <String, dynamic>{
      'ok': true,
      'artifacts': limited,
      'total': total,
      'groups': bySource,
      'truncated': total > maxList,
      'note': '只列出磁盘上真实存在的文件。',
    };
  }

  Future<void> _scanDir(
    Directory dir,
    String source,
    List<Map<String, dynamic>> out,
  ) async {
    if (!await dir.exists() || out.length >= maxList) return;
    try {
      await for (final FileSystemEntity e
          in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final String abs = e.absolute.path;
        if (abs.contains('/.browser-profiles/')) continue;
        final String rel = abs.substring(_root.absolute.path.length + 1);
        final FileStat st = await e.stat();
        out.add(<String, dynamic>{
          'id': rel,
          'name': abs.split('/').last,
          'source': source,
          'kind': _kind(abs),
          'size': st.size,
          'modified': st.modified.toIso8601String(),
          'absolute': abs,
        });
        if (out.length >= maxList) break;
      }
    } on Object {
      // 单个目录读取失败不影响其它来源。
    }
  }

  Future<void> _scanPages(List<Map<String, dynamic>> out) async {
    if (out.length >= maxList) return;
    final File index = File('${_root.path}/pages.json');
    if (!await index.exists()) return;
    Map<String, String> titles = <String, String>{};
    List<Map<String, dynamic>> pages = <Map<String, dynamic>>[];
    try {
      final dynamic decoded = jsonDecode(await index.readAsString());
      if (decoded is Map && decoded['pages'] is List) {
        pages = (decoded['pages'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        for (final Map<String, dynamic> p in pages) {
          titles['${p['id'] ?? ''}'] = '${p['title'] ?? '页面'}';
        }
      }
    } on Object {
      return;
    }
    for (final Map<String, dynamic> p in pages) {
      final String id = '${p['id'] ?? ''}';
      final int version = p['current_version'] is num
          ? (p['current_version'] as num).toInt()
          : int.tryParse('${p['current_version']}') ?? 0;
      if (id.isEmpty || version <= 0) continue;
      final File f = File('${_root.path}/pages/$id/v$version.html');
      if (!await f.exists()) continue;
      final FileStat st = await f.stat();
      out.add(<String, dynamic>{
        'id': 'pages/$id/v$version.html',
        'name': '${titles[id] ?? id} · v$version.html',
        'source': 'page',
        'kind': 'page',
        'size': st.size,
        'modified': st.modified.toIso8601String(),
        'absolute': f.absolute.path,
      });
      if (out.length >= maxList) return;
    }
  }

  Future<Map<String, dynamic>> _read(Map<String, dynamic> p) async {
    final File? f = _safeFile((p['id'] ?? '').toString());
    if (f == null) {
      return <String, dynamic>{'ok': false, 'error': '路径越界或不受支持'};
    }
    if (!await f.exists()) {
      return <String, dynamic>{'ok': false, 'error': '文件不存在'};
    }
    final int size = await f.length();
    if (size > maxReadBytes) {
      return <String, dynamic>{
        'ok': false,
        'error': '文件超过 ${maxReadBytes ~/ (1024 * 1024)}MB，请用工作区或电脑页处理',
      };
    }
    try {
      final String text = utf8.decode(await f.readAsBytes());
      return <String, dynamic>{
        'ok': true,
        'text': text,
        'size': size,
        'kind': _kind(f.path),
      };
    } on Object {
      return <String, dynamic>{
        'ok': false,
        'error': '不是 UTF-8 文本（图片/音视频请在系统中预览）',
        'size': size,
        'kind': _kind(f.path),
      };
    }
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final File? f = _safeFile((p['id'] ?? '').toString());
    if (f == null) {
      return <String, dynamic>{'ok': false, 'error': '路径越界或不受支持'};
    }
    if (!await f.exists()) {
      return <String, dynamic>{'ok': false, 'error': '文件不存在'};
    }
    await f.delete();
    return <String, dynamic>{'ok': true, 'deleted': p['id']};
  }

  File? _safeFile(String raw) {
    final String rel = raw.replaceAll('\\', '/').trim();
    if (rel.isEmpty || rel.startsWith('/') || rel.contains('..')) return null;
    if (rel.split('/').contains('.browser-profiles')) return null;
    final bool allowed = rel.startsWith('work/') ||
        rel.startsWith('pages/') ||
        rel.startsWith('computer/homes/');
    if (!allowed) return null;
    final String base = _root.absolute.path;
    final String abs = '$base/$rel';
    if (!abs.startsWith('$base/')) return null;
    return File(abs);
  }

  static String _kind(String path) {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.html')) return 'page';
    if (RegExp(r'\.(png|jpe?g|webp|gif|bmp)$').hasMatch(lower)) return 'image';
    if (RegExp(r'\.(md|txt|json|jsonl|csv|tsv|log|yaml|yml|xml)$').hasMatch(lower)) {
      return 'text';
    }
    if (RegExp(r'\.(mp3|wav|m4a|ogg|flac)$').hasMatch(lower)) return 'audio';
    if (RegExp(r'\.(mp4|mov|webm|mkv)$').hasMatch(lower)) return 'video';
    if (RegExp(r'\.(dart|py|js|ts|css|sh|kt|java|go|rs)$').hasMatch(lower)) {
      return 'code';
    }
    return 'file';
  }
}
