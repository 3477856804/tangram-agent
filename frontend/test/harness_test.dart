/// Tangram Harness 真实行为测试。
///
/// 遵守参考 harness 的验证规范：test/ 镜像实现、真实落盘、逐域断言，
/// 不使用任何 mock 数据冒充响应。

library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/agent/sandbox/sandboxed_shell.dart';
import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/services/model_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;
  late EmbeddedBackend backend;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_harness_test_');
    for (final sub in <String>['models', 'cards', 'plugins', 'work',
        'downloads', 'sandbox']) {
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

  Future<Map<String, dynamic>> call(String topic,
      [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final reply = await backend.dispatch(topic, payload);
    return reply.payload;
  }

  group('SafeExpression（抄 appsup-dart/expressions 语义）', () {
    test('算术与优先级', () {
      expect(SafeExpression.eval('2 + 3 * 4'), 14);
      expect(SafeExpression.eval('(2 + 3) * 4'), 20);
      expect(SafeExpression.eval('10 / 4'), 2.5);
      expect(SafeExpression.eval('7 % 3'), 1);
    });

    test('比较 / 逻辑 / 三元', () {
      expect(SafeExpression.eval('3 > 2 && 1 < 2'), true);
      expect(SafeExpression.eval('5 == 5 ? "yes" : "no"'), 'yes');
      expect(SafeExpression.eval('!false'), true);
    });

    test('白名单纯函数', () {
      expect(SafeExpression.eval('sqrt(144)'), 12);
      expect(SafeExpression.eval('max(3, 9)'), 9);
      expect(SafeExpression.eval('abs(-7)'), 7);
      expect(SafeExpression.eval('upper("ok")'), 'OK');
    });

    test('拒绝副作用语法', () {
      expect(() => SafeExpression.eval('import os'), throwsA(isA<ExpressionException>()));
      expect(() => SafeExpression.eval('__import__("os")'),
          throwsA(isA<ExpressionException>()));
      expect(() => SafeExpression.eval('1; 2'), throwsA(isA<ExpressionException>()));
      expect(() => SafeExpression.eval('1 / 0'), throwsA(isA<ExpressionException>()));
    });
  });

  group('CancelToken / ToolRegistry（抄 flutter_agent_harness）', () {
    test('协作取消同步生效', () {
      final src = CancelTokenSource();
      expect(src.token.isCancelled, isFalse);
      src.cancel('stop');
      expect(src.token.isCancelled, isTrue);
      expect(src.token.cancelReason, 'stop');
      expect(() => src.token.throwIfCancelled(),
          throwsA(isA<CancelledException>()));
    });

    test('三段式：未知工具 / 参数校验 / 执行，异常不逃逸', () async {
      final registry = ToolRegistry(<AgentTool>[
        AgentTool(
          name: 'double',
          description: 'x2',
          parameters: <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'n': <String, dynamic>{'type': 'integer'},
            },
            'required': <String>['n'],
          },
          execute: (args, _) async => ToolResult.ok('${(args['n'] as int) * 2}'),
        ),
      ]);
      expect((await registry.run('double', <String, dynamic>{'n': 21})).content, '42');
      // 缺参数：转成 error 结果，而不是抛异常逃逸。
      final missing = await registry.run('double', <String, dynamic>{});
      expect(missing.ok, isFalse);
      expect(missing.error, contains('必填参数'));
      // 类型错误：同样转成 error。
      final wrongType = await registry.run('double', <String, dynamic>{'n': 'x'});
      expect(wrongType.ok, isFalse);
      // 未知工具：转成 error，循环不崩溃。
      expect((await registry.run('nope', <String, dynamic>{})).ok, isFalse);
    });

    test('轨迹快照不可变追加', () {
      final t = TrajectorySnapshot('goal')
          .append(TrajectoryCellKind.user, 'hi')
          .append(TrajectoryCellKind.result, 'ok');
      expect(t.length, 2);
      expect(t.exportMarkdown(), contains('user'));
    });
  });

  group('控制域逐域真实返回', () {
    test('capability_negotiation 声明真实能力，不谎称 Python', () async {
      final r = await call('capability_negotiation');
      expect(r['ok'], true);
      expect(r['version'], '0.0.1');
      expect(r['transport'], 'in-process-dart');
      expect(r['python'], 'not-used');
      expect((r['control_domains'] as List).length, greaterThan(15));
      expect((r['tools'] as List), isNotEmpty);
    });

    test('rpc: sandbox_policy 有真实 gates', () async {
      final r = await call('rpc', <String, dynamic>{'action': 'sandbox_policy'});
      expect(r['gates'], isA<Map>());
    });

    test('rpc: selftest 全部通过', () async {
      final r = await call('rpc', <String, dynamic>{'action': 'selftest'});
      expect(r['ok'], true, reason: '${r['checks']}');
      expect(r['status'], 'ok');
    });

    test('rpc: active 无模型时如实返回空列表', () async {
      final r = await call('rpc', <String, dynamic>{'action': 'active'});
      expect(r['models'], isA<List>());
    });

    test('chat: 表达式问法真实求值', () async {
      final r = await call('agent_command', <String, dynamic>{'text': '计算 12 * (3 + 4)'});
      expect(r['ok'], true);
      expect(r['reply'].toString(), contains('84'));
      expect(r['engine'], 'builtin-agent-loop');
    });

    test('chat: /help 列出真实工具', () async {
      final r = await call('chat', <String, dynamic>{'text': '/help'});
      expect(r['reply'].toString(), contains('evaluate'));
    });

    test('chat: 记忆真实落盘并可检索', () async {
      await call('chat', <String, dynamic>{'text': '/remember 檀阁瑞木项目截止周五'});
      final r = await call('chat', <String, dynamic>{'text': '/recall 檀阁瑞木'});
      expect(r['reply'].toString(), contains('檀阁瑞木'));
    });

    test('chat: 空消息如实报错', () async {
      final r = await call('chat', <String, dynamic>{'text': '   '});
      expect(r['ok'], isFalse);
    });

    test('chat: 附件内容真实解析并统计，不伪造', () async {
      const String text = '[附件] note.txt（text/plain，36 B）\n'
          '--- 文件内容 ---\n'
          '第一行\n第二行\n第三行\n'
          '--- 内容结束 ---';
      final r = await call('chat', <String, dynamic>{'text': text});
      final String reply = r['reply'].toString();
      expect(reply, contains('附件已接收并真实解析'));
      expect(reply, contains('note.txt'));
      expect(reply, contains('文本行数：3'));
      expect(reply, contains('字符数：'));
    });

    test('chat: 二进制附件只登记元信息，不伪造文本', () async {
      const String text = '[附件] photo.jpg（image/jpeg，2.0 MB）\n'
          '（二进制或不可解码附件：仅登记元信息，不伪造文本内容。）';
      final r = await call('chat', <String, dynamic>{'text': text});
      final String reply = r['reply'].toString();
      expect(reply, contains('仅登记元信息'));
      expect(reply, isNot(contains('文本行数')));
    });

    test('memory_event: 日记按天聚合真实轮次', () async {
      await call('chat', <String, dynamic>{'text': '/remember 今天做了自检'});
      final r = await call('memory_event', <String, dynamic>{'action': 'diary'});
      expect((r['days'] as List), isNotEmpty);
    });

    test('proactive_task: 增删改查真实持久化', () async {
      final added = await call('proactive_task', <String, dynamic>{
        'action': 'add', 'title': '每小时检查'
      });
      expect(added['ok'], true);
      final list = await call('proactive_task', <String, dynamic>{'action': 'list'});
      expect((list['rules'] as List).any((x) => x['name'] == '每小时检查'), true);
    });

    test('security_approval: 审批真实落盘', () async {
      final req = await call('security_approval', <String, dynamic>{
        'action': 'request', 'name': '删除文件'
      });
      final id = req['id'];
      final done = await call('security_approval', <String, dynamic>{
        'action': 'approve', 'id': id,
      });
      expect(done['ok'], true);
      final list = await call('security_approval', <String, dynamic>{'action': 'list'});
      expect((list['approvals'] as List).first['status'], 'approved');
    });

    test('im_event: 未配置凭据时不谎称已连接', () async {
      final r = await call('im_event', <String, dynamic>{'action': 'connect', 'connector': 'QQ'});
      expect(r['ok'], isFalse);
      expect(r['error'].toString(), contains('未配置'));
    });

    test('distill: 无权重时明确拒绝，不产出假模型', () async {
      final r = await call('distill', <String, dynamic>{'action': 'distill'});
      expect(r['ok'], isFalse);
      expect(r['error'].toString(), contains('不会伪造'));
    });

    test('distill: describe 报告真实轨迹数', () async {
      final r = await call('distill', <String, dynamic>{'action': 'describe'});
      final data = r['data'] as Map;
      expect(data['version'], '0.0.1');
      expect(data['harness']['backend'], 'pure-dart-in-process');
    });

    test('device_file: 写入后读取真实内容', () async {
      final w = await call('device_file', <String, dynamic>{
        'action': 'write',
        'args': <String, dynamic>{'path': 'note.txt', 'content': 'hello'},
      });
      expect(w['ok'], true);
      final r = await call('device_file', <String, dynamic>{
        'action': 'read',
        'args': <String, dynamic>{'path': 'note.txt'},
      });
      expect((r['data'] as Map)['content'], 'hello');
    });

    test('device_file: 路径越界被拒绝', () async {
      final r = await call('device_file', <String, dynamic>{
        'action': 'read',
        'args': <String, dynamic>{'path': '../../etc/passwd'},
      });
      expect(r['ok'], isFalse);
    });

    test('model_store: catalog 是真实内置目录', () async {
      final r = await call('model_store', <String, dynamic>{'action': 'catalog'});
      expect((r['models'] as List), isNotEmpty);
      expect((r['models'] as List).first['url'].toString(), startsWith('https://'));
    });

    test('model_route: 空版本池如实返回空，激活不存在的版本失败', () async {
      final list = await call('model_route', <String, dynamic>{'action': 'list'});
      expect(list['versions'], isA<List>());
      final act = await call('model_route', <String, dynamic>{
        'action': 'activate', 'tag': 'not-exist',
      });
      expect(act['ok'], isFalse);
    });

    test('plugin_community: 内置技能目录真实可读', () async {
      final r = await call('plugin_community', <String, dynamic>{'action': 'catalog'});
      expect((r['items'] as List), isNotEmpty);
    });

    test('未知控制域返回结构化错误而非崩溃', () async {
      final r = await call('no_such_domain');
      expect(r['ok'], isFalse);
      expect(r['error'].toString(), contains('未知控制域'));
    });
  });

  group('内置沙箱执行链路（回归：_atEnd 哨兵误判）', () {
    test('exec(run_test) 全部通过，不再是 3 通过/3 失败', () async {
      final shell = SandboxedShell.instance;
      await shell.ensureLoaded();
      expect(shell.loaded, isTrue, reason: shell.loadError ?? '契约未加载');
      final r = await shell.exec('run_test');
      expect(r.ok, isTrue, reason: r.stdout + r.error.toString());
      expect(r.stdout, contains('全部通过'));
      expect(r.stdout, isNot(contains('存在失败')));
    });

    test('exec(eval_expression) 正确求值算术/括号/比较', () async {
      final shell = SandboxedShell.instance;
      await shell.ensureLoaded();
      final r = await shell.exec(
        'eval_expression',
        <String, dynamic>{'expression': '(2+3)*4'},
      );
      expect(r.ok, isTrue, reason: r.error.toString());
      expect(r.stdout, contains('20'));
    });
  });

  group('模型注册表：用户添加的模型真实出现在选择器', () {
    test('空态 = 内置免费云端模型（Kilo）+ 内置引擎，兜底标记（本地）', () async {
      final reg = await ModelRegistry.forTest(store);
      expect(reg.entries.length, 1 + kBuiltinFreeModels.length);
      expect(reg.entries.last.builtin, isTrue);
      expect(reg.entries.first.free, isTrue);
      expect(reg.selected.displayName, contains('（本地）'));
      expect(reg.chatParams()['model_kind'], 'builtin');
    });

    test('内置免费模型可选：chatParams 带真实 base/model、free 标记且无需密钥',
        () async {
      final reg = await ModelRegistry.forTest(store);
      final free = kBuiltinFreeModels.first;
      await reg.setSelected(free.id);
      expect(reg.selectedId, free.id);
      final p = reg.chatParams();
      expect(p['api_base'], 'https://api.kilo.ai/api/gateway');
      expect(p['model'], free.modelId);
      expect(p['model_kind'], 'cloud');
      expect(p['free'], isTrue);
      expect(p['api_key'], isEmpty);
    });

    test('保存 API →（云端）+ 自动选中 + chatParams 携带真实凭据', () async {
      final reg = await ModelRegistry.forTest(store);
      final err = await reg.addCloud(
        name: 'deepseek-chat',
        apiBase: 'https://api.deepseek.com/v1/',
        apiKey: 'sk-test-123',
        modelId: 'deepseek-chat',
      );
      expect(err, isNull);
      expect(reg.cloudEntries.length, 1);
      expect(reg.cloudEntries.first.displayName, 'deepseek-chat（云端）');
      expect(reg.selectedId, reg.cloudEntries.first.id);
      final p = reg.chatParams();
      expect(p['api_base'], 'https://api.deepseek.com/v1');
      expect(p['api_key'], 'sk-test-123');
      expect(p['model'], 'deepseek-chat');
      expect(p['model_kind'], 'cloud');
    });

    test('云端配置真实落盘，重新加载可恢复', () async {
      final reg = await ModelRegistry.forTest(store);
      await reg.addCloud(
        name: 'qwen-plus',
        apiBase: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
        apiKey: 'k-2',
        modelId: 'qwen-plus',
      );
      final reg2 = await ModelRegistry.forTest(store);
      expect(reg2.cloudEntries.length, 1);
      expect(reg2.cloudEntries.first.displayName, contains('（云端）'));
      expect(reg2.selectedId, reg2.cloudEntries.first.id);
    });

    test('可添加多个厂商云端模型，互不覆盖', () async {
      final reg = await ModelRegistry.forTest(store);
      await reg.addCloud(name: 'a', apiBase: 'https://a.example/v1',
          apiKey: 'k', modelId: 'm1');
      await reg.addCloud(name: 'b', apiBase: 'https://b.example/v1',
          apiKey: 'k', modelId: 'm2');
      expect(reg.cloudEntries.length, 2);
      expect(reg.cloudEntries.map((e) => e.displayName),
          everyElement(contains('（云端）')));
    });

    test('已下载 GGUF/BIN 真实文件 →（本地）；.part 分片不计入', () async {
      await File('${tmp.path}/downloads/qwen.gguf')
          .writeAsBytes(List<int>.filled(1024, 0));
      await File('${tmp.path}/downloads/big.gguf.part0')
          .writeAsBytes(List<int>.filled(512, 0));
      await File('${tmp.path}/models/tiny.bin')
          .writeAsBytes(List<int>.filled(2048, 0));
      final reg = await ModelRegistry.forTest(store);
      expect(reg.localEntries.length, 2);
      expect(reg.localEntries.map((e) => e.displayName),
          everyElement(contains('（本地）')));
      expect(reg.localEntries.map((e) => e.name).join(),
          isNot(contains('.part')));
      expect(reg.localEntries.first.kind, ModelKind.local);
    });

    test('选中本地权重 → chatParams 带真实路径，绝不带 API 凭据', () async {
      await File('${tmp.path}/downloads/qwen.gguf')
          .writeAsBytes(List<int>.filled(10, 0));
      final reg = await ModelRegistry.forTest(store);
      final local = reg.localEntries.single;
      await reg.setSelected(local.id);
      final p = reg.chatParams();
      expect(p['model_kind'], 'local');
      expect(p['local_model_path'], local.path);
      expect(p.containsKey('api_key'), isFalse);
      expect(p.containsKey('api_base'), isFalse);
    });

    test('删除云端模型后诚实回退内置引擎', () async {
      final reg = await ModelRegistry.forTest(store);
      await reg.addCloud(name: 'x', apiBase: 'https://x.example/v1',
          apiKey: 'k', modelId: 'm');
      final id = reg.cloudEntries.single.id;
      await reg.removeCloud(id);
      expect(reg.cloudEntries, isEmpty);
      expect(reg.selected.builtin, isTrue);
      expect(reg.chatParams()['model_kind'], 'builtin');
    });

    test('缺 Base/Key/模型名时拒绝保存，不产生假条目', () async {
      final reg = await ModelRegistry.forTest(store);
      expect(
        await reg.addCloud(name: 'x', apiBase: '', apiKey: 'k', modelId: 'm'),
        contains('Base URL'),
      );
      expect(
        await reg.addCloud(name: 'x', apiBase: 'b', apiKey: '', modelId: 'm'),
        contains('API Key'),
      );
      expect(
        await reg.addCloud(name: 'x', apiBase: 'b', apiKey: 'k', modelId: ''),
        contains('模型名称'),
      );
      expect(reg.cloudEntries, isEmpty);
    });

    test('chat 携带云端凭据 → 真实进入 HTTP 推理分支（失败也如实回报）',
        () async {
      // 127.0.0.1:1 会立即拒绝连接，验证确实发起了真实网络调用，
      // 而不是悄悄回退到内置引擎；同时不产生 30s 等待。
      final r = await call('chat', <String, dynamic>{
        'text': 'hi',
        'api_base': 'http://127.0.0.1:1/v1',
        'api_key': 'k',
        'model': 'm',
        'temperature': 0.3,
        'max_tokens': 128,
        'system': '你是助手',
      });
      expect(r['engine'], 'remote-failed');
      expect(r['reply'].toString(), contains('外部推理调用失败'));
    });
  });
}
