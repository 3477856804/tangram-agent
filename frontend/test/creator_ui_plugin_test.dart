/// Creator 插件同时支持 UI 槽位与权限策略：激活注册、停用撤销。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/creator_runtime.dart';
import 'package:tangram/harness/plugin_kernel.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UI 槽位与权限策略随插件激活注册、停用撤销', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('tga_creator_ui_');
    HarnessStore.overrideForTest(tmp);
    final HarnessStore store = await HarnessStore.instance();
    final ToolRegistry tools = ToolRegistry();
    final PluginKernel kernel =
        PluginKernel(persistence: MemoryKernelPersistence(), toolRegistry: tools);
    await kernel.boot(
      builtinPlugins: <Plugin>[],
      defaultProfile: RuntimeProfile(
          'test', 'test', RunMode.standard, <Bundle>[], <String, dynamic>{}),
    );
    final CreatorRuntime runtime = CreatorRuntime(store, kernel: kernel);

    final Map<String, dynamic> manifest = <String, dynamic>{
      'id': 'demo.ui',
      'name': 'UI 插件',
      'version': '1.0.0',
      'description': '声明式 UI 槽位与权限策略',
      'permissions': <String>[],
      'actions': <dynamic>[],
      'ui_slots': <String, dynamic>{
        'sidebar.banner': <String, dynamic>{
          'type': 'card',
          'title': '提示',
          'children': <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': '来自 Creator 插件'},
          ],
        },
      },
      'policies': <String, dynamic>{
        'read-sandbox': <String, dynamic>{
          'allow': <String>['read_file'],
          'deny': <String>['shell'],
        },
      },
    };

    final Map<String, dynamic> saved =
        await runtime.save(jsonEncode(manifest));
    expect(saved['ok'], true, reason: '${saved['error']}');
    final Map<String, dynamic> activated = await runtime.activate('demo.ui');
    expect(activated['ok'], true, reason: '${activated['error']}');

    final Map<String, dynamic> slots =
        await kernel.handle('widget_slots', <String, dynamic>{});
    final List<dynamic> list = slots['slots'] as List;
    expect(list.any((dynamic s) =>
        (s as Map)['id'] == 'creator.demo.ui.sidebar.banner'), true);

    final Map<String, dynamic> policies =
        await kernel.handle('permission_policies', <String, dynamic>{});
    final List<dynamic> ps = policies['policies'] as List;
    expect(ps.any((dynamic p) =>
        (p as Map)['id'] == 'creator.demo.ui.read-sandbox'), true);

    final Map<String, dynamic> off = await runtime.deactivate('demo.ui');
    expect(off['ok'], true);
    final Map<String, dynamic> slots2 =
        await kernel.handle('widget_slots', <String, dynamic>{});
    expect((slots2['slots'] as List).any((dynamic s) =>
        (s as Map)['id'] == 'creator.demo.ui.sidebar.banner'), false);

    await tmp.delete(recursive: true);
  });
}
