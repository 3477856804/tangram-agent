/// Tangram 本地存储 —— 纯 Dart 的真实持久化层。
///
/// 把参考 harness 的「SQLite 记忆 / JSONL 轨迹 / 版本池目录」语义映射到
/// Android 可用的 App 私有目录（path_provider + dart:io），全部数据真实落盘，
/// 重启后可恢复；不编造、不内存伪造。所有写操作都先写临时文件再原子改名，
/// 避免中途崩溃留下半个 JSON。

library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class HarnessStore {
  HarnessStore._(this.root);

  static HarnessStore? _instance;
  final Directory root;

  /// 全局唯一实例。首次调用时解析 App 文档目录并创建子目录树。
  ///
  /// 真实降级链：path_provider 的 App 文档目录 → 系统临时目录。两者都是
  /// **真实磁盘目录**，数据依旧真实落盘、重启可恢复；绝不退化成纯内存伪造。
  /// 桌面无 XDG 环境时 path_provider 会抛 MissingPlatformDirectoryException，
  /// 降级保证 APP 依然可用。
  static Future<HarnessStore> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } on Object {
      base = Directory.systemTemp;
    }
    final dir = Directory('${base.path}/tangram_harness');
    if (!await dir.exists()) await dir.create(recursive: true);
    for (final sub in <String>['models', 'cards', 'plugins', 'work', 'downloads', 'sandbox']) {
      final d = Directory('${dir.path}/$sub');
      if (!await d.exists()) await d.create(recursive: true);
    }
    _instance = HarnessStore._(dir);
    return _instance!;
  }

  /// 允许测试注入自定义根目录。
  static void overrideForTest(Directory dir) {
    _instance = HarnessStore._(dir);
  }

  Directory sub(String name) => Directory('${root.path}/$name');

  File file(String relative) => File('${root.path}/$relative');

  // ---- JSON 文档读/写（原子替换）----

  Future<Map<String, dynamic>> readJson(
    String relative, {
    Map<String, dynamic> fallback = const <String, dynamic>{},
  }) async {
    try {
      final f = file(relative);
      if (!await f.exists()) return Map<String, dynamic>.of(fallback);
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) {
        return decoded.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
      }
    } on Object {
      // 损坏的文件不冒充数据，回退到空态。
    }
    return Map<String, dynamic>.of(fallback);
  }

  Future<List<dynamic>> readList(String relative) async {
    try {
      final f = file(relative);
      if (!await f.exists()) return <dynamic>[];
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is List) return decoded;
    } on Object {
      // 同上。
    }
    return <dynamic>[];
  }

  Future<void> writeJson(String relative, Object? value) async {
    final f = file(relative);
    final parent = f.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(f.path);
  }

  // ---- 列表型集合（日记 / 规则 / 审批 / 轨迹 / 模型卡）----

  Future<List<Map<String, dynamic>>> readRecords(String key) async {
    final raw = await readList('$key.json');
    return raw
        .whereType<Map>()
        .map((Map<dynamic, dynamic> m) =>
            m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)))
        .toList();
  }

  Future<void> writeRecords(
    String key,
    List<Map<String, dynamic>> records,
  ) async {
    await writeJson('$key.json', records);
  }

  Future<int> insert(String key, Map<String, dynamic> record) async {
    final records = await readRecords(key);
    int maxId = 0;
    for (final r in records) {
      final id = r['id'];
      if (id is int && id > maxId) maxId = id;
    }
    final next = maxId + 1;
    records.add(<String, dynamic>{'id': next, ...record});
    await writeRecords(key, records);
    return next;
  }

  Future<bool> update(
    String key,
    int id,
    Map<String, dynamic> changes,
  ) async {
    final records = await readRecords(key);
    var changed = false;
    for (var i = 0; i < records.length; i++) {
      if (records[i]['id'] == id) {
        records[i] = <String, dynamic>{...records[i], ...changes};
        changed = true;
        break;
      }
    }
    if (changed) await writeRecords(key, records);
    return changed;
  }

  Future<bool> remove(String key, int id) async {
    final records = await readRecords(key);
    final before = records.length;
    records.removeWhere((Map<String, dynamic> r) => r['id'] == id);
    if (records.length == before) return false;
    await writeRecords(key, records);
    return true;
  }

  // ---- 目录扫描（真实文件，不虚构模型/插件）----

  List<Map<String, dynamic>> scanFiles(
    String subDir, {
    Set<String> extensions = const <String>{'.gguf', '.json'},
  }) {
    final dir = sub(subDir);
    if (!dir.existsSync()) return <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (extensions.isNotEmpty &&
          !extensions.any((String e) => name.toLowerCase().endsWith(e))) {
        continue;
      }
      final stat = entity.statSync();
      out.add(<String, dynamic>{
        'name': name,
        'path': entity.path,
        'size': stat.size,
        'modified': stat.modified.toIso8601String(),
      });
    }
    out.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        (a['name'] as String).compareTo(b['name'] as String));
    return out;
  }

  /// 真实磁盘可用空间 / 目录可写性（用于 rpc selftest 与 hardware）。
  bool get writable {
    try {
      final probe = File('${root.path}/.write_probe');
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return true;
    } on Object {
      return false;
    }
  }

  int get totalModelBytes {
    final dir = sub('models');
    if (!dir.existsSync()) return 0;
    var total = 0;
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is File) total += entity.statSync().size;
    }
    return total;
  }
}
