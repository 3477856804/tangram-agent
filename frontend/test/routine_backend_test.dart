/// Routine 控制域集成测试：能力声明、CRUD、到点查询与旧数据迁移。
///
/// 走真实 `EmbeddedBackend.dispatch` 与临时目录，不 mock 返回结构；
/// 不触发 chat 推理（运行链路由 RoutineStore 的单元测试覆盖）。

import 'dart:convert';
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
    tmp = await Directory.systemTemp.createTemp('tangram_routine_backend_');
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
    String topic, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final reply = await backend.dispatch(topic, payload);
    return reply.payload;
  }

  Future<Map<String, dynamic>> createRoutine({
    String name = '每日简报',
    List<String> crons = const <String>['0 9 * * *'],
    String timezone = 'UTC+8',
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) {
    return call('routine', <String, dynamic>{
      'action': 'create',
      'name': name,
      'prompt': '总结今天的消息',
      'crons': crons,
      'timezone': timezone,
      ...extra,
    });
  }

  test('能力声明包含 routine，且 Agent 工具已注册', () async {
    final Map<String, dynamic> caps =
        await call('capability_negotiation');
    expect(caps['ok'], isTrue);
    expect((caps['control_domains'] as List).contains('routine'), isTrue);
    expect(caps['routine'], isNotNull);
    final List<dynamic> tools = caps['tools'] as List;
    expect(tools, contains('routine_list'));
    expect(tools, contains('routine_create'));
    expect(tools, contains('routine_run'));
    expect(tools, contains('routine_history'));
  });

  test('创建 / 列表 / 更新 / 切换 / 复制 / 删除走真实控制域', () async {
    final Map<String, dynamic> created = await createRoutine();
    expect(created['ok'], isTrue, reason: '${created['error']}');
    final Map<dynamic, dynamic> routine = created['routine'] as Map;
    final String id = '${routine['id']}';

    final Map<String, dynamic> list = await call('routine', <String, dynamic>{
      'action': 'list',
    });
    expect((list['routines'] as List).length, 1);
    expect('${(list['routines'] as List).first['name']}', '每日简报');

    final Map<String, dynamic> updated =
        await call('routine', <String, dynamic>{
      'action': 'update',
      'id': id,
      'name': '改名后',
      'crons': <String>['*/20 * * * *'],
    });
    expect(updated['ok'], isTrue, reason: '${updated['error']}');
    expect('${(updated['routine'] as Map)['name']}', '改名后');

    final Map<String, dynamic> paused =
        await call('routine', <String, dynamic>{
      'action': 'toggle',
      'id': id,
      'enabled': false,
    });
    expect(paused['ok'], isTrue);
    expect((paused['routine'] as Map)['next_run_at'], isNull);

    final Map<String, dynamic> copied =
        await call('routine', <String, dynamic>{
      'action': 'duplicate',
      'id': id,
    });
    expect(copied['ok'], isTrue);
    expect((copied['routine'] as Map)['active'], isFalse);

    final Map<String, dynamic> deleted =
        await call('routine', <String, dynamic>{
      'action': 'delete',
      'id': id,
    });
    expect(deleted['ok'], isTrue);
    final Map<String, dynamic> after = await call('routine', <String, dynamic>{
      'action': 'list',
    });
    expect((after['routines'] as List).length, 1, reason: '只剩副本');
  });

  test('validate 返回下一次运行，非法 cron 如实报错', () async {
    final Map<String, dynamic> ok = await call('routine', <String, dynamic>{
      'action': 'validate',
      'crons': <String>['30 9 * * 1-5'],
      'timezone': 'Asia/Shanghai',
    });
    expect(ok['ok'], isTrue);
    expect(ok['next_run_at'], isNotNull);

    final Map<String, dynamic> bad = await call('routine', <String, dynamic>{
      'action': 'validate',
      'crons': <String>['99 * * * *'],
      'timezone': 'UTC',
    });
    expect(bad['ok'], isFalse);
    expect('${bad['error']}', contains('时间表无效'));
  });

  test('一次性 Routine 到点后出现在 due 列表', () async {
    final DateTime at = DateTime.now().toUtc().add(const Duration(hours: 1));
    final Map<String, dynamic> created = await createRoutine(
      name: '一次性提醒',
      crons: <String>['@once'],
      timezone: 'UTC',
      extra: <String, dynamic>{'once_at': at.toIso8601String()},
    );
    expect(created['ok'], isTrue, reason: '${created['error']}');
    final String id = '${(created['routine'] as Map)['id']}';
    final Map<String, dynamic> before = await call('routine', <String, dynamic>{
      'action': 'due',
    });
    expect((before['due'] as List), isEmpty);
    final Map<String, dynamic> after = await call('routine', <String, dynamic>{
      'action': 'due',
      'now': at.add(const Duration(minutes: 1)).toIso8601String(),
    });
    expect((after['due'] as List).length, 1);
    expect('${(after['due'] as List).first['id']}', id);
  });

  test('旧版 schedules.json 自动迁移为 Routine，只迁移一次', () async {
    await File('${tmp.path}/schedules.json').writeAsString(jsonEncode(<dynamic>[
      <String, dynamic>{
        'id': 1,
        'title': '旧每日任务',
        'prompt': '旧提示词',
        'cron': '08:30',
        'enabled': true,
      },
      <String, dynamic>{
        'id': 2,
        'title': '旧间隔任务',
        'prompt': '每 30 分钟',
        'cron': 'every:30',
        'enabled': false,
      },
      <String, dynamic>{
        'id': 3,
        'title': '无效表达式',
        'prompt': '不应导入',
        'cron': 'not-a-cron',
        'enabled': true,
      },
    ]));

    final Map<String, dynamic> first = await call('routine', <String, dynamic>{
      'action': 'list',
    });
    final List<dynamic> routines = first['routines'] as List;
    expect(routines.length, 2);
    expect(
      routines.map((dynamic r) => '${(r as Map)['name']}'),
      containsAll(<String>['旧每日任务', '旧间隔任务']),
    );
    expect(
      routines
          .map((dynamic r) => (r as Map)['crons'] as List)
          .expand((List e) => e)
          .toList(),
      containsAll(<String>['30 8 * * *', '*/30 * * * *']),
    );
    expect(
      File('${tmp.path}/schedules.json.migrated').existsSync(),
      isTrue,
    );

    // 再次 list 不会重复导入。
    final Map<String, dynamic> second = await call('routine', <String, dynamic>{
      'action': 'list',
    });
    expect((second['routines'] as List).length, 2);
  });

  test('不存在的 Routine 操作如实失败', () async {
    for (final String action in <String>['get', 'delete', 'toggle']) {
      final Map<String, dynamic> r = await call('routine', <String, dynamic>{
        'action': action,
        'id': 'missing',
        if (action == 'toggle') 'enabled': false,
      });
      expect(r['ok'], isFalse, reason: action);
    }
    final Map<String, dynamic> run = await call('routine', <String, dynamic>{
      'action': 'run',
      'id': 'missing',
    });
    expect(run['ok'], isFalse);
  });
}
