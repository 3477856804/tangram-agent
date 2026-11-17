/// 认知页面纯逻辑 + 账号运营定时发布/互动/订单的真实行为测试。
///
/// 全部使用临时 HarnessStore 真实落盘；注入的 send 只替代外部发布通道，
/// 服务内部的审批状态机、到期筛选与审计都是真实逻辑。认知部分只测纯函数，
/// 不构建 Provider/页面，也不访问网络。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/account_ops.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/ui/pages/tga_cognition_page.dart';

void main() {
  late Directory tmp;
  late HarnessStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_cognition_account_');
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
  });

  tearDown(() async {
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // 后台落盘竞态不影响断言。
    }
  });

  AccountOps opsWith(AccountSender send) =>
      AccountOps(store, send: send);

  Future<String> newAccount(AccountOps ops,
      {String channel = 'wechat', String name = '品牌号'}) async {
    final Map<String, dynamic> r = await ops.addAccount(
      channel: channel,
      name: name,
      credentialRef: 'env:${channel.toUpperCase()}_TOKEN',
    );
    expect(r['ok'], true, reason: '账号应创建成功：${r['error']}');
    return ((r['account'] as Map)['id']).toString();
  }

  Future<String> approvedDraft(
    AccountOps ops,
    String accountId,
    String scheduledAt, {
    String content = '定时内容',
  }) async {
    final Map<String, dynamic> created = await ops.createDraft(
      accountId: accountId,
      content: content,
      scheduledAt: scheduledAt,
    );
    expect(created['ok'], true, reason: '草稿应创建成功：${created['error']}');
    final String id = ((created['draft'] as Map)['id']).toString();
    expect((await ops.submitDraft(id))['ok'], true);
    expect((await ops.approveDraft(id))['ok'], true);
    return id;
  }

  group('AccountOps.dueDrafts / publishDue', () {
    test('只返回 approved + 到点 + 账号启用的草稿，绝不自动审批', () async {
      final AccountOps ops = opsWith(
          (String channel, Map<String, dynamic> payload) async =>
              <String, dynamic>{'ok': true});
      final String enabled = await newAccount(ops, name: '启用号');
      final String disabled = await newAccount(ops, name: '停用号');
      final DateTime now = DateTime(2026, 11, 17, 12);

      final String dueId = await approvedDraft(
          ops, enabled, now.subtract(const Duration(minutes: 10)).toIso8601String());
      await approvedDraft(
          ops, enabled, now.add(const Duration(hours: 1)).toIso8601String());
      await approvedDraft(ops, enabled, '');
      // 未审批：scheduled_at 已到点，但状态仍是 draft。
      final Map<String, dynamic> pending = await ops.createDraft(
        accountId: enabled,
        content: '未审批内容',
        scheduledAt: now.subtract(const Duration(hours: 1)).toIso8601String(),
      );
      final String pendingId = ((pending['draft'] as Map)['id']).toString();
      // 停用账号：审批通过后停用，到期也不得发布。
      final String disabledDraftId = await approvedDraft(
          ops,
          disabled,
          now.subtract(const Duration(minutes: 5)).toIso8601String());
      await ops.toggleAccount(disabled, false);

      final List<Map<String, dynamic>> due = await ops.dueDrafts(now: now);
      expect(due.length, 1);
      expect(due.single['id'], dueId);
      expect(due.single['status'], 'approved');

      final Map<String, dynamic> pendingBefore =
          (await ops.listDrafts()).firstWhere(
              (Map<String, dynamic> d) => d['id'] == pendingId);
      expect(pendingBefore['status'], 'draft');
      final Map<String, dynamic> disabledBefore =
          (await ops.listDrafts()).firstWhere(
              (Map<String, dynamic> d) => d['id'] == disabledDraftId);
      expect(disabledBefore['status'], 'approved');
    });

    test('publishDue 成功记 published、失败记 failed 且错误保留；每草稿只调用一次',
        () async {
      final Map<String, int> sendCalls = <String, int>{};
      final AccountOps ops = opsWith(
          (String channel, Map<String, dynamic> payload) async {
        final String draftId = (payload['draft_id'] ?? '').toString();
        sendCalls[draftId] = (sendCalls[draftId] ?? 0) + 1;
        if (channel == 'bad-chan') {
          return <String, dynamic>{'ok': false, 'error': '平台限流 429'};
        }
        return <String, dynamic>{'ok': true, 'post_id': 'p-$draftId'};
      });
      final String okAccount =
          await newAccount(ops, channel: 'ok-chan', name: '成功号');
      final String badAccount =
          await newAccount(ops, channel: 'bad-chan', name: '失败号');
      final DateTime now = DateTime(2026, 11, 17, 12);
      final String okId = await approvedDraft(ops, okAccount,
          now.subtract(const Duration(minutes: 3)).toIso8601String());
      final String badId = await approvedDraft(ops, badAccount,
          now.subtract(const Duration(minutes: 2)).toIso8601String());

      final Map<String, dynamic> r =
          await ops.publishDue(now: now, limit: 10);
      expect(r['ok'], true);
      expect(r['due'], 2);
      expect(r['attempted'], 2);
      expect(r['published'], 1);
      expect(r['failed'], 1);
      expect(r['skipped'], 0);
      expect(sendCalls[okId], 1);
      expect(sendCalls[badId], 1);
      expect(sendCalls.length, 2);

      final List<Map<String, dynamic>> drafts = await ops.listDrafts();
      final Map<String, dynamic> okDraft =
          drafts.firstWhere((Map<String, dynamic> d) => d['id'] == okId);
      final Map<String, dynamic> badDraft =
          drafts.firstWhere((Map<String, dynamic> d) => d['id'] == badId);
      expect(okDraft['status'], 'published');
      expect(badDraft['status'], 'failed');
      expect(badDraft['error'].toString(), contains('限流'));
      expect(await ops.dueDrafts(now: now), isEmpty);

      final Map<String, dynamic> raw = await store.readJson('account_ops.json');
      final List<dynamic> persisted = raw['drafts'] as List<dynamic>;
      final Map<String, dynamic> persistedBad = Map<String, dynamic>.from(
          persisted.firstWhere((dynamic e) =>
              (e as Map)['id'] == badId) as Map);
      expect(persistedBad['status'], 'failed');
      expect(persistedBad['error'].toString(), contains('限流'));

      final List<Map<String, dynamic>> audit = await ops.audit(limit: 50);
      expect(
          audit.any((Map<String, dynamic> e) =>
              e['action'] == 'draft.publish_success'),
          true);
      expect(
          audit.any((Map<String, dynamic> e) =>
              e['action'] == 'draft.publish_failed'),
          true);
    });

    test('publishDue 的 limit 只处理前 N 条，其余计入 skipped 且仍为 approved',
        () async {
      final AccountOps ops = opsWith(
          (String channel, Map<String, dynamic> payload) async =>
              <String, dynamic>{'ok': true});
      final String account =
          await newAccount(ops, channel: 'ok-chan', name: '批量号');
      final DateTime now = DateTime(2026, 11, 17, 12);
      final List<String> ids = <String>[
        for (int i = 0; i < 3; i++)
          await approvedDraft(ops, account,
              now.subtract(Duration(minutes: 10 - i)).toIso8601String()),
      ];

      final Map<String, dynamic> r = await ops.publishDue(now: now, limit: 2);
      expect(r['due'], 3);
      expect(r['attempted'], 2);
      expect(r['published'], 2);
      expect(r['skipped'], 1);

      final List<Map<String, dynamic>> drafts = await ops.listDrafts();
      final Map<String, dynamic> left =
          drafts.firstWhere((Map<String, dynamic> d) => d['id'] == ids.last);
      expect(left['status'], 'approved');
      expect((await ops.dueDrafts(now: now)).single['id'], ids.last);
    });
  });

  group('AccountOps 互动 / 订单', () {
    test('互动记录 CRUD 与状态更新真实落盘，明文密钥拒绝保存', () async {
      final AccountOps ops = opsWith(
          (String channel, Map<String, dynamic> payload) async =>
              <String, dynamic>{'ok': true});
      final String account =
          await newAccount(ops, channel: 'wechat', name: '互动号');

      final Map<String, dynamic> added = await ops.addInteraction(
        channel: '',
        accountId: account,
        target: 'group-1',
        direction: 'out',
        summary: '回复了用户关于发货时间的问题',
      );
      expect(added['ok'], true);
      final Map<String, dynamic> interaction =
          Map<String, dynamic>.from(added['interaction'] as Map);
      expect(interaction['channel'], 'wechat');
      expect(interaction['direction'], 'out');
      expect(interaction['status'], 'logged');
      final String id = interaction['id'].toString();

      final List<Map<String, dynamic>> listed = await ops.listInteractions();
      expect(listed.length, 1);
      expect(listed.single['summary'], '回复了用户关于发货时间的问题');

      final Map<String, dynamic> updated =
          await ops.updateInteractionStatus(id, 'replied');
      expect(updated['ok'], true);
      expect((await ops.listInteractions()).single['status'], 'replied');

      final Map<String, dynamic> secret = await ops.addInteraction(
        channel: 'wechat',
        accountId: account,
        target: 'group-1',
        direction: 'out',
        summary: '令牌 sk-live-abcdef0123456789',
      );
      expect(secret['ok'], false);
      expect(secret['error'].toString(), contains('明文密钥'));
      expect((await ops.listInteractions()).length, 1);

      final Map<String, dynamic> badDirection = await ops.addInteraction(
        channel: 'wechat',
        accountId: account,
        target: 'group-1',
        direction: 'sideways',
        summary: '方向非法',
      );
      expect(badDirection['ok'], false);

      final Map<String, dynamic> raw = await store.readJson('account_ops.json');
      final List<dynamic> stored = raw['interactions'] as List<dynamic>;
      expect(stored.length, 1);
      expect((stored.single as Map)['status'], 'replied');
      expect(jsonEncode(raw).contains('sk-live-abcdef0123456789'), false);
    });

    test('订单按平台单号幂等 upsert，状态更新与落盘真实', () async {
      final AccountOps ops = opsWith(
          (String channel, Map<String, dynamic> payload) async =>
              <String, dynamic>{'ok': true});
      final String account =
          await newAccount(ops, channel: 'shop', name: '店铺号');

      final Map<String, dynamic> first = await ops.upsertOrder(
        accountId: account,
        platformOrderId: 'PO-1001',
        title: '联名礼盒',
        amount: 129.0,
      );
      expect(first['ok'], true);
      expect(first['created'], true);
      final String orderId = ((first['order'] as Map)['id']).toString();

      final Map<String, dynamic> second = await ops.upsertOrder(
        accountId: account,
        platformOrderId: 'PO-1001',
        title: '联名礼盒（补发）',
        amount: 99.5,
        status: 'paid',
      );
      expect(second['ok'], true);
      expect(second['created'], false);
      expect(((second['order'] as Map)['id']).toString(), orderId);

      final List<Map<String, dynamic>> orders = await ops.listOrders();
      expect(orders.length, 1, reason: '同账号同平台单号不得产生重复订单');
      expect(orders.single['title'], '联名礼盒（补发）');
      expect(orders.single['amount'], 99.5);
      expect(orders.single['status'], 'paid');

      final Map<String, dynamic> updated =
          await ops.updateOrderStatus(orderId, 'shipped');
      expect(updated['ok'], true);
      expect((await ops.listOrders()).single['status'], 'shipped');

      final Map<String, dynamic> raw = await store.readJson('account_ops.json');
      final List<dynamic> stored = raw['orders'] as List<dynamic>;
      expect(stored.length, 1);
      expect((stored.single as Map)['platform_order_id'], 'PO-1001');
      expect((stored.single as Map)['status'], 'shipped');
    });

    test('账号仍拒绝明文密钥，只保存凭据引用', () async {
      final AccountOps ops = opsWith(
          (String channel, Map<String, dynamic> payload) async =>
              <String, dynamic>{'ok': true});
      final Map<String, dynamic> bad = await ops.addAccount(
        channel: 'wechat',
        name: '品牌号',
        credentialRef: 'sk-live-abcdef0123456789',
      );
      expect(bad['ok'], false);
      expect(bad['error'].toString(), contains('明文密钥'));
      expect(await ops.listAccounts(), isEmpty);
      final String id = await newAccount(ops);
      expect((await ops.listAccounts()).single['credential_ref'],
          'env:WECHAT_TOKEN');
      expect(id.isNotEmpty, true);
    });
  });

  group('认知页面纯逻辑', () {
    test('风险等级颜色与文案', () {
      expect(riskLevelColor('high'), riskLevelColor('critical'));
      expect(riskLevelColor('high'), isNot(riskLevelColor('medium')));
      expect(riskLevelColor('medium'), isNot(riskLevelColor('low')));
      expect(riskLevelColor('unknown'), isNot(riskLevelColor('low')));
      expect(riskLevelLabel('HIGH'), '高');
      expect(riskLevelLabel('critical'), '极高');
      expect(riskLevelLabel(''), '未知');
    });

    test('方案完整性与 2-3 条路线范围', () {
      final Map<String, dynamic> complete = <String, dynamic>{
        'name': '热修复',
        'benefits': <String>['见效快'],
        'costs': <String>['改动集中'],
        'risks': <String>['可能回归'],
        'fit': '紧急上线',
        'tradeoff': '速度优先',
      };
      expect(optionIsComplete(complete), true);
      final Map<String, dynamic> missingCosts = <String, dynamic>{
        ...complete,
        'costs': <String>[],
      };
      expect(optionIsComplete(missingCosts), false);
      final Map<String, dynamic> noName = <String, dynamic>{
        ...complete,
        'name': '',
      };
      expect(optionIsComplete(noName), false);
      expect(
          completeOptionCount(<Map<String, dynamic>>[complete, missingCosts]),
          1);
      expect(meetsRouteRange(1), false);
      expect(meetsRouteRange(2), true);
      expect(meetsRouteRange(3), true);
      expect(meetsRouteRange(4), false);
    });

    test('结构化缺失时如实给出降级说明，不伪造结论', () {
      expect(
          cognitionDegradationNote(<String, dynamic>{'structured': true}), '');
      final String note = cognitionDegradationNote(<String, dynamic>{
        'structured': false,
        'degraded': true,
        'engine': 'remote-failed',
      });
      expect(note, contains('remote-failed'));
      expect(note, contains('降级'));
      expect(note, contains('不展示伪造结论'));

      expect(
          riskScanModelNote(<String, dynamic>{'model_structured': true}), '');
      expect(
          riskScanModelNote(<String, dynamic>{
            'model_structured': false,
            'engine': 'builtin-agent-loop',
          }),
          contains('模型补充未解析'));
    });
  });
}
