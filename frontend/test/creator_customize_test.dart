/// Creator 声明式插件 + UI 自定义的真实行为测试。
///
/// 全部使用临时 [HarnessStore] 真实落盘；不访问网络（HTTP 动作只测校验），
/// 不 mock 插件内核 —— 注入真实 PluginKernel / ToolRegistry 验证激活与撤销。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/creator_runtime.dart';
import 'package:tangram/harness/plugin_kernel.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/ui_customization.dart';

Map<String, dynamic> _manifest({
  String id = 'demo.greeter',
  List<String> permissions = const <String>['prompt'],
  List<String> dependencies = const <String>[],
  List<Map<String, dynamic>>? actions,
}) =>
    <String, dynamic>{
      'id': id,
      'name': 'Greeter',
      'version': '1.0.0',
      'description': '声明式测试插件',
      'permissions': permissions,
      'dependencies': dependencies,
      'actions': actions ??
          <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'greet',
              'type': 'prompt',
              'template': 'Hello {{name}}',
              'required': <String>['name'],
            },
          ],
    };

PluginKernel _kernel(ToolRegistry tools) => PluginKernel(
      persistence: MemoryKernelPersistence(),
      toolRegistry: tools,
    );

Future<void> _boot(PluginKernel kernel) => kernel.boot(
      builtinPlugins: <Plugin>[],
      defaultProfile: RuntimeProfile(
          'test', 'test', RunMode.standard, <Bundle>[], <String, dynamic>{}),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_creator_test_');
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('Creator manifest 校验', () {
    test('合法 prompt manifest 通过', () {
      final CreatorRuntime runtime = CreatorRuntime(store);
      final CreatorValidation v = runtime.validate(jsonEncode(_manifest()));
      expect(v.ok, isTrue, reason: v.errors.join('；'));
      expect(v.errors, isEmpty);
    });

    test('shell 动作没有显式授权时拒绝', () {
      final CreatorRuntime runtime = CreatorRuntime(store);
      final CreatorValidation v = runtime.validate(jsonEncode(_manifest(
        permissions: const <String>['prompt'],
        actions: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'danger',
            'type': 'shell',
            'command': 'rm -rf /tmp/x',
          },
        ],
      )));
      expect(v.ok, isFalse);
      expect(v.errors.join('；'), contains('shell'));
      expect(v.errors.join('；'), contains('默认拒绝'));
    });

    test('http 仅允许 http/https、必须声明 network、URL 不得内嵌凭据', () {
      final CreatorRuntime runtime = CreatorRuntime(store);
      final CreatorValidation scheme = runtime.validate(jsonEncode(_manifest(
        permissions: const <String>['network'],
        actions: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'fetch',
            'type': 'http',
            'method': 'GET',
            'url': 'ftp://example.com/data',
          },
        ],
      )));
      expect(scheme.ok, isFalse);
      expect(scheme.errors.join('；'), contains('http/https'));

      final CreatorValidation noPerm = runtime.validate(jsonEncode(_manifest(
        permissions: const <String>['prompt'],
        actions: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'fetch',
            'type': 'http',
            'method': 'GET',
            'url': 'https://example.com/data',
          },
        ],
      )));
      expect(noPerm.ok, isFalse);
      expect(noPerm.errors.join('；'), contains('network'));

      final CreatorValidation creds = runtime.validate(jsonEncode(_manifest(
        permissions: const <String>['network'],
        actions: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'fetch',
            'type': 'http',
            'method': 'GET',
            'url': 'https://user:pass@example.com/data',
          },
        ],
      )));
      expect(creds.ok, isFalse);
      expect(creds.errors.join('；'), contains('凭据'));
    });

    test('id / 版本 / 动作必填字段错误被拒绝', () {
      final CreatorRuntime runtime = CreatorRuntime(store);
      final Map<String, dynamic> bad = _manifest(id: 'Bad ID');
      bad['version'] = 'v1';
      bad['actions'] = <Map<String, dynamic>>[
        <String, dynamic>{'id': 'x', 'type': 'prompt', 'template': ''},
      ];
      final CreatorValidation v = runtime.validate(jsonEncode(bad));
      expect(v.ok, isFalse);
      expect(v.errors.join('；'), contains('id'));
      expect(v.errors.join('；'), contains('version'));
      expect(v.errors.join('；'), contains('template'));
    });
  });

  group('Creator 保存 / 激活 / 运行 / 停用', () {
    test('保存落盘、激活注册进真实 kernel、prompt 走注入 chat、停用后拒绝运行',
        () async {
      final ToolRegistry tools = ToolRegistry();
      final PluginKernel kernel = _kernel(tools);
      await _boot(kernel);
      final List<String> prompts = <String>[];
      final CreatorRuntime runtime = CreatorRuntime(
        store,
        kernel: kernel,
        chat: (String prompt, Map<String, dynamic> args) async {
          prompts.add(prompt);
          return <String, dynamic>{'ok': true, 'reply': 'pong'};
        },
      );

      final Map<String, dynamic> saved =
          await runtime.save(jsonEncode(_manifest()));
      expect(saved['ok'], isTrue, reason: '${saved['error']}');
      expect(saved['path'].toString(), contains('plugins/creator/demo.greeter.json'));
      expect(
          await store.file('plugins/creator/demo.greeter.json').exists(), isTrue);

      final List<Map<String, dynamic>> before = await runtime.list();
      expect(before.length, 1);
      expect(before.first['active'], isFalse);

      final Map<String, dynamic> activated = await runtime.activate('demo.greeter');
      expect(activated['ok'], isTrue, reason: '${activated['error']}');
      expect(runtime.isActive('demo.greeter'), isTrue);
      final String toolName = runtime.toolName('demo.greeter', 'greet');
      expect(tools.lookup(toolName), isNotNull,
          reason: '激活必须真实注册 AgentTool');

      final Map<String, dynamic> run =
          await runtime.run('greet', <String, dynamic>{'name': 'Ada'});
      expect(run['ok'], isTrue, reason: '${run['error']}');
      expect(run['prompt'], 'Hello Ada');
      expect(prompts, <String>['Hello Ada']);
      expect((run['result'] as Map)['reply'], 'pong');

      final Map<String, dynamic> deactivated =
          await runtime.deactivate('demo.greeter');
      expect(deactivated['ok'], isTrue);
      expect(tools.lookup(toolName), isNull, reason: '停用必须真实撤销 AgentTool');

      final Map<String, dynamic> after =
          await runtime.run('greet', <String, dynamic>{'name': 'Ada'});
      expect(after['ok'], isFalse);
      expect(after['error'].toString(), contains('未激活'));
    });

    test('challenge：缺少 chat 回调时如实失败，不伪造回复', () async {
      final CreatorRuntime runtime = CreatorRuntime(store);
      expect((await runtime.save(jsonEncode(_manifest())))['ok'], isTrue);
      expect((await runtime.activate('demo.greeter'))['ok'], isTrue);
      final Map<String, dynamic> run =
          await runtime.run('greet', <String, dynamic>{'name': 'Ada'});
      expect(run['ok'], isFalse);
      expect(run['error'].toString(), contains('chat'));
    });

    test('依赖未激活时拒绝激活', () async {
      final CreatorRuntime runtime = CreatorRuntime(store);
      final Map<String, dynamic> manifest =
          _manifest(id: 'demo.dependent', dependencies: const <String>['demo.base']);
      expect((await runtime.save(jsonEncode(manifest)))['ok'], isTrue);
      final Map<String, dynamic> activated =
          await runtime.activate('demo.dependent');
      expect(activated['ok'], isFalse);
      expect(activated['error'].toString(), contains('依赖'));
    });
  });

  group('Creator 导出 / 导入 / 删除', () {
    test('导出 JSON 后可删除并重新导入，catalog 恢复', () async {
      final CreatorRuntime runtime = CreatorRuntime(store);
      expect((await runtime.save(jsonEncode(_manifest())))['ok'], isTrue);

      final Map<String, dynamic> exported =
          await runtime.exportJson('demo.greeter');
      expect(exported['ok'], isTrue);
      final String json = exported['json'] as String;
      expect(json, contains('"id": "demo.greeter"'));

      final Map<String, dynamic> deleted = await runtime.delete('demo.greeter');
      expect(deleted['ok'], isTrue);
      expect(await runtime.list(), isEmpty);
      expect(
          await store.file('plugins/creator/demo.greeter.json').exists(), isFalse);

      final Map<String, dynamic> imported = await runtime.importJson(json);
      expect(imported['ok'], isTrue, reason: '${imported['error']}');
      expect(imported['imported'], isTrue);
      final List<Map<String, dynamic>> restored = await runtime.list();
      expect(restored.length, 1);
      expect(restored.first['id'], 'demo.greeter');

      final Map<String, dynamic> rejected =
          await runtime.importJson('{"id":"!!!"}');
      expect(rejected['ok'], isFalse);
    });
  });

  group('UI 自定义配置 clamp 与持久化', () {
    test('fontScale / radius 真实 clamp', () async {
      final UiCustomizationStore ui = await UiCustomizationStore.load(store);
      ui.setFontScale(99);
      expect(ui.config.fontScale, UiCustomizationConfig.maxFontScale);
      ui.setFontScale(-1);
      expect(ui.config.fontScale, UiCustomizationConfig.minFontScale);
      ui.setRadius(1000);
      expect(ui.config.radius, UiCustomizationConfig.maxRadius);
      ui.setRadius(-100);
      expect(ui.config.radius, UiCustomizationConfig.minRadius);
    });

    test('保存后新实例恢复，global / project 作用域互不覆盖', () async {
      final UiCustomizationStore ui = await UiCustomizationStore.load(store);
      ui.setAccent(UiAccentPreset.purple);
      ui.setFontScale(1.2);
      ui.setSidebarGrouping(true);
      ui.setComposerFloating(true);
      expect(await ui.save(), isTrue);

      ui.setScope(UiScope.project);
      ui.setAccent(UiAccentPreset.gold);
      ui.setDensity(UiDensity.compact);
      expect(await ui.save(), isTrue);

      expect(ui.apply(UiScope.global).accentPreset, UiAccentPreset.purple);
      expect(ui.apply(UiScope.project).accentPreset, UiAccentPreset.gold);

      final UiCustomizationStore reloaded =
          await UiCustomizationStore.load(store);
      expect(reloaded.loadError, isEmpty);
      expect(reloaded.scope, UiScope.project);
      expect(reloaded.config.accentPreset, UiAccentPreset.gold);
      expect(reloaded.config.density, UiDensity.compact);
      expect(reloaded.apply(UiScope.global).accentPreset, UiAccentPreset.purple);
      expect(reloaded.apply(UiScope.global).fontScale, 1.2);
      expect(reloaded.apply(UiScope.global).sidebarGrouping, isTrue);
      expect(reloaded.apply(UiScope.global).composerFloating, isTrue);
      expect(File('${tmp.path}/ui_customization.json').existsSync(), isTrue);
    });

    test('非法 JSON / 未知预设 / 空导航导入被拒绝且状态不变', () async {
      final UiCustomizationStore ui = await UiCustomizationStore.load(store);
      ui.setAccent(UiAccentPreset.cyan);
      await ui.save();
      final String before = ui.exportJson();

      final Map<String, dynamic> notJson = await ui.importJson('not-json');
      expect(notJson['ok'], isFalse);

      final Map<String, dynamic> unknownPreset = await ui.importJson(
          jsonEncode(<String, dynamic>{'accentPreset': 'rainbow'}));
      expect(unknownPreset['ok'], isFalse);
      expect(unknownPreset['error'].toString(), contains('rainbow'));

      final Map<String, dynamic> emptyNav = await ui.importJson(
          jsonEncode(<String, dynamic>{'visibleNavKeys': <String>[]}));
      expect(emptyNav['ok'], isFalse);
      expect(emptyNav['error'].toString(), contains('不能为空'));

      expect(ui.exportJson(), before, reason: '拒绝导入不得改内存状态');
      final UiCustomizationStore reloaded =
          await UiCustomizationStore.load(store);
      expect(reloaded.config.accentPreset, UiAccentPreset.cyan);
    });

    test('导入合法配置时数值 clamp，未知导航 key 被过滤', () async {
      final UiCustomizationStore ui = await UiCustomizationStore.load(store);
      final Map<String, dynamic> result = await ui.importJson(jsonEncode(
        <String, dynamic>{
          'fontScale': 99,
          'radius': -5,
          'visibleNavKeys': <String>[
            'sidebar.training',
            'sidebar.unknown',
          ],
        },
      ));
      expect(result['ok'], isTrue, reason: '${result['error']}');
      expect(ui.config.fontScale, UiCustomizationConfig.maxFontScale);
      expect(ui.config.radius, UiCustomizationConfig.minRadius);
      expect(ui.config.visibleNavKeys, <String>['sidebar.training']);
    });

    test('可见导航不能为空（最后一个不许关闭）', () async {
      final UiCustomizationStore ui = await UiCustomizationStore.load(store);
      final List<String> keys = List<String>.of(ui.config.visibleNavKeys);
      expect(keys.length, UiCustomizationConfig.knownNavKeys.length);
      for (int i = 0; i < keys.length - 1; i++) {
        expect(ui.toggleNavKey(keys[i]), isTrue);
      }
      expect(ui.config.visibleNavKeys.length, 1);
      expect(ui.toggleNavKey(keys.last), isFalse);
      expect(ui.config.visibleNavKeys, <String>[keys.last]);
      expect(ui.setVisibleNavKeys(<String>[]), isFalse);
      expect(ui.lastError, contains('不能为空'));
    });
  });
}
