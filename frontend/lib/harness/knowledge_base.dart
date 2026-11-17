/// 私有知识库：多库隔离、增量入库、本地检索与引用溯源。
///
/// 设计红线（与项目其它模块一致）：
///  * 所有数据真实落盘在 App 私有目录（`knowledge_base.json` 与
///    `knowledge_snapshots/`），不上传任何第三方，也不伪造向量库。
///  * 检索使用本地 BM25（中文单字 + 二元组 + 英文/数字词），返回真实命中的
///    文档、片段与分数；没有命中就是空列表，绝不编造引用。
///  * 二进制/暂不支持的格式（PDF、图片等）如实报错，提示先在沙箱用真实
///    解析工具转成文本再入库，不假装已解析。
///  * 每个库可独立启停、绑定人格、做版本快照；删除库同时清理其文档与片段。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'store.dart';
import 'vector_store.dart';

class KnowledgeBase {
  KnowledgeBase(this.store, {VectorStore? vectorStore})
      : vectorStore = vectorStore ?? LocalHashedVectorStore(store);

  final HarnessStore store;

  /// 可切换向量库；默认本地哈希向量库（真实落盘）。
  final VectorStore vectorStore;
  Map<String, dynamic>? _data;

  static const String _file = 'knowledge_base.json';
  static const String _vectorCollection = 'knowledge_chunks';
  static const int _maxIngestBytes = 8 * 1024 * 1024;
  static const Set<String> _textExtensions = <String>{
    '.txt', '.md', '.markdown', '.json', '.jsonl', '.csv', '.tsv', '.log',
    '.yaml', '.yml', '.xml', '.html', '.htm', '.css', '.js', '.ts', '.dart',
    '.py', '.sh', '.toml', '.ini', '.conf', '.srt', '.vtt',
  };

  Future<Map<String, dynamic>> _load() async {
    final Map<String, dynamic>? cached = _data;
    if (cached != null) return cached;
    final Map<String, dynamic> raw = await store.readJson(_file, fallback: <String, dynamic>{
      'version': 1,
      'libraries': <dynamic>[],
      'documents': <dynamic>[],
      'chunks': <dynamic>[],
    });
    raw['libraries'] = raw['libraries'] is List
        ? (raw['libraries'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList()
        : <dynamic>[];
    raw['documents'] = raw['documents'] is List
        ? (raw['documents'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList()
        : <dynamic>[];
    raw['chunks'] = raw['chunks'] is List
        ? (raw['chunks'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList()
        : <dynamic>[];
    _data = raw;
    return raw;
  }

  Future<void> _save() async {
    final Map<String, dynamic> data = _data ?? <String, dynamic>{};
    data['updated_at'] = DateTime.now().toIso8601String();
    await store.writeJson(_file, data);
  }

  List<Map<String, dynamic>> _maps(dynamic raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList()
      : <Map<String, dynamic>>[];

  List<Map<String, dynamic>> get _libraries => (_data?['libraries'] as List? ??
          <dynamic>[])
      .whereType<Map<String, dynamic>>()
      .toList();
  List<Map<String, dynamic>> get _documents => (_data?['documents'] as List? ??
          <dynamic>[])
      .whereType<Map<String, dynamic>>()
      .toList();
  List<Map<String, dynamic>> get _chunks =>
      (_data?['chunks'] as List? ?? <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .toList();

  void _setList(String key, List<Map<String, dynamic>> list) {
    _data![key] = list;
  }

  String _id(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  Map<String, dynamic> _findLibrary(String id) {
    for (final Map<String, dynamic> lib in _libraries) {
      if (lib['id'] == id) return lib;
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    await _load();
    switch (action) {
      case 'list':
      case 'libraries':
        return <String, dynamic>{
          'ok': true,
          ..._stats(),
          'libraries': _libraries.map(_libraryView).toList(),
        };
      case 'create':
        return await _create(p);
      case 'update':
        return await _update(p);
      case 'delete':
        return await _delete(p);
      case 'docs':
        return _docs(p);
      case 'dump':
        return _dump(p);
      case 'delete_doc':
        return await _deleteDoc(p);
      case 'ingest_file':
        return await _ingestFile(p);
      case 'ingest_text':
        return await _ingestText(
          libraryId: (p['library_id'] ?? '').toString(),
          text: (p['text'] ?? '').toString(),
          name: (p['name'] ?? '粘贴的文本').toString(),
          path: '',
        );
      case 'ingest_url':
        return await _ingestUrl(p);
      case 'search':
        return await _search(p);
      case 'vector_stats':
        return await _vectorStats();
      case 'rebuild_vectors':
        return await _rebuildVectors(p);
      case 'snapshot':
        return await _snapshot(p);
      case 'snapshots':
        return _snapshots(p);
      case 'restore':
        return await _restore(p);
      case 'stats':
        return <String, dynamic>{'ok': true, ..._stats()};
      case 'context':
        return <String, dynamic>{
          'ok': true,
          'context': await contextBlock(
            (p['query'] ?? '').toString(),
            personaId: (p['persona_id'] ?? '').toString(),
            libraryIds: _idsOf(p['library_ids']),
            topK: (p['top_k'] is num) ? (p['top_k'] as num).toInt() : 4,
          ),
        };
      default:
        return <String, dynamic>{
          'ok': false,
          'error': '未知知识库动作：$action',
        };
    }
  }

  List<String> _idsOf(dynamic raw) => raw is List
      ? raw.map((dynamic e) => e.toString()).where((String e) => e.isNotEmpty).toList()
      : <String>[];

  Map<String, dynamic> _libraryView(Map<String, dynamic> lib) {
    final String id = (lib['id'] ?? '').toString();
    final int docs =
        _documents.where((Map<String, dynamic> d) => d['library_id'] == id).length;
    final int chunks =
        _chunks.where((Map<String, dynamic> c) => c['library_id'] == id).length;
    return <String, dynamic>{
      ...lib,
      'doc_count': docs,
      'chunk_count': chunks,
    };
  }

  Map<String, dynamic> _stats() {
    final int enabled =
        _libraries.where((Map<String, dynamic> l) => l['enabled'] != false).length;
    return <String, dynamic>{
      'library_count': _libraries.length,
      'enabled_libraries': enabled,
      'documents': _documents.length,
      'chunks': _chunks.length,
      'data_file': store.file(_file).path,
    };
  }

  Future<Map<String, dynamic>> _create(Map<String, dynamic> p) async {
    final String name = (p['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库名称不能为空'};
    }
    if (_libraries.any((Map<String, dynamic> l) => l['name'] == name)) {
      return <String, dynamic>{'ok': false, 'error': '同名知识库已存在：$name'};
    }
    final String now = DateTime.now().toIso8601String();
    final Map<String, dynamic> lib = <String, dynamic>{
      'id': _id('kb'),
      'name': name,
      'description': (p['description'] ?? '').toString().trim(),
      'enabled': p['enabled'] != false,
      'persona_ids': _idsOf(p['persona_ids']),
      'visibility': (p['visibility'] ?? 'private').toString() == 'team'
          ? 'team'
          : 'private',
      'created_at': now,
      'updated_at': now,
      'snapshots': <dynamic>[],
    };
    _setList('libraries', <Map<String, dynamic>>[..._libraries, lib]);
    await _save();
    return <String, dynamic>{'ok': true, 'library': _libraryView(lib)};
  }

  Future<Map<String, dynamic>> _update(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final Map<String, dynamic> lib = _findLibrary(id);
    if (lib.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    if (p.containsKey('name')) {
      final String name = (p['name'] ?? '').toString().trim();
      if (name.isEmpty) {
        return <String, dynamic>{'ok': false, 'error': '知识库名称不能为空'};
      }
      if (_libraries.any((Map<String, dynamic> l) =>
          l['id'] != id && l['name'] == name)) {
        return <String, dynamic>{'ok': false, 'error': '同名知识库已存在：$name'};
      }
      lib['name'] = name;
    }
    if (p.containsKey('description')) {
      lib['description'] = (p['description'] ?? '').toString().trim();
    }
    if (p.containsKey('enabled')) lib['enabled'] = p['enabled'] == true;
    if (p.containsKey('persona_ids')) {
      lib['persona_ids'] = _idsOf(p['persona_ids']);
    }
    if (p.containsKey('visibility')) {
      lib['visibility'] =
          (p['visibility'] ?? 'private').toString() == 'team' ? 'team' : 'private';
    }
    lib['updated_at'] = DateTime.now().toIso8601String();
    _setList('libraries', _libraries);
    await _save();
    return <String, dynamic>{'ok': true, 'library': _libraryView(lib)};
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    if (_findLibrary(id).isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    final List<Map<String, dynamic>> removedChunks =
        _chunks.where((Map<String, dynamic> c) => c['library_id'] == id).toList();
    _setList('libraries',
        _libraries.where((Map<String, dynamic> l) => l['id'] != id).toList());
    _setList('documents',
        _documents.where((Map<String, dynamic> d) => d['library_id'] != id).toList());
    _setList('chunks',
        _chunks.where((Map<String, dynamic> c) => c['library_id'] != id).toList());
    await _deleteVectors(removedChunks);
    await _save();
    return <String, dynamic>{'ok': true, 'deleted': id};
  }

  Map<String, dynamic> _docs(Map<String, dynamic> p) {
    final String id = (p['library_id'] ?? '').toString();
    if (_findLibrary(id).isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    final List<Map<String, dynamic>> docs = _documents
        .where((Map<String, dynamic> d) => d['library_id'] == id)
        .toList()
        .reversed
        .toList();
    return <String, dynamic>{'ok': true, 'documents': docs};
  }

  Map<String, dynamic> _dump(Map<String, dynamic> p) {
    final String id = (p['library_id'] ?? '').toString();
    final Map<String, dynamic> lib = _findLibrary(id);
    if (lib.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    final List<Map<String, dynamic>> docs = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> d in _documents
        .where((Map<String, dynamic> d) => d['library_id'] == id)) {
      final List<Map<String, dynamic>> cs = _chunks
          .where((Map<String, dynamic> c) => c['document_id'] == d['id'])
          .toList()
        ..sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
            _intOf(a['ordinal']).compareTo(_intOf(b['ordinal'])));
      docs.add(<String, dynamic>{
        'name': d['name'],
        'path': d['path'],
        'text': cs.map((Map<String, dynamic> c) => c['text']).join('\n\n'),
      });
    }
    return <String, dynamic>{
      'ok': true,
      'library': <String, dynamic>{
        'name': lib['name'],
        'description': lib['description'],
        'persona_ids': lib['persona_ids'],
        'visibility': lib['visibility'],
      },
      'documents': docs,
    };
  }

  Future<Map<String, dynamic>> _deleteDoc(Map<String, dynamic> p) async {
    final String documentId = (p['document_id'] ?? '').toString();
    final List<Map<String, dynamic>> docs = _documents;
    if (!docs.any((Map<String, dynamic> d) => d['id'] == documentId)) {
      return <String, dynamic>{'ok': false, 'error': '文档不存在'};
    }
    final List<Map<String, dynamic>> removedChunks = _chunks
        .where((Map<String, dynamic> c) => c['document_id'] == documentId)
        .toList();
    _setList('documents',
        docs.where((Map<String, dynamic> d) => d['id'] != documentId).toList());
    _setList('chunks',
        _chunks.where((Map<String, dynamic> c) => c['document_id'] != documentId).toList());
    await _deleteVectors(removedChunks);
    await _save();
    return <String, dynamic>{'ok': true, 'deleted': documentId};
  }

  Future<Map<String, dynamic>> _ingestFile(Map<String, dynamic> p) async {
    final String libraryId = (p['library_id'] ?? '').toString();
    final String path = (p['path'] ?? '').toString().trim();
    if (_findLibrary(libraryId).isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    if (path.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '文件路径为空'};
    }
    final File file = File(path);
    if (!await file.exists()) {
      return <String, dynamic>{'ok': false, 'error': '文件不存在：$path'};
    }
    final int size = await file.length();
    if (size > _maxIngestBytes) {
      return <String, dynamic>{
        'ok': false,
        'error': '文件超过 8MB（$size 字节），请先切分后再入库',
      };
    }
    final String lower = path.toLowerCase();
    final bool textLike = _textExtensions.any(lower.endsWith);
    if (!textLike) {
      return <String, dynamic>{
        'ok': false,
        'error': '纯 Dart 知识库暂不解析该格式（${lower.split('.').last}）。'
            '请先在沙箱用真实解析工具（PDF/OCR/文档解析）转成文本后入库。',
      };
    }
    String content;
    try {
      content = utf8.decode(await file.readAsBytes());
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '文件不是有效 UTF-8 文本：$e'};
    }
    final String name = (p['name'] ?? file.uri.pathSegments.last).toString();
    return _ingestText(
      libraryId: libraryId,
      text: content,
      name: name,
      path: path,
    );
  }

  Future<Map<String, dynamic>> _ingestText({
    required String libraryId,
    required String text,
    required String name,
    required String path,
  }) async {
    if (text.trim().isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '内容为空，未入库'};
    }
    if (text.length > _maxIngestBytes) {
      return <String, dynamic>{'ok': false, 'error': '文本过大，请切分后再入库'};
    }
    final String hash = sha256.convert(utf8.encode(text)).toString();
    for (final Map<String, dynamic> d in _documents) {
      if (d['library_id'] == libraryId && d['hash'] == hash) {
        return <String, dynamic>{
          'ok': true,
          'duplicate': true,
          'document': d,
          'message': '内容相同，已跳过重复入库',
        };
      }
    }
    final String docId = _id('doc');
    final List<String> pieces = _chunk(text);
    final String now = DateTime.now().toIso8601String();
    final Map<String, dynamic> doc = <String, dynamic>{
      'id': docId,
      'library_id': libraryId,
      'name': name,
      'path': path,
      'hash': hash,
      'chars': text.length,
      'chunks': pieces.length,
      'ingested_at': now,
    };
    final List<Map<String, dynamic>> newChunks = <Map<String, dynamic>>[];
    for (int i = 0; i < pieces.length; i++) {
      final Map<String, int> tf = _tokenize(pieces[i]);
      newChunks.add(<String, dynamic>{
        'id': '$docId#$i',
        'document_id': docId,
        'library_id': libraryId,
        'ordinal': i,
        'text': pieces[i],
        'length': tf.values.fold<int>(0, (int a, int b) => a + b),
      });
    }
    int vectorCount = 0;
    String vectorError = '';
    for (final Map<String, dynamic> chunk in newChunks) {
      try {
        await vectorStore.upsert(
          _vectorCollection,
          (chunk['id'] ?? '').toString(),
          HashingTrick.embed((chunk['text'] ?? '').toString()),
          <String, dynamic>{
            'chunk_id': chunk['id'],
            'library_id': chunk['library_id'],
            'document_id': chunk['document_id'],
            'ordinal': chunk['ordinal'],
          },
        );
        vectorCount++;
      } on Object catch (e) {
        // 向量库失败不伪造成功：文本仍真实入库，响应里如实标注降级。
        vectorError = _vectorErrorText(e);
      }
    }
    _setList('documents', <Map<String, dynamic>>[..._documents, doc]);
    _setList('chunks', <Map<String, dynamic>>[..._chunks, ...newChunks]);
    await _save();
    return <String, dynamic>{
      'ok': true,
      'duplicate': false,
      'document': doc,
      'chunks': pieces.length,
      'vectors': vectorCount,
      'vector_backend': vectorStore.backendName,
      'degraded': vectorError.isNotEmpty,
      if (vectorError.isNotEmpty) 'vector_error': vectorError,
    };
  }

  Future<Map<String, dynamic>> _ingestUrl(Map<String, dynamic> p) async {
    final String libraryId = (p['library_id'] ?? '').toString();
    final String raw = (p['url'] ?? '').toString().trim();
    if (_findLibrary(libraryId).isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return <String, dynamic>{'ok': false, 'error': '仅支持 http/https 网页地址'};
    }
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final HttpClientRequest req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.userAgentHeader, 'TangramAgent/1.0');
      final HttpClientResponse resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return <String, dynamic>{
          'ok': false,
          'error': '网页返回 HTTP ${resp.statusCode}',
        };
      }
      final List<int> bytes = <int>[];
      await for (final List<int> part in resp) {
        bytes.addAll(part);
        if (bytes.length > _maxIngestBytes) {
          return <String, dynamic>{'ok': false, 'error': '网页超过 8MB，已中止'};
        }
      }
      final String html = utf8.decode(bytes, allowMalformed: true);
      final String text = _htmlToText(html);
      if (text.trim().isEmpty) {
        return <String, dynamic>{'ok': false, 'error': '网页没有可提取的正文'};
      }
      return await _ingestText(
        libraryId: libraryId,
        text: text,
        name: (p['name'] ?? uri.host).toString(),
        path: uri.toString(),
      );
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '抓取网页失败：$e'};
    } finally {
      client.close(force: true);
    }
  }

  String _htmlToText(String html) {
    String s = html
        .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|li|h[1-6]|tr)>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ' ');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return s
        .split('\n')
        .map((String line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((String line) => line.isNotEmpty)
        .join('\n');
  }

  List<String> _chunk(String text) {
    const int maxChars = 600;
    const int overlap = 80;
    final String normalized =
        text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
    final List<String> paragraphs = normalized
        .split(RegExp(r'\n\s*\n'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    final List<String> out = <String>[];
    final StringBuffer buf = StringBuffer();
    void flush() {
      final String s = buf.toString().trim();
      if (s.isNotEmpty) out.add(s);
      buf.clear();
    }

    for (final String para in paragraphs) {
      if (para.length > maxChars) {
        flush();
        int start = 0;
        while (start < para.length) {
          final int end = (start + maxChars < para.length)
              ? start + maxChars
              : para.length;
          out.add(para.substring(start, end));
          if (end == para.length) break;
          start = end - overlap;
        }
        continue;
      }
      if (buf.length + para.length + 1 > maxChars) flush();
      if (buf.isNotEmpty) buf.write('\n');
      buf.write(para);
    }
    flush();
    if (out.isEmpty && normalized.isNotEmpty) out.add(normalized);
    return out;
  }

  /// 中文按单字 + 二元组，英文/数字按词切分；用于本地 BM25 检索。
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
    final List<String> cjk =
        RegExp(r'[\u4e00-\u9fff]').allMatches(lower).map((RegExpMatch m) => m.group(0)!).toList();
    // 中文只用二元组打分：单字命中会把无关查询误判为命中。
    if (cjk.length == 1) add(cjk.first);
    for (int i = 0; i + 1 < cjk.length; i++) {
      add('${cjk[i]}${cjk[i + 1]}');
    }
    return tf;
  }

  /// 混合检索：BM25 词法分 + 0.35 * 余弦向量分。
  ///
  /// 向量库不可用时如实降级为纯 BM25，并在响应与每条结果上标注
  /// `degraded=true`；此时不会伪造 vector_score，也不会编造命中。
  Future<Map<String, dynamic>> _search(Map<String, dynamic> p) async {
    final String query = (p['query'] ?? '').toString().trim();
    final int topK =
        (p['top_k'] is num) ? (p['top_k'] as num).toInt().clamp(1, 50) : 8;
    final List<String> onlyIds = _idsOf(p['library_ids']);
    final String personaId = (p['persona_id'] ?? '').toString();
    if (query.isEmpty) {
      return <String, dynamic>{
        'ok': true,
        'results': <dynamic>[],
        'query': '',
        'backend': vectorStore.backendName,
        'degraded': false,
      };
    }
    final Map<String, int> qtf = _tokenize(query);
    if (qtf.isEmpty) {
      return <String, dynamic>{
        'ok': true,
        'results': <dynamic>[],
        'query': query,
        'backend': vectorStore.backendName,
        'degraded': false,
      };
    }
    final Set<String> allowedLibraries = <String>{};
    for (final Map<String, dynamic> lib in _libraries) {
      final String id = (lib['id'] ?? '').toString();
      if (lib['enabled'] == false) continue;
      if (onlyIds.isNotEmpty && !onlyIds.contains(id)) continue;
      final List<String> personas = _idsOf(lib['persona_ids']);
      if (personaId.isNotEmpty && personas.isNotEmpty && !personas.contains(personaId)) {
        continue;
      }
      allowedLibraries.add(id);
    }
    final List<Map<String, dynamic>> pool = _chunks
        .where((Map<String, dynamic> c) =>
            allowedLibraries.contains(c['library_id']))
        .toList();
    if (pool.isEmpty) {
      return <String, dynamic>{
        'ok': true,
        'results': <dynamic>[],
        'query': query,
        'backend': vectorStore.backendName,
        'degraded': false,
      };
    }

    // ---- BM25 词法分 ----
    final int totalLength = pool.fold<int>(
        0, (int a, Map<String, dynamic> c) => a + _intOf(c['length']));
    final double avgdl = totalLength <= 0 ? 1.0 : totalLength / pool.length;
    final Map<String, int> df = <String, int>{};
    for (final Map<String, dynamic> c in pool) {
      final Set<String> seen = <String>{};
      for (final String term in qtf.keys) {
        if ((c['text'] ?? '').toString().toLowerCase().contains(term) &&
            seen.add(term)) {
          df[term] = (df[term] ?? 0) + 1;
        }
      }
    }
    const double k1 = 1.5;
    const double b = 0.75;
    final Map<String, double> bm25 = <String, double>{};
    for (final Map<String, dynamic> c in pool) {
      final String text = (c['text'] ?? '').toString().toLowerCase();
      final Map<String, int> tf = _tokenize(text);
      final int dl = _intOf(c['length']) == 0 ? 1 : _intOf(c['length']);
      double score = 0;
      for (final String term in qtf.keys) {
        final int f = tf[term] ?? 0;
        if (f == 0) continue;
        final int n = df[term] ?? 0;
        final double idf =
            ((pool.length - n + 0.5) / (n + 0.5) + 1).clamp(0.0, 20.0).toDouble();
        score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgdl));
      }
      if (score > 0) bm25[(c['id'] ?? '').toString()] = score;
    }

    // ---- 向量分（失败如实降级，不编造）----
    final Map<String, double> vectorScores = <String, double>{};
    bool degraded = false;
    String vectorError = '';
    try {
      final List<double> queryVector = HashingTrick.embed(query);
      final Set<String> poolIds = pool
          .map((Map<String, dynamic> c) => (c['id'] ?? '').toString())
          .toSet();
      final int limit = pool.length < 64 ? pool.length : 64;
      final List<VectorMatch> matches =
          await vectorStore.query(_vectorCollection, queryVector, limit);
      for (final VectorMatch m in matches) {
        if (!poolIds.contains(m.id)) continue;
        vectorScores[m.id] = m.score;
      }
    } on Object catch (e) {
      degraded = true;
      vectorError = _vectorErrorText(e);
    }

    final Map<String, Map<String, dynamic>> byId = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> c in pool)
        (c['id'] ?? '').toString(): c,
    };
    final Set<String> candidates = <String>{
      ...bm25.keys,
      ...vectorScores.keys,
    };
    final List<Map<String, dynamic>> scored = <Map<String, dynamic>>[];
    for (final String id in candidates) {
      final Map<String, dynamic>? chunk = byId[id];
      if (chunk == null) continue;
      final double lexical = bm25[id] ?? 0;
      final double cosine = vectorScores[id] ?? 0;
      // 纯向量候选需要达到最低相似度，避免哈希碰撞带来的噪声命中；
      // BM25 命中的片段始终保留。
      if (lexical <= 0 && cosine < 0.15) continue;
      final double hybrid = lexical + 0.35 * cosine;
      if (hybrid <= 0) continue;
      scored.add(<String, dynamic>{
        'score': hybrid,
        'bm25_score': lexical,
        'vector_score': cosine,
        'chunk': chunk,
        'snippet': _snippet(
            (chunk['text'] ?? '').toString(), qtf.keys.toList()),
      });
    }
    scored.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final int byScore =
          (b['score'] as double).compareTo(a['score'] as double);
      if (byScore != 0) return byScore;
      return (a['chunk'] as Map)['id']
          .toString()
          .compareTo((b['chunk'] as Map)['id'].toString());
    });
    final Map<String, Map<String, dynamic>> libs = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> l in _libraries)
        (l['id'] ?? '').toString(): l,
    };
    final Map<String, Map<String, dynamic>> docs = <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> d in _documents) (d['id'] ?? '').toString(): d,
    };
    final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
    final Set<String> usedDocChunk = <String>{};
    for (final Map<String, dynamic> s in scored) {
      final Map<String, dynamic> c =
          Map<String, dynamic>.from(s['chunk'] as Map);
      final String key = '${c['document_id']}#${c['ordinal']}';
      if (!usedDocChunk.add(key)) continue;
      final Map<String, dynamic> lib =
          libs[(c['library_id'] ?? '').toString()] ?? <String, dynamic>{};
      final Map<String, dynamic> doc =
          docs[(c['document_id'] ?? '').toString()] ?? <String, dynamic>{};
      results.add(<String, dynamic>{
        'library_id': c['library_id'],
        'library_name': lib['name'] ?? '',
        'document_id': c['document_id'],
        'document_name': doc['name'] ?? '',
        'path': doc['path'] ?? '',
        'chunk_id': c['id'],
        'ordinal': c['ordinal'],
        'score': _round(s['score'] as double),
        'bm25_score': _round(s['bm25_score'] as double),
        'vector_score': _round(s['vector_score'] as double),
        'backend': vectorStore.backendName,
        'degraded': degraded,
        'snippet': s['snippet'],
      });
      if (results.length >= topK) break;
    }
    return <String, dynamic>{
      'ok': true,
      'query': query,
      'results': results,
      'searched_chunks': pool.length,
      'backend': vectorStore.backendName,
      'degraded': degraded,
      if (vectorError.isNotEmpty) 'vector_error': vectorError,
    };
  }

  double _round(double value) => double.parse(value.toStringAsFixed(4));

  String _vectorErrorText(Object e) =>
      e is VectorStoreException ? e.message : '$e';

  /// 删除文档/库时清理对应向量；尽力而为，陈留向量不会在检索中被匹配，
  /// 因为结果只接受当前仍存在的 chunk id。
  Future<void> _deleteVectors(Iterable<Map<String, dynamic>> chunks) async {
    for (final Map<String, dynamic> chunk in chunks) {
      try {
        await vectorStore.delete(
            _vectorCollection, (chunk['id'] ?? '').toString());
      } on Object {
        // 清理失败不掩盖文本删除；检索侧按现有 chunk 过滤。
      }
    }
  }

  Future<Map<String, dynamic>> _vectorStats() async {
    try {
      final Map<String, dynamic> stats =
          await vectorStore.stats(_vectorCollection);
      return <String, dynamic>{
        'ok': true,
        'backend': vectorStore.backendName,
        'available': vectorStore.available,
        'collection': _vectorCollection,
        'chunks': _chunks.length,
        'count': stats['count'],
        'dimensions': stats['dimensions'],
        'stats': stats,
      };
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'backend': vectorStore.backendName,
        'available': vectorStore.available,
        'error': _vectorErrorText(e),
        'code': e is VectorStoreException ? e.code : 'vector_error',
      };
    }
  }

  /// 真实重建：删除当前 chunk 的旧向量，再按最新文本重新 embedding 写入。
  Future<Map<String, dynamic>> _rebuildVectors(Map<String, dynamic> p) async {
    final String libraryId = (p['library_id'] ?? '').toString();
    final List<Map<String, dynamic>> chunks = _chunks
        .where((Map<String, dynamic> c) =>
            libraryId.isEmpty || c['library_id'] == libraryId)
        .toList();
    int deleted = 0;
    int upserted = 0;
    final List<String> errors = <String>[];
    for (final Map<String, dynamic> chunk in chunks) {
      final String id = (chunk['id'] ?? '').toString();
      try {
        await vectorStore.delete(_vectorCollection, id);
        deleted++;
      } on Object catch (e) {
        errors.add('delete $id: ${_vectorErrorText(e)}');
      }
    }
    for (final Map<String, dynamic> chunk in chunks) {
      final String id = (chunk['id'] ?? '').toString();
      try {
        await vectorStore.upsert(
          _vectorCollection,
          id,
          HashingTrick.embed((chunk['text'] ?? '').toString()),
          <String, dynamic>{
            'chunk_id': chunk['id'],
            'library_id': chunk['library_id'],
            'document_id': chunk['document_id'],
            'ordinal': chunk['ordinal'],
          },
        );
        upserted++;
      } on Object catch (e) {
        errors.add('upsert $id: ${_vectorErrorText(e)}');
      }
    }
    return <String, dynamic>{
      'ok': errors.isEmpty,
      'backend': vectorStore.backendName,
      'collection': _vectorCollection,
      'chunks': chunks.length,
      'deleted': deleted,
      'vectors': upserted,
      if (libraryId.isNotEmpty) 'library_id': libraryId,
      if (errors.isNotEmpty) 'error': errors.first,
      if (errors.isNotEmpty) 'errors': errors.take(5).toList(),
    };
  }

  int _intOf(dynamic v) => v is num ? v.toInt() : 0;

  String _snippet(String text, List<String> terms) {
    final String lower = text.toLowerCase();
    int first = -1;
    for (final String t in terms) {
      final int i = lower.indexOf(t);
      if (i >= 0 && (first < 0 || i < first)) first = i;
    }
    final int start = first <= 60 ? 0 : first - 60;
    final int end = (start + 220 < text.length) ? start + 220 : text.length;
    final String s = text.substring(start, end).replaceAll('\n', ' ').trim();
    return '${start > 0 ? '…' : ''}$s${end < text.length ? '…' : ''}';
  }

  /// 供聊天注入的检索上下文：真实命中才注入，并明确要求标注来源。
  Future<String> contextBlock(
    String query, {
    String personaId = '',
    List<String> libraryIds = const <String>[],
    int topK = 4,
  }) async {
    if (query.trim().isEmpty) return '';
    final Map<String, dynamic> r = await _search(<String, dynamic>{
      'query': query,
      'top_k': topK,
      'persona_id': personaId,
      'library_ids': libraryIds,
    });
    final List<dynamic> results = r['results'] is List ? r['results'] as List : <dynamic>[];
    if (results.isEmpty) return '';
    final bool degraded = r['degraded'] == true;
    final StringBuffer b = StringBuffer()
      ..writeln(degraded
          ? '【私有知识库检索结果（向量库不可用，已降级为本地 BM25 真实命中，引用必须标注来源）】'
          : '【私有知识库检索结果（本地 BM25 + 向量混合检索真实命中，引用必须标注来源）】');
    for (int i = 0; i < results.length; i++) {
      final Map<String, dynamic> x =
          Map<String, dynamic>.from(results[i] as Map);
      b.writeln('[${i + 1}] 库「${x['library_name']}」/ 文档「${x['document_name']}」'
          ' #${x['ordinal']}：${x['snippet']}');
    }
    b.writeln('回答涉及以上内容时请在句末标注 [来源: 文档名#片段]；'
        '没有命中就如实说知识库里没有找到，不要编造引用。');
    return b.toString();
  }

  Future<Map<String, dynamic>> _snapshot(Map<String, dynamic> p) async {
    final String id = (p['library_id'] ?? '').toString();
    final Map<String, dynamic> lib = _findLibrary(id);
    if (lib.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    final String snapId = _id('snap');
    final List<Map<String, dynamic>> docs = _documents
        .where((Map<String, dynamic> d) => d['library_id'] == id)
        .toList();
    final List<Map<String, dynamic>> chunks = _chunks
        .where((Map<String, dynamic> c) => c['library_id'] == id)
        .toList();
    final String file = 'knowledge_snapshots/$snapId.json';
    await store.writeJson(file, <String, dynamic>{
      'id': snapId,
      'library': lib,
      'documents': docs,
      'chunks': chunks,
      'created_at': DateTime.now().toIso8601String(),
    });
    final Map<String, dynamic> meta = <String, dynamic>{
      'id': snapId,
      'file': file,
      'created_at': DateTime.now().toIso8601String(),
      'documents': docs.length,
      'chunks': chunks.length,
    };
    final List<dynamic> snaps =
        lib['snapshots'] is List ? lib['snapshots'] as List : <dynamic>[];
    // 只保留最近 10 个版本元数据；快照文件本身保留在磁盘，便于恢复。
    lib['snapshots'] = <dynamic>[...snaps, meta].take(10).toList();
    _setList('libraries', _libraries);
    await _save();
    return <String, dynamic>{'ok': true, 'snapshot': meta};
  }

  Map<String, dynamic> _snapshots(Map<String, dynamic> p) {
    final String id = (p['library_id'] ?? '').toString();
    final Map<String, dynamic> lib = _findLibrary(id);
    if (lib.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    return <String, dynamic>{
      'ok': true,
      'snapshots': lib['snapshots'] is List ? lib['snapshots'] as List : <dynamic>[],
    };
  }

  Future<Map<String, dynamic>> _restore(Map<String, dynamic> p) async {
    final String libraryId = (p['library_id'] ?? '').toString();
    final String snapId = (p['snapshot_id'] ?? '').toString();
    final Map<String, dynamic> lib = _findLibrary(libraryId);
    if (lib.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '知识库不存在'};
    }
    final List<dynamic> snaps =
        lib['snapshots'] is List ? lib['snapshots'] as List : <dynamic>[];
    Map<String, dynamic>? meta;
    for (final dynamic raw in snaps) {
      if (raw is Map && (raw['id'] ?? '').toString() == snapId) {
        meta = Map<String, dynamic>.from(raw);
        break;
      }
    }
    if (meta == null) {
      return <String, dynamic>{'ok': false, 'error': '快照不存在：$snapId'};
    }
    final Map<String, dynamic> snap =
        await store.readJson((meta['file'] ?? '').toString());
    final List<Map<String, dynamic>> docs = _maps(snap['documents']);
    final List<Map<String, dynamic>> chunks = _maps(snap['chunks']);
    _setList('documents', <Map<String, dynamic>>[
      ..._documents.where((Map<String, dynamic> d) => d['library_id'] != libraryId),
      ...docs,
    ]);
    _setList('chunks', <Map<String, dynamic>>[
      ..._chunks.where((Map<String, dynamic> c) => c['library_id'] != libraryId),
      ...chunks,
    ]);
    lib['updated_at'] = DateTime.now().toIso8601String();
    _setList('libraries', _libraries);
    await _save();
    return <String, dynamic>{
      'ok': true,
      'restored': snapId,
      'documents': docs.length,
      'chunks': chunks.length,
    };
  }
}
