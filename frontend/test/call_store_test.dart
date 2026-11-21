/// 通话记录测试：真实落盘、转写校验、统计与后端接线。
///
/// 不触发麦克风 / TTS（那两部分在 UI 层，分别由平台识别器与 Edge TTS 负责）；
/// 这里验证「通话结束后必须如实保存的转写」与能力声明。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/call_store.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late CallStore store;

  Map<String, dynamic> transcript() => <String, dynamic>{
        'transcript': <Map<String, dynamic>>[
          <String, dynamic>{
            'speaker': 'user',
            'text': '帮我看看今天的安排',
            'ts': '2026-11-21T09:00:00Z',
          },
          <String, dynamic>{
            'speaker': 'bot',
            'text': '今天有两场会议。',
            'ts': '2026-11-21T09:00:02Z',
          },
          <String, dynamic>{
            'speaker': 'unknown',
            'text': '应被忽略',
            'ts': '2026-11-21T09:00:03Z',
          },
          <String, dynamic>{
            'speaker': 'system',
            'text': '   ',
            'ts': '2026-11-21T09:00:04Z',
          },
        ],
      };

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_call_');
    store = CallStore(tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('保存通话：校验状态、时间与转写字段', () async {
    final Map<String, dynamic> saved = await store.handle('save', <String, dynamic>{
      'bot_name': '助手',
      'started_at': '2026-11-21T09:00:00.000Z',
      'ended_at': '2026-11-21T09:01:05.000Z',
      'status': 'completed',
      ...transcript(),
    });
    expect(saved['ok'], isTrue, reason: '${saved['error']}');
    final Map<dynamic, dynamic> call = saved['call'] as Map;
    expect(call['duration_ms'], 65000);
    final List<dynamic> entries = call['transcript'] as List;
    expect(entries.length, 2, reason: '未知说话人与空文本必须剔除');
    expect(entries.first['speaker'], 'user');
    expect(entries.last['speaker'], 'bot');

    final Map<String, dynamic> bad = await store.handle('save', <String, dynamic>{
      'bot_name': '助手',
      'status': 'unknown',
    });
    expect(bad['ok'], isFalse);

    final Map<String, dynamic> noName =
        await store.handle('save', <String, dynamic>{'bot_name': ''});
    expect(noName['ok'], isFalse);

    final Map<String, dynamic> badTime = await store.handle('save', <String, dynamic>{
      'bot_name': '助手',
      'started_at': '2026-11-21T09:10:00Z',
      'ended_at': '2026-11-21T09:00:00Z',
    });
    expect(badTime['ok'], isFalse);
  });

  test('列表 / 详情 / 搜索 / 删除 / 统计', () async {
    await store.handle('save', <String, dynamic>{
      'bot_name': '分析师',
      'started_at': '2026-11-21T08:00:00Z',
      'ended_at': '2026-11-21T08:01:00Z',
      ...transcript(),
    });
    final Map<String, dynamic> second =
        await store.handle('save', <String, dynamic>{
      'bot_name': '写作助手',
      'started_at': '2026-11-21T10:00:00Z',
      'ended_at': '2026-11-21T10:00:30Z',
      'status': 'missed',
    });

    final Map<String, dynamic> list =
        await store.handle('list', <String, dynamic>{});
    expect((list['calls'] as List).length, 2);
    expect((list['calls'] as List).first['bot_name'], '写作助手');

    final Map<String, dynamic> filtered =
        await store.handle('list', <String, dynamic>{'query': '安排'});
    expect((filtered['calls'] as List).length, 1);
    expect((filtered['calls'] as List).first['bot_name'], '分析师');

    final Map<String, dynamic> got = await store.handle(
      'get',
      <String, dynamic>{'id': '${(second['call'] as Map)['id']}'},
    );
    expect(got['ok'], isTrue);
    expect((got['call'] as Map)['status'], 'missed');

    final Map<String, dynamic> stats =
        await store.handle('stats', <String, dynamic>{});
    expect(stats['total'], 2);
    expect(stats['completed'], 1);
    expect(stats['missed'], 1);
    expect(stats['duration_ms'], 90000);

    final Map<String, dynamic> removed = await store.handle(
      'delete',
      <String, dynamic>{'id': '${(second['call'] as Map)['id']}'},
    );
    expect(removed['ok'], isTrue);
    expect((await store.handle('list', <String, dynamic>{}))['total'], 1);
    final Map<String, dynamic> missing =
        await store.handle('delete', <String, dynamic>{'id': 'nope'});
    expect(missing['ok'], isFalse);
  });

  test('超过上限时丢弃最旧记录', () async {
    for (int i = 0; i < CallStore.maxCalls + 3; i++) {
      await store.handle('save', <String, dynamic>{
        'bot_name': '助手',
        'started_at':
            DateTime(2026, 1, 1).add(Duration(minutes: i)).toIso8601String(),
        'ended_at':
            DateTime(2026, 1, 1).add(Duration(minutes: i, seconds: 10)).toIso8601String(),
      });
    }
    final Map<String, dynamic> list =
        await store.handle('list', <String, dynamic>{'limit': 100});
    expect((list['calls'] as List).length, CallStore.maxCalls);
    expect(list['total'], CallStore.maxCalls);
  });

  group('内嵌后端接线', () {
    late HarnessStore harness;
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
      harness = await HarnessStore.instance();
      backend = EmbeddedBackend.forTest(harness);
    });

    tearDown(() async {
      await backend.dispose();
    });

    test('能力声明包含 call 与 call_history 工具', () async {
      final reply =
          await backend.dispatch('capability_negotiation', <String, dynamic>{});
      final Map<String, dynamic> caps = reply.payload;
      expect((caps['control_domains'] as List).contains('call'), isTrue);
      expect(caps['call'], isNotNull);
      expect(caps['call']['bot_initiated'], isFalse);
      expect(caps['tools'] as List, contains('call_history'));
    });

    test('通过控制域保存并读回通话', () async {
      final reply = await backend.dispatch('call', <String, dynamic>{
        'action': 'save',
        'bot_name': '助手',
        'started_at': '2026-11-21T09:00:00Z',
        'ended_at': '2026-11-21T09:00:20Z',
        'transcript': <Map<String, dynamic>>[
          <String, dynamic>{
            'speaker': 'user',
            'text': '你好',
            'ts': '2026-11-21T09:00:01Z',
          },
        ],
      });
      expect(reply.payload['ok'], isTrue);
      final reply2 =
          await backend.dispatch('call', <String, dynamic>{'action': 'list'});
      final List<dynamic> calls = reply2.payload['calls'] as List;
      expect(calls.length, 1);
      expect(calls.first['entry_count'], 1);
    });
  });
}
