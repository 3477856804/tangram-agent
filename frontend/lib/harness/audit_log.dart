/// 审计日志 —— 真实落盘的 append-only JSONL 事件流。
///
/// 与参考 harness 的 audit 语义一致：
///  * 文件固定为 `${root}/audit/audit.jsonl`，逐行追加，不重写历史；
///  * 写入前对 `detail` 做脱敏，避免把 token / 密码原样写进日志；
///  * 读取时损坏行直接跳过（不冒充数据），统计只基于真实读回的事件；
///  * 追加串行化，避免并发写让两行交错成坏行。
///
/// round15 轮转与性能：
///  * 当前文件达到 `maxFileBytes` 时在写新事件前轮转：旧文件重命名为
///    同目录下 `audit-<yyyyMMdd-HHmmss>-<seq>.jsonl`，新文件先写一条
///    轮转标记事件（category `audit`、action `rotated`、prevHash=旧尾
///    hash），哈希链因此跨文件不断；读取（all/query/stats/verifyChain/
///    exportJsonl）按时间顺序读全部轮转文件 + 当前文件；
///  * 尾 hash 缓存：append 不再每次全量读文件，只在缓存未加载时从磁盘
///    读最后一行非空行解析 hash（RandomAccessFile 从尾部倒读，扫到换行
///    即停；单行超长时倒读到文件头兜底）；append 成功后更新缓存，
///    写失败时置空。exportJsonl 改为导出全部文件拼接（行为变化）。
///
/// round17（沙箱审计第三阶段）导入重接链 + 溯源保留 + 导出去重：
///  * importJsonl 不再直接写原始行：每条导入行经 [_appendChained]
///    重新接入本链（prevHash 取本地链尾、hash 重算），原 id / ts 保留，
///    原 hash 存入 [AuditEvent.originHash] 溯源（原行无 hash 则为空串）；
///    导入同样受轮转约束，导入量大触发轮转时链也不断；
///  * exportJsonl 按 id 去重（首次出现为准）；同一份导出重复导入再
///    导出，结果不变（幂等）。不可解析行与 id 为空的行原样保留。
///  * 本文件不 import `store.dart`：后者经 path_provider 牵出 dart:ui，
///    纯 Dart VM 无法加载；AuditLog 只需要根目录，旧构造
///    `AuditLog(store: store)` 只取 `store.root`（见 [_rootOf]），
///    调用点保持不变；可测试构造见 [AuditLog.forDirectory]。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 一条审计事件。`ts` 为 Unix 秒（带小数，保留毫秒/微秒精度）。
///
/// [prevHash] / [hash] 构成防篡改哈希链：每条事件的 hash 由自身内容与
/// 上一条事件的 hash 共同决定，任何一行被改写都会让链在校验时断掉。
/// 历史日志里没有 hash 的旧事件按空 hash 处理（视为 legacy，跳过校验）。
/// 导入事件的原 hash 记在 [originHash] 里溯源，不参与链校验与 hash 计算。
class AuditEvent {
  AuditEvent({
    required this.id,
    required this.category,
    required this.action,
    this.decision = 'info',
    this.actor = 'system',
    this.detail = '',
    required this.ts,
    this.prevHash = '',
    this.hash = '',
    this.originHash = '',
  });

  final String id;
  final String category;
  final String action;
  final String decision;
  final String actor;
  final String detail;
  final double ts;
  final String prevHash;
  final String hash;

  /// 溯源：导入事件在原日志里的 hash（重新接链后原 hash 不再是链 hash，
  /// 在此保留以便溯源）；本地追加的事件与无 hash 的导入行留空。
  final String originHash;

  /// 按内容与 [prevHash] 重算哈希；写入与校验共用同一算法。
  String computeHash() => sha256
      .convert(utf8.encode(
        '$prevHash|$category|$action|$decision|$actor|$detail|${ts.toString()}',
      ))
      .toString();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'category': category,
        'action': action,
        'decision': decision,
        'actor': actor,
        'detail': detail,
        'ts': ts,
        if (prevHash.isNotEmpty) 'prevHash': prevHash,
        if (hash.isNotEmpty) 'hash': hash,
        if (originHash.isNotEmpty) 'originHash': originHash,
      };

  /// 容错解析：字段缺失或类型不符时用默认值，坏行由调用方决定是否跳过。
  factory AuditEvent.fromJson(Map<String, dynamic> json) {
    final Object? rawTs = json['ts'];
    double ts = 0;
    if (rawTs is num) {
      ts = rawTs.toDouble();
    } else if (rawTs is String) {
      ts = double.tryParse(rawTs) ?? 0;
    }
    final Object? rawPrevHash = json['prevHash'] ?? json['prev_hash'];
    final Object? rawOriginHash = json['originHash'] ?? json['origin_hash'];
    return AuditEvent(
      id: json['id']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      action: json['action']?.toString() ?? '',
      decision: json['decision']?.toString() ?? 'info',
      actor: json['actor']?.toString() ?? 'system',
      detail: json['detail']?.toString() ?? '',
      ts: ts,
      prevHash: rawPrevHash?.toString() ?? '',
      hash: json['hash']?.toString() ?? '',
      originHash: rawOriginHash?.toString() ?? '',
    );
  }
}

/// 密钥脱敏：只替换敏感**值**，其余文本原样保留。
abstract final class SecretRedactor {
  /// `Authorization: Bearer xxx` / `Basic xxx` 这类认证头整体脱敏。
  static final RegExp _authScheme = RegExp(
    r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=\-]+',
    caseSensitive: false,
  );

  /// `key=value` / `"key": "value"` 形式的敏感键值。
  /// 值不能是 Bearer/Basic，交给上一条规则处理，避免只吃掉方案名。
  static final RegExp _secretKeyValue = RegExp(
    r'''(?<![A-Za-z0-9_])(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|pwd|secret|client[_-]?secret|authorization)(["']?\s*[:=]\s*["']?)(?!Bearer\b|Basic\b)([^"'\s,;&}\]]+)''',
    caseSensitive: false,
  );

  static String redact(String input) {
    if (input.isEmpty) return input;
    final String withoutSchemes = input.replaceAllMapped(
      _authScheme,
      (Match m) => '${m[1]} ***',
    );
    return withoutSchemes.replaceAllMapped(
      _secretKeyValue,
      (Match m) => '${m[1]}${m[2]}***',
    );
  }
}

/// 审计日志门面：追加、查询、统计、导入导出。
class AuditLog {
  /// 旧构造：`store` 为生产侧的 HarnessStore（调用点
  /// `AuditLog(store: store)` 保持不变）。构造时只取 `store.root`，
  /// 之后内部一律以 [_root] 工作（`store.file('audit/audit.jsonl')`
  /// 与 `File('${store.root.path}/audit/audit.jsonl')` 等价）。
  /// dynamic 访问是刻意的：本文件不能 import store.dart（见文件头），
  /// store 的类型由调用方保证。
  AuditLog({required this.store})
      : _root = _rootOf(store),
        _maxFileBytes = _defaultMaxFileBytes;

  /// 可测试的命名构造：直接以根目录工作（纯 Dart VM 可跑；不依赖
  /// path_provider / Flutter）。`maxFileBytes` 为当前文件轮转阈值。
  AuditLog.forDirectory(Directory root, {int maxFileBytes = _defaultMaxFileBytes})
      : store = null,
        _root = root,
        _maxFileBytes = maxFileBytes;

  /// 旧构造传入的 store 对象（HarnessStore）；forDirectory 构造时为 null。
  /// 仅保留引用以兼容旧构造，内部读写一律用 [_root]。
  final Object? store;

  final Directory _root;

  /// 当前文件达到该字节数时，下一次 append 前轮转。
  final int _maxFileBytes;

  static const int _defaultMaxFileBytes = 512 * 1024;

  static const String _relativePath = 'audit/audit.jsonl';
  static const String _auditDirName = 'audit';
  static const String _currentFileName = 'audit.jsonl';

  /// 轮转文件名：audit-<yyyyMMdd-HHmmss>-<seq>.jsonl。
  static final RegExp _rotatedName =
      RegExp(r'^audit-(\d{8}-\d{6})-(\d+)\.jsonl$');

  static Directory _rootOf(Object? store) {
    final dynamic s = store;
    return s.root as Directory;
  }

  int _seq = 0;

  /// 轮转序号（同秒多次轮转时防文件名碰撞；进程内递增，同名已存在时
  /// 继续递增直到空闲）。
  int _rotateSeq = 0;

  /// 串行化追加链：并发 append 时按顺序写，单次失败不影响后续写入。
  Future<void> _writeChain = Future<void>.value();

  /// 尾 hash 缓存。`_tailHashLoaded` 为 false 时表示未加载（append 时
  /// 懒加载，从磁盘读尾行）；加载后即便链尾为空串也记 loaded=true。
  /// 写入成功后更新（append 与 importJsonl 都走 [_appendChained]）；
  /// 写失败时置空，避免缓存说谎。
  String? _tailHash;
  bool _tailHashLoaded = false;

  File get _file => File('${_root.path}/$_relativePath');

  Directory get _dir => Directory('${_root.path}/$_auditDirName');

  Future<void> _ensureDir() async {
    if (!await _dir.exists()) await _dir.create(recursive: true);
  }

  String _nextId() {
    _seq++;
    return 'audit-${DateTime.now().microsecondsSinceEpoch}-$_seq';
  }

  String _rotationStamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// 轮转当前文件：重命名为同目录下 `audit-<stamp>-<seq>.jsonl`。
  /// 调用方保证当前文件已存在；返回轮转后的文件。
  Future<File> _rotateCurrentFile() async {
    final String stamp = _rotationStamp(DateTime.now());
    File target;
    while (true) {
      _rotateSeq++;
      final String name =
          'audit-$stamp-${_rotateSeq.toString().padLeft(3, '0')}.jsonl';
      target = File('${_dir.path}/$name');
      if (!await target.exists()) break;
    }
    await _file.rename(target.path);
    return target;
  }

  /// 在新文件里先写一条轮转标记事件（category `audit`、action `rotated`、
  /// decision `info`、detail `prev=<旧尾 hash> file=<旧文件名>`，
  /// prevHash=<旧尾 hash>），哈希链因此跨文件不断。返回标记事件的 hash。
  Future<String> _writeRotationMarker(String prevHash, String oldName) async {
    final AuditEvent marker = AuditEvent(
      id: _nextId(),
      category: 'audit',
      action: 'rotated',
      decision: 'info',
      actor: 'system',
      detail: SecretRedactor.redact('prev=$prevHash file=$oldName'),
      ts: DateTime.now().microsecondsSinceEpoch / 1000000,
      prevHash: prevHash,
    );
    final Map<String, dynamic> json = marker.toJson()
      ..['hash'] = marker.computeHash();
    final IOSink sink = _file.openWrite(mode: FileMode.append);
    sink.writeln(jsonEncode(json));
    await sink.flush();
    await sink.close();
    return json['hash'] as String;
  }

  /// 读文件最后一行非空行（不含换行符）。文件不存在/为空/全是空行时
  /// 返回 null。RandomAccessFile 从尾部倒读 8KB 一块，扫到换行即停；
  /// 单行超长时一直倒读到文件头（等价于全量读该行，兜底）。
  Future<String?> _readLastNonEmptyLine(File f) async {
    if (!await f.exists()) return null;
    final int length = await f.length();
    if (length == 0) return null;
    final RandomAccessFile raf = await f.open();
    try {
      const int chunkSize = 8192;
      int end = length;
      String buf = '';
      while (end > 0) {
        final int start = end - chunkSize < 0 ? 0 : end - chunkSize;
        await raf.setPosition(start);
        final List<int> bytes = await raf.read(end - start);
        buf = utf8.decode(bytes, allowMalformed: true) + buf;
        end = start;
        // buf 覆盖 [start, 文件尾)；最后一行完整（以 EOF 结尾）。
        final String trimmedEnd = buf.replaceAll(RegExp(r'\s+$'), '');
        if (trimmedEnd.isEmpty) {
          if (end == 0) return null;
          buf = '';
          continue;
        }
        final int nl = trimmedEnd.lastIndexOf('\n');
        if (nl >= 0) {
          final String last = trimmedEnd.substring(nl + 1).trim();
          if (last.isNotEmpty) return last;
          buf = trimmedEnd.substring(0, nl);
          continue;
        }
        if (end == 0) {
          final String last = trimmedEnd.trim();
          return last.isEmpty ? null : last;
        }
        // 单行超长、未见换行：继续往前倒读。
      }
      return null;
    } finally {
      await raf.close();
    }
  }

  /// 解析一行取 hash；行损坏（非 JSON / 非 Map）时返回 null，
  /// 调用方全量读兜底。旧格式事件（无 hash）返回 ''。
  static String? _hashOfLine(String line) {
    try {
      final Object? decoded = jsonDecode(line);
      if (decoded is! Map) return null;
      return AuditEvent.fromJson(
        decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
      ).hash;
    } on Object {
      return null;
    }
  }

  /// 全量读一个文件取链尾 hash（尾行损坏时的兜底，与旧行为一致：
  /// 损坏行跳过，取最后一条可解析事件；无事件时为 ''）。
  Future<String> _fullTailHash(File f) async {
    final List<AuditEvent> events = await _readEventsFromFile(f);
    return events.isEmpty ? '' : events.last.hash;
  }

  /// 轮转文件里的链尾：按文件名倒序（时间升序的反向），取第一个有
  /// 有效行的文件尾 hash；都没有则 ''。
  Future<String> _rotatedTailHash() async {
    final List<File> rotated = await _rotatedFiles();
    for (final File f in rotated.reversed) {
      final String? lastLine = await _readLastNonEmptyLine(f);
      if (lastLine == null) continue;
      final String? hash = _hashOfLine(lastLine);
      if (hash != null) return hash;
      return _fullTailHash(f);
    }
    return '';
  }

  /// 懒加载链尾 hash：缓存未加载时只读当前文件最后一行非空行解析；
  /// 当前文件无有效行时到轮转文件里找；尾行损坏时全量读当前文件兜底。
  Future<String> _loadTailHash() async {
    if (_tailHashLoaded) return _tailHash ?? '';
    String tail = '';
    final String? lastLine = await _readLastNonEmptyLine(_file);
    if (lastLine != null) {
      tail = _hashOfLine(lastLine) ?? await _fullTailHash(_file);
    } else {
      tail = await _rotatedTailHash();
    }
    _tailHash = tail;
    _tailHashLoaded = true;
    return tail;
  }

  void _invalidateTailHash() {
    _tailHash = null;
    _tailHashLoaded = false;
  }

  /// 轮转文件（audit-<stamp>-<seq>.jsonl），按时间升序排列。
  /// 时间戳定长、seq 按数字比较；不合命名规范的文件不计入。
  Future<List<File>> _rotatedFiles() async {
    if (!await _dir.exists()) return <File>[];
    final List<File> out = <File>[];
    await for (final FileSystemEntity e in _dir.list(followLinks: false)) {
      if (e is! File) continue;
      final String name = e.path.split('/').last;
      if (name == _currentFileName) continue;
      if (!_rotatedName.hasMatch(name)) continue;
      out.add(e);
    }
    out.sort(_compareRotatedNames);
    return out;
  }

  static int _compareRotatedNames(File a, File b) {
    final String na = a.path.split('/').last;
    final String nb = b.path.split('/').last;
    final RegExpMatch? ma = _rotatedName.firstMatch(na);
    final RegExpMatch? mb = _rotatedName.firstMatch(nb);
    if (ma != null && mb != null) {
      final int byStamp = ma.group(1)!.compareTo(mb.group(1)!);
      if (byStamp != 0) return byStamp;
      final int sa = int.parse(ma.group(2)!);
      final int sb = int.parse(mb.group(2)!);
      if (sa != sb) return sa.compareTo(sb);
    }
    return na.compareTo(nb);
  }

  /// 全部日志文件（时间升序）：轮转文件 + 当前文件（若存在）。
  Future<List<File>> _allLogFiles() async {
    final List<File> files = await _rotatedFiles();
    if (await _file.exists()) files.add(_file);
    return files;
  }

  /// 追加一条事件；`detail` 先经 [SecretRedactor.redact] 再落盘。
  /// 落盘时自动接入哈希链：prevHash 取上一条事件的 hash（首条为空串）。
  /// 写新事件前，若当前文件已达 [maxFileBytes]，先轮转再写（轮转标记
  /// 事件先行，链不断）。append 成功后更新尾 hash 缓存。
  Future<void> append({
    required String category,
    required String action,
    String decision = 'info',
    String actor = 'system',
    String detail = '',
  }) {
    final AuditEvent draft = AuditEvent(
      id: _nextId(),
      category: category,
      action: action,
      decision: decision,
      actor: actor,
      detail: SecretRedactor.redact(detail),
      ts: DateTime.now().microsecondsSinceEpoch / 1000000,
    );
    return _appendChained(draft);
  }

  /// 串行接链写入：draft 自带 id / ts / category / action / decision /
  /// actor / detail（调用方保证 detail 已脱敏）与 originHash（导入事件
  /// 的原 hash，本地追加为空串）；方法内只负责接链——在串行链内取链尾
  /// hash、必要时先轮转（标记事件先行）、算 hash、写行、更新尾缓存。
  /// 写失败时缓存置空并把错误抛给调用方（不谎称已落盘），同时让串行链
  /// 恢复，避免一次磁盘异常导致后续写入全部级联失败。
  Future<void> _appendChained(AuditEvent draft) {
    final Future<void> write = _writeChain.then((_) async {
      try {
        await _ensureDir();
        // 在串行链内取链尾（缓存命中时不读磁盘），保证并发写入时
        // prevHash 不重复。
        String prevHash = await _loadTailHash();
        // 轮转：在串行链内、写新事件前检查当前文件大小。
        if (await _file.exists() &&
            await _file.length() >= _maxFileBytes) {
          final File rotated = await _rotateCurrentFile();
          final String rotatedName = rotated.path.split('/').last;
          prevHash = await _writeRotationMarker(prevHash, rotatedName);
        }
        final AuditEvent event = AuditEvent(
          id: draft.id,
          category: draft.category,
          action: draft.action,
          decision: draft.decision,
          actor: draft.actor,
          detail: draft.detail,
          ts: draft.ts,
          prevHash: prevHash,
          originHash: draft.originHash,
        );
        final Map<String, dynamic> json = event.toJson()
          ..['hash'] = event.computeHash();
        final IOSink sink = _file.openWrite(mode: FileMode.append);
        sink.writeln(jsonEncode(json));
        await sink.flush();
        await sink.close();
        _tailHash = json['hash'] as String;
        _tailHashLoaded = true;
      } catch (e) {
        // 写失败时缓存可能已说谎（如轮转后标记未写成），置空让下一
        // 次写入重新从磁盘读尾；错误本身照常抛给调用方。
        _invalidateTailHash();
        rethrow;
      }
    });
    // 写失败如实抛给调用方（不谎称已落盘），同时让串行链恢复，
    // 避免一次磁盘异常导致后续写入全部级联失败。
    _writeChain = write.catchError((Object _) {});
    return write;
  }

  /// 读取磁盘上的全部事件（按写入顺序，跨轮转文件）。损坏行跳过。
  /// 不等待 [_writeChain]，供串行链内部与 [all] 复用。
  Future<List<AuditEvent>> _readEvents() async {
    final List<AuditEvent> out = <AuditEvent>[];
    for (final File f in await _allLogFiles()) {
      out.addAll(await _readEventsFromFile(f));
    }
    return out;
  }

  /// 读取单个日志文件的全部事件（按写入顺序）。损坏行跳过。
  Future<List<AuditEvent>> _readEventsFromFile(File f) async {
    if (!await f.exists()) return <AuditEvent>[];
    final String raw = await f.readAsString();
    final List<AuditEvent> out = <AuditEvent>[];
    for (final String line in const LineSplitter().convert(raw)) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final Object? decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          out.add(AuditEvent.fromJson(
            decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
          ));
        }
      } on Object {
        // 半行 / 损坏行不冒充数据。
      }
    }
    return out;
  }

  /// 读取全部事件（按写入顺序，跨轮转文件）。损坏行跳过。
  Future<List<AuditEvent>> all() async {
    await _writeChain;
    return _readEvents();
  }

  /// 按分类与起始时间过滤，返回**最近** `limit` 条（保持时间升序）。
  Future<List<AuditEvent>> query({
    String? category,
    double? since,
    int limit = 200,
  }) async {
    final List<AuditEvent> events = await all();
    final List<AuditEvent> filtered = <AuditEvent>[];
    for (final AuditEvent e in events) {
      if (category != null && category.isNotEmpty && e.category != category) {
        continue;
      }
      if (since != null && e.ts < since) continue;
      filtered.add(e);
    }
    if (limit <= 0) return <AuditEvent>[];
    if (filtered.length <= limit) return filtered;
    return filtered.sublist(filtered.length - limit);
  }

  /// 总数 + 按 category / decision 的计数（只统计真实读回的事件）。
  Future<Map<String, dynamic>> stats() async {
    final List<AuditEvent> events = await all();
    final Map<String, int> byCategory = <String, int>{};
    final Map<String, int> byDecision = <String, int>{};
    for (final AuditEvent e in events) {
      byCategory[e.category] = (byCategory[e.category] ?? 0) + 1;
      byDecision[e.decision] = (byDecision[e.decision] ?? 0) + 1;
    }
    return <String, dynamic>{
      'total': events.length,
      'by_category': byCategory,
      'by_decision': byDecision,
    };
  }

  /// 校验防篡改哈希链（跨轮转文件，按时间顺序）。
  ///
  /// 逐条按同一算法重算（使用事件自身的 prevHash）并与落盘 hash 比对，
  /// 同时要求 prevHash 等于上一条事件的 hash（首条必须为空串）。
  /// 无 hash 的旧事件跳过校验，但计入 `legacy`。发现不一致立即返回
  /// `broken_at`（从 0 开始）。
  Future<Map<String, dynamic>> verifyChain() async {
    await _writeChain;
    final List<AuditEvent> events = await _readEvents();
    int legacy = 0;
    String expectedPrev = '';
    for (int i = 0; i < events.length; i++) {
      final AuditEvent e = events[i];
      if (e.hash.isEmpty) {
        legacy++;
        expectedPrev = e.hash;
        continue;
      }
      if (e.prevHash != expectedPrev) {
        return <String, dynamic>{
          'ok': false,
          'total': events.length,
          'broken_at': i,
          'legacy': legacy,
          'reason': '第 ${i + 1} 条事件的 prevHash 与上一条事件的 hash 不一致'
              '（期望 "$expectedPrev"，实际 "${e.prevHash}"）',
        };
      }
      if (e.computeHash() != e.hash) {
        return <String, dynamic>{
          'ok': false,
          'total': events.length,
          'broken_at': i,
          'legacy': legacy,
          'reason': '第 ${i + 1} 条事件内容与存储 hash 不匹配，疑似被篡改',
        };
      }
      expectedPrev = e.hash;
    }
    return <String, dynamic>{
      'ok': true,
      'total': events.length,
      'broken_at': null,
      'legacy': legacy,
      'reason': legacy == 0
          ? '哈希链完整（共 ${events.length} 条）'
          : '哈希链完整（共 ${events.length} 条，其中 $legacy 条旧格式事件无 hash）',
    };
  }

  /// 原样导出全部 JSONL 文本：轮转文件（时间升序）+ 当前文件依次拼接；
  /// 无任何文件时返回空串。round15 行为变化：旧版只导出当前文件。
  ///
  /// 导出按 id 去重（首次出现为准）：可解析且 id 非空的行，重复 id 只
  /// 保留第一次出现；不可解析行与 id 为空的行原样保留。同一份导出重复
  /// 导入再导出，结果不变（幂等）。
  Future<String> exportJsonl() async {
    await _writeChain;
    final StringBuffer buf = StringBuffer();
    final Set<String> seenIds = <String>{};
    for (final File f in await _allLogFiles()) {
      if (!await f.exists()) continue;
      final String raw = await f.readAsString();
      for (final String line in const LineSplitter().convert(raw)) {
        final String trimmed = line.trim();
        if (trimmed.isEmpty) {
          buf.writeln(line);
          continue;
        }
        String? id;
        try {
          final Object? decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            final Object? rawId = decoded['id'];
            id = rawId?.toString() ?? '';
          }
        } on Object {
          // 不可解析行原样保留。
          id = null;
        }
        if (id != null && id.isNotEmpty) {
          if (!seenIds.add(id)) continue; // 重复 id 只保留首次出现。
        }
        buf.writeln(line);
      }
    }
    return buf.toString();
  }

  /// 逐行导入：坏行 / 缺关键字段的行跳过，返回成功追加的条数。
  /// 导入前同样脱敏，避免把外部日志里的明文密钥带回磁盘。
  /// 导入事件重新接入本链：每条导入行保留原 id / category / action /
  /// decision / actor / detail / ts，原 hash 存入 originHash 溯源
  /// （原行无 hash 则为空串），prevHash 取本地链尾、hash 重算；导入
  /// 同样受轮转约束（经 [_appendChained]，导入量大触发轮转时链也不断）。
  /// 与 append 交错时同样保证正确。
  Future<int> importJsonl(String content) async {
    final List<String> lines = const LineSplitter().convert(content);
    int imported = 0;
    await _ensureDir();
    for (final String line in lines) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      AuditEvent event;
      try {
        final Object? decoded = jsonDecode(trimmed);
        if (decoded is! Map) continue;
        event = AuditEvent.fromJson(
          decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
        );
      } on Object {
        continue;
      }
      if (event.id.isEmpty || event.category.isEmpty || event.action.isEmpty) {
        continue;
      }
      final AuditEvent safe = AuditEvent(
        id: event.id,
        category: event.category,
        action: event.action,
        decision: event.decision,
        actor: event.actor,
        detail: SecretRedactor.redact(event.detail),
        ts: event.ts,
        originHash: event.hash,
      );
      await _appendChained(safe);
      imported++;
    }
    return imported;
  }
}
