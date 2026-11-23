/// Tangram 内嵌后端（In-Process Backend）—— 纯 Dart，随 APK 内置。
///
/// 背景：Android 端原本走 `BridgeMode.embedded` + MethodChannel 调 CPython，
/// 移除 Chaquopy 后原生侧已无通道处理器，`connect()` 抛 MissingPluginException，
/// 导致所有 `sendControl` 抛 BackendNotConnected —— 聊天与 9 个面板全部不可用。
///
/// 本类把参考 harness 的「能力契约 + 真实数据源 + 拒绝语义」搬到 Dart 侧：
///   * 所有控制域（capability_negotiation / rpc / chat / agent_command /
///     model_route / model_store / distill / device_file / memory_event /
///     proactive_task / security_approval / plugin_lifecycle /
///     plugin_community / im_event / responsibility_trace / code_task /
///     update_status / dependency_event / perception_event / reload / status）
///     都在进程内真实执行，数据落到 App 私有目录（HarnessStore），重启可恢复。
///   * 聊天走内置 AgentLoop（工具注册表 + 真实计算/检索/记忆），不编造回答；
///     显式配置了 OpenAI 兼容 API 凭据时才走真实 HTTP 推理。
///   * 代码执行复用 SandboxedShell（受限 Isolate + cube 能力契约 + REFUSE）。
///   * 模型下载走 DownloadManager（Range 分片 + 断点续传），进度是真实字节数。
///
/// 绝不填充示例数据、绝不静默降级、绝不谎称已连接外部服务。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io'
    show
        Directory,
        File,
        FileSystemEntity,
        FileSystemEntityType,
        InternetAddressType,
        NetworkInterface,
        Platform,
        Process,
        ProcessResult,
        ProcessSignal;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:tangram/agent/sandbox/sandboxed_shell.dart';
import 'package:tangram/app_version.dart';
import 'package:tangram/harness/app_package.dart';
import 'package:tangram/harness/artifacts.dart';
import 'package:tangram/harness/audit_log.dart';
import 'package:tangram/harness/builtin_plugins.dart';
import 'package:tangram/harness/call_service.dart';
import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/downloader.dart';
import 'package:tangram/harness/explanation_level.dart';
import 'package:tangram/harness/experience_transfer.dart';
import 'package:tangram/harness/account_ops.dart';
import 'package:tangram/harness/creator_runtime.dart';
import 'package:tangram/harness/hardware_scheduler.dart';
import 'package:tangram/harness/im_service.dart';
import 'package:tangram/harness/integration_registry.dart';
import 'package:tangram/harness/knowledge_base.dart';
import 'package:tangram/harness/local_inference.dart';
import 'package:tangram/harness/local_search.dart';
import 'package:tangram/harness/mcp_client.dart';
import 'package:tangram/harness/model3d.dart';
import 'package:tangram/harness/plugin_kernel.dart';
import 'package:tangram/harness/prompt_kit.dart';
import 'package:tangram/harness/proot_sandbox.dart';
import 'package:tangram/harness/qq_sandbox.dart';
import 'package:tangram/harness/security_policy.dart';
import 'package:tangram/harness/pages_http_server.dart';
import 'package:tangram/harness/pages_service.dart';
import 'package:tangram/harness/routine_service.dart';
import 'package:tangram/harness/snapshot_service.dart';
import 'package:tangram/harness/startup_timeline.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/super_agent.dart';
import 'package:tangram/harness/team_computer.dart';
import 'package:tangram/harness/team_space.dart';
import 'package:tangram/harness/video_studio.dart';
import 'package:tangram/harness/web_search.dart';
import 'package:tangram/harness/workflow.dart';
import 'package:tangram/harness/workspace_mapping.dart';
import 'package:tangram/services/model_registry.dart' show kBuiltinFreeModels;
import 'package:tangram/services/secret_vault.dart';
import 'package:tangram/services/ssh_sandbox.dart';
import 'package:tangram/services/update_service.dart';

/// 后端一次 dispatch 的结果：结构化 payload + 可选的 hot-path 事件。
class BackendReply {
  const BackendReply(
    this.payload, {
    this.events = const <Map<String, dynamic>>[],
  });
  final Map<String, dynamic> payload;
  final List<Map<String, dynamic>> events;
}

class EmbeddedBackend implements QqShellRunner {
  EmbeddedBackend._(this.store, this.downloads) {
    _registerTools();
    // 真实 IM 网关：微信/QQ/飞书消息进来后走 _chat 的真实模型推理，
    // 回复经 AGP WebSocket 原样发回，绝不编造。QQ 沙箱直连扫码需要真实
    // shell 执行能力，把本后端作为 QqShellRunner 注入。
    im = ImService(store, _imInfer, qqShell: this);
  }

  static EmbeddedBackend? _instance;

  /// 知识图谱可扩展上限：>200 节点场景由前端性能改造承载。
  static const int _kGraphMaxNodes = 800;
  static const int _kGraphMaxEdges = 2400;

  final HarnessStore store;
  final DownloadManager downloads;

  /// 真实 IM 网关服务（配置落盘、连接状态可查、可热更新）。
  late final ImService im;

  /// 私有知识库：多库隔离、本地 BM25 检索、引用溯源、版本快照。
  late final KnowledgeBase knowledge = KnowledgeBase(store);

  /// 可视化工作流 / 批量自动化：步骤真实调用对话、shell 与知识库。
  late final WorkflowEngine workflows = WorkflowEngine(
    store,
    chat: _chat,
    shell: (String command, String cwd) =>
        _shellExec(<String, dynamic>{'command': command, 'cwd': cwd}),
    knowledge: (String query) => knowledge.contextBlock(query),
  );

  /// 本地快照 / 备份 / 恢复（真实文件副本 + SHA256 校验）。
  late final SnapshotService snapshots = SnapshotService(store);

  /// Agent 生成的版本化 Pages（看板 / 文档）。
  late final PagesService pages = PagesService(store);

  /// Pages 本地分享服务（127.0.0.1 临时端口，懒创建，用完可停）。
  PagesHttpServer? _pagesServer;

  /// 多时间表 Routine（cron + 时区 + 运行历史）。
  late final RoutineService routines = RoutineService(store);

  /// Agent 应用市场：行业工作站模板安装 / 导入 / 导出。
  late final AppPackageService appPackages = AppPackageService(
    store,
    workflows,
    knowledge,
  );

  /// 团队协作沙箱：本机协作空间 + 角色权限 + 审计日志。
  late final TeamSpaceService team = TeamSpaceService(store);

  /// Team Computer：共享工作区 + 每智能体独立浏览器 profile + 检查点。
  late final TeamComputerService computer = TeamComputerService(store.root);

  /// Integrations：MCP / OpenAPI / GraphQL，凭据走系统安全存储。
  late final IntegrationRegistry integrations = IntegrationRegistry(
    store.root,
    vault: const FlutterSecretVault(),
  );

  /// 语音通话记录：真实转写落盘。
  late final CallService calls = CallService(store);

  /// 本机全局搜索：只读真实落盘的对话 / 页面 / 知识库 / 通话等。
  late final LocalSearchService search = LocalSearchService(store.root);

  /// 本地产物：工作区、Pages 版本与 Team Computer 文件。
  late final ArtifactService artifacts = ArtifactService(store.root);

  /// 硬件自适应调度：真实探针 + 量化/后端/路由建议 + 队列。
  late final HardwareScheduler hardware = HardwareScheduler();

  /// 工作区域目录映射：宿主目录 ↔ 沙箱文件同步（文件动作前过权限策略）。
  late final WorkspaceMappingService workspaceMappings =
      WorkspaceMappingService(store, guard: _workspaceGuard);

  /// 经验库 / 账号运营：由页面按需构造，回调统一走本后端的真实能力。
  ExperienceLibrary experienceLibrary() => ExperienceLibrary(store);
  AccountOps accountOps() => AccountOps(store, send: accountOpsSend);
  VideoStudio videoStudio() => VideoStudio(
    store,
    shell: (String command, String cwd) =>
        _shellExec(<String, dynamic>{'command': command, 'cwd': cwd}),
  );

  /// Creator 运行时：带上真实内核、对话与 shell，激活后立即可用。
  Future<CreatorRuntime> createCreatorRuntime() async {
    await _ensureKernel();
    return CreatorRuntime(
      store,
      kernel: _kernel,
      chat: (String prompt, Map<String, dynamic> args) =>
          _chat(<String, dynamic>{'text': prompt, ...args}),
      shell: (String command, String cwd) =>
          _shellExec(<String, dynamic>{'command': command, 'cwd': cwd}),
      mcp: (String server, String tool, Map<String, dynamic> args) async {
        final McpClient? client = _mcpClients[server];
        if (client == null) {
          return <String, dynamic>{
            'ok': false,
            'error': 'MCP 服务端「$server」未连接；已配置：${_mcpClients.keys.join(", ")}',
          };
        }
        final McpCallResult r = await client.callTool(tool, args);
        return <String, dynamic>{'ok': r.ok, 'text': r.text, 'error': r.error};
      },
    );
  }

  /// 账号运营发布：按草稿里的渠道推送到已接入的真实 IM 通道；
  /// 未登录/未配置的渠道由 IM 网关如实返回错误，不伪造成功。
  Future<Map<String, dynamic>> accountOpsSend(
    String channel,
    Map<String, dynamic> payload,
  ) async {
    final String grantKey = 'account.publish|$channel';
    PolicyDecision decision = (await _policyEngine()).evaluate(
      tool: 'account.publish',
      args: channel,
    );
    // ask 命中的一次性放行凭据：批准后重试同一渠道即直接放行，不再重复建单。
    if (decision == PolicyDecision.ask && await _consumeGrant(grantKey)) {
      decision = PolicyDecision.allow;
    }
    await _auditLog().append(
      category: 'security',
      action: 'account.publish',
      decision: decision.name,
      actor: 'account',
      detail: channel,
    );
    if (decision != PolicyDecision.allow) {
      int? approvalId;
      if (decision == PolicyDecision.ask) {
        approvalId = await store.insert('approvals', <String, dynamic>{
          'action': '账号发布: $channel',
          'status': 'pending',
          'grant_key': grantKey,
          'consumed': 0,
          'ts': _now(),
        });
      }
      return <String, dynamic>{
        'ok': false,
        'error': '发布被安全策略拒绝或待审批（$channel）',
        'denied': true,
        if (approvalId != null) 'approval_id': approvalId,
      };
    }
    return im.handle('send', <String, dynamic>{
      'connector': channel,
      'channel': channel,
      'text': (payload['content'] ?? '').toString(),
      'to': (payload['target'] ?? '').toString(),
      'scope': (payload['scope'] ?? '').toString(),
    });
  }

  // ---- 万物皆插件内核 + Super Agent（懒装配，绑定真实能力）----
  PluginKernel? _kernel;
  SuperAgent? _superAgent;
  Future<void>? _kernelBoot;

  final ToolRegistry tools = ToolRegistry();

  /// 真实联网搜索：DuckDuckGo HTML 优先，失败时回退中文维基百科。
  final WebSearchService webSearch = WebSearchService();

  /// Android「Debian 用户态（proot）」扩展包：真实下载/解包/proot 执行。
  late final ProotSandbox proot = ProotSandbox(store, downloads);

  /// MCP 真实接入：HTTP/SSE 传输的服务端工具会被注册进 [tools]，
  /// 由内置 AgentLoop 直接调用；stdio 传输移动端无法 spawn 进程，如实跳过。
  final Map<String, McpClient> _mcpClients = <String, McpClient>{};
  final List<String> _mcpToolNames = <String>[];
  final List<Map<String, dynamic>> _hotEvents = <Map<String, dynamic>>[];
  final StreamController<Map<String, dynamic>> _hotController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// hot-path 事件流（供流式 token / 轨迹事件消费）。
  Stream<Map<String, dynamic>> get onHotPath => _hotController.stream;

  static Future<EmbeddedBackend> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    StartupTimeline.global.mark('backend.enter');
    final store = await HarnessStore.instance();
    StartupTimeline.global.mark('store.ready', budgetMs: 800);
    final backend = EmbeddedBackend._(store, DownloadManager(store));
    await backend._initDefaults();
    StartupTimeline.global.mark('defaults.done', budgetMs: 2500);
    _instance = backend;
    return backend;
  }

  /// 供测试注入。
  static EmbeddedBackend forTest(HarnessStore store) =>
      EmbeddedBackend._(store, DownloadManager(store));

  /// 版本真源：全平台共用 app_version.dart 的 kAppVersion。
  static const String version = kAppVersion;

  static const List<String> controlDomains = <String>[
    'capability_negotiation',
    'rpc',
    'chat',
    'agent_command',
    'code_task',
    'model_route',
    'model_store',
    'distill',
    'device_file',
    'memory_event',
    'proactive_task',
    'security_approval',
    'plugin_lifecycle',
    'plugin_community',
    'plugin_kernel',
    'super_agent',
    'im_event',
    'knowledge_base',
    'workflow',
    'snapshot',
    'pages',
    'routine',
    'model_group',
    'app_market',
    'team_space',
    'computer',
    'integration',
    'call',
    'search',
    'artifact',
    'compute',
    'workspace_mapping',
    'web_search',
    'responsibility_trace',
    'update_status',
    'dependency_event',
    'perception_event',
    'reload',
    'status',
    'ping',
    'echo',
  ];

  static const List<String> hotPathTopics = <String>[
    'stream_token',
    'trajectory',
    'download_progress',
    'sandbox_result',
  ];

  Future<void> _initDefaults() async {
    StartupTimeline.global.mark('defaults.start');
    // MCP：启动时后台重连已配置的服务（网络失败不阻塞启动，状态可查）。
    unawaited(_mcpSync());
    // 插件内核 + Super Agent：后台预热装配（不阻塞启动，失败可重试、如实可查）。
    unawaited(_ensureKernel());
    // 只在首次启动时建立真实默认记录；不编造模型/插件。
    final rules = await store.readRecords('proactive_rules');
    if (rules.isEmpty) {
      await store.insert('proactive_rules', <String, dynamic>{
        'title': '每日工作回顾',
        'enabled': 1,
        'ts': _now(),
        'name': '每日工作回顾',
      });
    }
  }

  double _now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

  // ===========================================================================
  // 万物皆插件内核 + Super Agent：懒装配 + 真实能力绑定
  //
  // 这两层与原 24 个控制域并行：不接管 dispatch 的既有 case、不改 _emit 的
  // 流式 hot-path、不合并 cube 契约链与真 shell 链。内建插件的 provider 通过
  // _kernelHost() 绑定的闭包调用本类**已存在的真实私有方法**，绝不复制实现。
  // ===========================================================================

  /// 幂等懒装配。首次被 plugin_kernel/super_agent 控制域调用时装配；
  /// _initDefaults 也会后台预热一次（失败如实记录，不阻塞启动）。
  Future<void> _ensureKernel() {
    final Future<void>? ongoing = _kernelBoot;
    if (ongoing != null) return ongoing;
    final Future<void> f = _bootKernel().catchError((Object e) {
      // 装配失败不缓存失败 future，下次调用可重试；如实打印便于排查。
      debugPrint('TGA_KERNEL_BOOT_FAIL: $e');
      _kernelBoot = null;
    });
    _kernelBoot = f;
    return f;
  }

  /// 把内核所需能力绑定到本后端的真实实现。
  KernelHost _kernelHost() => KernelHost(
    tools: tools,
    chat: (Map<String, dynamic> p) => _chat(p),
    shell: (String command, String cwd) =>
        _shellExec(<String, dynamic>{'command': command, 'cwd': cwd}),
    cube: (String cube, Map<String, dynamic> args) async {
      final r = await SandboxedShell.instance.exec(cube, args);
      return r.toJson();
    },
    skills: () async =>
        store.scanFiles('skills', extensions: <String>{'.md', '.json'}),
    mcpSync: () => _mcpSync(),
    imStatus: () => <String, dynamic>{
      'ok': true,
      'adapters': im.adapters().map((a) => a.toJson()).toList(),
    },
    records: (String key) => store.readRecords(key),
    insertRecord: (String key, Map<String, dynamic> record) =>
        store.insert(key, record),
    readJson: (String file) => store.readJson(file),
    writeJson: (String file, Object? value) => store.writeJson(file, value),
    writable: () => store.writable,
    dataDir: () => store.root.path,
    // 页面清单：插件内核与 Super Agent 是内置核心，不暴露操作页，
    // 因此这里不再列出 plugins / kernel / super_agent。
    uiPages: () => const <String>[
      'training',
      'persona',
      'sandbox',
      'store',
      'workspace',
      'model3d',
      'channels',
      'models',
      'graph',
    ],
    sandboxEnvironment: () => _sandboxEnvironment(),
  );

  Future<void> _bootKernel() async {
    final Directory kernelDir = store.sub('kernel');
    await kernelDir.create(recursive: true);
    final PluginKernel kernel = PluginKernel(
      persistence: FileKernelPersistence(kernelDir),
      toolRegistry: tools,
      // 内核事件只进自己的 append-only 日志，绝不改流式 token 的 hot-path。
    );
    for (final MapEntry<RunMode, Set<String>?> e
        in BuiltinPlugins.modePlugins().entries) {
      kernel.defineModePlugins(e.key, e.value);
    }
    await kernel.boot(
      builtinPlugins: BuiltinPlugins.build(_kernelHost()),
      defaultProfile: BuiltinPlugins.defaultProfile(),
    );
    _kernel = kernel;
    _superAgent = SuperAgent(
      store: store,
      chat: (Map<String, dynamic> p) => _chat(p),
      kernel: kernel,
    );
    StartupTimeline.global.mark('kernel.ready', background: true);
  }

  Future<Map<String, dynamic>> _onPluginKernel(Map<String, dynamic> p) async {
    await _ensureKernel();
    final PluginKernel? k = _kernel;
    if (k == null) {
      return _err('插件内核装配失败，请稍后重试');
    }
    return await k.handle(_action(p, 'describe'), p);
  }

  Future<Map<String, dynamic>> _onSuperAgent(Map<String, dynamic> p) async {
    await _ensureKernel();
    final SuperAgent? sa = _superAgent;
    if (sa == null) {
      return _err('Super Agent 装配失败，请稍后重试');
    }
    return await sa.handle(_action(p, 'describe'), p);
  }

  void _emit(String topic, Map<String, dynamic> data) {
    final event = <String, dynamic>{'topic': topic, ...data};
    _hotEvents.add(event);
    if (!_hotController.isClosed) _hotController.add(event);
  }

  List<Map<String, dynamic>> drainEvents() {
    final out = List<Map<String, dynamic>>.of(_hotEvents);
    _hotEvents.clear();
    return out;
  }

  /// 目录映射分发：统一补上平台链接能力与每个 mapping 的 mode/link_target。
  Future<Map<String, dynamic>> _workspaceMapping(Map<String, dynamic> p) async {
    final Map<String, dynamic> result = await workspaceMappings.handle(
      _action(p, 'list'),
      p,
    );
    final bool bindSupported = WorkspaceMappingService.bindSupported;
    if (result['mappings'] is List) {
      result['mappings'] = (result['mappings'] as List).whereType<Map>().map((
        Map e,
      ) {
        final Map<String, dynamic> m = Map<String, dynamic>.from(e);
        m['bind_mode'] = (m['bind_mode'] ?? 'copy').toString();
        m['link_target'] = (m['link_target'] ?? '').toString();
        m['bind_supported'] = bindSupported;
        return m;
      }).toList();
    }
    return <String, dynamic>{...result, 'bind_supported': bindSupported};
  }

  /// Pages 控制域：列表 / 创建 / 读取 / 保存 / 元数据 / 删除 / 导出。
  Future<Map<String, dynamic>> _pages(Map<String, dynamic> p) async {
    final String action = _action(p, 'list');
    switch (action) {
      case 'list':
        return pages.list(query: (p['query'] ?? '').toString());
      case 'get':
        return pages.get(
          (p['id'] ?? '').toString(),
          version: p['version'] is int ? p['version'] as int : null,
        );
      case 'create':
        return pages.create(
          title: (p['title'] ?? '').toString(),
          html: (p['html'] ?? '').toString(),
          botId: (p['bot_id'] ?? '').toString(),
          visibility: '${p['visibility']}' == 'link'
              ? PageVisibility.link
              : PageVisibility.private,
        );
      case 'save':
        return pages.save(
          (p['id'] ?? '').toString(),
          (p['html'] ?? '').toString(),
          title: p['title'] == null ? null : '${p['title']}',
          visibility: p['visibility'] == null
              ? null
              : ('${p['visibility']}' == 'link'
                    ? PageVisibility.link
                    : PageVisibility.private),
        );
      case 'update':
        return pages.updateMeta(
          (p['id'] ?? '').toString(),
          title: p['title'] == null ? null : '${p['title']}',
          pinned: p['pinned'] is bool ? p['pinned'] as bool : null,
          visibility: p['visibility'] == null
              ? null
              : ('${p['visibility']}' == 'link'
                    ? PageVisibility.link
                    : PageVisibility.private),
        );
      case 'delete':
        return pages.delete((p['id'] ?? '').toString());
      case 'export':
        return pages.export(
          (p['id'] ?? '').toString(),
          version: p['version'] is int ? p['version'] as int : null,
        );
      case 'serve':
        // 启动本机分享服务并返回该页面的真实可打开地址；
        // 仅链接可见页面可分享，私有页面如实拒绝。
        _pagesServer ??= PagesHttpServer(pages);
        final Map<String, dynamic> started = await _pagesServer!.start();
        if (started['ok'] != true) return started;
        final Map<String, dynamic> shared =
            await _pagesServer!.shareUrl((p['id'] ?? '').toString());
        if (shared['ok'] != true) return shared;
        return <String, dynamic>{...started, ...shared};
      case 'stop':
        await _pagesServer?.stop();
        return <String, dynamic>{'ok': true, 'serving': false};
      default:
        return _err('未知 Pages 动作：$action');
    }
  }

  // ---- routine：多时间表 + 时区 + 真实运行历史 ----

  bool _legacySchedulesMigrated = false;
  final Set<String> _routineRunning = <String>{};

  /// Routine 控制域：
  /// list/get/create/update/delete/toggle/duplicate/validate/history/due/run/
  /// reconcile/retry_due/retry。
  ///
  /// 真实语义：`next_run_at` 由 RoutineStore 按 cron + 时区计算；`run` 真正
  /// 调用内置 chat 并把结果写回运行历史；`due` 只返回已到点的启用项；
  /// 失败的运行由 `retry_due`/`retry` 按退避重跑（最多 3 次），
  /// `reconcile` 把进程被杀残留的 running 记录改为失败并安排重试。
  Future<Map<String, dynamic>> _routine(Map<String, dynamic> p) async {
    final String action = _action(p, 'list');
    final String id = (p['id'] ?? '').toString().trim();
    switch (action) {
      case 'list':
        await _migrateLegacySchedules();
        return routines.list(
          query: (p['query'] ?? '').toString(),
          activeOnly: p['active_only'] == true,
        );
      case 'get':
        return routines.get(id);
      case 'create':
      case 'add':
        await _migrateLegacySchedules();
        return routines.create(
          name: (p['name'] ?? p['title'] ?? '').toString(),
          prompt: (p['prompt'] ?? p['text'] ?? '').toString(),
          crons: _routineCrons(p),
          timezone: (p['timezone'] ?? 'local').toString(),
          active: p['active'] != false,
          notify: p['notify'] != false,
          inChat: p['in_chat'] == true,
          modelProvider: _nullableText(p['model_provider']),
          modelId: _nullableText(p['model_id']),
          thinkingLevel: _nullableText(p['thinking_level']),
          oneShotAt: _parseTime(p['once_at']),
        );
      case 'update':
        final String? modelProvider = _nullableText(p['model_provider']);
        final String? modelId = _nullableText(p['model_id']);
        final String? thinkingLevel = _nullableText(p['thinking_level']);
        return routines.update(
          id,
          name: p['name'] == null ? null : '${p['name']}',
          prompt: p['prompt'] == null ? null : '${p['prompt']}',
          crons: p.containsKey('crons') ? _routineCrons(p) : null,
          timezone: p['timezone'] == null ? null : '${p['timezone']}',
          active: p['active'] is bool ? p['active'] as bool : null,
          notify: p['notify'] is bool ? p['notify'] as bool : null,
          inChat: p['in_chat'] is bool ? p['in_chat'] as bool : null,
          modelProvider: modelProvider,
          clearModelProvider:
              p.containsKey('model_provider') && modelProvider == null,
          modelId: modelId,
          clearModelId: p.containsKey('model_id') && modelId == null,
          thinkingLevel: thinkingLevel,
          clearThinkingLevel:
              p.containsKey('thinking_level') && thinkingLevel == null,
          oneShotAt: _parseTime(p['once_at']),
        );
      case 'delete':
        return routines.delete(id);
      case 'toggle':
        return routines.setActive(
          id,
          p['enabled'] is bool ? p['enabled'] as bool : p['active'] == true,
        );
      case 'duplicate':
        return routines.duplicate(
          id,
          name: p['name'] == null ? null : '${p['name']}',
        );
      case 'validate':
        final List<String> crons = _routineCrons(p);
        final String zone = (p['timezone'] ?? 'local').toString();
        final String? invalid = RoutineStore.validateSchedule(crons, zone);
        return invalid == null
            ? <String, dynamic>{
                'ok': true,
                'crons': crons,
                'timezone': zone,
                'next_run_at': _nextRunPreview(crons, zone),
              }
            : _err(invalid);
      case 'history':
        final dynamic cursor = p['before'];
        return routines.historyDetailed(
          id,
          before: cursor is Map
              ? cursor.map(
                  (dynamic k, dynamic v) => MapEntry(k.toString(), v),
                )
              : null,
          limit: p['limit'] is num ? (p['limit'] as num).toInt() : 30,
        );
      case 'due':
        return routines.due(now: _parseTime(p['now']));
      case 'run':
        return _runRoutine(
          id,
          scheduled: p['scheduled'] == true,
          now: _parseTime(p['now']),
        );
      case 'reconcile':
        return routines.reconcileStaleRuns(now: _parseTime(p['now']));
      case 'retry_due':
        return routines.dueRetries(now: _parseTime(p['now']));
      case 'retry':
        return _retryRoutine(
          (p['run_id'] ?? '').toString(),
          now: _parseTime(p['now']),
        );
      default:
        return _err('未知 routine 动作：$action');
    }
  }

  /// 真实执行一条 Routine：先推进计划时间并写 running 记录，再调用 chat。
  Future<Map<String, dynamic>> _runRoutine(
    String id, {
    required bool scheduled,
    DateTime? now,
  }) async {
    if (id.isEmpty) return _err('缺少 Routine id');
    if (_routineRunning.contains(id)) {
      return <String, dynamic>{
        'ok': true,
        'skipped': true,
        'reason': 'Routine 正在运行中',
      };
    }
    if (scheduled) {
      // 双重检查：内置调度器与页面可能同时 tick，只有真正到期才执行。
      final Map<String, dynamic> due = await routines.due(now: now);
      final List<dynamic> items =
          (due['due'] as List?) ?? const <dynamic>[];
      final bool isDue = items.whereType<Map>().any(
        (Map r) => '${r['id']}' == id,
      );
      if (!isDue) {
        return <String, dynamic>{
          'ok': true,
          'skipped': true,
          'reason': '未到点或已停用',
        };
      }
    }
    _routineRunning.add(id);
    try {
      final Map<String, dynamic> started = await routines.startRun(
        id,
        trigger: scheduled ? 'schedule' : 'manual',
        now: now,
      );
      if (started['ok'] != true) return started;
      final Map<dynamic, dynamic> run = started['run'] as Map;
      final Map<dynamic, dynamic> routine = started['routine'] as Map;
      // 必须 await：不 await 就直接返回 Future，finally 会立刻把 id 从
      // _routineRunning 里摘掉，chat 还在跑时就可能被并发重跑。
      return await _executeRoutineRun(
        id: id,
        runId: '${run['id'] ?? ''}',
        routine: routine,
        now: now,
      );
    } finally {
      _routineRunning.remove(id);
    }
  }

  /// 重跑一条失败的运行：恢复记录为 running 后再次调用 chat，
  /// 成功则结束，失败则继续记 attempts 与下次重试时刻。
  /// Routine 已停用时跳过重跑并把记录标记为 skipped，不再重试。
  Future<Map<String, dynamic>> _retryRoutine(
    String runId, {
    DateTime? now,
  }) async {
    if (runId.isEmpty) return _err('缺少运行记录 id');
    final Map<String, dynamic> got = await routines.getRun(runId);
    if (got['ok'] != true) return got;
    final Map<dynamic, dynamic> run = got['run'] as Map;
    final String routineId = '${run['routine_id'] ?? ''}';
    if (routineId.isEmpty) return _err('运行记录缺少 Routine id');
    if (_routineRunning.contains(routineId)) {
      return <String, dynamic>{
        'ok': true,
        'skipped': true,
        'reason': 'Routine 正在运行中',
      };
    }
    final Map<String, dynamic> detail = await routines.get(routineId);
    if (detail['ok'] != true) return detail;
    final Map<dynamic, dynamic> routine = detail['routine'] as Map;
    if (routine['active'] != true) {
      await routines.skipRun(runId, now: now);
      return <String, dynamic>{
        'ok': true,
        'skipped': true,
        'reason': 'Routine 已停用，不再重跑',
      };
    }
    _routineRunning.add(routineId);
    try {
      final Map<String, dynamic> resumed =
          await routines.resumeRun(runId, now: now);
      if (resumed['ok'] != true) return resumed;
      // 必须 await：理由同 _runRoutine，finally 必须等 chat 跑完才摘 guard。
      return await _executeRoutineRun(
        id: routineId,
        runId: runId,
        routine: routine,
        now: now,
      );
    } finally {
      _routineRunning.remove(routineId);
    }
  }

  /// 一次 Routine 执行的 chat 部分（首跑与重跑共用）：
  /// 调用 chat，把结果写入运行记录；失败时 finishRun 会记 attempts 与
  /// 下次重试时刻，成功则清掉重试安排。
  Future<Map<String, dynamic>> _executeRoutineRun({
    required String id,
    required String runId,
    required Map<dynamic, dynamic> routine,
    DateTime? now,
  }) async {
    final String name = '${routine['name'] ?? 'Routine'}';
    final String prompt = '${routine['prompt'] ?? ''}';
    final String text =
        '【定时例程 · $name】\n$prompt\n\n请执行这项例程，并把结果如实汇报。';
    String reply = '';
    String error = '';
    bool ok = false;
    try {
      final Map<String, dynamic> r = await _chat(<String, dynamic>{
        'text': text,
        'session_id': 'routine:$id',
      });
      ok = r['ok'] == true;
      reply = '${r['reply'] ?? r['text'] ?? ''}'.trim();
      if (!ok) error = '${r['error'] ?? 'ok=false'}';
    } on Object catch (e) {
      error = '$e';
    }
    if (runId.isNotEmpty) {
      await routines.finishRun(
        runId,
        ok: ok,
        result: reply,
        error: error,
        now: now,
      );
    }
    return <String, dynamic>{
      'ok': ok,
      'run_id': runId,
      'routine': routine,
      'result': reply.length > 500 ? '${reply.substring(0, 500)}…' : reply,
      'error': error,
    };
  }

  /// 旧版 `schedules.json`（每日 HH:mm / every:N）一次性迁移为 Routine。
  /// 迁移成功后把旧文件改名为 `.migrated`，不删除用户数据。
  Future<void> _migrateLegacySchedules() async {
    if (_legacySchedulesMigrated) return;
    _legacySchedulesMigrated = true;
    try {
      final Map<String, dynamic> existing = await routines.list();
      final dynamic list = existing['routines'];
      if (list is List && list.isNotEmpty) return;
      final List<Map<String, dynamic>> records =
          await store.readRecords('schedules');
      if (records.isEmpty) return;
      bool migratedAny = false;
      for (final Map<String, dynamic> record in records) {
        final String name =
            (record['title'] ?? record['name'] ?? '').toString().trim();
        final String prompt = (record['prompt'] ?? '').toString().trim();
        final String? cron = _legacyCron('${record['cron'] ?? ''}');
        if (name.isEmpty || prompt.isEmpty || cron == null) continue;
        final Map<String, dynamic> created = await routines.create(
          name: name,
          prompt: prompt,
          crons: <String>[cron],
          active: record['enabled'] != false,
        );
        if (created['ok'] == true) migratedAny = true;
      }
      if (migratedAny) {
        final File old = store.file('schedules.json');
        if (await old.exists()) {
          await old.rename('${old.path}.migrated');
        }
      }
    } on Object {
      // 迁移失败不影响新 Routine；旧文件保留，下次启动仍可重试。
    }
  }

  static String? _legacyCron(String raw) {
    final String text = raw.trim();
    final RegExpMatch? daily =
        RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text);
    if (daily != null) {
      final int h = int.tryParse(daily.group(1)!) ?? -1;
      final int m = int.tryParse(daily.group(2)!) ?? -1;
      if (h < 0 || h > 23 || m < 0 || m > 59) return null;
      return '$m $h * * *';
    }
    final RegExpMatch? interval =
        RegExp(r'^every:(\d{1,4})$').firstMatch(text);
    if (interval != null) {
      final int n = int.tryParse(interval.group(1)!) ?? 0;
      if (n >= 1 && n <= 59) return '*/$n * * * *';
      if (n >= 60 && n % 60 == 0 && n ~/ 60 <= 23) {
        return '0 */${n ~/ 60} * * *';
      }
      if (n == 1440) return '0 0 * * *';
      return null;
    }
    return CronExpression.isValid(text) ? text : null;
  }

  static List<String> _routineCrons(Map<String, dynamic> p) {
    final dynamic raw = p['crons'];
    if (raw is List) {
      return RoutineStore.normalizeCrons(raw);
    }
    final dynamic single = p['cron'] ?? p['schedule'];
    if (single is String && single.trim().isNotEmpty) {
      return RoutineStore.normalizeCrons(<dynamic>[single]);
    }
    return <String>[];
  }

  static String? _nullableText(dynamic value) {
    if (value == null) return null;
    final String text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  static DateTime? _parseTime(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString());
  }

  static String? _nextRunPreview(List<String> crons, String zone) {
    final String? invalid = RoutineStore.validateSchedule(crons, zone);
    if (invalid != null) return null;
    final DateTime now = DateTime.now().toUtc();
    try {
      final RoutineZone tz = RoutineZone.parse(zone);
      if (isOneShotCrons(crons)) return null;
      final DateTime? anchor =
          nextCronDateAcrossStrict(crons, now, tz);
      if (anchor == null) return null;
      return nextRoutineRunDateAcross(crons, anchor, now, tz)
          ?.toIso8601String();
    } on FormatException {
      return null;
    }
  }

  /// 统一分发入口。任何异常都转成结构化 error，绝不让 UI 拿到未捕获异常。
  Future<BackendReply> dispatch(
    String topic,
    Map<String, dynamic> payload,
  ) async {
    _hotEvents.clear();
    try {
      final Map<String, dynamic> result = switch (topic) {
        'capability_negotiation' => _capabilities(),
        'rpc' => await _rpc(payload),
        'chat' || 'agent_command' => await _chat(payload),
        'code_task' => await _codeTask(payload),
        'model_route' => await _modelRoute(payload),
        'model_store' => await _modelStore(payload),
        'distill' => await _distill(payload),
        'device_file' => await _deviceFile(payload),
        'memory_event' => await _memoryEvent(payload),
        'proactive_task' => await _proactiveTask(payload),
        'security_approval' => await _securityApproval(payload),
        'plugin_lifecycle' => await _pluginLifecycle(payload),
        'plugin_community' => await _pluginCommunity(payload),
        'plugin_kernel' => await _onPluginKernel(payload),
        'super_agent' => await _onSuperAgent(payload),
        'knowledge_base' => await knowledge.handle(
          _action(payload, 'list'),
          payload,
        ),
        'workflow' => await workflows.handle(_action(payload, 'list'), payload),
        'snapshot' => await snapshots.handle(_action(payload, 'list'), payload),
        'pages' => await _pages(payload),
        'routine' => await _routine(payload),
        'model_group' => await _modelGroup(payload),
        'app_market' => await appPackages.handle(
          _action(payload, 'list'),
          payload,
        ),
        'team_space' => await team.handle(_action(payload, 'list'), payload),
        'computer' => await computer.handle(
          _action(payload, 'list'),
          payload,
        ),
        'integration' => await integrations.handle(
          _action(payload, 'list'),
          payload,
        ),
        'call' => await calls.handle(_action(payload, 'list'), payload),
        'search' => await search.handle(_action(payload, 'query'), payload),
        'artifact' => await artifacts.handle(
          _action(payload, 'list'),
          payload,
        ),
        'compute' => await _onCompute(payload),
        'workspace_mapping' => await _workspaceMapping(payload),
        'web_search' => await _webSearchControl(payload),
        'im_event' => await im.handle(_action(payload), payload),
        'responsibility_trace' => await _responsibilityTrace(),
        'update_status' => await _updateStatus(),
        'dependency_event' => _dependencyEvent(),
        'perception_event' => await _perceptionEvent(),
        'reload' => _reload(),
        'status' => _status(),
        'ping' || 'echo' => <String, dynamic>{'ok': true, 'echo': payload},
        _ => _err('未知控制域：$topic'),
      };
      return BackendReply(result, events: drainEvents());
    } on Object catch (e) {
      return BackendReply(
        _err('$topic 执行失败：${e.runtimeType}: $e'),
        events: drainEvents(),
      );
    }
  }

  Map<String, dynamic> _ok([Map<String, dynamic>? extra]) => <String, dynamic>{
    'ok': true,
    ...?extra,
  };

  Map<String, dynamic> _err(String message) => <String, dynamic>{
    'ok': false,
    'error': message,
  };

  String _action(Map<String, dynamic> p, [String fallback = '']) =>
      (p['action'] ?? fallback).toString();

  // ---- web_search：真实联网搜索（DuckDuckGo → 中文维基百科） ----

  Future<Map<String, dynamic>> _webSearchControl(Map<String, dynamic> p) async {
    final String action = _action(p, 'search');
    if (action != 'search') {
      return _err('web_search 仅支持 action=search');
    }
    final String query = (p['query'] ?? '').toString().trim();
    if (query.isEmpty) return _err('web_search 缺少 query 参数');
    final Object? rawLimit = p['limit'];
    final int limit = rawLimit is num
        ? rawLimit.toInt()
        : (int.tryParse(rawLimit?.toString() ?? '') ?? 8);
    return webSearch.search(query, limit: limit);
  }

  // ---- capability_negotiation：真实能力清单 ----

  Map<String, dynamic> _capabilities() => <String, dynamic>{
    'ok': true,
    'name': 'tangram-in-process-harness',
    'version': version,
    'transport': 'in-process-dart',
    'runtime': 'Dart ${Platform.version.split(' ').first}',
    'backend': 'pure-dart',
    'python': 'not-used',
    'control_domains': controlDomains,
    'hot_path_topics': hotPathTopics,
    'multimodal_channels': <String>['text'],
    'realtime_categories': <String>['chat', 'tool', 'trajectory'],
    'ready': true,
    'tools': tools.names,
    'streaming': true,
    'local_inference': true,
    'data_dir': store.root.path,
    // 万物皆插件内核 + Super Agent：如实报告装配状态（未就绪不谎称）。
    'plugin_kernel': <String, dynamic>{
      'architecture': 'everything-is-a-plugin (Cordis-style)',
      'booted': _kernel?.booted ?? false,
      'mounted': _kernel?.mountedCount ?? 0,
      'seams': _kernel?.seamCount ?? 0,
      'run_modes': RunMode.values.map((RunMode m) => m.label).toList(),
    },
    'super_agent': <String, dynamic>{
      'architecture': 'router-worker + triggers + two-stage-filter + watchdog',
      'initialized': _superAgent?.initialized ?? false,
      'observe_default': true,
    },
    'knowledge_base': <String, dynamic>{
      'architecture': 'multi-library + local-bm25 + citation + snapshot',
      'storage': 'app-private-json',
      'cloud_upload': false,
    },
    'workflow': <String, dynamic>{
      'architecture':
          'sequential prompt/shell/knowledge steps + batch + daily trigger',
      'storage': 'app-private-json',
    },
    'snapshot': <String, dynamic>{
      'architecture':
          'local file copies + sha256 manifest + auto pre-restore backup',
      'cloud_enabled': false,
    },
    'pages': <String, dynamic>{
      'architecture': 'versioned html pages + pin/search + export/share file',
      'storage': 'app-private-json+html',
      'public_link_enabled': false,
      'max_html_bytes': PagesRepository.maxHtmlBytes,
    },
    'routine': <String, dynamic>{
      'architecture':
          'multi-cron + timezone + one-shot + run history + in-app scheduler',
      'storage': 'app-private-json',
      'max_crons': 12,
      'history_limit': RoutineStore.maxRuns,
      'one_shot': true,
      'background': false,
      'note': 'App 进程存活期间由内置调度器按时间表触发',
    },
    'model_group': <String, dynamic>{
      'architecture': 'parallel members + cross-compare + moderator synthesis',
      'max_members': 6,
      'key_isolation': true,
    },
    'app_market': <String, dynamic>{
      'architecture':
          'persona + workflows + knowledge + permission preset bundle',
      'payment_enabled': false,
    },
    'team_space': <String, dynamic>{
      'architecture': 'local shared dir + roles + append-only audit log',
      'cross_device_sync': false,
    },
    'computer': <String, dynamic>{
      'architecture':
          'shared workspace + per-bot browser profile + checkpoints + activity',
      'storage': 'app-private-dir',
      'browser': 'http',
      'js': false,
      'gui_desktop': false,
      'vm': false,
      'cross_device_sync': false,
      'checkpoint_limit_bytes': TeamComputerService.maxCheckpointBytes,
      'note': '浏览器为 HTTP 模式（不执行 JavaScript）；无虚拟机/图形桌面。',
    },
    'integration': <String, dynamic>{
      'architecture':
          'mcp + openapi + graphql clients + per-record secrets + append-only log',
      'kinds': <String>['mcp', 'openapi', 'graphql'],
      'auth': <String>['none', 'bearer', 'header', 'query'],
      'secret_storage': 'platform-secure-storage',
      'stdio_supported': false,
      'oauth_supported': false,
      'note': '凭据只存系统安全存储，不进入模型上下文；OAuth 流程未实现。',
    },
    'call': <String, dynamic>{
      'architecture':
          'device STT -> chat -> Edge TTS, transcript persisted per call',
      'storage': 'app-private-json',
      'history_limit': CallStore.maxCalls,
      'entries_limit': CallStore.maxEntries,
      'bot_initiated': false,
      'note': '通话由用户在通话页发起；真实转写落盘，未实现的自动外呼不伪装。',
    },
    'search': <String, dynamic>{
      'architecture':
          'local keyword scan over chats/pages/knowledge/calls/routines/workflows/integrations',
      'network': false,
      'sources': <String>[
        'chat',
        'page',
        'knowledge',
        'call',
        'routine',
        'workflow',
        'integration',
      ],
    },
    'artifact': <String, dynamic>{
      'architecture': 'real files under work/, pages/ and computer/homes/',
      'sources': <String>['work', 'page', 'computer'],
      'read_limit_bytes': ArtifactService.maxReadBytes,
      'upload': false,
    },
    'creator': <String, dynamic>{
      'architecture':
          'declarative manifest + validate + hot activate into kernel',
      'actions': <String>['prompt', 'http', 'shell'],
    },
    'experience': <String, dynamic>{
      'architecture': 'local BM25 patterns + heuristic/model adaptation',
    },
    'account_ops': <String, dynamic>{
      'architecture':
          'credential-ref only + human approval + audit + real IM send',
    },
    'video_studio': <String, dynamic>{
      'architecture':
          'ffmpeg command builder + injected sandbox shell + job records',
    },
    'ui_customization': <String, dynamic>{
      'architecture':
          'theme/layout presets + import/export + global/project scope',
    },
    'compute': <String, dynamic>{
      'architecture':
          'hardware probe + quant/backend/route recommendation + queues',
      'executes_models': false,
    },
    'workspace_mapping': <String, dynamic>{
      'architecture': 'host dir <-> sandbox file sync with sensitive-path deny',
      'bind_mount': false,
    },
  };

  // ---- rpc：真实策略 / 图 / 自检 / 激活指针 / 硬件 ----

  Future<Map<String, dynamic>> _rpc(Map<String, dynamic> p) async {
    final action = _action(p);
    switch (action) {
      case 'sandbox_policy':
        return await _sandboxPolicy();
      case 'sandbox_policy_set':
        return await _sandboxPolicySet(p);
      case 'sandbox_check':
        final kind = (p['kind'] ?? 'module').toString();
        final value = (p['value'] ?? '').toString();
        final denied = <String>['os', 'subprocess', 'sys', 'socket', 'shutil'];
        final bool allowed = kind == 'module'
            ? !denied.contains(value.toLowerCase())
            : kind == 'url'
            ? Uri.tryParse(value)?.hasScheme == true
            : !value.contains('..');
        return _ok(<String, dynamic>{
          'allowed': allowed,
          'reason': allowed ? '命中内置策略白名单' : '命中内置策略拒绝规则',
        });
      case 'graph_query':
        return _graphQuery();
      case 'status':
        return _selfTest();
      case 'selftest':
        return _selfTestAsync();
      case 'hardware':
        return await _hardware();
      case 'active':
        return _activeModel();
      case 'perf':
        return await _perf();
      case 'diagnostics':
        return await _diagnostics();
      default:
        return _err('未知 rpc action：${action.isEmpty ? '(空)' : action}');
    }
  }

  // ---- rpc perf：真实启动耗时 + 存储/知识库/审计规模（不采样、不编造）----

  static const int _kPerfFileLimit = 5000;

  Future<Map<String, dynamic>> _perf() async => _ok(await _perfSections());

  /// perf 与 diagnostics 共用的真实采集，避免两处逻辑漂移。
  Future<Map<String, dynamic>> _perfSections() async {
    final Map<String, dynamic> storage = await _perfStorage();
    Map<String, dynamic> knowledgeStats;
    try {
      knowledgeStats = await knowledge.handle('stats', <String, dynamic>{});
    } on Object catch (e) {
      knowledgeStats = <String, dynamic>{'ok': false, 'error': '$e'};
    }
    final File auditFile = store.file('audit/audit.jsonl');
    Map<String, dynamic> audit;
    try {
      final bool exists = await auditFile.exists();
      audit = <String, dynamic>{
        'path': auditFile.path,
        'exists': exists,
        'bytes': exists ? await auditFile.length() : 0,
      };
    } on Object catch (e) {
      audit = <String, dynamic>{
        'path': auditFile.path,
        'exists': false,
        'bytes': 0,
        'error': '$e',
      };
    }
    return <String, dynamic>{
      'timeline': StartupTimeline.global.report(),
      'storage': storage,
      'knowledge': knowledgeStats,
      'audit': audit,
    };
  }

  // ---- rpc diagnostics：脱敏的一键诊断包（只放计数/状态）----

  /// 一键诊断包：版本/平台 + perf 四块 + 安全摘要 + 控制域 + 能力摘要。
  /// 绝不包含 API key、token、消息正文、文件内容或审计事件明细。
  Future<Map<String, dynamic>> _diagnostics() async {
    final Map<String, dynamic> sections = await _perfSections();

    Map<String, dynamic> policySummary;
    try {
      final PermissionPolicy policy = await _ensurePolicy();
      policySummary = <String, dynamic>{
        'rules': policy.rules.length,
        'fallback': policy.fallback.name,
      };
    } on Object catch (e) {
      policySummary = <String, dynamic>{'error': '$e'};
    }

    // 只保留校验结论的计数/状态；reason 里可能带 hash，不放进诊断包。
    Map<String, dynamic> chainSummary;
    try {
      final Map<String, dynamic> verified = await _auditLog().verifyChain();
      chainSummary = <String, dynamic>{
        'ok': verified['ok'],
        'total': verified['total'],
        'broken_at': verified['broken_at'],
        'legacy': verified['legacy'],
      };
    } on Object catch (e) {
      chainSummary = <String, dynamic>{'ok': false, 'error': '$e'};
    }

    final Map<String, dynamic> bundle = <String, dynamic>{
      'app_version': version,
      'platform': '${Platform.operatingSystem} ${Platform.version}',
      'generated_at': DateTime.now().toIso8601String(),
      'timeline': sections['timeline'],
      'storage': sections['storage'],
      'knowledge': sections['knowledge'],
      'audit': sections['audit'],
      'security': <String, dynamic>{
        'policy': policySummary,
        'audit_chain': chainSummary,
      },
      'control_domains': <String, dynamic>{
        'count': controlDomains.length,
        'items': controlDomains,
      },
      'capabilities': _capabilitySummary(),
    };
    return _ok(<String, dynamic>{
      'bundle': bundle,
      'json': const JsonEncoder.withIndent('  ').convert(bundle),
    });
  }

  /// 能力摘要：直接取 [_capabilities] / [_selfTest] 的真实值，
  /// 只留名称、版本、计数与状态，不复制路径或工具清单明细。
  Map<String, dynamic> _capabilitySummary() {
    final Map<String, dynamic> caps = _capabilities();
    final dynamic rawKernel = caps['plugin_kernel'];
    final Map<String, dynamic> kernel = rawKernel is Map
        ? rawKernel.map((Object? k, Object? v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final Map<String, dynamic> self = _selfTest();
    return <String, dynamic>{
      'name': caps['name'],
      'version': caps['version'],
      'transport': caps['transport'],
      'runtime': caps['runtime'],
      'ready': caps['ready'],
      'tool_count': tools.length,
      'streaming': caps['streaming'],
      'local_inference': caps['local_inference'],
      'plugin_kernel': <String, dynamic>{
        'booted': kernel['booted'],
        'mounted': kernel['mounted'],
        'seams': kernel['seams'],
      },
      'self_test': <String, dynamic>{
        'status': self['status'],
        'checks': self['checks'],
      },
    };
  }

  /// 异步递归统计 root 下每个一级子目录的真实文件数与字节数。
  /// 全量上限 [_kPerfFileLimit] 个文件，超限即停止扫描并标记 truncated，
  /// 绝不用 listSync 做同步全量扫盘。
  Future<Map<String, dynamic>> _perfStorage() async {
    final List<Map<String, dynamic>> dirs = <Map<String, dynamic>>[];
    int totalFiles = 0;
    int totalBytes = 0;
    var truncated = false;
    try {
      await for (final FileSystemEntity entity in store.root.list(
        followLinks: false,
      )) {
        if (entity is! Directory) continue;
        int fileCount = 0;
        int bytes = 0;
        var dirTruncated = false;
        if (!truncated) {
          try {
            await for (final FileSystemEntity child in entity.list(
              recursive: true,
              followLinks: false,
            )) {
              if (child is! File) continue;
              if (totalFiles >= _kPerfFileLimit) {
                truncated = true;
                dirTruncated = true;
                break;
              }
              int size = 0;
              try {
                size = await child.length();
              } on Object {
                size = 0;
              }
              totalFiles++;
              fileCount++;
              bytes += size;
              totalBytes += size;
            }
          } on Object {
            dirTruncated = true;
          }
        } else {
          dirTruncated = true;
        }
        dirs.add(<String, dynamic>{
          'name': entity.path.split(Platform.pathSeparator).last,
          'file_count': fileCount,
          'bytes': bytes,
          if (dirTruncated) 'truncated': true,
        });
      }
    } on Object catch (e) {
      return <String, dynamic>{
        'root': store.root.path,
        'dirs': dirs,
        'file_count': totalFiles,
        'bytes': totalBytes,
        'limit': _kPerfFileLimit,
        'truncated': true,
        'error': '$e',
      };
    }
    return <String, dynamic>{
      'root': store.root.path,
      'dirs': dirs,
      'file_count': totalFiles,
      'bytes': totalBytes,
      'limit': _kPerfFileLimit,
      'truncated': truncated,
    };
  }

  /// 沙箱策略：默认值 + 用户在「训练设置」里保存的真实覆盖，
  /// 落盘在 sandbox_policy.json；沙箱执行（code_task / sandbox_eval）
  /// 会真实读取 timeout_seconds 并用它终止超时的执行 isolate。
  static const Map<String, dynamic> _defaultQuota = <String, dynamic>{
    'cpu_percent': 50,
    'memory_mb': 128,
    'timeout_seconds': 5,
    'action_on_exceed': 'refuse',
  };

  Future<Map<String, dynamic>> _quota() async {
    final Map<String, dynamic> q = Map<String, dynamic>.of(_defaultQuota);
    try {
      final raw = await store.readJson('sandbox_policy.json');
      final saved = raw['quota'];
      if (saved is Map) {
        for (final k in saved.keys) {
          if (q.containsKey(k.toString())) q[k.toString()] = saved[k];
        }
      }
    } on Object {
      // 文件不存在/损坏时用默认值，不谎报。
    }
    return q;
  }

  Future<String> _sandboxEnvironment() async {
    try {
      final raw = await store.readJson('sandbox_policy.json');
      return (raw['environment'] ?? '内置沙箱').toString();
    } on Object {
      return '内置沙箱';
    }
  }

  Future<Map<String, dynamic>> _sandboxPolicy() async {
    final q = await _quota();
    return <String, dynamic>{
      'ok': true,
      'version': version,
      'environment': await _sandboxEnvironment(),
      'gates': <String, dynamic>{
        'file_isolation': <String, dynamic>{
          'enabled': true,
          'writable_roots': <String>[store.sub('sandbox').path],
          'read_only_roots': <String>[store.sub('work').path],
        },
        'network_proxy': <String, dynamic>{
          'enabled': false,
          'allowlist': <String>[],
        },
        'quota': q,
        'module_gating': <String, dynamic>{
          'deny_by_default': <String>['os', 'subprocess', 'sys', 'socket'],
          'allow': <String>['dart:math', 'dart:core'],
        },
      },
    };
  }

  Future<Map<String, dynamic>> _sandboxPolicySet(Map<String, dynamic> p) async {
    final cur = await _quota();
    final q = <String, dynamic>{
      'cpu_percent': _asInt(p['cpu_percent'], cur['cpu_percent'] as int),
      'memory_mb': _asInt(p['memory_mb'], cur['memory_mb'] as int),
      'timeout_seconds': _asInt(
        p['timeout_seconds'],
        cur['timeout_seconds'] as int,
      ),
      'action_on_exceed': (p['action_on_exceed'] ?? cur['action_on_exceed'])
          .toString(),
    };
    if (q['cpu_percent'] < 1 || q['cpu_percent'] > 100) {
      return _err('CPU 上限需在 1~100 之间');
    }
    if (q['memory_mb'] < 16 || q['memory_mb'] > 4096) {
      return _err('内存上限需在 16~4096 MB 之间');
    }
    if (q['timeout_seconds'] < 1 || q['timeout_seconds'] > 300) {
      return _err('超时需在 1~300 秒之间');
    }
    final env = (p['environment'] ?? '').toString();
    await store.writeJson('sandbox_policy.json', <String, dynamic>{
      'quota': q,
      'environment': env.isEmpty ? await _sandboxEnvironment() : env,
      'updated_at': DateTime.now().toIso8601String(),
    });
    return _ok(<String, dynamic>{
      'quota': q,
      'environment': env.isEmpty ? await _sandboxEnvironment() : env,
    });
  }

  Future<Map<String, dynamic>> _graphQuery() async {
    final turns = await store.readRecords('turns');
    final Map<String, int> degree = <String, int>{};
    final List<Map<String, dynamic>> edges = <Map<String, dynamic>>[];
    final wordRe = RegExp(r'[\u4e00-\u9fa5]{2,}|[A-Za-z]{3,}');
    for (final t in turns) {
      final text = (t['text'] ?? '').toString();
      final words = wordRe
          .allMatches(text)
          .map((m) => m.group(0)!)
          .toSet()
          .toList();
      for (final w in words) {
        degree[w] = (degree[w] ?? 0) + 1;
      }
      for (var i = 0; i < words.length - 1; i++) {
        edges.add(<String, dynamic>{
          'subject': words[i],
          'predicate': 'co-occur',
          'obj': words[i + 1],
        });
      }
    }
    final nodes =
        degree.entries
            .map((e) => <String, dynamic>{'name': e.key, 'degree': e.value})
            .toList()
          ..sort((a, b) => (b['degree'] as int).compareTo(a['degree'] as int));
    // 可扩展上限：默认 800 节点 / 2400 边，支持 >200 节点场景。
    // 前端图谱页已做视口裁剪、背面剔除、标签网格避让与分层，能承载该规模。
    return _ok(<String, dynamic>{
      'nodes': nodes.take(_kGraphMaxNodes).toList(),
      'edges': edges.take(_kGraphMaxEdges).toList(),
    });
  }

  Future<Map<String, dynamic>> _selfTestAsync() async {
    // 先确保沙箱能力契约真实加载，再跑同步自检——否则 cubeNames 为空
    // 会把「还没加载」误报成「沙箱坏了」。
    await SandboxedShell.instance.ensureLoaded();
    return _selfTest();
  }

  Map<String, dynamic> _selfTest() {
    // 每一项都必须是真测：旧实现把 dart_sandbox / streaming 写死 true
    // 再据此算 status=ok，属于假自检。现在 dart_sandbox 查沙箱 cube
    // 注册表是否真实加载；streaming 不在此覆盖，如实列入 not_covered。
    final checks = <String, dynamic>{
      'dart_sandbox': SandboxedShell.instance.cubeNames.isNotEmpty,
      'store_writable': store.writable,
      'safe_expression': SafeExpression.eval('2 + 3 * 4') == 14,
      'tool_registry': tools.length > 0,
      'trajectory':
          TrajectorySnapshot(
            'probe',
          ).append(TrajectoryCellKind.message, 'ok').length ==
          1,
      'cancel_token': _cancelTokenSelfTest(),
    };
    final allOk = checks.values.every((v) => v == true);
    return <String, dynamic>{
      'ok': allOk,
      'status': allOk ? 'ok' : 'degraded',
      'checks': checks,
      'not_covered': <String>['streaming'],
    };
  }

  bool _cancelTokenSelfTest() {
    final src = CancelTokenSource();
    // 取消前：未取消；取消后：状态与 reason 同步可读。
    final before = !src.token.isCancelled;
    src.cancel('probe');
    // throwIfCancelled 是协作取消的核心契约，必须真的抛异常。
    var threw = false;
    try {
      src.token.throwIfCancelled();
    } on CancelledException {
      threw = true;
    } on Object {
      threw = false;
    }
    return before &&
        src.token.isCancelled &&
        src.token.cancelReason == 'probe' &&
        threw;
  }

  // ---- 硬件自适应调度（真实探针 + 建议 + 队列，不执行模型）----
  Future<Map<String, dynamic>> _onCompute(Map<String, dynamic> p) async {
    final String action = _action(p, 'status');
    switch (action) {
      case 'detect':
        final probe = await hardware.detect();
        return _ok(<String, dynamic>{
          'probe': probe.toJson(),
          'recommendation': hardware.recommend().toJson(),
        });
      case 'recommend':
        return _ok(<String, dynamic>{
          'probe': hardware.probe.toJson(),
          'recommendation': hardware.recommend().toJson(),
        });
      case 'schedule':
        final String id = (p['id'] ?? p['task'] ?? '').toString().trim();
        if (id.isEmpty) return _err('任务 id 为空，未入队');
        final HardwareTask task = HardwareTask(
          id: id,
          weight: (p['weight'] ?? 'light').toString(),
          description: (p['description'] ?? '').toString(),
        );
        return _ok(<String, dynamic>{
          'decision': hardware.schedule(task).toJson(),
          'pending_light': hardware.pendingLight,
          'pending_heavy': hardware.pendingHeavy,
        });
      case 'status':
        return _ok(<String, dynamic>{
          'probe': hardware.probe.toJson(),
          'recommendation': hardware.recommend().toJson(),
          'pending_light': hardware.pendingLight,
          'pending_heavy': hardware.pendingHeavy,
          'executes_models': false,
        });
      default:
        return _err('未知 compute 动作：$action（detect/recommend/schedule/status）');
    }
  }

  Future<Map<String, dynamic>> _hardware() async {
    final double? memGb = await _physicalMemoryGb();
    return <String, dynamic>{
      'ok': true,
      'platform': Platform.operatingSystem,
      'platform_version': Platform.operatingSystemVersion,
      'dart_version': Platform.version,
      'processors': Platform.numberOfProcessors,
      'locale': Platform.localeName,
      'models_dir': store.sub('models').path,
      'model_bytes_on_disk': store.totalModelBytes,
      if (memGb != null) 'memory_gb': memGb,
      'note': '纯 Dart 运行时，无外部解释器；磁盘统计来自真实文件系统。',
    };
  }

  /// 真实物理内存（GB）：Linux/Android 读 /proc/meminfo，macOS 用 sysctl，
  /// Windows 用 CIM；探测不到返回 null，调用方须如实显示「未知」而不是猜。
  Future<double?> _physicalMemoryGb() async {
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final String info = await File('/proc/meminfo').readAsString();
        final RegExpMatch? m = RegExp(
          r'MemTotal:\s*(\d+)\s*kB',
        ).firstMatch(info);
        final int kb = m != null ? int.tryParse(m.group(1)!) ?? 0 : 0;
        if (kb > 0) return kb / 1024 / 1024;
      } else if (Platform.isMacOS) {
        final r = await Process.run('sysctl', <String>['-n', 'hw.memsize']);
        final int bytes = int.tryParse('${r.stdout}'.trim()) ?? 0;
        if (r.exitCode == 0 && bytes > 0) return bytes / 1024 / 1024 / 1024;
      } else if (Platform.isWindows) {
        final r = await Process.run('powershell', <String>[
          '-NoProfile',
          '-Command',
          '(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory',
        ]);
        final int bytes = int.tryParse('${r.stdout}'.trim()) ?? 0;
        if (r.exitCode == 0 && bytes > 0) return bytes / 1024 / 1024 / 1024;
      }
    } on Object {
      // iOS 禁用 Process.run；命令缺失/无权限同样如实返回未知。
    }
    return null;
  }

  Future<Map<String, dynamic>> _activeModel() async {
    final active = await store.readJson('active.json');
    final files = store.scanFiles('models', extensions: <String>{'.gguf'});
    return <String, dynamic>{
      'ok': true,
      'active': active['active'] ?? <String, dynamic>{'base': '', 'chat': ''},
      'models': files,
      'quantization': files.isEmpty
          ? ''
          : _quantization(files.first['path'] as String),
      'source': 'local-files',
    };
  }

  String _quantization(String path) {
    final name = path.split('/').last.toUpperCase();
    final m = RegExp(r'(Q\d+_K_[SM]|Q\d+_0|F16|F32|BF16)').firstMatch(name);
    // 解析不到就返回空串（未知），旧实现默认编造 'Q4_K_M' 冒充该模型量化。
    return m?.group(1) ?? '';
  }

  // ---- chat / agent_command：真实 AgentLoop ----

  /// 从输入区拼接的 `[图片] /abs/path` 标记里提取真实存在的图片路径。
  /// 文件不存在时直接跳过，绝不把空路径交给视觉引擎。
  List<String> _imagePathsFrom(String text) {
    final Iterable<RegExpMatch> matches = RegExp(
      r'^\[图片\]\s*(.+)$',
      multiLine: true,
    ).allMatches(text);
    return <String>[
      for (final RegExpMatch m in matches)
        if (File(m.group(1)!.trim()).existsSync()) m.group(1)!.trim(),
    ];
  }

  Future<Map<String, dynamic>> _chat(Map<String, dynamic> p) async {
    final text = (p['text'] ?? p['message'] ?? p['prompt'] ?? '')
        .toString()
        .trim();
    // 会话边界：前端把当前会话 id 放进 metadata.conversationId，用于按会话
    // 隔离历史；未提供时退回 session_id，避免跨会话上下文串味。
    final dynamic meta = p['metadata'];
    final String session =
        (p['session_id'] ??
                (meta is Map ? meta['conversationId'] : null) ??
                'default')
            .toString();
    if (text.isEmpty) return _err('消息为空');
    // 每轮重置：该计数只用于判断"本轮云端是否已逐片投递"，不重置会让
    // 第二次对话的非流式路径误判为已投递而不再补分片。
    _streamedRemoteTokens = 0;
    // 完整多轮历史（前端已序列化为 [{role, content}]），按 token 预算裁剪。
    final List<Map<String, dynamic>> history = _historyFrom(p);

    final turnId = await store.insert('turns', <String, dynamic>{
      'session_id': session,
      'role': 'user',
      'text': text,
      'ts': _now(),
    });

    // 显式配置 OpenAI 兼容 API 时走真实网络推理；否则用内置 AgentLoop。
    final apiBase = (p['api_base'] ?? '').toString().trim();
    final apiKey = (p['api_key'] ?? '').toString().trim();
    final model = (p['model'] ?? '').toString().trim();
    // 真实消费用户配置的对话参数（不再硬编码）。
    final String system = (p['system'] ?? '').toString();
    final double temperature = _asDouble(p['temperature'], 0.7);
    final int maxTokens = _asInt(p['max_tokens'], 2048);
    final double topP = _asDouble(p['top_p'], 0.9);
    final String localPath = (p['local_model_path'] ?? '').toString().trim();
    final bool localSelected =
        (p['model_kind'] ?? '').toString() == 'local' && localPath.isNotEmpty;
    // 深度思考 / 智能搜索：由输入区的两个真实开关传入。
    final bool wantThinking = p['thinking'] == true;
    final bool wantSearch = p['search'] == true;
    // 内置免费云端模型（如 Kilo 网关 :free 档）：curl 实测无 Authorization
    // 头即可 200 返回且 cost=0，允许 api_key 为空走真实远程推理。
    final bool freeApi = p['free'] == true;
    // 底座提示词单一真源：用户/人格未提供 system 时用 PromptKit 的结构化底座，
    // 而不是各处手写的单句「你是 TGA…」，保证行为要求一致且前缀稳定可缓存。
    String effectiveSystem = system.trim().isEmpty
        ? PromptKit.defaultSystem
        : system;
    String modeSuffix = '';
    if (wantSearch) {
      // 问题 #4b：检索过程经 chat_status 热点事件真实上报，前端在
      // 流式气泡上方渲染状态条；results 解析自真实抓取摘要，绝不编造。
      _emit('chat_status', <String, dynamic>{
        'phase': 'searching',
        'query': text,
      });
      final results = await _webSearch(text);
      if (results.isEmpty) {
        effectiveSystem += '\n\n【联网检索】${PromptKit.searchFailedNote}';
      } else {
        effectiveSystem += '\n\n【联网检索结果（真实抓取，需在回答中注明来源）】\n$results';
      }
      _emit('chat_status', <String, dynamic>{
        'phase': 'search_done',
        'results': _searchResultPairs(results),
      });
      modeSuffix += '+web-search';
    }
    if (wantThinking) modeSuffix += '+deep-think';
    // 问题 #25：真实技能池——已启用的本地技能注入对话 system prompt；
    // 停用的技能被过滤，不进对话（云端与本地推理两条路径都生效）。
    final skillPool = await _enabledSkillPool();
    if (skillPool.isNotEmpty) {
      effectiveSystem += '\n\n【本地技能池（已启用，可在回答中运用）】\n$skillPool';
    }
    // 问题 #8：工作区真实可见——枚举 sandbox/ 根目录（与 device_file 同源）
    // 的真实文件树注入 system，让模型如实回答「工作区里有什么/能不能看见
    // 文件」。枚举失败静默跳过，不报错也不编造。
    final workspaceTree = _workspaceTreeBlock();
    if (workspaceTree.isNotEmpty) {
      effectiveSystem +=
          '\n\n【用户工作区文件（真实枚举）】\n$workspaceTree\n'
          '当用户问"工作区里有什么/能不能看见文件"时，依据此列表如实回答；'
          '可用 read_file 工具读取其中文件。';
    }
    // 让模型知道自己有一台 Linux：能力说明随当前沙箱模式如实给出。
    // tools 由 ChatRequest 携带，shell 工具经 tool_call 回环真实执行。
    effectiveSystem += await _linuxCapabilityBlock();
    // 跨会话持久记忆：turns 表真实落盘，按最近性 + 词项相关度注入，
    // 新会话也能召回长期事实；按会话边界与当轮历史去重。
    effectiveSystem += await _persistentMemoryBlock(text, session, history);
    // 私有知识库：仅注入真实命中的片段，并要求模型标注来源；无命中不注入。
    try {
      final String kbBlock = await knowledge.contextBlock(
        text,
        personaId: (p['persona_id'] ?? '').toString(),
      );
      if (kbBlock.isNotEmpty) effectiveSystem += '\n\n$kbBlock';
    } on Object {
      // 知识库文件损坏/不可读时不影响本轮对话，也不编造引用。
    }
    // 分层解释：用户偏好优先，自动模式按本轮提问关键词判断水平，
    // 只把讲解方式追加到人格提示词末尾，不覆盖原有 system。
    // 偏好读取失败时静默按 auto 处理，不影响本轮对话。
    AudienceLevel audience = AudienceLevel.auto;
    try {
      final AudienceLevel pref = await ExplanationLevelPref.load(store);
      audience = AudienceDetector.detect(text, preferred: pref);
    } on Object {
      audience = AudienceLevel.auto;
    }
    effectiveSystem += '\n\n${ExplanationStyle.hint(audience)}';

    String reply;
    String engine;
    if (apiBase.isNotEmpty &&
        model.isNotEmpty &&
        (apiKey.isNotEmpty || freeApi)) {
      // 1) 显式配置 OpenAI 兼容 API → 真实 HTTP 推理。
      String query = text;
      if (wantThinking) {
        // 两遍真实推理：先让模型产出分步推理要点，再基于要点作答。
        // 规划阶段同样带历史，避免"要点"脱离上文。
        final plan = await _remoteChat(
          apiBase: apiBase,
          apiKey: apiKey,
          model: model,
          text:
              '请把下面问题拆解为分步推理要点，只输出要点列表，'
              '不要给出最终答案：\n$text',
          system: '你是严谨的推理规划器。',
          temperature: 0.3,
          maxTokens: maxTokens,
          topP: topP,
          history: history,
        );
        if (plan.ok) {
          query =
              '参考以下推理要点，深入分析后作答：\n${plan.content}\n\n'
              '问题：$text';
          // 把两遍推理的规划要点作为「思考过程」逐片真实发给 UI：
          // 前端 tangram_ai_provider 收到 thinking:true 的 stream_token
          // 会转成 ThinkingDelta，喂给可展开的思考块。内容是模型真实
          // 产出的规划，绝不编造；按 runes 分片避免切断 emoji。
          final Runes planRunes = plan.content.runes;
          const int chunk = 24;
          for (int i = 0; i < planRunes.length; i += chunk) {
            final int end = (i + chunk < planRunes.length)
                ? i + chunk
                : planRunes.length;
            _emit('stream_token', <String, dynamic>{
              'token': String.fromCharCodes(planRunes.skip(i).take(end - i)),
              'thinking': true,
            });
          }
          // 状态条同样上报要点前 200 字（搜索/推理路径可视化）。
          _emit('chat_status', <String, dynamic>{
            'phase': 'thinking_done',
            'points': plan.content.length > 200
                ? plan.content.substring(0, 200)
                : plan.content,
          });
        }
      }
      final remote = await _remoteChat(
        apiBase: apiBase,
        apiKey: apiKey,
        model: model,
        text: query,
        system: wantThinking
            ? '请先在思考中拆解问题、检验假设、验证结论，再给出最终答案。'
                  '$effectiveSystem'
            : effectiveSystem,
        temperature: temperature,
        maxTokens: maxTokens,
        topP: topP,
        history: history,
        onDelta: (String d) =>
            _emit('stream_token', <String, dynamic>{'token': d}),
      );
      if (remote.ok) {
        // 工具回环：模型若输出 tga-shell 代码块，真实执行并把输出回灌，
        // 让模型据此继续推理（shell 与终端 UI 走同一执行通道）。
        reply = await _resolveShellLoops(
          first: remote.content,
          text: query,
          apiBase: apiBase,
          apiKey: apiKey,
          model: model,
          system: effectiveSystem,
          temperature: temperature,
          maxTokens: maxTokens,
          topP: topP,
          history: history,
        );
        engine = 'openai-compatible:$model$modeSuffix';
      } else {
        reply =
            '外部推理调用失败：${remote.error}\n\n'
            '（已如实记录，未编造回答。可在模型选择器里切回内置引擎。）';
        engine = 'remote-failed';
      }
    } else if (localSelected) {
      // 2) 选中已下载的 GGUF 权重 → 端侧 llama.cpp 真推理（不编造回答）。
      String localSystem = effectiveSystem.trim().isEmpty
          ? PromptKit.defaultSystem
          : effectiveSystem;
      if (wantThinking) {
        localSystem = '${PromptKit.deepThinkPrefix}\n\n$localSystem';
      }
      // 端侧 llama.cpp 只接收单条 prompt：把真实历史按角色折进 system，
      // 与云端走同一份上下文，不引入新依赖、不改推理引擎签名。
      if (history.isNotEmpty) {
        final StringBuffer past = StringBuffer('\n\n【此前对话（按时间顺序）】\n');
        for (final Map<String, dynamic> m in history) {
          past.writeln('${m['role'] == 'user' ? '用户' : '助手'}：${m['content']}');
        }
        localSystem += past.toString();
      }
      final String localText = text
          .replaceAll(RegExp(r'^\[图片\].*$', multiLine: true), '')
          .trim();
      final local = await LocalInference.instance.generate(
        localPath,
        wantThinking
            ? '请深入思考后回答：${localText.isEmpty ? '请描述这张图片' : localText}'
            : (localText.isEmpty ? '请描述这张图片' : localText),
        system: localSystem,
        imagePaths: _imagePathsFrom(text),
      );
      if (local.ok) {
        reply = local.text;
        engine = 'llama.cpp[${local.modelPath.split('/').last}]$modeSuffix';
      } else {
        reply =
            '端侧模型推理失败：${local.error}\n\n'
            '（已如实记录，未编造回答。请到「模型」页确认权重已下载完整，'
            '或在训练设置里配置 OpenAI 兼容 API。）';
        engine = 'local-inference-failed';
      }
    } else {
      // 3) 内置 AgentLoop（真实工具 / 记忆 / 计算），如实说明未加载权重。
      reply = await _agentLoop(text, session, p);
      engine = 'builtin-agent-loop$modeSuffix';
    }

    await store.insert('turns', <String, dynamic>{
      'session_id': session,
      'role': 'assistant',
      'text': reply,
      'ts': _now(),
    });
    await _appendTrace(<String, dynamic>{
      'kind': 'chat',
      'text': text,
      'reply': reply,
      'engine': engine,
      'ts': _now(),
    });

    // 流式 token 事件：云端真流式已在 onDelta 中逐片投递，不再重复整段；
    // 非流式路径（端侧 / 内置）仍按可见字符分片真实投递。
    // 注意：失败错误只作为一次性 reply 返回，不走这里分片，避免与前端兜底
    // 渲染各投一次、导致同一段错误在 UI 上重复显示两遍。
    final bool failedEngine =
        engine == 'local-inference-failed' || engine == 'remote-failed';
    if (_streamedRemoteTokens < 1 && !failedEngine) {
      for (final chunk in _chunks(reply, 24)) {
        _emit('stream_token', <String, dynamic>{'token': chunk});
      }
    }
    return <String, dynamic>{
      'ok': true,
      'reply': reply,
      'text': reply,
      'engine': engine,
      'recorded': true,
      'turn_id': turnId,
      'session_id': session,
    };
  }

  /// 把 _webSearch 返回的文本摘要解析成真实 [{title,url}] 对（最多 5 条），
  /// 供 chat_status 的 search_done 事件可视化检索过程。解析自已抓到的
  /// 真实内容；解析不到 URL 的条目直接舍弃，绝不凭空补一条来源。
  List<Map<String, String>> _searchResultPairs(String digest) {
    final out = <Map<String, String>>[];
    String pendingTitle = '';
    final titleRe = RegExp(r'^\d+\.\s+(.+)$');
    final urlRe = RegExp(r'^来源[：:]\s*(https?://\S+)$');
    for (final raw in digest.split('\n')) {
      final line = raw.trim();
      final tm = titleRe.firstMatch(line);
      if (tm != null) {
        pendingTitle = tm.group(1)!.trim();
        continue;
      }
      final um = urlRe.firstMatch(line);
      if (um != null && pendingTitle.isNotEmpty) {
        out.add(<String, String>{'title': pendingTitle, 'url': um.group(1)!});
        pendingTitle = '';
        if (out.length >= 5) break;
      }
    }
    return out;
  }

  /// 问题 #8：深度受限（≤2 层）真实枚举工作区（sandbox/ 根目录，与
  /// device_file 沙箱同源）。总条数 ≤80，跳过隐藏目录/文件与 .db/.sqlite；
  /// 文件行为「相对路径 (大小)」，目录行为「相对路径/」。任何异常返回
  /// 空串，由调用方静默跳过，不报错也不编造。
  String _workspaceTreeBlock() {
    try {
      final root = store.sub('sandbox');
      if (!root.existsSync()) return '';
      final lines = <String>[];
      String baseName(FileSystemEntity e) =>
          e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      String size(int bytes) {
        if (bytes < 1024) return '$bytes B';
        if (bytes < 1024 * 1024)
          return '${(bytes / 1024).toStringAsFixed(1)} KB';
        return '${(bytes / 1048576).toStringAsFixed(1)} MB';
      }

      void walk(Directory dir, String prefix, int depth) {
        if (depth > 2 || lines.length >= 80) return;
        final entries = dir.listSync(followLinks: false)
          ..sort(
            (FileSystemEntity a, FileSystemEntity b) =>
                baseName(a).compareTo(baseName(b)),
          );
        for (final e in entries) {
          if (lines.length >= 80) return;
          final name = baseName(e);
          if (name.startsWith('.')) continue;
          final rel = prefix.isEmpty ? name : '$prefix/$name';
          if (e is Directory) {
            lines.add('$rel/');
            walk(e, rel, depth + 1);
          } else if (e is File) {
            final lower = name.toLowerCase();
            if (lower.endsWith('.db') || lower.endsWith('.sqlite')) continue;
            lines.add('$rel (${size(e.statSync().size)})');
          }
        }
      }

      walk(root, '', 1);
      return lines.join('\n');
    } on Object {
      return '';
    }
  }

  /// 本轮云端流式已投递的 token 片数：>0 表示无需再补整段打字机。
  int _streamedRemoteTokens = 0;

  /// 把前端传来的完整 messages 转成标准 OpenAI messages，按 token 预算
  /// （以字符数近似）保留最近轮次，末尾重复的当前 user 轮去掉。
  List<Map<String, dynamic>> _historyFrom(Map<String, dynamic> p) {
    _streamedRemoteTokens = 0;
    final dynamic raw = p['messages'];
    if (raw is! List) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final dynamic m in raw) {
      if (m is! Map) continue;
      final String role = (m['role'] ?? '').toString();
      if (role != 'user' && role != 'assistant') continue;
      final String content = (m['content'] ?? '').toString().trim();
      if (content.isEmpty) continue;
      out.add(<String, dynamic>{'role': role, 'content': content});
    }
    final String text = (p['text'] ?? p['message'] ?? p['prompt'] ?? '')
        .toString()
        .trim();
    if (out.isNotEmpty &&
        out.last['role'] == 'user' &&
        out.last['content'] == text) {
      out.removeLast();
    }
    const int budget = 12000;
    int used = 0;
    int start = out.length;
    for (int i = out.length - 1; i >= 0; i--) {
      used += (out[i]['content'] as String).length;
      if (used > budget) break;
      start = i;
    }
    return out.sublist(start);
  }

  /// 跨会话长期记忆：turns 表真实落盘，取与本轮词项相关 / 最近的记录，
  /// 与当轮历史去重后注入 system，实现「新会话仍能召回长期事实」。
  Future<String> _persistentMemoryBlock(
    String text,
    String session,
    List<Map<String, dynamic>> history,
  ) async {
    try {
      final turns = await store.readRecords('turns');
      if (turns.isEmpty) return '';
      final Set<String> inHistory = history
          .map((Map<String, dynamic> m) => m['content'].toString())
          .toSet();
      final List<String> terms = <String>{
        ...text
            .toLowerCase()
            .split(RegExp(r'[\s,，。？?！!、]+'))
            .where((String s) => s.length >= 2),
      }.toList();
      int score(Map<String, dynamic> t) {
        final String body = (t['text'] ?? '').toString().toLowerCase();
        int s = 0;
        for (final String term in terms) {
          if (body.contains(term)) s += 2;
        }
        return s;
      }

      final List<Map<String, dynamic>> pool = turns.reversed.take(120).toList();
      pool.sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            score(b).compareTo(score(a)),
      );
      final List<String> lines = <String>[];
      for (final Map<String, dynamic> t in pool) {
        if (lines.length >= 8) break;
        final String role = (t['role'] ?? '').toString();
        if (role != 'user' && role != 'assistant') continue;
        final String body = (t['text'] ?? '').toString().trim();
        if (body.isEmpty || body == text || inHistory.contains(body)) continue;
        if (body.length > 240) continue;
        lines.add('- [$role] $body');
      }
      if (lines.isEmpty) return '';
      return '\n\n【长期记忆（本机真实对话记录，跨会话召回）】\n'
          '${lines.join('\n')}\n'
          '以上是既往事实，回答时可直接引用；当前会话以本轮 messages 为准。';
    } on Object {
      return '';
    }
  }

  /// 让模型知道自己拥有一台 Linux：能力与当前沙箱模式如实标注，
  /// 命令经 shell 工具执行，终端与模型共用同一套 shell / cwd / 已装依赖。
  Future<String> _linuxCapabilityBlock() async {
    final String env = await _sandboxEnvironment();
    final bool android = Platform.isAndroid;
    // 环境描述只按「唯一那套环境」如实给出：安卓端不描述宿主 toybox，
    // 桌面端才可能切换到远端 SSH / TCP 桥。
    final String pkgHint = proot.profile == 'alpine'
        ? 'apk 装包、python3 / pip 可用'
        : 'apt/dpkg 原生可用（pkg 是 apt-get 的封装）、python3 / pip 可用';
    final String mode = android
        ? (proot.installed
              ? '内置沙箱（安卓上唯一一套 Linux 用户态：proot + ${proot.distroLabel}；'
                    '$pkgHint，App 沙箱目录在 Linux 内是 /workspace）'
              : '内置沙箱（安卓上唯一一套 Linux 用户态，当前尚未完成初始化；'
                    '首次执行命令会自动真实下载 proot + ${proot.distroLabel}，'
                    '装好前会如实返回进度）')
        : (env.contains('SSH')
              ? '远端沙箱（SSH）：命令在远端 Linux 真实执行'
              : '$env（系统真实 shell）');
    return '\n\n【你的 Linux 环境】$mode'
        '可以安装依赖、编译运行代码、读写文件、调用命令行工具。'
        '需要执行命令时，在回答中输出一个 tga-shell 代码块，格式严格为：\n'
        '```tga-shell\n要执行的命令\n```\n'
        '系统会在沙箱里真实执行并把 stdout/stderr 与退出码回传给你，'
        '你再据此继续推理并给出最终答案；不要声称无法执行、不要编造命令输出。'
        '只有确实需要执行时才输出该代码块，普通代码示例请用常规语言标记。'
        '只按真实探测结果描述机器（内核、uid、磁盘、已装工具），'
        '不要把同一台机器说成两套环境；若系统提示降级为内置解释器，'
        '可用命令范围会如实给出，不要假装完整 Linux。';
  }

  /// 模型发起 shell 工具调用的显式协议块。用专有标记而非通用 ```bash，
  /// 避免把回答里的普通代码示例误当成命令执行。
  static final RegExp _shellCallBlock = RegExp(
    r'```tga-shell\s*\n([\s\S]*?)```',
    caseSensitive: false,
  );

  /// 工具回环：真实执行模型给出的 shell 块，把输出回灌后让模型继续推理。
  /// 对不支持 function calling 的网关也生效；最多 3 轮防止死循环。
  Future<String> _resolveShellLoops({
    required String first,
    required String text,
    required String apiBase,
    required String apiKey,
    required String model,
    required String system,
    required double temperature,
    required int maxTokens,
    required double topP,
    required List<Map<String, dynamic>> history,
  }) async {
    final StringBuffer transcript = StringBuffer(first);
    final List<Map<String, dynamic>> loopHistory = <Map<String, dynamic>>[
      ...history,
    ];
    String pending = first;
    for (int round = 0; round < 3; round++) {
      final List<RegExpMatch> calls = _shellCallBlock
          .allMatches(pending)
          .toList();
      if (calls.isEmpty) break;
      final StringBuffer observations = StringBuffer();
      for (final RegExpMatch m in calls) {
        final String cmd = (m.group(1) ?? '').trim();
        if (cmd.isEmpty) continue;
        _emit('chat_status', <String, dynamic>{
          'phase': 'shell',
          'command': cmd.length > 200 ? cmd.substring(0, 200) : cmd,
        });
        final ToolResult r = await tools.run('shell', <String, dynamic>{
          'command': cmd,
        });
        final String out = r.ok ? r.content : '执行失败：${r.error}';
        observations.writeln('命令 `$cmd` 的真实输出：\n$out');
      }
      if (observations.isEmpty) break;
      final String observationText = '\n\n【沙箱执行结果（真实）】\n$observations\n';
      transcript.write(observationText);
      _emit('stream_token', <String, dynamic>{'token': observationText});

      loopHistory.add(<String, dynamic>{
        'role': 'assistant',
        'content': pending,
      });
      const String toolMsg =
          '以上是你刚才在沙箱里执行命令的真实输出。'
          '请据此继续完成任务并给出最终回答；如无必要，不要重复执行相同命令，'
          '也不要再输出 tga-shell 代码块。';
      final follow = await _remoteChat(
        apiBase: apiBase,
        apiKey: apiKey,
        model: model,
        text: toolMsg,
        system: system,
        temperature: temperature,
        maxTokens: maxTokens,
        topP: topP,
        history: List<Map<String, dynamic>>.of(loopHistory),
        onDelta: (String d) =>
            _emit('stream_token', <String, dynamic>{'token': d}),
      );
      loopHistory.add(<String, dynamic>{'role': 'user', 'content': toolMsg});
      final String answer = follow.ok
          ? follow.content
          : '（工具结果回灌后推理失败：${follow.error}）';
      transcript.write(answer);
      pending = answer;
      if (!follow.ok) break;
    }
    return transcript.toString();
  }

  Iterable<String> _chunks(String s, int size) sync* {
    // 按 Unicode codepoint 分片，避免 substring 切断 emoji 代理对。
    final List<int> runes = s.runes.toList();
    for (var i = 0; i < runes.length; i += size) {
      final end = i + size > runes.length ? runes.length : i + size;
      yield String.fromCharCodes(runes.sublist(i, end));
    }
  }

  static double _asDouble(dynamic v, double fallback) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  static int _asInt(dynamic v, int fallback) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  // ---- 多模型群聊：并发提问 + 交叉比对 + 主持人裁决 ----

  Future<Map<String, dynamic>> _modelGroup(Map<String, dynamic> p) async {
    final String prompt = (p['text'] ?? p['prompt'] ?? '').toString().trim();
    if (prompt.isEmpty) return _err('群聊问题为空');
    final dynamic raw = p['models'];
    if (raw is! List || raw.isEmpty) {
      return _err('至少选择一个模型；每个成员需包含 name 与参数');
    }
    if (raw.length > 6) return _err('单次最多 6 个模型，避免并发过载');
    final List<Map<String, dynamic>> members = raw
        .whereType<Map>()
        .map((Map e) => Map<String, dynamic>.from(e))
        .toList();
    final String groupSystem =
        '你是多模型群聊中的一员。独立回答用户问题，'
        '先给结论再给依据；不确定的内容明确标注，不要编造事实。';
    final List<Map<String, dynamic>> replies = await Future.wait(
      members.map((Map<String, dynamic> m) async {
        final String name = (m['name'] ?? '模型').toString();
        final int t0 = DateTime.now().millisecondsSinceEpoch;
        try {
          final String apiBase = (m['api_base'] ?? '').toString();
          final String apiKey = (m['api_key'] ?? '').toString();
          final String model = (m['model'] ?? '').toString();
          final bool free = m['free'] == true;
          if (apiBase.isNotEmpty &&
              model.isNotEmpty &&
              (apiKey.isNotEmpty || free)) {
            final r = await _remoteChat(
              apiBase: apiBase,
              apiKey: apiKey,
              model: model,
              text: prompt,
              system: groupSystem,
              temperature: 0.7,
              maxTokens: 1024,
              topP: 0.9,
            );
            return <String, dynamic>{
              'name': name,
              'ok': r.ok,
              'reply': r.content,
              'engine': 'remote-http',
              'error': r.error,
              'ms': DateTime.now().millisecondsSinceEpoch - t0,
            };
          }
          final Map<String, dynamic> local = await _chat(<String, dynamic>{
            'text': prompt,
            'system': groupSystem,
            'session_id': 'model-group',
            'model_kind': (m['model_kind'] ?? 'builtin').toString(),
            if ((m['local_model_path'] ?? '').toString().isNotEmpty)
              'local_model_path': m['local_model_path'],
          });
          return <String, dynamic>{
            'name': name,
            'ok': local['ok'] != false,
            'reply': (local['reply'] ?? local['error'] ?? '').toString(),
            'engine': (local['engine'] ?? '').toString(),
            'error': local['ok'] == false ? (local['error'] ?? '') : '',
            'ms': DateTime.now().millisecondsSinceEpoch - t0,
          };
        } on Object catch (e) {
          return <String, dynamic>{
            'name': name,
            'ok': false,
            'reply': '',
            'engine': '',
            'error': '$e',
            'ms': DateTime.now().millisecondsSinceEpoch - t0,
          };
        }
      }),
    );
    final List<Map<String, dynamic>> good = replies
        .where(
          (Map<String, dynamic> r) =>
              r['ok'] == true &&
              (r['reply'] ?? '').toString().trim().isNotEmpty,
        )
        .toList();
    if (good.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': '所有模型均未能返回内容（详见 replies）',
        'replies': replies,
      };
    }
    final StringBuffer compare = StringBuffer()
      ..writeln('用户问题：$prompt')
      ..writeln('以下是 ${good.length} 个模型的独立回答：');
    for (int i = 0; i < good.length; i++) {
      final String reply = good[i]['reply'].toString();
      compare.writeln('【${i + 1}. ${good[i]['name']}】');
      compare.writeln(
        reply.length > 3000 ? '${reply.substring(0, 3000)}…' : reply,
      );
    }
    compare.writeln(
      '请作为主持人：先列出一致结论，再指出分歧与各自依据，'
      '最后给出你的裁决与仍不确定的部分；不要编造任何模型没说过的内容。',
    );

    String synthesis = '';
    String synthEngine = '';
    final dynamic agg = p['aggregator'];
    try {
      if (agg is Map &&
          (agg['api_base'] ?? '').toString().isNotEmpty &&
          (agg['model'] ?? '').toString().isNotEmpty) {
        final r = await _remoteChat(
          apiBase: agg['api_base'].toString(),
          apiKey: (agg['api_key'] ?? '').toString(),
          model: agg['model'].toString(),
          text: compare.toString(),
          system: '你是冷静、严谨的多模型讨论主持人。',
          temperature: 0.3,
          maxTokens: 1200,
          topP: 0.9,
        );
        synthesis = r.content;
        synthEngine = 'remote-http';
        if (!r.ok) synthesis = '主持模型失败：${r.error}';
      } else {
        final Map<String, dynamic> r = await _chat(<String, dynamic>{
          'text': compare.toString(),
          'session_id': 'model-group-synthesis',
        });
        synthesis = (r['reply'] ?? r['error'] ?? '').toString();
        synthEngine = (r['engine'] ?? '').toString();
      }
    } on Object catch (e) {
      synthesis = '汇总失败：$e';
    }
    _emit('model_group_result', <String, dynamic>{
      'models': replies.length,
      'succeeded': good.length,
    });
    return <String, dynamic>{
      'ok': true,
      'replies': replies,
      'succeeded': good.length,
      'synthesis': synthesis,
      'synthesis_engine': synthEngine,
    };
  }

  /// 云端 OpenAI 兼容推理：默认走 SSE 真流式，首字延迟从「整段生成完」
  /// 降到「第一个 token」；历史轮次按标准 messages 一并转发。
  /// 网关不支持流式时自动回退一次性请求，不丢回答、不编造内容。
  Future<({bool ok, String content, String error})> _remoteChat({
    required String apiBase,
    required String apiKey,
    required String model,
    required String text,
    required String system,
    required double temperature,
    required int maxTokens,
    required double topP,
    List<Map<String, dynamic>> history = const <Map<String, dynamic>>[],
    void Function(String delta)? onDelta,
  }) async {
    final uri = Uri.parse(
      '${apiBase.replaceAll(RegExp(r'/+$'), '')}/chat/completions',
    );
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
      // 免费端点（Kilo :free）实测不带 Authorization 头即可 200；
      // 空 Key 时省略该头，避免部分网关对 "Bearer " 直接 401。
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
    final Map<String, dynamic> body = <String, dynamic>{
      'model': model,
      'messages': <Map<String, dynamic>>[
        if (system.isNotEmpty)
          <String, dynamic>{'role': 'system', 'content': system},
        ...history,
        <String, dynamic>{'role': 'user', 'content': text},
      ],
      'temperature': temperature,
      'max_tokens': maxTokens,
      'top_p': topP,
      'stream': true,
    };
    try {
      // 流式请求用底层 Client.send 拿增量字节，按 SSE 行解析 delta，
      // 边收边上报，避免 http.post 必须等整段生成完导致的数十秒白屏。
      final http.Client client = http.Client();
      try {
        final http.Request req = http.Request('POST', uri)
          ..headers.addAll(headers)
          ..body = jsonEncode(body);
        final http.StreamedResponse resp = await client
            .send(req)
            .timeout(const Duration(seconds: 90));
        if (resp.statusCode != 200) {
          final String raw = await utf8.decoder.bind(resp.stream).join();
          return (
            ok: false,
            content: '',
            error: 'HTTP ${resp.statusCode}：${_brief(raw)}',
          );
        }
        final StringBuffer buf = StringBuffer();
        String carry = '';
        await for (final String chunk
            in utf8.decoder
                .bind(resp.stream)
                .timeout(const Duration(seconds: 90))) {
          carry += chunk;
          int nl;
          while ((nl = carry.indexOf('\n')) >= 0) {
            final String line = carry.substring(0, nl).trim();
            carry = carry.substring(nl + 1);
            if (line.isEmpty || !line.startsWith('data:')) continue;
            final String data = line.substring(5).trim();
            if (data == '[DONE]') break;
            final dynamic decoded = jsonDecode(data);
            if (decoded is! Map) continue;
            final dynamic choices = decoded['choices'];
            if (choices is! List || choices.isEmpty) continue;
            final dynamic first = choices.first;
            if (first is! Map) continue;
            final dynamic delta = first['delta'];
            if (delta is! Map) continue;
            final String piece = (delta['content'] ?? '').toString();
            if (piece.isEmpty) continue;
            buf.write(piece);
            _streamedRemoteTokens++;
            onDelta?.call(piece);
          }
        }
        final String content = buf.toString();
        if (content.isNotEmpty) return (ok: true, content: content, error: '');
        // 网关返回 200 但没给增量（不支持 stream）：回退一次性请求。
      } finally {
        client.close();
      }
      final http.Response plain = await http
          .post(
            uri,
            headers: headers,
            body: jsonEncode(<String, dynamic>{...body, 'stream': false}),
          )
          .timeout(const Duration(seconds: 90));
      if (plain.statusCode != 200) {
        return (ok: false, content: '', error: 'HTTP ${plain.statusCode}');
      }
      final dynamic decoded = jsonDecode(utf8.decode(plain.bodyBytes));
      if (decoded is Map) {
        final dynamic choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final dynamic msg = (choices.first as Map)['message'];
          if (msg is Map) {
            final String content = (msg['content'] ?? '').toString();
            if (content.isNotEmpty) {
              return (ok: true, content: content, error: '');
            }
          }
        }
      }
      return (ok: false, content: '', error: '响应结构不符合预期');
    } on Object catch (e) {
      return (ok: false, content: '', error: '$e');
    }
  }

  static String _brief(String raw) =>
      raw.length > 120 ? raw.substring(0, 120) : raw;

  /// 内置 AgentLoop：先做意图路由，命中就调用真实工具，把工具观测结果
  /// 组织成回答；未命中时基于真实记忆做检索式回应。全程不编造事实。
  Future<String> _agentLoop(
    String text,
    String session,
    Map<String, dynamic> p,
  ) async {
    final trace = TrajectorySnapshot(
      text,
    ).append(TrajectoryCellKind.user, text);

    // 1) 纯表达式（含常见数学问法）→ 真实求值工具
    final expr = _extractExpression(text);
    if (expr != null) {
      final r = await tools.run('evaluate', <String, dynamic>{
        'expression': expr,
      });
      final snap = trace
          .append(TrajectoryCellKind.tool, 'evaluate($expr)')
          .append(TrajectoryCellKind.result, r.content);
      _emit('trajectory', snap.toJson());
      return r.ok
          ? '计算结果：`$expr` = **${r.content}**\n\n'
                '（由内置安全表达式求值器真实计算，沙箱内无 I/O、无副作用。）'
          : '这个表达式没能求值：${r.error}';
    }

    // 2) 显式工具指令 / 关键词路由
    final route = _routeIntent(text);
    if (route != null) {
      final r = await tools.run(route.$1, route.$2);
      final snap = trace
          .append(TrajectoryCellKind.tool, '${route.$1}(${route.$2})')
          .append(TrajectoryCellKind.result, r.content);
      _emit('trajectory', snap.toJson());
      return r.ok ? r.content : '工具执行失败：${r.error}';
    }

    // 3) 记忆检索式回应：用真实落盘的对话轮次做词项打分
    final turns = await store.readRecords('turns');
    final hits = _retrieve(text, turns);
    final snap = trace.append(
      TrajectoryCellKind.context,
      hits.isEmpty ? '无相关记忆' : '命中 ${hits.length} 条记忆',
    );
    _emit('trajectory', snap.toJson());

    final buf = StringBuffer();
    buf.writeln(
      '我是 **TGA 内置本地引擎**（纯 Dart AgentLoop），'
      '当前没有加载外部大模型，所以不会编造一个看似聪明的答案。',
    );
    buf.writeln();
    if (hits.isNotEmpty) {
      buf.writeln('我在本地记忆里找到这些相关记录：');
      for (final h in hits.take(3)) {
        buf.writeln('- ${_preview(h)}');
      }
      buf.writeln();
    } else {
      buf.writeln('本地记忆里暂时没有与这句话相关的内容。');
      buf.writeln();
    }
    buf.writeln('现在就能真实做到的事（直接在对话框输入即可）：');
    buf.writeln('- **算数**：输入 `2 + 3 * 4` 或 `计算 sqrt(144)`');
    buf.writeln('- **能力清单**：输入 `/help` 或 `你能做什么`');
    buf.writeln('- **本地状态**：输入 `/status`、`/models`、`/memory`');
    buf.writeln('- **记住事情**：输入 `/remember 项目X的截止日是周五`');
    buf.writeln('- **运行自测**：输入 `/selftest` 或 `运行测试`');
    buf.writeln();
    buf.writeln(
      '需要真正的语言模型对话，请在蒸馏面板配置 OpenAI 兼容 API 凭据，'
      '或下载本地 GGUF 模型；配置后我会真实调用，绝不伪造回复。',
    );
    return buf.toString();
  }

  String? _extractExpression(String text) {
    var t = text.trim();
    t = t.replaceAll(
      RegExp(
        r'^(请|帮我|计算|算一下|算算|求值|evaluate|calc)\s*[:：,，]?\s*',
        caseSensitive: false,
      ),
      '',
    );
    t = t.replaceAll(RegExp(r'[?？。！!＝=]\s*$'), '').trim();
    // 允许数字、运算符、括号、白名单函数/变量、字符串、比较与三元。
    final allowed = RegExp(
      r'^[\d\s\+\-\*/\%\(\)\.\,\?\:\<\>\!\&\|\"\x27A-Za-z_]+$',
    );
    if (!allowed.hasMatch(t)) return null;
    if (!RegExp(r'\d').hasMatch(t)) return null; // 至少有数字
    if (!RegExp(r'[\+\-\*/\%\(\)]').hasMatch(t)) return null; // 有运算
    // 排除可疑关键字
    if (RegExp(
      r'\b(import|eval|exec|system|process|file|http|dart|new|var)\b',
      caseSensitive: false,
    ).hasMatch(t)) {
      return null;
    }
    try {
      SafeExpression.eval(t);
      return t;
    } on Object {
      return null;
    }
  }

  /// 智能搜索：真实抓取搜索结果页（必应 CN 优先 + DuckDuckGo 兜底），
  /// 解析标题+摘要+链接。失败或无结果返回空串，由调用方如实说明，绝不编造。
  Future<String> _webSearch(String query) async {
    // 多源并行（提速）：必应 CN（国内可达）与 DuckDuckGo（海外可用）同时
    // 发起，最坏延迟从串行 ~16s 压到单源超时 ~8s。两源都成功时优先必应，
    // 保持原有优先级语义；任一失败/超时不影响另一源。绝不编造结果。
    final List<String> results = await Future.wait<String>(<Future<String>>[
      _scrapeBing(query),
      _scrapeDdg(query),
    ]);
    final String bing = results[0];
    if (bing.isNotEmpty) return bing;
    return results[1];
  }

  Future<String> _scrapeBing(String query) async {
    try {
      final uri = Uri.https('cn.bing.com', '/search', <String, String>{
        'q': query,
      });
      final resp = await http
          .get(
            uri,
            headers: <String, String>{
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                  ' (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
              'Accept-Language': 'zh-CN,zh;q=0.9',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return '';
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final itemRe = RegExp(
        r'<li class="b_algo[^"]*">([\s\S]{0,1800}?)</li>',
        dotAll: true,
      );
      final linkRe = RegExp(
        r'<h2[^>]*><a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>',
        dotAll: true,
      );
      final snipRe = RegExp(r'<p[^>]*>([\s\S]*?)</p>', dotAll: true);
      final buf = StringBuffer();
      var n = 0;
      for (final m in itemRe.allMatches(body)) {
        if (n >= 5) break;
        final block = m.group(1) ?? '';
        final link = linkRe.firstMatch(block);
        if (link == null) continue;
        final title = _stripTags(link.group(2) ?? '');
        if (title.isEmpty) continue;
        n++;
        final url = link.group(1) ?? '';
        final snip = _stripTags(snipRe.firstMatch(block)?.group(1) ?? '');
        buf.writeln('$n. $title');
        if (snip.isNotEmpty) {
          buf.writeln(
            '   ${snip.length > 160 ? '${snip.substring(0, 160)}…' : snip}',
          );
        }
        if (url.startsWith('http')) buf.writeln('   来源：$url');
      }
      return buf.toString().trim();
    } on Object {
      return '';
    }
  }

  Future<String> _scrapeDdg(String query) async {
    try {
      final uri = Uri.https('html.duckduckgo.com', '/html/', <String, String>{
        'q': query,
      });
      final resp = await http
          .get(
            uri,
            headers: <String, String>{
              'User-Agent':
                  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
            },
          )
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return '';
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final titleRe = RegExp(
        r'<a[^>]*class="result__a"[^>]*>(.*?)</a>',
        dotAll: true,
      );
      final snipRe = RegExp(
        r'<a[^>]*class="result__snippet"[^>]*>(.*?)</a>',
        dotAll: true,
      );
      final hrefRe = RegExp(
        r'<a[^>]*class="result__a"[^>]*href="([^"]*)"',
        dotAll: true,
      );
      final titles = titleRe
          .allMatches(body)
          .take(5)
          .map((m) => _stripTags(m.group(1)!))
          .toList();
      final snips = snipRe
          .allMatches(body)
          .take(5)
          .map((m) => _stripTags(m.group(1)!))
          .toList();
      final hrefs = hrefRe.allMatches(body).take(5).map((m) {
        final raw = Uri.decodeComponent(m.group(1) ?? '');
        final u = Uri.tryParse(raw);
        final q = u?.queryParameters['u'];
        return q != null && q.isNotEmpty ? q : raw;
      }).toList();
      final buf = StringBuffer();
      for (var i = 0; i < titles.length; i++) {
        buf.writeln('${i + 1}. ${titles[i]}');
        if (i < snips.length && snips[i].isNotEmpty) {
          buf.writeln('   ${snips[i]}');
        }
        if (i < hrefs.length && hrefs[i].startsWith('http')) {
          buf.writeln('   来源：${hrefs[i]}');
        }
      }
      return buf.toString().trim();
    } on Object {
      return '';
    }
  }

  String _stripTags(String html) {
    var s = html.replaceAll(RegExp(r'<[^>]*>'), '');
    s = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&nbsp;', ' ');
    return s.trim();
  }

  (String, Map<String, dynamic>)? _routeIntent(String text) {
    final t = text.trim();
    // 随消息附上的真实文件内容，优先交给附件解析工具处理。
    if (t.contains('[附件]')) {
      return ('attachment_summary', <String, dynamic>{'text': t});
    }
    if (t.startsWith('/')) {
      final parts = t.substring(1).split(RegExp(r'\s+'));
      final cmd = parts.first.toLowerCase();
      final rest = parts.length > 1 ? parts.sublist(1).join(' ') : '';
      switch (cmd) {
        case 'help':
          return ('capabilities', <String, dynamic>{});
        case 'status':
          return ('self_test', <String, dynamic>{});
        case 'selftest':
          return ('self_test', <String, dynamic>{});
        case 'time':
          return ('current_time', <String, dynamic>{});
        case 'models':
          return ('list_models', <String, dynamic>{});
        case 'memory':
          return ('recall', <String, dynamic>{'query': rest});
        case 'recall':
          return ('recall', <String, dynamic>{'query': rest});
        case 'remember':
          return ('remember', <String, dynamic>{'text': rest});
        case 'sandbox':
          return ('sandbox_eval', <String, dynamic>{'expression': rest});
      }
    }
    if (RegExp(r'你能做什么|有什么功能|能力|帮助|help', caseSensitive: false).hasMatch(t) &&
        t.length < 24) {
      return ('capabilities', <String, dynamic>{});
    }
    if (RegExp(r'运行测试|自测|自检|selftest', caseSensitive: false).hasMatch(t) &&
        t.length < 20) {
      return ('self_test', <String, dynamic>{});
    }
    if (RegExp(r'几点|现在时间|当前时间|今天几号|日期', caseSensitive: false).hasMatch(t) &&
        t.length < 20) {
      return ('current_time', <String, dynamic>{});
    }
    if (RegExp(r'有哪些模型|模型列表|已下载模型', caseSensitive: false).hasMatch(t) &&
        t.length < 20) {
      return ('list_models', <String, dynamic>{});
    }
    if (RegExp(r'记住|记一下|备忘', caseSensitive: false).hasMatch(t) &&
        t.length < 80) {
      return ('remember', <String, dynamic>{'text': t});
    }
    // MCP 已注册工具：消息里出现工具名即真实调用（key=value 传参）。
    for (final fullName in _mcpToolNames) {
      final short = fullName.split('.').last;
      if (short.length > 2 && t.contains(short.toLowerCase())) {
        final args = <String, dynamic>{};
        for (final m in RegExp(r'(\w+)=([^\s]+)').allMatches(text)) {
          args[m.group(1)!] = m.group(2)!;
        }
        return (fullName, args);
      }
    }
    return null;
  }

  /// 真实解析消息里的附件块：统计行数、字符数并给出开头预览。
  /// 只读用户随消息附上的文本，不编造任何不存在的内容。
  String _summarizeAttachments(String raw) {
    final parts = raw.split(RegExp(r'(?=\[附件\])'));
    final buf = StringBuffer('**附件已接收并真实解析**\n\n');
    var count = 0;
    for (final String block in parts) {
      if (!block.contains('[附件]')) continue;
      count++;
      final lines = block.trim().split('\n');
      buf.writeln('$count. ${lines.first.trim()}');
      final start = lines.indexWhere((l) => l.trim() == '--- 文件内容 ---');
      final end = lines.indexWhere((l) => l.trim() == '--- 内容结束 ---');
      if (start >= 0 && end > start) {
        final content = lines.sublist(start + 1, end);
        final joined = content.join('\n');
        buf.writeln('   - 文本行数：${content.length}');
        buf.writeln('   - 字符数：${joined.length}');
        final preview = content
            .take(4)
            .map((l) => l.length > 90 ? '${l.substring(0, 90)}…' : l)
            .where((l) => l.trim().isNotEmpty)
            .join(' / ');
        if (preview.isNotEmpty) buf.writeln('   - 开头预览：$preview');
      } else {
        buf.writeln('   - 二进制或不可解码：仅登记元信息，未伪造文本内容。');
      }
    }
    if (count == 0) return '消息里没有可解析的附件块。';
    buf.writeln('\n附件内容已进入本次对话上下文，可以直接基于它继续提问。');
    return buf.toString();
  }

  List<String> _retrieve(String query, List<Map<String, dynamic>> turns) {
    final q = <String>{
      ...RegExp(
        r'[\u4e00-\u9fa5]{2,}|[A-Za-z]{3,}|\d{2,}',
      ).allMatches(query).map((m) => m.group(0)!.toLowerCase()),
    };
    if (q.isEmpty) return <String>[];
    final scored = <(String, int)>[];
    for (final t in turns) {
      final text = (t['text'] ?? '').toString();
      if (text.length > 600) continue;
      var score = 0;
      for (final term in q) {
        if (text.toLowerCase().contains(term)) score++;
      }
      if (score > 0) scored.add((text, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.map((e) => e.$1).toList();
  }

  String _preview(String s) {
    final one = s.replaceAll('\n', ' ').trim();
    return one.length > 90 ? '${one.substring(0, 90)}…' : one;
  }

  // ---- 工具注册（真实执行体）----

  /// 浏览器工具未显式指定智能体时：优先用给定电脑上的第一个智能体，
  /// 没有则真实创建一个名为「助手」的智能体（工作区与 profile 都会落盘）。
  Future<Map<String, dynamic>> _resolveComputerBot(
    String botId,
    String computerId,
  ) async {
    if (botId.isNotEmpty) {
      return <String, dynamic>{'ok': true, 'bot_id': botId};
    }
    final Map<String, dynamic> list =
        await computer.handle('list', <String, dynamic>{});
    if (list['ok'] != true) {
      return <String, dynamic>{'ok': false, 'error': '读取 Team Computer 失败'};
    }
    final List<dynamic> comps =
        (list['computers'] as List?) ?? const <dynamic>[];
    if (comps.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '本机没有 Team Computer'};
    }
    Map<dynamic, dynamic>? target;
    for (final dynamic raw in comps) {
      if (raw is! Map) continue;
      if (computerId.isNotEmpty && '${raw['id']}' == computerId) {
        target = raw;
        break;
      }
    }
    target ??= comps.first as Map;
    final String cid = '${target['id']}';
    final Map<String, dynamic> bots = await computer.handle(
      'bots',
      <String, dynamic>{'computer_id': cid},
    );
    final List<dynamic> existing =
        (bots['bots'] as List?) ?? const <dynamic>[];
    if (existing.isNotEmpty && existing.first is Map) {
      return <String, dynamic>{
        'ok': true,
        'bot_id': '${(existing.first as Map)['id']}',
        'computer_id': cid,
      };
    }
    final Map<String, dynamic> created = await computer.handle(
      'add_bot',
      <String, dynamic>{'computer_id': cid, 'name': '助手'},
    );
    if (created['ok'] != true) {
      return <String, dynamic>{
        'ok': false,
        'error': '${created['error'] ?? '创建默认智能体失败'}',
      };
    }
    final Map<dynamic, dynamic> bot = created['bot'] as Map;
    return <String, dynamic>{
      'ok': true,
      'bot_id': '${bot['id']}',
      'computer_id': cid,
    };
  }

  void _registerTools() {
    tools.registerAll(<AgentTool>[
      AgentTool(
        name: 'evaluate',
        description: '安全求值算术/逻辑表达式，无 I/O、无副作用',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'expression': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['expression'],
        },
        execute: (args, _) async {
          try {
            final v = SafeExpression.eval(args['expression'].toString());
            return ToolResult.ok(_formatValue(v));
          } on Object catch (e) {
            return ToolResult.error('$e');
          }
        },
      ),
      AgentTool(
        name: 'capabilities',
        description: '列出内置 AgentLoop 的全部真实工具与控制域',
        tier: ApprovalTier.read,
        execute: (args, _) async {
          final buf = StringBuffer('**TGA 内置能力清单（全部真实可用）**\n\n');
          for (final t in tools.tools) {
            buf.writeln('- `${t.name}`（${t.tier.name}）：${t.description}');
          }
          buf.writeln(
            '\n控制域 ${controlDomains.length} 个：'
            '${controlDomains.join('、')}',
          );
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'page_list',
        description: '列出本机 Agent Pages（可版本化的看板 / 文档）',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'query': <String, dynamic>{'type': 'string'},
          },
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await pages.list(
            query: (args['query'] ?? '').toString(),
          );
          final List<dynamic> items = r['pages'] is List
              ? r['pages'] as List
              : <dynamic>[];
          if (items.isEmpty) return ToolResult.ok('本机还没有 Page。');
          final StringBuffer buf = StringBuffer(
            '**本机 Pages（${items.length}）**\n',
          );
          for (final dynamic raw in items) {
            if (raw is! Map) continue;
            buf.writeln(
              '- `${raw['id']}` ${raw['title']}（v${raw['current_version']}'
              '${raw['pinned'] == true ? '，置顶' : ''}）',
            );
          }
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'page_publish',
        description: '创建或更新一个 Page；每次更新追加新版本，HTML 上限 2MB',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'title': <String, dynamic>{'type': 'string'},
            'html': <String, dynamic>{'type': 'string'},
            'page_id': <String, dynamic>{
              'type': 'string',
              'description': '留空则新建；填写已有 id 则追加版本',
            },
          },
          'required': <String>['title', 'html'],
        },
        execute: (args, _) async {
          final String id = (args['page_id'] ?? '').toString().trim();
          final Map<String, dynamic> r = id.isEmpty
              ? await pages.create(
                  title: (args['title'] ?? '').toString(),
                  html: (args['html'] ?? '').toString(),
                  botId: 'agent',
                )
              : await pages.save(
                  id,
                  (args['html'] ?? '').toString(),
                  title: (args['title'] ?? '').toString().trim().isEmpty
                      ? null
                      : (args['title'] ?? '').toString(),
                );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '保存 Page 失败'}');
          }
          final Map<String, dynamic> page = Map<String, dynamic>.from(
            r['page'] as Map,
          );
          return ToolResult.ok(
            '已保存 Page「${page['title']}」v${page['current_version']}\n'
            'tga://pages/${page['id']}',
            data: page,
          );
        },
      ),
      AgentTool(
        name: 'routine_list',
        description: '列出本机 Routine（定时例程）及其下次运行时间',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'query': <String, dynamic>{'type': 'string'},
            'active_only': <String, dynamic>{'type': 'boolean'},
          },
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await _routine(<String, dynamic>{
            'action': 'list',
            'query': (args['query'] ?? '').toString(),
            'active_only': args['active_only'] == true,
          });
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取 Routine 失败'}');
          }
          final List<dynamic> items =
              (r['routines'] as List?) ?? const <dynamic>[];
          if (items.isEmpty) return ToolResult.ok('本机还没有 Routine。');
          final StringBuffer buf = StringBuffer(
            '**本机 Routine（${items.length}）**\n',
          );
          for (final dynamic raw in items) {
            if (raw is! Map) continue;
            final String next = (raw['next_run_at'] ?? '').toString();
            buf.writeln(
              '- `${raw['id']}` ${raw['name']}'
              '（${raw['active'] == true ? '启用' : '暂停'}，'
              '${formatCrons(
                (raw['crons'] as List? ?? const <dynamic>[])
                    .map((dynamic e) => e.toString())
                    .toList(),
              )}'
              '${next.isEmpty ? '' : '，下次 ${formatRunAt(DateTime.parse(next))}'}）',
            );
          }
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'routine_create',
        description: '创建定时 Routine（cron + 时区），到点自动执行提示词',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'name': <String, dynamic>{'type': 'string'},
            'prompt': <String, dynamic>{'type': 'string'},
            'crons': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
              'description': '5 段 cron，如 "30 9 * * 1-5"；一次性用 @once + once_at',
            },
            'timezone': <String, dynamic>{
              'type': 'string',
              'description': 'local / UTC / Asia/Shanghai / UTC+8',
            },
            'once_at': <String, dynamic>{
              'type': 'string',
              'description': 'ISO 时间；仅 @once 使用',
            },
            'active': <String, dynamic>{'type': 'boolean'},
          },
          'required': <String>['name', 'prompt', 'crons'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await _routine(<String, dynamic>{
            'action': 'create',
            'name': (args['name'] ?? '').toString(),
            'prompt': (args['prompt'] ?? '').toString(),
            'crons': args['crons'] is List ? args['crons'] : <dynamic>[],
            'timezone': (args['timezone'] ?? 'local').toString(),
            'once_at': args['once_at'],
            'active': args['active'] != false,
          });
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '创建 Routine 失败'}');
          }
          final Map<dynamic, dynamic> routine = r['routine'] as Map;
          return ToolResult.ok(
            '已创建 Routine「${routine['name']}」\n'
            '时间表：${formatCrons(
              (routine['crons'] as List? ?? const <dynamic>[])
                  .map((dynamic e) => e.toString())
                  .toList(),
            )}\n'
            '时区：${routine['timezone']}',
            data: Map<String, dynamic>.from(routine),
          );
        },
      ),
      AgentTool(
        name: 'routine_run',
        description: '立即执行一条 Routine 并返回真实结果',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['id'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await _routine(<String, dynamic>{
            'action': 'run',
            'id': (args['id'] ?? '').toString(),
          });
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '执行 Routine 失败'}');
          }
          final String result = (r['result'] ?? '').toString().trim();
          return ToolResult.ok(
            result.isEmpty ? 'Routine 已执行（后端未返回文本）' : result,
            data: Map<String, dynamic>.from(r),
          );
        },
      ),
      AgentTool(
        name: 'routine_history',
        description: '查看一条 Routine 的最近运行记录',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
            'limit': <String, dynamic>{'type': 'integer'},
          },
          'required': <String>['id'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await _routine(<String, dynamic>{
            'action': 'history',
            'id': (args['id'] ?? '').toString(),
            'limit': args['limit'] ?? 10,
          });
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取运行历史失败'}');
          }
          final List<dynamic> runs =
              (r['runs'] as List?) ?? const <dynamic>[];
          if (runs.isEmpty) return ToolResult.ok('这条 Routine 还没有运行记录。');
          final StringBuffer buf = StringBuffer('**最近运行**\n');
          for (final dynamic raw in runs) {
            if (raw is! Map) continue;
            final String errText = (raw['error'] ?? '').toString();
            final String duration =
                (raw['duration_label'] ?? '').toString();
            buf.writeln(
              '- ${formatRunAt(DateTime.parse('${raw['created_at']}'))} '
              '${raw['status']}'
              '${duration.isEmpty ? '' : '（$duration）'}'
              '${errText.isEmpty ? '' : '：$errText'}',
            );
          }
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'computer_list',
        description: '列出本机 Team Computer、智能体与工作区统计（真实目录）',
        tier: ApprovalTier.read,
        execute: (args, _) async {
          final Map<String, dynamic> r = await computer.handle(
            'list',
            <String, dynamic>{},
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取电脑失败'}');
          }
          final List<dynamic> comps =
              (r['computers'] as List?) ?? const <dynamic>[];
          if (comps.isEmpty) return ToolResult.ok('本机还没有 Team Computer。');
          final StringBuffer buf = StringBuffer('**Team Computer**\n');
          for (final dynamic raw in comps) {
            if (raw is! Map) continue;
            buf.writeln(
              '- `${raw['id']}` ${raw['name']}（${raw['kind']}，'
              '${raw['bot_count']} 个智能体，${raw['file_count']} 个文件）',
            );
            final Map<String, dynamic> bots = await computer.handle(
              'bots',
              <String, dynamic>{'computer_id': '${raw['id']}'},
            );
            for (final dynamic b
                in (bots['bots'] as List?) ?? const <dynamic>[]) {
              if (b is! Map) continue;
              buf.writeln('  - `${b['id']}` ${b['name']} · ${b['file_count']} 文件');
            }
          }
          buf.writeln('\n浏览器：HTTP 模式，不执行 JavaScript。');
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'computer_files',
        description: '列出 Team Computer 工作区文件（可限定智能体目录）',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'computer_id': <String, dynamic>{'type': 'string'},
            'bot_id': <String, dynamic>{'type': 'string'},
            'path': <String, dynamic>{'type': 'string'},
          },
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await computer.handle(
            'files',
            <String, dynamic>{
              'computer_id': (args['computer_id'] ?? '').toString(),
              'bot_id': (args['bot_id'] ?? '').toString(),
              'path': (args['path'] ?? '').toString(),
            },
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取文件失败'}');
          }
          final List<dynamic> files =
              (r['files'] as List?) ?? const <dynamic>[];
          if (files.isEmpty) return ToolResult.ok('工作区里还没有文件。');
          final StringBuffer buf = StringBuffer('**工作区文件**\n');
          for (final dynamic raw in files.take(100)) {
            if (raw is! Map) continue;
            buf.writeln('- ${raw['path']}（${raw['size']} B）');
          }
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'computer_write',
        description: '把文本写入 Team Computer 工作区（限制在电脑目录内）',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'path': <String, dynamic>{'type': 'string'},
            'text': <String, dynamic>{'type': 'string'},
            'computer_id': <String, dynamic>{'type': 'string'},
            'bot_id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['path', 'text'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await computer.handle(
            'write',
            <String, dynamic>{
              'computer_id': (args['computer_id'] ?? '').toString(),
              'bot_id': (args['bot_id'] ?? '').toString(),
              'path': (args['path'] ?? '').toString(),
              'text': (args['text'] ?? '').toString(),
            },
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '写入失败'}');
          }
          return ToolResult.ok('已写入 ${r['path']}', data: r);
        },
      ),
      AgentTool(
        name: 'browser_open',
        description:
            '用 HTTP 模式打开网页并返回可操作快照（不执行 JavaScript，'
            '仅 http/https）',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'url': <String, dynamic>{'type': 'string'},
            'bot_id': <String, dynamic>{'type': 'string'},
            'computer_id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['url'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> bot = await _resolveComputerBot(
            (args['bot_id'] ?? '').toString(),
            (args['computer_id'] ?? '').toString(),
          );
          if (bot['ok'] != true) {
            return ToolResult.error('${bot['error'] ?? '没有可用智能体'}');
          }
          final Map<String, dynamic> r = await computer.handle(
            'navigate',
            <String, dynamic>{
              'bot_id': bot['bot_id'],
              'url': (args['url'] ?? '').toString(),
            },
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '打开失败'}');
          }
          return ToolResult.ok(
            '${r['display'] ?? ''}\n\n（HTTP 模式，不执行 JavaScript）',
            data: <String, dynamic>{
              ...r,
              'bot_id': bot['bot_id'],
              'computer_id': bot['computer_id'],
            },
          );
        },
      ),
      AgentTool(
        name: 'browser_snapshot',
        description: '读取当前网页快照（链接 ref / 表单字段 ref）',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'bot_id': <String, dynamic>{'type': 'string'},
            'computer_id': <String, dynamic>{'type': 'string'},
          },
        },
        execute: (args, _) async {
          final Map<String, dynamic> bot = await _resolveComputerBot(
            (args['bot_id'] ?? '').toString(),
            (args['computer_id'] ?? '').toString(),
          );
          if (bot['ok'] != true) {
            return ToolResult.error('${bot['error'] ?? '没有可用智能体'}');
          }
          final Map<String, dynamic> r = await computer.handle(
            'snapshot',
            <String, dynamic>{'bot_id': bot['bot_id']},
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取快照失败'}');
          }
          if (r['snapshot'] == null) {
            return ToolResult.ok('该智能体还没有打开网页。');
          }
          return ToolResult.ok('${r['display'] ?? ''}');
        },
      ),
      AgentTool(
        name: 'browser_act',
        description:
            '操作网页：click/fill/submit/back/forward/reload；ref 来自快照',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'action': <String, dynamic>{'type': 'string'},
            'ref': <String, dynamic>{'type': 'string'},
            'value': <String, dynamic>{'type': 'string'},
            'bot_id': <String, dynamic>{'type': 'string'},
            'computer_id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['action'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> bot = await _resolveComputerBot(
            (args['bot_id'] ?? '').toString(),
            (args['computer_id'] ?? '').toString(),
          );
          if (bot['ok'] != true) {
            return ToolResult.error('${bot['error'] ?? '没有可用智能体'}');
          }
          final Map<String, dynamic> r = await computer.handle(
            'act',
            <String, dynamic>{
              'bot_id': bot['bot_id'],
              'action': (args['action'] ?? '').toString(),
              'ref': (args['ref'] ?? '').toString(),
              'value': (args['value'] ?? '').toString(),
            },
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '页面操作失败'}');
          }
          final String display = (r['display'] ?? '').toString();
          return ToolResult.ok(
            display.isEmpty ? '操作已执行' : display,
            data: r,
          );
        },
      ),
      AgentTool(
        name: 'computer_checkpoint',
        description: '为 Team Computer 创建真实工作区检查点（目录副本 + SHA256 清单）',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'computer_id': <String, dynamic>{'type': 'string'},
            'note': <String, dynamic>{'type': 'string'},
          },
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await computer.handle(
            'checkpoint',
            <String, dynamic>{
              'computer_id': (args['computer_id'] ?? '').toString(),
              'note': (args['note'] ?? '').toString(),
            },
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '创建检查点失败'}');
          }
          final Map<dynamic, dynamic> cp = r['checkpoint'] as Map;
          return ToolResult.ok(
            '已创建检查点 ${cp['rev']}（${cp['entries']} 个文件，'
            '${cp['total_bytes']} 字节）',
            data: Map<String, dynamic>.from(cp),
          );
        },
      ),
      AgentTool(
        name: 'computer_restore',
        description: '恢复 Team Computer 检查点（恢复前自动备份当前工作区）',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'computer_id': <String, dynamic>{'type': 'string'},
            'rev': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['rev'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await computer.handle(
            'restore',
            <String, dynamic>{
              'computer_id': (args['computer_id'] ?? '').toString(),
              'rev': (args['rev'] ?? '').toString(),
            },
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '恢复检查点失败'}');
          }
          return ToolResult.ok('${r['note'] ?? '已恢复检查点'}');
        },
      ),
      AgentTool(
        name: 'integration_list',
        description: '列出已接入的 MCP / OpenAPI / GraphQL 集成（不含凭据）',
        tier: ApprovalTier.read,
        execute: (args, _) async {
          final Map<String, dynamic> r =
              await integrations.handle('list', <String, dynamic>{});
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取集成失败'}');
          }
          final List<dynamic> items =
              (r['integrations'] as List?) ?? const <dynamic>[];
          if (items.isEmpty) return ToolResult.ok('还没有接入任何集成。');
          final StringBuffer buf = StringBuffer('**已接入集成**\n');
          for (final dynamic raw in items) {
            if (raw is! Map) continue;
            buf.writeln(
              '- `${raw['id']}` ${raw['name']}（${raw['kind']}'
              '${raw['enabled'] == true ? '' : '，已停用'}'
              '${raw['last_test_ok'] == true ? '，连接正常' : ''}）',
            );
            for (final dynamic t
                in (raw['tools'] as List?) ?? const <dynamic>[]) {
              if (t is Map) buf.writeln('  - ${t['name']}');
            }
          }
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'integration_tools',
        description: '读取某个集成的工具 / 操作列表（refresh=true 时真实重连刷新）',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
            'refresh': <String, dynamic>{'type': 'boolean'},
          },
          'required': <String>['id'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r =
              await integrations.handle('tools', <String, dynamic>{
            'id': (args['id'] ?? '').toString(),
            'refresh': args['refresh'] == true,
          });
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取工具失败'}');
          }
          final List<dynamic> tools =
              (r['tools'] as List?) ?? const <dynamic>[];
          if (tools.isEmpty) return ToolResult.ok('该集成没有可用工具。');
          final StringBuffer buf = StringBuffer('**工具**\n');
          for (final dynamic raw in tools) {
            if (raw is! Map) continue;
            buf.writeln('- `${raw['name']}` ${raw['description'] ?? ''}');
            final dynamic schema = raw['input_schema'];
            if (schema is Map && schema['properties'] is Map) {
              buf.writeln('  参数：${(schema['properties'] as Map).keys.join('、')}');
            }
          }
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'integration_call',
        description: '调用集成工具：MCP tools/call、OpenAPI 操作或 GraphQL 查询',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
            'tool': <String, dynamic>{'type': 'string'},
            'arguments': <String, dynamic>{
              'type': 'object',
              'description': '工具参数；GraphQL 可用 query / variables',
            },
          },
          'required': <String>['id'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r =
              await integrations.handle('call', <String, dynamic>{
            'id': (args['id'] ?? '').toString(),
            'tool': (args['tool'] ?? '').toString(),
            'arguments': args['arguments'] is Map
                ? args['arguments']
                : <String, dynamic>{},
          });
          if (r['ok'] != true) {
            return ToolResult.error(
              '${r['error'] ?? '调用失败'}${'${r['text'] ?? ''}'.isEmpty ? '' : '\n${r['text']}'}',
            );
          }
          final String text = '${r['text'] ?? ''}'.trim();
          return ToolResult.ok(text.isEmpty ? '调用成功（无文本返回）' : text, data: r);
        },
      ),
      AgentTool(
        name: 'integration_test',
        description: '真实重连并刷新某个集成的工具列表',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['id'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r =
              await integrations.handle('test', <String, dynamic>{
            'id': (args['id'] ?? '').toString(),
          });
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '连接失败'}');
          }
          return ToolResult.ok(
            '连接成功，${(r['tools'] as List?)?.length ?? 0} 个工具'
            '${'${r['note'] ?? ''}'.isEmpty ? '' : '；${r['note']}'}',
          );
        },
      ),
      AgentTool(
        name: 'integration_add',
        description: '接入一个 HTTP MCP / OpenAPI / GraphQL 服务（凭据进安全存储）',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'name': <String, dynamic>{'type': 'string'},
            'kind': <String, dynamic>{'type': 'string'},
            'url': <String, dynamic>{'type': 'string'},
            'auth_type': <String, dynamic>{'type': 'string'},
            'token': <String, dynamic>{'type': 'string'},
            'header_name': <String, dynamic>{'type': 'string'},
            'query_name': <String, dynamic>{'type': 'string'},
            'spec_url': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['name', 'kind', 'url'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r =
              await integrations.handle('add', <String, dynamic>{
            'name': (args['name'] ?? '').toString(),
            'kind': (args['kind'] ?? '').toString(),
            'url': (args['url'] ?? '').toString(),
            'auth_type': (args['auth_type'] ?? 'none').toString(),
            'token': (args['token'] ?? '').toString(),
            'header_name': (args['header_name'] ?? 'X-API-Key').toString(),
            'query_name': (args['query_name'] ?? 'api_key').toString(),
            'spec_url': (args['spec_url'] ?? '').toString(),
          });
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '接入失败'}');
          }
          final Map<dynamic, dynamic> item = r['integration'] as Map;
          return ToolResult.ok(
            '已接入「${item['name']}」'
            '${r['tested'] == true ? '，连接成功' : '，但连接测试失败：${r['error'] ?? ''}'}',
            data: Map<String, dynamic>.from(item),
          );
        },
      ),
      AgentTool(
        name: 'call_history',
        description: '查看真实语音通话记录与逐句转写',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'limit': <String, dynamic>{'type': 'integer'},
            'query': <String, dynamic>{'type': 'string'},
            'id': <String, dynamic>{'type': 'string'},
          },
        },
        execute: (args, _) async {
          final String id = (args['id'] ?? '').toString();
          if (id.isNotEmpty) {
            final Map<String, dynamic> r = await calls.handle(
              'get',
              <String, dynamic>{'id': id},
            );
            if (r['ok'] != true) {
              return ToolResult.error('${r['error'] ?? '通话不存在'}');
            }
            final Map<dynamic, dynamic> call = r['call'] as Map;
            final StringBuffer buf = StringBuffer(
              '**${call['bot_name']}** · ${call['status']} · '
              '${(call['duration_ms'] as num? ?? 0) ~/ 1000} 秒\n',
            );
            for (final dynamic e in (call['transcript'] as List? ?? <dynamic>[])) {
              if (e is! Map) continue;
              final String who = '${e['speaker']}' == 'user' ? '你' : '对方';
              buf.writeln('$who：${e['text']}');
            }
            return ToolResult.ok(buf.toString(), data: Map<String, dynamic>.from(call));
          }
          final Map<String, dynamic> r = await calls.handle('list', <String, dynamic>{
            'limit': args['limit'] ?? 20,
            'query': (args['query'] ?? '').toString(),
          });
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取通话记录失败'}');
          }
          final List<dynamic> list =
              (r['calls'] as List?) ?? const <dynamic>[];
          if (list.isEmpty) return ToolResult.ok('还没有语音通话记录。');
          final StringBuffer buf = StringBuffer('**最近通话**\n');
          for (final dynamic raw in list) {
            if (raw is! Map) continue;
            final int seconds =
                (raw['duration_ms'] as num? ?? 0).toInt() ~/ 1000;
            buf.writeln(
              '- `${raw['id']}` ${raw['bot_name']} · ${raw['status']} · '
              '$seconds 秒 · ${raw['entry_count']} 句 · ${raw['started_at']}',
            );
          }
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'search_all',
        description:
            '在本机真实数据里搜索对话、页面、知识库、通话、Routine、工作流与集成',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'query': <String, dynamic>{'type': 'string'},
            'limit': <String, dynamic>{'type': 'integer'},
            'types': <String, dynamic>{
              'type': 'array',
              'items': <String, dynamic>{'type': 'string'},
            },
          },
          'required': <String>['query'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await search.handle(
            'query',
            <String, dynamic>{
              'query': (args['query'] ?? '').toString(),
              'limit': args['limit'] ?? 30,
              'types': args['types'] is List ? args['types'] : <dynamic>[],
            },
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '搜索失败'}');
          }
          final List<dynamic> results =
              (r['results'] as List?) ?? const <dynamic>[];
          if (results.isEmpty) {
            return ToolResult.ok('没有找到与「${r['query']}」匹配的本机内容。');
          }
          final StringBuffer buf = StringBuffer(
            '**搜索「${r['query']}」：${r['total']} 条**\n',
          );
          for (final dynamic raw in results) {
            if (raw is! Map) continue;
            buf.writeln('- [${raw['type']}] ${raw['title']}：${raw['snippet']}');
          }
          return ToolResult.ok(buf.toString(), data: r);
        },
      ),
      AgentTool(
        name: 'artifact_list',
        description: '列出本机真实产物（工作区 / Pages 版本 / Team Computer 文件）',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'source': <String, dynamic>{'type': 'string'},
            'query': <String, dynamic>{'type': 'string'},
          },
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await artifacts.handle(
            'list',
            <String, dynamic>{
              'source': (args['source'] ?? '').toString(),
              'query': (args['query'] ?? '').toString(),
            },
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取产物失败'}');
          }
          final List<dynamic> list =
              (r['artifacts'] as List?) ?? const <dynamic>[];
          if (list.isEmpty) return ToolResult.ok('本机还没有产物文件。');
          final StringBuffer buf = StringBuffer(
            '**产物（${r['total']}）**\n',
          );
          for (final dynamic raw in list.take(80)) {
            if (raw is! Map) continue;
            buf.writeln('- ${raw['id']}（${raw['kind']}，${raw['size']} B）');
          }
          return ToolResult.ok(buf.toString(), data: r);
        },
      ),
      AgentTool(
        name: 'artifact_read',
        description: '读取本机产物的 UTF-8 文本（图片/音视频不支持）',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['id'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await artifacts.handle(
            'read',
            <String, dynamic>{'id': (args['id'] ?? '').toString()},
          );
          if (r['ok'] != true) {
            return ToolResult.error('${r['error'] ?? '读取失败'}');
          }
          return ToolResult.ok('${r['text']}', data: r);
        },
      ),
      AgentTool(
        name: 'self_test',
        description: '运行内置真实自检并逐项报告结果',
        tier: ApprovalTier.read,
        execute: (args, _) async {
          final r = await _selfTestAsync();
          final checks = r['checks'] as Map<String, dynamic>;
          final buf = StringBuffer(
            '**内置自检：${r['status'] == 'ok' ? '全部通过' : '存在失败项'}**\n\n',
          );
          checks.forEach(
            (k, v) => buf.writeln('- $k: ${v == true ? "通过" : "失败"}'),
          );
          buf.writeln(
            '\n沙箱 cube：${SandboxedShell.instance.cubeNames.join('、')}',
          );
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'attachment_summary',
        description: '真实解析随消息附上的附件内容并报告行数、字符数与开头预览',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'text': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['text'],
        },
        execute: (args, _) async {
          return ToolResult.ok(_summarizeAttachments(args['text'].toString()));
        },
      ),
      AgentTool(
        name: 'current_time',
        description: '返回设备当前本地时间与 UTC 时间',
        tier: ApprovalTier.read,
        execute: (args, _) async {
          final now = DateTime.now();
          return ToolResult.ok('本地时间：${now.toLocal()}\nUTC：${now.toUtc()}');
        },
      ),
      AgentTool(
        name: 'list_models',
        description: '扫描本地真实已下载的模型文件',
        tier: ApprovalTier.read,
        execute: (args, _) async {
          final files = store.scanFiles(
            'models',
            extensions: <String>{'.gguf'},
          );
          final downloads = store.scanFiles(
            'downloads',
            extensions: <String>{'.gguf', '.bin'},
          );
          final buf = StringBuffer();
          buf.writeln('**本地模型（真实文件扫描）**');
          if (files.isEmpty) {
            buf.writeln('模型目录：暂无 .gguf 文件');
          } else {
            for (final f in files) {
              buf.writeln('- ${f['name']} · ${_humanSize(f['size'] as int)}');
            }
          }
          final pending = downloads.length;
          buf.writeln('下载目录：$pending 个文件');
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'model3d_generate',
        description:
            '按用户描述生成 3D 模型并真实导出到沙箱 models3d/。'
            '当前支持 cube（立方体）与 deer（品牌低模鹿），可导出 obj/stl；'
            '生成后会同时更新 3D 建模页当前模型。',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'kind': <String, dynamic>{
              'type': 'string',
              'enum': <String>['cube', 'deer'],
            },
            'scale': <String, dynamic>{'type': 'number'},
            'format': <String, dynamic>{
              'type': 'string',
              'enum': <String>['obj', 'stl'],
            },
            'name': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['kind'],
        },
        execute: (args, _) async {
          try {
            final String kind = (args['kind'] ?? 'cube').toString();
            final double scale = double.tryParse('${args['scale'] ?? 1}') ?? 1;
            final String format = (args['format'] ?? 'stl').toString();
            final Map<String, dynamic> generated = await _model3dPrimitive(
              <String, dynamic>{'kind': kind, 'scale': scale},
            );
            if (generated['ok'] != true) {
              return ToolResult.error(
                (generated['error'] ?? '模型生成失败').toString(),
              );
            }
            final Map<String, dynamic> exported = await _model3dExport(
              <String, dynamic>{
                'format': format,
                'name': (args['name'] ?? 'ai-$kind').toString(),
              },
            );
            if (exported['ok'] != true) {
              return ToolResult.error(
                (exported['error'] ?? '模型导出失败').toString(),
              );
            }
            return ToolResult.ok(
              '已生成 $kind 模型并导出 ${exported['format']}：'
              '${exported['path']}（${exported['bytes']} 字节）。'
              '可在「3D 建模」页查看/继续导出。',
              data: exported,
            );
          } on Object catch (e) {
            return ToolResult.error('3D 生成失败：$e');
          }
        },
      ),
      AgentTool(
        name: 'remember',
        description: '把一段文本真实写入本地记忆（重启可恢复）',
        tier: ApprovalTier.write,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'text': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['text'],
        },
        execute: (args, _) async {
          final text = args['text'].toString().trim();
          if (text.isEmpty) return ToolResult.error('记忆内容为空');
          final id = await store.insert('turns', <String, dynamic>{
            'session_id': 'memory',
            'role': 'memory',
            'text': text,
            'ts': _now(),
          });
          return ToolResult.ok('已写入本地记忆（记录 #$id）：\n> $text');
        },
      ),
      AgentTool(
        name: 'recall',
        description: '检索本地记忆中真实存在的相关记录',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'query': <String, dynamic>{'type': 'string'},
          },
        },
        execute: (args, _) async {
          final q = (args['query'] ?? '').toString();
          final turns = await store.readRecords('turns');
          final hits = _retrieve(q, turns);
          if (hits.isEmpty) {
            return ToolResult.ok(
              '本地记忆中没有与「${q.isEmpty ? '最近记录' : q}」'
              '相关的内容。',
            );
          }
          final buf = StringBuffer('**检索到 ${hits.length} 条相关记忆**\n\n');
          for (final h in hits.take(8)) {
            buf.writeln('- ${_preview(h)}');
          }
          return ToolResult.ok(buf.toString());
        },
      ),
      AgentTool(
        name: 'web_search',
        description:
            '联网搜索真实网页（DuckDuckGo HTML 优先，失败时回退中文维基百科），'
            '返回真实标题、链接与摘要；无结果时如实返回空，绝不编造来源',
        tier: ApprovalTier.read,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'query': <String, dynamic>{
              'type': 'string',
              'description': '搜索关键词',
            },
            'limit': <String, dynamic>{
              'type': 'integer',
              'minimum': 1,
              'maximum': 20,
              'description': '返回条数，默认 8',
            },
          },
          'required': <String>['query'],
        },
        execute: (args, _) async {
          final String query = (args['query'] ?? '').toString().trim();
          if (query.isEmpty) return ToolResult.error('搜索关键词为空');
          final Object? rawLimit = args['limit'];
          final int limit = rawLimit is num
              ? rawLimit.toInt()
              : (int.tryParse(rawLimit?.toString() ?? '') ?? 8);
          final Map<String, dynamic> r = await webSearch.search(
            query,
            limit: limit,
          );
          if (r['ok'] != true) {
            return ToolResult.error((r['error'] ?? '联网搜索失败').toString());
          }
          final List<dynamic> results =
              (r['results'] as List<dynamic>?) ?? const <dynamic>[];
          if (results.isEmpty) {
            return ToolResult.ok(
              '未搜索到「$query」的真实结果（来源：${r['provider']}）。',
              data: r,
            );
          }
          final StringBuffer buf = StringBuffer(
            '**联网搜索「$query」**（provider=${r['provider']}'
            '${r['degraded'] == true ? '，已降级' : ''}）\n',
          );
          if ((r['note'] ?? '').toString().isNotEmpty) {
            buf.writeln('说明：${r['note']}\n');
          }
          for (int i = 0; i < results.length; i++) {
            final Object? item = results[i];
            if (item is! Map) continue;
            buf.writeln('${i + 1}. [${item['title']}](${item['url']})');
            final String snippet = (item['snippet'] ?? '').toString();
            if (snippet.isNotEmpty) buf.writeln('   $snippet');
          }
          return ToolResult.ok(buf.toString().trim(), data: r);
        },
      ),
      AgentTool(
        name: 'sandbox_eval',
        description: '在受限 Isolate 沙箱中求值表达式（cube 能力契约 + REFUSE）',
        tier: ApprovalTier.exec,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'expression': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['expression'],
        },
        execute: (args, _) async {
          await SandboxedShell.instance.ensureLoaded();
          final r = await SandboxedShell.instance.exec(
            'eval_expression',
            <String, dynamic>{'expression': args['expression'].toString()},
          );
          return r.ok
              ? ToolResult.ok(
                  r.stdout.trim().isEmpty ? '(无输出)' : r.stdout.trim(),
                )
              : ToolResult.error(r.error ?? '沙箱执行失败');
        },
      ),
      AgentTool(
        name: 'run_sandbox_tests',
        description: '运行内置沙箱真实测试套件',
        tier: ApprovalTier.exec,
        execute: (args, _) async {
          await SandboxedShell.instance.ensureLoaded();
          final r = await SandboxedShell.instance.exec('run_test');
          return r.ok
              ? ToolResult.ok(
                  r.stdout.trim().isEmpty ? '测试通过' : r.stdout.trim(),
                )
              : ToolResult.error(r.error ?? '沙箱执行失败');
        },
      ),
      AgentTool(
        name: 'shell',
        description:
            '在真实 Linux 沙箱中执行命令（安装依赖、编译、读写文件、'
            '运行脚本），返回 stdout/stderr 与退出码；与终端页同一执行通道',
        tier: ApprovalTier.exec,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'command': <String, dynamic>{
              'type': 'string',
              'description': '要执行的 shell 命令',
            },
            'cwd': <String, dynamic>{
              'type': 'string',
              'description': '工作目录，相对 sandbox 根',
            },
          },
          'required': <String>['command'],
        },
        execute: (args, _) async {
          final Map<String, dynamic> r = await _shellExec(<String, dynamic>{
            'command': args['command'],
            'cwd': args['cwd'] ?? '.',
          });
          final String out = (r['stdout'] ?? '').toString();
          if (r['ok'] != true && out.isEmpty) {
            return ToolResult.error((r['error'] ?? 'shell 执行失败').toString());
          }
          final String mode = r['real'] == true ? '真实 shell' : '内置解释器';
          final String rc = r['exit_code'] == null
              ? ''
              : '（exit ${r['exit_code']}）';
          final String clipped = out.length > 6000
              ? '${out.substring(0, 6000)}\n…（输出已截断）'
              : out;
          return ToolResult.ok(
            '[$mode$rc]\n${clipped.isEmpty ? '(无输出)' : clipped}',
            data: <String, dynamic>{'cwd': r['cwd'], 'real': r['real']},
          );
        },
      ),
    ]);
  }

  String _formatValue(Object? v) {
    if (v is double) {
      if (v == v.roundToDouble()) return v.toInt().toString();
      return v
          .toStringAsFixed(6)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');
    }
    return v.toString();
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  // ---- code_task：真实沙箱 ----

  Future<Map<String, dynamic>> _codeTask(Map<String, dynamic> p) async {
    final action = _action(p, 'query');
    await SandboxedShell.instance.ensureLoaded();
    if (action == 'query' || action == 'describe') {
      return <String, dynamic>{
        'ok': true,
        'backend': 'dart',
        'isolate': true,
        'cubes': SandboxedShell.instance.cubeNames,
        'allowDegrade': false,
        'note':
            '代码执行由内置纯 Dart SandboxedShell 在受限 Isolate 中完成，'
            '能力契约见 assets/schema/cube_schema.json。',
      };
    }
    final cube = action == 'run' || action == 'eval'
        ? 'eval_expression'
        : action == 'run_test' || action == 'selftest'
        ? 'run_test'
        : null;
    if (action == 'shell') return _shellExec(p);
    if (action == 'debian_status') {
      // 安装中：把最新流式进度作为 proot_progress hot-path 事件随本次
      // 分发带出（dispatch 期间 _emit 的事件会经 reply.events 送达 UI）。
      final ev = proot.progressSnapshot();
      if (ev != null) _emit('proot_progress', ev);
      return proot.status();
    }
    if (action == 'debian_install') {
      return await proot.install(
        onProgress: (phase, received, total, bytesPerSec) =>
            _emit('proot_progress', <String, dynamic>{
              'phase': phase,
              'received': received,
              'total': total,
              'speed': bytesPerSec,
            }),
      );
    }
    // 统一环境自检：一套 Linux 环境只报一次口径（前端与 Agent 共用）。
    if (action == 'env_report') return _envReport();
    // ---- 3D 建模（OBJ/STL/PLY 真实解析、统计、变换与导出）----
    if (action == 'model3d_import') return _model3dImport(p);
    if (action == 'model3d_info') return _model3dInfo(p);
    if (action == 'model3d_export') return _model3dExport(p);
    if (action == 'model3d_primitive') return _model3dPrimitive(p);
    if (cube == null) return _err('未知 code_task 动作：$action');
    final r = await SandboxedShell.instance.exec(cube, <String, dynamic>{
      if (p['expression'] != null) 'expression': p['expression'].toString(),
      if (p['code'] != null) 'expression': p['code'].toString(),
    });
    _emit('sandbox_result', r.toJson());
    return <String, dynamic>{
      'ok': r.ok,
      'stdout': r.stdout,
      'error': r.error,
      'cube': r.cube,
      'degraded': r.degraded,
    };
  }

  /// 沙箱终端真实 shell（2026-11-14 Linux 全真实执行）：
  ///
  /// * 「远端沙箱（SSH）」：所有命令经 dartssh2 真实 SSH 会话在远端
  ///   Linux 执行——apt/pkg/pip/python 全部真命令真输出；连接/认证失败
  ///   如实报错，绝不回退本地冒充。
  /// * 安卓「内置沙箱」+ 已装 Debian 扩展包：命令在 proot 用户态里
  ///   真实执行（apk/python/pip 真跑）；ROM 拒绝 exec 时如实说明原因。
  /// * 桌面端（Linux/macOS）：命令交给系统 **bash/sh** 真实执行——
  ///   `apt`、`pkg-config`、`pip`、`curl`、`gcc`、`grep`、`sed`… 全部是
  ///   真命令，存在就真跑、不存在就如实 `command not found`。默认落在
  ///   App 私有 sandbox/ 目录，`cd` 可自由出入（和真 Linux 一样）。
  /// * 安卓未装扩展包：走 /system/bin/sh（toybox 真实命令集）；无 root 时
  ///   apt 这类系统命令如实报权限/不存在，不模拟成功。
  /// * 真实 shell 起不来（平台限制/权限拒绝）才回退内置 Dart 解释器
  ///   （pwd ls cd cat echo mkdir touch rm mv cp head tail wc date
  ///   whoami uname help clear，限定 sandbox/ 根内），并在输出如实标注。
  Future<Map<String, dynamic>> _shellExec(Map<String, dynamic> p) async {
    final raw = (p['command'] ?? '').toString().trim();
    if (raw.isEmpty) return _err('命令为空');
    String cwd = (p['cwd'] ?? '.').toString();

    // 权限策略前置：clear/help/算式等内置语义分支同样先过策略。
    // 审计 detail 只落命令摘要（≤120 字符），不记录环境变量或密钥；
    // AuditLog 落盘前还会再做一次密钥脱敏。
    final String auditDetail = raw.length > 120 ? raw.substring(0, 120) : raw;
    final String preview = raw.length > 80 ? raw.substring(0, 80) : raw;
    final String grantKey = 'shell|$raw';
    PolicyDecision decision = (await _ensurePolicy()).evaluate(
      tool: 'shell',
      path: cwd,
      args: raw,
    );
    // ask 命中的一次性放行凭据：批准后重试同一条命令直接执行，不再空转建单；
    // deny 不看凭据，仍如实拒绝。
    if (decision == PolicyDecision.ask && await _consumeGrant(grantKey)) {
      decision = PolicyDecision.allow;
    }
    if (decision != PolicyDecision.allow) {
      await _auditLog().append(
        category: 'security',
        action: 'shell',
        decision: decision.name,
        actor: 'shell',
        detail: auditDetail,
      );
      if (decision == PolicyDecision.deny) {
        return _err('命令被安全策略拒绝：$preview');
      }
      final int id = await store.insert('approvals', <String, dynamic>{
        'action': '执行命令: $preview',
        'status': 'pending',
        'grant_key': grantKey,
        'consumed': 0,
        'ts': _now(),
      });
      return _err('命令需要审批：$preview（审批 ID：$id，请在安全中心批准后重试）');
    }

    // 沙箱根目录必须先存在：store.sub 只拼路径不建目录，全新安装时
    // 该目录不存在会导致 _realShellExec 的 cwd 校验失败而回退内置解释器，
    // 表现为「命令啥也用不了」。这里递归建好根，保证真 shell 路径可用。
    final Directory sandboxDir = store.sub('sandbox');
    await sandboxDir.create(recursive: true);
    final root = sandboxDir.path;

    final String env = await _sandboxEnvironment();
    final bool android = Platform.isAndroid;
    // 安卓端只有一套 Linux 用户态（proot + Ubuntu/Alpine）。
    // 宿主 Android toybox shell（uid=10541、只读系统分区、无包管理器）永不参与
    // 命令执行——否则同一台机器会同时冒出 uid=0 与 uid=10541 两套互相矛盾的
    // 环境，正是旧版本被探测成「两台机器」的根因。
    final bool linuxMode = android;
    final bool remoteSsh = !android && env.contains('SSH');

    // 远端/客户机的 cwd 是远端路径，不做本地磁盘存在性校验。
    if (!remoteSsh && !linuxMode) {
      final cwdCheck = File(cwd).isAbsolute ? cwd : '$root/$cwd';
      if (!Directory(cwdCheck).existsSync()) cwd = '.';
    }

    // clear/help/纯算式保留内置语义（UI 依赖 clear 标记；算式走真实求值）。
    final firstWord = (raw.split(RegExp(r'\s+')).first).toLowerCase();
    final isExpression =
        RegExp(r'^[\d\s\+\-\*\/\%\(\)\.\,]+$').hasMatch(raw) && raw.isNotEmpty;
    if (firstWord != 'clear' && firstWord != 'help' && !isExpression) {
      // ① 远端沙箱（SSH）：真实远端 Linux 执行。
      if (remoteSsh) {
        return SshSandbox.instance.run(raw, cwd);
      }
      // ② 安卓：唯一那套 Linux 环境（proot 用户态）。未安装时真实触发下载，
      //    本次命令如实返回「初始化中」，绝不回落到宿主 shell 冒充 Linux。
      if (linuxMode) {
        if (!proot.installed) {
          final Map<String, dynamic> st = await _startLinuxInstall();
          return <String, dynamic>{
            'ok': false,
            'stdout': '',
            'error': st['installing'] == true
                ? 'Linux 环境首次初始化中：正在真实下载 proot + '
                      '${st['distro'] ?? 'Ubuntu 24.04 base'} rootfs'
                      '（约 ${((st['total'] as num? ?? 30243739) / 1000000).round()}MB）。'
                      '稍后重试即可；打开「沙箱」页可看实时进度。'
                : 'Linux 环境未就绪：${st['error'] ?? '安装未完成'}'
                      '。请在「沙箱」页点「Linux 环境」重试安装。',
            'cwd': cwd,
            'cube': 'shell',
            'linux': true,
            'installing': st['installing'] == true,
          };
        }
        final Map<String, dynamic>? viaLinux = await proot.run(raw, cwd);
        if (viaLinux != null) return viaLinux;
        return <String, dynamic>{
          'ok': false,
          'stdout': '',
          'error':
              'Linux 环境启动失败（proot 可执行文件不可用）。'
              '请到「沙箱」页重新安装 Linux 环境后再试。',
          'cwd': cwd,
          'cube': 'shell',
          'linux': true,
        };
      }
      final real = await _realShellExec(raw, root, cwd);
      if (real != null) return real;
    }

    String resolve(String rel) {
      final base = rel.startsWith('/')
          ? '$root${rel.replaceAll(RegExp(r'/+'), '/')}'.replaceAll('//', '/')
          : '$root/$cwd/$rel';
      final parts = base.split('/');
      final out = <String>[];
      for (final s in parts) {
        if (s.isEmpty || s == '.') continue;
        if (s == '..') {
          if (out.isEmpty) return '';
          out.removeLast();
        } else {
          out.add(s);
        }
      }
      final joined = '/${out.join('/')}';
      return joined.startsWith('$root/') || joined == root ? joined : '';
    }

    final sp = raw.indexOf(RegExp(r'\s'));
    final cmd = (sp < 0 ? raw : raw.substring(0, sp)).toLowerCase();
    final args = sp < 0
        ? <String>[]
        : raw
              .substring(sp + 1)
              .split(RegExp(r'\s+'))
              .where((s) => s.isNotEmpty)
              .toList();
    final buf = StringBuffer();
    String newCwd = cwd;
    var ok = true;

    void fail(String msg) {
      ok = false;
      buf.writeln(msg);
    }

    switch (cmd) {
      case 'pwd':
        buf.writeln('$root/$cwd'.replaceAll('//', '/'));
      case 'ls':
        final showLong =
            args.contains('-l') || args.contains('-la') || args.contains('-al');
        final target = resolve(
          args.where((a) => !a.startsWith('-')).isEmpty
              ? '.'
              : args.firstWhere((a) => !a.startsWith('-')),
        );
        if (target.isEmpty) {
          fail('ls: 路径越界被拒绝');
          break;
        }
        final dir = Directory(target);
        if (!dir.existsSync()) {
          fail('ls: 无法访问 \'${args}\'：No such file or directory');
          break;
        }
        final entries =
            dir
                .listSync(followLinks: false)
                .where((e) => !e.uri.pathSegments.last.startsWith('.tangram'))
                .toList()
              ..sort((a, b) {
                final ad = a is Directory ? 0 : 1;
                final bd = b is Directory ? 0 : 1;
                if (ad != bd) return ad.compareTo(bd);
                return a.uri.pathSegments.last.compareTo(
                  b.uri.pathSegments.last,
                );
              });
        for (final e in entries) {
          final name = e.uri.pathSegments.last;
          if (showLong) {
            final st = e.statSync();
            // 用文件真实修改时间，不再用当前时间伪造 mtime。
            final String mtime = st.modified.toIso8601String();
            buf.writeln(
              '${e is Directory ? "drwxr-xr-x" : "-rw-r--r--"} '
              '${st.size.toString().padLeft(10)}  $mtime  $name${e is Directory ? "/" : ""}',
            );
          } else {
            buf.writeln('$name${e is Directory ? "/" : ""}');
          }
        }
        if (entries.isEmpty) buf.writeln('(空目录)');
      case 'cd':
        final t = resolve(args.isEmpty ? '~' : args.first.replaceAll('~', ''));
        if (t.isEmpty) {
          fail('cd: 路径越界被拒绝');
        } else if (Directory(t).existsSync()) {
          final rel = t == root ? '.' : t.substring(root.length + 1);
          newCwd = rel;
        } else {
          fail('cd: ${args}: No such file or directory');
        }
      case 'cat':
        if (args.isEmpty) {
          fail('cat: 缺少文件名');
          break;
        }
        for (final a in args) {
          final t = resolve(a);
          if (t.isEmpty) {
            fail('cat: 路径越界被拒绝');
            continue;
          }
          final f = File(t);
          if (!f.existsSync()) {
            fail('cat: $a: No such file or directory');
          } else if (f.lengthSync() > 256 * 1024) {
            fail('cat: $a: 超过 256KB 上限');
          } else {
            final txt = f.readAsStringSync();
            buf.write(txt);
            if (!txt.endsWith('\n')) buf.writeln();
          }
        }
      case 'echo':
        buf.writeln(args.join(' '));
      case 'mkdir':
        if (args.isEmpty) {
          fail('mkdir: 缺少目录名');
          break;
        }
        final t = resolve(args.last);
        if (t.isEmpty) {
          fail('mkdir: 路径越界被拒绝');
        } else {
          Directory(t).createSync(recursive: true);
        }
      case 'touch':
        if (args.isEmpty) {
          fail('touch: 缺少文件名');
          break;
        }
        final t = resolve(args.last);
        if (t.isEmpty) {
          fail('touch: 路径越界被拒绝');
        } else {
          File(t).createSync(recursive: true);
        }
      case 'rm':
        final recursive =
            args.contains('-r') || args.contains('-rf') || args.contains('-fr');
        final targetArg = args.where((a) => !a.startsWith('-')).toList();
        if (targetArg.isEmpty) {
          fail('rm: 缺少目标');
          break;
        }
        final t = resolve(targetArg.first);
        if (t.isEmpty || t == root) {
          fail('rm: 路径越界或被保护，已拒绝');
        } else {
          final type = FileSystemEntity.typeSync(t);
          if (type == FileSystemEntityType.directory) {
            if (!recursive) {
              fail('rm: $targetArg: is a directory（需 -r）');
            } else {
              Directory(t).deleteSync(recursive: true);
            }
          } else if (type != FileSystemEntityType.notFound) {
            File(t).deleteSync();
          } else {
            fail('rm: $targetArg: No such file or directory');
          }
        }
      case 'mv' || 'cp':
        if (args.length < 2) {
          fail('$cmd: 用法: $cmd <源> <目标>');
          break;
        }
        final from = resolve(args[0]);
        final to = resolve(args[1]);
        if (from.isEmpty || to.isEmpty) {
          fail('$cmd: 路径越界被拒绝');
          break;
        }
        if (FileSystemEntity.typeSync(from) == FileSystemEntityType.directory) {
          if (cmd == 'mv') {
            Directory(from).renameSync(to);
          } else {
            fail('cp: 暂不支持目录递归复制');
          }
        } else if (File(from).existsSync()) {
          if (cmd == 'mv') {
            File(from).renameSync(to);
          } else {
            File(from).copySync(to);
          }
        } else {
          fail('$cmd: ${args[0]}: No such file or directory');
        }
      case 'head' || 'tail':
        if (args.isEmpty) {
          fail('$cmd: 缺少文件名');
          break;
        }
        final t = resolve(args.last);
        if (t.isEmpty || !File(t).existsSync()) {
          fail('$cmd: ${args.last}: No such file or directory');
          break;
        }
        final lines = File(t).readAsLinesSync();
        if (cmd == 'head') {
          buf.writeln(lines.take(10).join('\n'));
        } else {
          buf.writeln(
            lines.length <= 10
                ? lines.join('\n')
                : lines.sublist(lines.length - 10).join('\n'),
          );
        }
      case 'wc':
        if (args.isEmpty) {
          fail('wc: 缺少文件名');
          break;
        }
        final t = resolve(args.last);
        if (t.isEmpty || !File(t).existsSync()) {
          fail('wc: ${args.last}: No such file or directory');
          break;
        }
        final txt = File(t).readAsStringSync();
        buf.writeln(
          '${txt.split('\n').length} ${txt.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length} ${txt.length} ${args.last}',
        );
      case 'date':
        buf.writeln(DateTime.now().toString());
      case 'whoami':
        buf.writeln('tga');
      case 'uname':
        buf.writeln(
          '${Platform.operatingSystem} tangram-sandbox '
          '${Platform.operatingSystemVersion} '
          '${Uri.base.scheme == "file" ? Platform.localHostname : "device"}',
        );
      case 'clear':
        // 由前端识别：stdout 返回标记，页面清空屏幕。
        buf.writeln('\x1bclear\x1b');
      case 'help':
        if (remoteSsh) {
          buf.writeln('远端沙箱（SSH）：命令经真实 SSH 会话在远端 Linux 执行，');
          buf.writeln('apt/pkg/pip/python 全部真命令真输出；pwd/cd 由远端 shell');
          buf.writeln('提供（本终端仅 clear 与算式求值在本地）。');
          buf.writeln('连接失败会如实报错；右上「⚙」可改主机与凭据。');
          break;
        }
        buf.writeln('内置沙箱 shell（真实文件操作，限定 sandbox/ 根内）：');
        buf.writeln('pwd ls [-l] cd cat echo mkdir touch rm [-r] mv cp');
        buf.writeln('head tail wc date whoami uname clear help');
        buf.writeln('表达式求值请直接输入算式，如 2+3*4');
        buf.writeln(
          '注：本终端默认把命令交给系统真实 shell 执行，'
          'apt/pkg/pip/curl 等系统命令按本机真实情况响应。',
        );
        if (Platform.isAndroid) {
          final String distro = proot.distroLabel;
          buf.writeln(
            proot.installed
                ? '当前运行在唯一那套 Linux 用户态（proot + $distro）：'
                      '${proot.profile == 'alpine' ? 'apk' : 'apt/dpkg（pkg 封装）'}'
                      ' / python / pip 真实执行。'
                : 'Linux 环境尚未安装：点右上角图标真实下载'
                      '（proot + $distro rootfs，约 '
                      '${(proot.status()['total'] as num? ?? 30243739) ~/ 1000000}MB）。',
          );
        }
      default:
        // 表达式兜底：2+3*4 之类直接走真实求值（受限 Isolate）。
        if (RegExp(r'^[\d\s\+\-\*\/\%\(\)\.\,]+$').hasMatch(raw)) {
          final r = await SandboxedShell.instance.exec(
            'eval_expression',
            <String, dynamic>{'expression': raw},
          );
          ok = r.ok;
          buf.write(r.ok ? r.stdout : r.error);
          buf.writeln();
        } else {
          fail('$cmd: command not found（输入 help 查看可用命令）');
        }
    }
    return <String, dynamic>{
      'ok': ok,
      'stdout': buf.toString(),
      'error': ok ? '' : buf.toString(),
      'cwd': newCwd,
      'cube': 'shell',
      // 如实标注：这是受限内置解释器（真实 shell 不可用时才回退），
      // 不是系统 shell。终端据此提示用户，避免把模拟命令当成真 shell。
      'real': false,
    };
  }

  // ===========================================================================
  // 3D 建模（内置能力，无独立操作页依赖）
  // ===========================================================================

  /// 最近一次载入/生成的网格（进程内缓存；导出与统计共用同一份）。
  Mesh3D? _mesh3d;
  String _mesh3dName = 'tangram';

  File _resolveSandboxFile(String path) {
    final String root = store.sub('sandbox').path;
    // Windows 绝对路径是 C:\... 而不是 /...：用平台无关的 isAbsolute 判断，
    // 否则导出返回的路径再导入会被错误拼到沙箱根下，变成「文件不存在」。
    if (File(path).isAbsolute) return File(path);
    final String clean = path.replaceAll(RegExp(r'^\./'), '');
    return File('$root/$clean');
  }

  Map<String, dynamic> _model3dPayload(
    Mesh3D mesh, {
    required String format,
    required String name,
    String path = '',
    String note = '',
  }) {
    final MeshStats stats = mesh.stats();
    return _ok(<String, dynamic>{
      'name': name,
      'format': format,
      // 统计按原始网格（真实尺寸/单位）；渲染顶点归一化到单位盒，
      // 否则偏离原点的导入模型在画布上会缩成一点或偏出画面。
      'stats': stats.toJson(),
      'mesh': mesh.normalized().toJson(),
      if (path.isNotEmpty) 'path': path,
      if (note.isNotEmpty) 'note': note,
    });
  }

  /// 生成程序化图元（cube / deer），并缓存为当前网格。
  Future<Map<String, dynamic>> _model3dPrimitive(Map<String, dynamic> p) async {
    final String kind = (p['kind'] ?? 'deer').toString().toLowerCase();
    final double scale = double.tryParse('${p['scale'] ?? 1}') ?? 1;
    if (scale <= 0 || scale > 100) return _err('scale 需在 0~100 之间');
    final Mesh3D mesh;
    final String name;
    switch (kind) {
      case 'cube':
      case 'box':
        mesh = Mesh3D.box(width: scale, height: scale, depth: scale);
        name = 'cube';
      case 'deer':
        mesh = Mesh3D.deer(scale: scale);
        name = 'tanram-deer';
      default:
        return _err('未知图元：$kind（支持 cube / deer）');
    }
    _mesh3d = mesh;
    _mesh3dName = name;
    return _model3dPayload(mesh, format: 'procedural', name: name);
  }

  /// 从沙箱目录导入真实模型文件（OBJ / STL / PLY）。
  Future<Map<String, dynamic>> _model3dImport(Map<String, dynamic> p) async {
    final String rawPath = (p['path'] ?? '').toString().trim();
    if (rawPath.isEmpty) return _err('缺少模型路径');
    final File f = _resolveSandboxFile(rawPath);
    if (!f.existsSync()) return _err('模型文件不存在：$rawPath');
    final Uint8List bytes = await f.readAsBytes();
    if (bytes.isEmpty) return _err('模型文件为空：$rawPath');
    if (bytes.length > 64 * 1024 * 1024) return _err('模型超过 64MB 上限');
    try {
      final MeshLoadResult r = Mesh3D.parseBytes(f.path, bytes);
      _mesh3d = r.mesh;
      _mesh3dName = f.uri.pathSegments.last;
      return _model3dPayload(
        r.mesh,
        format: r.format,
        name: _mesh3dName,
        path: f.path,
        note: r.note,
      );
    } on MeshFormatException catch (e) {
      return _err('$e');
    } on Object catch (e) {
      return _err('解析失败：$e');
    }
  }

  /// 只读统计（不覆盖当前网格）：可传 path，也可查当前网格。
  Future<Map<String, dynamic>> _model3dInfo(Map<String, dynamic> p) async {
    final String rawPath = (p['path'] ?? '').toString().trim();
    if (rawPath.isNotEmpty) {
      final Map<String, dynamic> r = await _model3dImport(<String, dynamic>{
        'path': rawPath,
      });
      if (r['ok'] != true) return r;
      final Map<String, dynamic> stats = (r['stats'] as Map).map(
        (k, v) => MapEntry(k.toString(), v),
      );
      return _ok(<String, dynamic>{
        'name': r['name'],
        'format': r['format'],
        'stats': stats,
      });
    }
    final Mesh3D? mesh = _mesh3d;
    if (mesh == null) return _err('还没有载入模型；先生成或导入一个模型');
    return _ok(<String, dynamic>{
      'name': _mesh3dName,
      'stats': mesh.stats().toJson(),
    });
  }

  /// 导出当前网格为 OBJ、二进制 STL 或 ASCII PLY（真实写盘，返回字节数与路径）。
  Future<Map<String, dynamic>> _model3dExport(Map<String, dynamic> p) async {
    final Mesh3D? mesh = _mesh3d;
    if (mesh == null) return _err('还没有载入模型；先生成或导入一个模型');
    final String format = (p['format'] ?? 'obj').toString().toLowerCase();
    final Directory dir = store.sub('models3d');
    await dir.create(recursive: true);
    final String rawName = (p['name'] ?? _mesh3dName).toString();
    final String base = rawName
        .replaceAll(RegExp(r'[^\w\-.]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final String safe = base.isEmpty ? 'tangram-model' : base;
    final File out;
    if (format == 'obj') {
      out = File('${dir.path}/$safe.obj');
      await out.writeAsString(mesh.toObj(name: safe), flush: true);
    } else if (format == 'stl') {
      out = File('${dir.path}/$safe.stl');
      await out.writeAsBytes(mesh.toStlBinary(name: safe), flush: true);
    } else if (format == 'stl_ascii') {
      out = File('${dir.path}/$safe.stl');
      await out.writeAsString(mesh.toStlAscii(name: safe), flush: true);
    } else if (format == 'ply') {
      out = File('${dir.path}/$safe.ply');
      await out.writeAsString(mesh.toPly(name: safe), flush: true);
    } else {
      return _err('不支持的导出格式：$format（支持 obj / stl / stl_ascii / ply）');
    }
    return _ok(<String, dynamic>{
      'format': format,
      'ext': format == 'stl_ascii' ? 'stl' : format,
      'path': out.path,
      'bytes': out.lengthSync(),
      'name': safe,
    });
  }

  /// 启动（幂等）唯一那套 Linux 环境的真实安装，并把流式进度发到 UI。
  Future<Map<String, dynamic>> _startLinuxInstall() async {
    final Map<String, dynamic> st = proot.status();
    if (st['installed'] == true || st['installing'] == true) return st;
    unawaited(
      proot.install(
        onProgress: (phase, received, total, bytesPerSec) =>
            _emit('proot_progress', <String, dynamic>{
              'phase': phase,
              'received': received,
              'total': total,
              'speed': bytesPerSec,
            }),
      ),
    );
    return proot.status();
  }

  /// 统一环境自检（唯一真源）。
  ///
  /// 旧版本里「沙箱完整性」由调用方各自跑命令判断：一次落进 proot（uid=0、
  /// 2.4G 根分区、gcc/python 齐全），一次落进 Android 宿主 toybox
  /// （uid=10541、933M 分区满、无包管理器），于是被描述成两台互相矛盾的机器。
  /// 现在只有这一份报告：安卓恒为 proot + 单一 profile（Ubuntu/Alpine）用户态。
  Future<Map<String, dynamic>> _envReport() async {
    // distro 统一读 /etc/os-release 的 PRETTY_NAME（Ubuntu/Alpine 都有）；
    // 包管理器同时探测 apk 与 apt-get，由解析层按 apk > apt 取真实值。
    const String probe =
        "echo \"kernel:\$(uname -srm)\"; "
        "echo \"uid:\$(id -u)\"; "
        "echo \"distro:\$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null)\"; "
        "echo \"disk:\$(df -Pk / | tail -1)\"; "
        "echo \"apk:\$(command -v apk || echo -)\"; "
        "echo \"apt-get:\$(command -v apt-get || echo -)\"; "
        "echo \"python:\$(command -v python3 || echo -)\"; "
        "echo \"node:\$(command -v node || echo -)\"; "
        "echo \"gcc:\$(command -v gcc || echo -)\"; "
        "echo \"writable:\$(touch /root/.tga_env_probe 2>/dev/null && echo yes || echo no)\"";

    if (Platform.isAndroid) {
      final String pkgName = proot.profile == 'alpine'
          ? 'apk'
          : 'apt/dpkg（pkg 为封装）';
      if (!proot.installed) {
        final Map<String, dynamic> st = await _startLinuxInstall();
        return <String, dynamic>{
          'ok': false,
          'single_environment': true,
          'platform': 'android',
          'environment': '内置沙箱',
          'profile': 'android-proot-${proot.profile}',
          'distro': proot.distroLabel,
          'package_manager': proot.profile == 'alpine' ? 'apk' : 'apt',
          'linux_installed': false,
          'installing': st['installing'] == true,
          'step': (st['step'] ?? 'idle').toString(),
          if (st['error'] != null) 'error': st['error'],
          'note':
              '安卓端只有这一套 Linux 用户态（proot + ${proot.distroLabel}）；'
              '首次使用会真实下载并解包，装好后 $pkgName / python / pip '
              '都在用户态执行。',
        };
      }
      final Map<String, dynamic>? r = await proot.run(probe, '.');
      final Map<String, dynamic> report = _parseEnvReport(
        (r?['stdout'] ?? '').toString(),
      );
      report['ok'] = r?['ok'] == true;
      report['linux_installed'] = true;
      report['single_environment'] = true;
      report['platform'] = 'android';
      report['environment'] = '内置沙箱';
      report['profile'] = 'android-proot-${proot.profile}';
      if ('${report['distro'] ?? ''}'.isEmpty) {
        report['distro'] = proot.distroLabel;
      }
      if (r?['error'] != null && '${r!['error']}'.isNotEmpty) {
        report['error'] = r['error'];
      }
      return report;
    }

    // 桌面端：系统真实 shell 探测（与终端同一条链路）。
    final String shell = Platform.isWindows ? 'cmd' : '/bin/sh';
    final List<String> args = Platform.isWindows
        ? <String>['/c', 'ver']
        : <String>['-c', probe.replaceAll('/root/', '/tmp/')];
    try {
      final ProcessResult pr = await Process.run(
        shell,
        args,
      ).timeout(const Duration(seconds: 20));
      final Map<String, dynamic> report = _parseEnvReport('${pr.stdout}');
      report['ok'] = pr.exitCode == 0;
      report['single_environment'] = true;
      report['platform'] = Platform.operatingSystem;
      report['environment'] = await _sandboxEnvironment();
      report['linux_installed'] = !Platform.isWindows;
      report['profile'] = Platform.isWindows ? 'windows-host' : 'host-linux';
      return report;
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'single_environment': true,
        'platform': Platform.operatingSystem,
        'environment': await _sandboxEnvironment(),
        'error': '$e',
      };
    }
  }

  /// 把 `echo key:value` 形式的探测输出解析成结构化环境快照。
  Map<String, dynamic> _parseEnvReport(String out) {
    final Map<String, String> kv = <String, String>{};
    for (final String line in out.split('\n')) {
      final String t = line.trim();
      final int i = t.indexOf(':');
      if (i <= 0) continue;
      kv[t.substring(0, i).trim()] = t.substring(i + 1).trim();
    }
    String tool(String key) {
      final String v = kv[key] ?? '';
      return (v.isEmpty || v == '-') ? '' : v;
    }

    // PRETTY_NAME 通常带引号（"Ubuntu 24.04.5 LTS"），去掉首尾引号。
    String unquote(String raw) {
      var d = raw.trim();
      if (d.length >= 2 &&
          ((d.startsWith('"') && d.endsWith('"')) ||
              (d.startsWith("'") && d.endsWith("'")))) {
        d = d.substring(1, d.length - 1).trim();
      }
      return d;
    }

    int? totalMb;
    int? freeMb;
    final List<String> df = (kv['disk'] ?? '')
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .toList();
    if (df.length >= 4) {
      final int? totalK = int.tryParse(df[1]);
      final int? freeK = int.tryParse(df[3]);
      if (totalK != null) totalMb = (totalK / 1024).round();
      if (freeK != null) freeMb = (freeK / 1024).round();
    }

    return <String, dynamic>{
      'kernel': kv['kernel'] ?? '',
      'uid': kv['uid'] ?? '',
      'distro': unquote(kv['distro'] ?? ''),
      'disk_total_mb': totalMb,
      'disk_free_mb': freeMb,
      'package_manager': tool('apk').isNotEmpty
          ? 'apk'
          : (tool('apt-get').isNotEmpty ? 'apt' : ''),
      'tools': <String, String>{
        'python3': tool('python'),
        'node': tool('node'),
        'gcc': tool('gcc'),
      },
      'node_ready': tool('node').isNotEmpty,
      if (tool('node').isEmpty)
        'node_hint':
            '沙箱未检测到 Node.js；QQ 沙箱直连（dsh-qqbot）依赖 node/npm，'
            '扫码前会尝试在 Linux 用户态用系统包管理器真实补装。',
      'writable': kv['writable'] == 'yes',
    };
  }

  /// 真实 shell 执行：桌面端 bash/sh（安卓宿主 shell 已从链路移除）。
  /// 返回 null 表示真实 shell 不可用（调用方回退内置解释器）。
  /// 命令输出/退出码全部来自真实进程，绝不加工、绝不模拟成功。
  Future<Map<String, dynamic>?> _realShellExec(
    String raw,
    String root,
    String cwd,
  ) async {
    // 安卓端已统一到唯一那套 Linux 环境（proot）：宿主 toybox shell 不参与
    // 执行，避免出现第二套环境（uid=10541）与 proot（uid=0）互相矛盾。
    if (Platform.isAndroid) return null;
    final String shell;
    if (Platform.isWindows) {
      shell = r'C:\Windows\System32\cmd.exe';
    } else if (File('/bin/bash').existsSync()) {
      shell = '/bin/bash';
    } else if (File('/bin/sh').existsSync()) {
      shell = '/bin/sh';
    } else {
      return null;
    }
    if (!Platform.isWindows && !File(shell).existsSync()) {
      debugPrint('TGA_REAL_SHELL_FAIL: no shell $shell');
      return null;
    }
    // 平台无关判断绝对路径：Windows 的 C:\... 也必须以 isAbsolute 识别，
    // 否则会被错误拼成 'root/C:\...'，cwd 校验失败后静默回退内置解释器。
    final bool cwdIsAbsolute = Platform.isWindows
        ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(cwd) || cwd.startsWith(r'\\')
        : cwd.startsWith('/');
    final String cwdAbs = cwdIsAbsolute
        ? cwd
        : '$root/${cwd == '.' ? '' : cwd}';
    if (!Directory(cwdAbs).existsSync()) {
      debugPrint('TGA_REAL_SHELL_FAIL: no cwd $cwdAbs');
      return null;
    }

    // 用唯一标记把「真实输出」与「新 cwd/退出码」分离（POSIX shell 通用）。
    final String marker =
        '__TGA_END_${DateTime.now().microsecondsSinceEpoch}__';
    final String script =
        'cd ${_shellQuote(cwdAbs)} 2>/dev/null; $raw; __rc=\$?; '
        'printf "\\n$marker%s$marker\$__rc\\n" "\$(pwd -P 2>/dev/null)"; '
        'exit \$__rc';

    Process proc;
    try {
      proc = await Process.start(
        shell,
        Platform.isWindows
            ? <String>['/c', 'cd /d "$cwdAbs" && $raw']
            : <String>['-c', script],
        workingDirectory: cwdAbs,
        includeParentEnvironment: true,
        environment: <String, String>{
          'HOME': root,
          'TERM': 'xterm-256color',
          'LANG': 'C.UTF-8',
          'PS1': 'tga@sandbox:\\w\$ ',
        },
      );
    } on Object catch (e, st) {
      debugPrint('TGA_REAL_SHELL_FAIL: $e\n$st');
      return null; // 起进程失败：回退内置解释器。
    }

    // allowMalformed:true：真实命令可能输出非 UTF-8 字节（二进制/区域编码），
    // 严格解码会抛 FormatException 被误报成「执行失败」。宽松解码保留可读文本。
    final Future<String> outF = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    final Future<String> errF = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    int exitCode = 124;
    try {
      exitCode = await proc.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
    }
    final String stdoutAll = await outF.timeout(
      const Duration(seconds: 3),
      onTimeout: () => '',
    );
    final String stderrAll = await errF.timeout(
      const Duration(seconds: 3),
      onTimeout: () => '',
    );

    String out = stdoutAll;
    String newCwd = cwd;
    if (!Platform.isWindows) {
      final int first = stdoutAll.indexOf(marker);
      final int last = stdoutAll.lastIndexOf(marker);
      if (first >= 0 && last > first) {
        out = stdoutAll.substring(0, first);
        final String tail = stdoutAll
            .substring(last + marker.length)
            .trim(); // <rc>
        final String mid = stdoutAll.substring(
          first + marker.length,
          last,
        ); // <pwd>
        final int rc = int.tryParse(tail) ?? exitCode;
        exitCode = rc;
        final String pwd = mid.trim();
        if (pwd.isNotEmpty) {
          newCwd = pwd.startsWith('$root/') || pwd == root
              ? (pwd == root ? '.' : pwd.substring(root.length + 1))
              : pwd; // 沙箱外：如实保留绝对路径（Linux 语义）。
        }
      }
    }
    final String text = out + (stderrAll.isEmpty ? '' : '\n$stderrAll');
    return <String, dynamic>{
      'ok': exitCode == 0,
      'stdout': text,
      'error': exitCode == 0 ? '' : 'exit $exitCode',
      'exit_code': exitCode,
      'cwd': newCwd,
      'cube': 'shell',
      'real': true,
    };
  }

  // ---- QqShellRunner 实现：供 QQ 沙箱直连扫码（dsh-qqbot）真实执行 ----
  // dsh 会阻塞等待扫码，必须用托管长驻进程，不能用一次性 60s 命令模型。

  /// 当前平台下用于执行命令的 shell；无可用 shell 返回 null（如实降级）。
  String? _pickShell() {
    if (Platform.isWindows) return r'C:\Windows\System32\cmd.exe';
    if (Platform.isAndroid) {
      return File('/system/bin/sh').existsSync() ? '/system/bin/sh' : null;
    }
    if (File('/bin/bash').existsSync()) return '/bin/bash';
    if (File('/bin/sh').existsSync()) return '/bin/sh';
    return null;
  }

  final Map<String, _ManagedProc> _qqProcs = <String, _ManagedProc>{};

  @override
  Future<Map<String, dynamic>> runOnce(
    String command, {
    String cwd = '.',
  }) async {
    final r = await _shellExec(<String, dynamic>{
      'command': command,
      'cwd': cwd,
    });
    return r;
  }

  @override
  Future<QqShellProc> startDaemon(
    String command, {
    String cwd = '.',
    Map<String, String>? env,
  }) async {
    final StringBuffer buf = StringBuffer();
    final Process proc;

    // 安卓：dsh-qqbot 依赖的 node/npm 只存在于 proot 用户态里，宿主
    // /system/bin/sh（toybox）既无 node 也无 npm。旧实现在这里误用宿主
    // shell，导致「沙箱里装了 node，dsh 却永远起不来、拿不到二维码」。
    // 现在安卓分支必须与 proot.run 同一套参数启动长驻进程。
    if (Platform.isAndroid) {
      if (!proot.installed) {
        throw StateError('Linux 沙箱尚未就绪，无法启动 dsh-qqbot；请先在「沙箱」页安装 Linux 环境。');
      }
      // 启动前幂等确保 JS 运行时可用（缺失即真实补装，失败如实抛错）。
      final Map<String, dynamic> js = await proot.ensureJs();
      if (js['ok'] != true) {
        throw StateError('${js['error'] ?? 'JS 运行时不可用'}，无法启动 dsh-qqbot。');
      }
      final Directory prootTmp = Directory('${proot.extDir.path}/proot_tmp');
      if (!prootTmp.existsSync()) prootTmp.createSync(recursive: true);
      final Directory appSandbox = store.sub('sandbox');
      if (!appSandbox.existsSync()) appSandbox.createSync(recursive: true);
      final String guestCwd = cwd == '.'
          ? '/root'
          : (cwd.startsWith('/') ? cwd : '/root/$cwd');
      final String script = 'cd ${_shellQuote(guestCwd)} 2>/dev/null; $command';
      try {
        proc = await Process.start(
          proot.prootBin.path,
          <String>[
            '-0',
            '-l',
            '-r',
            proot.rootfsDir.path,
            '-w',
            '/root',
            '-b',
            '/dev',
            '-b',
            '/proc',
            '-b',
            '/sys',
            '-b',
            '${appSandbox.path}:/workspace',
            '/bin/sh',
            '-c',
            script,
          ],
          workingDirectory: proot.rootfsDir.path,
          includeParentEnvironment: false,
          environment: <String, String>{
            'LD_LIBRARY_PATH': proot.extDir.path,
            'PROOT_TMP_DIR': '${proot.extDir.path}/proot_tmp',
            'HOME': '/root',
            'PATH':
                '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
            'TERM': 'xterm-256color',
            'LANG': 'C.UTF-8',
            'PROOT_NO_SECCOMP': '1',
            if (env != null) ...env,
          },
        );
      } on Object catch (e) {
        throw StateError('在 proot 用户态启动 dsh-qqbot 失败：$e');
      }
    } else {
      final String? shell = _pickShell();
      if (shell == null) {
        throw StateError('沙箱无可用 shell，无法启动 dsh-qqbot');
      }
      // 沙箱根目录必须先存在（store.sub 只拼路径不建目录）。
      final Directory sandboxDir = store.sub('sandbox');
      await sandboxDir.create(recursive: true);
      final String root = sandboxDir.path;
      final String cwdAbs = cwd.startsWith('/')
          ? cwd
          : '$root/${cwd == '.' ? '' : cwd}';
      if (!Directory(cwdAbs).existsSync()) {
        await Directory(cwdAbs).create(recursive: true);
      }
      try {
        proc = await Process.start(
          shell,
          Platform.isWindows
              ? <String>['/c', 'cd /d "$cwdAbs" && $command']
              : <String>[
                  '-c',
                  'cd ${_shellQuote(cwdAbs)} 2>/dev/null; $command',
                ],
          workingDirectory: cwdAbs,
          includeParentEnvironment: true,
          environment: <String, String>{
            'HOME': root,
            'TERM': 'xterm-256color',
            'LANG': 'C.UTF-8',
            'PS1': 'tga@sandbox:\\w\$ ',
            if (env != null) ...env,
          },
        );
      } on Object catch (e) {
        throw StateError('启动 shell 进程失败：$e');
      }
    }
    proc.stdout.transform(utf8.decoder).listen((String s) => buf.write(s));
    proc.stderr.transform(utf8.decoder).listen((String s) => buf.write(s));
    final _ManagedProc mp = _ManagedProc(buf);
    unawaited(
      proc.exitCode.then((int c) {
        mp.alive = false;
        mp.exitCode = c;
      }),
    );
    mp.killFn = () => proc.kill(ProcessSignal.sigkill);
    _qqProcs['qq_sandbox'] = mp;
    return mp;
  }

  static String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  /// MCP 真实同步：断开重连 mcp_servers.json 里的全部服务，
  /// HTTP/SSE 传输 → initialize + tools/list，工具注册进 AgentLoop 的
  /// [tools]（消息里出现工具名即真实调用，支持 key=value 传参）；
  /// stdio 传输移动端无法 spawn 进程，如实归入 skipped。
  Future<Map<String, dynamic>> _mcpSync() async {
    for (final n in _mcpToolNames) {
      tools.unregister(n);
    }
    _mcpToolNames.clear();
    for (final c in _mcpClients.values) {
      c.dispose();
    }
    _mcpClients.clear();
    final cfg = await store.readJson('mcp_servers.json');
    final servers = (cfg['servers'] is List)
        ? (cfg['servers'] as List).whereType<Map>().toList()
        : <Map>[];
    final connected = <Map<String, dynamic>>[];
    final failed = <Map<String, dynamic>>[];
    final skipped = <Map<String, dynamic>>[];
    for (final s in servers) {
      final name = (s['name'] ?? '').toString();
      final transport = (s['transport'] ?? 'stdio').toString().toLowerCase();
      final url = (s['url'] ?? '').toString();
      final httpLike =
          transport.contains('http') ||
          transport == 'sse' ||
          transport == 'streamable';
      if (!httpLike || !url.startsWith('http')) {
        skipped.add(<String, dynamic>{
          'name': name,
          'reason': transport == 'stdio'
              ? 'stdio 传输需启动本机进程，移动端不支持；可在桌面端/网关使用此配置'
              : '移动端仅支持 HTTP/SSE 传输，需填写服务 URL',
        });
        continue;
      }
      final client = McpClient(url);
      try {
        final title = await client.initialize();
        final list = await client.listTools();
        _mcpClients[name] = client;
        final toolNames = <String>[];
        for (final t in list) {
          final full = 'mcp.$name.${t.name}';
          if (tools.contains(full)) continue;
          tools.register(
            AgentTool(
              name: full,
              description: '[MCP:$name] ${t.description}',
              parameters: t.inputSchema,
              tier: ApprovalTier.write,
              execute: (args, token) async {
                final r = await client.callTool(t.name, args);
                return r.ok ? ToolResult.ok(r.text) : ToolResult.error(r.error);
              },
            ),
          );
          _mcpToolNames.add(full);
          toolNames.add(t.name);
        }
        connected.add(<String, dynamic>{
          'name': name,
          'server': title,
          'tools': toolNames,
        });
      } on Object catch (e) {
        client.dispose();
        failed.add(<String, dynamic>{'name': name, 'error': '$e'});
      }
    }
    // Integrations 里的 MCP 服务同样真实注册进 AgentLoop；凭据由
    // IntegrationRegistry 从系统安全存储读取，工具名用 int.<集成>.<工具>。
    try {
      final Map<String, dynamic> reg =
          await integrations.handle('list', <String, dynamic>{});
      for (final dynamic raw
          in (reg['integrations'] as List?) ?? const <dynamic>[]) {
        if (raw is! Map) continue;
        if ('${raw['kind']}' != 'mcp' || raw['enabled'] != true) continue;
        final String id = '${raw['id']}';
        final String name = '${raw['name']}';
        final Map<String, dynamic> toolsRes =
            await integrations.handle('tools', <String, dynamic>{'id': id});
        if (toolsRes['ok'] != true) {
          failed.add(<String, dynamic>{
            'name': name,
            'error': '${toolsRes['error'] ?? '读取工具失败'}',
          });
          continue;
        }
        final List<String> toolNames = <String>[];
        for (final dynamic t
            in (toolsRes['tools'] as List?) ?? const <dynamic>[]) {
          if (t is! Map) continue;
          final String toolName = '${t['name']}';
          if (toolName.isEmpty) continue;
          final String full = 'int.$name.$toolName';
          if (tools.contains(full)) continue;
          tools.register(
            AgentTool(
              name: full,
              description: '[集成:$name] ${t['description'] ?? ''}',
              parameters: t['input_schema'] is Map
                  ? Map<String, dynamic>.from(t['input_schema'] as Map)
                  : <String, dynamic>{},
              tier: ApprovalTier.write,
              execute: (args, _) async {
                final Map<String, dynamic> r = await integrations.handle(
                  'call',
                  <String, dynamic>{
                    'id': id,
                    'tool': toolName,
                    'arguments': args,
                  },
                );
                return r['ok'] == true
                    ? ToolResult.ok('${r['text'] ?? ''}')
                    : ToolResult.error('${r['error'] ?? '调用失败'}');
              },
            ),
          );
          _mcpToolNames.add(full);
          toolNames.add(toolName);
        }
        connected.add(<String, dynamic>{
          'name': name,
          'server': 'integration',
          'tools': toolNames,
        });
      }
    } on Object catch (e) {
      failed.add(<String, dynamic>{'name': 'integrations', 'error': '$e'});
    }
    StartupTimeline.global.mark('mcp.sync', background: true);
    return <String, dynamic>{
      'connected': connected,
      'failed': failed,
      'skipped': skipped,
      'registered_tools': _mcpToolNames.length,
    };
  }

  // ---- model_route：真实版本池 ----

  Future<Map<String, dynamic>> _modelRoute(Map<String, dynamic> p) async {
    final action = _action(p, 'list');
    final active = await store.readJson('active.json');
    final cards = store.scanFiles('cards', extensions: <String>{'.json'});
    final versions = <Map<String, dynamic>>[];
    for (final c in cards) {
      try {
        final m = jsonDecode(await File(c['path'] as String).readAsString());
        if (m is Map) {
          versions.add(<String, dynamic>{
            'tag': (m['tag'] ?? m['name'] ?? c['name']).toString(),
            'name': (m['name'] ?? c['name']).toString(),
            'active': active['active_tag'] == m['tag'],
            'path': c['path'],
          });
        }
      } on Object {
        // 损坏的卡片跳过，不冒充版本。
      }
    }
    final files = store.scanFiles('models', extensions: <String>{'.gguf'});
    for (final f in files) {
      versions.add(<String, dynamic>{
        'tag': f['name'],
        'name': f['name'],
        'active': active['active_path'] == f['path'],
        'path': f['path'],
        'size': f['size'],
      });
    }
    switch (action) {
      case 'list':
        return _ok(<String, dynamic>{
          'models': versions,
          'versions': versions,
          'active': active,
          'cards_dir': store.sub('cards').path,
        });
      case 'activate':
        final tag = (p['tag'] ?? p['path'] ?? p['gguf'] ?? '').toString();
        final match = versions.where((v) => v['tag'] == tag).toList();
        if (match.isEmpty) {
          return _err('版本池里没有可激活的权重：$tag');
        }
        final path = match.first['path'].toString();
        if (!File(path).existsSync()) return _err('权重文件不存在：$path');
        await store.writeJson('active.json', <String, dynamic>{
          'active': <String, dynamic>{'base': path, 'chat': path},
          'active_tag': tag,
          'active_path': path,
          'activated_at': DateTime.now().toIso8601String(),
        });
        return _ok(<String, dynamic>{'activated': tag, 'path': path});
      case 'rollback':
        return _err('版本回滚需要真实的历史权重文件；当前版本池里无可回滚版本');
      default:
        return _err('未知 model_route 动作：$action');
    }
  }

  // ---- model_store：真实硬件 / 内置目录 / 分片下载 ----

  /// 内置可下载模型目录（真实开源仓库元信息；size 以 HEAD 实测为准）。
  static const List<Map<String, dynamic>>
  builtinCatalog = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'qwen2.5-0.5b-q4',
      'name': 'Qwen2.5 0.5B Instruct (Q4_K_M)',
      'source': 'ModelScope 魔搭社区',
      'params': '0.5B',
      'quantization': 'Q4_K_M',
      'url':
          'https://www.modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/'
          'resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    },
    <String, dynamic>{
      'id': 'tinyllama-1.1b-q4',
      'name': 'TinyLlama 1.1B Chat (Q4_K_M)',
      'source': 'ModelScope 魔搭社区',
      'params': '1.1B',
      'quantization': 'Q4_K_M',
      'url':
          'https://www.modelscope.cn/models/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/'
          'resolve/master/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
    },
    <String, dynamic>{
      'id': 'qwen2.5-1.5b-q4',
      'name': 'Qwen2.5 1.5B Instruct (Q4_K_M)',
      'source': 'ModelScope 魔搭社区',
      'params': '1.5B',
      'quantization': 'Q4_K_M',
      'url':
          'https://www.modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/'
          'resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    },
  ];

  /// 从 HuggingFace 链接 / owner/repo 中解析仓库，兼容 /tree、/blob、镜像站。
  String? _parseHfRepo(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    Uri? uri;
    if (s.startsWith('http://') || s.startsWith('https://')) {
      uri = Uri.tryParse(s);
    } else if (s.contains('/') && !s.contains(' ')) {
      final parts = s.split('/').where((e) => e.isNotEmpty).toList();
      if (parts.length >= 2) return '${parts[0]}/${parts[1]}';
      return null;
    }
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (!host.contains('huggingface.co') && !host.contains('hf-mirror.com')) {
      return null;
    }
    final seg = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    if (seg.length < 2) return null;
    return '${seg[0]}/${seg[1]}';
  }

  /// 依次尝试 huggingface.co / hf-mirror.com；返回解析后的 JSON。
  Future<dynamic> _hfGetJson(String path, {String token = ''}) async {
    Object? last;
    for (final host in <String>['hf-mirror.com', 'huggingface.co']) {
      try {
        final req = http.Request('GET', Uri.parse('https://$host$path'))
          ..headers['User-Agent'] =
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0'
          ..headers['Accept'] = 'application/json';
        if (token.isNotEmpty) {
          req.headers['Authorization'] = 'Bearer $token';
        }
        final resp = await http.Response.fromStream(
          await req.send(),
        ).timeout(const Duration(seconds: 45));
        if (resp.statusCode == 200) {
          return jsonDecode(utf8.decode(resp.bodyBytes));
        }
        last = 'HTTP ${resp.statusCode}';
      } on Object catch (e) {
        last = e;
      }
    }
    throw StateError('$last');
  }

  Future<Map<String, dynamic>> _modelStore(Map<String, dynamic> p) async {
    final action = _action(p);
    switch (action) {
      case 'hardware':
        return await _hardware();
      case 'search' || 'catalog' || 'list':
        final q = (p['query'] ?? '').toString().trim().toLowerCase();
        final local = store.scanFiles(
          'downloads',
          extensions: <String>{'.gguf', '.bin'},
        );
        final models = builtinCatalog
            .where(
              (m) =>
                  q.isEmpty ||
                  m['name'].toString().toLowerCase().contains(q) ||
                  m['id'].toString().contains(q),
            )
            .map(
              (m) => <String, dynamic>{
                ...m,
                // 必须与完整模型 id 对应才算已下载；旧实现只比 id 首段
                // （如 qwen2），会把同前缀的另一个模型误报为已下载。
                'downloaded': local.any(
                  (f) =>
                      f['name'].toString() == '${m['id']}.gguf' ||
                      f['name'].toString().contains(m['id'].toString()),
                ),
              },
            )
            .toList();
        return <String, dynamic>{
          'source': 'ModelScope 魔搭社区',
          'models': models,
          'local_files': local,
        };
      case 'download' || 'start_download':
        final id = (p['model_id'] ?? p['id'] ?? '').toString();
        final url = (p['url'] ?? '').toString();
        final match = builtinCatalog.where((m) => m['id'] == id).toList();
        final targetUrl = url.isNotEmpty
            ? url
            : (match.isNotEmpty ? match.first['url'].toString() : '');
        if (targetUrl.isEmpty) {
          return _err('未提供下载 URL，且内置目录里没有模型 $id');
        }
        final expectedSha256 = (p['expected_sha256'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final job = await downloads.start(
          targetUrl,
          filename: match.isNotEmpty ? '$id.gguf' : null,
          chunks: 4,
          expectedSha256: expectedSha256.isEmpty ? null : expectedSha256,
        );
        _emit('download_progress', downloads.progress(job));
        return <String, dynamic>{
          'ok': job.status != 'failed',
          'job_id': job.id,
          'model_id': id,
          'status': job.status,
          'target': job.target,
          'engine': 'dart-range-chunks',
          'resumable': job.resumable,
          'sha256': job.actualSha256,
          'expected_sha256': job.expectedSha256,
          if (job.error != null) 'error': job.error,
          'note': '真实 HTTP 分片下载（Range + 断点续传），进度按落盘字节回写。',
        };
      case 'ms_search':
        {
          // 魔搭社区真实模型搜索：PUT /api/v1/dolphin/models（实测可用；
          // GET 风格端点全部 404）。返回真实仓库、下载量与任务标签。
          final q = (p['query'] ?? '').toString().trim();
          try {
            final req =
                http.Request(
                    'PUT',
                    Uri.parse(
                      'https://www.modelscope.cn/api/v1/dolphin/models',
                    ),
                  )
                  ..headers['Content-Type'] = 'application/json'
                  ..headers['User-Agent'] =
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0'
                  ..body = jsonEncode(<String, dynamic>{
                    // 2026-11-14 curl 实测：真正的搜索参数是 Name；只传 Query 会被
                    // 忽略并返回热门榜（旧实现的 bug：搜什么都出同样的榜单）。
                    // Query 字段保留，兼容接口未来恢复该参数名的可能。
                    'Name': q,
                    'Query': q,
                    'PageSize': 20,
                    'PageNumber': 1,
                    'Sort': 'Default',
                  });
            final resp = await http.Response.fromStream(
              await req.send(),
            ).timeout(const Duration(seconds: 12));
            if (resp.statusCode != 200) {
              return _err('魔搭搜索失败：HTTP ${resp.statusCode}');
            }
            final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
            final models = <Map<String, dynamic>>[];
            if (decoded is Map &&
                decoded['Data'] is Map &&
                (decoded['Data'] as Map)['Model'] is Map) {
              final list = ((decoded['Data'] as Map)['Model'] as Map)['Models'];
              if (list is List) {
                for (final e in list.whereType<Map>()) {
                  final owner = (e['Path'] ?? e['Namespace'] ?? '').toString();
                  final name = (e['Name'] ?? '').toString();
                  if (owner.isEmpty || name.isEmpty) continue;
                  final tasks = (e['Tasks'] is List)
                      ? (e['Tasks'] as List)
                            .whereType<Map>()
                            .map(
                              (t) => (t['ChineseName'] ?? t['Name'] ?? '')
                                  .toString(),
                            )
                            .where((s) => s.isNotEmpty)
                            .toList()
                      : <String>[];
                  models.add(<String, dynamic>{
                    'path': '$owner/$name',
                    'name': name,
                    'chinese_name': (e['ChineseName'] ?? '').toString(),
                    'owner': owner,
                    'downloads': e['Downloads'] is int ? e['Downloads'] : 0,
                    'likes': e['Likes'] is int ? e['Likes'] : 0,
                    'tasks': tasks,
                    'tags': (e['Tags'] is List)
                        ? (e['Tags'] as List).map((t) => t.toString()).toList()
                        : <String>[],
                  });
                }
              }
            }
            return <String, dynamic>{
              'ok': true,
              'source': 'modelscope.cn',
              'models': models,
              'total': models.length,
            };
          } on Object catch (e) {
            return _err('魔搭搜索失败：$e');
          }
        }
      case 'ms_files':
        {
          // 真实仓库文件列表（递归），只回 .gguf —— 端侧推理可直接下载。
          final mp = (p['model_path'] ?? '').toString().trim();
          if (mp.isEmpty || mp.contains('..')) return _err('缺少 model_path');
          try {
            final uri = Uri.https(
              'www.modelscope.cn',
              '/api/v1/models/$mp/repo/files',
              <String, String>{'Revision': 'master', 'Recursive': 'true'},
            );
            final resp = await http
                .get(
                  uri,
                  headers: <String, String>{
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0) Chrome/124.0',
                  },
                )
                .timeout(const Duration(seconds: 12));
            if (resp.statusCode != 200) {
              return _err('读取文件列表失败：HTTP ${resp.statusCode}');
            }
            final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
            final files = <Map<String, dynamic>>[];
            if (decoded is Map && decoded['Data'] is Map) {
              final raw = (decoded['Data'] as Map)['Files'];
              if (raw is List) {
                for (final f in raw.whereType<Map>()) {
                  final path = (f['Path'] ?? f['Name'] ?? '').toString();
                  if (!path.toLowerCase().endsWith('.gguf')) continue;
                  files.add(<String, dynamic>{
                    'path': path,
                    'name': path.split('/').last,
                    'size': f['Size'] is int ? f['Size'] : 0,
                  });
                }
              }
            }
            files.sort(
              (a, b) => (a['size'] as int).compareTo(b['size'] as int),
            );
            return <String, dynamic>{'ok': true, 'files': files};
          } on Object catch (e) {
            return _err('读取文件列表失败：$e');
          }
        }
      case 'ms_download':
        {
          // 真实下载魔搭 GGUF：resolve/master 直链 → DownloadManager
          // 分片 + 断点续传，进度按落盘字节回写。
          final mp = (p['model_path'] ?? '').toString().trim();
          final file = (p['file'] ?? '').toString().trim();
          if (mp.isEmpty ||
              file.isEmpty ||
              file.contains('..') ||
              mp.contains('..')) {
            return _err('缺少 model_path / file');
          }
          final url =
              'https://www.modelscope.cn/models/$mp/resolve/master/$file';
          final safeName = '${mp.split('/').last}-${file.split('/').last}'
              .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
          final expectedSha256 = (p['expected_sha256'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final job = await downloads.start(
            url,
            filename: safeName,
            chunks: 4,
            expectedBytes: (p['size'] is num) ? (p['size'] as num).toInt() : 0,
            expectedSha256: expectedSha256.isEmpty ? null : expectedSha256,
          );
          _emit('download_progress', downloads.progress(job));
          return <String, dynamic>{
            'ok': job.status != 'failed',
            'job_id': job.id,
            'status': job.status,
            'target': job.target,
            'filename': safeName,
            'resumable': job.resumable,
            'sha256': job.actualSha256,
            'expected_sha256': job.expectedSha256,
            if (job.error != null) 'error': job.error,
            'note': '真实 HTTP 分片下载（Range + 断点续传）。',
          };
        }
      case 'hf_search':
        {
          final q = (p['query'] ?? '').toString().trim();
          if (q.isEmpty) return _err('请输入模型名或 HuggingFace 链接');
          final token = (p['token'] ?? '').toString().trim();
          final parsed = _parseHfRepo(q);
          if (parsed != null) {
            return <String, dynamic>{
              'ok': true,
              'source': 'huggingface.co',
              'repo': parsed,
              'models': <Map<String, dynamic>>[
                <String, dynamic>{
                  'id': parsed,
                  'path': parsed,
                  'name': parsed.split('/').last,
                  'owner': parsed.split('/').first,
                  'downloads': 0,
                  'likes': 0,
                  'pipeline_tag': '',
                  'from_link': true,
                },
              ],
            };
          }
          try {
            final decoded = await _hfGetJson(
              '/api/models?search=${Uri.encodeQueryComponent(q)}'
              '&limit=20&sort=downloads&direction=-1',
              token: token,
            );
            if (decoded is! List) return _err('抱脸搜索返回非预期结构');
            final models = <Map<String, dynamic>>[];
            for (final e in decoded.whereType<Map>()) {
              final id = (e['id'] ?? e['modelId'] ?? '').toString();
              if (id.isEmpty) continue;
              models.add(<String, dynamic>{
                'id': id,
                'path': id,
                'name': id.split('/').last,
                'owner': id.contains('/') ? id.split('/').first : '',
                'downloads': e['downloads'] is num
                    ? (e['downloads'] as num).toInt()
                    : 0,
                'likes': e['likes'] is num ? (e['likes'] as num).toInt() : 0,
                'pipeline_tag': (e['pipeline_tag'] ?? '').toString(),
                'tags': e['tags'] is List
                    ? (e['tags'] as List).map((t) => t.toString()).toList()
                    : <String>[],
                'updated': (e['lastModified'] ?? '').toString(),
              });
            }
            return <String, dynamic>{
              'ok': true,
              'source': 'huggingface.co',
              'models': models,
              'total': models.length,
            };
          } on Object catch (e) {
            return _err('抱脸搜索失败：$e');
          }
        }
      case 'hf_files':
        {
          final repo =
              _parseHfRepo(
                (p['repo'] ?? p['url'] ?? p['model_path'] ?? '').toString(),
              ) ??
              '';
          if (repo.isEmpty || !repo.contains('/')) {
            return _err('缺少 HuggingFace 仓库（owner/repo）');
          }
          final token = (p['token'] ?? '').toString().trim();
          try {
            final decoded = await _hfGetJson(
              '/api/models/$repo/tree/main?recursive=true&expand=true',
              token: token,
            );
            if (decoded is! List) return _err('抱脸文件列表返回非预期结构');
            final files = <Map<String, dynamic>>[];
            for (final f in decoded.whereType<Map>()) {
              final path = (f['path'] ?? '').toString();
              final type = (f['type'] ?? '').toString();
              if (type != 'file' || !path.toLowerCase().endsWith('.gguf')) {
                continue;
              }
              files.add(<String, dynamic>{
                'path': path,
                'name': path.split('/').last,
                'size': f['size'] is num ? (f['size'] as num).toInt() : 0,
              });
            }
            files.sort(
              (a, b) => (a['size'] as int).compareTo(b['size'] as int),
            );
            return <String, dynamic>{
              'ok': true,
              'repo': repo,
              'files': files,
              if (files.isEmpty) 'note': '该仓库没有 GGUF 文件，需要先在电脑上转换后再上传/导入。',
            };
          } on Object catch (e) {
            return _err('读取抱脸文件列表失败：$e');
          }
        }
      case 'hf_download':
        {
          final repo =
              _parseHfRepo(
                (p['repo'] ?? p['url'] ?? p['model_path'] ?? '').toString(),
              ) ??
              '';
          final file = (p['file'] ?? p['file_path'] ?? '').toString().trim();
          if (repo.isEmpty || file.isEmpty || file.contains('..')) {
            return _err('缺少 HuggingFace repo / file');
          }
          final safeName = '${repo.split('/').last}-${file.split('/').last}'
              .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
          final expectedSha256 = (p['expected_sha256'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          DownloadJob? job;
          Object? lastError;
          for (final host in <String>['hf-mirror.com', 'huggingface.co']) {
            final url = 'https://$host/$repo/resolve/main/$file?download=true';
            try {
              job = await downloads.start(
                url,
                filename: safeName,
                chunks: 4,
                expectedBytes: (p['size'] is num)
                    ? (p['size'] as num).toInt()
                    : 0,
                expectedSha256: expectedSha256.isEmpty ? null : expectedSha256,
              );
              if (job.status != 'failed') break;
              lastError = job.error;
            } on Object catch (e) {
              lastError = e;
            }
          }
          if (job == null) return _err('抱脸下载启动失败：$lastError');
          _emit('download_progress', downloads.progress(job));
          return <String, dynamic>{
            'ok': job.status != 'failed',
            'job_id': job.id,
            'repo': repo,
            'file': file,
            'status': job.status,
            'target': job.target,
            'filename': safeName,
            'resumable': job.resumable,
            if (job.error != null) 'error': job.error,
            'note': 'HuggingFace 直链，失败自动切 hf-mirror.com；Range 分片 + 断点续传。',
          };
        }
      case 'download_status' || 'status':
        final jobId = (p['job_id'] ?? '').toString();
        final job = downloads.job(jobId);
        if (job == null) return _err('下载任务不存在：$jobId');
        final prog = downloads.progress(job);
        _emit('download_progress', prog);
        return <String, dynamic>{'ok': true, 'job': prog};
      case 'cancel':
        return <String, dynamic>{
          'ok': downloads.cancel((p['job_id'] ?? '').toString()),
        };
      default:
        return _err('未知 model_store 动作：$action');
    }
  }

  // ---- distill：工作蒸馏 / 版本池 ----

  Future<Map<String, dynamic>> _distill(Map<String, dynamic> p) async {
    final action = _action(p, 'describe');
    switch (action) {
      case 'version':
        return <String, dynamic>{
          'ok': true,
          'action': action,
          'data': <String, dynamic>{
            'version': version,
            'equation': 'agent = model + harness',
          },
        };
      case 'describe':
        final traces = await store.readRecords('work_traces');
        final turns = await store.readRecords('turns');
        final pairs = _qaPairsFrom(turns);
        return <String, dynamic>{
          'ok': true,
          'action': action,
          'data': <String, dynamic>{
            'equation': 'agent = model + harness',
            'version': version,
            'harness': <String, dynamic>{
              'work_traces': traces.length,
              'dialog_turns': turns.length,
              // 真实可蒸馏问答对数与门槛，供 UI 显示按钮可用状态。
              'distill_pairs': pairs.length,
              'distill_min_pairs': _minDistillPairs,
              'tools': tools.names,
              'backend': 'pure-dart-in-process',
            },
          },
        };
      case 'catalog':
        return <String, dynamic>{
          'ok': true,
          'action': action,
          'data': <String, dynamic>{
            'base_models': builtinCatalog,
            'own_models': _ownModels(),
          },
        };
      case 'models':
        return <String, dynamic>{
          'ok': true,
          'action': action,
          'data': <String, dynamic>{
            'base_models': builtinCatalog,
            'own_models': _ownModels(),
          },
        };
      case 'traces':
        {
          // 真实分页：limit（1..500，默认 100）/ offset（>=0）/ query（大小写
          // 不敏感包含匹配 task/text/reply/source）/ since（秒级 ts 下界）。
          final int limit = _asInt(p['limit'], 100).clamp(1, 500).toInt();
          final int rawOffset = _asInt(p['offset'], 0);
          final int offset = rawOffset < 0 ? 0 : rawOffset;
          final String query = (p['query'] ?? '')
              .toString()
              .trim()
              .toLowerCase();
          final double since = _asDouble(p['since'], 0);
          double tsOf(Map<String, dynamic> r) {
            final dynamic v = r['ts'];
            if (v is num) return v.toDouble();
            if (v is String) return double.tryParse(v) ?? 0;
            return 0;
          }

          final List<Map<String, dynamic>> matched =
              (await store.readRecords('work_traces')).where((
                Map<String, dynamic> r,
              ) {
                if (tsOf(r) < since) return false;
                if (query.isEmpty) return true;
                return <String>['task', 'text', 'reply', 'source'].any(
                  (String k) =>
                      (r[k] ?? '').toString().toLowerCase().contains(query),
                );
              }).toList()..sort(
                (Map<String, dynamic> a, Map<String, dynamic> b) =>
                    tsOf(b).compareTo(tsOf(a)),
              );
          final List<Map<String, dynamic>> page = matched
              .skip(offset)
              .take(limit)
              .toList();
          return <String, dynamic>{
            'ok': true,
            'action': action,
            'data': page,
            'total': matched.length,
            'limit': limit,
            'offset': offset,
          };
        }
      case 'work':
        final task = (p['task'] ?? p['text'] ?? '').toString().trim();
        if (task.isEmpty) return _err('工作轨迹内容为空');
        final id = await _appendTrace(<String, dynamic>{
          'kind': 'work',
          'task': task,
          'ts': _now(),
          'source': (p['source'] ?? 'manual').toString(),
        });
        final traces = await store.readRecords('work_traces');
        return <String, dynamic>{
          'ok': true,
          'action': action,
          'data': <String, dynamic>{
            'completion': task,
            'traces': traces.length,
            'id': id,
          },
        };
      case 'run':
        // 知识蒸馏：对 turns 表的真实对话语料做统计抽取，产出知识蒸馏包。
        return await _distillRun();
      case 'distill':
        // 真实蒸馏需要模型权重与教师输出；不具备时明确拒绝，不产出假模型。
        final traces = await store.readRecords('work_traces');
        return <String, dynamic>{
          'ok': false,
          'action': action,
          'error':
              '蒸馏需要真实基底模型权重与教师输出。当前已采集 '
              '${traces.length} 条真实工作轨迹，但未加载权重；'
              '请先下载 GGUF 基底模型或配置 API 教师凭据，不会伪造模型产物。',
          'data': <String, dynamic>{'traces': traces.length},
        };
      case 'download':
        final id = (p['model_id'] ?? p['id'] ?? '').toString();
        final match = builtinCatalog.where((m) => m['id'] == id).toList();
        if (match.isEmpty) return _err('内置目录里没有模型 $id');
        final expectedSha256 = (p['expected_sha256'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        final job = await downloads.start(
          match.first['url'].toString(),
          filename: '$id.gguf',
          chunks: 4,
          expectedSha256: expectedSha256.isEmpty ? null : expectedSha256,
        );
        return <String, dynamic>{
          'ok': job.status != 'failed',
          'action': action,
          'data': <String, dynamic>{
            'job_id': job.id,
            'target': job.target,
            'sha256': job.actualSha256,
            'expected_sha256': job.expectedSha256,
            if (job.error != null) 'error': job.error,
          },
        };
      case 'delete_model':
        return _deleteModel((p['name'] ?? '').toString());
      case 'rename_model':
        return await _renameModel(
          (p['name'] ?? '').toString(),
          (p['new_name'] ?? '').toString(),
        );
      default:
        return _err('未知 distill 动作：$action');
    }
  }

  // ---- 知识蒸馏（run）：真实统计抽取对话语料，产出知识蒸馏包 ----

  /// 中文常见双字停用词（统计话题簇时剔除，避免「什么/怎么」霸榜）。
  static const Set<String> _cjkStopwords = <String>{
    '什么',
    '怎么',
    '如何',
    '可以',
    '这个',
    '那个',
    '一个',
    '一下',
    '请问',
    '帮我',
    '给我',
    '觉得',
    '知道',
    '希望',
    '需要',
    '想要',
    '问题',
    '东西',
    '时候',
    '现在',
    '然后',
    '已经',
    '还是',
    '或者',
    '因为',
    '所以',
    '如果',
    '但是',
    '就是',
    '不是',
    '有什',
    '为什',
    '哪些',
    '多少',
    '是否',
    '应该',
    '可能',
    '一样',
    '一直',
    '有点',
    '好的',
    '谢谢',
    '你帮',
    '我帮',
    '我们',
    '你们',
    '他们',
    '这样',
    '那样',
    '有没',
    '没什',
    '能不',
    '是不',
    '对什',
    '关于',
    '使用',
  };

  /// 对 turns 表的真实对话语料做统计蒸馏：
  ///  1) 按 session 把 user→assistant 配成 Q→A 对（取近 400 对）；
  ///  2) 话题簇：用户提问分词（ASCII 词 + 中文连续串双字组），词频 top 20；
  ///  3) 高频问答对：最多 60 条真实抽取（截断存储）；
  ///  4) 用户偏好摘要 + 语料统计（轮数 / token 估算），全部来自真实计数；
  ///  5) 写入 models/ 目录（_ownModels 扫描目录），命名 tga-distill-日期.json。
  /// 产物是统计抽取的知识包，不是神经网络权重，文件内如实标注。
  /// 蒸馏门槛按「一问一答的配对数」计：几轮真实对话即可产出知识包，
  /// 不必凑满十条消息（旧门槛与 UI 显示的消息条数语义不一致）。
  static const int _minDistillPairs = 3;

  /// 把 turns 按 session 配成 user→assistant 问答对。
  /// describe 与 run 共用，UI 显示的可蒸馏轮数与实际执行条件才一致。
  static List<Map<String, dynamic>> _qaPairsFrom(
    List<Map<String, dynamic>> turns,
  ) {
    final pending = <String, Map<String, dynamic>>{};
    final pairs = <Map<String, dynamic>>[];
    for (final t in turns) {
      final session = (t['session_id'] ?? 'default').toString();
      final role = (t['role'] ?? '').toString();
      final text = (t['text'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      if (role == 'user') {
        pending[session] = t;
      } else if (role == 'assistant') {
        final q = pending.remove(session);
        if (q != null) {
          pairs.add(<String, dynamic>{
            'question': q['text'].toString(),
            'answer': text,
            'session_id': session,
            'ts': t['ts'] is num ? t['ts'] : q['ts'],
          });
        }
      }
    }
    return pairs;
  }

  Future<Map<String, dynamic>> _distillRun() async {
    final turns = await store.readRecords('turns');
    final allPairs = _qaPairsFrom(turns);
    if (allPairs.length < _minDistillPairs) {
      return <String, dynamic>{
        'ok': false,
        'action': 'run',
        'error':
            '可蒸馏问答对不足（当前 ${allPairs.length} 对，'
            '至少需 $_minDistillPairs 对一问一答）',
        'data': <String, dynamic>{
          'pairs': allPairs.length,
          'required': _minDistillPairs,
        },
      };
    }
    final corpus = allPairs.length > 400
        ? allPairs.sublist(allPairs.length - 400)
        : allPairs;

    // ---- 2) 话题簇：对用户提问分词统计 ----
    final freq = <String, int>{};
    final asciiRe = RegExp(r'[A-Za-z0-9_+#.\-]{2,}');
    final cjkRe = RegExp(r'[\u4e00-\u9fff]+');
    for (final pair in corpus) {
      final q = pair['question'].toString();
      for (final m in asciiRe.allMatches(q.toLowerCase())) {
        final w = m.group(0)!;
        freq[w] = (freq[w] ?? 0) + 1;
      }
      for (final m in cjkRe.allMatches(q)) {
        final run = m.group(0)!;
        for (var i = 0; i + 2 <= run.length; i++) {
          final bg = run.substring(i, i + 2);
          if (_cjkStopwords.contains(bg)) continue;
          freq[bg] = (freq[bg] ?? 0) + 1;
        }
      }
    }
    final ranked = freq.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topKeywords = ranked
        .where((e) => e.value >= 2)
        .take(20)
        .map((e) => e.key)
        .toList();
    final topics = <Map<String, dynamic>>[];
    for (final kw in topKeywords) {
      final matched = corpus
          .where((pair) => pair['question'].toString().contains(kw))
          .toList();
      topics.add(<String, dynamic>{
        'keyword': kw,
        'count': matched.length,
        'examples': matched.take(3).map((p) {
          final q = p['question'].toString().replaceAll('\n', ' ');
          return q.length <= 60 ? q : '${q.substring(0, 60)}…';
        }).toList(),
      });
    }

    // ---- 3) 高频问答对：真实抽取，截断存储 ----
    final qaPairs = corpus.reversed
        .take(60)
        .toList()
        .reversed
        .map(
          (p) => <String, dynamic>{
            'question': _clipText(p['question'].toString(), 300),
            'answer': _clipText(p['answer'].toString(), 300),
            'ts': p['ts'],
          },
        )
        .toList();

    // ---- 4) 用户偏好摘要 + 语料统计（全部真实计数）----
    var qChars = 0, aChars = 0, shortQ = 0, cjkChars = 0, asciiWords = 0;
    final sessions = <String>{};
    final days = <String>{};
    double minTs = 0, maxTs = 0;
    for (final p in corpus) {
      final q = p['question'].toString();
      final a = p['answer'].toString();
      qChars += q.length;
      aChars += a.length;
      if (q.length < 15) shortQ += 1;
      sessions.add(p['session_id'].toString());
      cjkChars +=
          RegExp(r'[\u4e00-\u9fff]').allMatches(q).length +
          RegExp(r'[\u4e00-\u9fff]').allMatches(a).length;
      asciiWords +=
          RegExp(r'[A-Za-z0-9_]+').allMatches(q).length +
          RegExp(r'[A-Za-z0-9_]+').allMatches(a).length;
      final ts = p['ts'];
      if (ts is num) {
        if (minTs == 0 || ts.toDouble() < minTs) minTs = ts.toDouble();
        if (ts.toDouble() > maxTs) maxTs = ts.toDouble();
      }
    }
    for (final p in corpus) {
      final ts = p['ts'];
      if (ts is num) days.add(_dayOfTs(ts.toDouble()));
    }
    final estimatedTokens = cjkChars + (asciiWords * 1.3).round();
    final avgQ = (qChars / corpus.length).round();
    final avgA = (aChars / corpus.length).round();
    final topInterests = topKeywords.take(5).toList();
    final preferences = <String, dynamic>{
      'avg_question_chars': avgQ,
      'avg_answer_chars': avgA,
      'short_question_ratio': double.parse(
        (shortQ / corpus.length).toStringAsFixed(2),
      ),
      'sessions': sessions.length,
      'active_days': days.length,
      'top_interests': topInterests,
      'summary':
          '你平均每次提问 $avgQ 字、助手平均回复 $avgA 字；'
          '话题集中在 ${topInterests.join('、')}',
    };

    // ---- 5) 写入 _ownModels 扫描目录（models/），命名带日期 ----
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final day = '${now.year}-${two(now.month)}-${two(now.day)}';
    var name = 'tga-distill-$day.json';
    if (File('${store.sub('models').path}/$name').existsSync()) {
      name =
          'tga-distill-$day-${two(now.hour)}${two(now.minute)}'
          '${two(now.second)}.json';
    }
    final pack = <String, dynamic>{
      'type': 'tga-knowledge-pack',
      'title': '知识蒸馏包（统计抽取，非神经网络权重）',
      'disclaimer':
          '本文件由 TGA harness 对真实对话语料做统计蒸馏产出，'
          '内容是话题簇/问答对/偏好摘要等知识条目，不是模型权重。',
      'generated_at': now.toIso8601String(),
      'harness_version': version,
      'corpus_stats': <String, dynamic>{
        'turn_records': turns.length,
        'paired_turns': corpus.length,
        'qa_pairs_extracted': qaPairs.length,
        'estimated_tokens': estimatedTokens,
        'time_range': <String, dynamic>{
          'from': minTs > 0 ? _dayOfTs(minTs) : '',
          'to': maxTs > 0 ? _dayOfTs(maxTs) : '',
        },
      },
      'topics': topics,
      'qa_pairs': qaPairs,
      'preferences': preferences,
    };
    await store.writeJson('models/$name', pack);

    return <String, dynamic>{
      'ok': true,
      'action': 'run',
      'data': <String, dynamic>{
        'file': '${store.sub('models').path}/$name',
        'name': name,
        'pairs': qaPairs.length,
        'topics': topics.length,
        'corpus_turns': corpus.length,
      },
    };
  }

  static String _clipText(String s, int max) {
    final one = s.trim();
    return one.length <= max ? one : '${one.substring(0, max)}…';
  }

  static String _dayOfTs(double tsSeconds) =>
      DateTime.fromMillisecondsSinceEpoch(
        (tsSeconds * 1000).round(),
      ).toLocal().toIso8601String().substring(0, 10);

  /// 判断 models/ 下的 JSON 是否是知识蒸馏包（按文件内 type 标记识别，
  /// 重命名后依然能被识别；解析失败一律不算，不虚构条目）。
  bool _isKnowledgePack(String path) {
    try {
      final f = File(path);
      if (!f.existsSync() || f.lengthSync() > 8 * 1024 * 1024) return false;
      final decoded = jsonDecode(f.readAsStringSync());
      return decoded is Map && decoded['type'] == 'tga-knowledge-pack';
    } on Object {
      return false;
    }
  }

  List<Map<String, dynamic>> _ownModels() {
    final out = <Map<String, dynamic>>[
      ...store
          .scanFiles('models', extensions: <String>{'.gguf'})
          .map(
            (f) => <String, dynamic>{
              'name': f['name'],
              'path': f['path'],
              'size': f['size'],
              'modified': f['modified'],
              'version': version,
              'source': 'local',
              'kind': 'gguf',
            },
          ),
      // 知识蒸馏包：models/ 下带 tga-knowledge-pack 标记的真实 JSON 文件。
      ...store
          .scanFiles('models', extensions: <String>{'.json'})
          .where((f) => _isKnowledgePack(f['path'].toString()))
          .map(
            (f) => <String, dynamic>{
              'name': f['name'],
              'path': f['path'],
              'size': f['size'],
              'modified': f['modified'],
              'version': version,
              'source': 'distill',
              'kind': 'knowledge',
              'label': '知识蒸馏包',
            },
          ),
    ];
    return out;
  }

  Map<String, dynamic> _deleteModel(String name) {
    if (name.isEmpty || name.contains('/') || name.contains('..')) {
      return _err('非法模型名称');
    }
    final f = File('${store.sub('models').path}/$name');
    if (!f.existsSync()) return _err('模型文件不存在：$name');
    f.deleteSync();
    return <String, dynamic>{
      'ok': true,
      'action': 'delete_model',
      'data': <String, dynamic>{'name': name},
    };
  }

  Future<Map<String, dynamic>> _renameModel(String old, String next) async {
    if (old.isEmpty ||
        next.isEmpty ||
        old.contains('/') ||
        next.contains('/') ||
        old.contains('..') ||
        next.contains('..')) {
      return _err('非法模型名称');
    }
    final src = File('${store.sub('models').path}/$old');
    final dst = File('${store.sub('models').path}/$next');
    if (!src.existsSync()) return _err('模型文件不存在：$old');
    if (dst.existsSync()) return _err('目标名称已存在：$next');
    await src.rename(dst.path);
    return <String, dynamic>{
      'ok': true,
      'action': 'rename_model',
      'data': <String, dynamic>{'name': next},
    };
  }

  Future<int> _appendTrace(Map<String, dynamic> record) =>
      store.insert('work_traces', record);

  // ---- device_file：真实受限文件操作（沙箱内，路径防越界）----

  Future<Map<String, dynamic>> _deviceFile(Map<String, dynamic> p) async {
    final action = _action(p, 'status');
    final args = p['args'] is Map
        ? (p['args'] as Map).map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v),
          )
        : <String, dynamic>{};
    final root = store.sub('sandbox').path;

    String resolve(String rel) {
      final normalized = rel.replaceAll('\\', '/');
      if (normalized.contains('..')) {
        throw StateError('路径越界被拒绝：$rel');
      }
      final clean = normalized.startsWith('$root/') || normalized == root
          ? normalized
          : '$root/${normalized.replaceFirst(RegExp(r'^/+'), '')}';
      return clean;
    }

    try {
      dynamic data;
      switch (action) {
        case 'status':
          data = <String, dynamic>{
            'access': 'granted',
            'roots': <String>[root],
            'writable': store.writable,
          };
        case 'request_access':
          data = <String, dynamic>{'access': 'granted', 'granted': true};
        case 'list':
          final dir = Directory(resolve((args['path'] ?? '').toString()));
          if (!dir.existsSync()) return _err('目录不存在：${dir.path}');
          data = dir
              .listSync(followLinks: false)
              .map(
                (e) => <String, dynamic>{
                  'name': e.uri.pathSegments.where((s) => s.isNotEmpty).last,
                  'path': e.path,
                  'is_directory': e is Directory,
                  'size': e is File ? e.statSync().size : 0,
                  'modified': e.statSync().modified.toIso8601String(),
                },
              )
              .toList();
        case 'read':
          final f = File(resolve((args['path'] ?? '').toString()));
          if (!f.existsSync()) return _err('文件不存在：${f.path}');
          if (f.lengthSync() > 1024 * 1024) return _err('文件超过 1MB 读取上限');
          data = <String, dynamic>{
            'path': f.path,
            'content': await f.readAsString(),
          };
        case 'write':
          final f = File(resolve((args['path'] ?? '').toString()));
          await f.parent.create(recursive: true);
          await f.writeAsString((args['content'] ?? '').toString());
          data = <String, dynamic>{'path': f.path, 'written': f.lengthSync()};
        case 'mkdir':
          final d = Directory(resolve((args['path'] ?? '').toString()));
          await d.create(recursive: true);
          data = <String, dynamic>{'path': d.path};
        case 'copy':
          await File(
            resolve(args['from'].toString()),
          ).copy(resolve(args['to'].toString()));
          data = <String, dynamic>{'ok': true};
        case 'move':
          await File(
            resolve(args['from'].toString()),
          ).rename(resolve(args['to'].toString()));
          data = <String, dynamic>{'ok': true};
        case 'rename':
          await File(
            resolve(args['path'].toString()),
          ).rename(resolve(args['new_name'].toString()));
          data = <String, dynamic>{'ok': true};
        case 'delete':
          final target = resolve((args['path'] ?? '').toString());
          final entity =
              FileSystemEntity.typeSync(target) ==
                  FileSystemEntityType.directory
              ? Directory(target)
              : File(target);
          await entity.delete(recursive: true);
          data = <String, dynamic>{'deleted': target};
        case 'search':
          final dir = Directory(resolve((args['path'] ?? '').toString()));
          final kw = (args['keyword'] ?? '').toString().toLowerCase();
          if (!dir.existsSync()) return _err('目录不存在：${dir.path}');
          data = dir
              .listSync(recursive: true, followLinks: false)
              .where((e) => e.path.toLowerCase().contains(kw))
              .take(200)
              .map(
                (e) => <String, dynamic>{
                  'path': e.path,
                  'is_directory': e is Directory,
                },
              )
              .toList();
        case 'largest_files':
          final dir = Directory(resolve((args['path'] ?? '').toString()));
          if (!dir.existsSync()) return _err('目录不存在：${dir.path}');
          final files =
              dir
                  .listSync(recursive: true, followLinks: false)
                  .whereType<File>()
                  .map(
                    (f) => <String, dynamic>{
                      'path': f.path,
                      'size': f.statSync().size,
                    },
                  )
                  .toList()
                ..sort(
                  (a, b) => (b['size'] as int).compareTo(a['size'] as int),
                );
          data = files.take(20).toList();
        default:
          return _err('未知 device_file 动作：$action');
      }
      return <String, dynamic>{
        'ok': true,
        'op': action,
        'data': data,
        'error': '',
        'needs_permission': false,
      };
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'op': action,
        'error': '$e',
        'needs_permission': false,
      };
    }
  }

  // ---- memory_event：真实日记 ----

  Future<Map<String, dynamic>> _memoryEvent(Map<String, dynamic> p) async {
    final action = _action(p, 'diary');
    final turns = await store.readRecords('turns');
    if (action == 'diary') {
      final Map<String, List<Map<String, dynamic>>> days =
          <String, List<Map<String, dynamic>>>{};
      for (final t in turns) {
        final ts = t['ts'];
        final millis = ts is num
            ? (ts * 1000).round()
            : DateTime.now().millisecondsSinceEpoch;
        final day = DateTime.fromMillisecondsSinceEpoch(
          millis,
        ).toLocal().toIso8601String().substring(0, 10);
        days.putIfAbsent(day, () => <Map<String, dynamic>>[]).add(t);
      }
      final out =
          days.entries
              .map((e) => <String, dynamic>{'day': e.key, 'entries': e.value})
              .toList()
            ..sort(
              (a, b) => (b['day'] as String).compareTo(a['day'] as String),
            );
      return <String, dynamic>{'days': out};
    }
    if (action == 'delete_day') {
      final day = (p['day'] ?? '').toString();
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
        return <String, dynamic>{'ok': false, 'error': '非法日期'};
      }
      final kept = <Map<String, dynamic>>[];
      var deleted = 0;
      for (final t in turns) {
        final ts = t['ts'];
        final millis = ts is num
            ? (ts * 1000).round()
            : DateTime.now().millisecondsSinceEpoch;
        final d = DateTime.fromMillisecondsSinceEpoch(
          millis,
        ).toLocal().toIso8601String().substring(0, 10);
        if (d == day) {
          deleted++;
        } else {
          kept.add(t);
        }
      }
      await store.writeRecords('turns', kept);
      return <String, dynamic>{'ok': true, 'deleted': deleted};
    }
    return <String, dynamic>{'ok': false, 'error': '未知动作：$action'};
  }

  // ---- proactive_task：真实规则 ----

  Future<Map<String, dynamic>> _proactiveTask(Map<String, dynamic> p) async {
    final action = _action(p, 'list');
    final rules = await store.readRecords('proactive_rules');
    switch (action) {
      case 'list':
        return _ok(<String, dynamic>{
          'rules': rules
              .map(
                (r) => <String, dynamic>{
                  'id': r['id'],
                  'title': r['title'] ?? r['name'] ?? '规则',
                  'name': r['name'] ?? r['title'] ?? '规则',
                  'enabled': r['enabled'] == true || r['enabled'] == 1,
                  // 规则由 App 内 TaskScheduler 执行：每 30s 轮询，
                  // 仅在 App 进程存活期间触发（平台限制，如实说明）。
                  'scheduled': true,
                  'ts': r['ts'],
                },
              )
              .toList(),
          'timers': <String>[],
          'scheduler': 'in-app',
          'note': '规则由 App 内调度器在进程存活期间按 HH:mm 触发执行',
        });
      case 'add':
        final title = (p['title'] ?? p['name'] ?? '').toString().trim();
        if (title.isEmpty) return _err('规则标题为空');
        final id = await store.insert('proactive_rules', <String, dynamic>{
          'title': title,
          'name': title,
          'enabled': 1,
          'ts': _now(),
        });
        return _ok(<String, dynamic>{'id': id});
      case 'set_rule':
        final name = (p['name'] ?? '').toString();
        final enabled = p['enabled'] == true;
        for (final r in rules) {
          if ((r['name'] ?? r['title']).toString() == name) {
            await store.update(
              'proactive_rules',
              r['id'] as int,
              <String, dynamic>{'enabled': enabled ? 1 : 0},
            );
            return _ok();
          }
        }
        return _err('规则不存在：$name');
      case 'toggle':
        final id = int.tryParse('${p['id'] ?? 0}') ?? 0;
        final found = rules.where((r) => r['id'] == id).toList();
        if (found.isEmpty) return _err('规则不存在');
        final cur = found.first['enabled'];
        await store.update('proactive_rules', id, <String, dynamic>{
          'enabled': (cur == true || cur == 1) ? 0 : 1,
        });
        return _ok();
      case 'delete':
        final id = int.tryParse('${p['id'] ?? 0}') ?? 0;
        final name = (p['name'] ?? '').toString();
        var target = id;
        if (target == 0 && name.isNotEmpty) {
          final found = rules
              .where((r) => (r['name'] ?? r['title']).toString() == name)
              .toList();
          if (found.isNotEmpty) target = found.first['id'] as int;
        }
        return <String, dynamic>{
          'ok': await store.remove('proactive_rules', target),
        };
      default:
        return _err('未知 proactive_task 动作：$action');
    }
  }

  // ---- security_approval：真实审批 + 权限策略 + 审计 ----

  /// 懒加载的权限策略：首次使用时从 security/policy.json 恢复。
  late PermissionPolicy _policy = PermissionPolicy.withDefaults();

  /// 懒加载的审计日志（append-only，落 HarnessStore）。
  late final AuditLog _audit = AuditLog(store: store);

  bool _policyLoaded = false;

  static const String _policyFile = 'security/policy.json';

  Future<PermissionPolicy> _ensurePolicy() async {
    if (_policyLoaded) return _policy;
    final saved = await store.readJson(_policyFile);
    if (saved.isNotEmpty) _policy = PermissionPolicy.fromJson(saved);
    _policyLoaded = true;
    return _policy;
  }

  Future<void> _savePolicy() async {
    await store.writeJson(_policyFile, _policy.toJson());
  }

  /// 权限策略引擎（懒加载：首次使用时恢复 security/policy.json）。
  Future<PermissionPolicy> _policyEngine() => _ensurePolicy();

  /// 审计日志（懒加载，append-only）。
  AuditLog _auditLog() => _audit;

  /// 一次性放行凭据：ask 拦截时建单即写入 grant_key，用户「批准」后由被拦
  /// 动作在下次重试时消费（consumed=1）。否则批准只改 status，重试仍被拦截
  /// 并重复建单，审批永远空转。
  Future<bool> _consumeGrant(String grantKey) async {
    if (grantKey.isEmpty) return false;
    final List<Map<String, dynamic>> rows = await store.readRecords(
      'approvals',
    );
    for (int i = rows.length - 1; i >= 0; i--) {
      final Map<String, dynamic> r = rows[i];
      if (r['status'] != 'approved' ||
          r['grant_key'] != grantKey ||
          r['consumed'] == 1) {
        continue;
      }
      final Object? rawId = r['id'];
      final int id = rawId is int ? rawId : int.tryParse('$rawId') ?? 0;
      if (id <= 0) continue;
      if (!await store.update('approvals', id, <String, dynamic>{
        'consumed': 1,
      })) {
        return false;
      }
      await _auditLog().append(
        category: 'approval',
        action: 'grant_consumed',
        decision: 'allow',
        detail: grantKey.length > 120 ? grantKey.substring(0, 120) : grantKey,
      );
      return true;
    }
    return false;
  }

  /// 工作区域文件动作守卫：策略 allow 放行，ask/deny 拦截并写审计。
  /// ask 时额外落一条 approvals 待办，并把审批单号带回拒绝信息。
  Future<bool> _workspaceGuard(String tool, String path) async {
    final String action = 'workspace.$tool';
    final String grantKey = 'workspace|$tool|$path';
    PolicyDecision decision = (await _policyEngine()).evaluate(
      tool: action,
      path: path,
    );
    // ask 命中的一次性放行凭据：批准后重试同一文件动作直接放行，不再空转建单。
    if (decision == PolicyDecision.ask && await _consumeGrant(grantKey)) {
      decision = PolicyDecision.allow;
    }
    await _auditLog().append(
      category: 'security',
      action: action,
      decision: decision.name,
      actor: 'workspace',
      detail: path,
    );
    if (decision == PolicyDecision.allow) return true;
    if (decision == PolicyDecision.ask) {
      final int id = await store.insert('approvals', <String, dynamic>{
        'action': '工作区域 $tool: $path',
        'status': 'pending',
        'grant_key': grantKey,
        'consumed': 0,
        'ts': _now(),
      });
      throw WorkspaceGuardDenied('操作需要审批：$path（审批 ID：$id，请在安全中心批准后重试）');
    }
    return false;
  }

  Future<void> _auditAppend({
    required String category,
    required String action,
    required String decision,
    required String actor,
    Map<String, dynamic> detail = const <String, dynamic>{},
  }) {
    return _auditLog().append(
      category: category,
      action: action,
      decision: decision,
      actor: actor,
      detail: detail.isEmpty ? '' : jsonEncode(detail),
    );
  }

  Future<Map<String, dynamic>> _securityApproval(Map<String, dynamic> p) async {
    final action = _action(p, 'list');
    switch (action) {
      case 'list':
        final rows = await store.readRecords('approvals');
        return _ok(<String, dynamic>{'approvals': rows});
      case 'request':
        final id = await store.insert('approvals', <String, dynamic>{
          'action': (p['name'] ?? '未命名操作').toString(),
          'status': 'pending',
          'ts': _now(),
        });
        return _ok(<String, dynamic>{'id': id});
      case 'approve' || 'deny':
        final id = int.tryParse('${p['id'] ?? 0}') ?? 0;
        final ok = await store.update('approvals', id, <String, dynamic>{
          'status': action == 'approve' ? 'approved' : 'denied',
        });
        await _auditAppend(
          category: 'approval',
          action: action,
          decision: action == 'approve' ? 'approved' : 'denied',
          actor: (p['actor'] ?? 'user').toString(),
          detail: <String, dynamic>{'id': id, 'ok': ok},
        );
        return <String, dynamic>{'ok': ok};

      case 'policy_list':
        final policy = await _ensurePolicy();
        return _ok(<String, dynamic>{
          'rules': policy.rules.map((PermissionRule r) => r.toJson()).toList(),
          'fallback': policy.fallback.name,
        });

      case 'policy_set':
        final raw = <String, dynamic>{};
        final supplied = p['rule'];
        if (supplied is Map) {
          raw.addAll(
            supplied.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
          );
        }
        for (final String key in const <String>[
          'id',
          'tool',
          'path',
          'args',
          'decision',
          'enabled',
          'note',
        ]) {
          if (p.containsKey(key)) raw[key] = p[key];
        }
        if (raw.isEmpty) return _err('缺少权限规则字段');
        final rule = PermissionRule.fromJson(raw);
        if (rule.id.isEmpty) return _err('权限规则缺少 id');
        final policy = await _ensurePolicy();
        final rules = List<PermissionRule>.of(policy.rules);
        final index = rules.indexWhere((PermissionRule r) => r.id == rule.id);
        final replaced = index >= 0;
        if (replaced) {
          rules[index] = rule;
        } else {
          // 规则按声明顺序求值、首个命中即生效：内置 default-allow-shell /
          // default-allow-workspace 等放行规则排在前面时，用户新建的 shell
          // deny/ask 规则永远命中不到。新规则插到第一条内置 allow 规则之前，
          // 既优先于内置放行，又保留内置 deny/ask（私钥、破坏性命令）的前置拦截。
          final int firstDefaultAllow = rules.indexWhere(
            (PermissionRule r) =>
                r.decision == PolicyDecision.allow &&
                r.id.startsWith('default-'),
          );
          if (firstDefaultAllow >= 0) {
            rules.insert(firstDefaultAllow, rule);
          } else {
            rules.add(rule);
          }
        }
        _policy = PermissionPolicy(rules: rules, fallback: policy.fallback);
        await _savePolicy();
        await _auditAppend(
          category: 'security',
          action: 'policy_set',
          decision: rule.decision.name,
          actor: (p['actor'] ?? 'user').toString(),
          detail: <String, dynamic>{'id': rule.id, 'replaced': replaced},
        );
        return _ok(<String, dynamic>{
          'rule': rule.toJson(),
          'replaced': replaced,
        });

      case 'policy_remove':
        final ruleId = (p['id'] ?? '').toString().trim();
        if (ruleId.isEmpty) return _err('缺少权限规则 id');
        final policy = await _ensurePolicy();
        final rules = List<PermissionRule>.of(policy.rules);
        final before = rules.length;
        rules.removeWhere((PermissionRule r) => r.id == ruleId);
        if (rules.length == before) return _err('权限规则不存在：$ruleId');
        _policy = PermissionPolicy(rules: rules, fallback: policy.fallback);
        await _savePolicy();
        await _auditAppend(
          category: 'security',
          action: 'policy_remove',
          decision: 'removed',
          actor: (p['actor'] ?? 'user').toString(),
          detail: <String, dynamic>{'id': ruleId},
        );
        return _ok(<String, dynamic>{
          'id': ruleId,
          'removed': before - rules.length,
        });

      case 'policy_evaluate':
        final tool = (p['tool'] ?? '').toString().trim();
        if (tool.isEmpty) return _err('缺少 tool');
        final path = (p['path'] ?? '').toString();
        final rawArgs = p['args'];
        final args = rawArgs is String
            ? rawArgs
            : (rawArgs == null ? '' : jsonEncode(rawArgs));
        final policy = await _ensurePolicy();
        String? matched;
        for (final PermissionRule rule in policy.rules) {
          if (rule.matches(tool: tool, path: path, args: args)) {
            matched = rule.id;
            break;
          }
        }
        return _ok(<String, dynamic>{
          'decision': policy.evaluate(tool: tool, path: path, args: args).name,
          'matched': matched,
        });

      case 'audit_list':
        final category = (p['category'] ?? '').toString().trim();
        final limit = int.tryParse('${p['limit'] ?? ''}') ?? 100;
        final events = category.isEmpty
            ? await _audit.all()
            : await _audit.query(category: category, limit: limit);
        final take = limit <= 0 ? 0 : limit;
        final limited = events.length > take
            ? events.sublist(events.length - take)
            : events;
        return _ok(<String, dynamic>{
          'events': limited.map((AuditEvent e) => e.toJson()).toList(),
          'stats': await _audit.stats(),
        });

      case 'audit_export':
        return _ok(<String, dynamic>{'jsonl': await _audit.exportJsonl()});

      case 'audit_import':
        final jsonl = (p['jsonl'] ?? '').toString();
        if (jsonl.trim().isEmpty) return _err('jsonl 为空');
        return _ok(<String, dynamic>{
          'imported': await _audit.importJsonl(jsonl),
        });

      case 'audit_verify':
        return <String, dynamic>{
          'ok': true,
          'result': await _auditLog().verifyChain(),
        };

      default:
        return _err('未知 security_approval 动作：$action');
    }
  }

  // ---- plugin_lifecycle / plugin_community ----

  Future<Map<String, dynamic>> _pluginLifecycle(Map<String, dynamic> p) async {
    final action = _action(p, 'list');
    final files = store.scanFiles('plugins', extensions: <String>{'.json'});
    if (action == 'list') {
      // 如实上报：dep_status 不做依赖检查就不能报「就绪」；版本读插件
      // 自身 json 里声明的 version，而不是拿 App 版本号充数。
      final plugins = <Map<String, dynamic>>[];
      for (final f in files) {
        var declared = '';
        try {
          final content = await store
              .file('plugins/${f['name']}')
              .readAsString();
          final j = jsonDecode(content);
          if (j is Map) declared = (j['version'] ?? '').toString();
        } on Object {
          declared = '';
        }
        plugins.add(<String, dynamic>{
          'name': f['name'],
          'id': f['name'],
          'permission': 'local',
          'dep_status': '未校验',
          'installed': true,
          'versions': declared.isEmpty ? <String>[] : <String>[declared],
          'latest': declared,
        });
      }
      return _ok(<String, dynamic>{
        'plugins': plugins,
        'pool': store.sub('plugins').path,
      });
    }
    if (action == 'install') {
      final name = (p['name'] ?? '').toString().trim();
      if (name.isEmpty || name.contains('/') || name.contains('..')) {
        return _err('非法插件名称');
      }
      final f = store.file(
        'plugins/${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json',
      );
      await f.writeAsString(
        jsonEncode(<String, dynamic>{
          'name': name,
          'version': version,
          'installed_at': DateTime.now().toIso8601String(),
          'source': 'local',
        }),
        flush: true,
      );
      return _ok(<String, dynamic>{'name': name});
    }
    if (action == 'uninstall') {
      final name = (p['name'] ?? '').toString().trim();
      if (name.isEmpty) return _err('插件名称为空');
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final f = store.file('plugins/$safe.json');
      var ok = false;
      if (await f.exists()) {
        await f.delete();
        ok = true;
      }
      return <String, dynamic>{'ok': ok, 'name': name};
    }
    return _err('未知 plugin_lifecycle 动作：$action');
  }

  Future<Map<String, dynamic>> _pluginCommunity(Map<String, dynamic> p) async {
    final action = _action(p, 'catalog');
    // 内置能力目录：随包的内置工具/技能清单。旧实现给每项编了 heat
    // 热度数字冒充市场数据——没有任何统计来源，已全部删除；条目本身
    // 是真实内置能力，但这不是一个「市场」，kind/source 如实标注。
    const List<Map<String, dynamic>> items = <Map<String, dynamic>>[
      <String, dynamic>{
        'name': 'model-download',
        'kind': '技能',
        'source': '内置',
        'description': '模型下载：分片 + 断点续传 + 校验',
      },
      <String, dynamic>{
        'name': 'safe-expression',
        'kind': '工具',
        'source': '内置',
        'description': '受限表达式求值，无 I/O',
      },
      <String, dynamic>{
        'name': 'local-memory',
        'kind': '工具',
        'source': '内置',
        'description': '本地记忆写入与检索',
      },
      <String, dynamic>{
        'name': 'trajectory',
        'kind': '技能',
        'source': '内置',
        'description': '工作轨迹采集与快照导出',
      },
    ];
    if (action == 'catalog' || action == 'list') {
      return <String, dynamic>{'items': items};
    }
    if (action == 'install') {
      final name = (p['name'] ?? '').toString();
      final found = items.where((i) => i['name'] == name).toList();
      if (found.isEmpty) return _err('内置目录里没有插件：$name');
      // 真安装：在 plugins 池落一条本地注册记录（与 plugin_lifecycle
      // install 同一落点）；旧实现什么都不写就报 ok，是假安装成功。
      final f = store.file(
        'plugins/${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json',
      );
      await f.writeAsString(
        jsonEncode(<String, dynamic>{
          'name': name,
          'version': version,
          'installed_at': DateTime.now().toIso8601String(),
          'source': '内置目录',
        }),
        flush: true,
      );
      return _ok(<String, dynamic>{
        'name': name,
        'source': '内置',
        'installed': true,
      });
    }
    // 从本地文件添加插件：content 为用户通过文件选择器读到的 JSON 文本。
    if (action == 'install_local') {
      final name = (p['name'] ?? '').toString().trim();
      final content = (p['content'] ?? '').toString();
      if (name.isEmpty || name.contains('/') || name.contains('..')) {
        return _err('非法插件名称');
      }
      Object? parsed;
      try {
        parsed = jsonDecode(content);
      } on Object {
        return _err('插件文件不是合法 JSON');
      }
      if (parsed is! Map) return _err('插件 JSON 顶层必须是对象');
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      await store
          .file('plugins/$safe.json')
          .writeAsString(
            jsonEncode(<String, dynamic>{
              ...parsed.map((k, v) => MapEntry(k.toString(), v)),
              'name': (parsed['name'] ?? name).toString(),
              'installed_at': DateTime.now().toIso8601String(),
              'source': '本地文件',
            }),
            flush: true,
          );
      return _ok(<String, dynamic>{
        'name': name,
        'source': '本地文件',
        'installed': true,
      });
    }
    // 技能：扫描随包/用户安装的 skills 目录（.md / .json 清单）。
    // 问题 #25：正确解析 YAML frontmatter 取 name/description（旧实现拿
    // 文件首行当描述，带 frontmatter 的文件把「---」直接显示到界面）；
    // 并返回每条的启用状态（停用 = 不进对话技能池，见 _enabledSkillPool）。
    if (action == 'skills_list') {
      final files = <Map<String, dynamic>>[
        ...store.scanFiles('skills', extensions: <String>{'.md', '.json'}),
      ];
      final disabled = await _skillDisabled();
      final skills = <Map<String, dynamic>>[];
      for (final f in files) {
        final fileName = (f['name'] ?? '').toString();
        var name = fileName.split('.').first;
        var desc = '';
        try {
          final txt = await store.file('skills/$fileName').readAsString();
          final parsed = _parseSkillDoc(fileName, txt);
          name = parsed.name;
          desc = parsed.description;
        } on Object {
          desc = '';
        }
        skills.add(<String, dynamic>{
          'name': name,
          'file': fileName,
          'description': desc.isEmpty ? '本地技能文件' : desc,
          'size': f['size'],
          'enabled': !disabled.contains(fileName),
        });
      }
      return _ok(<String, dynamic>{
        'skills': skills,
        'dir': store.sub('skills').path,
      });
    }
    // 启用/停用技能：持久化到 skill_state.json（真实生效——对话只注入
    // 已启用技能，见 _chat → _enabledSkillPool）。name 为技能文件名。
    if (action == 'skill_set_enabled') {
      final fileName = (p['name'] ?? '').toString().trim();
      if (fileName.isEmpty ||
          fileName.contains('/') ||
          fileName.contains('..')) {
        return _err('非法技能名称');
      }
      final enabled = p['enabled'] == true;
      final cfg = await store.readJson('skill_state.json');
      final set = <String>{
        ...(cfg['disabled'] is List
            ? (cfg['disabled'] as List).map((dynamic e) => e.toString())
            : <String>[]),
      };
      if (enabled) {
        set.remove(fileName);
      } else {
        set.add(fileName);
      }
      await store.writeJson('skill_state.json', <String, dynamic>{
        'disabled': set.toList()..sort(),
      });
      return _ok(<String, dynamic>{'name': fileName, 'enabled': enabled});
    }
    // 编辑技能：读取 / 保存技能文件真实文本（⋮ 菜单「编辑」用）。
    if (action == 'skill_read') {
      final fileName = (p['name'] ?? '').toString().trim();
      if (fileName.isEmpty ||
          fileName.contains('/') ||
          fileName.contains('..')) {
        return _err('非法技能名称');
      }
      final f = store.file('skills/$fileName');
      if (!await f.exists()) return _err('技能文件不存在：$fileName');
      return _ok(<String, dynamic>{
        'name': fileName,
        'content': await f.readAsString(),
      });
    }
    if (action == 'skill_save') {
      final fileName = (p['name'] ?? '').toString().trim();
      final content = (p['content'] ?? '').toString();
      if (fileName.isEmpty ||
          fileName.contains('/') ||
          fileName.contains('..')) {
        return _err('非法技能名称');
      }
      if (!fileName.endsWith('.md') && !fileName.endsWith('.json')) {
        return _err('技能文件必须是 .md 或 .json');
      }
      final f = store.file('skills/$fileName');
      if (!await f.parent.exists()) await f.parent.create(recursive: true);
      await f.writeAsString(content, flush: true);
      return _ok(<String, dynamic>{'name': fileName, 'path': f.path});
    }
    // 从本地添加技能：真实写入 skills/ 目录（device_file 根限定 sandbox/，
    // 越界不可达，故在此提供专用动作）。
    if (action == 'skill_add') {
      final name = (p['name'] ?? '').toString().trim();
      final content = (p['content'] ?? '').toString();
      if (name.isEmpty || name.contains('/') || name.contains('..')) {
        return _err('非法技能名称');
      }
      final safe = name.replaceAll(
        RegExp(r'[^A-Za-z0-9._\u4e00-\u9fa5-]'),
        '_',
      );
      final ext = (safe.endsWith('.md') || safe.endsWith('.json')) ? '' : '.md';
      final f = store.file('skills/$safe$ext');
      if (!await f.parent.exists()) await f.parent.create(recursive: true);
      await f.writeAsString(content, flush: true);
      return _ok(<String, dynamic>{
        'name': safe,
        'path': f.path,
        'installed': true,
      });
    }
    if (action == 'skill_remove') {
      final name = (p['name'] ?? '').toString().trim();
      if (name.isEmpty || name.contains('/') || name.contains('..')) {
        return _err('非法技能名称');
      }
      var ok = false;
      for (final ext in <String>['.md', '.json']) {
        final f = store.file('skills/$name$ext');
        if (await f.exists()) {
          await f.delete();
          ok = true;
        }
      }
      if (ok) {
        // 删除后清理停用状态，避免残留脏记录。
        final cfg = await store.readJson('skill_state.json');
        final set =
            (cfg['disabled'] is List
                    ? (cfg['disabled'] as List)
                          .map((dynamic e) => e.toString())
                          .toSet()
                    : <String>{})
                .where((String e) => e != '$name.md' && e != '$name.json')
                .toList()
              ..sort();
        await store.writeJson('skill_state.json', <String, dynamic>{
          'disabled': set,
        });
      }
      return <String, dynamic>{'ok': ok, 'name': name};
    }
    // MCP 服务：真实落盘的 mcp_servers.json 配置。
    if (action == 'mcp_list') {
      final cfg = await store.readJson('mcp_servers.json');
      final servers = (cfg['servers'] is List)
          ? (cfg['servers'] as List).whereType<Map>().toList()
          : <Map>[];
      return _ok(<String, dynamic>{'servers': servers});
    }
    if (action == 'mcp_add' || action == 'mcp_update') {
      final name = (p['name'] ?? '').toString().trim();
      if (name.isEmpty) return _err('MCP 服务名不能为空');
      final cfg = await store.readJson('mcp_servers.json');
      final servers = <Map<String, dynamic>>[
        ...((cfg['servers'] is List)
            ? (cfg['servers'] as List).whereType<Map>().map(
                (e) => Map<String, dynamic>.from(e),
              )
            : <Map<String, dynamic>>[]),
      ];
      final entry = <String, dynamic>{
        'name': name,
        'transport': (p['transport'] ?? 'stdio').toString(),
        'command': (p['command'] ?? '').toString(),
        'args': (p['args'] is List)
            ? (p['args'] as List).map((e) => e.toString()).toList()
            : <String>[],
        'url': (p['url'] ?? '').toString(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      final idx = servers.indexWhere((s) => (s['name'] ?? '') == name);
      if (idx >= 0) {
        servers[idx] = entry;
      } else {
        servers.add(entry);
      }
      await store.writeJson('mcp_servers.json', <String, dynamic>{
        'servers': servers,
      });
      // 保存即真实重连：新服务的工具立刻注册进 AgentLoop。
      return _ok(<String, dynamic>{
        'name': name,
        'count': servers.length,
        'mcp_status': await _mcpSync(),
      });
    }
    if (action == 'mcp_remove') {
      final name = (p['name'] ?? '').toString().trim();
      final cfg = await store.readJson('mcp_servers.json');
      final servers =
          ((cfg['servers'] is List)
                  ? (cfg['servers'] as List).whereType<Map>().map(
                      (e) => Map<String, dynamic>.from(e),
                    )
                  : <Map<String, dynamic>>[])
              .where((s) => (s['name'] ?? '') != name)
              .toList();
      await store.writeJson('mcp_servers.json', <String, dynamic>{
        'servers': servers,
      });
      return _ok(<String, dynamic>{
        'count': servers.length,
        'mcp_status': await _mcpSync(),
      });
    }
    // 手动重连全部 MCP 服务并返回真实状态（供插件社区页展示）。
    if (action == 'mcp_sync') {
      return _ok(await _mcpSync());
    }
    // 问题 #23：真实在线目录（GitHub Search API + 官方注册表）与真实安装。
    if (action == 'discover') return _pluginDiscover(p);
    if (action == 'install_repo') return _installRepoPlugin(p);
    return _err('未知 plugin_community 动作：$action');
  }

  // ---- 插件社区 · 真实在线目录（问题 #23）----

  /// 各标签发现区的 GitHub topic 过滤（curl 实测匿名可达：
  /// topic:mcp-server ≈4.3 万仓库、topic:claude-skills ≈1.6 万、
  /// topic:claude-code-plugin ≈1.5 万；匿名 60 次/小时限流按需搜索够用）。
  static const Map<String, String> _discoverTopics = <String, String>{
    'plugin': 'claude-code-plugin',
    'skill': 'claude-skills',
    'mcp': 'mcp-server',
  };

  Map<String, String> _githubHeaders() => <String, String>{
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'tangram-agent',
    if (UpdateService.githubToken.isNotEmpty)
      'Authorization': 'Bearer ${UpdateService.githubToken}',
  };

  /// 发现区数据源：GitHub 仓库搜索（远端关键词过滤，不是本地过滤）
  /// + 官方注册表（发布通道仓库 raw plugins.json，文件不存在如实跳过）。
  /// GitHub 失败时如实带 error；两路都空才报「暂无结果」。
  Future<Map<String, dynamic>> _pluginDiscover(Map<String, dynamic> p) async {
    final kindRaw = (p['kind'] ?? 'plugin').toString();
    final kind = _discoverTopics.containsKey(kindRaw) ? kindRaw : 'plugin';
    final kw = (p['query'] ?? '').toString().trim();
    final topic = _discoverTopics[kind]!;
    final uri =
        Uri.https('api.github.com', '/search/repositories', <String, String>{
          'q': kw.isEmpty ? 'topic:$topic' : '$kw topic:$topic',
          'sort': 'stars',
          'order': 'desc',
          'per_page': '20',
        });
    final items = <Map<String, dynamic>>[];
    String? searchError;
    try {
      final resp = await http
          .get(uri, headers: _githubHeaders())
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        final list = decoded is Map ? decoded['items'] : null;
        if (list is List) {
          for (final e in list.whereType<Map>()) {
            items.add(<String, dynamic>{
              'name': (e['full_name'] ?? '').toString(),
              'description': (e['description'] ?? '').toString(),
              'stars': e['stargazers_count'] is num
                  ? (e['stargazers_count'] as num).toInt()
                  : 0,
              'updated': (e['pushed_at'] ?? e['updated_at'] ?? '').toString(),
              'url': (e['html_url'] ?? '').toString(),
              'repo': (e['full_name'] ?? '').toString(),
              'branch': (e['default_branch'] ?? 'main').toString(),
              'source': 'GitHub',
              'kind': kind,
            });
          }
        }
      } else if (resp.statusCode == 403) {
        searchError = 'GitHub Search API 限流（匿名 60 次/小时），稍后再试';
      } else {
        searchError = 'GitHub Search API 返回 HTTP ${resp.statusCode}';
      }
    } on Object catch (e) {
      searchError = 'GitHub 搜索请求失败：$e';
    }
    // 官方注册表排在前面（自家发布通道），GitHub 结果随后。
    items.insertAll(0, await _registryPlugins());
    if (items.isEmpty) {
      return _err(searchError ?? '远端目录暂无结果（GitHub 搜索 + 官方注册表均为空）');
    }
    return _ok(<String, dynamic>{
      'items': items,
      'query': kw,
      'source': 'GitHub Search API + 官方注册表',
      if (searchError != null) 'partial_error': searchError,
    });
  }

  /// 官方注册表：读发布通道仓库（与 UpdateService 同一 owner/repo 常量）
  /// 的 raw plugins.json。文件不存在（404）/网络失败一律如实跳过，不编造。
  Future<List<Map<String, dynamic>>> _registryPlugins() async {
    final uri = Uri.parse(
      'https://raw.githubusercontent.com/'
      '${UpdateService.repoOwner}/${UpdateService.repoName}/main/plugins.json',
    );
    try {
      final resp = await http
          .get(
            uri,
            headers: <String, String>{
              if (UpdateService.githubToken.isNotEmpty)
                'Authorization': 'Bearer ${UpdateService.githubToken}',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return <Map<String, dynamic>>[];
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      final list = decoded is List
          ? decoded
          : (decoded is Map && decoded['plugins'] is List
                ? decoded['plugins'] as List
                : null);
      if (list == null) return <Map<String, dynamic>>[];
      return list.whereType<Map>().map((Map<dynamic, dynamic> e) {
        final m = e.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        final repo = (m['repo'] ?? '').toString();
        return <String, dynamic>{
          'name': (m['name'] ?? repo).toString(),
          'description': (m['description'] ?? '').toString(),
          'stars': m['stars'] is num ? (m['stars'] as num).toInt() : 0,
          'updated': (m['updated'] ?? '').toString(),
          'url': (m['url'] ?? (repo.isEmpty ? '' : 'https://github.com/$repo'))
              .toString(),
          'repo': repo,
          'branch': (m['branch'] ?? 'main').toString(),
          'source': '官方注册表',
          'kind': (m['kind'] ?? 'plugin').toString(),
        };
      }).toList();
    } on Object {
      // plugins.json 不存在或不可达：跳过（不冒充有官方条目）。
      return <Map<String, dynamic>>[];
    }
  }

  /// 真实安装：先用 git/trees 递归列出仓库里真实存在的技能/插件文件
  /// （含 skills/*/SKILL.md 子目录），再并发下载落盘。
  /// 技能写 skills/*.md（skills_list 与启用链路可识别），插件清单写
  /// plugins/<safe>.json（与 plugin_lifecycle 同一落点，「已安装」可见可卸载）。
  /// 网络不可达与仓库确无文件分开如实上报，不再把超时误报成 404。
  Future<Map<String, dynamic>> _installRepoPlugin(
    Map<String, dynamic> p,
  ) async {
    final String repo = (p['repo'] ?? '').toString().trim();
    if (!RegExp(r'^[\w.\-]+/[\w.\-]+$').hasMatch(repo)) {
      return _err('非法仓库名：$repo');
    }
    final String branchRaw = (p['branch'] ?? '').toString().trim();
    final String branch = RegExp(r'^[\w.\-]+$').hasMatch(branchRaw)
        ? branchRaw
        : 'main';
    final String name = (p['name'] ?? repo).toString().trim();
    if (name.isEmpty) return _err('插件名称为空');
    final String safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final Map<String, String> auth = <String, String>{
      if (UpdateService.githubToken.isNotEmpty)
        'Authorization': 'Bearer ${UpdateService.githubToken}',
    };

    // 一次列目录即可覆盖子目录技能；列不动时退回根目录常见文件。
    List<String> paths = <String>[];
    try {
      final http.Response tree = await http
          .get(
            Uri.parse(
              'https://api.github.com/repos/$repo/git/trees/$branch?recursive=1',
            ),
            headers: <String, String>{
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'tangram-agent',
              ...auth,
            },
          )
          .timeout(const Duration(seconds: 8));
      if (tree.statusCode == 200) {
        final dynamic decoded = jsonDecode(utf8.decode(tree.bodyBytes));
        final dynamic items = decoded is Map ? decoded['tree'] : null;
        if (items is List) {
          for (final dynamic e in items) {
            if (e is! Map || e['type'] != 'blob') continue;
            final String path = (e['path'] ?? '').toString();
            final String lower = path.toLowerCase();
            if (lower.endsWith('skill.md') ||
                lower.endsWith('plugin.json') ||
                lower == 'readme.md') {
              paths.add(path);
            }
          }
        }
      }
    } on Object {
      // 目录 API 超时/限流：退回根目录候选，不阻塞安装。
    }
    if (paths.isEmpty) {
      paths = <String>['plugin.json', 'SKILL.md', 'skill.md', 'README.md'];
    }
    if (paths.length > 24) paths = paths.sublist(0, 24);

    Future<Map<String, dynamic>> fetch(String path) async {
      try {
        final http.Response r = await http
            .get(
              Uri.parse(
                'https://raw.githubusercontent.com/$repo/$branch/$path',
              ),
              headers: auth,
            )
            .timeout(const Duration(seconds: 8));
        return <String, dynamic>{
          'path': path,
          'status': r.statusCode,
          'body': r.statusCode == 200
              ? utf8.decode(r.bodyBytes, allowMalformed: true)
              : '',
        };
      } on Object {
        return <String, dynamic>{'path': path, 'status': -1, 'body': ''};
      }
    }

    final List<Map<String, dynamic>> fetched = await Future.wait(
      paths.map(fetch),
    );
    final Map<String, String> contents = <String, String>{};
    int netErrors = 0;
    int notFound = 0;
    for (final Map<String, dynamic> f in fetched) {
      final int status = f['status'] as int;
      if (status == 200) {
        contents[f['path'] as String] = f['body'] as String;
      } else if (status == 404) {
        notFound++;
      } else {
        netErrors++;
      }
    }
    if (contents.isEmpty) {
      return _err(
        netErrors > 0 && notFound == 0
            ? '无法连接 raw.githubusercontent.com（$netErrors 个文件超时或网络错误），未安装'
            : '仓库 $repo 未找到 SKILL.md / plugin.json / README.md'
                  '（$notFound 个 404），未安装',
      );
    }

    int skills = 0;
    String firstFile = '';
    Map<String, dynamic> manifest = <String, dynamic>{};
    for (final MapEntry<String, String> e in contents.entries) {
      final String path = e.key;
      final String body = e.value;
      firstFile = firstFile.isEmpty ? path : firstFile;
      if (path.toLowerCase().endsWith('plugin.json')) {
        try {
          final dynamic j = jsonDecode(body);
          if (j is Map) {
            manifest = j.map(
              (dynamic k, dynamic v) => MapEntry(k.toString(), v),
            );
          }
        } on Object {
          manifest = <String, dynamic>{};
        }
        continue;
      }
      // 技能 .md 原样落盘（保留 frontmatter），文件名展平子目录避免重名。
      final String flat = path.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final File target = store.file('skills/${safe}_$flat.md');
      if (!await target.parent.exists()) {
        await target.parent.create(recursive: true);
      }
      await target.writeAsString(body, flush: true);
      skills++;
    }

    final File record = store.file('plugins/$safe.json');
    await record.writeAsString(
      jsonEncode(<String, dynamic>{
        ...manifest,
        'name': name,
        'version': (manifest['version'] ?? '').toString(),
        'source': 'GitHub:$repo/$branch',
        'repo': repo,
        'skills': skills,
        'installed_at': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
    return _ok(<String, dynamic>{
      'name': name,
      'repo': repo,
      'file': skills > 0 ? '$skills 个技能文件' : firstFile,
      'path': record.path,
      'skills': skills,
      'installed': true,
    });
  }

  // ---- 技能 frontmatter 解析 / 启用状态（问题 #25）----

  /// 解析技能文件：.md 取 YAML frontmatter 的 name/description（剥掉
  /// --- 头），无 frontmatter 时回退首个非标题正文行；.json 读清单字段。
  static ({String name, String description}) _parseSkillDoc(
    String fileName,
    String text,
  ) {
    var name = fileName.split('.').first;
    var description = '';
    if (fileName.toLowerCase().endsWith('.json')) {
      try {
        final j = jsonDecode(text);
        if (j is Map) {
          name = (j['name'] ?? name).toString();
          description = (j['description'] ?? '').toString();
        }
      } on Object {
        // 非法 JSON：回退文件名。
      }
      return (name: name, description: description);
    }
    final lines = text.split('\n');
    var i = 0;
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      for (i = 1; i < lines.length; i++) {
        final t = lines[i].trim();
        if (t == '---') {
          i++;
          break;
        }
        // 只认顶层 key（缩进行是嵌套结构，跳过）。
        if (lines[i].startsWith(' ') || lines[i].startsWith('\t')) continue;
        final idx = lines[i].indexOf(':');
        if (idx <= 0) continue;
        final key = lines[i].substring(0, idx).trim();
        var value = lines[i].substring(idx + 1).trim();
        if (value.length >= 2 &&
            ((value.startsWith('"') && value.endsWith('"')) ||
                (value.startsWith("'") && value.endsWith("'")))) {
          value = value.substring(1, value.length - 1);
        }
        if (value.isEmpty) continue;
        if (key == 'name') {
          name = value;
        } else if (key == 'description') {
          description = value;
        }
      }
    }
    if (description.isEmpty) {
      for (; i < lines.length; i++) {
        final t = lines[i].trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        description = t;
        break;
      }
    }
    return (name: name, description: description);
  }

  /// 停用技能文件名集合（skill_state.json 持久化，默认全部启用）。
  Future<Set<String>> _skillDisabled() async {
    final cfg = await store.readJson('skill_state.json');
    return cfg['disabled'] is List
        ? (cfg['disabled'] as List).map((dynamic e) => e.toString()).toSet()
        : <String>{};
  }

  /// 对话技能池：只把「已启用」技能注入 system prompt（问题 #25：
  /// 停用 = 不进对话技能池，真实生效）。无启用技能时返回空串不注入。
  Future<String> _enabledSkillPool() async {
    try {
      final files = store.scanFiles(
        'skills',
        extensions: <String>{'.md', '.json'},
      );
      final disabled = await _skillDisabled();
      final buf = StringBuffer();
      var count = 0;
      for (final f in files) {
        final fileName = (f['name'] ?? '').toString();
        if (fileName.isEmpty || disabled.contains(fileName)) continue;
        String txt;
        try {
          txt = await store.file('skills/$fileName').readAsString();
        } on Object {
          continue;
        }
        final parsed = _parseSkillDoc(fileName, txt);
        final desc = parsed.description.length > 200
            ? '${parsed.description.substring(0, 200)}…'
            : parsed.description;
        buf.writeln('- ${parsed.name}：${desc.isEmpty ? '（无描述）' : desc}');
        if (++count >= 20) break;
      }
      return buf.toString().trimRight();
    } on Object {
      return '';
    }
  }

  // ---- im_event → ImService（真实 AGP/WebSocket 网关，见 im_service.dart）----

  /// IM 消息的真实推理回调：读取当前选中的模型配置（云端 API 或本地 GGUF），
  /// 注入 _chat 走真实推理，把真实回复文本交回网关发回微信/QQ。
  /// 没有任何编造：云端失败就如实返回失败说明，本地权重未加载就如实说明。
  Future<String> _imInfer(String text) async {
    final params = await _selectedChatParams();
    final r = await _chat(<String, dynamic>{
      'text': text,
      'session_id': 'im_gateway',
      ...params,
    });
    final reply = (r['reply'] ?? r['text'] ?? r['error'] ?? '').toString();
    return reply.isEmpty ? '（本次推理未产生回复）' : reply;
  }

  /// 从 model_registry.json 读取「当前选中模型」的真实推理参数。
  /// 与 UI 侧 ModelRegistry.chatParams() 语义保持一致。
  Future<Map<String, dynamic>> _selectedChatParams() async {
    try {
      final cfg = await store.readJson('model_registry.json');
      final selectedId = (cfg['selected_id'] ?? '').toString();
      final cloud = cfg['cloud'];
      if (cloud is List) {
        for (final dynamic m in cloud) {
          if (m is Map && (m['id'] ?? '').toString() == selectedId) {
            return <String, dynamic>{
              'api_base': (m['api_base'] ?? '').toString(),
              'api_key': (m['api_key'] ?? '').toString(),
              'model': (m['model_id'] ?? '').toString(),
              'model_kind': 'cloud',
            };
          }
        }
      }
      // 内置免费云端模型（Kilo 网关 :free 档）不落注册表文件，在代码表里；
      // IM 通道必须同样解析，否则 App 内选了免费模型、微信/QQ 对话会
      // 退化成内置 AgentLoop 兜底回复。
      for (final e in kBuiltinFreeModels) {
        if (e.id == selectedId) {
          return <String, dynamic>{
            'api_base': e.apiBase ?? '',
            'api_key': '',
            'model': e.modelId ?? '',
            'model_kind': 'cloud',
            'free': true,
          };
        }
      }
      // 选中本地权重：扫描 downloads/ 下真实存在的 .gguf 文件。
      if (selectedId.startsWith('local:')) {
        final files = store.scanFiles(
          'downloads',
          extensions: <String>{'.gguf', '.bin'},
        );
        final name = selectedId.substring('local:'.length);
        for (final f in files) {
          if ((f['name'] ?? '').toString() == name) {
            return <String, dynamic>{
              'model_kind': 'local',
              'local_model_path': (f['path'] ?? '').toString(),
            };
          }
        }
      }
    } on Object {
      // 配置读取失败：退回内置 AgentLoop（真实工具/记忆），不编造。
    }
    return <String, dynamic>{'model_kind': 'builtin'};
  }

  // ---- 其余域 ----

  Future<Map<String, dynamic>> _responsibilityTrace() async =>
      _ok(<String, dynamic>{
        'traces': await store.readRecords('work_traces'),
        'file': store.file('work_traces.json').path,
      });

  /// 真实更新源：GET GitHub Releases API releases/latest
  /// （UpdateService.checkLatest，http 包 + 15s 超时，按需调用、不阻塞启动）。
  /// 网络/API 失败如实 ok:false 带 error，绝不假装有更新。
  Future<Map<String, dynamic>> _updateStatus() async {
    final UpdateInfo info = await UpdateService().checkLatest();
    if (info.error != null) {
      return <String, dynamic>{
        'ok': false,
        'current': info.current,
        'latest': info.latest,
        'available': false,
        'apk_url': info.apkUrl,
        'error': info.error,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'current': info.current,
      'latest': info.latest,
      'available': info.available,
      'apk_url': info.apkUrl,
      'size': info.size,
      'notes': info.notes,
    };
  }

  Map<String, dynamic> _dependencyEvent() => <String, dynamic>{
    'ok': true,
    'installed': <String>[
      'dart:core',
      'dart:io',
      'dart:isolate',
      'path_provider',
      'http',
      'flutter_secure_storage',
    ],
    'missing': <String>[],
    'note':
        '纯 Dart 内嵌后端只依赖 Flutter SDK 与随包 pub 依赖；'
        '无 Python、无 CPython、无 Chaquopy。',
  };

  /// 感知采集：真实读取本机状态（时钟/时区/平台/CPU/内存/网卡/磁盘）。
  ///
  /// 旧实现无条件返回「未接入」错误，是 controlDomains 里一个永远不可用的假域。
  /// 现在所有字段都来自 dart:io 的真实读数；屏幕内容、摄像头、传感器、位置、
  /// 无障碍等确实需要系统权限，本应用未申请，如实列出边界，绝不编造数据。
  Future<Map<String, dynamic>> _perceptionEvent() async {
    final DateTime now = DateTime.now();
    final Map<String, dynamic> data = <String, dynamic>{
      'ok': true,
      'source': 'device-local-real',
      'captured_at': now.toIso8601String(),
      'local_time': now.toString(),
      'timezone': now.timeZoneName,
      'utc_offset_minutes': now.timeZoneOffset.inMinutes,
      'platform': Platform.operatingSystem,
      'platform_version': Platform.version,
      'hostname': Platform.localHostname,
      'cpu_count': Platform.numberOfProcessors,
      'locale': Platform.localeName,
      'workspace': store.root.path,
    };
    data['memory_kb'] = await _readMemInfoKb();
    data['workspace_free_kb'] = await _diskFreeKb();
    try {
      final List<NetworkInterface> ifaces = await NetworkInterface.list(
        type: InternetAddressType.any,
        includeLoopback: false,
      );
      data['network_interfaces'] = ifaces
          .map(
            (NetworkInterface i) => <String, dynamic>{
              'name': i.name,
              'addresses': i.addresses
                  .map((dynamic a) => a.address.toString())
                  .toList(),
            },
          )
          .toList();
    } on Object {
      data['network_interfaces'] = <dynamic>[];
      data['network_error'] = '网卡枚举被平台拒绝或未授权，如实留空';
    }
    data['not_collected'] = <String>[
      '屏幕内容',
      '摄像头',
      '麦克风波形',
      '传感器',
      '位置',
      '无障碍',
    ];
    data['note'] =
        '以上均为本机真实读数。屏幕/传感器/位置等需要系统权限，'
        '本应用未申请，未采集的数据一律不编造；需要时请在系统设置授权后接入对应插件。';
    return data;
  }

  /// Linux/Android 读 /proc/meminfo 得到真实物理内存与可用内存（KB）。
  Future<Map<String, dynamic>?> _readMemInfoKb() async {
    if (!Platform.isLinux && !Platform.isAndroid) return null;
    try {
      final List<String> lines = await File('/proc/meminfo').readAsLines();
      int total = 0;
      int available = 0;
      for (final String line in lines) {
        final List<String> parts = line.split(RegExp(r'\s+'));
        if (parts.length < 2) continue;
        final int? value = int.tryParse(parts[1]);
        if (value == null) continue;
        if (parts[0] == 'MemTotal:') total = value;
        if (parts[0] == 'MemAvailable:') available = value;
      }
      if (total <= 0) return null;
      return <String, dynamic>{
        'total_kb': total,
        'available_kb': available,
        'source': '/proc/meminfo',
      };
    } on Object {
      return null;
    }
  }

  /// 用真实 `df -k` 读工作区所在磁盘剩余空间（KB）；不支持/失败返回 null。
  Future<int?> _diskFreeKb() async {
    if (!Platform.isLinux && !Platform.isAndroid && !Platform.isMacOS)
      return null;
    try {
      final ProcessResult r = await Process.run('df', <String>[
        '-k',
        store.root.path,
      ]).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      final List<String> lines = '${r.stdout}'.trim().split('\n');
      if (lines.length < 2) return null;
      final List<String> cols = lines.last.trim().split(RegExp(r'\s+'));
      // Filesystem 1K-blocks Used Available Use% Mounted-on
      if (cols.length < 4) return null;
      return int.tryParse(cols[3]);
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> _reload() => <String, dynamic>{
    'ok': true,
    'reloaded': true,
    'message': '内嵌后端常驻，无需重载；策略与文件在下次请求时重新读取。',
  };

  Map<String, dynamic> _status() => <String, dynamic>{
    'status': 'ok',
    'pid': 0,
    'transport': 'in-process-dart',
    'handlers': controlDomains.map((d) => 'control/$d').toList(),
    'tools': tools.length,
    'debug': kDebugMode,
    'kernel_booted': _kernel?.booted ?? false,
    'kernel_mounted': _kernel?.mountedCount ?? 0,
  };

  Future<void> dispose() async {
    // 先等后台预热/装配收敛：否则 dispose 返回后 fire-and-forget 仍在写盘，
    // 会与调用方清理数据目录产生竞态（目录被重建、删除时目录非空）。
    final Future<void>? boot = _kernelBoot;
    if (boot != null) await boot;
    // 再卸载插件树（可逆撤销工具/接缝注册），关闭热流控制器。
    // 幂等：forTest 场景下 _kernel 可能为 null。
    // 释放 Team Computer 浏览器的 HTTP 连接。
    computer.dispose();
    integrations.dispose();
    await _kernel?.dispose();
    await _hotController.close();
  }
}

/// 托管长驻进程句柄：实现 [QqShellProc]，供 QQ 沙箱直连扫码真实执行 dsh。
class _ManagedProc implements QqShellProc {
  _ManagedProc(this._buf);
  final StringBuffer _buf;
  @override
  bool alive = true;
  @override
  int? exitCode;
  void Function()? killFn;

  @override
  String get output => _buf.toString();
  @override
  Future<void> kill() async {
    killFn?.call();
  }
}
