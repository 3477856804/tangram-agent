/// UI 截图与布局校验（无设备环境下渲染真实界面）。
///
/// 环境没有 /dev/kvm / Android emulator / system-image，无法真机跑 APK，
/// 因此用 Flutter widget 测试渲染真实面板并导出 PNG 供人工审查：
///   * 注入真实中文字体（默认 Ahem 会把文字渲染成黑方块，无法判断美观度）；
///   * 使用项目真实主题 [TangramTheme] 与真 inProcess 后端 + 全套 Provider；
///   * 给视口固定尺寸，避免 PanelPage 内置 ListView 拿到无界高度；
///   * 任何 Flutter 布局 overflow 都作为硬失败，其他异常仅记录供审查。
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:nested/nested.dart';
import 'package:provider/provider.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/services/model_registry.dart';
import 'package:tangram/services/model_state.dart';
import 'package:tangram/services/persona_store.dart';
import 'package:tangram/services/sandbox.dart';
import 'package:tangram/services/sandbox_runtime.dart';
import 'package:tangram/ui/panels/agent_control_panel.dart';
import 'package:tangram/ui/panels/autonomy_panel.dart';
import 'package:tangram/ui/panels/code_workspace.dart';
import 'package:tangram/ui/panels/dependency_panel.dart';
import 'package:tangram/ui/panels/device_files_panel.dart';
import 'package:tangram/ui/panels/distill_panel.dart';
import 'package:tangram/ui/panels/identity_panel.dart';
import 'package:tangram/ui/panels/identity_settings_panel.dart';
import 'package:tangram/ui/panels/im_panel.dart';
import 'package:tangram/ui/panels/model_manager_panel.dart';
import 'package:tangram/ui/panels/plugin_panel.dart';

// 字体与截图目录可通过环境变量覆盖，便于在别的机器上复跑；
// 字体缺失时跳过注入（布局校验仍有效，只是中文会回退成方块）。
final String _fontDir =
    Platform.environment['TGA_UI_FONT_DIR'] ?? '/workspace/tga_build/fonts';
final String _outDir =
    Platform.environment['TGA_UI_OUT_DIR'] ?? '/workspace/tga_build/screenshots';

/// 用 FontLoader 注册一个字体族（可含多个字重文件）。
Future<void> _loadFamily(String family, List<String> files) async {
  final List<String> existing =
      files.where((String f) => File(f).existsSync()).toList();
  if (existing.isEmpty) return;
  final FontLoader loader = FontLoader(family);
  for (final String f in existing) {
    loader.addFont(File(f)
        .readAsBytes()
        .then((Uint8List b) => ByteData.sublistView(b)));
  }
  await loader.load();
}

ThemeData _theme() {
  final ThemeData base = TangramTheme.light();
  // 项目主题未指定 fontFamily；这里注入 Noto Sans CJK SC，
  // 让截图里的中文与数字都是真实字形，而不是 Ahem 方块。
  return base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Roboto'));
}

/// 与 main.dart 一致的真实 Provider 环境。
class TestEnv {
  late final BackendClient client;
  late final ModelState modelState;
  late final ModelRegistry registry;
  late final PersonaStore persona;
  late final SandboxView sandboxView;
  late final SandboxRuntime sandboxRuntime;

  Widget wrap(Widget child) => MultiProvider(
        providers: <SingleChildWidget>[
          Provider<BackendClient>.value(value: client),
          ChangeNotifierProvider<ModelState>.value(value: modelState),
          ChangeNotifierProvider<SandboxView>.value(value: sandboxView),
          ChangeNotifierProvider<PersonaStore>.value(value: persona),
          ChangeNotifierProvider<ModelRegistry>.value(value: registry),
          ChangeNotifierProvider<SandboxRuntime>.value(value: sandboxRuntime),
        ],
        child: child,
      );
}

Future<TestEnv> _createEnv(WidgetTester tester, Directory dataDir) async {
  final TestEnv env = TestEnv();
  // 真实异步初始化必须脱离 testWidgets 的 FakeAsync zone，否则永不返回。
  await tester.runAsync(() async {
    HarnessStore.overrideForTest(dataDir);
    env.client = BackendClient(
      mode: BridgeMode.inProcess,
      // 测试里缩短控制域超时：sendControl 的 .timeout() 会创建 FakeAsync
      // Timer，dispatch 在无设备环境若未及时返回，测试结束会残留 pending
      // Timer 触发 flutter_test 的 invariant 断言。短超时便于消费它。
      requestTimeout: const Duration(milliseconds: 800),
    );
    await env.client.connect();
    final HarnessStore store = await HarnessStore.instance();
    env.registry = await ModelRegistry.forTest(store);
    env.modelState = ModelState();
    env.persona = PersonaStore();
    env.sandboxView = SandboxView();
    env.sandboxRuntime =
        SandboxRuntime(backend: env.client, persona: env.persona);
  });
  return env;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late final Directory dataDir;
  setUpAll(() async {
    Directory(_outDir).createSync(recursive: true);
    dataDir = Directory('${Directory.systemTemp.path}/tga_ui_test_$pid');
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    dataDir.createSync(recursive: true);
    HarnessStore.overrideForTest(dataDir);

    await _loadFamily('Roboto', <String>[
      '$_fontDir/NotoSansSC-Regular.otf',
      '$_fontDir/NotoSansSC-Bold.otf',
    ]);
    await _loadFamily('monospace', <String>[
      '$_fontDir/NotoSansMonoSC-Regular.otf',
    ]);
    await _loadFamily('MaterialIcons', <String>[
      '$_fontDir/MaterialIcons-Regular.otf',
    ]);
  });

  /// 用真 Provider 渲染 [child] 到固定视口并导出 PNG。
  Future<void> snap(
    WidgetTester tester,
    String name,
    TestEnv env,
    Widget child, {
    double width = 390,
    double height = 1400,
  }) async {
    final GlobalKey repaintKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: RepaintBoundary(
              key: repaintKey,
              child: env.wrap(child),
            ),
          ),
        ),
      ),
    ));

    // 面板 initState 会异步读后端（真实文件 IO），放真实事件循环跑完。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final String? info = await tester.runAsync<String?>(() async {
      final RenderRepaintBoundary boundary =
          repaintKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return null;
      final Uint8List png = bytes.buffer.asUint8List();
      await File('$_outDir/$name.png').writeAsBytes(png);
      return '${image.width}x${image.height}, '
          '${(png.length / 1024).toStringAsFixed(0)}KB';
    });
    // ignore: avoid_print
    print('[screenshot] $name: ${info ?? "FAILED"}');
    expect(info, isNotNull, reason: '$name 截图生成失败');

    // 截图已导出，推进 1s 让 sendControl 的超时 Timer 触发并被消费，
    // 避免测试结束时残留 pending Timer。
    await tester.pump(const Duration(seconds: 1));
  }

  /// 布局类异常硬失败；其他异常（插件缺失等）仅打印，避免测试环境误报。
  void expectNoLayoutErrors(WidgetTester tester, String name) {
    final List<String> all = <String>[];
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      all.add(ex.toString());
    }
    final List<String> layout = all
        .where((String s) =>
            s.contains('overflowed') ||
            s.contains('RenderFlex') ||
            s.contains('unbounded') ||
            s.contains('RenderConstrainedBox'))
        .toList();
    if (all.isNotEmpty) {
      // ignore: avoid_print
      print('[errors] $name (${all.length}): ${all.take(3).join(' | ')}');
    }
    expect(layout, isEmpty, reason: '$name 出现布局异常：\n${layout.join('\n')}');
  }

  void setupViewport(WidgetTester tester, {double height = 2600}) {
    tester.view.physicalSize = Size(1200, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  // ---------- 逐屏：所有面板 ----------
  final Map<String, Widget> panels = <String, Widget>{
    'im': const PersonalIMPanel(),
    'model_manager': const ModelManagerPanel(),
    'agent_control': const AgentControlPanel(),
    'autonomy': const ProactiveSection(),
    'code_workspace': const CodeWorkspacePanel(),
    'sandbox_controls': const SandboxControls(),
    'dependency': const DependencyPanel(),
    'device_files': const DeviceFilesPanel(),
    'distill': const DistillPanel(),
    'identity': const IdentityPanel(),
    'identity_settings': const IdentitySettingsPanel(),
    'plugin_lifecycle': const PluginLifecycleSection(),
  };

  for (final MapEntry<String, Widget> entry in panels.entries) {
    testWidgets('面板 ${entry.key} 渲染无 overflow', (WidgetTester tester) async {
      setupViewport(tester);
      final TestEnv env = await _createEnv(tester, dataDir);
      addTearDown(() => tester.runAsync(() async {
            env.client.disconnect();
          }));
      await snap(tester, 'panel_${entry.key}', env, entry.value);
      expectNoLayoutErrors(tester, entry.key);
    });
  }

  // ---------- IM 专项：真实手机首屏 / 长图 / 展开配置 ----------
  group('更多通信（IM / OpenClaw 网关）专项', () {
    testWidgets('手机首屏 390x844', (WidgetTester tester) async {
      setupViewport(tester);
      final TestEnv env = await _createEnv(tester, dataDir);
      addTearDown(() => tester.runAsync(() async {
            env.client.disconnect();
          }));
      await snap(tester, 'im_panel_phone', env, const PersonalIMPanel(),
          height: 844);
      expectNoLayoutErrors(tester, 'im_panel_phone');
    });

    testWidgets('完整长图 390x2000', (WidgetTester tester) async {
      setupViewport(tester, height: 2800);
      final TestEnv env = await _createEnv(tester, dataDir);
      addTearDown(() => tester.runAsync(() async {
            env.client.disconnect();
          }));
      await snap(tester, 'im_panel_full', env, const PersonalIMPanel(),
          height: 2000);
      expectNoLayoutErrors(tester, 'im_panel_full');
    });

    testWidgets('展开网关配置表单后无 overflow', (WidgetTester tester) async {
      setupViewport(tester, height: 2400);
      final TestEnv env = await _createEnv(tester, dataDir);
      addTearDown(() => tester.runAsync(() async {
            env.client.disconnect();
          }));

      final GlobalKey repaintKey = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: repaintKey,
              child: SizedBox(
                width: 390,
                height: 1200,
                child: env.wrap(const PersonalIMPanel()),
              ),
            ),
          ),
        ),
      ));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final Finder expand = find.byIcon(Icons.expand_more);
      expect(expand, findsOneWidget,
          reason: '未找到网关配置展开按钮，UI 结构可能已变化');
      await tester.tap(expand);
      for (int i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      final String? info = await tester.runAsync<String?>(() async {
        final RenderRepaintBoundary boundary =
            repaintKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
        final ByteData? bytes =
            await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) return null;
        await File('$_outDir/im_panel_config.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        return '${image.width}x${image.height}';
      });
      // ignore: avoid_print
      print('[screenshot] im_panel_config: ${info ?? "FAILED"}');
      expect(info, isNotNull, reason: '配置展开态截图生成失败');
      await tester.pump(const Duration(seconds: 1));
      expectNoLayoutErrors(tester, 'im_panel_config');
    });

    testWidgets('IM 面板提供「获取登录二维码」入口', (WidgetTester tester) async {
      setupViewport(tester, height: 2800);
      final TestEnv env = await _createEnv(tester, dataDir);
      addTearDown(() => tester.runAsync(() async {
            env.client.disconnect();
          }));
      await snap(tester, 'im_panel_qr_entry', env, const PersonalIMPanel(),
          height: 2000);
      // 用户点一下就能申请真二维码，不再只有手填 wss:// 地址。
      expect(find.text('获取登录二维码'), findsOneWidget);
      expect(find.textContaining('二维码由网关生成'), findsOneWidget);
      expectNoLayoutErrors(tester, 'im_panel_qr_entry');
    });
  });

  // ---------- 扫码弹窗专项 ----------
  group('扫码登录弹窗', () {
    testWidgets('网关未配置时如实报错、绝不显示假二维码',
        (WidgetTester tester) async {
      setupViewport(tester, height: 1400);
      final TestEnv env = await _createEnv(tester, dataDir);
      addTearDown(() => tester.runAsync(() async {
            env.client.disconnect();
          }));
      await snap(
        tester,
        'qr_login_error',
        env,
        QrLoginSheet(
          client: env.client,
          connector: 'wechat',
          connectorName: '微信',
          // 指向明确不可达地址，绕过局域网发现直接快速失败，稳定进入 error 态。
          gatewayUrl: 'http://127.0.0.1:1',
        ),
        height: 900,
      );
      // 核心不变量：拿不到真码时如实报错、绝不显示一张扫了没用的占位二维码。
      expect(find.text('接入失败'), findsOneWidget);
      expect(find.byIcon(Icons.link_off), findsOneWidget);
      expect(find.text('要新码'), findsOneWidget);
      expectNoLayoutErrors(tester, 'qr_login_error');
    });
  });
}
