import 'dart:async';
import 'dart:io' show Directory;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nested/nested.dart';
import 'package:provider/provider.dart';

import 'bridge/backend_client.dart';
import 'flai/app.dart';
import 'flai/providers/persistent_storage_provider.dart';
import 'flai/providers/tangram_ai_provider.dart';
import 'flai/tangram_config.dart';
import 'harness/store.dart';
import 'harness/ui_customization.dart';
import 'services/backend_port.dart';
import 'services/model_registry.dart';
import 'services/model_state.dart';
import 'services/persona_store.dart';
import 'services/presence_store.dart';
import 'services/sandbox.dart';
import 'services/sandbox_runtime.dart';
import 'services/task_scheduler.dart';
import 'ui/controllers/audio_stream.dart';
import 'ui/controllers/chat_stream.dart';
import 'ui/controllers/image_controller.dart';
import 'ui/system_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 问题 #10：edgeToEdge 让页面铺到系统栏底下，消除上下黑带；
  // 系统栏背景全透明，图标亮度随主题（后续在主题监听处同步切换）。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  applyTgaSystemUi(Brightness.light);
  runApp(const TangramServices());
}

class TangramServices extends StatefulWidget {
  const TangramServices({super.key});

  @override
  State<TangramServices> createState() => _TangramServicesState();
}

class _TangramServicesState extends State<TangramServices> {
  late final BridgeBackendPort _port;
  late final BackendClient _backend;
  late final TangramAiProvider _ai;
  late final PersistentStorageProvider _storage;
  late final ChatStreamController _chat;
  late final AudioStreamController _audio;
  late final ImageController _image;
  late final ModelState _modelState;
  late final SandboxView _sandbox;
  // 这些在 _init() 中异步初始化，APP 可能在完成前就被销毁；用可空 +
  // 判空避免 LateInitializationError（快速退出时真实存在）。
  PersonaStore? _persona;
  SandboxRuntime? _sandboxRuntime;
  // 定时任务真实调度器：每 30 秒检查启用任务，到点经 chat 真实执行。
  TaskScheduler? _scheduler;
  // 模型注册表：模型选择器与聊天推理的唯一真实数据源（真实落盘、动态刷新）。
  ModelRegistry? _registry;
  // UI 自定义配置：真实落盘、启动时加载；加载失败回退默认值（不阻塞启动）。
  UiCustomizationStore? _uiCustomization;
  // 场景模式 / 情绪连贯 / 打断恢复：与人格独立，真实落盘。
  PresenceStore? _presence;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    // 全平台统一使用纯 Dart 内嵌后端：所有控制域随 APK 内置、真实执行，
    // 不依赖 Python / Chaquopy / 外部进程 / 网络，开箱即用。
    // 需要连接外部 Python 桥时可在设置里切换 BridgeMode.stdio / tcp。
    _port = BridgeBackendPort(mode: BridgeMode.inProcess);
    _backend = _port.rawClient;
    _ai = TangramAiProvider(client: _backend);
    _storage = PersistentStorageProvider();
    _chat = ChatStreamController(_backend);
    _audio = AudioStreamController(_backend);
    _image = ImageController(_backend);
    _modelState = ModelState();
    _sandbox = SandboxView();
    _init();
  }

  Future<void> _init() async {
    // UI 自定义与人格并行加载：本地 JSON 读取，失败即回退默认值。
    final Future<UiCustomizationStore> uiFuture = _loadUiCustomization();
    final Future<PresenceStore> presenceFuture = _loadPresence();
    final PersonaStore persona = await PersonaStore.load();
    final SandboxRuntime runtime =
        SandboxRuntime(backend: _backend, persona: persona);
    // 先赋值再 await，确保即便启动中途被销毁，dispose 也能拿到实例。
    _persona = persona;
    _sandboxRuntime = runtime;
    _ai.persona = persona;
    // 模型注册表先加载：它是选择器与聊天推理的唯一真源（云端 API 配置 +
    // 真实本地权重文件 + 内置兜底），全部来自真实落盘/磁盘扫描。
    final ModelRegistry registry = await ModelRegistry.load();
    _registry = registry;
    _ai.registry = registry;
    // UI 自定义必须在 _ready 之前就绪，buildTangramConfig 才能按 visibleNavKeys
    // 过滤 navItems；这里 await 的是本地文件读取（最多 3s 超时后回退默认值），
    // 不会让启动无限等待。
    final UiCustomizationStore ui = await uiFuture;
    if (mounted) {
      _uiCustomization = ui;
    } else {
      ui.dispose();
    }
    final PresenceStore presence = await presenceFuture;
    _presence = presence;
    _ai.presence = presence;
    try {
      await _port.start();
      _chat.init();
      _audio.init();
      await _modelState.load(_backend);
      await _sandbox.load(_backend);
    } catch (_) {
      _chat.init();
    }
    unawaited(runtime.probe());
    // 启动定时任务真实调度器（人格页「定时任务」到点自动执行的来源）。
    final TaskScheduler scheduler =
        TaskScheduler(backend: _backend, persona: persona);
    _scheduler = scheduler;
    scheduler.start();
    if (mounted) setState(() => _ready = true);
  }

  /// 加载 UI 自定义配置。任何异常都回退到默认配置，绝不阻塞或崩溃启动。
  Future<UiCustomizationStore> _loadUiCustomization() async {
    HarnessStore harness;
    try {
      harness = await HarnessStore.instance();
    } on Object {
      // 文档目录不可用：常驻实例退到系统临时目录（仍是真实可写磁盘）。
      HarnessStore.overrideForTest(Directory.systemTemp);
      harness = await HarnessStore.instance();
    }
    try {
      return await UiCustomizationStore.load(harness)
          .timeout(const Duration(seconds: 3));
    } on Object catch (e) {
      return UiCustomizationStore.defaults(
        harness,
        loadError: '加载 UI 配置失败，已回退默认配置：$e',
      );
    }
  }

  /// 加载场景模式。失败回退内存默认值，不影响对话启动。
  Future<PresenceStore> _loadPresence() async {
    final HarnessStore harness = await HarnessStore.instance();
    try {
      // load 内部已对损坏文件回退到默认内存态，并会在后续写入时重建。
      return await PresenceStore.load(harness)
          .timeout(const Duration(seconds: 3));
    } on Object {
      return PresenceStore.load(harness);
    }
  }

  @override
  void dispose() {
    _chat.dispose();
    _audio.dispose();
    _image.dispose();
    _modelState.dispose();
    _sandbox.dispose();
    _sandboxRuntime?.dispose();
    _scheduler?.dispose();
    _persona?.dispose();
    _uiCustomization?.dispose();
    _presence?.dispose();
    unawaited(_ai.dispose());
    unawaited(_port.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _registry == null || _uiCustomization == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFFF7F9F7),
          body: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(0xFF8A97A8),
              ),
            ),
          ),
        ),
      );
    }
    return MultiProvider(
      providers: <SingleChildWidget>[
        Provider<BridgeBackendPort>.value(value: _port),
        Provider<BackendClient>.value(value: _backend),
        Provider<TangramAiProvider>.value(value: _ai),
        ChangeNotifierProvider<ModelState>.value(value: _modelState),
        ChangeNotifierProvider<SandboxView>.value(value: _sandbox),
        ChangeNotifierProvider<PersonaStore>.value(value: _persona!),
        ChangeNotifierProvider<ModelRegistry>.value(value: _registry!),
        ChangeNotifierProvider<UiCustomizationStore>.value(
            value: _uiCustomization!),
        ChangeNotifierProvider<PresenceStore>.value(value: _presence!),
        ChangeNotifierProvider<SandboxRuntime>.value(value: _sandboxRuntime!),
        ChangeNotifierProvider<ChatStreamController>.value(value: _chat),
        ChangeNotifierProvider<AudioStreamController>.value(value: _audio),
        ChangeNotifierProvider<ImageController>.value(value: _image),
      ],
      child: FlaiApp(
        config: buildTangramConfig(
          aiProvider: _ai,
          storageProvider: _storage,
          // 模型列表不再由静态 config 承载，改由 ModelRegistry Provider
          // 动态提供（新增/下载后立即刷新，带本地/云端标记）。
          // 侧栏真实按界面自定义「已保存」的可见 key 过滤；空/未知回退全部入口。
          visibleNavKeys: _uiCustomization!
              .apply(_uiCustomization!.scope)
              .visibleNavKeys,
        ),
      ),
    );
  }
}
