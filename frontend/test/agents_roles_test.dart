/// 多角色子 Agent：字段持久化 / 兼容 / 权限校验 / 对话注入边界 / 独立记忆。
///
/// 全部使用真实临时目录与真实 JSON 落盘，不 mock 存储、不伪造结果。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/services/agent_memory.dart';
import 'package:tangram/services/agents_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore harness;
  late AgentsStore agents;
  late String agentsPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_agents_');
    HarnessStore.overrideForTest(tmp);
    harness = await HarnessStore.instance();
    agentsPath = '${tmp.path}/agents.json';
    agents = await AgentsStore.openAt(agentsPath);
    AgentsStore.overrideForTest(agents);
  });

  tearDown(() async {
    AgentsStore.overrideForTest(null);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // 后台落盘竞态不影响断言。
    }
  });

  Map<String, dynamic> fullPermissions() => <String, dynamic>{
        'tools': <String, dynamic>{
          'allow': <String>['read_file'],
          'ask': <String>['write_file'],
          'deny': <String>['shell'],
        },
        'files': r'^workspace/.*',
        'note': '只处理工作区内的文件',
      };

  group('TgaAgent 字段与旧数据兼容', () {
    test('旧 agents.json 缺字段时回退默认值', () async {
      final String legacyPath = '${tmp.path}/agents_legacy.json';
      await File(legacyPath).writeAsString(jsonEncode(<dynamic>[
        <String, dynamic>{
          'id': 'old-1',
          'name': '旧智能体',
          'description': '旧版只有四个字段',
          'systemPrompt': '你是旧版人设。',
          'enabled': true,
        },
      ]));
      final AgentsStore legacy = await AgentsStore.openAt(legacyPath);
      final TgaAgent a = legacy.resolve('old-1')!;
      expect(a.name, '旧智能体');
      expect(a.enabled, true);
      expect(a.role, isNull);
      expect(a.knowledgeIds, isEmpty);
      expect(a.maxSteps, TgaAgent.defaultMaxSteps);
      expect(a.executionEnabled, false);
      expect(a.modelId, isNull);
      expect(a.memoryScope, TgaAgent.scopeIsolated);
      expect(a.updatedAt, 0);
      expect(a.permissions['tools'], isA<Map>());
      expect(
          ((a.permissions['tools'] as Map)['deny'] as List).contains('*'), true);
    });

    test('create / update 持久化角色、知识库、权限、步数、模型与记忆作用域',
        () async {
      final TgaAgent created = await agents.create(
        name: '研究员',
        description: '负责资料检索',
        systemPrompt: '你是严谨的研究员。',
        role: 'researcher',
        knowledgeIds: <String>['kb-1', 'kb-1', 'kb-2'],
        permissions: fullPermissions(),
        maxSteps: 12,
        executionEnabled: true,
        modelId: 'qwen2.5-7b',
        memoryScope: TgaAgent.scopeShared,
      );
      expect(created.knowledgeIds, <String>['kb-1', 'kb-2']);
      expect(created.maxSteps, 12);
      expect(created.updatedAt > 0, true);

      final AgentsStore reloaded = await AgentsStore.openAt(agentsPath);
      final TgaAgent a = reloaded.resolve(created.id)!;
      expect(a.role, 'researcher');
      expect(a.knowledgeIds, <String>['kb-1', 'kb-2']);
      expect(a.permissions['files'], r'^workspace/.*');
      expect(((a.permissions['tools'] as Map)['allow'] as List), <String>['read_file']);
      expect(a.maxSteps, 12);
      expect(a.executionEnabled, true);
      expect(a.modelId, 'qwen2.5-7b');
      expect(a.memoryScope, TgaAgent.scopeShared);
      expect(a.updatedAt > 0, true);

      await agents.update(created.copyWith(
        role: 'writer',
        knowledgeIds: <String>['kb-9'],
        permissions: <String, dynamic>{
          'tools': <String, dynamic>{
            'allow': <String>['read_file', 'write_file'],
            'ask': <String>[],
            'deny': <String>['shell'],
          },
          'files': r'^workspace/docs/.*',
          'note': '只写文档',
        },
        maxSteps: 15,
        executionEnabled: false,
        modelId: 'qwen3-14b',
        memoryScope: TgaAgent.scopeIsolated,
      ));
      final AgentsStore reloaded2 = await AgentsStore.openAt(agentsPath);
      final TgaAgent b = reloaded2.resolve(created.id)!;
      expect(b.role, 'writer');
      expect(b.knowledgeIds, <String>['kb-9']);
      expect(b.permissions['files'], r'^workspace/docs/.*');
      expect(b.maxSteps, 15);
      expect(b.executionEnabled, false);
      expect(b.modelId, 'qwen3-14b');
      expect(b.memoryScope, TgaAgent.scopeIsolated);
    });

    test('maxSteps 越界被 clamp 到 1~20', () async {
      final TgaAgent high = await agents.create(name: '高步数', maxSteps: 99);
      final TgaAgent low = await agents.create(name: '低步数', maxSteps: -3);
      expect(high.maxSteps, 20);
      expect(low.maxSteps, 1);
      expect(high.copyWith(maxSteps: 0).maxSteps, 1);
      expect(low.copyWith(maxSteps: 100).maxSteps, 20);
      expect(
          TgaAgent.fromJson(<String, dynamic>{
            'id': 'x',
            'name': 'x',
            'maxSteps': 999,
          }).maxSteps,
          20);
      expect(
          TgaAgent.fromJson(<String, dynamic>{
            'id': 'x',
            'name': 'x',
            'maxSteps': 0,
          }).maxSteps,
          1);
    });

    test('空名称与非法权限结构被拒绝且不写入', () async {
      await expectLater(agents.create(name: '   '), throwsArgumentError);
      await expectLater(
        agents.create(
          name: '坏权限',
          permissions: <String, dynamic>{'tools': 'not-a-map'},
        ),
        throwsArgumentError,
      );
      await expectLater(
        agents.create(
          name: '坏正则',
          permissions: <String, dynamic>{'files': '[unclosed'},
        ),
        throwsArgumentError,
      );
      await expectLater(
        agents.create(
          name: '冲突权限',
          permissions: <String, dynamic>{
            'tools': <String, dynamic>{
              'allow': <String>['shell'],
              'deny': <String>['shell'],
            },
          },
        ),
        throwsArgumentError,
      );
      expect(agents.agents, isEmpty);

      final TgaAgent ok = await agents.create(name: '合法智能体');
      await expectLater(
        agents.update(ok.copyWith(
          permissions: <String, dynamic>{'tools': 'bad-after-copy'},
        )),
        throwsArgumentError,
      );
      expect(agents.resolve(ok.id)!.permissions['tools'], isA<Map>());
      expect(agents.agents.length, 1);
      await agents.remove(ok.id);

      final Map<String, dynamic> badImport =
          await agents.importJson('{not json');
      expect(badImport['ok'], false);
      final Map<String, dynamic> badPermissionImport =
          await agents.importJson(jsonEncode(<dynamic>[
        <String, dynamic>{
          'name': '导入坏权限',
          'permissions': <String, dynamic>{'tools': 'nope'},
        },
      ]));
      expect(badPermissionImport['ok'], false);
      expect(agents.agents, isEmpty);
    });
  });

  group('对话注入边界', () {
    test('只注入 enabled，executionEnabled 不影响注入且不泄露文件路径', () async {
      final TgaAgent a = await agents.create(
        name: '甲',
        systemPrompt: '甲的人设。',
        role: 'researcher',
        executionEnabled: false,
        permissions: <String, dynamic>{
          'tools': <String, dynamic>{
            'allow': <String>['read_file'],
            'ask': <String>[],
            'deny': <String>['shell'],
          },
          'files': r'^/home/alice/secret/.*',
          'note': '/home/alice/secret 下的内容',
        },
      );
      final TgaAgent b = await agents.create(
        name: '乙',
        systemPrompt: '乙的人设。',
        executionEnabled: true,
      );
      await agents.setEnabled(b.id, false);

      final String block = await AgentsStore.enabledSystemPromptBlock();
      expect(block, contains('甲的人设。'));
      expect(block, isNot(contains('乙的人设。')));
      expect(block, contains('researcher'));
      expect(block, contains('权限边界'));
      expect(block, isNot(contains('/home/alice')));
      expect(block, isNot(contains('secret')));

      final String beforeToggle =
          await AgentsStore.enabledSystemPromptBlock();
      await agents.setExecution(a.id, true);
      expect(await AgentsStore.enabledSystemPromptBlock(), beforeToggle);
      expect((await AgentsStore.enabledSystemPromptBlock()),
          isNot(contains('乙的人设。')));

      final Map<String, dynamic> roundTrip = await agents.importJson(
          agents.exportJson());
      expect(roundTrip['ok'], true);
      expect(agents.agents.length, 2);
    });
  });

  group('AgentMemory 独立记忆', () {
    test('isolated 不串 agent，检索命中/无命中', () async {
      final AgentMemory m1 = AgentMemory(harness, 'agent-1');
      final AgentMemory m2 = AgentMemory(harness, 'agent-2');
      await m1.append('user', '项目代号是青鸟计划，负责人是林舟。');
      await m1.append('assistant', '收下了，愿意帮你盯 BM25 检索。');

      expect((await m1.recent(10)).length, 2);
      expect(await m2.recent(10), isEmpty);
      expect(await m1.search('青鸟', 5), isNotEmpty);
      expect((await m1.search('青鸟', 5)).first['text'], contains('青鸟'));
      expect(await m1.search('BM25', 5), isNotEmpty);
      expect(await m1.search('量子纠缠', 5), isEmpty);
      expect(await m2.search('青鸟', 5), isEmpty);
      expect(await File('${tmp.path}/agent_memory/agent-1.json').exists(), true);
      expect(await File('${tmp.path}/agent_memory/agent-2.json').exists(), false);
    });

    test('sharedView 只读全局 turns，isolated 不可用', () async {
      await harness.writeRecords('turns', <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'role': 'user', 'text': '全局记录一'},
        <String, dynamic>{'id': 2, 'role': 'user', 'text': '全局记录二'},
      ]);
      final AgentMemory isolated = AgentMemory(harness, 'agent-x');
      await expectLater(isolated.sharedView(), throwsStateError);

      final AgentMemory shared =
          AgentMemory(harness, 'agent-x', memoryScope: 'shared');
      final List<Map<String, dynamic>> view =
          await shared.sharedView(limit: 1);
      expect(view.length, 1);
      expect(view.single['text'], '全局记录二');

      await shared.append('assistant', '只写自己的记忆');
      final List<Map<String, dynamic>> turns =
          await harness.readRecords('turns');
      expect(turns.length, 2);
      expect(turns.last['text'], '全局记录二');
      expect((await shared.recent(10)).length, 1);
    });

    test('clear 真清空，snapshot / restore 可恢复', () async {
      final AgentMemory memory = AgentMemory(harness, 'agent-clear');
      await memory.append('user', '第一条');
      await memory.append('assistant', '第二条');
      final Map<String, dynamic> snap = await memory.snapshot();
      expect((snap['entries'] as List).length, 2);

      expect(await memory.clear(), 2);
      expect(await memory.recent(10), isEmpty);
      final AgentMemory reread = AgentMemory(harness, 'agent-clear');
      expect(await reread.recent(10), isEmpty);

      final int restored = await memory.restore(snap);
      expect(restored, 2);
      final List<Map<String, dynamic>> after = await memory.recent(10);
      expect(after.map((Map<String, dynamic> e) => e['text']).toList(),
          <String>['第一条', '第二条']);
    });

    test('超过条数上限按时间裁剪，落盘结果同样受限', () async {
      final AgentMemory memory = AgentMemory(harness, 'agent-limit');
      for (int i = 0; i < AgentMemory.maxEntries + 5; i++) {
        await memory.append('note', '记录 $i');
      }
      final List<Map<String, dynamic>> recent = await memory.recent(1000);
      expect(recent.length, AgentMemory.maxEntries);
      expect(recent.first['text'], '记录 5');
      expect(recent.last['text'], '记录 ${AgentMemory.maxEntries + 4}');

      final AgentMemory reread = AgentMemory(harness, 'agent-limit');
      expect((await reread.recent(1000)).length, AgentMemory.maxEntries);
      expect((await reread.recent(1000)).first['text'], '记录 5');
    });

    test('非法输入与跨 agent 快照恢复被拒绝', () async {
      final AgentMemory memory = AgentMemory(harness, 'agent-guard');
      await expectLater(memory.append('', '内容'), throwsArgumentError);
      await expectLater(memory.append('user', '   '), throwsArgumentError);
      await expectLater(
        memory.restore(<String, dynamic>{
          'agent_id': 'another-agent',
          'entries': <dynamic>[],
        }),
        throwsArgumentError,
      );
    });
  });
}
