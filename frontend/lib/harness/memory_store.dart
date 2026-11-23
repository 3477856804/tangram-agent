/// 记忆分三层（Dart 侧，与 Python `im/memory.py` 同语义的镜像实现）。
///
/// 只借鉴设计思路、自己写实现，未复制任何第三方源码；供后续接线用，
/// 不新增操作页面。
///
/// * 短期：会话摘要（session summary）——每会话只存要点（单条 ≤120 字，
///   每会话最多 20 条），不存整段对话全文。
/// * 长期：显式保存的事实库（fact store）——只有显式调用 [saveFact]
///   才写入；支持按 id / 文本查、按来源 / 标签过滤。
/// * 共享：跨 bot / 跨群聊的共享记忆——scope 分 private / shared；
///   共享须显式 opt-in（`shared: true` 或 `scope: 'shared'`），默认
///   private；共享事实带来源 bot 与共享时间。
///
/// 开关：[learn]（是否从对话学习进摘要，默认开）、[remember]（是否允许
/// 写入长期事实库，默认开但只接受显式保存）。[forgetFact] 按 id 或文本
/// 删事实，删后不可恢复。
///
/// 凭据/密钥类内容绝不进记忆：保存前用与 `audit_log.dart` 的
/// [SecretRedactor] 相同规则脱敏比对（本文件内自带同规则实现，避免引入
/// `store.dart` 的 path_provider 依赖，保持纯 Dart 可跑），命中则拒绝
/// 保存并记原因。
///
/// 落盘：调用方传入的应用私有目录根下的 `memory_layers.json`，原子写
/// （tmp + rename），尽力 0600；写盘失败只记原因、不抛错、不阻断调用方。

import 'dart:convert';
import 'dart:io';

/// 长期事实的可见范围：`private`（默认）或 `shared`（显式 opt-in 才共享）。
class MemoryScope {
  static const String private = 'private';
  static const String shared = 'shared';
}

/// 一条长期事实：只由显式保存产生，可删改，可共享。
class MemoryFact {
  MemoryFact({
    required this.id,
    required this.text,
    this.source = '',
    this.scope = MemoryScope.private,
    this.tags = const <String>[],
    DateTime? createdAt,
    this.sharedBy = '',
    DateTime? sharedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        sharedAt = sharedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  final String id;
  final String text;
  final String source;
  final String scope;
  final List<String> tags;
  final DateTime createdAt;

  /// 共享该事实的 bot（仅 shared 事实有值）。
  final String sharedBy;

  /// 共享时间（仅 shared 事实有值，否则为 epoch 0）。
  final DateTime sharedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'text': text,
        'source': source,
        'scope': scope,
        'tags': tags,
        'created_at': createdAt.millisecondsSinceEpoch / 1000.0,
        if (sharedBy.isNotEmpty) 'shared_by': sharedBy,
        if (sharedAt.millisecondsSinceEpoch > 0)
          'shared_at': sharedAt.millisecondsSinceEpoch / 1000.0,
      };

  factory MemoryFact.fromJson(Map<String, dynamic> json) {
    double asDouble(Object? v) {
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0;
      return 0;
    }

    final Object? rawTags = json['tags'];
    return MemoryFact(
      id: json['id']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      scope: json['scope']?.toString() ?? MemoryScope.private,
      tags: rawTags is List
          ? rawTags.map((Object? e) => e.toString()).toList()
          : const <String>[],
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (asDouble(json['created_at']) * 1000).round(),
      ),
      sharedBy: json['shared_by']?.toString() ?? '',
      sharedAt: DateTime.fromMillisecondsSinceEpoch(
        (asDouble(json['shared_at']) * 1000).round(),
      ),
    );
  }
}

/// [saveFact] 的返回：`ok` 为真时 [fact] 有值，否则看 [reason]。
class MemorySaveResult {
  const MemorySaveResult({required this.ok, this.fact, this.reason = 'ok'});

  final bool ok;
  final MemoryFact? fact;

  /// `ok` / `empty` / `too-long` / `secret-rejected` /
  /// `remember-off` / `fact-store-full`。
  final String reason;
}

/// [forgetFact] 的返回：删掉的条数与 id 列表。
class MemoryForgetResult {
  const MemoryForgetResult(
      {required this.ok, this.deleted = 0, this.ids = const <String>[]});

  final bool ok;
  final int deleted;
  final List<String> ids;
}

/// 密钥脱敏：与 `audit_log.dart` 的 SecretRedactor 相同规则——只替换
/// 敏感**值**，其余文本原样保留；另补裸露令牌前缀（`sk-…` 等）。
abstract final class MemorySecretRedactor {
  static final RegExp _authScheme = RegExp(
    r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=\-]+',
    caseSensitive: false,
  );

  static final RegExp _secretKeyValue = RegExp(
    r'''(?<![A-Za-z0-9_])(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|pwd|secret|client[_-]?secret|authorization)(["']?\s*[:=]\s*["']?)(?!Bearer\b|Basic\b)([^"'\s,;&}\]]+)''',
    caseSensitive: false,
  );

  static final RegExp _bareToken = RegExp(
    r'\b(?:sk-[A-Za-z0-9-]{8,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|'
    r'xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|'
    r'glpat-[A-Za-z0-9_-]{10,})\b',
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

  /// 文本是否含凭据/密钥类内容。
  static bool containsSecret(String input) {
    if (input.isEmpty) return false;
    if (redact(input) != input) return true;
    return _bareToken.hasMatch(input);
  }
}

/// 三层记忆门面：会话摘要 + 显式事实库 + 共享记忆。
///
/// [root] 为应用私有目录根（调用方传入，如 `HarnessStore.root`；
/// 测试可传临时目录）。构造时不碰磁盘，首次读写时惰性加载。
class MemoryStore {
  MemoryStore(this.root, {this.botId = 'tangram', this.onAudit});

  /// 应用私有目录根；记忆文件为 `$root/memory_layers.json`。
  final Directory root;

  /// 本 bot 的标识：共享事实的 `shared_by` 与审计 `actor` 用它。
  final String botId;

  /// 可选审计回调：`(action, decision, detail)`，只传元数据，绝不传
  /// 事实正文；回调抛错会被吞掉，绝不阻断记忆操作。
  final void Function(String action, String decision, String detail)? onAudit;

  static const String _file = 'memory_layers.json';
  static const int maxPointChars = 120;
  static const int maxPointsPerSession = 20;
  static const int maxFactChars = 2000;
  static const int maxFacts = 5000;

  File get _dataFile => File('${root.path}/$_file');

  bool _loaded = false;
  int _seq = 0;
  bool _learn = true;
  bool _remember = true;
  final List<MemoryFact> _facts = <MemoryFact>[];
  final Map<String, Map<String, dynamic>> _sessions =
      <String, Map<String, dynamic>>{};

  /// 串行化写盘链：并发保存时按顺序写，不让两份写入交错成坏文件。
  Future<void> _writeChain = Future<void>.value();

  /// 开关的当前值（反映最近一次加载的状态；首次读取前请先调任意 async
  /// 方法一次以触发惰性加载，如 `stats()`）。
  bool get learn => _learn;
  bool get remember => _remember;

  Future<void> setLearn(bool value) async {
    await _load();
    _learn = value;
    await _save();
  }

  Future<void> setRemember(bool value) async {
    await _load();
    _remember = value;
    await _save();
  }

  // ---- 持久化（惰性加载、原子写、尽力 0600、失败只记不抛） ----

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    final File file = _dataFile;
    try {
      if (!await file.exists()) return;
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final Map<String, dynamic> raw =
          decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v));
      if (raw['learn'] is bool) _learn = raw['learn'] as bool;
      if (raw['remember'] is bool) _remember = raw['remember'] as bool;
      final Object? facts = raw['facts'];
      if (facts is List) {
        for (final Object? item in facts) {
          if (item is! Map) continue;
          try {
            final MemoryFact fact = MemoryFact.fromJson(
              item.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            );
            if (fact.id.isNotEmpty && fact.text.isNotEmpty) {
              _facts.add(fact);
            }
          } on Object {
            continue; // 坏行跳过，不冒充数据
          }
        }
      }
      final Object? sessions = raw['sessions'];
      if (sessions is Map) {
        sessions.forEach((Object? key, Object? value) {
          if (value is! Map) return;
          final Object? points = value['points'];
          if (points is! List) return;
          _sessions[key.toString()] = <String, dynamic>{
            'points': points
                .map((Object? e) => e.toString())
                .take(maxPointsPerSession)
                .toList(),
            'turns': value['turns'] is num ? (value['turns'] as num).toInt() : 0,
            'updated_at': value['updated_at'] is num
                ? (value['updated_at'] as num).toDouble()
                : 0.0,
          };
        });
      }
    } on Object catch (e) {
      // 损坏文件不冒充数据：从空态开始，并如实说明。
      stderr.writeln('[memory] 记忆文件损坏，已从空态开始：$e');
    }
  }

  Future<bool> _save() {
    final Future<void> chained = _writeChain.then((_) => _saveNow());
    _writeChain = chained.catchError((Object _) {});
    return chained.then((_) => true).catchError((Object _) => false);
  }

  Future<void> _saveNow() async {
    final Map<String, dynamic> doc = <String, dynamic>{
      'version': 1,
      'learn': _learn,
      'remember': _remember,
      'facts': _facts.map((MemoryFact f) => f.toJson()).toList(),
      'sessions': _sessions,
      'updated_at': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    final File file = _dataFile;
    try {
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(doc), flush: true);
      await tmp.rename(file.path);
      if (!Platform.isWindows) {
        try {
          Process.runSync('chmod', <String>['600', file.path]);
        } on Object {
          // 权限设置失败不阻断：应用私有目录本身已隔离。
        }
      }
    } on Object catch (e) {
      stderr.writeln('[memory] 写盘失败（已忽略）：$e');
    }
  }

  // ---- 短期：会话摘要 ----

  /// 从一轮对话学习进会话摘要（只存要点，不存全文）。
  ///
  /// learn 开关关闭时直接返回 false；要点超过 120 字截断；每会话最多
  /// 保留 20 条要点（最旧的先丢）；连续重复要点不重复记。
  Future<bool> learnTurn(String sessionKey, String role, String text) async {
    final String key =
        sessionKey.trim().isEmpty ? 'default' : sessionKey.trim();
    final String src = text.trim();
    if (src.isEmpty) return false;
    await _load();
    if (!_learn) return false;
    String point = src.replaceAll('\n', ' ').trim();
    if (point.length > maxPointChars) {
      point = '${point.substring(0, maxPointChars)}…';
    }
    point = '${role.isEmpty ? 'user' : role}: $point';
    final Map<String, dynamic> session = _sessions.putIfAbsent(
      key,
      () => <String, dynamic>{
        'points': <String>[],
        'turns': 0,
        'updated_at': 0.0,
      },
    );
    final List<String> points =
        (session['points'] as List).map((Object? e) => e.toString()).toList();
    if (points.isNotEmpty && points.last == point) return false;
    points.add(point);
    if (points.length > maxPointsPerSession) {
      points.removeRange(0, points.length - maxPointsPerSession);
    }
    session['points'] = points;
    session['turns'] = (session['turns'] is num ? (session['turns'] as num).toInt() : 0) + 1;
    session['updated_at'] =
        DateTime.now().millisecondsSinceEpoch / 1000.0;
    await _save();
    return true;
  }

  /// 取某会话的摘要要点（只读副本）。
  Future<List<String>> sessionSummary(String sessionKey) async {
    final String key =
        sessionKey.trim().isEmpty ? 'default' : sessionKey.trim();
    await _load();
    final Map<String, dynamic>? session = _sessions[key];
    if (session == null) return <String>[];
    return (session['points'] as List? ?? <dynamic>[])
        .map((Object? e) => e.toString())
        .toList();
  }

  /// 清空某会话的摘要（要点删除，不可恢复）。
  Future<bool> clearSession(String sessionKey) async {
    final String key =
        sessionKey.trim().isEmpty ? 'default' : sessionKey.trim();
    await _load();
    if (!_sessions.containsKey(key)) return false;
    _sessions.remove(key);
    await _save();
    return true;
  }

  // ---- 长期：显式事实库 ----

  String _nextId() {
    _seq++;
    return 'fact-${DateTime.now().microsecondsSinceEpoch}-$_seq';
  }

  /// 显式保存一条长期事实。
  ///
  /// 只有显式调用才会写进长期记忆；对话内容绝不会自动进事实库。
  /// `shared: true` 或 `scope: 'shared'` 才是共享 opt-in，默认一律
  /// private；共享事实带来源 bot 与共享时间。密钥类内容命中即拒绝保存。
  Future<MemorySaveResult> saveFact(
    String text, {
    String source = '',
    List<String> tags = const <String>[],
    String scope = MemoryScope.private,
    bool shared = false,
    String? botId,
  }) async {
    final String content = text.trim();
    await _load();
    if (!_remember) {
      _audit('fact_save_rejected', 'denied', 'remember-off');
      return const MemorySaveResult(ok: false, reason: 'remember-off');
    }
    if (content.isEmpty) {
      return const MemorySaveResult(ok: false, reason: 'empty');
    }
    if (content.length > maxFactChars) {
      return const MemorySaveResult(ok: false, reason: 'too-long');
    }
    if (MemorySecretRedactor.containsSecret(content)) {
      _audit('fact_save_rejected', 'denied', 'secret-rejected');
      return const MemorySaveResult(ok: false, reason: 'secret-rejected');
    }
    if (_facts.length >= maxFacts) {
      return const MemorySaveResult(ok: false, reason: 'fact-store-full');
    }
    final String finalScope =
        (shared || scope == MemoryScope.shared)
            ? MemoryScope.shared
            : MemoryScope.private;
    final DateTime now = DateTime.now();
    final MemoryFact fact = MemoryFact(
      id: _nextId(),
      text: content,
      source: source.trim(),
      scope: finalScope,
      tags: tags.map((String t) => t.trim()).where((String t) => t.isNotEmpty).toList(),
      sharedBy: finalScope == MemoryScope.shared ? (botId ?? this.botId) : '',
      sharedAt: finalScope == MemoryScope.shared
          ? now
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
    _facts.add(fact);
    await _save();
    _audit('fact_save', 'info',
        'id=${fact.id} scope=${fact.scope} source=${fact.source.isEmpty ? '-' : fact.source}');
    return MemorySaveResult(ok: true, fact: fact);
  }

  /// 按 id 取一条事实，没有返回 null。
  Future<MemoryFact?> getFact(String id) async {
    await _load();
    for (final MemoryFact fact in _facts) {
      if (fact.id == id) return fact;
    }
    return null;
  }

  /// 按来源 / 标签 / scope 过滤列出事实（按保存顺序）。
  Future<List<MemoryFact>> listFacts({
    String? source,
    List<String>? tags,
    String? scope,
    bool includeShared = true,
  }) async {
    await _load();
    final Set<String> wantedTags = <String>{
      for (final String t in tags ?? const <String>[]) t,
    };
    return _facts.where((MemoryFact fact) {
      if (!includeShared && fact.scope == MemoryScope.shared) return false;
      if (scope != null && fact.scope != scope) return false;
      if (source != null && fact.source != source) return false;
      if (wantedTags.isNotEmpty &&
          !fact.tags.any(wantedTags.contains)) {
        return false;
      }
      return true;
    }).toList();
  }

  /// 按 id 或文本子串查事实（大小写不敏感，CJK 原样比对）。
  Future<List<MemoryFact>> searchFacts(String query) async {
    final String q = query.trim();
    if (q.isEmpty) return <MemoryFact>[];
    await _load();
    final String lowered = q.toLowerCase();
    return _facts
        .where((MemoryFact f) =>
            f.text.toLowerCase().contains(lowered) || f.id == q)
        .toList();
  }

  /// 按 id 或文本删事实，删后不可恢复，并记审计事件。
  ///
  /// 先按 id 精确匹配；否则按文本子串匹配（可能删多条）。
  Future<MemoryForgetResult> forgetFact(String query) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return const MemoryForgetResult(ok: false);
    }
    await _load();
    final MemoryFact? exact = await getFact(q);
    final List<MemoryFact> doomed;
    if (exact != null) {
      doomed = <MemoryFact>[exact];
    } else {
      final String lowered = q.toLowerCase();
      doomed = _facts
          .where((MemoryFact f) => f.text.toLowerCase().contains(lowered))
          .toList();
    }
    if (doomed.isEmpty) {
      return const MemoryForgetResult(ok: false);
    }
    final Set<String> ids = doomed.map((MemoryFact f) => f.id).toSet();
    _facts.removeWhere((MemoryFact f) => ids.contains(f.id));
    await _save();
    final List<String> sortedIds = ids.toList()..sort();
    _audit('fact_forget', 'info',
        'deleted=${doomed.length} ids=${sortedIds.join(',')}');
    return MemoryForgetResult(
        ok: true, deleted: doomed.length, ids: sortedIds);
  }

  // ---- 审计（只记元数据，绝不记事实正文） ----

  void _audit(String action, String decision, String detail) {
    final void Function(String, String, String)? cb = onAudit;
    if (cb == null) return;
    try {
      cb(action, decision, detail);
    } on Object {
      // 审计回调失败不阻断记忆操作。
    }
  }

  // ---- 统计 ----

  Future<Map<String, dynamic>> stats() async {
    await _load();
    int points = 0;
    for (final Map<String, dynamic> session in _sessions.values) {
      points += (session['points'] as List? ?? <dynamic>[]).length;
    }
    return <String, dynamic>{
      'facts': _facts.length,
      'shared_facts': _facts
          .where((MemoryFact f) => f.scope == MemoryScope.shared)
          .length,
      'sessions': _sessions.length,
      'points': points,
      'learn': _learn,
      'remember': _remember,
      'path': _dataFile.path,
    };
  }
}
