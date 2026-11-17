/// 导航拖拽排序：配置真实落盘，并按保存顺序生成侧栏。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/ui_customization.dart';
import 'package:tangram/flai/flows/workspace/workspace_sections.dart';
import 'package:tangram/flai/flows/sidebar/sidebar_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('reorderVisibleNav 真实改变顺序并持久化', () async {
    final Directory tmp = await Directory.systemTemp.createTemp('tga_ui_order_');
    HarnessStore.overrideForTest(tmp);
    final HarnessStore store = await HarnessStore.instance();
    final UiCustomizationStore ui = await UiCustomizationStore.load(store);

    expect(
      ui.setVisibleNavKeys(<String>[
        'sidebar.training',
        'sidebar.workspace',
        'sidebar.graph',
      ]),
      true,
    );
    expect(ui.reorderVisibleNav(0, 3), true);
    expect(ui.config.visibleNavKeys,
        <String>['sidebar.workspace', 'sidebar.graph', 'sidebar.training']);

    expect(await ui.save(), true);
    final UiCustomizationStore reloaded =
        await UiCustomizationStore.load(store);
    expect(reloaded.apply(UiScope.global).visibleNavKeys,
        <String>['sidebar.workspace', 'sidebar.graph', 'sidebar.training']);

    final List<NavItem> nav = buildWorkspaceNavItems(
      visibleKeys: reloaded.apply(UiScope.global).visibleNavKeys,
    );
    expect(nav.map((NavItem e) => e.labelKey).toList(),
        <String>['sidebar.workspace', 'sidebar.graph', 'sidebar.training']);

    await tmp.delete(recursive: true);
  });
}
