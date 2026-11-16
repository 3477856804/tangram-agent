/// 知识库 / 工作流 / 快照 / 多模型群聊 / Super Agent 协商的真实行为测试。
///
/// 全部走 EmbeddedBackend.dispatch 的真实控制域与真实磁盘落盘；
/// 不 mock 存储、不编造结果。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/super_agent.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;
  late EmbeddedBackend backend;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_kb_wf_');
    for (final String sub in <String>[
      'models', 'cards', 'plugins', 'work', 'downloads', 'sandbox',
    ]) {
      await Directory('${tmp.path}/$sub').create(recursive: true);
    }
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
    backend = EmbeddedBackend.forTest(store);
  });

  tearDown(() async {
    await backend.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // 后台落盘竞态不影响断言。
    }
  });

  Future<Map<String, dynamic>> call(
    String topic, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final reply = await backend.dispatch(topic, payload);
    return reply.payload;
  }

  group('私有知识库：多库隔离 / 检索 / 引用 / 快照', () {
    test('入库后可检索、引用真实来源、重复内容跳过', () async {
      final Map<String, dynamic> lib = await call('knowledge_base', <String, dynamic>{
        'action': 'create',
        'name': '产品手册',
        'description': '测试库',
      });
      expect(lib['ok'], true);
      final String id = (lib['library'] as Map)['id'].toString();

      final Map<String, dynamic> ingest = await call('knowledge_base', <String, dynamic>{
        'action': 'ingest_text',
        'library_id': id,
        'name': '登录说明',
        'text': 'TGA 的登录入口在侧边栏底部。若忘记密码，请使用邮箱验证码重置。\n\n'
            '沙箱默认目录是 /workspace，所有工作区文件都在这里。',
      });
      expect(ingest['ok'], true);
      expect(ingest['duplicate'], false);
      expect((ingest['chunks'] as int) > 0, true);

      final Map<String, dynamic> dup = await call('knowledge_base', <String, dynamic>{
        'action': 'ingest_text',
        'library_id': id,
        'name': '重复',
        'text': 'TGA 的登录入口在侧边栏底部。若忘记密码，请使用邮箱验证码重置。\n\n'
            '沙箱默认目录是 /workspace，所有工作区文件都在这里。',
      });
      expect(dup['duplicate'], true);

      final Map<String, dynamic> search = await call('knowledge_base', <String, dynamic>{
        'action': 'search',
        'query': '忘记密码怎么办',
      });
      expect(search['ok'], true);
      final List<dynamic> results = search['results'] as List;
      expect(results, isNotEmpty);
      final Map result = results.first as Map;
      expect(result['document_name'], '登录说明');
      expect(result['library_name'], '产品手册');
      expect((result['snippet'] as String).isNotEmpty, true);

      final Map<String, dynamic> block = await call('knowledge_base', <String, dynamic>{
        'action': 'context',
        'query': '忘记密码',
      });
      expect(block['context'].toString(), contains('登录说明'));
      expect(block['context'].toString(), contains('来源'));
    });

    test('停用库不参与检索；删除库清理文档', () async {
      final Map<String, dynamic> lib = await call('knowledge_base', <String, dynamic>{
        'action': 'create', 'name': '临时库',
      });
      final String id = (lib['library'] as Map)['id'].toString();
      await call('knowledge_base', <String, dynamic>{
        'action': 'ingest_text',
        'library_id': id,
        'name': '片段',
        'text': '只属于临时库的关键词 火星基地',
      });
      await call('knowledge_base', <String, dynamic>{
        'action': 'update', 'id': id, 'enabled': false,
      });
      final Map<String, dynamic> s1 = await call('knowledge_base', <String, dynamic>{
        'action': 'search', 'query': '火星基地',
      });
      expect((s1['results'] as List), isEmpty);

      await call('knowledge_base', <String, dynamic>{'action': 'delete', 'id': id});
      final Map<String, dynamic> list = await call('knowledge_base');
      expect((list['libraries'] as List), isEmpty);
      expect(list['documents'], 0);
      expect(list['chunks'], 0);
    });

    test('快照保存与恢复到真实版本', () async {
      final Map<String, dynamic> lib = await call('knowledge_base', <String, dynamic>{
        'action': 'create', 'name': '版本库',
      });
      final String id = (lib['library'] as Map)['id'].toString();
      await call('knowledge_base', <String, dynamic>{
        'action': 'ingest_text',
        'library_id': id,
        'name': 'v1',
        'text': '第一版内容：蓝鲸计划。',
      });
      final Map<String, dynamic> snap = await call('knowledge_base', <String, dynamic>{
        'action': 'snapshot', 'library_id': id,
      });
      expect(snap['ok'], true);
      final String snapId = (snap['snapshot'] as Map)['id'].toString();

      await call('knowledge_base', <String, dynamic>{
        'action': 'ingest_text',
        'library_id': id,
        'name': 'v2',
        'text': '第二版内容：极光计划。',
      });
      final Map<String, dynamic> before = await call('knowledge_base', <String, dynamic>{
        'action': 'docs', 'library_id': id,
      });
      expect((before['documents'] as List).length, 2);

      final Map<String, dynamic> restore = await call('knowledge_base', <String, dynamic>{
        'action': 'restore', 'library_id': id, 'snapshot_id': snapId,
      });
      expect(restore['ok'], true);
      expect(restore['documents'], 1);
      final Map<String, dynamic> after = await call('knowledge_base', <String, dynamic>{
        'action': 'docs', 'library_id': id,
      });
      expect((after['documents'] as List).length, 1);
      expect(((after['documents'] as List).first as Map)['name'], 'v1');
    });
  });

  group('工作流：定义校验 / 真实执行 / 变量替换 / 批量', () {
    test('保存后运行，变量与输出真实落盘', () async {
      final Map<String, dynamic> saved = await call('workflow', <String, dynamic>{
        'action': 'save',
        'workflow': <String, dynamic>{
          'name': '计算测试',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '计算',
              'type': 'prompt',
              'input': '6 * 7',
              'save_as': 'result',
            },
          ],
        },
      });
      expect(saved['ok'], true);
      final String id = (saved['workflow'] as Map)['id'].toString();

      final Map<String, dynamic> run = await call('workflow', <String, dynamic>{
        'action': 'run', 'id': id, 'input': 'ignored',
      });
      expect(run['ok'], true);
      final Map<String, dynamic> detail = Map<String, dynamic>.from(run['run'] as Map);
      expect(detail['status'], 'done');
      expect((detail['outputs'] as List), isNotEmpty);
      final Map step = (detail['outputs'] as List).first as Map;
      expect((step['output'] as String).contains('42'), true);
      expect((detail['variables'] as Map)['result'].toString().contains('42'), true);

      final Map<String, dynamic> runs = await call('workflow', <String, dynamic>{
        'action': 'runs',
      });
      expect((runs['runs'] as List), isNotEmpty);
    });

    test('空步骤 / 未知类型如实拒绝', () async {
      final Map<String, dynamic> a = await call('workflow', <String, dynamic>{
        'action': 'save',
        'workflow': <String, dynamic>{'name': '坏流程', 'steps': <dynamic>[]},
      });
      expect(a['ok'], false);
      final Map<String, dynamic> b = await call('workflow', <String, dynamic>{
        'action': 'save',
        'workflow': <String, dynamic>{
          'name': '坏类型',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{'name': 'x', 'type': 'hack', 'input': 'x'},
          ],
        },
      });
      expect(b['ok'], false);
    });

    test('批量运行按 inputs 逐条执行', () async {
      final Map<String, dynamic> saved = await call('workflow', <String, dynamic>{
        'action': 'save',
        'workflow': <String, dynamic>{
          'name': '批量',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '处理',
              'type': 'prompt',
              'input': '原样返回：{{input}}',
            },
          ],
        },
      });
      final String id = (saved['workflow'] as Map)['id'].toString();
      final Map<String, dynamic> r = await call('workflow', <String, dynamic>{
        'action': 'batch',
        'id': id,
        'inputs': <String>['甲', '乙'],
      });
      expect(r['ok'], true);
      expect(r['count'], 2);
      expect(r['succeeded'], 2);
    });
  });

  group('快照：创建 / 列表 / 恢复前备份', () {
    test('快照记录真实文件数与 SHA256，恢复后数据一致', () async {
      await store.writeJson('agents.json', <String, dynamic>{
        'agents': <dynamic>[<String, dynamic>{'name': '测试智能体'}],
      });
      final Map<String, dynamic> created =
          await call('snapshot', <String, dynamic>{
        'action': 'create', 'label': '测试快照',
      });
      expect(created['ok'], true);
      final Map snap = created['snapshot'] as Map;
      expect((snap['file_count'] as int) > 0, true);
      final List files = snap['files'] as List;
      final Map agentFile =
          files.firstWhere((dynamic e) => (e as Map)['path'] == 'agents.json') as Map;
      expect((agentFile['sha256'] as String).length, 64);

      await store.writeJson('agents.json', <String, dynamic>{
        'agents': <dynamic>[<String, dynamic>{'name': '被改坏'}],
      });
      final Map<String, dynamic> restored = await call('snapshot', <String, dynamic>{
        'action': 'restore', 'id': snap['id'],
      });
      expect(restored['ok'], true);
      expect(restored['restored'], greaterThan(0));
      final Map<String, dynamic> agents = await store.readJson('agents.json');
      expect((agents['agents'] as List).first['name'], '测试智能体');

      final Map<String, dynamic> list =
          await call('snapshot', <String, dynamic>{'action': 'list'});
      expect((list['snapshots'] as List).length, greaterThanOrEqualTo(2));
    });
  });

  group('多模型群聊：内置引擎并发 + 主持人汇总', () {
    test('成员独立作答并由主持人给出汇总', () async {
      final Map<String, dynamic> r = await call('model_group', <String, dynamic>{
        'text': '用一句话说明 2+2 等于几',
        'models': <Map<String, dynamic>>[
          <String, dynamic>{'name': '内置A', 'model_kind': 'builtin'},
          <String, dynamic>{'name': '内置B', 'model_kind': 'builtin'},
        ],
      });
      expect(r['ok'], true);
      expect((r['replies'] as List).length, 2);
      expect(r['succeeded'], greaterThanOrEqualTo(1));
      expect(r['synthesis'].toString().isNotEmpty, true);
    });

    test('空问题 / 无模型如实拒绝', () async {
      expect((await call('model_group', <String, dynamic>{'text': ''}))['ok'], false);
      expect(
        (await call('model_group', <String, dynamic>{
          'text': '问题', 'models': <dynamic>[],
        }))['ok'],
        false,
      );
    });
  });

  group('Agent 应用市场：模板安装 / 导出 / 导入', () {
    test('安装内置模板真实创建工作流与知识库，可导出 JSON', () async {
      final Map<String, dynamic> list =
          await call('app_market', <String, dynamic>{'action': 'list'});
      expect(list['ok'], true);
      final List<dynamic> templates = list['templates'] as List;
      expect(templates, isNotEmpty);
      final Map<String, dynamic> tpl =
          Map<String, dynamic>.from(templates.first as Map);

      final Map<String, dynamic> installed = await call('app_market', <String, dynamic>{
        'action': 'install',
        'package': tpl,
      });
      expect(installed['ok'], true);
      expect((installed['workflow_ids'] as List), isNotEmpty);
      expect((installed['knowledge_ids'] as List), isNotEmpty);
      expect((installed['persona'] as Map)['name'], isNotEmpty);

      final Map<String, dynamic> wfs =
          await call('workflow', <String, dynamic>{'action': 'list'});
      expect((wfs['workflows'] as List), isNotEmpty);
      final Map<String, dynamic> kbs = await call('knowledge_base');
      expect((kbs['libraries'] as List), isNotEmpty);

      final Map<String, dynamic> installedList =
          await call('app_market', <String, dynamic>{'action': 'list'});
      final Map record = (installedList['installed'] as List).first as Map;
      final Map<String, dynamic> exported = await call('app_market', <String, dynamic>{
        'action': 'export',
        'id': record['id'],
      });
      expect(exported['ok'], true);
      expect(exported['json'].toString(), contains('tga-app/1'));

      final Map<String, dynamic> dup = await call('app_market', <String, dynamic>{
        'action': 'install',
        'package': tpl,
      });
      expect(dup['ok'], false);
      expect(dup['error'].toString(), contains('已安装'));
    });

    test('导入最小应用包；错误格式如实拒绝', () async {
      final Map<String, dynamic> pkg = <String, dynamic>{
        'format': 'tga-app/1',
        'name': '导入测试应用',
        'version': '1.0.0',
        'description': '测试',
        'persona': <String, dynamic>{'name': '测试人格'},
        'workflows': <Map<String, dynamic>>[
          <String, dynamic>{
            'name': '导入流程',
            'steps': <Map<String, dynamic>>[
              <String, dynamic>{'name': '步骤', 'type': 'prompt', 'input': '{{input}}'},
            ],
          },
        ],
      };
      final Map<String, dynamic> r = await call('app_market', <String, dynamic>{
        'action': 'import',
        'json': jsonEncode(pkg),
      });
      expect(r['ok'], true);
      final Map<String, dynamic> bad = await call('app_market', <String, dynamic>{
        'action': 'import',
        'json': jsonEncode(<String, dynamic>{'format': 'wrong', 'name': 'x'}),
      });
      expect(bad['ok'], false);
    });
  });

  group('团队协作沙箱：角色权限 / 路径越界 / 审计', () {
    test('viewer 只读、editor 可写、越界路径被拒绝', () async {
      final Map<String, dynamic> created = await call('team_space', <String, dynamic>{
        'action': 'create',
        'name': '测试团队',
        'actor': '我',
      });
      expect(created['ok'], true);
      final String id = (created['space'] as Map)['id'].toString();

      final Map<String, dynamic> added = await call('team_space', <String, dynamic>{
        'action': 'members',
        'id': id,
        'actor': '我',
        'op': 'add',
        'name': '小明',
        'role': 'viewer',
      });
      expect(added['ok'], true);

      final Map<String, dynamic> writeOwner = await call('team_space', <String, dynamic>{
        'action': 'write',
        'id': id,
        'actor': '我',
        'path': 'docs/plan.md',
        'text': '# 团队计划\n真实内容',
      });
      expect(writeOwner['ok'], true);

      final Map<String, dynamic> readViewer = await call('team_space', <String, dynamic>{
        'action': 'read',
        'id': id,
        'actor': '小明',
        'path': 'docs/plan.md',
      });
      expect(readViewer['ok'], true);
      expect(readViewer['text'].toString(), contains('真实内容'));

      final Map<String, dynamic> writeViewer = await call('team_space', <String, dynamic>{
        'action': 'write',
        'id': id,
        'actor': '小明',
        'path': 'docs/hack.md',
        'text': '不该成功',
      });
      expect(writeViewer['ok'], false);

      await call('team_space', <String, dynamic>{
        'action': 'set_role',
        'id': id,
        'actor': '我',
        'name': '小明',
        'role': 'editor',
      });
      final Map<String, dynamic> writeEditor = await call('team_space', <String, dynamic>{
        'action': 'write',
        'id': id,
        'actor': '小明',
        'path': 'docs/hack.md',
        'text': '现在可以写',
      });
      expect(writeEditor['ok'], true);

      final Map<String, dynamic> traversal = await call('team_space', <String, dynamic>{
        'action': 'write',
        'id': id,
        'actor': '我',
        'path': '../escape.txt',
        'text': '越界',
      });
      expect(traversal['ok'], false);

      final Map<String, dynamic> audit = await call('team_space', <String, dynamic>{
        'action': 'audit',
        'id': id,
      });
      expect((audit['audit'] as List).length, greaterThan(0));
      final Map first = (audit['audit'] as List).first as Map;
      expect(first['actor'], isNotEmpty);
      expect(first['action'], isNotEmpty);
    });
  });

  group('Super Agent：优先级协商 / 上下文分级 / 阶段复盘', () {
    test('优先级可协商并返回队列位置与影响预估', () async {
      final SuperAgent sa = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async => <String, dynamic>{
          'ok': true,
          'engine': 'remote-http',
          'reply': '结果 ${DateTime.now().microsecondsSinceEpoch}',
        },
      );
      await sa.init();
      await sa.handle('set_policy', <String, dynamic>{'max_workers': 1});
      final Map<String, dynamic> a = await sa.handle(
          'create_direct', <String, dynamic>{'goal': '低优先级任务', 'priority': 1});
      final Map<String, dynamic> b = await sa.handle(
          'create_direct', <String, dynamic>{'goal': '高优先级任务', 'priority': 1});
      final String idB = b['id'].toString();
      final Map<String, dynamic> set = await sa.handle(
          'set_priority', <String, dynamic>{'id': idB, 'priority': 9});
      expect(set['ok'], true);
      expect(set['priority'], 9);
      expect(set['impact'].toString().isNotEmpty, true);
      final Map<String, dynamic> queue =
          await sa.handle('queue', <String, dynamic>{});
      expect(queue['capacity'], 1);
      expect(queue['queued'], isA<List>());
      expect(a['ok'], true);
    });

    test('暂停 / 恢复 / 延后 / 非法状态如实返回', () async {
      final SuperAgent sa = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async => <String, dynamic>{
          'ok': true, 'engine': 'remote-http', 'reply': 'ok',
        },
      );
      await sa.init();
      await sa.handle('set_policy', <String, dynamic>{'max_workers': 1});
      final Map<String, dynamic> c = await sa.handle(
          'create_direct', <String, dynamic>{
        'goal': '待暂停任务',
        'not_before': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      });
      final String id = c['id'].toString();
      final Map<String, dynamic> pause =
          await sa.handle('pause', <String, dynamic>{'id': id});
      expect(pause['ok'], true);
      expect(pause['status'], 'paused');
      final Map<String, dynamic> defer =
          await sa.handle('defer', <String, dynamic>{'id': id, 'seconds': 3600});
      expect(defer['ok'], true);
      expect(defer['not_before'].toString().isNotEmpty, true);
      final Map<String, dynamic> resume =
          await sa.handle('resume', <String, dynamic>{'id': id});
      expect(resume['ok'], true);
      final Map<String, dynamic> bad =
          await sa.handle('pause', <String, dynamic>{'id': 'missing'});
      expect(bad['ok'], false);
    });

    test('上下文分级返回 inline / spill 统计；复盘记录真实落盘', () async {
      final SuperAgent sa = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async => <String, dynamic>{
          'ok': true,
          'engine': 'remote-http',
          'reply': '步骤输出 ${DateTime.now().microsecondsSinceEpoch}',
        },
      );
      await sa.init();
      await sa.handle('set_policy', <String, dynamic>{
        'default_max_steps': 20,
        'auto_review': false,
      });
      final Map<String, dynamic> c = await sa.handle(
          'create_direct', <String, dynamic>{
        'goal': '长任务上下文测试',
        'mandate': <String, dynamic>{'max_steps': 20},
      });
      final String id = c['id'].toString();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final Map<String, dynamic> ctx =
          await sa.handle('context', <String, dynamic>{'id': id});
      expect(ctx['ok'], true);
      expect(ctx['spill_refs'], isA<List>());
      expect((ctx['inline'] as int) <= 20, true);

      final Map<String, dynamic> review =
          await sa.handle('review', <String, dynamic>{'id': id});
      expect(review['ok'], true);
      expect((review['review'] as Map)['verdict'].toString().isNotEmpty, true);
      final Map<String, dynamic> reviews =
          await sa.handle('reviews', <String, dynamic>{});
      expect((reviews['reviews'] as List), isNotEmpty);
    });
  });
}
