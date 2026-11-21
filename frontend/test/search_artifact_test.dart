/// 移动端搜索与产物测试：真实读写临时目录，不访问网络。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/artifacts.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/local_search.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  Future<void> writeJson(String rel, Object value) async {
    final File f = File('${root.path}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(value), flush: true);
  }

  Future<void> writeText(String rel, String value) async {
    final File f = File('${root.path}/$rel');
    await f.parent.create(recursive: true);
    await f.writeAsString(value, flush: true);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tangram_mobile_');
    await writeJson('turns.json', <String, dynamic>{
      'turns': <Map<String, dynamic>>[
        <String, dynamic>{
          'session_id': 's1',
          'role': 'user',
          'text': '帮我整理季度营收数据',
          'ts': 1760000000,
        },
        <String, dynamic>{
          'session_id': 's1',
          'role': 'assistant',
          'text': '已整理完成，请查看报告。',
          'ts': 1760000001,
        },
      ],
    });
    await writeJson('pages.json', <String, dynamic>{
      'pages': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'p1',
          'title': '季度报告',
          'current_version': 1,
          'visibility': 'private',
          'pinned': false,
          'bot_id': '',
          'created_at': '2026-11-01T00:00:00Z',
          'updated_at': '2026-11-02T00:00:00Z',
        },
      ],
    });
    await writeText(
      'pages/p1/v1.html',
      '<html><body><h1>季度营收增长 12%</h1></body></html>',
    );
    await writeJson('knowledge_base.json', <String, dynamic>{
      'libraries': <dynamic>[],
      'documents': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'd1', 'title': '产品手册'},
      ],
      'chunks': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'c1',
          'library_id': 'l1',
          'document_id': 'd1',
          'text': '安装步骤：先下载安装包，再运行安装程序。',
        },
      ],
    });
    await writeJson('calls.json', <String, dynamic>{
      'calls': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'call-1',
          'bot_name': '助手',
          'started_at': '2026-11-03T09:00:00Z',
          'ended_at': '2026-11-03T09:01:00Z',
          'duration_ms': 60000,
          'status': 'completed',
          'transcript': <Map<String, dynamic>>[
            <String, dynamic>{
              'speaker': 'user',
              'text': '预约明天的回访电话',
              'ts': '2026-11-03T09:00:01Z',
            },
          ],
        },
      ],
    });
    await writeJson('routines/routines.json', <String, dynamic>{
      'routines': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'r1',
          'name': '每日回访提醒',
          'prompt': '检查今天需要回访的客户',
          'timezone': 'UTC+8',
          'updated_at': '2026-11-04T00:00:00Z',
        },
      ],
    });
    await writeJson('workflows.json', <String, dynamic>{
      'workflows': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'w1',
          'name': '报表生成',
          'description': '生成季度报表并归档',
          'steps': <dynamic>[],
          'updated_at': '2026-11-05T00:00:00Z',
        },
      ],
    });
    await writeJson('integrations.json', <String, dynamic>{
      'integrations': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'int-1',
          'name': '季度知识服务',
          'kind': 'mcp',
          'url': 'https://example.com/mcp',
          'updated_at': '2026-11-06T00:00:00Z',
        },
      ],
    });
    await writeText('work/notes.txt', '工作产物：会议纪要');
    await writeText('computer/homes/pc/bots/b1/out.md', '# 输出\n内容');
    await writeText('computer/homes/pc/.browser-profiles/b1/cookies.json', '{}');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('全局搜索', () {
    test('跨对话 / 页面 / 知识库 / 通话 / Routine / 工作流 / 集成', () async {
      final LocalSearchService search = LocalSearchService(root);

      final Map<String, dynamic> quarter = await search.handle(
        'query',
        <String, dynamic>{'query': '季度'},
      );
      expect(quarter['ok'], isTrue);
      final Set<String> types = (quarter['results'] as List)
          .map((dynamic r) => '${(r as Map)['type']}')
          .toSet();
      expect(types, contains('chat'));
      expect(types, contains('page'));
      expect(types, contains('workflow'));
      expect(types, contains('integration'));

      final Map<String, dynamic> install = await search.handle(
        'query',
        <String, dynamic>{'query': '安装'},
      );
      expect((install['results'] as List).first['type'], 'knowledge');
      expect('${(install['results'] as List).first['snippet']}', contains('安装'));

      final Map<String, dynamic> callback = await search.handle(
        'query',
        <String, dynamic>{'query': '回访'},
      );
      final Set<String> callbackTypes = (callback['results'] as List)
          .map((dynamic r) => '${(r as Map)['type']}')
          .toSet();
      expect(callbackTypes, contains('call'));
      expect(callbackTypes, contains('routine'));

      final Map<String, dynamic> filtered = await search.handle(
        'query',
        <String, dynamic>{'query': '季度', 'types': <String>['page']},
      );
      expect((filtered['results'] as List).length, 1);
      expect((filtered['results'] as List).first['type'], 'page');
    });

    test('空关键字如实拒绝，大小写不敏感', () async {
      final LocalSearchService search = LocalSearchService(root);
      final Map<String, dynamic> empty =
          await search.handle('query', <String, dynamic>{});
      expect(empty['ok'], isFalse);
      await writeJson('turns.json', <String, dynamic>{
        'turns': <Map<String, dynamic>>[
          <String, dynamic>{
            'session_id': 's2',
            'role': 'assistant',
            'text': 'Tangram 全局搜索',
            'ts': 1760000010,
          },
        ],
      });
      final Map<String, dynamic> lower = await search.handle(
        'query',
        <String, dynamic>{'query': 'tangram'},
      );
      expect((lower['results'] as List).length, 1);
      expect((lower['results'] as List).first['type'], 'chat');
    });
  });

  group('本地产物', () {
    test('列出来源、读取文本、排除浏览器 profile', () async {
      final ArtifactService artifacts = ArtifactService(root);
      final Map<String, dynamic> list =
          await artifacts.handle('list', <String, dynamic>{});
      expect(list['ok'], isTrue);
      final List<dynamic> items = list['artifacts'] as List;
      final Set<String> ids =
          items.map((dynamic a) => '${(a as Map)['id']}').toSet();
      expect(ids, contains('work/notes.txt'));
      expect(ids, contains('pages/p1/v1.html'));
      expect(ids, contains('computer/homes/pc/bots/b1/out.md'));
      expect(ids.any((String id) => id.contains('.browser-profiles')), isFalse);
      expect((list['groups'] as Map)['work'], 1);

      final Map<String, dynamic> read = await artifacts.handle(
        'read',
        <String, dynamic>{'id': 'work/notes.txt'},
      );
      expect(read['ok'], isTrue);
      expect(read['text'], contains('会议纪要'));

      final Map<String, dynamic> escape = await artifacts.handle(
        'read',
        <String, dynamic>{'id': '../turns.json'},
      );
      expect(escape['ok'], isFalse);
      final Map<String, dynamic> outside = await artifacts.handle(
        'read',
        <String, dynamic>{'id': 'turns.json'},
      );
      expect(outside['ok'], isFalse);
      final Map<String, dynamic> profile = await artifacts.handle(
        'read',
        <String, dynamic>{
          'id': 'computer/homes/pc/.browser-profiles/b1/cookies.json',
        },
      );
      expect(profile['ok'], isFalse);
    });

    test('非 UTF-8 如实拒绝，删除真实生效', () async {
      final File bin = File('${root.path}/work/blob.bin');
      await bin.writeAsBytes(<int>[0xff, 0xfe, 0x00], flush: true);
      final ArtifactService artifacts = ArtifactService(root);
      final Map<String, dynamic> read = await artifacts.handle(
        'read',
        <String, dynamic>{'id': 'work/blob.bin'},
      );
      expect(read['ok'], isFalse);
      expect('${read['error']}', contains('UTF-8'));

      final Map<String, dynamic> removed = await artifacts.handle(
        'delete',
        <String, dynamic>{'id': 'work/notes.txt'},
      );
      expect(removed['ok'], isTrue);
      expect(await File('${root.path}/work/notes.txt').exists(), isFalse);
    });
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
        await Directory('${root.path}/$sub').create(recursive: true);
      }
      HarnessStore.overrideForTest(root);
      store = await HarnessStore.instance();
      backend = EmbeddedBackend.forTest(store);
    });

    tearDown(() async {
      await backend.dispose();
    });

    test('能力声明与搜索 / 产物控制域', () async {
      final reply =
          await backend.dispatch('capability_negotiation', <String, dynamic>{});
      final Map<String, dynamic> caps = reply.payload;
      expect((caps['control_domains'] as List).contains('search'), isTrue);
      expect((caps['control_domains'] as List).contains('artifact'), isTrue);
      expect(caps['search'], isNotNull);
      expect(caps['artifact'], isNotNull);
      final List<dynamic> tools = caps['tools'] as List;
      expect(tools, contains('search_all'));
      expect(tools, contains('artifact_list'));
      expect(tools, contains('artifact_read'));

      final reply2 = await backend.dispatch('search', <String, dynamic>{
        'action': 'query',
        'query': '会议',
      });
      expect(reply2.payload['ok'], isTrue);
      final reply3 =
          await backend.dispatch('artifact', <String, dynamic>{'action': 'list'});
      expect(reply3.payload['ok'], isTrue);
    });
  });
}
