/// 可切换向量存储：本地真实落盘 + 远程 Qdrant / Chroma HTTP 适配。
///
/// 设计红线（与知识库一致）：
///  * 本地向量真实写入 App 私有目录 `vectors/<collection>.json`，重启后可恢复；
///    文本用 Hashing Trick 映射到 256 维并 L2 归一化，余弦相似度真实计算。
///  * 远程库只发真实 HTTP 请求；未配置 baseUrl、超时、非 2xx、响应结构异常
///    都抛 [VectorStoreException]，绝不返回假命中或假装写入成功。
///  * 不 eval、不反序列化任意对象；元数据只保留 JSON 兼容值。
///
/// 远程接口约定（构造时 style 选择）：
///  * `qdrant`：PUT /collections/{c}/points、POST /collections/{c}/points/search、
///    POST /collections/{c}/points/delete、GET /collections/{c}。
///  * `chroma`：POST /api/v1/collections/{c}/upsert、/query、/delete、
///    GET /api/v1/collections/{c}/count。这里的 c 需要是 Chroma collection id。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'store.dart';

/// 向量库统一错误：带稳定错误码，调用方可据此决定降级或如实报错。
class VectorStoreException implements Exception {
  VectorStoreException(this.message, {this.code = 'vector_error'});

  final String message;
  final String code;

  @override
  String toString() => 'VectorStoreException($code): $message';
}

class VectorMatch {
  const VectorMatch(this.id, this.score, this.metadata);

  final String id;
  final double score;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'score': score,
        'metadata': Map<String, dynamic>.from(metadata),
      };
}

/// 向量库抽象。collection 是逻辑集合名，具体落点由实现决定。
abstract class VectorStore {
  String get backendName;

  /// 配置完整且当前可尝试读写；远程未配置时为 false。
  bool get available;

  Future<void> upsert(
    String collection,
    String id,
    List<double> vector, [
    Map<String, dynamic> metadata = const <String, dynamic>{},
  ]);

  Future<List<VectorMatch>> query(
    String collection,
    List<double> vector, [
    int topK = 8,
  ]);

  Future<void> delete(String collection, String id);

  Future<Map<String, dynamic>> stats(String collection);
}

/// Hashing Trick 词项向量化 + 余弦相似度（确定性、无外部模型依赖）。
class HashingTrick {
  static const int defaultDimensions = 256;

  /// 中文单字 + 二元组，英文/数字按词；与 BM25 分词保持同一口径。
  static List<String> tokenize(String text) {
    final String lower = text.toLowerCase();
    final List<String> out = <String>[];
    for (final RegExpMatch m in RegExp(r'[a-z0-9_]{2,}').allMatches(lower)) {
      out.add(m.group(0)!);
    }
    final List<String> cjk = RegExp(r'[\u4e00-\u9fff]')
        .allMatches(lower)
        .map((RegExpMatch m) => m.group(0)!)
        .toList();
    for (int i = 0; i < cjk.length; i++) {
      if (cjk.length == 1) out.add(cjk[i]);
      if (i + 1 < cjk.length) out.add('${cjk[i]}${cjk[i + 1]}');
    }
    // 单个英文/数字字符或纯符号文本：用整段非空文本兜底，避免合法输入
    // 被误判为空向量；空文本仍由 embedTerms 明确报错。
    if (out.isEmpty && lower.trim().isNotEmpty) out.add(lower.trim());
    return out;
  }

  /// 把一段文本映射为 L2 归一化的 [dimensions] 维向量；空文本明确报错。
  static List<double> embed(String text, {int dimensions = defaultDimensions}) =>
      embedTerms(tokenize(text), dimensions: dimensions);

  /// 把词项列表映射为向量。同一词项固定落同一个桶与符号（确定性）。
  static List<double> embedTerms(
    Iterable<String> terms, {
    int dimensions = defaultDimensions,
  }) {
    if (dimensions <= 0) {
      throw VectorStoreException('向量维度必须为正数：$dimensions',
          code: 'bad_dimension');
    }
    final Map<String, int> counts = <String, int>{};
    for (final String term in terms) {
      if (term.isEmpty) continue;
      counts[term] = (counts[term] ?? 0) + 1;
    }
    if (counts.isEmpty) {
      throw VectorStoreException('空文本/空词项无法生成向量',
          code: 'empty_vector');
    }
    final List<double> vector = List<double>.filled(dimensions, 0.0);
    counts.forEach((String term, int tf) {
      final int hash = _fnv1a(term);
      final int bucket = hash % dimensions;
      final double sign = ((hash >> 16) & 1) == 0 ? 1.0 : -1.0;
      // 次线性 TF，避免长片段被高频词支配。
      vector[bucket] += sign * (1.0 + math.log(tf.toDouble()));
    });
    return normalize(vector);
  }

  /// L2 归一化；空向量 / 非有限值明确拒绝。
  static List<double> normalize(List<double> vector) {
    if (vector.isEmpty) {
      throw VectorStoreException('空向量被拒绝', code: 'empty_vector');
    }
    double sum = 0;
    for (final double x in vector) {
      if (!x.isFinite) {
        throw VectorStoreException('向量包含非有限数值', code: 'bad_vector');
      }
      sum += x * x;
    }
    if (sum <= 0) {
      throw VectorStoreException('空向量（模长为 0）被拒绝', code: 'empty_vector');
    }
    final double inv = 1 / math.sqrt(sum);
    return List<double>.generate(
        vector.length, (int i) => vector[i] * inv,
        growable: false);
  }

  /// 余弦相似度；维度不符 / 空向量 / 非有限值明确拒绝。
  static double cosine(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty) {
      throw VectorStoreException('空向量无法计算余弦相似度',
          code: 'empty_vector');
    }
    if (a.length != b.length) {
      throw VectorStoreException(
          '向量维度不一致：${a.length} != ${b.length}',
          code: 'dimension_mismatch');
    }
    double dot = 0;
    double na = 0;
    double nb = 0;
    for (int i = 0; i < a.length; i++) {
      final double x = a[i];
      final double y = b[i];
      if (!x.isFinite || !y.isFinite) {
        throw VectorStoreException('向量包含非有限数值', code: 'bad_vector');
      }
      dot += x * y;
      na += x * x;
      nb += y * y;
    }
    if (na <= 0 || nb <= 0) {
      throw VectorStoreException('空向量（模长为 0）无法计算相似度',
          code: 'empty_vector');
    }
    return (dot / (math.sqrt(na) * math.sqrt(nb))).clamp(-1.0, 1.0).toDouble();
  }

  /// 校验向量维度与非零模长（写入/查询前的统一入口）。
  static void validate(List<double> vector, int expected, {String what = '向量'}) {
    if (vector.isEmpty) {
      throw VectorStoreException('$what 为空被拒绝', code: 'empty_vector');
    }
    if (vector.length != expected) {
      throw VectorStoreException(
          '$what 维度不符：需要 $expected 维，实际 ${vector.length} 维',
          code: 'dimension_mismatch');
    }
    double sum = 0;
    for (final double x in vector) {
      if (!x.isFinite) {
        throw VectorStoreException('$what 包含非有限数值', code: 'bad_vector');
      }
      sum += x * x;
    }
    if (sum <= 0) {
      throw VectorStoreException('$what 模长为 0 被拒绝', code: 'empty_vector');
    }
  }

  static int _fnv1a(String input) {
    int hash = 0x811c9dc5;
    for (final int unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }
}

class _StoredVector {
  _StoredVector(this.vector, this.metadata);
  final List<double> vector;
  final Map<String, dynamic> metadata;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'vector': vector,
        'metadata': metadata,
      };

  static _StoredVector? fromJson(dynamic raw, int dimensions) {
    if (raw is! Map) return null;
    final dynamic vec = raw['vector'];
    if (vec is! List || vec.length != dimensions) return null;
    final List<double> vector = <double>[];
    for (final dynamic v in vec) {
      if (v is! num || !v.toDouble().isFinite) return null;
      vector.add(v.toDouble());
    }
    final Map<String, dynamic> metadata = raw['metadata'] is Map
        ? Map<String, dynamic>.from(raw['metadata'] as Map)
        : <String, dynamic>{};
    return _StoredVector(vector, metadata);
  }
}

/// 本地向量库：真实落盘到 `vectors/<collection>.json`，读写串行化。
class LocalHashedVectorStore implements VectorStore {
  LocalHashedVectorStore(this.store, {this.dimensions = HashingTrick.defaultDimensions});

  final HarnessStore store;
  final int dimensions;

  final Map<String, Map<String, _StoredVector>> _cache =
      <String, Map<String, _StoredVector>>{};
  final Map<String, Future<void>> _writeChains = <String, Future<void>>{};

  @override
  String get backendName => 'local';

  @override
  bool get available => store.writable;

  String _safeName(String collection) {
    final String name = collection.trim();
    if (name.isEmpty) {
      throw VectorStoreException('collection 名称不能为空',
          code: 'bad_collection');
    }
    final String safe = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    if (safe.isEmpty) {
      throw VectorStoreException('collection 名称无效：$collection',
          code: 'bad_collection');
    }
    return safe;
  }

  String pathFor(String collection) =>
      'vectors/${_safeName(collection)}.json';

  Future<Map<String, _StoredVector>> _load(String collection) async {
    final Map<String, _StoredVector>? cached = _cache[collection];
    if (cached != null) return cached;
    final Map<String, dynamic> raw = await store.readJson(
      pathFor(collection),
      fallback: <String, dynamic>{'version': 1, 'vectors': <dynamic>[]},
    );
    final Map<String, _StoredVector> loaded = <String, _StoredVector>{};
    final dynamic vectors = raw['vectors'];
    if (vectors is List) {
      for (final dynamic entry in vectors) {
        if (entry is! Map) continue;
        final String id = (entry['id'] ?? '').toString();
        if (id.isEmpty) continue;
        // 统一按当前维度解析：旧文件里维度不符的条目直接跳过，不冒充可用。
        final _StoredVector? stored = _StoredVector.fromJson(entry, dimensions);
        if (stored != null) loaded[id] = stored;
      }
    }
    _cache[collection] = loaded;
    return loaded;
  }

  Future<void> _persist(String collection, Map<String, _StoredVector> vectors) {
    final Future<void> previous =
        _writeChains[collection] ?? Future<void>.value();
    final Future<void> next = previous.then((_) async {
      await store.writeJson(pathFor(collection), <String, dynamic>{
        'version': 1,
        'collection': collection,
        'dimensions': dimensions,
        'updated_at': DateTime.now().toIso8601String(),
        'vectors': vectors.entries
            .map((MapEntry<String, _StoredVector> e) => <String, dynamic>{
                  'id': e.key,
                  ...e.value.toJson(),
                })
            .toList(),
      });
    });
    // 单次失败不把串行链焊死：后续写入仍要执行，调用方拿到本次异常。
    _writeChains[collection] = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> upsert(
    String collection,
    String id,
    List<double> vector, [
    Map<String, dynamic> metadata = const <String, dynamic>{},
  ]) async {
    if (id.trim().isEmpty) {
      throw VectorStoreException('向量 id 不能为空', code: 'bad_id');
    }
    HashingTrick.validate(vector, dimensions, what: '写入向量');
    final Map<String, _StoredVector> vectors = await _load(collection);
    vectors[id] = _StoredVector(
      HashingTrick.normalize(vector),
      Map<String, dynamic>.from(metadata),
    );
    await _persist(collection, vectors);
  }

  @override
  Future<List<VectorMatch>> query(
    String collection,
    List<double> vector, [
    int topK = 8,
  ]) async {
    HashingTrick.validate(vector, dimensions, what: '查询向量');
    final int limit = topK.clamp(1, 1000).toInt();
    final Map<String, _StoredVector> vectors = await _load(collection);
    final List<VectorMatch> matches = <VectorMatch>[];
    final List<double> query = HashingTrick.normalize(vector);
    vectors.forEach((String id, _StoredVector stored) {
      matches.add(VectorMatch(
        id,
        HashingTrick.cosine(query, stored.vector),
        Map<String, dynamic>.from(stored.metadata),
      ));
    });
    matches.sort((VectorMatch a, VectorMatch b) {
      final int byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.id.compareTo(b.id);
    });
    return matches.take(limit).toList();
  }

  @override
  Future<void> delete(String collection, String id) async {
    final Map<String, _StoredVector> vectors = await _load(collection);
    if (vectors.remove(id) == null) return;
    await _persist(collection, vectors);
  }

  @override
  Future<Map<String, dynamic>> stats(String collection) async {
    final Map<String, _StoredVector> vectors = await _load(collection);
    return <String, dynamic>{
      'backend': backendName,
      'collection': collection,
      'count': vectors.length,
      'dimensions': dimensions,
      'file': store.file(pathFor(collection)).path,
    };
  }
}

// ---------------------------------------------------------------------------
// 远程 HTTP 适配
// ---------------------------------------------------------------------------

class VectorHttpResponse {
  const VectorHttpResponse(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

/// 最小 HTTP 传输契约，方便注入真实客户端或测试替身。
abstract class VectorHttpClient {
  Future<VectorHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  });

  void close();
}

typedef VectorHttpClientFactory = VectorHttpClient Function();

class _IoVectorHttpClient implements VectorHttpClient {
  _IoVectorHttpClient(this.timeout);

  final Duration timeout;
  HttpClient? _client;

  HttpClient get _clientOrCreate {
    final HttpClient? existing = _client;
    if (existing != null) return existing;
    final HttpClient created = HttpClient()
      ..connectionTimeout = timeout;
    _client = created;
    return created;
  }

  @override
  Future<VectorHttpResponse> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    try {
      final HttpClientRequest request =
          await _clientOrCreate.openUrl(method, uri).timeout(timeout);
      headers.forEach((String key, String value) {
        request.headers.set(key, value);
      });
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final HttpClientResponse response = await request.close().timeout(timeout);
      final String text = await utf8.decoder
          .bind(response)
          .join()
          .timeout(timeout);
      return VectorHttpResponse(response.statusCode, text);
    } on TimeoutException {
      throw VectorStoreException(
          '向量库请求超时（${timeout.inSeconds}s）', code: 'timeout');
    } on SocketException catch (e) {
      throw VectorStoreException('无法连接向量库：${e.message}',
          code: 'network_error');
    } on HandshakeException catch (e) {
      throw VectorStoreException('向量库 TLS 握手失败：${e.message}',
          code: 'network_error');
    } on HttpException catch (e) {
      throw VectorStoreException('向量库 HTTP 异常：${e.message}',
          code: 'network_error');
    }
  }

  @override
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}

/// 通用远程向量库适配器：支持 Qdrant 与 Chroma 风格端点。
class RemoteVectorStore implements VectorStore {
  RemoteVectorStore({
    String style = 'qdrant',
    required this.baseUrl,
    this.apiKey = '',
    this.collection = '',
    VectorHttpClientFactory? clientFactory,
    this.timeout = const Duration(seconds: 10),
  })  : style = style.toLowerCase(),
        _clientFactory = clientFactory {
    if (this.style != 'qdrant' && this.style != 'chroma') {
      throw VectorStoreException(
          '不支持的远程向量库类型：$style（仅 qdrant / chroma）',
          code: 'bad_config');
    }
  }

  final String style;
  final String baseUrl;
  final String apiKey;
  final String collection;
  final Duration timeout;
  final VectorHttpClientFactory? _clientFactory;

  VectorHttpClient? _client;

  @override
  String get backendName => style;

  @override
  bool get available => baseUrl.trim().isNotEmpty;

  VectorHttpClient get _http =>
      _client ??= (_clientFactory?.call() ?? _IoVectorHttpClient(timeout));

  void close() {
    _client?.close();
    _client = null;
  }

  String _resolveCollection(String name) {
    final String resolved =
        name.trim().isNotEmpty ? name.trim() : collection.trim();
    if (resolved.isEmpty) {
      throw VectorStoreException('未指定 collection，且默认 collection 为空',
          code: 'bad_collection');
    }
    return resolved;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final Uri? base = Uri.tryParse(baseUrl.trim());
    if (base == null ||
        !base.hasScheme ||
        (base.scheme != 'http' && base.scheme != 'https') ||
        base.host.isEmpty) {
      throw VectorStoreException(
          '远程向量库（$style）未配置有效的 http(s) baseUrl，明确不可用：'
          '${baseUrl.isEmpty ? '(空)' : baseUrl}',
          code: 'not_configured');
    }
    final String prefix = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    return base.replace(path: '$prefix$path', queryParameters: query);
  }

  Map<String, String> _headers() {
    final Map<String, String> headers = <String, String>{
      'Accept': 'application/json',
    };
    if (apiKey.isNotEmpty) {
      if (style == 'qdrant') {
        headers['api-key'] = apiKey;
      } else {
        headers['Authorization'] = 'Bearer $apiKey';
        headers['X-Chroma-Token'] = apiKey;
      }
    }
    return headers;
  }

  Future<String> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Map<String, String>? query,
  }) async {
    if (!available) {
      throw VectorStoreException(
          '远程向量库（$style）未配置 baseUrl，拒绝发起请求（不伪造成功）',
          code: 'not_configured');
    }
    final Uri uri = _uri(path, query);
    VectorHttpResponse response;
    try {
      response = await _http.send(
        method,
        uri,
        headers: _headers(),
        body: body == null ? null : jsonEncode(body),
      );
    } on VectorStoreException {
      rethrow;
    } on Object catch (e) {
      throw VectorStoreException('向量库请求失败：$e', code: 'network_error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw VectorStoreException(
        '$style 返回 HTTP ${response.statusCode}：${_truncate(response.body)}',
        code: 'http_error',
      );
    }
    return response.body;
  }

  static String _truncate(String text, [int max = 300]) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  static dynamic _decode(String body) {
    if (body.trim().isEmpty) return <String, dynamic>{};
    try {
      return jsonDecode(body);
    } on FormatException {
      throw VectorStoreException(
          '向量库返回非 JSON 响应：${_truncate(body)}', code: 'bad_response');
    }
  }

  static String _pointId(String id) {
    if (RegExp(r'^[0-9]+$').hasMatch(id)) return id;
    if (RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
            r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        .hasMatch(id)) {
      return id;
    }
    // Qdrant 只接受 uint64 / UUID；用 SHA-1 派生确定性 UUIDv5 风格 id，
    // 原始 chunk id 仍放在 payload，查询时取回。
    final String hex = sha1
        .convert(utf8.encode('tangram-vector-point:$id'))
        .bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final int variantByte = int.parse(hex.substring(16, 18), radix: 16);
    final String variant =
        ((variantByte & 0x3f) | 0x80).toRadixString(16).padLeft(2, '0');
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '5${hex.substring(13, 16)}-$variant${hex.substring(18, 20)}-'
        '${hex.substring(20, 32)}';
  }

  @override
  Future<void> upsert(
    String collection,
    String id,
    List<double> vector, [
    Map<String, dynamic> metadata = const <String, dynamic>{},
  ]) async {
    if (id.trim().isEmpty) {
      throw VectorStoreException('向量 id 不能为空', code: 'bad_id');
    }
    HashingTrick.validate(vector, HashingTrick.defaultDimensions,
        what: '写入向量');
    final String coll = Uri.encodeComponent(_resolveCollection(collection));
    final Map<String, dynamic> payload = <String, dynamic>{
      ...Map<String, dynamic>.from(metadata),
      'chunk_id': (metadata['chunk_id'] ?? id).toString(),
    };
    if (style == 'qdrant') {
      await _send(
        'PUT',
        '/collections/$coll/points',
        query: <String, String>{'wait': 'true'},
        body: <String, dynamic>{
          'points': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': _pointId(id),
              'vector': vector,
              'payload': payload,
            },
          ],
        },
      );
      return;
    }
    await _send(
      'POST',
      '/api/v1/collections/$coll/upsert',
      body: <String, dynamic>{
        'ids': <String>[id],
        'embeddings': <List<double>>[vector],
        'metadatas': <Map<String, dynamic>>[payload],
      },
    );
  }

  @override
  Future<List<VectorMatch>> query(
    String collection,
    List<double> vector, [
    int topK = 8,
  ]) async {
    HashingTrick.validate(vector, HashingTrick.defaultDimensions,
        what: '查询向量');
    final int limit = topK.clamp(1, 1000).toInt();
    final String coll = Uri.encodeComponent(_resolveCollection(collection));
    final dynamic decoded;
    if (style == 'qdrant') {
      decoded = _decode(await _send(
        'POST',
        '/collections/$coll/points/search',
        body: <String, dynamic>{
          'vector': vector,
          'limit': limit,
          'with_payload': true,
        },
      ));
      final dynamic result = decoded is Map ? decoded['result'] : null;
      if (result is! List) {
        throw VectorStoreException('qdrant 查询响应缺少 result 列表',
            code: 'bad_response');
      }
      final List<VectorMatch> matches = <VectorMatch>[];
      for (final dynamic raw in result) {
        if (raw is! Map) continue;
        final Map<String, dynamic> payload = raw['payload'] is Map
            ? Map<String, dynamic>.from(raw['payload'] as Map)
            : <String, dynamic>{};
        final String id =
            (payload['chunk_id'] ?? raw['id'] ?? '').toString();
        if (id.isEmpty) continue;
        matches.add(VectorMatch(
          id,
          (raw['score'] as num?)?.toDouble() ?? 0,
          payload,
        ));
      }
      return matches;
    }

    decoded = _decode(await _send(
      'POST',
      '/api/v1/collections/$coll/query',
      body: <String, dynamic>{
        'query_embeddings': <List<double>>[vector],
        'n_results': limit,
        'include': <String>['metadatas', 'distances'],
      },
    ));
    if (decoded is! Map) {
      throw VectorStoreException('chroma 查询响应不是对象',
          code: 'bad_response');
    }
    final dynamic ids = decoded['ids'];
    final dynamic distances = decoded['distances'];
    final dynamic metadatas = decoded['metadatas'];
    if (ids is! List || ids.isEmpty || ids.first is! List) {
      return <VectorMatch>[];
    }
    final List<dynamic> idList = ids.first as List;
    final List<dynamic> distanceList = (distances is List && distances.isNotEmpty)
        ? (distances.first as List)
        : <dynamic>[];
    final List<dynamic> metaList =
        (metadatas is List && metadatas.isNotEmpty && metadatas.first is List)
            ? metadatas.first as List
            : <dynamic>[];
    final List<VectorMatch> matches = <VectorMatch>[];
    for (int i = 0; i < idList.length; i++) {
      final String id = idList[i].toString();
      if (id.isEmpty) continue;
      final Map<String, dynamic> metadata =
          i < metaList.length && metaList[i] is Map
              ? Map<String, dynamic>.from(metaList[i] as Map)
              : <String, dynamic>{};
      final double distance =
          i < distanceList.length && distanceList[i] is num
              ? (distanceList[i] as num).toDouble()
              : 1.0;
      matches.add(VectorMatch(
        (metadata['chunk_id'] ?? id).toString(),
        1.0 - distance,
        metadata,
      ));
    }
    return matches;
  }

  @override
  Future<void> delete(String collection, String id) async {
    final String coll = Uri.encodeComponent(_resolveCollection(collection));
    if (style == 'qdrant') {
      await _send(
        'POST',
        '/collections/$coll/points/delete',
        query: <String, String>{'wait': 'true'},
        body: <String, dynamic>{
          'points': <String>[_pointId(id)],
        },
      );
      return;
    }
    await _send(
      'POST',
      '/api/v1/collections/$coll/delete',
      body: <String, dynamic>{
        'ids': <String>[id],
      },
    );
  }

  @override
  Future<Map<String, dynamic>> stats(String collection) async {
    final String coll = Uri.encodeComponent(_resolveCollection(collection));
    if (style == 'qdrant') {
      final dynamic decoded =
          _decode(await _send('GET', '/collections/$coll'));
      final dynamic result = decoded is Map ? decoded['result'] : null;
      final int count =
          result is Map ? (result['points_count'] as num?)?.toInt() ?? 0 : 0;
      return <String, dynamic>{
        'backend': backendName,
        'collection': _resolveCollection(collection),
        'count': count,
      };
    }
    final dynamic decoded = _decode(
        await _send('GET', '/api/v1/collections/$coll/count'));
    final int count = decoded is num
        ? decoded.toInt()
        : (decoded is Map ? (decoded['count'] as num?)?.toInt() ?? 0 : 0);
    return <String, dynamic>{
      'backend': backendName,
      'collection': _resolveCollection(collection),
      'count': count,
    };
  }
}

/// 向量存储配置。backend ∈ local / qdrant / chroma，默认 local。
class VectorStoreConfig {
  const VectorStoreConfig({
    this.backend = 'local',
    this.baseUrl = '',
    this.apiKey = '',
    this.collection = '',
    this.dimensions = HashingTrick.defaultDimensions,
  });

  final String backend;
  final String baseUrl;
  final String apiKey;
  final String collection;
  final int dimensions;

  factory VectorStoreConfig.local({int dimensions = HashingTrick.defaultDimensions}) =>
      VectorStoreConfig(dimensions: dimensions);

  factory VectorStoreConfig.qdrant({
    required String baseUrl,
    String apiKey = '',
    String collection = '',
  }) =>
      VectorStoreConfig(
        backend: 'qdrant',
        baseUrl: baseUrl,
        apiKey: apiKey,
        collection: collection,
      );

  factory VectorStoreConfig.chroma({
    required String baseUrl,
    String apiKey = '',
    String collection = '',
  }) =>
      VectorStoreConfig(
        backend: 'chroma',
        baseUrl: baseUrl,
        apiKey: apiKey,
        collection: collection,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'backend': backend,
        'base_url': baseUrl,
        'collection': collection,
        'dimensions': dimensions,
        'has_api_key': apiKey.isNotEmpty,
      };
}

class VectorStoreFactory {
  static VectorStore create(
    VectorStoreConfig config,
    HarnessStore store, {
    VectorHttpClientFactory? clientFactory,
  }) {
    switch (config.backend.toLowerCase()) {
      case 'local':
        return LocalHashedVectorStore(store, dimensions: config.dimensions);
      case 'qdrant':
      case 'chroma':
        return RemoteVectorStore(
          style: config.backend,
          baseUrl: config.baseUrl,
          apiKey: config.apiKey,
          collection: config.collection,
          clientFactory: clientFactory,
        );
      default:
        throw VectorStoreException(
            '未知向量库后端：${config.backend}（local / qdrant / chroma）',
            code: 'bad_config');
    }
  }
}
