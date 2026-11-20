/// Pages：Agent 生成的版本化看板 / 文档。
///
/// 列表、版本、置顶与导出都走 EmbeddedBackend 的 `pages` 控制域；
/// 预览使用 WebView（默认禁用 JavaScript），桌面无 WebView 时真实调用
/// 系统默认浏览器打开导出的 HTML，不伪造渲染结果。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/pages_service.dart' show PageVisibility;

class TgaPagesPage extends StatefulWidget {
  const TgaPagesPage({super.key});

  @override
  State<TgaPagesPage> createState() => _TgaPagesPageState();
}

class _TgaPagesPageState extends State<TgaPagesPage> {
  final TextEditingController _query = TextEditingController();
  List<Map<String, dynamic>> _pages = <Map<String, dynamic>>[];
  bool _loading = true;

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
    Map<String, dynamic> extra = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('pages', <String, dynamic>{
      'action': action,
      ...extra,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await _call('list', <String, dynamic>{
        'query': _query.text,
      });
      if (!mounted) return;
      setState(() {
        _pages = (r['pages'] is List ? r['pages'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  Future<void> _create() async {
    final TextEditingController title = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('新建 Page', style: Tga.h2),
        content: TextField(
          controller: title,
          autofocus: true,
          style: TextStyle(color: Tga.text),
          decoration: const InputDecoration(hintText: '页面标题'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    final String name = title.text.trim();
    title.dispose();
    if (ok != true || name.isEmpty) return;
    final Map<String, dynamic> r = await _call('create', <String, dynamic>{
      'title': name,
      'html': _starterHtml(name),
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '创建失败'}');
      return;
    }
    final String id = '${r['page']['id']}';
    await _open(id);
    await _load();
  }

  Future<void> _open(String id) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => TgaPageDetailPage(pageId: id)),
    );
    if (changed == true) await _load();
  }

  Future<void> _togglePin(Map<String, dynamic> page) async {
    final Map<String, dynamic> r = await _call('update', <String, dynamic>{
      'id': page['id'],
      'pinned': page['pinned'] != true,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '更新失败'}');
      return;
    }
    await _load();
  }

  Future<void> _rename(Map<String, dynamic> page) async {
    final TextEditingController title = TextEditingController(
      text: '${page['title']}',
    );
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('重命名', style: Tga.h2),
        content: TextField(
          controller: title,
          autofocus: true,
          style: TextStyle(color: Tga.text),
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
    final String name = title.text.trim();
    title.dispose();
    if (ok != true || name.isEmpty) return;
    final Map<String, dynamic> r = await _call('update', <String, dynamic>{
      'id': page['id'],
      'title': name,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '重命名失败'}');
      return;
    }
    await _load();
  }

  Future<void> _delete(Map<String, dynamic> page) async {
    final bool ok =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('删除 Page？', style: Tga.h2),
            content: Text(
              '将删除「${page['title']}」及全部版本文件，无法撤销。',
              style: Tga.body,
            ),
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
        ) ??
        false;
    if (!ok) return;
    final Map<String, dynamic> r = await _call('delete', <String, dynamic>{
      'id': page['id'],
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
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: 'Pages',
      actions: <Widget>[
        IconButton(
          tooltip: '新建 Page',
          onPressed: _create,
          icon: const Icon(Icons.add_rounded),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Tga.pagePad, 12, Tga.pagePad, 32),
          children: <Widget>[
            TextField(
              controller: _query,
              style: TextStyle(color: Tga.text),
              onChanged: (_) => _load(),
              decoration: InputDecoration(
                hintText: '搜索标题',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                filled: true,
                fillColor: Tga.card,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 14),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_pages.isEmpty)
              TgaCard(
                child: TgaEmpty(
                  '还没有 Page。让 Agent 用 page_publish 生成看板，或点右上角新建。',
                  icon: Icons.auto_awesome_mosaic_outlined,
                ),
              )
            else
              TgaCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: <Widget>[
                    for (int i = 0; i < _pages.length; i++) ...<Widget>[
                      _row(_pages[i]),
                      if (i != _pages.length - 1)
                        Divider(height: 1, color: Tga.divider),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> page) {
    final bool pinned = page['pinned'] == true;
    final bool link = '${page['visibility']}' == 'link';
    return InkWell(
      onTap: () => _open('${page['id']}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Tga.iconBlueBg,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                pinned
                    ? Icons.push_pin_rounded
                    : Icons.auto_awesome_mosaic_outlined,
                size: 20,
                color: Tga.iconBlue,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${page['title']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Tga.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'v${page['current_version']}'
                    '${link ? ' · 链接可见' : ' · 私有'}',
                    style: Tga.caption,
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz_rounded, color: Tga.textSub),
              onSelected: (String value) {
                switch (value) {
                  case 'pin':
                    _togglePin(page);
                    break;
                  case 'rename':
                    _rename(page);
                    break;
                  case 'delete':
                    _delete(page);
                    break;
                }
              },
              itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'pin',
                  child: Text(pinned ? '取消置顶' : '置顶'),
                ),
                const PopupMenuItem<String>(
                  value: 'rename',
                  child: Text('重命名'),
                ),
                const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class TgaPageDetailPage extends StatefulWidget {
  const TgaPageDetailPage({super.key, required this.pageId});

  final String pageId;

  @override
  State<TgaPageDetailPage> createState() => _TgaPageDetailPageState();
}

class _TgaPageDetailPageState extends State<TgaPageDetailPage> {
  final TextEditingController _editor = TextEditingController();
  WebViewController? _web;
  Map<String, dynamic>? _page;
  List<int> _versions = <int>[];
  int _viewing = 0;
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  bool _changed = false;
  String _html = '';
  String _hint = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _editor.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> extra = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('pages', <String, dynamic>{
      'action': action,
      'id': widget.pageId,
      ...extra,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load({int? version}) async {
    final Map<String, dynamic> r = await _call('get', <String, dynamic>{
      if (version != null) 'version': version,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      setState(() => _loading = false);
      _toast('${r['error'] ?? '读取失败'}');
      return;
    }
    final Map<String, dynamic> page = Map<String, dynamic>.from(
      r['page'] as Map,
    );
    final List<int> versions =
        (r['versions'] is List ? r['versions'] as List : <dynamic>[])
            .map((dynamic e) => int.tryParse('$e') ?? 0)
            .where((int v) => v > 0)
            .toList();
    setState(() {
      _page = page;
      _html = '${r['html']}';
      _editor.text = _html;
      _versions = versions;
      _viewing =
          int.tryParse('${r['version']}') ?? page['current_version'] as int;
      _loading = false;
    });
    _mountPreview();
  }

  void _mountPreview() {
    try {
      final WebViewController c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.disabled)
        ..setBackgroundColor(Tga.card)
        ..setNavigationDelegate(
          NavigationDelegate(
            // 预览只允许内联/本地内容，阻止页面偷偷加载远程图片或脚本。
            onNavigationRequest: (NavigationRequest request) {
              final String url = request.url;
              final bool local =
                  url.startsWith('about:') ||
                  url.startsWith('data:') ||
                  url.startsWith('file:');
              return local
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent;
            },
            onWebResourceError: (WebResourceError e) {
              if (!mounted) return;
              setState(() => _hint = '预览失败：${e.description}');
            },
          ),
        );
      c.loadHtmlString(_previewHtml(_html)).catchError((Object e) {
        if (!mounted) return;
        setState(() => _hint = '内嵌 WebView 不可用：$e');
      });
      setState(() {
        _web = c;
        _hint = '';
      });
    } on Object catch (e) {
      setState(() {
        _web = null;
        _hint = '当前平台无内嵌 WebView：$e；可导出后用系统浏览器打开。';
      });
    }
  }

  Future<void> _save() async {
    final String html = _editor.text;
    if (html.trim().isEmpty) {
      _toast('页面内容不能为空');
      return;
    }
    setState(() => _saving = true);
    final Map<String, dynamic> r = await _call('save', <String, dynamic>{
      'html': html,
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '保存失败'}');
      return;
    }
    _changed = true;
    _toast('已保存 v${r['page']['current_version']}');
    await _load();
    if (!mounted) return;
    setState(() => _editing = false);
  }

  Future<void> _share() async {
    final Map<String, dynamic> r = await _call('export', <String, dynamic>{
      'version': _viewing,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '导出失败'}');
      return;
    }
    final File file = File('${r['path']}');
    try {
      await Share.shareXFiles(<XFile>[XFile(file.path, mimeType: 'text/html')]);
    } on Object catch (e) {
      _toast('系统分享不可用：$e\n文件：${file.path}');
    }
  }

  Future<void> _openSystem() async {
    final Map<String, dynamic> r = await _call('export', <String, dynamic>{
      'version': _viewing,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '导出失败'}');
      return;
    }
    final String path = '${r['path']}';
    try {
      late final ProcessResult result;
      if (Platform.isLinux) {
        result = await Process.run('xdg-open', <String>[path]);
      } else if (Platform.isMacOS) {
        result = await Process.run('open', <String>[path]);
      } else if (Platform.isWindows) {
        result = await Process.run('cmd', <String>['/c', 'start', '', path]);
      } else {
        _toast('当前平台请使用系统分享打开：$path');
        return;
      }
      if (!mounted) return;
      if (result.exitCode != 0) {
        _toast('系统打开失败（exit=${result.exitCode}）：${result.stderr}');
      }
    } on Object catch (e) {
      _toast('系统打开失败：$e');
    }
  }

  Future<void> _setVisibility(PageVisibility visibility) async {
    final Map<String, dynamic> r = await _call('update', <String, dynamic>{
      'visibility': visibility == PageVisibility.link ? 'link' : 'private',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '更新失败'}');
      return;
    }
    await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? page = _page;
    final bool link = '${page?['visibility']}' == 'link';
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, bool? _) {
        if (didPop) return;
        Navigator.of(context).pop(_changed);
      },
      child: TgaPage(
        title: page == null ? 'Page' : '${page['title']}',
        actions: <Widget>[
          if (page != null)
            IconButton(
              tooltip: link ? '改为私有' : '允许链接可见',
              onPressed: () => _setVisibility(
                link ? PageVisibility.private : PageVisibility.link,
              ),
              icon: Icon(
                link ? Icons.link_rounded : Icons.lock_outline_rounded,
                color: link ? Tga.primary : Tga.textSub,
              ),
            ),
          IconButton(
            tooltip: '导出 / 分享 HTML',
            onPressed: _share,
            icon: const Icon(Icons.ios_share_rounded),
          ),
          IconButton(
            tooltip: _editing ? '预览' : '编辑 HTML',
            onPressed: () => setState(() => _editing = !_editing),
            icon: Icon(
              _editing ? Icons.visibility_outlined : Icons.code_rounded,
            ),
          ),
        ],
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                  Tga.pagePad,
                  10,
                  Tga.pagePad,
                  28,
                ),
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text('版本', style: Tga.caption),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: _versions.contains(_viewing)
                            ? _viewing
                            : (_versions.isEmpty ? null : _versions.first),
                        items: _versions
                            .map(
                              (int v) => DropdownMenuItem<int>(
                                value: v,
                                child: Text('v$v'),
                              ),
                            )
                            .toList(),
                        onChanged: (int? v) {
                          if (v != null) _load(version: v);
                        },
                      ),
                      const Spacer(),
                      if (_viewing != page?['current_version'])
                        Text('历史版本（只读）', style: Tga.caption),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_editing)
                    TgaCard(
                      child: TextField(
                        controller: _editor,
                        maxLines: 24,
                        minLines: 12,
                        style: TextStyle(
                          color: Tga.text,
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.45,
                        ),
                        decoration: const InputDecoration(
                          hintText: '<!doctype html>…',
                          border: InputBorder.none,
                        ),
                      ),
                    )
                  else if (_web != null)
                    TgaCard(
                      padding: EdgeInsets.zero,
                      child: SizedBox(
                        height: 460,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(Tga.rCard),
                          child: WebViewWidget(controller: _web!),
                        ),
                      ),
                    )
                  else
                    TgaCard(
                      child: TgaEmpty(_hint, icon: Icons.desktop_mac_outlined),
                    ),
                  if (_hint.isNotEmpty && _web != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(_hint, style: Tga.caption),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      if (_editing)
                        FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_outlined, size: 17),
                          label: const Text('保存为新版本'),
                        ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: _openSystem,
                        icon: const Icon(Icons.open_in_new, size: 17),
                        label: const Text('系统打开'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '页面是本机 HTML，预览默认禁用 JavaScript 并阻止外部资源；'
                    '导出后可交给系统浏览器或分享面板。',
                    style: Tga.caption,
                  ),
                ],
              ),
      ),
    );
  }
}

String _previewHtml(String html) {
  const String csp =
      '<meta http-equiv="Content-Security-Policy" '
      "content=\"default-src 'none'; img-src data:; "
      "style-src 'unsafe-inline'; font-src data:\">";
  final RegExp head = RegExp(r'<head[^>]*>', caseSensitive: false);
  final RegExpMatch? match = head.firstMatch(html);
  if (match != null) {
    return html.replaceRange(match.end, match.end, csp);
  }
  return '$csp$html';
}

String _starterHtml(String title) {
  final String safe = title
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  return '''<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>$safe</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; padding: 28px; font-family: -apple-system, "Segoe UI", sans-serif;
         background: #f6f7fb; color: #111; }
  .card { background: #fff; border-radius: 16px; padding: 22px;
          box-shadow: 0 8px 30px rgba(27,37,89,.08); }
  h1 { margin: 0 0 8px; font-size: 24px; }
  p { color: #555; line-height: 1.6; }
</style>
</head>
<body>
  <div class="card">
    <h1>$safe</h1>
    <p>这是 Agent 生成的 Page。直接编辑 HTML，保存会自动追加新版本。</p>
  </div>
</body>
</html>''';
}
