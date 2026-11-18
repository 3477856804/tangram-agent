import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/web_search.dart';

/// 全部用例只用本地 HttpServer 模拟，绝不访问公网。
void main() {
  setUpAll(() {
    // flutter_test 会安装屏蔽真实网络的 HttpOverrides；这里显式还原，
    // 让 dart:io HttpClient 能连本地回环端口（仍然不会发往公网）。
    HttpOverrides.global = null;
  });

  late HttpServer server;
  late String base;
  Future<void> Function(HttpRequest request)? onDdg;
  Future<void> Function(HttpRequest request)? onWiki;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    onDdg = null;
    onWiki = null;
    server.listen((HttpRequest request) async {
      try {
        if (request.uri.path == '/html/') {
          final handler = onDdg;
          if (handler != null) return await handler(request);
        } else if (request.uri.path == '/w/api.php') {
          final handler = onWiki;
          if (handler != null) return await handler(request);
        }
        await _write(request, 'not found', status: 404);
      } on Object {
        // 测试服务器容错：客户端提前断开等异常不影响断言。
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  WebSearchService service({HttpGetFn? httpGet}) => WebSearchService(
        httpGet: httpGet,
        duckDuckGoBaseUrl: base,
        wikipediaBaseUrl: base,
      );

  test('DDG 正常解析、跳转链接解码、HTML 标签与实体清洗', () async {
    String? seenQuery;
    onDdg = (HttpRequest request) async {
      seenQuery = request.uri.queryParameters['q'];
      await _write(
        request,
        _ddgPage(<String>[
          _ddgResult(
            title: '示例 <b>标题</b> A',
            href: '//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com'
                '%2Fa%3Fb%3D1&amp;rut=abc',
            snippet: '这是 <b>摘要</b> A &amp; 更多',
          ),
          _ddgResult(
            title: '示例 B',
            href: 'https://example.org/b',
            snippet: 'B 摘要',
          ),
        ]),
      );
    };

    final Map<String, dynamic> r = await service().search('dart 异步');

    expect(r['ok'], true);
    expect(r['provider'], 'duckduckgo');
    expect(r['degraded'], false);
    expect(seenQuery, 'dart 异步');
    final List<dynamic> results = r['results'] as List<dynamic>;
    expect(results.length, 2);
    expect(results[0]['url'], 'https://example.com/a?b=1');
    expect(results[0]['title'], '示例 标题 A');
    expect(results[0]['snippet'], '这是 摘要 A & 更多');
    expect(results[0]['source'], 'duckduckgo');
    expect(results[1]['url'], 'https://example.org/b');
  });

  test('按 url 去重且按 limit 截断', () async {
    onDdg = (HttpRequest request) async {
      await _write(
        request,
        _ddgPage(<String>[
          _ddgResult(
            title: 'A',
            href: 'https://example.com/a',
            snippet: 'a',
          ),
          _ddgResult(
            title: 'A 重复',
            href: 'https://example.com/a',
            snippet: 'dup',
          ),
          _ddgResult(title: 'B', href: 'https://example.com/b'),
          _ddgResult(title: 'C', href: 'https://example.com/c'),
        ]),
      );
    };

    final Map<String, dynamic> deduped = await service().search('x');
    expect((deduped['results'] as List<dynamic>).length, 3);

    final Map<String, dynamic> limited = await service().search('x', limit: 2);
    final List<dynamic> results = limited['results'] as List<dynamic>;
    expect(results.length, 2);
    expect(results[0]['url'], 'https://example.com/a');
    expect(results[1]['url'], 'https://example.com/b');
  });

  test('DDG 请求失败时回退中文维基百科并标记 degraded', () async {
    onDdg = (HttpRequest request) async {
      await _write(request, 'boom', status: 500);
    };
    String? seenSrsearch;
    onWiki = (HttpRequest request) async {
      seenSrsearch = request.uri.queryParameters['srsearch'];
      await _write(
        request,
        jsonEncode(<String, dynamic>{
          'query': <String, dynamic>{
            'search': <Map<String, dynamic>>[
              <String, dynamic>{
                'title': '人工智能',
                'snippet': '人工智能，<span class="searchmatch">机器学习</span>'
                    '分支 &quot;定义&quot;',
              },
            ],
          },
        }),
        contentType: 'application/json; charset=utf-8',
      );
    };

    final Map<String, dynamic> r = await service().search('人工智能');

    expect(r['ok'], true);
    expect(r['provider'], 'wikipedia');
    expect(r['degraded'], true);
    expect((r['note'] as String), contains('降级'));
    expect(seenSrsearch, '人工智能');
    final List<dynamic> results = r['results'] as List<dynamic>;
    expect(results.length, 1);
    expect(results[0]['title'], '人工智能');
    expect(results[0]['snippet'], '人工智能，机器学习分支 "定义"');
    expect(results[0]['source'], 'wikipedia');
    expect(
      results[0]['url'],
      '$base/wiki/${Uri.encodeComponent('人工智能')}',
    );
  });

  test('DDG 返回 0 条结果时同样回退维基百科', () async {
    onDdg = (HttpRequest request) async {
      await _write(request, '<html><body><div>没有匹配结果</div></body></html>');
    };
    onWiki = (HttpRequest request) async {
      await _write(
        request,
        jsonEncode(<String, dynamic>{
          'query': <String, dynamic>{
            'search': <Map<String, dynamic>>[
              <String, dynamic>{'title': 'Dart', 'snippet': '编程语言'},
            ],
          },
        }),
        contentType: 'application/json; charset=utf-8',
      );
    };

    final Map<String, dynamic> r = await service().search('Dart');
    expect(r['ok'], true);
    expect(r['provider'], 'wikipedia');
    expect(r['degraded'], true);
    expect((r['results'] as List<dynamic>).length, 1);
  });

  test('两个来源都失败时返回 ok:false 且不产生任何结果', () async {
    onDdg = (HttpRequest request) async {
      await _write(request, 'boom', status: 500);
    };
    onWiki = (HttpRequest request) async {
      await _write(request, 'unavailable', status: 503);
    };

    final Map<String, dynamic> r = await service().search('不存在的关键词');

    expect(r['ok'], false);
    expect((r['error'] as String), contains('联网搜索失败'));
    expect(r.containsKey('results'), false);
    expect(r.containsKey('provider'), false);
  });

  test('httpGet 注入抛错时同样如实失败，不伪造来源', () async {
    final WebSearchService failing = service(
      httpGet: (Uri uri) async => throw const SocketException('no network'),
    );

    final Map<String, dynamic> r = await failing.search('任意查询');

    expect(r['ok'], false);
    expect((r['error'] as String), contains('DuckDuckGo'));
    expect(r.containsKey('results'), false);
  });

  test('非 http(s) 链接被丢弃，不产生假来源', () async {
    onDdg = (HttpRequest request) async {
      await _write(
        request,
        _ddgPage(<String>[
          _ddgResult(
            title: '脚本链接',
            href: 'javascript:alert(1)',
            snippet: '不应出现',
          ),
          _ddgResult(
            title: 'FTP 链接',
            href: 'ftp://example.com/file',
            snippet: '不应出现',
          ),
        ]),
      );
    };
    onWiki = (HttpRequest request) async {
      await _write(
        request,
        jsonEncode(<String, dynamic>{
          'query': <String, dynamic>{'search': <dynamic>[]},
        }),
        contentType: 'application/json; charset=utf-8',
      );
    };

    final Map<String, dynamic> r = await service().search('坏链接');
    expect(r['ok'], false);
    expect(r.containsKey('results'), false);
  });

  test('空关键词直接返回 ok:false，不发请求', () async {
    final Map<String, dynamic> r = await service().search('   ');
    expect(r['ok'], false);
    expect((r['error'] as String), contains('为空'));
  });
}

String _ddgPage(List<String> blocks) =>
    '<!doctype html><html><body>${blocks.join('\n')}</body></html>';

String _ddgResult({
  required String title,
  required String href,
  String snippet = '',
}) =>
    '<div class="result results_links results_links_deep web-result">'
    '<h2 class="result__title">'
    '<a rel="nofollow" class="result__a" href="$href">$title</a>'
    '</h2>'
    '${snippet.isEmpty ? '' : '<a class="result__snippet" href="$href">$snippet</a>'}'
    '</div>';

Future<void> _write(
  HttpRequest request,
  String body, {
  int status = 200,
  String contentType = 'text/html; charset=utf-8',
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.parse(contentType);
  request.response.write(body);
  await request.response.close();
}
