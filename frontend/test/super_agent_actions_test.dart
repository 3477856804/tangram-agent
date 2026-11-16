import 'dart:io';

import 'package:test/test.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/super_agent.dart';

/// 轻量独立测试：只依赖 SuperAgent + HarnessStore，不加载 embedded_backend，
/// 因此不受他人正在处理的 embedded_backend.dart 编译错误影响。
/// 验证 create_direct / retry / batch_stop / tickets 过滤的真实行为。
void main() {
  group('SuperAgent 新增 action（独立可运行）', () {
    late Directory tmp;
    late HarnessStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangram_sa_actions_');
      HarnessStore.overrideForTest(tmp);
      store = await HarnessStore.instance();
    });

    tearDown(() async {
      for (int i = 0; i < 6; i++) {
        try {
          if (await tmp.exists()) await tmp.delete(recursive: true);
          return;
        } on Object {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }
    });

    /// 每步回复递增，避免恒定输出被 Watchdog 如实判为 repeated/failed。
    SuperAgent agentWithStepReplies() {
      int step = 0;
      return SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async {
          step += 1;
          return <String, dynamic>{
            'ok': true,
            'engine': 'remote-http',
            'reply': '第 $step 步真实结果',
          };
        },
      );
    }

    test('create_direct：goal 校验 + 真实 id/状态 + mandate 入参', () async {
      final SuperAgent saD = agentWithStepReplies();
      await saD.init();
      final Map<String, dynamic> empty = await saD.handle(
          'create_direct', <String, dynamic>{'goal': '   '});
      expect(empty['ok'], false);
      expect(empty['error'].toString(), contains('目标'));

      final Map<String, dynamic> r = await saD.handle('create_direct',
          <String, dynamic>{
        'goal': '直接修好登录崩溃',
        'source': 'manual',
        'thread': 'direct-1',
        'mandate': <String, dynamic>{
          'max_steps': 2,
          'deadline_seconds': 60,
        },
      });
      expect(r['ok'], true);
      final String id = r['id'].toString();
      expect(id, startsWith('ticket-'));
      final Map<String, dynamic> t = Map<String, dynamic>.from(r['ticket'] as Map);
      expect(t['goal'], '直接修好登录崩溃');
      expect(t['thread'], 'direct-1');
      expect((t['mandate'] as Map)['max_steps'], 2);
      expect(<String>['running', 'queued'], contains(t['status']));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final Map<String, dynamic> after =
          await saD.handle('ticket', <String, dynamic>{'id': id});
      expect((after['ticket'] as Map)['status'], 'done');
      expect((after['ticket'] as Map)['steps'], 2);
    });

    test('retry：仅失败类工单可重试，重置 queued 并跳过非法状态', () async {
      final SuperAgent saR = agentWithStepReplies();
      await saR.init();
      final Map<String, dynamic> created = await saR.handle(
          'create_direct', <String, dynamic>{
        'goal': '一个停止后重试的任务',
        'mandate': <String, dynamic>{'max_steps': 1},
      });
      final String id = created['id'].toString();
      await saR.handle('stop', <String, dynamic>{'id': id});
      final Map<String, dynamic> before =
          await saR.handle('ticket', <String, dynamic>{'id': id});
      expect((before['ticket'] as Map)['status'], 'stopped');

      final Map<String, dynamic> ok =
          await saR.handle('retry', <String, dynamic>{'id': id});
      expect(ok['ok'], true);
      expect(ok['id'], id);
      expect(<String>['running', 'queued'], contains(ok['status']));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final Map<String, dynamic> done =
          await saR.handle('ticket', <String, dynamic>{'id': id});
      expect((done['ticket'] as Map)['status'], 'done');

      final Map<String, dynamic> bad =
          await saR.handle('retry', <String, dynamic>{'id': id});
      expect(bad['ok'], false);
      expect(bad['error'].toString(), contains('仅'));
      final Map<String, dynamic> missing =
          await saR.handle('retry', <String, dynamic>{'id': 'no-such'});
      expect(missing['ok'], false);
      expect(missing['error'], '工单不存在');
    });

    test('batch_stop：逐项返回真实结果，非法 ids 报错', () async {
      final SuperAgent saB = agentWithStepReplies();
      await saB.init();
      final Map<String, dynamic> a = await saB.handle(
          'create_direct', <String, dynamic>{'goal': '批量停止任务A'});
      final Map<String, dynamic> b = await saB.handle(
          'create_direct', <String, dynamic>{'goal': '批量停止任务B'});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final Map<String, dynamic> r = await saB.handle('batch_stop',
          <String, dynamic>{
        'ids': <String>[
          a['id'].toString(),
          b['id'].toString(),
          'missing-id',
        ],
      });
      expect(r['ok'], true);
      expect(r['succeeded'], 2);
      expect(r['failed'], 1);
      expect(r['all_ok'], false);
      final List<dynamic> results = r['results'] as List;
      expect(results.length, 3);
      expect((results[0] as Map)['id'], a['id'].toString());
      expect((results[0] as Map)['ok'], true);
      expect((results[0] as Map)['status'], 'stopped');
      expect((results[2] as Map)['ok'], false);
      expect((results[2] as Map)['error'], '工单不存在');

      final Map<String, dynamic> bad = await saB.handle(
          'batch_stop', <String, dynamic>{'ids': 'not-a-list'});
      expect(bad['ok'], false);
      expect(bad['error'], 'ids 必须为列表');
    });

    test('tickets：query/status 过滤返回真实子集与 total', () async {
      final SuperAgent saF = agentWithStepReplies();
      await saF.init();
      await saF.handle('create_direct',
          <String, dynamic>{'goal': '修复 alpha 崩溃', 'source': 'manual'});
      await saF.handle('create_direct',
          <String, dynamic>{'goal': '处理 beta 报表', 'source': 'manual'});
      final Map<String, dynamic> all =
          await saF.handle('tickets', <String, dynamic>{});
      expect(all['total'], 2);
      expect((all['tickets'] as List).length, 2);

      final Map<String, dynamic> byQuery = await saF.handle(
          'tickets', <String, dynamic>{'query': 'alpha'});
      expect(byQuery['filtered'], 1);
      expect((byQuery['tickets'] as List).length, 1);
      expect(((byQuery['tickets'] as List).first as Map)['goal'].toString(),
          contains('alpha'));

      final Map<String, dynamic> byStatus = await saF.handle(
          'tickets', <String, dynamic>{'status': 'done'});
      for (final dynamic e in byStatus['tickets'] as List) {
        expect((e as Map)['status'], 'done');
      }

      final Map<String, dynamic> none = await saF.handle(
          'tickets', <String, dynamic>{'query': '不存在的关键词xyz'});
      expect(none['filtered'], 0);
      expect((none['tickets'] as List), isEmpty);
    });
  });
}
