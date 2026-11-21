/// Integrations 测试：MCP / OpenAPI / GraphQL 的真实请求与凭据隔离。
///
/// 全部走 `package:http/testing.dart` 的 MockClient，不访问外网；
/// 断言包含「凭据不落 integrations.json」「工具缓存」「真实请求参数」。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/integration_registry.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late MemorySecretVault vault;
  late List<http.Request> requests;

  MockClient mock() => MockClient((http.Request req) async {
        requests.add(req);
        final String path = req.url.path;
        if (path == '/mcp') {
          final dynamic body = jsonDecode(req.body);
          final String method = body is Map ? '${body['method'] ?? ''}' : '';
          if (method == 'initialize') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': <String, dynamic>{
                  'protocolVersion': '2024-11-05',
                  'serverInfo': <String, dynamic>{'name': 'Demo MCP'},
                  'capabilities': <String, dynamic>{},
                },
              }),
              200,
              headers: <String, String>{
                'content-type': 'application/json',
                'mcp-session-id': 'sess-1',
              },
            );
          }
          if (method == 'tools/list') {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': <String, dynamic>{
                  'tools': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'name': 'echo',
                      'description': '回显文本',
                      'inputSchema': <String, dynamic>{
                        'type': 'object',
                        'properties': <String, dynamic>{
                          'text': <String, dynamic>{'type': 'string'},
                        },
                      },
                    },
                  ],
                },
              }),
              200,
              headers: <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          if (method == 'tools/call') {
            final Map<dynamic, dynamic> params = body['params'] as Map;
            final Map<dynamic, dynamic> args = params['arguments'] as Map;
            return http.Response(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': body['id'],
                'result': <String, dynamic>{
                  'content': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'type': 'text',
                      'text': 'echo:${args['text']}',
                    },
                  ],
                },
              }),
              200,
              headers: <String, String>{
                'content-type': 'application/json',
              },
            );
          }
          return http.Response('{}', 200,
              headers: <String, String>{'content-type': 'application/json'});
        }
        if (path == '/openapi.json') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'openapi': '3.0.0',
              'servers': <Map<String, dynamic>>[
                <String, dynamic>{'url': 'https://api.example.com/v1'},
              ],
              'paths': <String, dynamic>{
                '/items/{id}': <String, dynamic>{
                  'get': <String, dynamic>{
                    'operationId': 'getItem',
                    'summary': '读取条目',
                    'parameters': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'name': 'id',
                        'in': 'path',
                        'required': true,
                        'schema': <String, dynamic>{'type': 'integer'},
                      },
                      <String, dynamic>{
                        'name': 'expand',
                        'in': 'query',
                        'schema': <String, dynamic>{'type': 'string'},
                      },
                    ],
                  },
                },
                '/items': <String, dynamic>{
                  'post': <String, dynamic>{
                    'operationId': 'createItem',
                    'summary': '创建条目',
                    'requestBody': <String, dynamic>{
                      'required': true,
                      'content': <String, dynamic>{},
                    },
                  },
                },
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        if (path == '/v1/items/42') {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'id': 42,
              'expand': req.url.queryParameters['expand'],
              'auth': req.headers['authorization'],
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        if (path == '/v1/items') {
          return http.Response(
            jsonEncode(<String, dynamic>{'created': jsonDecode(req.body)}),
            201,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        if (path == '/graphql') {
          final Map<String, dynamic> body =
              jsonDecode(req.body) as Map<String, dynamic>;
          final String query = '${body['query'] ?? ''}';
          if (query.contains('__schema')) {
            return http.Response(
              jsonEncode(<String, dynamic>{
                'data': <String, dynamic>{
                  '__schema': <String, dynamic>{
                    'queryType': <String, dynamic>{
                      'fields': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'name': 'hello',
                          'description': '打招呼',
                          'args': <dynamic>[],
                        },
                      ],
                    },
                    'mutationType': null,
                  },
                },
              }),
              200,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(<String, dynamic>{
              'data': <String, dynamic>{
                'echo': <String, dynamic>{
                  'query': query,
                  'variables': body['variables'],
                },
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404,
            headers: <String, String>{'content-type': 'text/plain'});
      });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_integration_');
    vault = MemorySecretVault();
    requests = <http.Request>[];
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('MCP：真实握手、工具缓存、调用与凭据不落盘', () async {
    final IntegrationRegistry registry =
        IntegrationRegistry(tmp, vault: vault, client: mock());
    final Map<String, dynamic> added = await registry.handle(
      'add',
      <String, dynamic>{
        'name': '演示 MCP',
        'kind': 'mcp',
        'url': 'https://api.example.com/mcp',
        'auth_type': 'bearer',
        'token': 'sekret-token',
      },
    );
    expect(added['ok'], isTrue, reason: '${added['error']}');
    expect(added['tested'], isTrue);
    final Map<dynamic, dynamic> item = added['integration'] as Map;
    final String id = '${item['id']}';
    expect(item['has_secret'], isTrue);
    expect((item['tools'] as List).first['name'], 'echo');

    final File cfg = File('${tmp.path}/integrations.json');
    final String raw = await cfg.readAsString();
    expect(raw.contains('sekret-token'), isFalse,
        reason: '凭据不得写入集成配置');
    expect(await vault.read('integration.$id.token'), 'sekret-token');

    final Map<String, dynamic> call = await registry.handle(
      'call',
      <String, dynamic>{
        'id': id,
        'tool': 'echo',
        'arguments': <String, dynamic>{'text': 'hi'},
      },
    );
    expect(call['ok'], isTrue, reason: '${call['error']}');
    expect(call['text'], 'echo:hi');
    final http.Request toolReq =
        requests.lastWhere((http.Request r) => r.body.contains('tools/call'));
    expect(toolReq.headers['authorization'], 'Bearer sekret-token');
    registry.dispose();
  });

  test('OpenAPI：解析操作、路径参数、查询参数与 Bearer', () async {
    final IntegrationRegistry registry =
        IntegrationRegistry(tmp, vault: vault, client: mock());
    final Map<String, dynamic> added = await registry.handle(
      'add',
      <String, dynamic>{
        'name': '演示 OpenAPI',
        'kind': 'openapi',
        'url': 'https://api.example.com/openapi.json',
        'auth_type': 'bearer',
        'token': 'api-token',
      },
    );
    expect(added['ok'], isTrue, reason: '${added['error']}');
    expect(added['tested'], isTrue);
    final Map<dynamic, dynamic> item = added['integration'] as Map;
    final String id = '${item['id']}';
    final List<dynamic> tools = item['tools'] as List;
    expect(tools.map((dynamic t) => t['name']), contains('getItem'));
    expect(tools.map((dynamic t) => t['name']), contains('createItem'));

    final Map<String, dynamic> got = await registry.handle(
      'call',
      <String, dynamic>{
        'id': id,
        'tool': 'getItem',
        'arguments': <String, dynamic>{'id': 42, 'expand': 'detail'},
      },
    );
    expect(got['ok'], isTrue, reason: '${got['error']}');
    expect(got['text'], contains('"id":42'));
    expect(got['text'], contains('detail'));
    expect(got['text'], contains('Bearer api-token'));

    final Map<String, dynamic> created = await registry.handle(
      'call',
      <String, dynamic>{
        'id': id,
        'tool': 'createItem',
        'arguments': <String, dynamic>{
          'body': <String, dynamic>{'name': '新条目'},
        },
      },
    );
    expect(created['ok'], isTrue, reason: '${created['error']}');
    expect(created['status'], 201);
    expect(created['text'], contains('新条目'));
    registry.dispose();
  });

  test('GraphQL：introspection 发现字段并按 query 调用', () async {
    final IntegrationRegistry registry =
        IntegrationRegistry(tmp, vault: vault, client: mock());
    final Map<String, dynamic> added = await registry.handle(
      'add',
      <String, dynamic>{
        'name': '演示 GraphQL',
        'kind': 'graphql',
        'url': 'https://api.example.com/graphql',
        'auth_type': 'header',
        'header_name': 'X-Key',
        'token': 'gql-token',
      },
    );
    expect(added['ok'], isTrue, reason: '${added['error']}');
    final Map<dynamic, dynamic> item = added['integration'] as Map;
    final String id = '${item['id']}';
    expect((item['tools'] as List).first['name'], 'hello');

    final Map<String, dynamic> call = await registry.handle(
      'call',
      <String, dynamic>{
        'id': id,
        'tool': 'hello',
        'arguments': <String, dynamic>{
          'query': 'query { hello }',
          'variables': <String, dynamic>{'a': 1},
        },
      },
    );
    expect(call['ok'], isTrue, reason: '${call['error']}');
    expect(call['text'], contains('hello'));
    final http.Request req = requests.lastWhere(
      (http.Request r) => r.url.path == '/graphql' && r.body.contains('query {'),
    );
    expect(req.headers['x-key'], 'gql-token');
    registry.dispose();
  });

  test('连接失败如实返回，更新凭据与删除真实生效', () async {
    final IntegrationRegistry registry =
        IntegrationRegistry(tmp, vault: vault, client: mock());
    final Map<String, dynamic> added = await registry.handle(
      'add',
      <String, dynamic>{
        'name': '坏地址',
        'kind': 'mcp',
        'url': 'https://api.example.com/nope',
      },
    );
    expect(added['ok'], isTrue);
    expect(added['tested'], isFalse);
    expect('${added['error']}', isNotEmpty);
    final String id = '${(added['integration'] as Map)['id']}';

    final Map<String, dynamic> updated = await registry.handle(
      'update',
      <String, dynamic>{
        'id': id,
        'name': '改好地址',
        'kind': 'mcp',
        'url': 'https://api.example.com/mcp',
        'auth_type': 'bearer',
        'token': 'new-token',
      },
    );
    expect(updated['ok'], isTrue);
    expect(updated['tested'], isTrue);
    expect(await vault.read('integration.$id.token'), 'new-token');

    final Map<String, dynamic> listed = await registry.handle(
      'list',
      <String, dynamic>{},
    );
    final Map<dynamic, dynamic> row = (listed['integrations'] as List).first as Map;
    expect(row['name'], '改好地址');
    expect(row.containsKey('token'), isFalse);

    final Map<String, dynamic> removed = await registry.handle(
      'delete',
      <String, dynamic>{'id': id},
    );
    expect(removed['ok'], isTrue);
    expect(await vault.read('integration.$id.token'), isNull);
    final Map<String, dynamic> logs =
        await registry.handle('logs', <String, dynamic>{});
    expect((logs['logs'] as List), isNotEmpty);
    registry.dispose();
  });

  group('内嵌后端接线', () {
    late HarnessStore store;
    late EmbeddedBackend backend;

    setUp(() async {
      for (final String sub in <String>[
        'models',
        'cards',
        'plugins',
        'work',
        'downloads',
        'sandbox',
      ]) {
        await Directory('${tmp.path}/$sub').create(recursive: true);
      }
      HarnessStore.overrideForTest(tmp);
      store = await HarnessStore.instance();
      backend = EmbeddedBackend.forTest(store);
    });

    tearDown(() async {
      await backend.dispose();
    });

    test('能力声明包含 integration 与工具', () async {
      final reply = await backend.dispatch(
        'capability_negotiation',
        <String, dynamic>{},
      );
      final Map<String, dynamic> caps = reply.payload;
      expect((caps['control_domains'] as List).contains('integration'), isTrue);
      expect(caps['integration'], isNotNull);
      expect(caps['integration']['oauth_supported'], isFalse);
      final List<dynamic> tools = caps['tools'] as List;
      for (final String name in <String>[
        'integration_list',
        'integration_tools',
        'integration_call',
        'integration_test',
        'integration_add',
      ]) {
        expect(tools, contains(name), reason: name);
      }
      final reply2 = await backend.dispatch(
        'integration',
        <String, dynamic>{'action': 'list'},
      );
      expect(reply2.payload['ok'], isTrue);
      expect(reply2.payload['integrations'], isEmpty);
    });
  });
}
