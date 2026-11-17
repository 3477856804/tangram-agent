/// 多角色子 Agent 绑定：executionEnabled 门禁、独立记忆注入与写入。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/super_agent.dart';
import 'package:tangram/services/agent_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tga_agent_bind_');
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('未开启独立执行拒绝；开启后子工单读取并写入角色记忆', () async {
    final List<String> prompts = <String>[];
    final SuperAgent sa = SuperAgent(
      store: store,
      chat: (Map<String, dynamic> p) async {
        prompts.add((p['text'] ?? '').toString());
        return <String, dynamic>{
          'ok': true,
          'engine': 'remote-http',
          'reply': '第 ${prompts.length} 步真实结果',
        };
      },
    );
    await sa.init();
    final Map<String, dynamic> created = await sa.handle(
        'create_direct', <String, dynamic>{'goal': '父任务：排查登录失败'});
    final String parentId = created['id'].toString();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final Map<String, dynamic> denied = await sa.handle('subagent', <String, dynamic>{
      'id': parentId,
      'goal': '子任务：检查 token',
      'agent': <String, dynamic>{
        'id': 'agent-a',
        'name': 'Auth 助手',
        'executionEnabled': false,
      },
    });
    expect(denied['ok'], false);
    expect(denied['error'].toString(), contains('未开启独立执行'));

    // 预置一条角色记忆，确认会进入 Worker prompt。
    await AgentMemory(store, 'agent-a').append('user', '历史：401 多由 token 过期导致');

    final Map<String, dynamic> ok = await sa.handle('subagent', <String, dynamic>{
      'id': parentId,
      'goal': '子任务：检查 token 刷新',
      'agent': <String, dynamic>{
        'id': 'agent-a',
        'name': 'Auth 助手',
        'role': 'reviewer',
        'executionEnabled': true,
        'memoryScope': 'isolated',
      },
    });
    expect(ok['ok'], true, reason: '${ok['error']}');
    final Map ticket = ok['ticket'] as Map;
    expect(ticket['agent_id'], 'agent-a');
    expect(ticket['agent_name'], 'Auth 助手');
    expect(ticket['agent_memory_scope'], 'isolated');

    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(prompts.any((String p) => p.contains('独立记忆')), true);
    expect(prompts.any((String p) => p.contains('token 过期')), true);

    final List<Map<String, dynamic>> memory =
        await AgentMemory(store, 'agent-a').recent(20);
    expect(memory.any((Map<String, dynamic> m) =>
        m['role'] == 'user' && m['text'].toString().contains('401')), true);
    expect(memory.any((Map<String, dynamic> m) => m['role'] == 'assistant'), true);
  });
}
