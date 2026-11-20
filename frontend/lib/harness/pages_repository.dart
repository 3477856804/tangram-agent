/// Pages —— Agent 生成的可版本化看板 / 文档。
///
/// 纯 Dart 仓储层，不依赖 Flutter / path_provider，便于独立回归测试。
/// 移植自 Rakazo `packages/core` + `apps/api/src/content/pages.ts` 的产品语义：
/// 一个 Page 有标题、当前版本、置顶、私有 / 链接可见三种状态，每次保存都
/// 追加一个新版本而不是覆盖历史。TGA 是端侧运行时，没有 Rakazo 的 Web
/// 服务，因此「链接可见」只作为元数据保留，真实分享走导出 HTML 文件 +
/// 系统分享面板，绝不再造一个打不开的假 URL。
///
/// 真实性约束：
///  * 版本文件真实落盘到 `pages/<id>/v<n>.html`，临时文件 + 原子改名；
///  * 索引写 `pages.json`，与版本文件在同一事务锁内更新；
///  * 标题、HTML 大小、版本号都做边界校验，失败返回结构化错误。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// 页面可见性。`link` 表示允许持有分享令牌的人查看；端侧没有服务端，
/// 该状态只影响 UI 提示与后续同步，不会伪造公网地址。
enum PageVisibility { private, link }

class TgaPageRecord {
  const TgaPageRecord({
    required this.id,
    required this.title,
    required this.currentVersion,
    required this.visibility,
    required this.pinned,
    required this.botId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final int currentVersion;
  final PageVisibility visibility;
  final bool pinned;
  final String botId;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'current_version': currentVersion,
    'visibility': visibility.name,
    'pinned': pinned,
    'bot_id': botId,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  static TgaPageRecord? tryParse(Map<String, dynamic> raw) {
    final String id = (raw['id'] ?? '').toString().trim();
    final String title = (raw['title'] ?? '').toString().trim();
    if (id.isEmpty || title.isEmpty) return null;
    final int version = raw['current_version'] is int
        ? raw['current_version'] as int
        : int.tryParse('${raw['current_version']}') ?? 0;
    if (version < 1) return null;
    final DateTime? created = DateTime.tryParse('${raw['created_at']}');
    final DateTime? updated = DateTime.tryParse('${raw['updated_at']}');
    if (created == null || updated == null) return null;
    return TgaPageRecord(
      id: id,
      title: title,
      currentVersion: version,
      visibility: '${raw['visibility']}' == 'link'
          ? PageVisibility.link
          : PageVisibility.private,
      pinned: raw['pinned'] == true,
      botId: (raw['bot_id'] ?? '').toString(),
      createdAt: created,
      updatedAt: updated,
    );
  }
}

class PagesRepository {
  PagesRepository(this.root);

  final Directory root;

  static const int maxHtmlBytes = 2 * 1024 * 1024;
  static const int maxTitleLength = 120;
  static const String _indexPath = 'pages.json';
  static const String _dirName = 'pages';

  Future<void> _tail = Future<void>.value();

  /// 所有写操作串行执行，避免并发保存把 current_version 写乱。
  Future<T> _guard<T>(Future<T> Function() work) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await work());
      } on Object catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  Directory get _root => Directory('${root.path}/$_dirName');

  String _newId() {
    final int now = DateTime.now().microsecondsSinceEpoch;
    final int salt = Random.secure().nextInt(1 << 32);
    return 'page-${now.toRadixString(36)}-${salt.toRadixString(36)}';
  }

  Future<List<dynamic>> _readIndexRaw() async {
    final File f = File('${root.path}/$_indexPath');
    if (!await f.exists()) return <dynamic>[];
    try {
      final dynamic decoded = jsonDecode(await f.readAsString());
      if (decoded is Map && decoded['pages'] is List) {
        return decoded['pages'] as List<dynamic>;
      }
    } on Object {
      // 损坏的索引不冒充数据；下次写入会重建。
    }
    return <dynamic>[];
  }

  Future<List<TgaPageRecord>> _readIndex() async {
    final List<dynamic> raw = await _readIndexRaw();
    final List<TgaPageRecord> out = <TgaPageRecord>[];
    for (final dynamic item in raw) {
      if (item is! Map) continue;
      final TgaPageRecord? page = TgaPageRecord.tryParse(
        item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
      );
      if (page != null) out.add(page);
    }
    return out;
  }

  Future<void> _writeIndex(List<TgaPageRecord> pages) async {
    final File target = File('${root.path}/$_indexPath');
    await target.parent.create(recursive: true);
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, dynamic>{
        'pages': pages.map((TgaPageRecord p) => p.toJson()).toList(),
      }),
      flush: true,
    );
    await tmp.rename(target.path);
  }

  static List<TgaPageRecord> _sort(List<TgaPageRecord> pages) {
    final List<TgaPageRecord> copy = List<TgaPageRecord>.of(pages);
    copy.sort((TgaPageRecord a, TgaPageRecord b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return copy;
  }

  static String? _validateTitle(String title) {
    final String t = title.trim();
    if (t.isEmpty) return '标题不能为空';
    if (t.length > maxTitleLength) return '标题不能超过 $maxTitleLength 个字符';
    return null;
  }

  static String? _validateHtml(String html) {
    final int bytes = utf8.encode(html).length;
    if (bytes == 0) return '页面内容不能为空';
    if (bytes > maxHtmlBytes) {
      return '页面内容超过 ${maxHtmlBytes ~/ (1024 * 1024)} MB 上限';
    }
    return null;
  }

  Future<void> _writeVersion(String id, int version, String html) async {
    final Directory dir = Directory('${_root.path}/$id');
    await dir.create(recursive: true);
    final File target = File('${dir.path}/v$version.html');
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(html, flush: true);
    await tmp.rename(target.path);
  }

  Future<String> readVersion(String id, int version) async {
    final File f = File('${_root.path}/$id/v$version.html');
    if (!await f.exists()) {
      throw StateError('页面版本不存在：$id v$version');
    }
    return f.readAsString();
  }

  /// 版本号从新到旧。
  Future<List<int>> versions(String id) async {
    final Directory dir = Directory('${_root.path}/$id');
    if (!await dir.exists()) return <int>[];
    final List<int> out = <int>[];
    await for (final FileSystemEntity e in dir.list()) {
      if (e is! File || !e.path.endsWith('.html')) continue;
      final String name = e.uri.pathSegments.last;
      final RegExpMatch? m = RegExp(r'^v(\d+)\.html$').firstMatch(name);
      if (m == null) continue;
      final int? v = int.tryParse(m.group(1) ?? '');
      if (v != null && v > 0) out.add(v);
    }
    out.sort((int a, int b) => b.compareTo(a));
    return out;
  }

  Future<Map<String, dynamic>> list({String query = ''}) async {
    final String q = query.trim().toLowerCase();
    final List<TgaPageRecord> all = _sort(await _readIndex());
    final List<TgaPageRecord> filtered = q.isEmpty
        ? all
        : all
              .where((TgaPageRecord p) => p.title.toLowerCase().contains(q))
              .toList();
    return <String, dynamic>{
      'ok': true,
      'pages': filtered.map((TgaPageRecord p) => p.toJson()).toList(),
      'total': filtered.length,
      'storage': 'app-private-json+html',
    };
  }

  Future<Map<String, dynamic>> create({
    required String title,
    required String html,
    String botId = '',
    PageVisibility visibility = PageVisibility.private,
  }) {
    return _guard(() async {
      final String? titleError = _validateTitle(title);
      if (titleError != null)
        return <String, dynamic>{'ok': false, 'error': titleError};
      final String? htmlError = _validateHtml(html);
      if (htmlError != null)
        return <String, dynamic>{'ok': false, 'error': htmlError};

      final DateTime now = DateTime.now();
      final String id = _newId();
      await _writeVersion(id, 1, html);
      final TgaPageRecord page = TgaPageRecord(
        id: id,
        title: title.trim(),
        currentVersion: 1,
        visibility: visibility,
        pinned: false,
        botId: botId,
        createdAt: now,
        updatedAt: now,
      );
      final List<TgaPageRecord> pages = (await _readIndex())..add(page);
      await _writeIndex(pages);
      return <String, dynamic>{'ok': true, 'page': page.toJson()};
    });
  }

  Future<Map<String, dynamic>> get(String id, {int? version}) async {
    final List<TgaPageRecord> pages = await _readIndex();
    final int index = pages.indexWhere((TgaPageRecord p) => p.id == id);
    if (index < 0) return <String, dynamic>{'ok': false, 'error': '页面不存在'};
    final TgaPageRecord page = pages[index];
    final int v = version ?? page.currentVersion;
    if (v < 1 || v > page.currentVersion) {
      return <String, dynamic>{'ok': false, 'error': '版本不存在：$v'};
    }
    final File f = File('${_root.path}/$id/v$v.html');
    if (!await f.exists()) {
      return <String, dynamic>{'ok': false, 'error': '版本文件缺失：v$v'};
    }
    return <String, dynamic>{
      'ok': true,
      'page': page.toJson(),
      'version': v,
      'html': await f.readAsString(),
      'versions': await versions(id),
      'path': f.path,
    };
  }

  Future<Map<String, dynamic>> save(
    String id,
    String html, {
    String? title,
    PageVisibility? visibility,
  }) {
    return _guard(() async {
      final String? htmlError = _validateHtml(html);
      if (htmlError != null)
        return <String, dynamic>{'ok': false, 'error': htmlError};
      if (title != null) {
        final String? titleError = _validateTitle(title);
        if (titleError != null)
          return <String, dynamic>{'ok': false, 'error': titleError};
      }
      final List<TgaPageRecord> pages = await _readIndex();
      final int index = pages.indexWhere((TgaPageRecord p) => p.id == id);
      if (index < 0) return <String, dynamic>{'ok': false, 'error': '页面不存在'};
      final TgaPageRecord old = pages[index];
      final int next = old.currentVersion + 1;
      await _writeVersion(id, next, html);
      final TgaPageRecord page = TgaPageRecord(
        id: old.id,
        title: title?.trim() ?? old.title,
        currentVersion: next,
        visibility: visibility ?? old.visibility,
        pinned: old.pinned,
        botId: old.botId,
        createdAt: old.createdAt,
        updatedAt: DateTime.now(),
      );
      pages[index] = page;
      await _writeIndex(pages);
      return <String, dynamic>{'ok': true, 'page': page.toJson()};
    });
  }

  Future<Map<String, dynamic>> updateMeta(
    String id, {
    String? title,
    bool? pinned,
    PageVisibility? visibility,
  }) {
    return _guard(() async {
      if (title != null) {
        final String? titleError = _validateTitle(title);
        if (titleError != null)
          return <String, dynamic>{'ok': false, 'error': titleError};
      }
      final List<TgaPageRecord> pages = await _readIndex();
      final int index = pages.indexWhere((TgaPageRecord p) => p.id == id);
      if (index < 0) return <String, dynamic>{'ok': false, 'error': '页面不存在'};
      final TgaPageRecord old = pages[index];
      final TgaPageRecord page = TgaPageRecord(
        id: old.id,
        title: title?.trim() ?? old.title,
        currentVersion: old.currentVersion,
        visibility: visibility ?? old.visibility,
        pinned: pinned ?? old.pinned,
        botId: old.botId,
        createdAt: old.createdAt,
        updatedAt: DateTime.now(),
      );
      pages[index] = page;
      await _writeIndex(pages);
      return <String, dynamic>{'ok': true, 'page': page.toJson()};
    });
  }

  Future<Map<String, dynamic>> delete(String id) {
    return _guard(() async {
      final List<TgaPageRecord> pages = await _readIndex();
      final int before = pages.length;
      pages.removeWhere((TgaPageRecord p) => p.id == id);
      if (pages.length == before) {
        return <String, dynamic>{'ok': false, 'error': '页面不存在'};
      }
      await _writeIndex(pages);
      final Directory dir = Directory('${_root.path}/$id');
      if (await dir.exists()) await dir.delete(recursive: true);
      return <String, dynamic>{'ok': true, 'deleted': id};
    });
  }

  /// 导出某个版本为独立 HTML 文件，返回真实路径，供系统分享 / 浏览器打开。
  Future<Map<String, dynamic>> export(String id, {int? version}) async {
    final Map<String, dynamic> detail = await get(id, version: version);
    if (detail['ok'] != true) return detail;
    final String path = '${detail['path']}';
    final File source = File(path);
    final File out = File(
      '${_root.path}/$id/export-v${detail['version']}.html',
    );
    await source.copy(out.path);
    return <String, dynamic>{
      'ok': true,
      'path': out.path,
      'filename': '${detail['page']['title']}.html',
      'version': detail['version'],
    };
  }
}
