/// distill traces 真实分页与筛选测试。
///
/// 全部数据经 HarnessStore 真实落盘，再走 EmbeddedBackend.dispatch，
/// 不做任何 mock 响应。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;
  late EmbeddedBackend backend;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_traces_paging_test_');
    for (final sub in <String>['models', 'cards', 'plugins', 'work',
        'downloads', 'sandbox']) {
      await Directory('${tmp.path}/$sub').create(recursive: true);
    }
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
    backend = EmbeddedBackend.forTest(store);

    // 5 条真实记录，ts 乱序写入，用于验证倒序与切片。
    final List<Map<String, dynamic>> records = <Map<String, dynamic>>[
      <String, dynamic>{
        'kind': 'work', 'task': 'Alpha 任务', 'ts': 300, 'source': 'manual',
      },
      <String, dynamic>{
        'kind': 'chat', 'text': 'beta question', 'reply': 'Gamma answer',
        'ts': 100, 'engine': 'builtin',
      },
      <String, dynamic>{
        'kind': 'work', 'task': '项目 Project 上线', 'ts': 500,
        'source': 'Manual',
      },
      <String, dynamic>{
        'kind': 'work', 'task': 'other', 'ts': 200, 'source': 'import',
      },
      <String, dynamic>{
        'kind': 'chat', 'text': 'zeta', 'reply': 'eta', 'ts': 400,
        'engine': 'builtin',
      },
    ];
    for (final Map<String, dynamic> r in records) {
      await store.insert('work_traces', r);
    }
  });

  tearDown(() async {
    await backend.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> traces(
      [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final reply = await backend.dispatch('distill', <String, dynamic>{
      'action': 'traces',
      ...payload,
    });
    return reply.payload;
  }

  List<int> tsOf(Map<String, dynamic> payload) => (payload['data'] as List)
      .map((dynamic r) => ((r as Map)['ts'] as num).toInt())
      .toList();

  group('distill traces 分页与筛选', () {
    test('默认返回倒序前 100 条，total 为真实总数', () async {
      final Map<String, dynamic> r = await traces();
      expect(r['ok'], true);
      expect(r['action'], 'traces');
      expect(r['data'], isA<List>());
      expect(r['total'], 5);
      expect(r['limit'], 100);
      expect(r['offset'], 0);
      expect(tsOf(r), <int>[500, 400, 300, 200, 100]);
    });

    test('limit=2&offset=1 切片正确', () async {
      final Map<String, dynamic> r =
          await traces(<String, dynamic>{'limit': 2, 'offset': 1});
      expect(r['total'], 5);
      expect(r['limit'], 2);
      expect(r['offset'], 1);
      expect(tsOf(r), <int>[400, 300]);
    });

    test('offset 为负数按 0 处理', () async {
      final Map<String, dynamic> r =
          await traces(<String, dynamic>{'limit': 2, 'offset': -3});
      expect(r['offset'], 0);
      expect(tsOf(r), <int>[500, 400]);
    });

    test('query 对 task/text/reply/source 大小写不敏感匹配', () async {
      final Map<String, dynamic> byTask =
          await traces(<String, dynamic>{'query': 'project'});
      expect(byTask['total'], 1);
      expect(tsOf(byTask), <int>[500]);

      final Map<String, dynamic> byReply =
          await traces(<String, dynamic>{'query': 'GAMMA'});
      expect(byReply['total'], 1);
      expect(tsOf(byReply), <int>[100]);

      final Map<String, dynamic> bySource =
          await traces(<String, dynamic>{'query': 'IMPORT'});
      expect(bySource['total'], 1);
      expect(tsOf(bySource), <int>[200]);

      final Map<String, dynamic> none =
          await traces(<String, dynamic>{'query': '不存在的关键词'});
      expect(none['ok'], true);
      expect(none['total'], 0);
      expect(none['data'], isEmpty);
    });

    test('since 过滤 ts >= since', () async {
      final Map<String, dynamic> r =
          await traces(<String, dynamic>{'since': 300});
      expect(r['total'], 3);
      expect(tsOf(r), <int>[500, 400, 300]);
    });

    test('query 与分页组合：total 为过滤后总数', () async {
      final Map<String, dynamic> r = await traces(<String, dynamic>{
        'query': 'builtin', 'limit': 1, 'offset': 1,
      });
      expect(r['total'], 0); // engine 不在匹配字段内，命中空集
      expect(r['data'], isEmpty);

      final Map<String, dynamic> chat = await traces(<String, dynamic>{
        'query': 'question', 'limit': 1, 'offset': 0,
      });
      expect(chat['total'], 1);
      expect(tsOf(chat), <int>[100]);
    });
  });
}
