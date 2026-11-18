/// 真实联网搜索：DuckDuckGo HTML 端点优先，失败/无结果时回退中文维基百科 API。
///
/// 实现要点（参考 SearXNG / httpx / BeautifulSoup 的行为，但只用 Dart 原生）：
///   * 网络层只用 dart:io HttpClient，带 User-Agent，整体 10s 超时；可注入
///     httpGet 或 base URL 以便测试，不需要新增依赖。
///   * HTML 解析按 class 属性定位 `result__a` / `result__snippet`，
///     对属性顺序、单双引号、实体转义与嵌套标签全部容错。
///   * DuckDuckGo 的 `/l/?uddg=` 跳转链接会还原成真实 URL；非 http(s) 链接丢弃。
///   * 按 url 去重、按 limit 截断；两个来源都拿不到结果时返回 ok=false，
///     绝不编造标题、链接或摘要。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 可注入的 HTTP GET：返回响应正文（UTF-8 解码，容错非法字节）。
typedef HttpGetFn = Future<String> Function(Uri uri);

/// 一条真实搜索结果。
class WebSearchResult {
  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
    required this.source,
    required this.fetchedAt,
  });

  final String title;
  final String url;
  final String snippet;

  /// 'duckduckgo' | 'wikipedia'
  final String source;
  final DateTime fetchedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'url': url,
        'snippet': snippet,
        'source': source,
        'fetchedAt': fetchedAt.toIso8601String(),
      };
}

class WebSearchService {
  WebSearchService({
    HttpGetFn? httpGet,
    this.duckDuckGoBaseUrl = 'https://html.duckduckgo.com',
    this.wikipediaBaseUrl = 'https://zh.wikipedia.org',
    this.timeout = const Duration(seconds: 10),
  }) : _httpGet = httpGet;

  final HttpGetFn? _httpGet;
  final String duckDuckGoBaseUrl;
  final String wikipediaBaseUrl;
  final Duration timeout;

  static const String _userAgent =
      'TangramAgent/0.0.11 (+https://github.com/tangram-agent; web_search)';

  /// 真实搜索。任何异常都转成结构化结果，不向调用方抛未捕获异常。
  Future<Map<String, dynamic>> search(String query, {int limit = 8}) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'query': q,
        'error': '搜索关键词为空',
      };
    }
    final int cap = limit <= 0 ? 8 : (limit > 20 ? 20 : limit);
    final DateTime fetchedAt = DateTime.now().toUtc();
    final List<String> notes = <String>[];

    // ---- 1) DuckDuckGo HTML ----
    List<WebSearchResult> ddg = const <WebSearchResult>[];
    try {
      final Uri uri = Uri.parse(duckDuckGoBaseUrl)
          .replace(path: '/html/', queryParameters: <String, String>{'q': q});
      final String html = await _get(uri);
      ddg = _dedupe(_parseDuckDuckGo(html, fetchedAt));
      if (ddg.isEmpty) notes.add('DuckDuckGo 返回 0 条可解析结果');
    } on Object catch (e) {
      notes.add('DuckDuckGo 请求失败（${_briefError(e)}）');
    }
    if (ddg.isNotEmpty) {
      final List<WebSearchResult> results =
          ddg.take(cap).toList(growable: false);
      return <String, dynamic>{
        'ok': true,
        'query': q,
        'results': results.map((WebSearchResult r) => r.toJson()).toList(),
        'provider': 'duckduckgo',
        'degraded': false,
        'note': '结果来自 DuckDuckGo HTML 搜索的真实网页解析'
            '${results.length < cap ? '，仅解析到 ${results.length} 条' : ''}。',
      };
    }

    // ---- 2) 中文维基百科 API 回退 ----
    List<WebSearchResult> wiki = const <WebSearchResult>[];
    try {
      final Uri uri = Uri.parse(wikipediaBaseUrl).replace(
        path: '/w/api.php',
        queryParameters: <String, String>{
          'action': 'query',
          'list': 'search',
          'srsearch': q,
          'format': 'json',
          'utf8': '1',
          'srlimit': '$cap',
        },
      );
      final String body = await _get(uri);
      wiki = _dedupe(_parseWikipedia(body, fetchedAt));
      if (wiki.isEmpty) notes.add('中文维基百科返回 0 条结果');
    } on Object catch (e) {
      notes.add('中文维基百科请求失败（${_briefError(e)}）');
    }
    if (wiki.isNotEmpty) {
      final List<WebSearchResult> results =
          wiki.take(cap).toList(growable: false);
      return <String, dynamic>{
        'ok': true,
        'query': q,
        'results': results.map((WebSearchResult r) => r.toJson()).toList(),
        'provider': 'wikipedia',
        'degraded': true,
        'note': '已降级到中文维基百科：${notes.join('；')}'
            '${results.length < cap ? '；仅取到 ${results.length} 条' : ''}。',
      };
    }

    // ---- 3) 全部失败：如实返回空，不编造来源 ----
    return <String, dynamic>{
      'ok': false,
      'query': q,
      'error': notes.isEmpty
          ? '联网搜索失败：DuckDuckGo 与中文维基百科均未返回结果'
          : '联网搜索失败：${notes.join('；')}',
    };
  }

  Future<String> _get(Uri uri) {
    final HttpGetFn? fn = _httpGet;
    if (fn != null) return fn(uri);
    return _defaultHttpGet(uri);
  }

  Future<String> _defaultHttpGet(Uri uri) async {
    final HttpClient client = HttpClient()..connectionTimeout = timeout;
    try {
      final HttpClientRequest req =
          await client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      req.headers.set(HttpHeaders.acceptHeader,
          'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8');
      req.headers.set(HttpHeaders.acceptLanguageHeader,
          'zh-CN,zh;q=0.9,en;q=0.8');
      final HttpClientResponse resp = await req.close().timeout(timeout);
      final String body = await resp
          .transform(const Utf8Decoder(allowMalformed: true))
          .join()
          .timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}', uri: uri);
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  // ---------------------------------------------------------------------------
  // DuckDuckGo HTML 解析
  // ---------------------------------------------------------------------------

  List<WebSearchResult> _parseDuckDuckGo(String html, DateTime fetchedAt) {
    final List<_Element> elements = _elements(html);
    final List<_DdgEntry> entries = <_DdgEntry>[];
    for (final _Element el in elements) {
      final String cls = (_attrValue(el.attrs, 'class') ?? '').toLowerCase();
      if (cls.contains('result__a')) {
        final String href = _attrValue(el.attrs, 'href') ?? '';
        entries.add(_DdgEntry(
          title: _stripHtml(el.inner),
          url: _resolveResultUrl(href),
        ));
      } else if (cls.contains('result__snippet') && entries.isNotEmpty) {
        if (entries.last.snippet.isEmpty) {
          entries.last.snippet = _stripHtml(el.inner);
        }
      }
    }
    final List<WebSearchResult> out = <WebSearchResult>[];
    for (final _DdgEntry e in entries) {
      if (e.title.isEmpty || e.url.isEmpty) continue;
      out.add(WebSearchResult(
        title: e.title,
        url: e.url,
        snippet: e.snippet,
        source: 'duckduckgo',
        fetchedAt: fetchedAt,
      ));
    }
    return out;
  }

  /// 把 DuckDuckGo 的跳转链接还原成真实地址；非 http(s) 一律丢弃。
  String _resolveResultUrl(String href) {
    String h = _decodeEntities(href).trim();
    if (h.isEmpty) return '';
    if (h.startsWith('//')) h = 'https:$h';
    final Uri? uri = Uri.tryParse(h);
    if (uri == null) return '';
    final String host = uri.host.toLowerCase();
    final bool ddgHost = host.isEmpty || host.endsWith('duckduckgo.com');
    if (ddgHost &&
        (uri.path == '/l/' || uri.path == '/l') &&
        uri.queryParameters.containsKey('uddg')) {
      final String target = (uri.queryParameters['uddg'] ?? '').trim();
      if (target.isEmpty) return '';
      final Uri? targetUri = Uri.tryParse(target);
      if (targetUri == null) return '';
      if (targetUri.scheme != 'http' && targetUri.scheme != 'https') return '';
      return targetUri.toString();
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') return '';
    return uri.toString();
  }

  // ---------------------------------------------------------------------------
  // 维基百科 API 解析
  // ---------------------------------------------------------------------------

  List<WebSearchResult> _parseWikipedia(String body, DateTime fetchedAt) {
    final Object? decoded = jsonDecode(body);
    if (decoded is! Map) return const <WebSearchResult>[];
    final Object? query = decoded['query'];
    if (query is! Map) return const <WebSearchResult>[];
    final Object? search = query['search'];
    if (search is! List) return const <WebSearchResult>[];
    final List<WebSearchResult> out = <WebSearchResult>[];
    for (final Object? item in search) {
      if (item is! Map) continue;
      final String title = (item['title'] ?? '').toString().trim();
      if (title.isEmpty) continue;
      final String slug = title.replaceAll(' ', '_');
      out.add(WebSearchResult(
        title: title,
        url: '$wikipediaBaseUrl/wiki/${Uri.encodeComponent(slug)}',
        snippet: _stripHtml((item['snippet'] ?? '').toString()),
        source: 'wikipedia',
        fetchedAt: fetchedAt,
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 容错解析工具
  // ---------------------------------------------------------------------------

  /// 扫描所有 `<tag attrs>inner</tag>` 元素（支持任意标签、大小写、跨行）。
  /// 只提取 `<a ...>...</a>`：详情页结果都是锚点；若用通用标签正则，
  /// 外层 div 会先吞掉内部锚点，导致一个结果都解析不到。
  List<_Element> _elements(String html) {
    final RegExp re = RegExp(
      r'<a\b([^>]*)>(.*?)</a\s*>',
      dotAll: true,
      caseSensitive: false,
    );
    final List<_Element> out = <_Element>[];
    for (final RegExpMatch m in re.allMatches(html)) {
      out.add(_Element(
        attrs: m.group(1) ?? '',
        inner: m.group(2) ?? '',
      ));
    }
    return out;
  }

  /// 读取属性值，兼容双引号 / 单引号 / 无引号。
  String? _attrValue(String attrs, String name) {
    final RegExp re = RegExp(
      r'\b' + RegExp.escape(name) +
          r'''\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''',
      caseSensitive: false,
    );
    final RegExpMatch? m = re.firstMatch(attrs);
    if (m == null) return null;
    return m.group(1) ?? m.group(2) ?? m.group(3) ?? '';
  }

  String _stripHtml(String source) {
    if (source.isEmpty) return '';
    final String withoutTags =
        source.replaceAll(RegExp(r'<[^>]*>', dotAll: true), '');
    return _decodeEntities(withoutTags)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _decodeEntities(String source) {
    const Map<String, String> named = <String, String>{
      'amp': '&',
      'lt': '<',
      'gt': '>',
      'quot': '"',
      'apos': "'",
      'nbsp': ' ',
      '#39': "'",
    };
    return source.replaceAllMapped(
      RegExp(r'&(#[xX]?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);'),
      (Match m) {
        final String key = m.group(1) ?? '';
        if (key.startsWith('#x') || key.startsWith('#X')) {
          final int? code = int.tryParse(key.substring(2), radix: 16);
          return code == null ? m.group(0)! : String.fromCharCode(code);
        }
        if (key.startsWith('#')) {
          final int? code = int.tryParse(key.substring(1));
          return code == null ? m.group(0)! : String.fromCharCode(code);
        }
        return named[key] ?? m.group(0)!;
      },
    );
  }

  List<WebSearchResult> _dedupe(List<WebSearchResult> input) {
    final Set<String> seen = <String>{};
    final List<WebSearchResult> out = <WebSearchResult>[];
    for (final WebSearchResult r in input) {
      if (r.url.isEmpty) continue;
      if (!seen.add(r.url)) continue;
      out.add(r);
    }
    return out;
  }

  String _briefError(Object e) {
    final String text = e is TimeoutException ? '超时' : '$e';
    final String oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length > 120 ? '${oneLine.substring(0, 120)}…' : oneLine;
  }
}

class _Element {
  const _Element({required this.attrs, required this.inner});
  final String attrs;
  final String inner;
}

class _DdgEntry {
  _DdgEntry({required this.title, required this.url});
  final String title;
  final String url;
  String snippet = '';
}
