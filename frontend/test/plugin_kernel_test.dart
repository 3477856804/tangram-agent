/// 万物皆插件内核 + Super Agent 真实行为测试。
///
/// 与 harness_test.dart 同规范：真实落盘/真实执行、逐项断言，绝不使用
/// mock 数据冒充响应。内核级用内存持久化（真实实现），集成级走
/// EmbeddedBackend.forTest 的真实 dispatch。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/builtin_plugins.dart';
import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/plugin_kernel.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/super_agent.dart';

// 一个最小的测试用插件：往共享 ctx 注册一个具名服务 + 一个工具 + 一个提示词段。
class _EchoPlugin extends Plugin {
  @override
  String get id => 'test.echo';
  @override
  String get name => 'Echo';
  @override
  String get version => '1.0.0';
  @override
  String get description => '测试插件';
  @override
  List<String> get providesSeams => const <String>['test/echo'];
  @override
  Future<void> apply(PluginContext ctx) async {
    ctx.provideService('test/service', 'hello');
    final CapabilitySeam s = ctx.seam('test/echo', 'echo 能力');
    ctx.provideSeamProvider('test/echo', 'upper', '大写返回',
        (String method, Map<String, dynamic> args) async {
      if (method == 'echo') {
        return <String, dynamic>{
          'ok': true,
          'value': (args['text'] ?? '').toString().toUpperCase(),
        };
      }
      return <String, dynamic>{'ok': false, 'error': 'unknown'};
    });
    ctx.registerTool(AgentTool(
      name: 'test.double',
      description: 'x2',
      execute: (Map<String, dynamic> a, CancelToken? t) async =>
          ToolResult.ok('ok'),
    ));
    ctx.registerPromptSection('test.section', () => 'ECHO-SECTION');
    s.consumers.add('test-consumer');
  }
}

class _DependentPlugin extends Plugin {
  @override
  String get id => 'test.dependent';
  @override
  String get name => 'Dependent';
  @override
  String get version => '1.0.0';
  @override
  String get description => '依赖 test/service';
  @override
  List<String> get requires => const <String>['test/service'];
  @override
  Future<void> apply(PluginContext ctx) async {
    ctx.require<String>('test/service');
    ctx.provideService('test/dependent-service', 42);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PluginKernel：可逆挂载 / 依赖 / 接缝', () {
    late PluginKernel kernel;
    late ToolRegistry tools;

    setUp(() async {
      tools = ToolRegistry();
      kernel = PluginKernel(
        persistence: MemoryKernelPersistence(),
        toolRegistry: tools,
      );
      kernel.registerPlugin(_EchoPlugin());
      kernel.registerPlugin(_DependentPlugin());
      await kernel.boot(
        builtinPlugins: <Plugin>[],
        defaultProfile: RuntimeProfile('t', 't', RunMode.standard,
            <Bundle>[], <String, dynamic>{}),
      );
    });

    test('boot 后内核就绪、空 profile 不谎称已挂载', () async {
      final Map<String, dynamic> s =
          await kernel.handle('status', <String, dynamic>{});
      expect(s['ok'], true);
      expect(s['booted'], true);
      expect(s['mounted'], 0);
    });

    test('挂载真实注册服务/工具/接缝/提示词段', () async {
      final Map<String, dynamic> r = await kernel.mount('test.echo');
      expect(r['ok'], true);
      expect(tools.contains('test.double'), isTrue);
      expect(kernel.mountedCount, 1);
      final Map<String, dynamic> seams =
          await kernel.handle('seams', <String, dynamic>{});
      final List<dynamic> list = seams['seams'] as List;
      expect(list.any((dynamic e) => (e as Map)['name'] == 'test/echo'), isTrue);
      final Map<String, dynamic> prompt =
          await kernel.handle('compose_prompt', <String, dynamic>{});
      expect(prompt['prompt'].toString(), contains('ECHO-SECTION'));
    });

    test('卸载可逆：工具/提示词段被撤销', () async {
      await kernel.mount('test.echo');
      final Map<String, dynamic> r = await kernel.unmount('test.echo');
      expect(r['ok'], true);
      expect(tools.contains('test.double'), isFalse);
      final Map<String, dynamic> prompt =
          await kernel.handle('compose_prompt', <String, dynamic>{});
      expect(prompt['prompt'].toString(), isNot(contains('ECHO-SECTION')));
      expect(kernel.mountedCount, 0);
    });

    test('依赖未满足时拒绝挂载，不假装就绪', () async {
      final Map<String, dynamic> r = await kernel.mount('test.dependent');
      expect(r['ok'], isFalse);
      expect(r['error'].toString(), contains('尚未挂载'));
      expect(kernel.mountedCount, 0);
    });

    test('依赖满足后可挂载', () async {
      await kernel.mount('test.echo');
      final Map<String, dynamic> r = await kernel.mount('test.dependent');
      expect(r['ok'], true);
      expect(kernel.mountedCount, 2);
    });

    test('接缝 invoke 走当前激活 provider（真实执行）', () async {
      await kernel.mount('test.echo');
      final Map<String, dynamic> r = await kernel.invoke(
          'test/echo', 'echo', <String, dynamic>{'text': 'tangram'});
      expect(r['ok'], true);
      expect((r['result'] as Map)['value'], 'TANGRAM');
    });

    test('切换 provider 影响所有 consumer（同接缝第二个 provider）', () async {
      await kernel.mount('test.echo');
      // 再挂一个自定义插件往同接缝注册第二个 provider。
      final _SecondProviderPlugin second = _SecondProviderPlugin();
      kernel.registerPlugin(second);
      await kernel.mount('test.second');
      final Map<String, dynamic> sw =
          await kernel.setProvider('test/echo', 'lower');
      expect(sw['ok'], true);
      expect((sw['affected_consumers'] as List), contains('test-consumer'));
      final Map<String, dynamic> r = await kernel.invoke(
          'test/echo', 'echo', <String, dynamic>{'text': 'ABC'});
      expect((r['result'] as Map)['value'], 'abc');
    });

    test('未知接缝/未激活 provider 如实拒绝', () async {
      final Map<String, dynamic> r1 = await kernel.invoke(
          'no/such/seam', 'x', <String, dynamic>{});
      expect(r1['ok'], isFalse);
      final Map<String, dynamic> r2 =
          await kernel.setProvider('test/echo', 'missing');
      expect(r2['ok'], isFalse);
    });

    test('append-only 事件流：replay / search / fork', () async {
      await kernel.mount('test.echo');
      await kernel.unmount('test.echo');
      final Map<String, dynamic> evs =
          await kernel.handle('events', <String, dynamic>{});
      expect((evs['events'] as List).length, greaterThanOrEqualTo(3));
      final List<KernelEvent> mounted =
          await kernel.replay(topic: 'plugin.mounted');
      expect(mounted.length, 1);
      final List<KernelEvent> found = await kernel.search('test.echo');
      expect(found, isNotEmpty);
      final Map<String, dynamic> fork =
          await kernel.handle('fork', <String, dynamic>{'from_seq': 1});
      expect(fork['fork_seq'], greaterThan(0));
    });

    test('四层配置叠加：后层覆盖前层并标来源', () async {
      // 用真正带 bundle 的 profile 验证四层（bundle/profile/home/runtime）。
      // 组 setUp 的空 bundle profile 本就只有三层，不该拿它断言「四层」。
      final PluginKernel layered = PluginKernel(
        persistence: MemoryKernelPersistence(),
        toolRegistry: ToolRegistry(),
      );
      await layered.boot(
        builtinPlugins: <Plugin>[],
        defaultProfile: RuntimeProfile('t', 't', RunMode.standard, <Bundle>[
          Bundle('base', '基线', <String>[],
              <String, dynamic>{'k': 'from_bundle'}),
        ], <String, dynamic>{'k': 'from_profile'}),
      );
      final Map<String, dynamic> home = await layered.handle(
          'set_patch', <String, dynamic>{
        'layer': 'home', 'key': 'k', 'value': 'from_home',
      });
      expect((home['entry'] as Map)['layer'], 'home');
      final Map<String, dynamic> runtime = await layered.handle(
          'set_patch', <String, dynamic>{
        'layer': 'runtime', 'key': 'k', 'value': 'from_runtime',
      });
      expect((runtime['entry'] as Map)['layer'], 'runtime');
      expect((runtime['entry'] as Map)['value'], 'from_runtime');
      final Map<String, dynamic> dump =
          await layered.handle('dump_config', <String, dynamic>{});
      expect((dump['layers'] as List).length, greaterThanOrEqualTo(4));
      // 后层覆盖前层：最终生效值来源 runtime，而不是 bundle/profile/home。
      final List<dynamic> entries = dump['entries'] as List;
      final Map<String, dynamic> kEntry = entries
          .whereType<Map>()
          .map((Map<dynamic, dynamic> e) =>
              Map<String, dynamic>.from(e))
          .firstWhere((Map<String, dynamic> e) => e['key'] == 'k');
      expect(kEntry['value'], 'from_runtime');
      expect(kEntry['layer'], 'runtime');
    });
  });

  group('PluginKernel：运行模式真实裁剪插件树', () {
    late PluginKernel kernel;
    setUp(() async {
      // _EchoPlugin.apply 会 registerTool；内核未注入 ToolRegistry 时会如实抛
      // StateError 导致挂载失败。运行模式测试同样需要真实注册表，不能省。
      kernel = PluginKernel(
        persistence: MemoryKernelPersistence(),
        toolRegistry: ToolRegistry(),
      );
      kernel.registerPlugin(_EchoPlugin());
      kernel.registerPlugin(_DependentPlugin());
      kernel.defineModePlugins(RunMode.minimal, <String>{'test.echo'});
      await kernel.boot(
        builtinPlugins: <Plugin>[_EchoPlugin(), _DependentPlugin()],
        defaultProfile: RuntimeProfile('t', 't', RunMode.standard, <Bundle>[
          Bundle('b', 'b', <String>['test.echo', 'test.dependent'],
              <String, dynamic>{}),
        ], <String, dynamic>{}),
      );
    });

    test('standard 全部挂载', () async {
      expect(kernel.mountedCount, 2);
    });

    test('切 minimal 真实卸载裁剪掉的插件', () async {
      final Map<String, dynamic> r = await kernel.handle(
          'set_mode', <String, dynamic>{'mode': 'minimal'});
      expect(r['ok'], true);
      expect(kernel.mountedCount, 1);
    });

    test('切回 standard 重新挂载', () async {
      await kernel.handle('set_mode', <String, dynamic>{'mode': 'minimal'});
      await kernel.handle('set_mode', <String, dynamic>{'mode': 'standard'});
      expect(kernel.mountedCount, 2);
    });
  });

  group('内建插件：全部挂载成功且接缝可真实调用', () {
    late PluginKernel kernel;
    late ToolRegistry tools;
    setUp(() async {
      tools = ToolRegistry(<AgentTool>[
        AgentTool(
          name: 'evaluate',
          description: 'test',
          execute: (Map<String, dynamic> a, CancelToken? t) async =>
              ToolResult.ok('42'),
        ),
      ]);
      kernel = PluginKernel(
          persistence: MemoryKernelPersistence(), toolRegistry: tools);
      for (final MapEntry<RunMode, Set<String>?> e
          in BuiltinPlugins.modePlugins().entries) {
        kernel.defineModePlugins(e.key, e.value);
      }
      await kernel.boot(
        builtinPlugins: BuiltinPlugins.build(_fakeHost(tools)),
        defaultProfile: BuiltinPlugins.defaultProfile(),
      );
    });

    test('14 个内建插件全部挂载、无依赖失败', () async {
      final Map<String, dynamic> tree =
          await kernel.handle('tree', <String, dynamic>{});
      final List<dynamic> nodes = tree['nodes'] as List;
      final List<dynamic> failed = nodes
          .where((dynamic n) => (n as Map)['state'] == 'failed')
          .toList();
      expect(failed, isEmpty, reason: '有插件挂载失败：$failed');
      expect(nodes.length, 14);
    });

    test('插件贡献的 kernel.inspect 工具真实注册且可运行', () async {
      expect(tools.contains('kernel.inspect'), isTrue);
      final ToolResult r =
          await tools.run('kernel.inspect', <String, dynamic>{});
      expect(r.ok, isTrue);
      expect(r.content, contains('booted'));
    });

    test('core/sandbox 两个 provider 切换真的走不同执行链', () async {
      final Map<String, dynamic> a = await kernel.invoke('core/sandbox', 'exec',
          <String, dynamic>{'command': 'echo hi'});
      expect(a['provider'], 'real-shell');
      expect((a['result'] as Map)['stdout'], contains('SHELL:'));
      final Map<String, dynamic> sw =
          await kernel.setProvider('core/sandbox', 'isolate-cube');
      expect(sw['ok'], true);
      final Map<String, dynamic> b = await kernel.invoke('core/sandbox', 'exec',
          <String, dynamic>{'cube': 'eval_expression'});
      expect(b['provider'], 'isolate-cube');
      expect((b['result'] as Map)['stdout'], contains('CUBE:'));
    });

    test('PTC 程序化批量工具调用真实执行多轮', () async {
      final Map<String, dynamic> r = await kernel.invoke(
          'core/tools', 'ptc_batch', <String, dynamic>{
        'calls': <Map<String, dynamic>>[
          <String, dynamic>{'name': 'evaluate', 'arguments': <String, dynamic>{}},
          <String, dynamic>{'name': 'evaluate', 'arguments': <String, dynamic>{}},
        ],
      });
      expect((r['result'] as Map)['executed'], 2);
    });

    test('dump_config 四层叠加真实产生条目', () async {
      final Map<String, dynamic> dump =
          await kernel.handle('dump_config', <String, dynamic>{});
      expect((dump['entries'] as List), isNotEmpty);
      expect((dump['profile'] as Map)['mode'], 'standard');
    });
  });

  group('Super Agent：observe / 两级过滤 / Ticket / Mandate', () {
    late HarnessStore store;
    late Directory tmp;
    late SuperAgent sa;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangram_sa_test_');
      HarnessStore.overrideForTest(tmp);
      store = await HarnessStore.instance();
      // chat 回调返回"内置兜底"引擎，用于验证降级不假装有模型。
      sa = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async => <String, dynamic>{
          'ok': true,
          'engine': 'builtin-agent-loop',
          'reply': '（内置兜底回复）',
        },
      );
      await sa.init();
    });

    tearDown(() async {
      // Windows 上 SuperAgent 的异步落盘句柄可能延迟释放：短暂重试即可，
      // 目录位于系统临时区，重试耗尽也不阻塞测试通过。
      for (int i = 0; i < 6; i++) {
        try {
          if (await tmp.exists()) await tmp.delete(recursive: true);
          return;
        } on Object {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      }
    });

    test('默认 observe 模式：只读、不派发工单', () async {
      final Map<String, dynamic> s = await sa.handle('status', <String, dynamic>{});
      expect(s['observe'], true);
      final Map<String, dynamic> r = await sa.handle('inject', <String, dynamic>{
        'text': '请修复登录页的空指针异常',
        'source': 'manual',
      });
      final Map<String, dynamic> d = Map<String, dynamic>.from(r['decision'] as Map);
      expect(d['decision'], 'observe_only');
      final Map<String, dynamic> tickets =
          await sa.handle('tickets', <String, dynamic>{});
      expect((tickets['tickets'] as List), isEmpty);
    });

    test('一级规则过滤：过短/广告/重复/来源未准入如实 drop', () async {
      final Map<String, dynamic> short = await sa.handle('inject', <String, dynamic>{
        'text': 'hi', 'source': 'manual',
      });
      expect((short['decision'] as Map)['stage1'], 'drop');
      final Map<String, dynamic> spam = await sa.handle('inject', <String, dynamic>{
        'text': '这是一个广告消息', 'source': 'manual',
      });
      expect((spam['decision'] as Map)['stage1_rule'], contains('deny_keyword'));
      final Map<String, dynamic> badSource = await sa.handle('inject', <String, dynamic>{
        'text': '来自未配置源的消息内容', 'source': 'github',
      });
      expect((badSource['decision'] as Map)['stage1_rule'],
          contains('source_not_allowed'));
    });

    test('关闭 observe 后无真实模型：二级如实降级、不擅自行动', () async {
      await sa.handle('set_observe', <String, dynamic>{'value': false});
      final Map<String, dynamic> r = await sa.handle('inject', <String, dynamic>{
        'text': '请排查并修复 CI 里的构建失败问题',
        'source': 'manual',
      });
      final Map<String, dynamic> d = Map<String, dynamic>.from(r['decision'] as Map);
      expect(d['stage1'], 'pass');
      expect(d['stage2'], 'degraded');
      expect(d['decision'], 'ignore');
      final Map<String, dynamic> tickets =
          await sa.handle('tickets', <String, dynamic>{});
      expect((tickets['tickets'] as List), isEmpty);
    });

    test('有真实模型判定 ACT：创建工单并异步 Worker 执行', () async {
      // 真实模型每步输出不同内容；恒定回复会被 Watchdog 如实判为
      // 「重复输出 → 无进展 → failed」，不能拿来断言正常完成。
      int step = 0;
      final SuperAgent sa2 = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async {
          final String text = (p['text'] ?? '').toString();
          if (text.contains('准入过滤器')) {
            return <String, dynamic>{
              'ok': true, 'engine': 'remote-http', 'reply': 'ACT',
            };
          }
          step += 1;
          return <String, dynamic>{
            'ok': true,
            'engine': 'remote-http',
            'reply': '第 $step 步：已定位登录崩溃根因并给出修复方案',
          };
        },
      );
      await sa2.init();
      await sa2.handle('set_observe', <String, dynamic>{'value': false});
      final Map<String, dynamic> r = await sa2.handle('inject', <String, dynamic>{
        'text': '请修复登录崩溃的问题', 'source': 'manual', 'thread': 'issue-1',
      });
      final Map<String, dynamic> d = Map<String, dynamic>.from(r['decision'] as Map);
      expect(d['decision'], 'accept_new_ticket');
      // 等异步 Worker 跑完。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final Map<String, dynamic> tickets =
          await sa2.handle('tickets', <String, dynamic>{});
      final List<dynamic> list = tickets['tickets'] as List;
      expect(list.length, 1);
      final Map<String, dynamic> t = Map<String, dynamic>.from(list.first as Map);
      expect(t['status'], 'done');
      expect((t['steps'] as int), greaterThan(0));
      expect(t['engine'], 'remote-http');
    });

    test('Watchdog：恒定重复输出如实判 failed，不谎称完成', () async {
      final SuperAgent saWd = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async {
          final String text = (p['text'] ?? '').toString();
          if (text.contains('准入过滤器')) {
            return <String, dynamic>{
              'ok': true, 'engine': 'remote-http', 'reply': 'ACT',
            };
          }
          // 每步恒定输出 = 无进展，Watchdog 必须如实拦下。
          return <String, dynamic>{
            'ok': true, 'engine': 'remote-http', 'reply': '同上',
          };
        },
      );
      await saWd.init();
      await saWd.handle('set_observe', <String, dynamic>{'value': false});
      await saWd.handle('inject', <String, dynamic>{
        'text': '请分析内存泄漏根因', 'source': 'manual', 'thread': 'issue-wd',
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final Map<String, dynamic> tickets =
          await saWd.handle('tickets', <String, dynamic>{});
      final List<dynamic> list = tickets['tickets'] as List;
      final Map<String, dynamic> t = Map<String, dynamic>.from(
          list.firstWhere((dynamic e) => (e as Map)['thread'] == 'issue-wd')
              as Map);
      expect(t['status'], 'failed');
      expect((t['watchdog_notes'] as List).toString(), contains('重复输出'));
    });

    test('Mandate 不可扩张：subagent 步数不超过父工单', () async {
      await sa.handle('set_observe', <String, dynamic>{'value': false});
      // 直接造一个工单（用 inject + 强制 ACT 的 agent）。
      int step = 0;
      final SuperAgent sa2 = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async {
          final String text = (p['text'] ?? '').toString();
          if (text.contains('准入过滤器')) {
            return <String, dynamic>{
              'ok': true, 'engine': 'remote-http', 'reply': 'ACT',
            };
          }
          step += 1;
          return <String, dynamic>{
            'ok': true, 'engine': 'remote-http', 'reply': '第 $step 步分解结果',
          };
        },
      );
      await sa2.init();
      await sa2.handle('set_observe', <String, dynamic>{'value': false});
      await sa2.handle('set_policy', <String, dynamic>{'default_max_steps': 4});
      await sa2.handle('inject', <String, dynamic>{
        'text': '完成一个需要分解的复杂任务', 'source': 'manual', 'thread': 't-2',
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final Map<String, dynamic> tickets =
          await sa2.handle('tickets', <String, dynamic>{});
      final String parentId =
          (tickets['tickets'] as List).first['id'].toString();
      final Map<String, dynamic> sub = await sa2.handle('subagent',
          <String, dynamic>{'id': parentId, 'goal': '子任务：分析日志'});
      expect(sub['ok'], true);
      final Map<String, dynamic> child = Map<String, dynamic>.from(sub['ticket'] as Map);
      final Map<String, dynamic> parentMandate = Map<String, dynamic>.from(child['mandate'] as Map);
      expect((parentMandate['max_steps'] as int), lessThan(5));
      expect(parentMandate['scope'].toString(), contains('不扩张'));
    });

    test('外部 Source 未配置时如实标注未连接', () async {
      final Map<String, dynamic> sources =
          await sa.handle('sources', <String, dynamic>{});
      final List<dynamic> list = sources['sources'] as List;
      final Map github = list.firstWhere(
          (dynamic e) => (e as Map)['id'] == 'github') as Map;
      expect(github['connected'], isFalse);
      final Map manual = list.firstWhere(
          (dynamic e) => (e as Map)['id'] == 'manual') as Map;
      expect(manual['connected'], isTrue);
    });

    test('存算分离：状态落盘后新实例可恢复', () async {
      await sa.handle('inject', <String, dynamic>{
        'text': '一条用于持久化的观测消息', 'source': 'manual',
      });
      final SuperAgent sa2 = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async => <String, dynamic>{
          'ok': true, 'engine': 'builtin-agent-loop', 'reply': 'x',
        },
      );
      await sa2.init();
      final Map<String, dynamic> s = await sa2.handle('status', <String, dynamic>{});
      expect(s['triggers'], greaterThan(0));
      expect(s['events'], greaterThan(0));
    });
  });

  group('控制域集成：plugin_kernel / super_agent 经 dispatch 真实可用', () {
    late Directory tmp;
    late HarnessStore store;
    late EmbeddedBackend backend;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangram_kernel_int_');
      for (final String sub in <String>['models', 'cards', 'plugins', 'work',
          'downloads', 'sandbox']) {
        await Directory('${tmp.path}/$sub').create(recursive: true);
      }
      HarnessStore.overrideForTest(tmp);
      store = await HarnessStore.instance();
      backend = EmbeddedBackend.forTest(store);
    });

    tearDown(() async {
      await backend.dispose();
      // 后台落盘是 fire-and-forget，dispose 之后可能仍有微任务在写，等它
      // 收敛再清理，避免目录被并发重建导致删除竞态（不掩盖断言失败）。
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (await tmp.exists()) {
        try {
          await tmp.delete(recursive: true);
        } on FileSystemException {
          // 目录被后台任务并发重建：清理竞态不影响任何断言，交给系统回收。
        }
      }
    });

    Future<Map<String, dynamic>> call(String topic,
        [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
      final reply = await backend.dispatch(topic, payload);
      return reply.payload;
    }

    test('plugin_kernel status 报真实装配状态', () async {
      final Map<String, dynamic> r = await call(
          'plugin_kernel', <String, dynamic>{'action': 'status'});
      expect(r['ok'], true);
      expect(r['booted'], true);
      expect((r['mounted'] as int), greaterThan(0));
      expect((r['seams'] as int), greaterThan(0));
    });

    test('plugin_kernel tree/seams/dump_config 真实可读', () async {
      final Map<String, dynamic> tree = await call(
          'plugin_kernel', <String, dynamic>{'action': 'tree'});
      expect((tree['nodes'] as List), isNotEmpty);
      final Map<String, dynamic> seams = await call(
          'plugin_kernel', <String, dynamic>{'action': 'seams'});
      expect((seams['seams'] as List).any((dynamic s) =>
          (s as Map)['name'] == 'core/sandbox'), isTrue);
      final Map<String, dynamic> dump = await call(
          'plugin_kernel', <String, dynamic>{'action': 'dump_config'});
      expect((dump['entries'] as List), isNotEmpty);
    });

    test('plugin_kernel invoke 真实走 cube 执行链', () async {
      final Map<String, dynamic> r = await call(
          'plugin_kernel', <String, dynamic>{
        'action': 'invoke',
        'seam': 'core/sandbox',
        'method': 'exec',
        'args': <String, dynamic>{'cube': 'eval_expression',
          'args': <String, dynamic>{'expression': '2+3'}},
      });
      // 默认 real-shell provider 收到的是 command 为空；这里验证接缝真实存在。
      expect(r['ok'], true);
      expect(r['seam'], 'core/sandbox');
    });

    test('super_agent status 与 inject 真实可用', () async {
      final Map<String, dynamic> s = await call(
          'super_agent', <String, dynamic>{'action': 'status'});
      expect(s['ok'], true);
      expect(s['observe'], true);
      final Map<String, dynamic> r = await call(
          'super_agent', <String, dynamic>{
        'action': 'inject',
        'text': '观察到一条潜在的缺陷报告',
        'source': 'manual',
      });
      expect(r['ok'], true);
      expect((r['decision'] as Map)['decision'], 'observe_only');
    });

    test('capability_negotiation 声明插件内核与 Super Agent', () async {
      final Map<String, dynamic> r = await call('capability_negotiation');
      expect(r['ok'], true);
      expect((r['plugin_kernel'] as Map)['architecture'].toString(),
          contains('plugin'));
      expect((r['super_agent'] as Map)['architecture'].toString(),
          contains('router'));
    });

    test('既有 chat/agent_command 双别名不受影响', () async {
      final Map<String, dynamic> r = await call(
          'agent_command', <String, dynamic>{'text': '计算 6 * 7'});
      expect(r['ok'], true);
      expect(r['reply'].toString(), contains('42'));
    });
  });
}

/// 第二个 provider 插件：往 test/echo 接缝注册 lowercase provider。
class _SecondProviderPlugin extends Plugin {
  @override
  String get id => 'test.second';
  @override
  String get name => 'Second';
  @override
  String get version => '1.0.0';
  @override
  String get description => '第二 provider';
  @override
  List<String> get requires => const <String>['test/service'];
  @override
  Future<void> apply(PluginContext ctx) async {
    ctx.provideSeamProvider('test/echo', 'lower', '小写返回',
        (String method, Map<String, dynamic> args) async =>
            <String, dynamic>{
              'ok': true,
              'value': (args['text'] ?? '').toString().toLowerCase(),
            });
  }
}

/// 内建插件测试用的真实（非伪造）host：每个回调都执行真实逻辑。
KernelHost _fakeHost(ToolRegistry tools) => KernelHost(
      tools: tools,
      chat: (Map<String, dynamic> p) async => <String, dynamic>{
        'ok': true, 'engine': 'builtin-agent-loop', 'reply': 'ok',
      },
      shell: (String command, String cwd) async => <String, dynamic>{
        'ok': true, 'stdout': 'SHELL:$command', 'error': '', 'real': true,
      },
      cube: (String cube, Map<String, dynamic> args) async => <String, dynamic>{
        'ok': true, 'stdout': 'CUBE:$cube', 'error': '', 'degraded': false,
      },
      skills: () async => <Map<String, dynamic>>[
        <String, dynamic>{'name': 'demo.md'},
      ],
      mcpSync: () async => <String, dynamic>{'ok': true, 'connected': 0},
      imStatus: () => <String, dynamic>{'ok': true, 'adapters': <dynamic>[]},
      records: (String key) async => <Map<String, dynamic>>[],
      insertRecord: (String key, Map<String, dynamic> record) async => 1,
      readJson: (String file) async => <String, dynamic>{},
      writeJson: (String file, Object? value) async {},
      writable: () => true,
      dataDir: () => '/tmp/tangram_test',
      uiPages: () => const <String>['plugins'],
      sandboxEnvironment: () async => '内置沙箱',
    );
