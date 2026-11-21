/// Routine 持久化仓储测试：真实落盘、校验、下次运行、运行历史与并发写。
///
/// 使用临时目录，不触碰 App 目录；全部断言真实 JSON 文件与返回结构。

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tangram/harness/routine_store.dart';

void main() {
  late Directory tmp;
  late RoutineStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_routine_');
    store = RoutineStore(tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> createDaily({
    String name = '每日简报',
    String prompt = '总结今天的消息',
    List<String> crons = const <String>['0 9 * * *'],
    String timezone = 'UTC+8',
    bool active = true,
  }) {
    return store.create(
      name: name,
      prompt: prompt,
      crons: crons,
      timezone: timezone,
      active: active,
    );
  }

  group('创建与校验', () {
    test('创建后真实写入 routines.json，并算出未来运行时间', () async {
      final Map<String, dynamic> r = await createDaily();
      expect(r['ok'], isTrue, reason: '${r['error']}');
      final Map<dynamic, dynamic> routine = r['routine'] as Map;
      final DateTime next =
          DateTime.parse('${routine['next_run_at']}');
      expect(next.isAfter(DateTime.now().toUtc()), isTrue);
      final File index = File('${tmp.path}/routines/routines.json');
      expect(index.existsSync(), isTrue);
      expect(index.readAsStringSync(), contains('每日简报'));
      expect(index.readAsStringSync(), contains('0 9 * * *'));
    });

    test('名称为空 / 过长 / 提示词为空都如实拒绝', () async {
      expect((await createDaily(name: '  '))['ok'], isFalse);
      expect(
        (await createDaily(name: '名' * 81))['ok'],
        isFalse,
      );
      expect((await createDaily(prompt: ' '))['ok'], isFalse);
    });

    test('非法 cron、空时间表、混用一次性都拒绝', () async {
      expect((await createDaily(crons: <String>[]))['ok'], isFalse);
      expect((await createDaily(crons: <String>['bad']))['ok'], isFalse);
      expect(
        (await createDaily(crons: <String>['@once', '0 9 * * *']))['ok'],
        isFalse,
      );
    });

    test('不支持的时区拒绝，不静默按 UTC 计算', () async {
      final Map<String, dynamic> r = await createDaily(
        timezone: 'America/New_York',
      );
      expect(r['ok'], isFalse);
      expect('${r['error']}', contains('时区'));
    });

    test('一次性 Routine 必须给出未来时刻', () async {
      final Map<String, dynamic> missing = await store.create(
        name: '提醒',
        prompt: '提醒我',
        crons: <String>['@once'],
        timezone: 'UTC',
      );
      expect(missing['ok'], isFalse);
      final Map<String, dynamic> past = await store.create(
        name: '提醒',
        prompt: '提醒我',
        crons: <String>['@once'],
        timezone: 'UTC',
        oneShotAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );
      expect(past['ok'], isFalse);
      final DateTime at =
          DateTime.now().toUtc().add(const Duration(minutes: 30));
      final Map<String, dynamic> ok = await store.create(
        name: '提醒',
        prompt: '提醒我',
        crons: <String>['@once'],
        timezone: 'UTC',
        oneShotAt: at,
      );
      expect(ok['ok'], isTrue);
      expect(
        DateTime.parse('${(ok['routine'] as Map)['next_run_at']}').toUtc(),
        at,
      );
    });
  });

  group('查询与更新', () {
    test('列表按启用与下次运行排序，并支持搜索', () async {
      await createDaily(name: '早报');
      await createDaily(name: '晚报', active: false);
      final Map<String, dynamic> all = await store.list();
      expect((all['routines'] as List).length, 2);
      final Map<String, dynamic> on =
          await store.list(activeOnly: true);
      expect((on['routines'] as List).length, 1);
      final Map<String, dynamic> search = await store.list(query: '晚');
      expect((search['routines'] as List).length, 1);
      expect('${(search['routines'] as List).first['name']}', '晚报');
    });

    test('只改名称不动下次运行；改时间表会重算', () async {
      final Map<String, dynamic> created = await createDaily();
      final Map<dynamic, dynamic> routine = created['routine'] as Map;
      final String id = '${routine['id']}';
      final String before = '${routine['next_run_at']}';
      final Map<String, dynamic> renamed =
          await store.update(id, name: '新名字');
      expect(renamed['ok'], isTrue);
      expect('${(renamed['routine'] as Map)['next_run_at']}', before);
      final Map<String, dynamic> changed = await store.update(
        id,
        crons: <String>['*/10 * * * *'],
      );
      expect(changed['ok'], isTrue);
      expect(
        '${(changed['routine'] as Map)['next_run_at']}',
        isNot(before),
      );
    });

    test('暂停清空 next_run，启用后重新计算', () async {
      final Map<dynamic, dynamic> routine =
          (await createDaily())['routine'] as Map;
      final String id = '${routine['id']}';
      final Map<String, dynamic> paused =
          await store.setActive(id, false);
      expect(paused['ok'], isTrue);
      expect((paused['routine'] as Map)['next_run_at'], isNull);
      final Map<String, dynamic> resumed =
          await store.setActive(id, true);
      expect(resumed['ok'], isTrue);
      expect((resumed['routine'] as Map)['next_run_at'], isNotNull);
    });

    test('复制得到暂停副本，一次性不可复制', () async {
      final Map<dynamic, dynamic> routine =
          (await createDaily())['routine'] as Map;
      final Map<String, dynamic> copy =
          await store.duplicate('${routine['id']}');
      expect(copy['ok'], isTrue);
      final Map<dynamic, dynamic> copied = copy['routine'] as Map;
      expect(copied['active'], isFalse);
      expect(copied['next_run_at'], isNull);
      expect('${copied['name']}', '每日简报 副本');
      expect(copied['id'], isNot(routine['id']));

      final Map<String, dynamic> once = await store.create(
        name: '一次性',
        prompt: '只跑一次',
        crons: <String>['@once'],
        timezone: 'UTC',
        oneShotAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      final Map<String, dynamic> rejected = await store.duplicate(
        '${(once['routine'] as Map)['id']}',
      );
      expect(rejected['ok'], isFalse);
    });

    test('删除同时移除运行历史', () async {
      final Map<dynamic, dynamic> routine =
          (await createDaily())['routine'] as Map;
      final String id = '${routine['id']}';
      final Map<String, dynamic> run =
          await store.startRun(id, trigger: 'manual');
      await store.finishRun('${(run['run'] as Map)['id']}', ok: true);
      final Map<String, dynamic> deleted = await store.delete(id);
      expect(deleted['ok'], isTrue);
      final Map<String, dynamic> history = await store.history(id);
      expect((history['runs'] as List), isEmpty);
      final Map<String, dynamic> missing = await store.get(id);
      expect(missing['ok'], isFalse);
    });

    test('新建实例能读回同一份数据', () async {
      await createDaily(name: '持久化');
      final RoutineStore reopened = RoutineStore(tmp);
      final Map<String, dynamic> list = await reopened.list();
      expect((list['routines'] as List).length, 1);
      expect('${(list['routines'] as List).first['name']}', '持久化');
    });
  });

  group('到期与运行记录', () {
    test('due 只返回到点且启用的 Routine', () async {
      final DateTime now = DateTime.now().toUtc();
      final Map<String, dynamic> created = await store.create(
        name: '到点提醒',
        prompt: '提醒',
        crons: <String>['@once'],
        timezone: 'UTC',
        oneShotAt: now.add(const Duration(minutes: 1)),
      );
      final String id = '${(created['routine'] as Map)['id']}';
      final Map<String, dynamic> before =
          await store.due(now: now);
      expect((before['due'] as List), isEmpty);
      final Map<String, dynamic> after =
          await store.due(now: now.add(const Duration(minutes: 2)));
      expect((after['due'] as List).length, 1);
      expect('${(after['due'] as List).first['id']}', id);
      await store.setActive(id, false);
      final Map<String, dynamic> paused = await store.due(
        now: now.add(const Duration(minutes: 3)),
      );
      expect((paused['due'] as List), isEmpty);
    });

    test('一次性运行后自动停用，记录耗时与成功状态', () async {
      final DateTime at =
          DateTime.now().toUtc().add(const Duration(minutes: 10));
      final Map<String, dynamic> created = await store.create(
        name: '一次性',
        prompt: '执行',
        crons: <String>['@once'],
        timezone: 'UTC',
        oneShotAt: at,
      );
      final String id = '${(created['routine'] as Map)['id']}';
      final Map<String, dynamic> started =
          await store.startRun(id, trigger: 'schedule');
      expect(started['ok'], isTrue);
      final Map<dynamic, dynamic> routine = started['routine'] as Map;
      expect(routine['active'], isFalse);
      expect(routine['next_run_at'], isNull);
      final String runId = '${(started['run'] as Map)['id']}';
      final Map<String, dynamic> finished = await store.finishRun(
        runId,
        ok: true,
        result: '完成',
      );
      expect(finished['ok'], isTrue);
      final Map<dynamic, dynamic> run = finished['run'] as Map;
      expect(run['status'], 'success');
      expect(run['completed_at'], isNotNull);
      final Map<String, dynamic> history =
          await store.historyDetailed(id);
      final List<dynamic> runs = history['runs'] as List;
      expect(runs.length, 1);
      expect((runs.first as Map)['duration_label'], isNotNull);
    });

    test('运行历史按时间倒序并分页', () async {
      final Map<dynamic, dynamic> routine =
          (await createDaily())['routine'] as Map;
      final String id = '${routine['id']}';
      for (int i = 0; i < 25; i++) {
        final Map<String, dynamic> started =
            await store.startRun(id, trigger: 'manual');
        await store.finishRun(
          '${(started['run'] as Map)['id']}',
          ok: i.isEven,
          result: '第 $i 次',
          error: i.isEven ? '' : '失败 $i',
        );
      }
      final Map<String, dynamic> first =
          await store.history(id, limit: 10);
      expect((first['runs'] as List).length, 10);
      expect(first['next_cursor'], isNotNull);
      final Map<String, dynamic> second = await store.history(
        id,
        limit: 10,
        before: Map<String, dynamic>.from(first['next_cursor'] as Map),
      );
      expect((second['runs'] as List).length, 10);
      final Set<String> ids = <String>{
        ...(first['runs'] as List).map((dynamic r) => '${(r as Map)['id']}'),
        ...(second['runs'] as List).map((dynamic r) => '${(r as Map)['id']}'),
      };
      expect(ids.length, 20, reason: '两页不应有重复记录');
    });

    test('运行记录超过上限时丢弃最旧记录', () async {
      final Map<dynamic, dynamic> routine =
          (await createDaily())['routine'] as Map;
      final String id = '${routine['id']}';
      final List<Map<String, dynamic>> runs = <Map<String, dynamic>>[
        for (int i = 0; i < RoutineStore.maxRuns + 5; i++)
          <String, dynamic>{
            'id': 'old-$i',
            'routine_id': id,
            'trigger': 'schedule',
            'status': 'success',
            'created_at': DateTime.now()
                .toUtc()
                .subtract(Duration(minutes: i))
                .toIso8601String(),
            'started_at': null,
            'completed_at': null,
            'late_since': null,
            'error': '',
            'result': '',
          },
      ];
      final File runsFile = File('${tmp.path}/routines/runs.json');
      await runsFile.parent.create(recursive: true);
      await runsFile.writeAsString(
        jsonEncode(<String, dynamic>{'runs': runs}),
      );
      await store.startRun(id, trigger: 'manual');
      final Map<String, dynamic> history =
          await store.history(id, limit: 100);
      // 读取接口按页返回，直接看文件确认总量被裁剪。
      final Map<String, dynamic> raw = jsonDecode(
        await runsFile.readAsString(),
      ) as Map<String, dynamic>;
      expect((raw['runs'] as List).length, RoutineStore.maxRuns);
      expect(history['ok'], isTrue);
    });
  });

  group('并发写', () {
    test('并发创建不会丢记录', () async {
      await Future.wait(<Future<Map<String, dynamic>>>[
        for (int i = 0; i < 10; i++)
          store.create(
            name: '并发 $i',
            prompt: '任务 $i',
            crons: <String>['0 9 * * *'],
            timezone: 'UTC',
          ),
      ]);
      final Map<String, dynamic> list = await store.list();
      expect((list['routines'] as List).length, 10);
      final Map<String, dynamic> raw = jsonDecode(
        await File('${tmp.path}/routines/routines.json').readAsString(),
      ) as Map<String, dynamic>;
      expect((raw['routines'] as List).length, 10);
    });
  });
}
