/// 审计日志 —— 真实落盘的 append-only JSONL 事件流。
///
/// 与参考 harness 的 audit 语义一致：
///  * 文件固定为 `${store.root.path}/audit/audit.jsonl`，逐行追加，不重写历史；
///  * 写入前对 `detail` 做脱敏，避免把 token / 密码原样写进日志；
///  * 读取时损坏行直接跳过（不冒充数据），统计只基于真实读回的事件；
///  * 追加串行化，避免并发写让两行交错成坏行。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'store.dart';

/// 一条审计事件。`ts` 为 Unix 秒（带小数，保留毫秒/微秒精度）。
///
/// [prevHash] / [hash] 构成防篡改哈希链：每条事件的 hash 由自身内容与
/// 上一条事件的 hash 共同决定，任何一行被改写都会让链在校验时断掉。
/// 历史日志里没有 hash 的旧事件按空 hash 处理（视为 legacy，跳过校验）。
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
  AuditLog({required this.store});

  final HarnessStore store;

  static const String _relativePath = 'audit/audit.jsonl';

  int _seq = 0;

  /// 串行化追加链：并发 append 时按顺序写，单次失败不影响后续写入。
  Future<void> _writeChain = Future<void>.value();

  File get _file => store.file(_relativePath);

  Directory get _dir => Directory('${store.root.path}/audit');

  Future<void> _ensureDir() async {
    if (!await _dir.exists()) await _dir.create(recursive: true);
  }

  String _nextId() {
    _seq++;
    return 'audit-${DateTime.now().microsecondsSinceEpoch}-$_seq';
  }

  /// 追加一条事件；`detail` 先经 [SecretRedactor.redact] 再落盘。
  /// 落盘时自动接入哈希链：prevHash 取上一条事件的 hash（首条为空串）。
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
    final Future<void> write = _writeChain.then((_) async {
      await _ensureDir();
      // 在串行链内读取当前链尾，保证并发 append 时 prevHash 不重复。
      final List<AuditEvent> existing = await _readEvents();
      final String prevHash =
          existing.isEmpty ? '' : existing.last.hash;
      final AuditEvent event = AuditEvent(
        id: draft.id,
        category: draft.category,
        action: draft.action,
        decision: draft.decision,
        actor: draft.actor,
        detail: draft.detail,
        ts: draft.ts,
        prevHash: prevHash,
      );
      final Map<String, dynamic> json = event.toJson()
        ..['hash'] = event.computeHash();
      final IOSink sink = _file.openWrite(mode: FileMode.append);
      sink.writeln(jsonEncode(json));
      await sink.flush();
      await sink.close();
    });
    // 写失败如实抛给调用方（不谎称已落盘），同时让串行链恢复，
    // 避免一次磁盘异常导致后续 append 全部级联失败。
    _writeChain = write.catchError((Object _) {});
    return write;
  }

  /// 读取磁盘上的全部事件（按写入顺序）。损坏行跳过。
  /// 不等待 [_writeChain]，供串行链内部与 [all] 复用。
  Future<List<AuditEvent>> _readEvents() async {
    final File f = _file;
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

  /// 读取全部事件（按写入顺序）。损坏行跳过。
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

  /// 校验防篡改哈希链。
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

  /// 原样导出 JSONL 文本；文件不存在时返回空串。
  Future<String> exportJsonl() async {
    await _writeChain;
    final File f = _file;
    if (!await f.exists()) return '';
    return f.readAsString();
  }

  /// 逐行导入：坏行 / 缺关键字段的行跳过，返回成功追加的条数。
  /// 导入前同样脱敏，避免把外部日志里的明文密钥带回磁盘。
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
      );
      final Future<void> write = _writeChain.then((_) async {
        final IOSink sink = _file.openWrite(mode: FileMode.append);
        sink.writeln(jsonEncode(safe.toJson()));
        await sink.flush();
        await sink.close();
      });
      _writeChain = write.catchError((Object _) {});
      await write;
      imported++;
    }
    return imported;
  }
}
