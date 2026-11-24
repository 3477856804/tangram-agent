/// 分层记忆接线测试：控制域、事实库、共享作用域、开关与凭据拒绝。
///
/// 直接走 `EmbeddedBackend.dispatch` 与临时目录，不 mock 数据结构。

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
    tmp = await Directory.systemTemp.createTemp('tangram_memory_backend_');
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
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final reply = await backend.dispatch('memory', <String, dynamic>{
      'action': action,
      ...payload,
    });
    return reply.payload;
  }

  test('能力声明包含 memory 与记忆工具', () async {
    final reply =
        await backend.dispatch('capability_negotiation', <String, dynamic>{});
    final Map<String, dynamic> caps = reply.payload;
    expect((caps['control_domains'] as List).contains('memory'), isTrue);
    expect(caps['memory'], isNotNull);
    expect(caps['memory']['secret_rejected'], isTrue);
    final List<dynamic> tools = caps['tools'] as List;
    for (final String name in <String>[
      'memory_save',
      'memory_search',
      'memory_summary',
      'memory_forget',
    ]) {
      expect(tools, contains(name), reason: name);
    }
  });

  test('事实保存 / 搜索 / 共享作用域 / 删除', () async {
    final Map<String, dynamic> saved = await call('save', <String, dynamic>{
      'text': '用户偏好深色模式',
      'source': '手动',
      'tags': <String>['偏好', '界面'],
      'shared': true,
    });
    expect(saved['ok'], isTrue, reason: '${saved['error']}');
    final Map<dynamic, dynamic> fact = saved['fact'] as Map;
    expect(fact['scope'], 'shared');
    expect(fact['shared_by'], 'tangram');

    final Map<String, dynamic> found = await call('search', <String, dynamic>{
      'query': '深色',
    });
    expect(found['total'], 1);
    expect('${(found['facts'] as List).first['text']}', contains('深色'));

    final Map<String, dynamic> private1 = await call('save', <String, dynamic>{
      'text': '测试凭据 password=abc123456',
    });
    expect(private1['ok'], isFalse,
        reason: '凭据类内容必须被拒绝');

    final Map<String, dynamic> private2 = await call('save', <String, dynamic>{
      'text': '私有事实：喜欢喝乌龙茶',
    });
    expect(private2['ok'], isTrue);
    final Map<String, dynamic> sharedOnly = await call(
      'facts',
      <String, dynamic>{'scope': 'shared'},
    );
    expect(sharedOnly['total'], 1);
    final Map<String, dynamic> privateOnly = await call(
      'facts',
      <String, dynamic>{'scope': 'private'},
    );
    expect(privateOnly['total'], 1);

    final Map<String, dynamic> forgotten =
        await call('forget', <String, dynamic>{'query': '乌龙茶'});
    expect(forgotten['ok'], isTrue);
    expect(forgotten['deleted'], 1);
    expect((await call('facts'))['total'], 1);
  });

  test('开关真实影响保存与会话要点', () async {
    await call('remember', <String, dynamic>{'enabled': false});
    final Map<String, dynamic> blocked =
        await call('save', <String, dynamic>{'text': '关闭时不应写入'});
    expect(blocked['ok'], isFalse);
    expect('${blocked['error']}', contains('已关闭'));

    await call('remember', <String, dynamic>{'enabled': true});
    expect(
      (await call('save', <String, dynamic>{'text': '重新开启后可写入'}))['ok'],
      isTrue,
    );

    await call('learn', <String, dynamic>{'enabled': false});
    expect(
      await backend.memory.learnTurn('s1', 'user', '不应学习'),
      isFalse,
    );
    await call('learn', <String, dynamic>{'enabled': true});
    expect(await backend.memory.learnTurn('s1', 'user', '我喜欢简洁的界面'),
        isTrue);
    expect(await backend.memory.learnTurn('s1', 'assistant', '已记下'),
        isTrue);

    final Map<String, dynamic> summary =
        await call('summary', <String, dynamic>{'session': 's1'});
    expect(summary['count'], 2);
    expect((summary['points'] as List).first, contains('简洁'));

    final Map<String, dynamic> cleared =
        await call('clear_summary', <String, dynamic>{'session': 's1'});
    expect(cleared['cleared'], isTrue);
    expect((await call('summary', <String, dynamic>{'session': 's1'}))['count'],
        0);
  });

  test('状态返回真实计数与落盘路径', () async {
    await call('save', <String, dynamic>{'text': '一条事实'});
    await backend.memory.learnTurn('s2', 'user', '一个要点');
    final Map<String, dynamic> status = await call('status');
    expect(status['ok'], isTrue);
    expect(status['facts'], 1);
    expect(status['sessions'], 1);
    expect(status['points'], 1);
    expect('${status['path']}', contains('memory_layers.json'));
    expect(await File('${tmp.path}/memory_layers.json').exists(), isTrue);
  });
}
