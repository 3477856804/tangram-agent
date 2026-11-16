/// P2-3「万物皆插件」自定义能力轻量测试。
///
/// 用内存持久化 + 真实 PluginKernel 验证 pages / text_overrides /
/// permission_policies / widget_slots 的真实读写与可逆性；用内建插件验证
/// ui/pages 与 core/sandbox 的扩展 method 真实生效。不伪造响应、不依赖磁盘
/// 与外部后端；权限策略是纯数据规则，内核不冒充判定方。

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/builtin_plugins.dart';
import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/plugin_kernel.dart';

/// 往内核注册全部四类自定义接缝的测试插件：验证挂载生效、卸载恢复。
class _CustomPlugin extends Plugin {
  @override
  String get id => 'test.custom';
  @override
  String get name => 'Custom';
  @override
  String get version => '1.0.0';
  @override
  String get description => '自定义能力接缝测试插件';
  @override
  Future<void> apply(PluginContext ctx) async {
    ctx.registerPage('custom.page', <String, dynamic>{'title': '自定义页'});
    ctx.registerWidgetSlot('custom.slot', <String, dynamic>{'where': 'header'});
    ctx.registerTextOverride('zh', 'kernel.title', '自定义内核');
    ctx.registerPermissionPolicy(
        'custom.policy', <String, dynamic>{'deny': <String>['danger']});
  }
}

KernelHost _fakeHost(
  ToolRegistry tools, {
  Future<Map<String, dynamic>> Function(String, String)? shell,
}) =>
    KernelHost(
      tools: tools,
      chat: (Map<String, dynamic> p) async => <String, dynamic>{
        'ok': true,
        'engine': 'builtin-agent-loop',
        'reply': 'ok',
      },
      shell: shell ??
          ((String command, String cwd) async => <String, dynamic>{
                'ok': true,
                'stdout': 'SHELL:$command',
              }),
      cube: (String cube, Map<String, dynamic> args) async =>
          <String, dynamic>{'ok': true, 'stdout': 'CUBE:$cube'},
      skills: () async => <Map<String, dynamic>>[],
      mcpSync: () async => <String, dynamic>{'ok': true, 'connected': 0},
      imStatus: () => <String, dynamic>{'ok': true, 'adapters': <dynamic>[]},
      records: (String key) async => <Map<String, dynamic>>[],
      insertRecord: (String key, Map<String, dynamic> record) async => 1,
      readJson: (String file) async => <String, dynamic>{},
      writeJson: (String file, Object? value) async {},
      writable: () => true,
      dataDir: () => '/tmp/tangram_test',
      uiPages: () => const <String>['training', 'workspace'],
      sandboxEnvironment: () async => 'test-env',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('自定义能力接缝：挂载生效 / 卸载恢复', () {
    late PluginKernel kernel;

    setUp(() async {
      kernel = PluginKernel(
        persistence: MemoryKernelPersistence(),
        toolRegistry: ToolRegistry(),
      );
      kernel.registerPlugin(_CustomPlugin());
      await kernel.boot(
        builtinPlugins: <Plugin>[],
        defaultProfile: RuntimeProfile(
            't', 't', RunMode.standard, <Bundle>[], <String, dynamic>{}),
      );
    });

    test('挂载后四类注册项真实可读', () async {
      final Map<String, dynamic> mounted = await kernel.mount('test.custom');
      expect(mounted['ok'], true);

      final Map<String, dynamic> pages =
          await kernel.handle('pages', <String, dynamic>{});
      expect(((pages['pages'] as List).first as Map)['id'], 'custom.page');

      final Map<String, dynamic> slots =
          await kernel.handle('widget_slots', <String, dynamic>{});
      expect(((slots['slots'] as List).first as Map)['id'], 'custom.slot');

      final Map<String, dynamic> texts = await kernel.handle(
          'text_overrides', <String, dynamic>{'op': 'list'});
      expect((texts['overrides'] as List).length, 1);

      final Map<String, dynamic> policies = await kernel.handle(
          'permission_policies', <String, dynamic>{'op': 'list'});
      expect((policies['policies'] as List).length, 1);
    });

    test('卸载逆序撤销，四类注册项真实消失', () async {
      await kernel.mount('test.custom');
      final Map<String, dynamic> r = await kernel.unmount('test.custom');
      expect(r['ok'], true);

      final Map<String, dynamic> pages =
          await kernel.handle('pages', <String, dynamic>{});
      expect((pages['pages'] as List), isEmpty);
      final Map<String, dynamic> slots =
          await kernel.handle('widget_slots', <String, dynamic>{});
      expect((slots['slots'] as List), isEmpty);
      final Map<String, dynamic> texts = await kernel.handle(
          'text_overrides', <String, dynamic>{'op': 'list'});
      expect((texts['overrides'] as List), isEmpty);
      final Map<String, dynamic> policies = await kernel.handle(
          'permission_policies', <String, dynamic>{'op': 'list'});
      expect((policies['policies'] as List), isEmpty);
    });

    test('pages add/remove/reorder 真实改写注册表，非法 reorder 如实拒绝', () async {
      var r = await kernel.handle('pages', <String, dynamic>{
        'op': 'add',
        'id': 'p1',
        'meta': <String, dynamic>{'title': 'P1'},
      });
      expect(r['ok'], true);
      final Map<String, dynamic> dup = await kernel.handle(
          'pages',
          <String, dynamic>{'op': 'add', 'id': 'p1', 'meta': <String, dynamic>{}});
      expect(dup['ok'], false, reason: '重复 id 不应静默覆盖');

      r = await kernel.handle('pages', <String, dynamic>{
        'op': 'add',
        'id': 'p2',
        'meta': <String, dynamic>{'title': 'P2'},
      });
      expect(r['ok'], true);

      r = await kernel.handle('pages', <String, dynamic>{
        'op': 'reorder',
        'ids': <String>['p2', 'p1'],
      });
      expect(r['ok'], true);
      expect(
          (r['order'] as List).map((dynamic e) => (e as Map)['id']).toList(),
          <String>['p2', 'p1']);

      final Map<String, dynamic> listed =
          await kernel.handle('pages', <String, dynamic>{});
      expect(((listed['pages'] as List).first as Map)['id'], 'p2');

      final Map<String, dynamic> bad = await kernel.handle(
          'pages',
          <String, dynamic>{'op': 'reorder', 'ids': <String>['p1']});
      expect(bad['ok'], false);

      r = await kernel.handle('pages', <String, dynamic>{
        'op': 'remove',
        'id': 'p1',
      });
      expect(r['ok'], true);
      final Map<String, dynamic> after =
          await kernel.handle('pages', <String, dynamic>{});
      expect((after['pages'] as List).length, 1);
    });

    test('text_overrides set/get/list 真实返回，未覆盖不编造默认值', () async {
      var r = await kernel.handle('text_overrides', <String, dynamic>{
        'op': 'set',
        'locale': 'zh',
        'key': 'k',
        'value': '覆盖值',
      });
      expect(r['ok'], true);

      r = await kernel.handle('text_overrides', <String, dynamic>{
        'op': 'get',
        'locale': 'zh',
        'key': 'k',
      });
      expect(r['found'], true);
      expect(r['value'], '覆盖值');

      r = await kernel.handle('text_overrides', <String, dynamic>{
        'op': 'get',
        'locale': 'en',
        'key': 'k',
      });
      expect(r['found'], false);
      expect(r['value'], isNull);

      r = await kernel.handle(
          'text_overrides', <String, dynamic>{'op': 'list'});
      expect((r['overrides'] as List).length, 1);
    });

    test('permission_policies set/list 真实返回策略数据', () async {
      var r = await kernel.handle('permission_policies', <String, dynamic>{
        'op': 'set',
        'id': 'pol1',
        'policy': <String, dynamic>{'allow': <String>['read']},
      });
      expect(r['ok'], true);

      r = await kernel.handle(
          'permission_policies', <String, dynamic>{'op': 'list'});
      final List<dynamic> list = r['policies'] as List;
      expect(list.length, 1);
      expect((list.first as Map)['id'], 'pol1');
      expect(((list.first as Map)['policy'] as Map)['allow'], contains('read'));
    });
  });

  group('配置 bundle 层：真实写入并标注来源', () {
    test('set_patch(bundle) 写入 bundle.patch，dump_config 显示来源 bundle:<id>',
        () async {
      final PluginKernel layered = PluginKernel(
        persistence: MemoryKernelPersistence(),
        toolRegistry: ToolRegistry(),
      );
      await layered.boot(
        builtinPlugins: <Plugin>[],
        defaultProfile: RuntimeProfile(
          't',
          't',
          RunMode.standard,
          <Bundle>[
            Bundle('core', '核心', <String>[],
                <String, dynamic>{'k': 'from_bundle'}),
          ],
          <String, dynamic>{},
        ),
      );
      final Map<String, dynamic> r = await layered.handle(
          'set_patch',
          <String, dynamic>{
            'layer': 'bundle',
            'bundle': 'core',
            'key': 'k',
            'value': 'changed',
          });
      expect(r['ok'], true);
      expect((r['entry'] as Map)['layer'], 'bundle:core');
      expect((r['entry'] as Map)['value'], 'changed');

      final Map<String, dynamic> dump =
          await layered.handle('dump_config', <String, dynamic>{});
      final Map<String, dynamic> entry = (dump['entries'] as List)
          .whereType<Map>()
          .map((Map<dynamic, dynamic> e) => Map<String, dynamic>.from(e))
          .firstWhere((Map<String, dynamic> e) => e['key'] == 'k');
      expect(entry['value'], 'changed');
      expect(entry['layer'], 'bundle:core');

      final Map<String, dynamic> bad = await layered.handle(
          'set_patch',
          <String, dynamic>{
            'layer': 'bundle',
            'bundle': 'missing',
            'key': 'k',
            'value': 'x',
          });
      expect(bad['ok'], false, reason: '未知 bundle 不得静默新建');
    });
  });

  group('内建插件扩展：ui/pages 与 core/sandbox 真实可调用', () {
    late ToolRegistry tools;
    late PluginKernel kernel;

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
        persistence: MemoryKernelPersistence(),
        toolRegistry: tools,
      );
      await kernel.boot(
        builtinPlugins: BuiltinPlugins.build(_fakeHost(tools)),
        defaultProfile: BuiltinPlugins.defaultProfile(),
      );
    });

    test('ui/pages list 区分真实导航基线与自定义注册表，add/remove 真实生效',
        () async {
      var r = await kernel.invoke('ui/pages', 'list', <String, dynamic>{});
      expect(r['ok'], true);
      final Map<String, dynamic> data = r['result'] as Map<String, dynamic>;
      expect(data['nav_pages'], contains('training'));
      expect(data['pages'], isEmpty);

      r = await kernel.invoke('ui/pages', 'add', <String, dynamic>{
        'id': 'custom.page',
        'meta': <String, dynamic>{'title': 'X'},
      });
      expect((r['result'] as Map)['ok'], true);

      r = await kernel.invoke('ui/pages', 'list', <String, dynamic>{});
      expect(((r['result'] as Map)['pages'] as List).length, 1);
      expect((r['result'] as Map)['all'], contains('custom.page'));
      // nav_pages 是只读真实基线，不因自定义页凭空新增导航入口。
      expect((r['result'] as Map)['nav_pages'], isNot(contains('custom.page')));

      r = await kernel.invoke('ui/pages', 'remove', <String, dynamic>{
        'id': 'custom.page',
      });
      expect((r['result'] as Map)['ok'], true);
      r = await kernel.invoke('ui/pages', 'list', <String, dynamic>{});
      expect(((r['result'] as Map)['pages'] as List), isEmpty);
    });

    test('core/sandbox configure 的 env/timeout 真实影响 exec 且如实超时', () async {
      String? seenCommand;
      final PluginKernel k = PluginKernel(
        persistence: MemoryKernelPersistence(),
        toolRegistry: tools,
      );
      await k.boot(
        builtinPlugins: BuiltinPlugins.build(_fakeHost(tools,
            shell: (String command, String cwd) async {
          seenCommand = command;
          await Future<void>.delayed(const Duration(milliseconds: 60));
          return <String, dynamic>{'ok': true, 'stdout': 'done'};
        })),
        defaultProfile: BuiltinPlugins.defaultProfile(),
      );

      var r = await k.invoke('core/sandbox', 'configure', <String, dynamic>{
        'env': <String, dynamic>{'FOO': 'bar'},
        'timeout_ms': 5,
      });
      expect((r['result'] as Map)['ok'], true);
      expect(((r['result'] as Map)['params'] as Map)['timeout_ms'], 5);

      r = await k.invoke('core/sandbox', 'exec', <String, dynamic>{
        'command': 'echo hi',
      });
      // shell 延迟 60ms > 5ms：真实超时，绝不假绿。
      expect((r['result'] as Map)['ok'], false);
      expect((r['result'] as Map)['error'].toString(), contains('超时'));
      expect(seenCommand, contains("export FOO='bar';"));

      r = await k.invoke('core/sandbox', 'config', <String, dynamic>{});
      expect(((r['result'] as Map)['params'] as Map)['timeout_ms'], 5);
    });
  });
}
