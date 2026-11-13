import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nested/nested.dart';
import 'package:provider/provider.dart';

import 'bridge/backend_client.dart';
import 'flai/app.dart';
import 'flai/providers/persistent_storage_provider.dart';
import 'flai/providers/tangram_ai_provider.dart';
import 'flai/tangram_config.dart';
import 'services/backend_port.dart';
import 'services/model_registry.dart';
import 'services/model_state.dart';
import 'services/persona_store.dart';
import 'services/sandbox.dart';
import 'services/sandbox_runtime.dart';
import 'services/task_scheduler.dart';
import 'ui/controllers/audio_stream.dart';
import 'ui/controllers/chat_stream.dart';
import 'ui/controllers/image_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 浅色外观：状态栏深色图标 + 蓝灰底导航栏（与页面底色一致）。
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Color(0x00000000),
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFFF7F9F7),
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
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
    unawaited(_ai.dispose());
    unawaited(_port.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _registry == null) {
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
        ),
      ),
    );
  }
}
