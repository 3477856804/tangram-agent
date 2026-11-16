/// 经验类比迁移 / AI 账号运营（人工确认）/ AI 视频剪辑工作室的真实行为测试。
///
/// 全部使用临时 HarnessStore，不访问网络、不 mock 磁盘；注入的 send / shell
/// 只用于替代外部通道与沙箱进程，服务内部的校验、状态机与落盘都是真实逻辑。

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tangram/harness/account_ops.dart';
import 'package:tangram/harness/experience_transfer.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/video_studio.dart';

void main() {
  late Directory tmp;
  late HarnessStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_exp_acct_video_');
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

  group('经验类比迁移', () {
    test('手工导入后可检索、无命中返回空、迁移标注 heuristic', () async {
      final ExperienceLibrary lib = ExperienceLibrary(store);
      final Map<String, dynamic> added = await lib.addManual(
        name: '登录 401 排查',
        task: '登录接口返回 401 未授权',
        approach: '检查 token 过期时间与刷新逻辑，补充刷新失败的重试',
        tags: <String>['auth', '登录'],
        steps: <String>['复现 401', '抓包确认 token', '刷新 token 后重试'],
      );
      expect(added['ok'], true);
      final String id = (added['pattern'] as Map)['id'].toString();

      final List<Map<String, dynamic>> hits = await lib.search('登录 401', 5);
      expect(hits, isNotEmpty);
      expect((hits.first['score'] as num) > 0, true);
      expect(hits.first['id'], id);

      final List<Map<String, dynamic>> none =
          await lib.search('视频转码 ffmpeg 剪辑', 5);
      expect(none, isEmpty);

      final Map<String, dynamic> adapted =
          await lib.adapt(id, '小程序登录偶尔 401');
      expect(adapted['ok'], true);
      expect(adapted['engine'], 'heuristic');
      expect(adapted['model'], false);
      expect(adapted['plan'].toString(), contains('登录 401 排查'));
      expect(adapted['checklist'], isA<List<dynamic>>());
      expect((adapted['checklist'] as List<dynamic>).isNotEmpty, true);

      final Map<String, dynamic> first =
          await lib.recordOutcome(id, true, '一次成功');
      expect(first['uses'], 1);
      expect(first['successes'], 1);
      final Map<String, dynamic> second =
          await lib.recordOutcome(id, false, '边界条件不满足');
      expect(second['uses'], 2);
      expect(second['successes'], 1);
      expect(second['success_rate'], 0.5);

      final List<Map<String, dynamic>> persisted = await lib.list();
      expect(persisted.length, 1);
      expect(persisted.first['uses'], 2);
      expect(persisted.first['successes'], 1);
    });

    test('从成功工单 / 成功工作流导入，失败记录不导入且可重复导入去重', () async {
      await store.insert('super_tickets', <String, dynamic>{
        'id': 'ticket-1',
        'status': 'done',
        'goal': '修复支付回调签名校验',
        'result': '核对签名算法并补齐单元测试',
        'history': <String>['[step 1] 定位签名拼接顺序', '[step 2] 修复并验证'],
        'source': 'manual',
        'engine': 'remote-http',
      });
      await store.insert('super_tickets', <String, dynamic>{
        'id': 'ticket-2',
        'status': 'failed',
        'goal': '这次失败的工单不应导入',
        'result': '失败',
      });
      await store.insert('workflow_runs', <String, dynamic>{
        'id': 'run-1',
        'status': 'done',
        'workflow_name': '日志巡检',
        'input': 'prod',
        'outputs': <Map<String, dynamic>>[
          <String, dynamic>{
            'step': '扫描日志',
            'type': 'shell',
            'output': '发现 3 条 error 并已归档',
          },
        ],
      });
      await store.insert('workflow_runs', <String, dynamic>{
        'id': 'run-2',
        'status': 'failed',
        'workflow_name': '失败运行',
        'outputs': <dynamic>[],
      });

      final ExperienceLibrary lib = ExperienceLibrary(store);
      final Map<String, dynamic> tickets = await lib.importFromTickets();
      expect(tickets['ok'], true);
      expect(tickets['imported'], 1);

      final Map<String, dynamic> runs = await lib.importFromRuns();
      expect(runs['ok'], true);
      expect(runs['imported'], 1);

      final List<Map<String, dynamic>> payHits =
          await lib.search('支付回调签名', 5);
      expect(payHits, isNotEmpty);
      expect(payHits.first['source'], 'ticket');

      final List<Map<String, dynamic>> logHits =
          await lib.search('日志巡检', 5);
      expect(logHits, isNotEmpty);
      expect(logHits.first['source'], 'workflow');

      final List<Map<String, dynamic>> failedHits =
          await lib.search('失败的工单不应导入', 5);
      expect(failedHits, isEmpty);

      final Map<String, dynamic> again = await lib.importFromTickets();
      expect(again['imported'], 0);
      expect((await lib.list()).length, 2);
    });
  });

  group('AI 账号运营（人工确认）', () {
    test('明文密钥拒绝保存，只保存凭据引用', () async {
      final AccountOps ops = AccountOps(
        store,
        send: (String channel, Map<String, dynamic> payload) async =>
            <String, dynamic>{'ok': true},
      );
      final Map<String, dynamic> bad = await ops.addAccount(
        channel: 'wechat',
        name: '品牌号',
        credentialRef: 'sk-live-abcdef0123456789',
      );
      expect(bad['ok'], false);
      expect(bad['error'].toString(), contains('明文密钥'));
      expect(await ops.listAccounts(), isEmpty);

      final Map<String, dynamic> good = await ops.addAccount(
        channel: 'wechat',
        name: '品牌号',
        credentialRef: 'env:WECHAT_TOKEN',
      );
      expect(good['ok'], true);
      expect((good['account'] as Map)['credential_ref'], 'env:WECHAT_TOKEN');

      final Map<String, dynamic> raw =
          await store.readJson('account_ops.json');
      final String serialized = jsonEncode(raw);
      expect(serialized.contains('sk-live-abcdef0123456789'), false);
      expect((raw['accounts'] as List).length, 1);
    });

    test('发布必须 approved：未审批不调用 send，失败如实 failed', () async {
      int calls = 0;
      final AccountOps ops = AccountOps(
        store,
        send: (String channel, Map<String, dynamic> payload) async {
          calls += 1;
          return <String, dynamic>{'ok': false, 'error': '平台返回 500'};
        },
      );
      final Map<String, dynamic> account = await ops.addAccount(
        channel: 'wechat',
        name: '品牌号',
        credentialRef: 'env:WECHAT_TOKEN',
      );
      final String accountId = (account['account'] as Map)['id'].toString();
      final Map<String, dynamic> created = await ops.createDraft(
        accountId: accountId,
        content: '新品上线预告',
      );
      final String draftId = (created['draft'] as Map)['id'].toString();

      final Map<String, dynamic> beforeApprove =
          await ops.publishDraft(draftId);
      expect(beforeApprove['ok'], false);
      expect(calls, 0);
      expect((beforeApprove['draft'] as Map)['status'], 'draft');

      await ops.submitDraft(draftId);
      final Map<String, dynamic> pendingPublish =
          await ops.publishDraft(draftId);
      expect(pendingPublish['ok'], false);
      expect(calls, 0);

      await ops.approveDraft(draftId);
      final Map<String, dynamic> failed = await ops.publishDraft(draftId);
      expect(calls, 1);
      expect(failed['ok'], false);
      expect(failed['status'], 'failed');
      expect(failed['error'].toString(), contains('平台返回 500'));
      expect((failed['draft'] as Map)['status'], 'failed');
      expect((failed['draft'] as Map)['error'].toString(), contains('平台返回 500'));

      final Map<String, dynamic> raw =
          await store.readJson('account_ops.json');
      final Map<String, dynamic> persistedDraft =
          Map<String, dynamic>.from((raw['drafts'] as List).first as Map);
      expect(persistedDraft['status'], 'failed');
      expect(persistedDraft['status'], isNot('published'));

      final List<Map<String, dynamic>> audit = await ops.audit(limit: 50);
      expect(audit, isNotEmpty);
      expect(
        audit.any((Map<String, dynamic> e) =>
            e['action'] == 'draft.publish_denied'),
        true,
      );
      expect(
        audit.any((Map<String, dynamic> e) =>
            e['action'] == 'draft.publish_failed'),
        true,
      );
    });

    test('approved 后 send 成功才记录 published', () async {
      String? seenRef;
      final AccountOps ops = AccountOps(
        store,
        send: (String channel, Map<String, dynamic> payload) async {
          seenRef = (payload['credential_ref'] ?? '').toString();
          return <String, dynamic>{'ok': true, 'post_id': 'post-1'};
        },
      );
      final Map<String, dynamic> account = await ops.addAccount(
        channel: 'feishu',
        name: '官方号',
        credentialRef: 'vault://feishu/official',
      );
      final String accountId = (account['account'] as Map)['id'].toString();
      final Map<String, dynamic> created = await ops.createDraft(
        accountId: accountId,
        content: '周报',
        target: 'chat-1',
      );
      final String draftId = (created['draft'] as Map)['id'].toString();
      await ops.submitDraft(draftId);
      await ops.approveDraft(draftId);
      final Map<String, dynamic> published = await ops.publishDraft(draftId);
      expect(published['ok'], true);
      expect((published['draft'] as Map)['status'], 'published');
      expect(seenRef, 'vault://feishu/official');

      final Map<String, dynamic> raw =
          await store.readJson('account_ops.json');
      final Map<String, dynamic> persistedDraft =
          Map<String, dynamic>.from((raw['drafts'] as List).first as Map);
      expect(persistedDraft['status'], 'published');
    });
  });

  group('AI 视频剪辑工作室', () {
    test('命令包含真实参数与依赖检查，且安全处理单引号', () async {
      final VideoStudio studio = VideoStudio(
        store,
        shell: (String command, String cwd) async =>
            <String, dynamic>{'ok': true, 'exit_code': 0, 'stdout': '{}'},
      );
      final Map<String, dynamic> built = studio.buildAutoEditCommand(
        <String>['sandbox/a b.mp4', "sandbox/o'brien.mp4"],
        'sandbox/out final.mp4',
        subtitles: 'sandbox/subs.srt',
        music: 'sandbox/music.mp3',
        width: 1920,
        height: 1080,
        fps: 25,
      );
      expect(built['ok'], true);
      expect(built['argv'], isA<List<dynamic>>());
      expect((built['argv'] as List<dynamic>).first, 'python3');
      final String command = built['command'].toString();
      for (final String token in <String>[
        'sandbox/a b.mp4',
        "sandbox/o'\\''brien.mp4",
        'sandbox/out final.mp4',
        'sandbox/subs.srt',
        'sandbox/music.mp3',
        '1920',
        '1080',
        '25',
      ]) {
        expect(command.contains(token), true);
      }
      expect(command.contains("'\\''"), true);
      final String deps = built['dependency_check'].toString();
      expect(deps.contains('ffmpeg'), true);
      expect(deps.contains('ffprobe'), true);
      expect((built['uses'] as List<dynamic>).contains('ffmpeg'), true);

      final Map<String, dynamic> empty =
          studio.buildAutoEditCommand(<String>[], 'out.mp4');
      expect(empty['ok'], false);
      expect(empty['error'].toString(), contains('素材'));
    });

    test('shell 失败如实记录 failed 与错误，任务落盘可删', () async {
      final VideoStudio studio = VideoStudio(
        store,
        shell: (String command, String cwd) async => <String, dynamic>{
          'ok': false,
          'exit_code': 1,
          'stdout': '',
          'stderr': 'ffmpeg: command not found',
        },
      );
      final Map<String, dynamic> run = await studio.runJob(
        assets: <String>['sandbox/a.mp4'],
        output: 'sandbox/final.mp4',
        subtitles: 'sandbox/subs.srt',
        music: 'sandbox/music.mp3',
        width: 1280,
        height: 720,
        fps: 30,
      );
      expect(run['ok'], false);
      final Map<String, dynamic> job =
          Map<String, dynamic>.from(run['job'] as Map);
      expect(job['status'], 'failed');
      expect(job['exit_code'], 1);
      expect(job['error'].toString(), contains('not found'));

      final List<Map<String, dynamic>> jobs = await studio.listJobs();
      expect(jobs.length, 1);
      expect(jobs.first['status'], 'failed');
      expect(await store.file('video_jobs.json').exists(), true);

      final Map<String, dynamic> removed =
          await studio.deleteJob(jobs.first['id']);
      expect(removed['ok'], true);
      expect(await studio.listJobs(), isEmpty);
    });

    test('stdout JSON 可解析时才判 done，并保留 video_edit 输出结构', () async {
      final String stdout = jsonEncode(<String, dynamic>{
        'ok': true,
        'output': '/tmp/final.mp4',
        'steps': <Map<String, dynamic>>[
          <String, dynamic>{
            'step': 'concat',
            'result': <String, dynamic>{'ok': true, 'clips': 1},
          },
        ],
        'info': <String, dynamic>{
          'duration': 3.5,
          'width': 1280,
          'height': 720,
          'video_codec': 'h264',
        },
      });
      final VideoStudio studio = VideoStudio(
        store,
        shell: (String command, String cwd) async => <String, dynamic>{
          'ok': true,
          'exit_code': 0,
          'stdout': stdout,
        },
      );
      final Map<String, dynamic> run = await studio.runJob(
        assets: <String>['sandbox/a.mp4'],
        output: 'sandbox/final.mp4',
      );
      expect(run['ok'], true);
      final Map<String, dynamic> job =
          Map<String, dynamic>.from(run['job'] as Map);
      expect(job['status'], 'done');
      expect(job['error'], '');
      final Map<String, dynamic> result =
          Map<String, dynamic>.from(job['result'] as Map);
      expect(result['output'], '/tmp/final.mp4');
      expect((result['info'] as Map)['width'], 1280);
    });
  });
}
