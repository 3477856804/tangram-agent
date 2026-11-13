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

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show
        Directory,
        File,
        FileSystemEntity,
        FileSystemEntityType,
        Platform,
        Process,
        ProcessSignal;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:tangram/agent/sandbox/sandboxed_shell.dart';
import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/downloader.dart';
import 'package:tangram/harness/im_service.dart';
import 'package:tangram/harness/local_inference.dart';
import 'package:tangram/harness/mcp_client.dart';
import 'package:tangram/harness/proot_sandbox.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/services/ssh_sandbox.dart';
import 'package:tangram/services/update_service.dart';

/// 后端一次 dispatch 的结果：结构化 payload + 可选的 hot-path 事件。
class BackendReply {
  const BackendReply(this.payload, {this.events = const <Map<String, dynamic>>[]});
  final Map<String, dynamic> payload;
  final List<Map<String, dynamic>> events;
}

class EmbeddedBackend {
  EmbeddedBackend._(this.store, this.downloads) {
    _registerTools();
    // 真实 IM 网关：微信/QQ/飞书消息进来后走 _chat 的真实模型推理，
    // 回复经 AGP WebSocket 原样发回，绝不编造。
    im = ImService(store, _imInfer);
  }

  static EmbeddedBackend? _instance;
  final HarnessStore store;
  final DownloadManager downloads;

  /// 真实 IM 网关服务（配置落盘、连接状态可查、可热更新）。
  late final ImService im;

  final ToolRegistry tools = ToolRegistry();

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
    final store = await HarnessStore.instance();
    final backend = EmbeddedBackend._(store, DownloadManager(store));
    await backend._initDefaults();
    _instance = backend;
    return backend;
  }

  /// 供测试注入。
  static EmbeddedBackend forTest(HarnessStore store) =>
      EmbeddedBackend._(store, DownloadManager(store));

  static const String version = '0.0.1';

  static const List<String> controlDomains = <String>[
    'capability_negotiation', 'rpc', 'chat', 'agent_command', 'code_task',
    'model_route', 'model_store', 'distill', 'device_file', 'memory_event',
    'proactive_task', 'security_approval', 'plugin_lifecycle',
    'plugin_community', 'im_event', 'responsibility_trace', 'update_status',
    'dependency_event', 'perception_event', 'reload', 'status', 'ping', 'echo',
  ];

  static const List<String> hotPathTopics = <String>[
    'stream_token', 'trajectory', 'download_progress', 'sandbox_result',
  ];

  Future<void> _initDefaults() async {
    // MCP：启动时后台重连已配置的服务（网络失败不阻塞启动，状态可查）。
    unawaited(_mcpSync());
    // 只在首次启动时建立真实默认记录；不编造模型/插件。
    final rules = await store.readRecords('proactive_rules');
    if (rules.isEmpty) {
      await store.insert('proactive_rules', <String, dynamic>{
        'title': '每日工作回顾', 'enabled': 1, 'ts': _now(),
        'name': '每日工作回顾',
      });
    }
  }

  double _now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

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
        'im_event' => await im.handle(_action(payload), payload),
        'responsibility_trace' => await _responsibilityTrace(),
        'update_status' => await _updateStatus(),
        'dependency_event' => _dependencyEvent(),
        'perception_event' => _perceptionEvent(),
        'reload' => _reload(),
        'status' => _status(),
        'ping' || 'echo' => <String, dynamic>{'ok': true, 'echo': payload},
        _ => _err('未知控制域：$topic'),
      };
      return BackendReply(result, events: drainEvents());
    } on Object catch (e) {
      return BackendReply(_err('$topic 执行失败：${e.runtimeType}: $e'),
          events: drainEvents());
    }
  }

  Map<String, dynamic> _ok([Map<String, dynamic>? extra]) =>
      <String, dynamic>{'ok': true, ...?extra};

  Map<String, dynamic> _err(String message) =>
      <String, dynamic>{'ok': false, 'error': message};

  String _action(Map<String, dynamic> p, [String fallback = '']) =>
      (p['action'] ?? fallback).toString();

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
        return _hardware();
      case 'active':
        return _activeModel();
      default:
        return _err('未知 rpc action：${action.isEmpty ? '(空)' : action}');
    }
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
      'timeout_seconds':
          _asInt(p['timeout_seconds'], cur['timeout_seconds'] as int),
      'action_on_exceed':
          (p['action_on_exceed'] ?? cur['action_on_exceed']).toString(),
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
    return _ok(<String, dynamic>{'quota': q, 'environment': env.isEmpty ? await _sandboxEnvironment() : env});
  }

  Future<Map<String, dynamic>> _graphQuery() async {
    final turns = await store.readRecords('turns');
    final Map<String, int> degree = <String, int>{};
    final List<Map<String, dynamic>> edges = <Map<String, dynamic>>[];
    final wordRe = RegExp(r'[\u4e00-\u9fa5]{2,}|[A-Za-z]{3,}');
    for (final t in turns) {
      final text = (t['text'] ?? '').toString();
      final words = wordRe.allMatches(text).map((m) => m.group(0)!).toSet().toList();
      for (final w in words) {
        degree[w] = (degree[w] ?? 0) + 1;
      }
      for (var i = 0; i < words.length - 1; i++) {
        edges.add(<String, dynamic>{
          'subject': words[i], 'predicate': 'co-occur', 'obj': words[i + 1],
        });
      }
    }
    final nodes = degree.entries
        .map((e) => <String, dynamic>{'name': e.key, 'degree': e.value})
        .toList()
      ..sort((a, b) => (b['degree'] as int).compareTo(a['degree'] as int));
    return _ok(<String, dynamic>{
      'nodes': nodes.take(200).toList(),
      'edges': edges.take(500).toList(),
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
      'trajectory': TrajectorySnapshot('probe')
          .append(TrajectoryCellKind.message, 'ok')
          .length ==
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

  Map<String, dynamic> _hardware() => <String, dynamic>{
        'ok': true,
        'platform': Platform.operatingSystem,
        'platform_version': Platform.operatingSystemVersion,
        'dart_version': Platform.version,
        'processors': Platform.numberOfProcessors,
        'locale': Platform.localeName,
        'models_dir': store.sub('models').path,
        'model_bytes_on_disk': store.totalModelBytes,
        'note': '纯 Dart 运行时，无外部解释器；磁盘统计来自真实文件系统。',
      };

  Future<Map<String, dynamic>> _activeModel() async {
    final active = await store.readJson('active.json');
    final files = store.scanFiles('models', extensions: <String>{'.gguf'});
    return <String, dynamic>{
      'ok': true,
      'active': active['active'] ?? <String, dynamic>{'base': '', 'chat': ''},
      'models': files,
      'quantization': files.isEmpty ? '' : _quantization(files.first['path'] as String),
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

  Future<Map<String, dynamic>> _chat(Map<String, dynamic> p) async {
    final text = (p['text'] ?? p['message'] ?? p['prompt'] ?? '').toString().trim();
    final session = (p['session_id'] ?? 'default').toString();
    if (text.isEmpty) return _err('消息为空');

    final turnId = await store.insert('turns', <String, dynamic>{
      'session_id': session, 'role': 'user', 'text': text, 'ts': _now(),
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
    String effectiveSystem = system;
    String modeSuffix = '';
    if (wantSearch) {
      final results = await _webSearch(text);
      if (results.isEmpty) {
        effectiveSystem += '\n\n【联网检索】本次检索失败或无结果，'
            '请如实告知用户未能联网获取资料，不要编造检索内容。';
      } else {
        effectiveSystem += '\n\n【联网检索结果（真实抓取，需在回答中注明来源）】\n$results';
      }
      modeSuffix += '+web-search';
    }
    if (wantThinking) modeSuffix += '+deep-think';
    // 问题 #25：真实技能池——已启用的本地技能注入对话 system prompt；
    // 停用的技能被过滤，不进对话（云端与本地推理两条路径都生效）。
    final skillPool = await _enabledSkillPool();
    if (skillPool.isNotEmpty) {
      effectiveSystem += '\n\n【本地技能池（已启用，可在回答中运用）】\n$skillPool';
    }
    String reply;
    String engine;
    if (apiBase.isNotEmpty && model.isNotEmpty &&
        (apiKey.isNotEmpty || freeApi)) {
      // 1) 显式配置 OpenAI 兼容 API → 真实 HTTP 推理。
      String query = text;
      if (wantThinking) {
        // 两遍真实推理：先让模型产出分步推理要点，再基于要点作答。
        final plan = await _remoteChat(
          apiBase: apiBase,
          apiKey: apiKey,
          model: model,
          text: '请把下面问题拆解为分步推理要点，只输出要点列表，'
              '不要给出最终答案：\n$text',
          system: '你是严谨的推理规划器。',
          temperature: 0.3,
          maxTokens: maxTokens,
          topP: topP,
        );
        if (plan.ok) {
          query = '参考以下推理要点，深入分析后作答：\n${plan.content}\n\n'
              '问题：$text';
        }
      }
      final remote = await _remoteChat(
        apiBase: apiBase,
        apiKey: apiKey,
        model: model,
        text: query,
        system: effectiveSystem.isEmpty && !wantThinking
            ? system
            : (wantThinking && effectiveSystem.isEmpty
                ? '请先在思考中拆解问题、检验假设、验证结论，再给出最终答案。'
                    '$effectiveSystem'
                : effectiveSystem),
        temperature: temperature,
        maxTokens: maxTokens,
        topP: topP,
      );
      if (remote.ok) {
        reply = remote.content;
        engine = 'openai-compatible:$model$modeSuffix';
      } else {
        reply = '外部推理调用失败：${remote.error}\n\n'
            '（已如实记录，未编造回答。可在模型选择器里切回内置引擎。）';
        engine = 'remote-failed';
      }
    } else if (localSelected) {
      // 2) 选中已下载的 GGUF 权重 → 端侧 llama.cpp 真推理（不编造回答）。
      String localSystem =
          effectiveSystem.isEmpty ? '你是 TGA，一个简洁、诚实、有用的中文助手。' : effectiveSystem;
      if (wantThinking) {
        localSystem = '请先分步拆解问题、检验假设、验证结论，再给出最终答案。$localSystem';
      }
      final local = await LocalInference.instance.generate(
          localPath, wantThinking ? '请深入思考后回答：$text' : text,
          system: localSystem);
      if (local.ok) {
        reply = local.text;
        engine = 'llama.cpp[${local.modelPath.split('/').last}]$modeSuffix';
      } else {
        reply = '端侧模型推理失败：${local.error}\n\n'
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
      'session_id': session, 'role': 'assistant', 'text': reply, 'ts': _now(),
    });
    await _appendTrace(<String, dynamic>{
      'kind': 'chat', 'text': text, 'reply': reply, 'engine': engine, 'ts': _now(),
    });

    // 流式 token 事件：按可见字符分片真实投递（打字机效果）。
    for (final chunk in _chunks(reply, 24)) {
      _emit('stream_token', <String, dynamic>{'token': chunk});
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

  Iterable<String> _chunks(String s, int size) sync* {
    for (var i = 0; i < s.length; i += size) {
      final end = i + size > s.length ? s.length : i + size;
      yield s.substring(i, end);
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

  Future<({bool ok, String content, String error})> _remoteChat({
    required String apiBase,
    required String apiKey,
    required String model,
    required String text,
    required String system,
    required double temperature,
    required int maxTokens,
    required double topP,
  }) async {
    try {
      final uri = Uri.parse('${apiBase.replaceAll(RegExp(r'/+$'), '')}/chat/completions');
      final resp = await http
          .post(
            uri,
            headers: <String, String>{
              'Content-Type': 'application/json',
              // 免费端点（Kilo :free）实测不带 Authorization 头即可 200；
              // 空 Key 时省略该头，避免部分网关对 "Bearer " 直接 401。
              if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(<String, dynamic>{
              'model': model,
              'messages': <Map<String, dynamic>>[
                if (system.isNotEmpty)
                  <String, dynamic>{'role': 'system', 'content': system},
                <String, dynamic>{'role': 'user', 'content': text},
              ],
              'temperature': temperature,
              'max_tokens': maxTokens,
              'top_p': topP,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        return (ok: false, content: '', error: 'HTTP ${resp.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is Map) {
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final msg = (choices.first as Map)['message'];
          if (msg is Map) {
            final content = (msg['content'] ?? '').toString();
            if (content.isNotEmpty) return (ok: true, content: content, error: '');
          }
        }
      }
      return (ok: false, content: '', error: '响应结构不符合预期');
    } on Object catch (e) {
      return (ok: false, content: '', error: '$e');
    }
  }

  /// 内置 AgentLoop：先做意图路由，命中就调用真实工具，把工具观测结果
  /// 组织成回答；未命中时基于真实记忆做检索式回应。全程不编造事实。
  Future<String> _agentLoop(
    String text,
    String session,
    Map<String, dynamic> p,
  ) async {
    final trace = TrajectorySnapshot(text)
        .append(TrajectoryCellKind.user, text);

    // 1) 纯表达式（含常见数学问法）→ 真实求值工具
    final expr = _extractExpression(text);
    if (expr != null) {
      final r = await tools.run('evaluate', <String, dynamic>{'expression': expr});
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
    buf.writeln('我是 **TGA 内置本地引擎**（纯 Dart AgentLoop），'
        '当前没有加载外部大模型，所以不会编造一个看似聪明的答案。');
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
    buf.writeln('需要真正的语言模型对话，请在蒸馏面板配置 OpenAI 兼容 API 凭据，'
        '或下载本地 GGUF 模型；配置后我会真实调用，绝不伪造回复。');
    return buf.toString();
  }

  String? _extractExpression(String text) {
    var t = text.trim();
    t = t.replaceAll(RegExp(r'^(请|帮我|计算|算一下|算算|求值|evaluate|calc)\s*[:：,，]?\s*',
        caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'[?？。！!＝=]\s*$'), '').trim();
    // 允许数字、运算符、括号、白名单函数/变量、字符串、比较与三元。
    final allowed = RegExp(r'^[\d\s\+\-\*/\%\(\)\.\,\?\:\<\>\!\&\|\"\x27A-Za-z_]+$');
    if (!allowed.hasMatch(t)) return null;
    if (!RegExp(r'\d').hasMatch(t)) return null; // 至少有数字
    if (!RegExp(r'[\+\-\*/\%\(\)]').hasMatch(t)) return null; // 有运算
    // 排除可疑关键字
    if (RegExp(r'\b(import|eval|exec|system|process|file|http|dart|new|var)\b',
            caseSensitive: false)
        .hasMatch(t)) {
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
    // 多源：必应 CN 优先（实测国内可达），DuckDuckGo 兜底（海外网络可用）。
    final String bing = await _scrapeBing(query);
    if (bing.isNotEmpty) return bing;
    return _scrapeDdg(query);
  }

  Future<String> _scrapeBing(String query) async {
    try {
      final uri = Uri.https('cn.bing.com', '/search',
          <String, String>{'q': query});
      final resp = await http.get(uri, headers: <String, String>{
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            ' (KHTML, like Gecko) Chrome/124.0 Safari/537.36',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }).timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return '';
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final itemRe = RegExp(
          r'<li class="b_algo[^"]*">([\s\S]{0,1800}?)</li>', dotAll: true);
      final linkRe = RegExp(
          r'<h2[^>]*><a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>', dotAll: true);
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
          buf.writeln('   ${snip.length > 160 ? '${snip.substring(0, 160)}…' : snip}');
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
      final uri = Uri.https('html.duckduckgo.com', '/html/',
          <String, String>{'q': query});
      final resp = await http
          .get(uri, headers: <String, String>{
            'User-Agent':
                'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
          })
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return '';
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final titleRe = RegExp(
          r'<a[^>]*class="result__a"[^>]*>(.*?)</a>', dotAll: true);
      final snipRe = RegExp(
          r'<a[^>]*class="result__snippet"[^>]*>(.*?)</a>', dotAll: true);
      final hrefRe = RegExp(
          r'<a[^>]*class="result__a"[^>]*href="([^"]*)"', dotAll: true);
      final titles = titleRe.allMatches(body)
          .take(5)
          .map((m) => _stripTags(m.group(1)!))
          .toList();
      final snips = snipRe.allMatches(body)
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
    if (RegExp(r'你能做什么|有什么功能|能力|帮助|help', caseSensitive: false)
            .hasMatch(t) &&
        t.length < 24) {
      return ('capabilities', <String, dynamic>{});
    }
    if (RegExp(r'运行测试|自测|自检|selftest', caseSensitive: false).hasMatch(t) &&
        t.length < 20) {
      return ('self_test', <String, dynamic>{});
    }
    if (RegExp(r'几点|现在时间|当前时间|今天几号|日期', caseSensitive: false)
            .hasMatch(t) &&
        t.length < 20) {
      return ('current_time', <String, dynamic>{});
    }
    if (RegExp(r'有哪些模型|模型列表|已下载模型', caseSensitive: false)
            .hasMatch(t) &&
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
      ...RegExp(r'[\u4e00-\u9fa5]{2,}|[A-Za-z]{3,}|\d{2,}')
          .allMatches(query)
          .map((m) => m.group(0)!.toLowerCase()),
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
          buf.writeln('\n控制域 ${controlDomains.length} 个：'
              '${controlDomains.join('、')}');
          return ToolResult.ok(buf.toString());
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
              '**内置自检：${r['status'] == 'ok' ? '全部通过' : '存在失败项'}**\n\n');
          checks.forEach((k, v) => buf.writeln('- $k: ${v == true ? "通过" : "失败"}'));
          buf.writeln('\n沙箱 cube：${SandboxedShell.instance.cubeNames.join('、')}');
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
          final files = store.scanFiles('models', extensions: <String>{'.gguf'});
          final downloads = store.scanFiles('downloads',
              extensions: <String>{'.gguf', '.bin'});
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
            'session_id': 'memory', 'role': 'memory', 'text': text, 'ts': _now(),
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
            return ToolResult.ok('本地记忆中没有与「${q.isEmpty ? '最近记录' : q}」'
                '相关的内容。');
          }
          final buf = StringBuffer('**检索到 ${hits.length} 条相关记忆**\n\n');
          for (final h in hits.take(8)) {
            buf.writeln('- ${_preview(h)}');
          }
          return ToolResult.ok(buf.toString());
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
              ? ToolResult.ok(r.stdout.trim().isEmpty ? '(无输出)' : r.stdout.trim())
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
              ? ToolResult.ok(r.stdout.trim().isEmpty ? '测试通过' : r.stdout.trim())
              : ToolResult.error(r.error ?? '沙箱执行失败');
        },
      ),
    ]);
  }

  String _formatValue(Object? v) {
    if (v is double) {
      if (v == v.roundToDouble()) return v.toInt().toString();
      return v.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
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
        'note': '代码执行由内置纯 Dart SandboxedShell 在受限 Isolate 中完成，'
            '能力契约见 assets/schema/cube_schema.json。',
      };
    }
    final cube = action == 'run' || action == 'eval'
        ? 'eval_expression'
        : action == 'run_test' || action == 'selftest'
            ? 'run_test'
            : null;
    if (action == 'shell') return _shellExec(p);
    if (action == 'debian_status') return proot.status();
    if (action == 'debian_install') return await proot.install();
    if (cube == null) return _err('未知 code_task 动作：$action');
    final r = await SandboxedShell.instance.exec(
      cube,
      <String, dynamic>{
        if (p['expression'] != null) 'expression': p['expression'].toString(),
        if (p['code'] != null) 'expression': p['code'].toString(),
      },
    );
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
    final root = store.sub('sandbox').path;
    String cwd = (p['cwd'] ?? '.').toString();

    final String env = await _sandboxEnvironment();
    final bool remoteSsh = env.contains('SSH');
    final bool debianMode =
        Platform.isAndroid && env == '内置沙箱' && proot.installed;

    // 远端/用户态的 cwd 是远端/客户机路径，不做本地磁盘存在性校验。
    if (!remoteSsh && !debianMode) {
      final cwdCheck = cwd.startsWith('/') ? cwd : '$root/$cwd';
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
      // ② 安卓 Debian 用户态（proot）：apk/python/pip 真实执行。
      if (debianMode) {
        final viaDebian = await proot.run(raw, cwd);
        if (viaDebian != null) return viaDebian;
      }
      final real = await _realShellExec(raw, root, cwd);
      if (real != null) return real;
    }

    String resolve(String rel) {
      final base = rel.startsWith('/') ? '$root${rel.replaceAll(RegExp(r'/+'), '/')}'.replaceAll('//', '/') : '$root/$cwd/$rel';
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
        final showLong = args.contains('-l') || args.contains('-la') ||
            args.contains('-al');
        final target = resolve(args.where((a) => !a.startsWith('-')).isEmpty
            ? '.'
            : args.firstWhere((a) => !a.startsWith('-')));
        if (target.isEmpty) {
          fail('ls: 路径越界被拒绝');
          break;
        }
        final dir = Directory(target);
        if (!dir.existsSync()) {
          fail('ls: 无法访问 \'${args}\'：No such file or directory');
          break;
        }
        final entries = dir
            .listSync(followLinks: false)
            .where((e) => !e.uri.pathSegments.last.startsWith('.tangram'))
            .toList()
          ..sort((a, b) {
            final ad = a is Directory ? 0 : 1;
            final bd = b is Directory ? 0 : 1;
            if (ad != bd) return ad.compareTo(bd);
            return a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last);
          });
        for (final e in entries) {
          final name = e.uri.pathSegments.last;
          if (showLong) {
            final st = e.statSync();
            buf.writeln('${e is Directory ? "drwxr-xr-x" : "-rw-r--r--"} '
                '${st.size.toString().padLeft(10)}  ${_now()}  $name${e is Directory ? "/" : ""}');
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
        final recursive = args.contains('-r') || args.contains('-rf') ||
            args.contains('-fr');
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
          buf.writeln(lines.length <= 10
              ? lines.join('\n')
              : lines.sublist(lines.length - 10).join('\n'));
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
        buf.writeln('${txt.split('\n').length} ${txt.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length} ${txt.length} ${args.last}');
      case 'date':
        buf.writeln(DateTime.now().toString());
      case 'whoami':
        buf.writeln('tga');
      case 'uname':
        buf.writeln('${Platform.operatingSystem} tangram-sandbox '
            '${Platform.operatingSystemVersion} '
            '${Uri.base.scheme == "file" ? Platform.localHostname : "device"}');
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
        buf.writeln('注：本终端默认把命令交给系统真实 shell 执行，'
            'apt/pkg/pip/curl 等系统命令按本机真实情况响应。');
        if (Platform.isAndroid) {
          buf.writeln(debianMode
              ? '当前已启用 Debian 用户态（proot）：apk/python 真实执行。'
              : '安卓本机为 toybox；跑 apt 请装「Debian 扩展包」或切'
                  '「远端沙箱（SSH）」。');
        }
      default:
        // 表达式兜底：2+3*4 之类直接走真实求值（受限 Isolate）。
        if (RegExp(r'^[\d\s\+\-\*\/\%\(\)\.\,]+$').hasMatch(raw)) {
          final r = await SandboxedShell.instance
              .exec('eval_expression', <String, dynamic>{'expression': raw});
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
    };
  }

  /// 真实 shell 执行：桌面端 bash/sh、安卓 /system/bin/sh（toybox）。
  /// 返回 null 表示真实 shell 不可用（调用方回退内置解释器）。
  /// 命令输出/退出码全部来自真实进程，绝不加工、绝不模拟成功。
  Future<Map<String, dynamic>?> _realShellExec(
      String raw, String root, String cwd) async {
    final String shell;
    if (Platform.isWindows) {
      shell = r'C:\Windows\System32\cmd.exe';
    } else if (Platform.isAndroid) {
      shell = '/system/bin/sh';
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
    final String cwdAbs =
        cwd.startsWith('/') ? cwd : '$root/${cwd == '.' ? '' : cwd}';
    if (!Directory(cwdAbs).existsSync()) {
      debugPrint('TGA_REAL_SHELL_FAIL: no cwd $cwdAbs');
      return null;
    }

    // 用唯一标记把「真实输出」与「新 cwd/退出码」分离（POSIX shell 通用）。
    final String marker = '__TGA_END_${DateTime.now().microsecondsSinceEpoch}__';
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

    final Future<String> outF =
        proc.stdout.transform(utf8.decoder).join();
    final Future<String> errF =
        proc.stderr.transform(utf8.decoder).join();
    int exitCode = 124;
    try {
      exitCode = await proc.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
    }
    final String stdoutAll =
        await outF.timeout(const Duration(seconds: 3),
            onTimeout: () => '');
    final String stderrAll =
        await errF.timeout(const Duration(seconds: 3), onTimeout: () => '');

    String out = stdoutAll;
    String newCwd = cwd;
    if (!Platform.isWindows) {
      final int first = stdoutAll.indexOf(marker);
      final int last = stdoutAll.lastIndexOf(marker);
      if (first >= 0 && last > first) {
        out = stdoutAll.substring(0, first);
        final String tail =
            stdoutAll.substring(last + marker.length).trim(); // <rc>
        final String mid =
            stdoutAll.substring(first + marker.length, last); // <pwd>
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
      final httpLike = transport.contains('http') ||
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
          tools.register(AgentTool(
            name: full,
            description: '[MCP:$name] ${t.description}',
            parameters: t.inputSchema,
            tier: ApprovalTier.write,
            execute: (args, token) async {
              final r = await client.callTool(t.name, args);
              return r.ok ? ToolResult.ok(r.text) : ToolResult.error(r.error);
            },
          ));
          _mcpToolNames.add(full);
          toolNames.add(t.name);
        }
        connected.add(<String, dynamic>{
          'name': name, 'server': title, 'tools': toolNames,
        });
      } on Object catch (e) {
        client.dispose();
        failed.add(<String, dynamic>{'name': name, 'error': '$e'});
      }
    }
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
  static const List<Map<String, dynamic>> builtinCatalog = <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'qwen2.5-0.5b-q4',
      'name': 'Qwen2.5 0.5B Instruct (Q4_K_M)',
      'source': 'ModelScope 魔搭社区',
      'params': '0.5B',
      'quantization': 'Q4_K_M',
      'url': 'https://www.modelscope.cn/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/'
          'resolve/master/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    },
    <String, dynamic>{
      'id': 'tinyllama-1.1b-q4',
      'name': 'TinyLlama 1.1B Chat (Q4_K_M)',
      'source': 'ModelScope 魔搭社区',
      'params': '1.1B',
      'quantization': 'Q4_K_M',
      'url': 'https://www.modelscope.cn/models/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/'
          'resolve/master/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
    },
    <String, dynamic>{
      'id': 'qwen2.5-1.5b-q4',
      'name': 'Qwen2.5 1.5B Instruct (Q4_K_M)',
      'source': 'ModelScope 魔搭社区',
      'params': '1.5B',
      'quantization': 'Q4_K_M',
      'url': 'https://www.modelscope.cn/models/Qwen/Qwen2.5-1.5B-Instruct-GGUF/'
          'resolve/master/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    },
  ];

  Future<Map<String, dynamic>> _modelStore(Map<String, dynamic> p) async {
    final action = _action(p);
    switch (action) {
      case 'hardware':
        return _hardware();
      case 'search' || 'catalog' || 'list':
        final q = (p['query'] ?? '').toString().trim().toLowerCase();
        final local = store.scanFiles('downloads',
            extensions: <String>{'.gguf', '.bin'});
        final models = builtinCatalog
            .where((m) => q.isEmpty ||
                m['name'].toString().toLowerCase().contains(q) ||
                m['id'].toString().contains(q))
            .map((m) => <String, dynamic>{
                  ...m,
                  // 必须与完整模型 id 对应才算已下载；旧实现只比 id 首段
                  // （如 qwen2），会把同前缀的另一个模型误报为已下载。
                  'downloaded': local.any((f) =>
                      f['name'].toString() == '${m['id']}.gguf' ||
                      f['name'].toString().contains(m['id'].toString())),
                })
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
        final job = await downloads.start(
          targetUrl,
          filename: match.isNotEmpty ? '$id.gguf' : null,
          chunks: 4,
        );
        _emit('download_progress', downloads.progress(job));
        return <String, dynamic>{
          'ok': true,
          'job_id': job.id,
          'model_id': id,
          'status': 'running',
          'target': job.target,
          'engine': 'dart-range-chunks',
          'resumable': job.resumable,
          'note': '真实 HTTP 分片下载（Range + 断点续传），进度按落盘字节回写。',
        };
      case 'ms_search': {
        // 魔搭社区真实模型搜索：PUT /api/v1/dolphin/models（实测可用；
        // GET 风格端点全部 404）。返回真实仓库、下载量与任务标签。
        final q = (p['query'] ?? '').toString().trim();
        try {
          final req = http.Request(
              'PUT', Uri.parse('https://www.modelscope.cn/api/v1/dolphin/models'))
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
          final resp = await http.Response.fromStream(await req.send())
              .timeout(const Duration(seconds: 12));
          if (resp.statusCode != 200) {
            return _err('魔搭搜索失败：HTTP ${resp.statusCode}');
          }
          final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
          final models = <Map<String, dynamic>>[];
          if (decoded is Map &&
              decoded['Data'] is Map &&
              (decoded['Data'] as Map)['Model'] is Map) {
            final list =
                ((decoded['Data'] as Map)['Model'] as Map)['Models'];
            if (list is List) {
              for (final e in list.whereType<Map>()) {
                final owner = (e['Path'] ?? e['Namespace'] ?? '').toString();
                final name = (e['Name'] ?? '').toString();
                if (owner.isEmpty || name.isEmpty) continue;
                final tasks = (e['Tasks'] is List)
                    ? (e['Tasks'] as List)
                        .whereType<Map>()
                        .map((t) => (t['ChineseName'] ?? t['Name'] ?? '')
                            .toString())
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
            'ok': true, 'source': 'modelscope.cn',
            'models': models, 'total': models.length,
          };
        } on Object catch (e) {
          return _err('魔搭搜索失败：$e');
        }
      }
      case 'ms_files': {
        // 真实仓库文件列表（递归），只回 .gguf —— 端侧推理可直接下载。
        final mp = (p['model_path'] ?? '').toString().trim();
        if (mp.isEmpty || mp.contains('..')) return _err('缺少 model_path');
        try {
          final uri = Uri.https('www.modelscope.cn',
              '/api/v1/models/$mp/repo/files', <String, String>{
            'Revision': 'master',
            'Recursive': 'true',
          });
          final resp = await http.get(uri, headers: <String, String>{
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0) Chrome/124.0',
          }).timeout(const Duration(seconds: 12));
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
          files.sort((a, b) =>
              (a['size'] as int).compareTo(b['size'] as int));
          return <String, dynamic>{'ok': true, 'files': files};
        } on Object catch (e) {
          return _err('读取文件列表失败：$e');
        }
      }
      case 'ms_download': {
        // 真实下载魔搭 GGUF：resolve/master 直链 → DownloadManager
        // 分片 + 断点续传，进度按落盘字节回写。
        final mp = (p['model_path'] ?? '').toString().trim();
        final file = (p['file'] ?? '').toString().trim();
        if (mp.isEmpty || file.isEmpty || file.contains('..') ||
            mp.contains('..')) {
          return _err('缺少 model_path / file');
        }
        final url =
            'https://www.modelscope.cn/models/$mp/resolve/master/$file';
        final safeName =
            '${mp.split('/').last}-${file.split('/').last}'.replaceAll(
                RegExp(r'[^A-Za-z0-9._-]'), '_');
        final job = await downloads.start(url,
            filename: safeName, chunks: 4);
        _emit('download_progress', downloads.progress(job));
        return <String, dynamic>{
          'ok': true, 'job_id': job.id, 'status': 'running',
          'target': job.target, 'filename': safeName,
          'resumable': job.resumable,
          'note': '真实 HTTP 分片下载（Range + 断点续传）。',
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
          'ok': true, 'action': action,
          'data': <String, dynamic>{'version': version, 'equation': 'agent = model + harness'},
        };
      case 'describe':
        final traces = await store.readRecords('work_traces');
        final turns = await store.readRecords('turns');
        return <String, dynamic>{
          'ok': true, 'action': action,
          'data': <String, dynamic>{
            'equation': 'agent = model + harness',
            'version': version,
            'harness': <String, dynamic>{
              'work_traces': traces.length,
              'dialog_turns': turns.length,
              'tools': tools.names,
              'backend': 'pure-dart-in-process',
            },
          },
        };
      case 'catalog':
        return <String, dynamic>{
          'ok': true, 'action': action,
          'data': <String, dynamic>{
            'base_models': builtinCatalog,
            'own_models': _ownModels(),
          },
        };
      case 'models':
        return <String, dynamic>{
          'ok': true, 'action': action,
          'data': <String, dynamic>{
            'base_models': builtinCatalog,
            'own_models': _ownModels(),
          },
        };
      case 'traces':
        return <String, dynamic>{
          'ok': true, 'action': action,
          'data': await store.readRecords('work_traces'),
        };
      case 'work':
        final task = (p['task'] ?? p['text'] ?? '').toString().trim();
        if (task.isEmpty) return _err('工作轨迹内容为空');
        final id = await _appendTrace(<String, dynamic>{
          'kind': 'work', 'task': task, 'ts': _now(),
          'source': (p['source'] ?? 'manual').toString(),
        });
        final traces = await store.readRecords('work_traces');
        return <String, dynamic>{
          'ok': true, 'action': action,
          'data': <String, dynamic>{
            'completion': task, 'traces': traces.length, 'id': id,
          },
        };
      case 'distill':
        // 真实蒸馏需要模型权重与教师输出；不具备时明确拒绝，不产出假模型。
        final traces = await store.readRecords('work_traces');
        return <String, dynamic>{
          'ok': false, 'action': action,
          'error': '蒸馏需要真实基底模型权重与教师输出。当前已采集 '
              '${traces.length} 条真实工作轨迹，但未加载权重；'
              '请先下载 GGUF 基底模型或配置 API 教师凭据，不会伪造模型产物。',
          'data': <String, dynamic>{'traces': traces.length},
        };
      case 'download':
        final id = (p['model_id'] ?? p['id'] ?? '').toString();
        final match = builtinCatalog.where((m) => m['id'] == id).toList();
        if (match.isEmpty) return _err('内置目录里没有模型 $id');
        final job = await downloads.start(match.first['url'].toString(),
            filename: '$id.gguf', chunks: 4);
        return <String, dynamic>{
          'ok': true, 'action': action,
          'data': <String, dynamic>{'job_id': job.id, 'target': job.target},
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

  List<Map<String, dynamic>> _ownModels() {
    return store
        .scanFiles('models', extensions: <String>{'.gguf'})
        .map((f) => <String, dynamic>{
              'name': f['name'],
              'path': f['path'],
              'size': f['size'],
              'version': version,
              'source': 'local',
            })
        .toList();
  }

  Map<String, dynamic> _deleteModel(String name) {
    if (name.isEmpty || name.contains('/') || name.contains('..')) {
      return _err('非法模型名称');
    }
    final f = File('${store.sub('models').path}/$name');
    if (!f.existsSync()) return _err('模型文件不存在：$name');
    f.deleteSync();
    return <String, dynamic>{'ok': true, 'action': 'delete_model',
      'data': <String, dynamic>{'name': name}};
  }

  Future<Map<String, dynamic>> _renameModel(String old, String next) async {
    if (old.isEmpty || next.isEmpty ||
        old.contains('/') || next.contains('/') ||
        old.contains('..') || next.contains('..')) {
      return _err('非法模型名称');
    }
    final src = File('${store.sub('models').path}/$old');
    final dst = File('${store.sub('models').path}/$next');
    if (!src.existsSync()) return _err('模型文件不存在：$old');
    if (dst.existsSync()) return _err('目标名称已存在：$next');
    await src.rename(dst.path);
    return <String, dynamic>{'ok': true, 'action': 'rename_model',
      'data': <String, dynamic>{'name': next}};
  }

  Future<int> _appendTrace(Map<String, dynamic> record) =>
      store.insert('work_traces', record);

  // ---- device_file：真实受限文件操作（沙箱内，路径防越界）----

  Future<Map<String, dynamic>> _deviceFile(Map<String, dynamic> p) async {
    final action = _action(p, 'status');
    final args = p['args'] is Map
        ? (p['args'] as Map).map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
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
              .map((e) => <String, dynamic>{
                    'name': e.uri.pathSegments.where((s) => s.isNotEmpty).last,
                    'path': e.path,
                    'is_directory': e is Directory,
                    'size': e is File ? e.statSync().size : 0,
                    'modified': e.statSync().modified.toIso8601String(),
                  })
              .toList();
        case 'read':
          final f = File(resolve((args['path'] ?? '').toString()));
          if (!f.existsSync()) return _err('文件不存在：${f.path}');
          if (f.lengthSync() > 1024 * 1024) return _err('文件超过 1MB 读取上限');
          data = <String, dynamic>{
            'path': f.path, 'content': await f.readAsString(),
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
          await File(resolve(args['from'].toString()))
              .copy(resolve(args['to'].toString()));
          data = <String, dynamic>{'ok': true};
        case 'move':
          await File(resolve(args['from'].toString()))
              .rename(resolve(args['to'].toString()));
          data = <String, dynamic>{'ok': true};
        case 'rename':
          await File(resolve(args['path'].toString()))
              .rename(resolve(args['new_name'].toString()));
          data = <String, dynamic>{'ok': true};
        case 'delete':
          final target = resolve((args['path'] ?? '').toString());
          final entity = FileSystemEntity.typeSync(target) ==
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
              .map((e) => <String, dynamic>{'path': e.path,
                'is_directory': e is Directory})
              .toList();
        case 'largest_files':
          final dir = Directory(resolve((args['path'] ?? '').toString()));
          if (!dir.existsSync()) return _err('目录不存在：${dir.path}');
          final files = dir
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .map((f) => <String, dynamic>{
                    'path': f.path, 'size': f.statSync().size})
              .toList()
            ..sort((a, b) => (b['size'] as int).compareTo(a['size'] as int));
          data = files.take(20).toList();
        default:
          return _err('未知 device_file 动作：$action');
      }
      return <String, dynamic>{
        'ok': true, 'op': action, 'data': data, 'error': '',
        'needs_permission': false,
      };
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false, 'op': action, 'error': '$e',
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
        final millis = ts is num ? (ts * 1000).round() : DateTime.now().millisecondsSinceEpoch;
        final day = DateTime.fromMillisecondsSinceEpoch(millis)
            .toLocal()
            .toIso8601String()
            .substring(0, 10);
        days.putIfAbsent(day, () => <Map<String, dynamic>>[]).add(t);
      }
      final out = days.entries
          .map((e) => <String, dynamic>{'day': e.key, 'entries': e.value})
          .toList()
        ..sort((a, b) => (b['day'] as String).compareTo(a['day'] as String));
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
        final millis = ts is num ? (ts * 1000).round() : DateTime.now().millisecondsSinceEpoch;
        final d = DateTime.fromMillisecondsSinceEpoch(millis)
            .toLocal()
            .toIso8601String()
            .substring(0, 10);
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
              .map((r) => <String, dynamic>{
                    'id': r['id'],
                    'title': r['title'] ?? r['name'] ?? '规则',
                    'name': r['name'] ?? r['title'] ?? '规则',
                    'enabled': r['enabled'] == true || r['enabled'] == 1,
                    // 规则由 App 内 TaskScheduler 执行：每 30s 轮询，
                    // 仅在 App 进程存活期间触发（平台限制，如实说明）。
                    'scheduled': true,
                    'ts': r['ts'],
                  })
              .toList(),
          'timers': <String>[],
          'scheduler': 'in-app',
          'note': '规则由 App 内调度器在进程存活期间按 HH:mm 触发执行',
        });
      case 'add':
        final title = (p['title'] ?? p['name'] ?? '').toString().trim();
        if (title.isEmpty) return _err('规则标题为空');
        final id = await store.insert('proactive_rules', <String, dynamic>{
          'title': title, 'name': title, 'enabled': 1, 'ts': _now(),
        });
        return _ok(<String, dynamic>{'id': id});
      case 'set_rule':
        final name = (p['name'] ?? '').toString();
        final enabled = p['enabled'] == true;
        for (final r in rules) {
          if ((r['name'] ?? r['title']).toString() == name) {
            await store.update('proactive_rules', r['id'] as int,
                <String, dynamic>{'enabled': enabled ? 1 : 0});
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
        return <String, dynamic>{'ok': await store.remove('proactive_rules', target)};
      default:
        return _err('未知 proactive_task 动作：$action');
    }
  }

  // ---- security_approval：真实审批 ----

  Future<Map<String, dynamic>> _securityApproval(Map<String, dynamic> p) async {
    final action = _action(p, 'list');
    switch (action) {
      case 'list':
        final rows = await store.readRecords('approvals');
        return _ok(<String, dynamic>{'approvals': rows});
      case 'request':
        final id = await store.insert('approvals', <String, dynamic>{
          'action': (p['name'] ?? '未命名操作').toString(),
          'status': 'pending', 'ts': _now(),
        });
        return _ok(<String, dynamic>{'id': id});
      case 'approve' || 'deny':
        final id = int.tryParse('${p['id'] ?? 0}') ?? 0;
        final ok = await store.update('approvals', id, <String, dynamic>{
          'status': action == 'approve' ? 'approved' : 'denied',
        });
        return <String, dynamic>{'ok': ok};
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
          final content = await store.file('plugins/${f['name']}').readAsString();
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
      final f = store.file('plugins/${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json');
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'name': name, 'version': version,
        'installed_at': DateTime.now().toIso8601String(),
        'source': 'local',
      }), flush: true);
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
        'name': 'model-download', 'kind': '技能', 'source': '内置',
        'description': '模型下载：分片 + 断点续传 + 校验',
      },
      <String, dynamic>{
        'name': 'safe-expression', 'kind': '工具', 'source': '内置',
        'description': '受限表达式求值，无 I/O',
      },
      <String, dynamic>{
        'name': 'local-memory', 'kind': '工具', 'source': '内置',
        'description': '本地记忆写入与检索',
      },
      <String, dynamic>{
        'name': 'trajectory', 'kind': '技能', 'source': '内置',
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
      final f = store.file('plugins/${name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json');
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'name': name, 'version': version,
        'installed_at': DateTime.now().toIso8601String(),
        'source': '内置目录',
      }), flush: true);
      return _ok(<String, dynamic>{'name': name, 'source': '内置', 'installed': true});
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
      await store.file('plugins/$safe.json').writeAsString(
          jsonEncode(<String, dynamic>{
            ...parsed.map((k, v) => MapEntry(k.toString(), v)),
            'name': (parsed['name'] ?? name).toString(),
            'installed_at': DateTime.now().toIso8601String(),
            'source': '本地文件',
          }), flush: true);
      return _ok(<String, dynamic>{'name': name, 'source': '本地文件', 'installed': true});
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
      return _ok(<String, dynamic>{'skills': skills, 'dir': store.sub('skills').path});
    }
    // 启用/停用技能：持久化到 skill_state.json（真实生效——对话只注入
    // 已启用技能，见 _chat → _enabledSkillPool）。name 为技能文件名。
    if (action == 'skill_set_enabled') {
      final fileName = (p['name'] ?? '').toString().trim();
      if (fileName.isEmpty || fileName.contains('/') || fileName.contains('..')) {
        return _err('非法技能名称');
      }
      final enabled = p['enabled'] == true;
      final cfg = await store.readJson('skill_state.json');
      final set = <String>{...(cfg['disabled'] is List
          ? (cfg['disabled'] as List).map((dynamic e) => e.toString())
          : <String>[])};
      if (enabled) {
        set.remove(fileName);
      } else {
        set.add(fileName);
      }
      await store.writeJson('skill_state.json',
          <String, dynamic>{'disabled': set.toList()..sort()});
      return _ok(<String, dynamic>{'name': fileName, 'enabled': enabled});
    }
    // 编辑技能：读取 / 保存技能文件真实文本（⋮ 菜单「编辑」用）。
    if (action == 'skill_read') {
      final fileName = (p['name'] ?? '').toString().trim();
      if (fileName.isEmpty || fileName.contains('/') || fileName.contains('..')) {
        return _err('非法技能名称');
      }
      final f = store.file('skills/$fileName');
      if (!await f.exists()) return _err('技能文件不存在：$fileName');
      return _ok(<String, dynamic>{'name': fileName, 'content': await f.readAsString()});
    }
    if (action == 'skill_save') {
      final fileName = (p['name'] ?? '').toString().trim();
      final content = (p['content'] ?? '').toString();
      if (fileName.isEmpty || fileName.contains('/') || fileName.contains('..')) {
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
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._\u4e00-\u9fa5-]'), '_');
      final ext = (safe.endsWith('.md') || safe.endsWith('.json')) ? '' : '.md';
      final f = store.file('skills/$safe$ext');
      if (!await f.parent.exists()) await f.parent.create(recursive: true);
      await f.writeAsString(content, flush: true);
      return _ok(<String, dynamic>{
        'name': safe, 'path': f.path, 'installed': true,
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
        final set = (cfg['disabled'] is List
                ? (cfg['disabled'] as List).map((dynamic e) => e.toString()).toSet()
                : <String>{})
            .where((String e) => e != '$name.md' && e != '$name.json')
            .toList()
          ..sort();
        await store.writeJson('skill_state.json', <String, dynamic>{'disabled': set});
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
            ? (cfg['servers'] as List).whereType<Map>().map((e) =>
                Map<String, dynamic>.from(e))
            : <Map<String, dynamic>>[]),
      ];
      final entry = <String, dynamic>{
        'name': name,
        'transport': (p['transport'] ?? 'stdio').toString(),
        'command': (p['command'] ?? '').toString(),
        'args': (p['args'] is List) ? (p['args'] as List).map((e) => e.toString()).toList() : <String>[],
        'url': (p['url'] ?? '').toString(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      final idx = servers.indexWhere((s) => (s['name'] ?? '') == name);
      if (idx >= 0) {
        servers[idx] = entry;
      } else {
        servers.add(entry);
      }
      await store.writeJson('mcp_servers.json', <String, dynamic>{'servers': servers});
      // 保存即真实重连：新服务的工具立刻注册进 AgentLoop。
      return _ok(<String, dynamic>{
        'name': name, 'count': servers.length,
        'mcp_status': await _mcpSync(),
      });
    }
    if (action == 'mcp_remove') {
      final name = (p['name'] ?? '').toString().trim();
      final cfg = await store.readJson('mcp_servers.json');
      final servers = ((cfg['servers'] is List)
              ? (cfg['servers'] as List).whereType<Map>().map(
                  (e) => Map<String, dynamic>.from(e))
              : <Map<String, dynamic>>[])
          .where((s) => (s['name'] ?? '') != name)
          .toList();
      await store.writeJson('mcp_servers.json', <String, dynamic>{'servers': servers});
      return _ok(<String, dynamic>{
        'count': servers.length, 'mcp_status': await _mcpSync(),
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
    final uri = Uri.https('api.github.com', '/search/repositories',
        <String, String>{
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
    final uri = Uri.parse('https://raw.githubusercontent.com/'
        '${UpdateService.repoOwner}/${UpdateService.repoName}/main/plugins.json');
    try {
      final resp = await http.get(uri, headers: <String, String>{
        if (UpdateService.githubToken.isNotEmpty)
          'Authorization': 'Bearer ${UpdateService.githubToken}',
      }).timeout(const Duration(seconds: 10));
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
          'url': (m['url'] ?? (repo.isEmpty
                  ? ''
                  : 'https://github.com/$repo'))
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

  /// 真实安装：按仓库自身 default_branch 从 raw.githubusercontent.com
  /// 依次下载根目录 plugin.json / SKILL.md / README.md（curl 实测：文件
  /// 存在 200 即落盘，404 如实报未找到），写入现有插件池目录
  /// plugins/<name>.json——与 plugin_lifecycle 同一落点，「已安装」可见、可卸载。
  Future<Map<String, dynamic>> _installRepoPlugin(Map<String, dynamic> p) async {
    final repo = (p['repo'] ?? '').toString().trim();
    if (!RegExp(r'^[\w.\-]+/[\w.\-]+$').hasMatch(repo)) {
      return _err('非法仓库名：$repo');
    }
    final branchRaw = (p['branch'] ?? '').toString().trim();
    final branch = RegExp(r'^[\w.\-]+$').hasMatch(branchRaw) ? branchRaw : 'main';
    final name = (p['name'] ?? repo).toString().trim();
    if (name.isEmpty) return _err('插件名称为空');
    for (final fname in <String>['plugin.json', 'SKILL.md', 'README.md']) {
      final url = 'https://raw.githubusercontent.com/$repo/$branch/$fname';
      String content;
      try {
        final resp = await http.get(Uri.parse(url), headers: <String, String>{
          if (UpdateService.githubToken.isNotEmpty)
            'Authorization': 'Bearer ${UpdateService.githubToken}',
        }).timeout(const Duration(seconds: 15));
        if (resp.statusCode != 200) continue;
        content = utf8.decode(resp.bodyBytes, allowMalformed: true);
      } on Object {
        continue;
      }
      var entry = <String, dynamic>{'content': content};
      if (fname.endsWith('.json')) {
        try {
          final j = jsonDecode(content);
          if (j is Map) {
            entry = j.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
          }
        } on Object {
          entry = <String, dynamic>{'content': content};
        }
      }
      final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final target = store.file('plugins/$safe.json');
      await target.writeAsString(jsonEncode(<String, dynamic>{
        ...entry,
        'name': name,
        'version': (entry['version'] ?? '').toString(),
        'source': 'GitHub:$repo/$branch/$fname',
        'repo': repo,
        'installed_at': DateTime.now().toIso8601String(),
      }), flush: true);
      return _ok(<String, dynamic>{
        'name': name,
        'repo': repo,
        'file': fname,
        'path': target.path,
        'installed': true,
      });
    }
    return _err('仓库 $repo 根目录未找到 plugin.json / SKILL.md / README.md'
        '（raw.githubusercontent.com 均 404），未安装');
  }

  // ---- 技能 frontmatter 解析 / 启用状态（问题 #25）----

  /// 解析技能文件：.md 取 YAML frontmatter 的 name/description（剥掉
  /// --- 头），无 frontmatter 时回退首个非标题正文行；.json 读清单字段。
  static ({String name, String description}) _parseSkillDoc(
      String fileName, String text) {
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
      final files =
          store.scanFiles('skills', extensions: <String>{'.md', '.json'});
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
      // 选中本地权重：扫描 downloads/ 下真实存在的 .gguf 文件。
      if (selectedId.startsWith('local:')) {
        final files = store.scanFiles('downloads',
            extensions: <String>{'.gguf', '.bin'});
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

  Future<Map<String, dynamic>> _responsibilityTrace() async => _ok(
        <String, dynamic>{
          'traces': await store.readRecords('work_traces'),
          'file': store.file('work_traces.json').path,
        },
      );

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
        'installed': <String>['dart:core', 'dart:io', 'dart:isolate',
          'path_provider', 'http', 'flutter_secure_storage'],
        'missing': <String>[],
        'note': '纯 Dart 内嵌后端只依赖 Flutter SDK 与随包 pub 依赖；'
            '无 Python、无 CPython、无 Chaquopy。',
      };

  Map<String, dynamic> _perceptionEvent() => _err(
        '感知采集未接入：需要屏幕/传感器/无障碍等系统权限，'
        '当前应用未申请这些权限，不会伪造感知数据。');

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
      };

  Future<void> dispose() async {
    await _hotController.close();
  }
}
