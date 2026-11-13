import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../design/tga_design.dart';
import '../../services/persona_store.dart';
import '../../services/works_registry.dart';

/// 我的作品（#13 真实化）：WorksRegistry 扫描 Agent 真实写文件的
/// 工作区目录（本地工作区 + 内置沙箱 sandbox/），把含产物的子目录识别为
/// 网站 / App / 脚本。
/// - 网站 → webview_flutter 加载真实 file:// HTML；平台不支持 WebView 时
///   如实提示「请在移动端预览」，不伪造渲染。
/// - App / 脚本 → 目录内真实文件列表，可点开文本内容预览。
class TgaWorksPage extends StatefulWidget {
  const TgaWorksPage({super.key});

  @override
  State<TgaWorksPage> createState() => _TgaWorksPageState();
}

class _TgaWorksPageState extends State<TgaWorksPage> {
  List<TgaWork> _works = <TgaWork>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _loading = true);
    final String? ws = context.read<PersonaStore>().workspaceRoot;
    final List<TgaWork> works = await WorksRegistry.scan(workspaceRoot: ws);
    if (!mounted) return;
    setState(() {
      _works = works;
      _loading = false;
    });
  }

  void _open(TgaWork work) {
    switch (work.kind) {
      case TgaWorkKind.website:
        final String? html = work.entryFile;
        if (html == null || !File(html).existsSync()) {
          _toast(context, '未找到可打开的 HTML 文件');
          return;
        }
        Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (BuildContext _) => TgaWorkWebPage(work: work, htmlPath: html)));
      case TgaWorkKind.app:
      case TgaWorkKind.script:
        Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (BuildContext _) => TgaWorkFilesPage(work: work)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '我的作品',
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
          tooltip: '重新扫描',
          onPressed: _loading ? null : _scan,
        ),
      ],
      child: RefreshIndicator(
        onRefresh: _scan,
        child: _loading
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  const SizedBox(height: 80),
                  Center(
                      child: SizedBox(
                          width: 26,
                          height: 26,
                          child: CircularProgressIndicator(
                              strokeWidth: 2.4, color: Tga.primary))),
                ],
              )
            : _works.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(Tga.pagePad, 40, Tga.pagePad, 32),
                    children: const <Widget>[
                      TgaCard(
                        child: TgaEmpty(
                          '还没有作品\n让 Agent 在工作区里产出网页 / App / 脚本后回来看看',
                          icon: Icons.folder_open_outlined,
                        ),
                      ),
                    ],
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding:
                        const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
                    children: <Widget>[
                      Text('来自工作区与内置沙箱的真实目录，共 ${_works.length} 件',
                          style: Tga.caption),
                      const SizedBox(height: 10),
                      for (final TgaWork w in _works) ...<Widget>[
                        _WorkTile(work: w, onTap: () => _open(w)),
                        const SizedBox(height: 10),
                      ],
                    ],
                  ),
      ),
    );
  }
}

class _WorkTile extends StatelessWidget {
  const _WorkTile({required this.work, required this.onTap});
  final TgaWork work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color bg, Color fg, Color tag) = switch (work.kind) {
      TgaWorkKind.website => (
          Icons.public_outlined,
          Tga.iconBlueBg,
          Tga.iconBlue,
          Tga.iconBlue
        ),
      TgaWorkKind.app => (
          Icons.apps_outlined,
          Tga.iconPurpleBg,
          Tga.iconPurple,
          Tga.iconPurple
        ),
      TgaWorkKind.script => (
          Icons.terminal_outlined,
          Tga.iconGreenBg,
          Tga.iconGreen,
          Tga.iconGreen
        ),
    };
    return TgaCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: bg, borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, size: 22, color: fg),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                        child: Text(work.name,
                            style: Tga.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    TgaTag(tgaWorkKindLabel(work.kind), color: tag),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${_fmtTime(work.modified)} · ${work.fileCount} 个文件 · ${_fmtBytes(work.totalBytes)}',
                  style: Tga.sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 19, color: Tga.textDim),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 网站作品：webview_flutter 加载真实 file:// HTML
// ---------------------------------------------------------------------------

/// 用 WebViewController（platform 接口，跨 Android/iOS）加载本地 HTML。
/// 桌面等未注册 WebView 实现的平台创建控制器会抛异常，如实提示
/// 「请在移动端预览」，绝不伪造渲染。
class TgaWorkWebPage extends StatefulWidget {
  const TgaWorkWebPage({super.key, required this.work, required this.htmlPath});
  final TgaWork work;
  final String htmlPath;

  @override
  State<TgaWorkWebPage> createState() => _TgaWorkWebPageState();
}

class _TgaWorkWebPageState extends State<TgaWorkWebPage> {
  WebViewController? _controller;
  String _hint = '';

  @override
  void initState() {
    super.initState();
    if (!File(widget.htmlPath).existsSync()) {
      _hint = 'HTML 文件已不存在：${widget.htmlPath}';
      return;
    }
    try {
      final WebViewController c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.disabled)
        ..setNavigationDelegate(NavigationDelegate(
          onWebResourceError: (WebResourceError e) {
            if (!mounted) return;
            setState(() => _hint = '页面加载失败：${e.description}');
          },
        ));
      c.loadFile(widget.htmlPath).catchError((Object err) {
        if (!mounted) return;
        setState(() => _hint = '当前平台不支持 WebView 预览，请在移动端预览。');
      });
      _controller = c;
    } on Object {
      _hint = '当前平台不支持 WebView 预览，请在移动端预览。';
    }
  }

  @override
  Widget build(BuildContext context) {
    final WebViewController? controller = _controller;
    return TgaPage(
      title: widget.work.name,
      child: controller == null
          ? ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 60, Tga.pagePad, 32),
              children: <Widget>[
                TgaCard(child: TgaEmpty(_hint, icon: Icons.desktop_mac_outlined)),
              ],
            )
          : Stack(
              children: <Widget>[
                Positioned.fill(child: WebViewWidget(controller: controller)),
                if (_hint.isNotEmpty)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: Tga.card.withValues(alpha: 0.95),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(_hint, style: Tga.sub),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// App / 脚本作品：真实文件列表 + 文本预览
// ---------------------------------------------------------------------------

class TgaWorkFilesPage extends StatefulWidget {
  const TgaWorkFilesPage({super.key, required this.work});
  final TgaWork work;

  @override
  State<TgaWorkFilesPage> createState() => _TgaWorkFilesPageState();
}

class _TgaWorkFilesPageState extends State<TgaWorkFilesPage> {
  List<File> _files = <File>[];

  @override
  void initState() {
    super.initState();
    _files = WorksRegistry.listFiles(widget.work.dirPath);
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: widget.work.name,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
            child: Text(widget.work.dirPath, style: Tga.caption),
          ),
          if (_files.isEmpty)
            TgaCard(child: TgaEmpty('目录为空或已不存在', icon: Icons.folder_off_outlined))
          else
            TgaCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < _files.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    _FileTile(
                        file: _files[i],
                        baseDir: widget.work.dirPath,
                        onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                  builder: (BuildContext _) =>
                                      TgaFilePreviewPage(file: _files[i])),
                            )),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  const _FileTile(
      {required this.file, required this.baseDir, required this.onTap});
  final File file;
  final String baseDir;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    int size = 0;
    String mtime = '';
    try {
      final FileStat st = file.statSync();
      size = st.size;
      mtime = _fmtTime(st.modified);
    } on Object {
      // 文件刚被删除：照常显示，点开时如实报错。
    }
    final String rel = file.path.startsWith('$baseDir/')
        ? file.path.substring(baseDir.length + 1)
        : file.path;
    return TgaIconTile(
      icon: Icons.description_outlined,
      title: rel,
      subtitle: '$size B · $mtime',
      showArrow: true,
      onTap: onTap,
    );
  }
}

/// 文本内容预览：真实读盘，超大 / 二进制如实提示。
class TgaFilePreviewPage extends StatefulWidget {
  const TgaFilePreviewPage({super.key, required this.file});
  final File file;

  @override
  State<TgaFilePreviewPage> createState() => _TgaFilePreviewPageState();
}

class _TgaFilePreviewPageState extends State<TgaFilePreviewPage> {
  static const int _maxPreviewBytes = 512 * 1024;

  String? _text;
  String _error = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (!await widget.file.exists()) {
        _error = '文件不存在';
      } else {
        final int len = await widget.file.length();
        if (len > _maxPreviewBytes) {
          _error = '文件过大（$len 字节 > ${_maxPreviewBytes ~/ 1024} KB），不支持预览';
        } else {
          final String raw = await const Utf8Decoder(allowMalformed: true)
              .bind(widget.file.openRead())
              .join();
          if (raw.codeUnits.contains(0)) {
            _error = '二进制文件，不支持文本预览';
          } else {
            _text = raw;
          }
        }
      }
    } on Object catch (e) {
      _error = '读取失败：$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final String name = widget.file.path.split('/').last;
    return TgaPage(
      title: name,
      child: _loading
          ? Center(
              child: SizedBox(
                  width: 26,
                  height: 26,
                  child:
                      CircularProgressIndicator(strokeWidth: 2.4, color: Tga.primary)),
            )
          : _error.isNotEmpty
              ? ListView(
                  padding:
                      const EdgeInsets.fromLTRB(Tga.pagePad, 40, Tga.pagePad, 32),
                  children: <Widget>[
                    TgaCard(child: TgaEmpty(_error, icon: Icons.info_outline_rounded)),
                  ],
                )
              : SingleChildScrollView(
                  padding:
                      const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
                  child: TgaCard(
                    child: SelectableText(
                      _text ?? '',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.55,
                          fontFamily: 'monospace',
                          color: Tga.text),
                    ),
                  ),
                ),
    );
  }
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

String _fmtTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

String _fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12)));
}
