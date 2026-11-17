/// 子 Agent 独立记忆：每个 agent 一个真实 JSON 文件，本地 BM25 检索，
/// 支持快照/恢复；`shared` 作用域额外提供只读全局视图。
///
/// 设计红线：
///  * isolated 只读写 `agent_memory/<agentId>.json`，绝不触碰其它 agent 文件。
///  * shared 的 [AgentMemory.sharedView] 只读 harness 的 `turns.json`，
///    不提供任何写全局记忆的入口。
///  * 条目数有真实上限，超出按时间裁剪；空查询/无命中返回空列表，绝不编造。
///  * 写入失败/参数非法时抛真实异常，不吞掉错误冒充成功。

import 'dart:convert';

import '../harness/store.dart';

class AgentMemory {
  AgentMemory(
    this.store,
    String agentId, {
    String memoryScope = 'isolated',
  })  : agentId = agentId.trim(),
        memoryScope = memoryScope == 'shared' ? 'shared' : 'isolated' {
    if (this.agentId.isEmpty) {
      throw ArgumentError.value(agentId, 'agentId', '不能为空');
    }
    if (this.agentId.contains('/') ||
        this.agentId.contains('\\') ||
        this.agentId.contains('..')) {
      throw ArgumentError.value(agentId, 'agentId', '不能包含路径分隔符或 ..');
    }
  }

  final HarnessStore store;
  final String agentId;
  final String memoryScope;

  /// 单 agent 最多保留的条目数；超出后从最旧开始裁剪。
  static const int maxEntries = 200;
  static const int _maxTextChars = 20000;
  static const double _bm25K1 = 1.5;

  String get _path => 'agent_memory/$agentId.json';

  Map<String, dynamic> _emptyData() => <String, dynamic>{
        'version': 1,
        'agent_id': agentId,
        'seq': 0,
        'updated_at': DateTime.now().toIso8601String(),
        'entries': <dynamic>[],
      };

  Future<Map<String, dynamic>> _load() async {
    final Map<String, dynamic> raw =
        await store.readJson(_path, fallback: _emptyData());
    final List<Map<String, dynamic>> entries = _entriesOf(raw);
    final dynamic rawSeq = raw['seq'];
    int seq = rawSeq is num ? rawSeq.toInt() : 0;
    for (final Map<String, dynamic> e in entries) {
      final dynamic id = e['id'];
      if (id is num && id.toInt() > seq) seq = id.toInt();
    }
    return <String, dynamic>{
      'version': 1,
      'agent_id': agentId,
      'seq': seq,
      'updated_at': (raw['updated_at'] ?? '').toString(),
      'entries': entries,
    };
  }

  List<Map<String, dynamic>> _entriesOf(Map<String, dynamic> data) {
    final dynamic raw = data['entries'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((Map<dynamic, dynamic> e) => e.map(
            (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)))
        .toList();
  }

  Future<void> _write(Map<String, dynamic> data) async {
    data['version'] = 1;
    data['agent_id'] = agentId;
    data['updated_at'] = DateTime.now().toIso8601String();
    await store.writeJson(_path, data);
  }

  static Map<String, dynamic> _normalizeMeta(Map<String, dynamic>? meta) {
    if (meta == null) return <String, dynamic>{};
    try {
      final dynamic decoded = jsonDecode(jsonEncode(meta));
      if (decoded is Map) {
        return decoded.map((dynamic k, dynamic v) =>
            MapEntry<String, dynamic>(k.toString(), v));
      }
    } on Object catch (e) {
      throw ArgumentError('meta 必须是可序列化为 JSON 的对象：$e');
    }
    throw ArgumentError('meta 必须是可序列化为 JSON 的对象');
  }

  static Map<String, dynamic> _cloneEntry(Map<String, dynamic> entry) {
    final dynamic meta = entry['meta'];
    return <String, dynamic>{
      'id': entry['id'],
      'role': (entry['role'] ?? '').toString(),
      'text': (entry['text'] ?? '').toString(),
      'meta': meta is Map
          ? meta.map(
              (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v))
          : <String, dynamic>{},
      'ts': (entry['ts'] ?? '').toString(),
      'ts_ms': entry['ts_ms'] is num ? (entry['ts_ms'] as num).toInt() : 0,
    };
  }

  /// 追加一条记忆（role + text + 可选 meta），返回真实落盘后的条目。
  Future<Map<String, dynamic>> append(
    String role,
    String text, [
    Map<String, dynamic>? meta,
  ]) async {
    final String r = role.trim();
    final String t = text.trim();
    if (r.isEmpty) throw ArgumentError.value(role, 'role', '不能为空');
    if (t.isEmpty) throw ArgumentError.value(text, 'text', '不能为空');
    if (t.length > _maxTextChars) {
      throw ArgumentError.value(
          text, 'text', '单条记忆最多 $_maxTextChars 字符');
    }
    final Map<String, dynamic> data = await _load();
    final List<Map<String, dynamic>> entries = _entriesOf(data);
    final int seq = (data['seq'] as int? ?? 0) + 1;
    final DateTime now = DateTime.now();
    final Map<String, dynamic> entry = <String, dynamic>{
      'id': seq,
      'role': r,
      'text': t,
      'meta': _normalizeMeta(meta),
      'ts': now.toIso8601String(),
      'ts_ms': now.millisecondsSinceEpoch,
    };
    entries.add(entry);
    while (entries.length > maxEntries) {
      entries.removeAt(0);
    }
    data['seq'] = seq;
    data['entries'] = entries;
    await _write(data);
    return _cloneEntry(entry);
  }

  /// 最近 [limit] 条，按时间从旧到新返回；limit<=0 返回空。
  Future<List<Map<String, dynamic>>> recent(int limit) async {
    if (limit <= 0) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> entries = _entriesOf(await _load());
    final int n = limit < entries.length ? limit : entries.length;
    return entries
        .sublist(entries.length - n)
        .map(_cloneEntry)
        .toList(growable: false);
  }

  /// BM25 风格本地检索：中文单字 + 二元组 + 英文/数字词；无命中返回空列表。
  Future<List<Map<String, dynamic>>> search(String query, int topK) async {
    final String q = query.trim();
    if (q.isEmpty || topK <= 0) return <Map<String, dynamic>>[];
    final Map<String, int> qtf = _tokenize(q);
    if (qtf.isEmpty) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> entries = _entriesOf(await _load());
    if (entries.isEmpty) return <Map<String, dynamic>>[];

    final List<Map<String, int>> tfs = <Map<String, int>>[];
    final List<int> lengths = <int>[];
    int totalLength = 0;
    for (final Map<String, dynamic> e in entries) {
      final Map<String, int> tf =
          _tokenize((e['text'] ?? '').toString().toLowerCase());
      tfs.add(tf);
      final int dl = tf.values.fold<int>(0, (int a, int b) => a + b);
      lengths.add(dl <= 0 ? 1 : dl);
      totalLength += dl <= 0 ? 1 : dl;
    }
    final double avgdl = totalLength <= 0 ? 1.0 : totalLength / entries.length;

    final Map<String, int> df = <String, int>{};
    for (int i = 0; i < entries.length; i++) {
      final String text =
          (entries[i]['text'] ?? '').toString().toLowerCase();
      for (final String term in qtf.keys) {
        if (text.contains(term)) df[term] = (df[term] ?? 0) + 1;
      }
    }

    final List<Map<String, dynamic>> scored = <Map<String, dynamic>>[];
    for (int i = 0; i < entries.length; i++) {
      final Map<String, int> tf = tfs[i];
      final int dl = lengths[i];
      double score = 0;
      for (final String term in qtf.keys) {
        final int f = tf[term] ?? 0;
        if (f == 0) continue;
        final int n = df[term] ?? 0;
        final double idf =
            ((entries.length - n + 0.5) / (n + 0.5) + 1)
                .clamp(0.0, 20.0)
                .toDouble();
        score += idf *
            (f * (_bm25K1 + 1)) /
            (f + _bm25K1 * (1 - 0.75 + 0.75 * dl / avgdl));
      }
      if (score <= 0) continue;
      final Map<String, dynamic> entry = _cloneEntry(entries[i]);
      scored.add(<String, dynamic>{
        ...entry,
        'score': double.parse(score.toStringAsFixed(4)),
        'snippet':
            _snippet((entry['text'] ?? '').toString(), qtf.keys.toList()),
      });
    }
    scored.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        (b['score'] as double).compareTo(a['score'] as double));
    return scored.take(topK).toList(growable: false);
  }

  /// 真正清空本 agent 的条目并落盘，返回被清除的条数。
  /// 只操作自己的文件，绝不清空全局 turns.json。
  Future<int> clear() async {
    final Map<String, dynamic> data = await _load();
    final int removed = _entriesOf(data).length;
    data['entries'] = <dynamic>[];
    await _write(data);
    return removed;
  }

  /// 当前记忆的完整快照（深拷贝，可 JSON 编码）。
  Future<Map<String, dynamic>> snapshot() async {
    final Map<String, dynamic> data = await _load();
    final dynamic cloned = jsonDecode(jsonEncode(data));
    return (cloned as Map).map(
        (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v));
  }

  /// 从快照恢复；快照必须属于当前 agent，否则拒绝。
  Future<int> restore(Map<String, dynamic> snapshot) async {
    final String owner = (snapshot['agent_id'] ?? '').toString();
    if (owner.isNotEmpty && owner != agentId) {
      throw ArgumentError.value(
          owner, 'snapshot.agent_id', '快照属于其它 agent，拒绝恢复');
    }
    final dynamic rawEntries = snapshot['entries'];
    if (rawEntries is! List) {
      throw ArgumentError('快照缺少 entries 数组');
    }
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    for (final dynamic raw in rawEntries) {
      if (raw is! Map) throw ArgumentError('快照条目必须是对象');
      final Map<String, dynamic> e = raw.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v));
      if ((e['role'] ?? '').toString().trim().isEmpty ||
          (e['text'] ?? '').toString().trim().isEmpty) {
        throw ArgumentError('快照条目缺少 role/text');
      }
      entries.add(<String, dynamic>{
        'id': e['id'] is num
            ? (e['id'] as num).toInt()
            : entries.length + 1,
        'role': e['role'].toString(),
        'text': e['text'].toString(),
        'meta': e['meta'] is Map
            ? (e['meta'] as Map).map((dynamic k, dynamic v) =>
                MapEntry<String, dynamic>(k.toString(), v))
            : <String, dynamic>{},
        'ts': (e['ts'] ?? '').toString(),
        'ts_ms': e['ts_ms'] is num ? (e['ts_ms'] as num).toInt() : 0,
      });
    }
    while (entries.length > maxEntries) {
      entries.removeAt(0);
    }
    int seq = 0;
    for (final Map<String, dynamic> e in entries) {
      final int id = e['id'] as int;
      if (id > seq) seq = id;
    }
    final dynamic rawSeq = snapshot['seq'];
    if (rawSeq is num && rawSeq.toInt() > seq) seq = rawSeq.toInt();
    await _write(<String, dynamic>{
      'version': 1,
      'agent_id': agentId,
      'seq': seq,
      'entries': entries,
    });
    return entries.length;
  }

  /// 只读全局视图：仅 `memoryScope == shared` 可用。
  ///
  /// 读取 HarnessStore 的 `turns.json` 最近 [limit] 条，返回副本；
  /// 本类没有任何写全局记忆的入口，因此这里绝不修改 turns.json。
  Future<List<Map<String, dynamic>>> sharedView({int limit = 20}) async {
    if (memoryScope != 'shared') {
      throw StateError('isolated 记忆不提供全局视图，请使用 memoryScope=shared');
    }
    if (limit <= 0) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> turns = await store.readRecords('turns');
    final int n = limit < turns.length ? limit : turns.length;
    return turns
        .sublist(turns.length - n)
        .map((Map<String, dynamic> t) => t.map(
            (String k, dynamic v) => MapEntry<String, dynamic>(k, v)))
        .toList(growable: false);
  }

  // ---- 检索辅助 ----

  /// 中文按单字 + 二元组，英文/数字按词切分；与知识库保持同一套 BM25 词项。
  Map<String, int> _tokenize(String text) {
    final String lower = text.toLowerCase();
    final Map<String, int> tf = <String, int>{};
    void add(String token) {
      if (token.isEmpty) return;
      tf[token] = (tf[token] ?? 0) + 1;
    }

    for (final RegExpMatch m
        in RegExp(r'[a-z0-9_]{2,}').allMatches(lower)) {
      add(m.group(0)!);
    }
    final List<String> cjk = RegExp(r'[\u4e00-\u9fff]')
        .allMatches(lower)
        .map((RegExpMatch m) => m.group(0)!)
        .toList();
    for (int i = 0; i < cjk.length; i++) {
      add(cjk[i]);
      if (i + 1 < cjk.length) add('${cjk[i]}${cjk[i + 1]}');
    }
    return tf;
  }

  String _snippet(String text, List<String> terms) {
    final String lower = text.toLowerCase();
    int first = -1;
    for (final String term in terms) {
      final int i = lower.indexOf(term);
      if (i >= 0 && (first < 0 || i < first)) first = i;
    }
    final int start = first <= 40 ? 0 : first - 40;
    final int end = (start + 160 < text.length) ? start + 160 : text.length;
    final String s = text.substring(start, end).replaceAll('\n', ' ').trim();
    return '${start > 0 ? '…' : ''}$s${end < text.length ? '…' : ''}';
  }
}
