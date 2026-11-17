/// 界面自定义「真正生效」回归测试：
///   * visibleNavKeys 过滤（空 / 未知回退全部，绝不把侧栏清空）；
///   * accent 预设 → 色值 / ThemeData 覆盖；
///   * fontScale / radius / density 的应用层 clamp 映射；
///   * UI 插件槽页在无后端时安全空态（不崩溃、如实提示）。
///
/// 只测纯函数与 NavItem 过滤，不引入真实 Provider / 网络 / 磁盘。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangram/flai/flows/sidebar/sidebar_config.dart';
import 'package:tangram/flai/flows/workspace/workspace_sections.dart';
import 'package:tangram/harness/ui_customization.dart';
import 'package:tangram/ui/pages/tga_ui_plugins_page.dart';

List<String> _keysOf(List<NavItem> items) =>
    items.map((NavItem item) => item.labelKey).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('visibleNavKeys 过滤', () {
    test('null / 空集合回退全部', () {
      final List<NavItem> all = buildWorkspaceNavItems();
      expect(all, isNotEmpty);
      expect(_keysOf(buildWorkspaceNavItems(visibleKeys: null)), _keysOf(all));
      expect(
        _keysOf(buildWorkspaceNavItems(visibleKeys: <String>{})),
        _keysOf(all),
      );
    });

    test('按 key 过滤且保持原有声明顺序', () {
      final List<NavItem> items = buildWorkspaceNavItems(
        visibleKeys: <String>{'sidebar.graph', 'sidebar.training'},
      );
      expect(_keysOf(items), <String>['sidebar.training', 'sidebar.graph']);
    });

    test('全部是未知 key 时回退全部，绝不清空侧栏', () {
      final List<NavItem> all = buildWorkspaceNavItems();
      final List<NavItem> items = buildWorkspaceNavItems(
        visibleKeys: <String>{'sidebar.unknown', 'not.a.key'},
      );
      expect(items.length, all.length);
      expect(_keysOf(items), _keysOf(all));
    });

    test('默认配置包含全部已知导航 key', () {
      final UiCustomizationConfig config = UiCustomizationConfig.defaults();
      expect(
        config.visibleNavKeys.toSet(),
        UiCustomizationConfig.knownNavKeys.toSet(),
      );
      // 新增入口（经验库 / Creator / 界面自定义 / UI 插件槽 / 视频 / 账号运营）
      // 必须能被真实配置覆盖，否则保存配置后它们会被误隐藏。
      for (final String key in <String>[
        'sidebar.experience',
        'sidebar.creator',
        'sidebar.customize',
        'sidebar.uiPlugins',
        'sidebar.videoStudio',
        'sidebar.accountOps',
      ]) {
        expect(UiCustomizationConfig.knownNavKeys, contains(key));
        expect(UiCustomizationConfig.navLabels[key], isNotNull);
      }
    });
  });

  group('accent 预设映射与 ThemeData 应用', () {
    test('五个预设映射到约定色值', () {
      expect(uiAccentColor(UiAccentPreset.blue), const Color(0xFF4A90D9));
      expect(uiAccentColor(UiAccentPreset.cyan), const Color(0xFF2FB3AE));
      expect(uiAccentColor(UiAccentPreset.purple), const Color(0xFF8B5CF6));
      expect(uiAccentColor(UiAccentPreset.gold), const Color(0xFFD97706));
      expect(uiAccentColor(UiAccentPreset.green), const Color(0xFF059669));
    });

    test('覆盖 primary / secondary / tertiary，并应用圆角与密度', () {
      final UiCustomizationConfig config =
          UiCustomizationConfig.defaults().copyWith(
        accentPreset: UiAccentPreset.purple,
        radius: 20,
        density: UiDensity.compact,
      );
      final ThemeData themed =
          applyUiCustomizationTheme(ThemeData(useMaterial3: true), config);
      const Color purple = Color(0xFF8B5CF6);
      expect(themed.colorScheme.primary, purple);
      expect(themed.colorScheme.secondary, purple);
      expect(themed.colorScheme.tertiary, purple);
      expect(
        themed.visualDensity,
        const VisualDensity(horizontal: 2, vertical: 2),
      );
      final ShapeBorder? shape = themed.cardTheme.shape;
      expect(shape, isA<RoundedRectangleBorder>());
      expect(
        (shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.circular(20),
      );
    });
  });

  group('应用层 clamp / 映射', () {
    test('fontScale 收敛到 0.85–1.35，NaN 回退 1', () {
      expect(uiAppliedFontScale(0.1), minAppliedFontScale);
      expect(uiAppliedFontScale(9), maxAppliedFontScale);
      expect(uiAppliedFontScale(1.1), 1.1);
      expect(uiAppliedFontScale(double.nan), 1);
    });

    test('系统缩放 × 配置缩放后整体 clamp', () {
      expect(uiEffectiveTextScale(1, 1.1), closeTo(1.1, 1e-9));
      expect(uiEffectiveTextScale(2, 1.2), maxAppliedFontScale);
      expect(uiEffectiveTextScale(0.5, 1), minAppliedFontScale);
      expect(uiEffectiveTextScale(double.nan, 1), 1);
    });

    test('radius clamp 到 4–24', () {
      expect(uiAppliedRadius(1), UiCustomizationConfig.minRadius);
      expect(uiAppliedRadius(100), UiCustomizationConfig.maxRadius);
      expect(uiAppliedRadius(18), 18);
      expect(uiAppliedRadius(double.nan), 16);
    });

    test('density → visualDensity 2 / 0 / -1', () {
      expect(uiVisualDensityValue(UiDensity.compact), 2);
      expect(uiVisualDensityValue(UiDensity.comfortable), 0);
      expect(uiVisualDensityValue(UiDensity.spacious), -1);
    });

    test('surfacePreset：mist / midnight 强制，auto 跟随系统', () {
      expect(uiForcedBrightness(UiSurfacePreset.mist), Brightness.light);
      expect(uiForcedBrightness(UiSurfacePreset.midnight), Brightness.dark);
      expect(uiForcedBrightness(UiSurfacePreset.auto), isNull);
    });
  });

  group('UI 插件槽页安全空态', () {
    testWidgets('无后端 Provider 时不崩溃并如实提示', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: TgaUiPluginsPage(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('UI 插件槽'), findsOneWidget);
      expect(find.textContaining('后端未就绪'), findsOneWidget);
      expect(find.text('组件槽'), findsOneWidget);
      expect(find.text('注册页面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
