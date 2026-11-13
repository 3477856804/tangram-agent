import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 作品类型（由目录内真实产物判定）。
enum TgaWorkKind { website, app, script }

String tgaWorkKindLabel(TgaWorkKind kind) => switch (kind) {
      TgaWorkKind.website => '网站',
      TgaWorkKind.app => 'App',
      TgaWorkKind.script => '脚本',
    };

/// 一个「作品」：真实工作区里一个含产物的目录。
///
/// 全部字段来自磁盘真实扫描（mtime / 字节数 / 文件数），不做任何虚构。
class TgaWork {
  TgaWork({
    required this.name,
    required this.kind,
    required this.dirPath,
    required this.modified,
    required this.totalBytes,
    required this.fileCount,
    this.entryFile,
  });

  /// 展示名：目录名（根目录散件作品用根目录名）。
  final String name;
  final TgaWorkKind kind;

  /// 作品目录绝对路径。
  final String dirPath;

  /// 目录内产物的最近修改时间。
  final DateTime modified;

  /// 目录内文件总字节数与文件数（递归，有上限防失控）。
  final int totalBytes;
  final int fileCount;

  /// 网站类作品的主 html（优先 index.html，否则最大的 html）。
  final String? entryFile;
}

/// 作品登记表：扫描 Agent 真实写文件的目录，把含产物的子目录识别为作品。
///
/// 扫描根（与后端真实写入位置一致）：
///  1. PersonaStore.workspaceRoot —— 用户创建的「本地工作区」
///     （tga_workspace_page 经 device_file mkdir 落在 App 沙箱内）；
///  2. <App 文档目录>/tangram_harness/sandbox —— 内置沙箱 shell /
///     code_task / device_file 的可写根（embedded_backend 的 writable_roots）。
///
/// 判定规则（递归，深度与文件数有限）：有 *.html → 网站；有 pubspec.yaml
/// → App；有 *.py / *.sh → 脚本。隐藏目录（. 开头，含隔离区）一律跳过。
class WorksRegistry {
  WorksRegistry._();

  static const int _maxDepth = 4;
  static const int _maxFiles = 500;

  /// 扫描全部真实工作区根，返回按最近修改排序的作品列表。
  static Future<List<TgaWork>> scan({String? workspaceRoot}) async {
    final List<String> roots = await _roots(workspaceRoot);
    final List<TgaWork> out = <TgaWork>[];
    for (final String root in roots) {
      final Directory dir = Directory(root);
      if (!dir.existsSync()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on Object {
        continue;
      }
      for (final FileSystemEntity e in entries) {
        if (e is! Directory) continue;
        final String name = _baseName(e.path);
        if (name.startsWith('.')) continue;
        final _DirArtifacts? a = _inspect(e, 1);
        if (a == null) continue;
        out.add(TgaWork(
          name: name,
          kind: a.kind!,
          dirPath: e.path,
          modified: a.modified,
          totalBytes: a.totalBytes,
          fileCount: a.fileCount,
          entryFile: a.entryHtml,
        ));
      }
      // 根目录直接散落的产物（Agent 常把单个脚本 / html 写在根）：
      // 只看根目录这一层的文件，不与子目录作品重复计数。
      final _DirArtifacts? loose = _inspectLoose(dir);
      if (loose != null) {
        out.add(TgaWork(
          name: _baseName(dir.path),
          kind: loose.kind!,
          dirPath: dir.path,
          modified: loose.modified,
          totalBytes: loose.totalBytes,
          fileCount: loose.fileCount,
          entryFile: loose.entryHtml,
        ));
      }
    }
    out.sort((TgaWork a, TgaWork b) => b.modified.compareTo(a.modified));
    return out;
  }

  /// 作品目录内的真实文件清单（相对路径展示，递归，跳过隐藏项）。
  static List<File> listFiles(String dirPath, {int max = 300}) {
    final Directory dir = Directory(dirPath);
    if (!dir.existsSync()) return <File>[];
    final List<File> out = <File>[];
    void walk(Directory d, int depth) {
      if (depth > _maxDepth || out.length >= max) return;
      List<FileSystemEntity> entries;
      try {
        entries = d.listSync(followLinks: false);
      } on Object {
        return;
      }
      entries.sort((FileSystemEntity a, FileSystemEntity b) =>
          a.path.compareTo(b.path));
      for (final FileSystemEntity e in entries) {
        if (out.length >= max) return;
        final String name = _baseName(e.path);
        if (name.startsWith('.')) continue;
        if (e is File) {
          out.add(e);
        } else if (e is Directory) {
          walk(e, depth + 1);
        }
      }
    }

    walk(dir, 1);
    return out;
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  static Future<List<String>> _roots(String? workspaceRoot) async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } on Object {
      base = Directory.systemTemp;
    }
    final List<String> out = <String>[];
    final String ws = (workspaceRoot ?? '').trim();
    if (ws.isNotEmpty) out.add(ws);
    final String sandbox = '${base.path}/tangram_harness/sandbox';
    if (!out.contains(sandbox)) out.add(sandbox);
    return out;
  }

  static String _baseName(String path) =>
      path.replaceAll('\\', '/').split('/').where((String s) => s.isNotEmpty).last;

  /// 递归统计一个目录的产物特征；无产物返回 null。
  static _DirArtifacts? _inspect(Directory dir, int depth) {
    final _DirArtifacts acc = _DirArtifacts();
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on Object {
      return null;
    }
    for (final FileSystemEntity e in entries) {
      if (acc.fileCount >= _maxFiles) break;
      final String name = _baseName(e.path);
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        if (depth >= _maxDepth) continue;
        final _DirArtifacts? sub = _inspect(e, depth + 1);
        if (sub == null) continue;
        acc.merge(sub);
      } else if (e is File) {
        FileStat stat;
        try {
          stat = e.statSync();
        } on Object {
          continue;
        }
        acc.addFile(name, e.path, stat);
      }
    }
    return acc.toResult();
  }

  /// 只看目录这一层的文件（根目录散件判定，不递归子目录）。
  static _DirArtifacts? _inspectLoose(Directory dir) {
    final _DirArtifacts acc = _DirArtifacts();
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on Object {
      return null;
    }
    for (final FileSystemEntity e in entries) {
      if (acc.fileCount >= _maxFiles) break;
      if (e is! File) continue;
      final String name = _baseName(e.path);
      if (name.startsWith('.')) continue;
      FileStat stat;
      try {
        stat = e.statSync();
      } on Object {
        continue;
      }
      acc.addFile(name, e.path, stat);
    }
    return acc.toResult();
  }
}

/// 扫描累加器：产物特征 + 体量统计。
class _DirArtifacts {
  bool html = false;
  bool pubspec = false;
  bool script = false;
  int totalBytes = 0;
  int fileCount = 0;
  DateTime modified = DateTime.fromMillisecondsSinceEpoch(0);
  String? entryHtml;
  int _entryHtmlSize = -1;

  void addFile(String name, String path, FileStat stat) {
    fileCount += 1;
    totalBytes += stat.size;
    if (stat.modified.isAfter(modified)) modified = stat.modified;
    final String lower = name.toLowerCase();
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      html = true;
      // index.html 优先；同为 index / 同为普通 html 时取更大的那个作入口。
      final bool otherIndex = _isIndex(entryHtml);
      if (lower == 'index.html') {
        if (!otherIndex || stat.size > _entryHtmlSize) _setEntry(path, stat.size);
      } else if (entryHtml == null ||
          (!otherIndex && stat.size > _entryHtmlSize)) {
        _setEntry(path, stat.size);
      }
    } else if (lower == 'pubspec.yaml') {
      pubspec = true;
    } else if (lower.endsWith('.py') || lower.endsWith('.sh')) {
      script = true;
    }
  }

  void _setEntry(String path, int size) {
    entryHtml = path;
    _entryHtmlSize = size;
  }

  void merge(_DirArtifacts other) {
    html |= other.html;
    pubspec |= other.pubspec;
    script |= other.script;
    totalBytes += other.totalBytes;
    fileCount += other.fileCount;
    if (other.modified.isAfter(modified)) modified = other.modified;
    if (other.entryHtml != null) {
      final bool otherIndex = _isIndex(other.entryHtml);
      final bool curIndex = _isIndex(entryHtml);
      if (entryHtml == null ||
          (otherIndex && !curIndex) ||
          (!otherIndex && !curIndex && other._entryHtmlSize > _entryHtmlSize)) {
        _setEntry(other.entryHtml!, other._entryHtmlSize);
      }
    }
  }

  TgaWorkKind? get kind =>
      html ? TgaWorkKind.website : (pubspec ? TgaWorkKind.app : (script ? TgaWorkKind.script : null));

  _DirArtifacts? toResult() => kind == null ? null : this;

  static bool _isIndex(String? path) =>
      path != null && _leaf(path).toLowerCase() == 'index.html';

  static String _leaf(String path) => path.split('/').last;
}
