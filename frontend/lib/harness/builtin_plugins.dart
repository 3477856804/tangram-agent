/// 内建插件集：把项目已有的**真实能力**逐一挂上插件内核的能力接缝。
///
/// 对标 DeepSeek Harness「模型、工具、技能、会话、沙箱、存储、循环、调度、
/// UI 全都是插件树上的节点」，以及 Claude Code 的 Skills / Hooks / Subagents /
/// MCP 分层、Codex 的 PTC 程序化工具调用、WorkBuddy 的技能与定时任务。
///
/// 关键：这些插件不是空壳。每个接缝 provider 的 invoke 都通过 [KernelHost]
/// 调到 EmbeddedBackend 里**已经存在的真实实现**（磁盘读写、工具注册表、
/// 真 shell、Isolate cube、真实推理、真实 MCP 同步、真实 IM 网关状态……），
/// 由 embedded_backend.dart 传入绑定了私有方法的闭包。插件本身不复制、
/// 不改写、不合并现有执行链（尤其 cube 契约链与真 shell 链保持分离）。
///
/// 「换一个 provider，整个产品就变了」在这里是真的：core/sandbox 接缝有
/// real-shell 与 isolate-cube 两个真实 provider，切换 active 后 invoke('exec')
/// 真的走两条不同的执行链；core/model 的 auto 与 builtin-loop 亦然。

import 'dart:convert';

import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/plugin_kernel.dart';

// ---------------------------------------------------------------------------
// KernelHost：内建插件唯一依赖的"真实能力"契约（由 EmbeddedBackend 注入）
// ---------------------------------------------------------------------------

typedef HostChat = Future<Map<String, dynamic>> Function(Map<String, dynamic> p);
typedef HostShell = Future<Map<String, dynamic>> Function(
    String command, String cwd);
typedef HostCube = Future<Map<String, dynamic>> Function(
    String cube, Map<String, dynamic> args);
typedef HostList = Future<List<Map<String, dynamic>>> Function();
typedef HostRecords = Future<List<Map<String, dynamic>>> Function(String key);
typedef HostInsert = Future<int> Function(String key, Map<String, dynamic> record);
typedef HostMcp = Future<Map<String, dynamic>> Function();
typedef HostIm = Map<String, dynamic> Function();
typedef HostPages = List<String> Function();
typedef HostReadJson = Future<Map<String, dynamic>> Function(String file);
typedef HostWriteJson = Future<void> Function(String file, Object? value);

/// 真实能力注入点。所有回调都指向项目已存在的实现，绝无占位/伪造。
class KernelHost {
  KernelHost({
    required this.tools,
    required this.chat,
    required this.shell,
    required this.cube,
    required this.skills,
    required this.mcpSync,
    required this.imStatus,
    required this.records,
    required this.insertRecord,
    required this.readJson,
    required this.writeJson,
    required this.writable,
    required this.dataDir,
    required this.uiPages,
    required this.sandboxEnvironment,
  });

  final ToolRegistry tools;
  final HostChat chat;
  final HostShell shell;
  final HostCube cube;
  final HostList skills;
  final HostMcp mcpSync;
  final HostIm imStatus;
  final HostRecords records;
  final HostInsert insertRecord;
  final HostReadJson readJson;
  final HostWriteJson writeJson;
  final bool Function() writable;
  final String Function() dataDir;
  final HostPages uiPages;
  final Future<String> Function() sandboxEnvironment;
}

// ---------------------------------------------------------------------------
// 通用能力插件：一个插件 = 一项能力接缝 + 若干真实 provider + 依赖/使用方
// ---------------------------------------------------------------------------

typedef PluginBuild = void Function(PluginContext ctx);

class _CapabilityPlugin extends Plugin {
  _CapabilityPlugin({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.seam,
    required this.definition,
    required this.build,
    this.requires = const <String>[],
    this.consumers = const <String>[],
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final String version;
  @override
  final String description;
  final String seam;
  final String definition;
  final PluginBuild build;
  @override
  final List<String> requires;
  final List<String> consumers;

  @override
  List<String> get providesSeams => <String>[seam];

  @override
  Future<void> apply(PluginContext ctx) async {
    // 把接缝对象本身登记为具名服务，供依赖它的插件 inject。
    final CapabilitySeam s = ctx.seam(seam, definition);
    ctx.provideService(seam, s);
    build(ctx);
    for (final String c in consumers) {
      ctx.consumeSeam(seam, c);
    }
  }
}

Future<Map<String, dynamic>> _unknown(String method) async =>
    <String, dynamic>{'ok': false, 'error': '未知方法：$method'};

// ---------------------------------------------------------------------------
// 内存存储 provider：creator 模式/测试用的**真实**另一种持久化（非伪造）
// ---------------------------------------------------------------------------

class _MemoryStore {
  final Map<String, Map<String, dynamic>> _docs = <String, Map<String, dynamic>>{};
  final Map<String, List<Map<String, dynamic>>> _records =
      <String, List<Map<String, dynamic>>>{};
  int _nextId = 1;

  Future<Map<String, dynamic>> invoke(
      String method, Map<String, dynamic> args) async {
    switch (method) {
      case 'read_json':
        final String file = (args['file'] ?? '').toString();
        return <String, dynamic>{
          'ok': true,
          'data': Map<String, dynamic>.from(_docs[file] ?? <String, dynamic>{}),
        };
      case 'write_json':
        final String file = (args['file'] ?? '').toString();
        final Object? value = args['value'];
        _docs[file] = value is Map
            ? Map<String, dynamic>.from(value)
            : <String, dynamic>{};
        return <String, dynamic>{'ok': true};
      case 'records':
        final String key = (args['key'] ?? '').toString();
        return <String, dynamic>{
          'ok': true,
          'records': List<Map<String, dynamic>>.of(
              _records[key] ?? <Map<String, dynamic>>[]),
        };
      case 'insert':
        final String key = (args['key'] ?? '').toString();
        final Map<String, dynamic> record = args['record'] is Map
            ? Map<String, dynamic>.from(args['record'] as Map)
            : <String, dynamic>{};
        final int id = _nextId++;
        _records.putIfAbsent(key, () => <Map<String, dynamic>>[])
            .add(<String, dynamic>{'id': id, ...record});
        return <String, dynamic>{'ok': true, 'id': id};
      case 'status':
        return <String, dynamic>{
          'ok': true,
          'provider': 'in-memory',
          'docs': _docs.length,
          'record_collections': _records.length,
          'note': '进程内存，重启即失；绝不冒充磁盘持久化',
        };
      default:
        return _unknown(method);
    }
  }
}

/// 构建全部内建插件 + 默认 profile + 各运行模式的插件裁剪集。
class BuiltinPlugins {
  BuiltinPlugins._();

  static const String v = '1.0.0';

  /// 挂载顺序即依赖顺序：被依赖的先挂。
  static List<Plugin> build(KernelHost host) {
    final _MemoryStore mem = _MemoryStore();
    return <Plugin>[
      // ---- core/storage ----
      _CapabilityPlugin(
        id: 'core.storage',
        name: '持久化存储',
        version: v,
        description: '真实磁盘 JSON 原子写 / 记录集合；可切到内存实现',
        seam: 'core/storage',
        definition: '读写具名 JSON 文档与记录集合（原子写、可恢复）',
        consumers: const <String>['session', 'trajectory', 'scheduler'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider(
              'core/storage', 'harness-store', 'App 私有目录真实磁盘存储',
              (String method, Map<String, dynamic> args) async {
            switch (method) {
              case 'read_json':
                final Map<String, dynamic> data =
                    await host.readJson((args['file'] ?? '').toString());
                return <String, dynamic>{'ok': true, 'data': data};
              case 'write_json':
                await host.writeJson(
                    (args['file'] ?? '').toString(), args['value']);
                return <String, dynamic>{'ok': true};
              case 'records':
                return <String, dynamic>{
                  'ok': true,
                  'records': await host.records((args['key'] ?? '').toString()),
                };
              case 'insert':
                final String key = (args['key'] ?? '').toString();
                final Map<String, dynamic> record = args['record'] is Map
                    ? Map<String, dynamic>.from(args['record'] as Map)
                    : <String, dynamic>{};
                return <String, dynamic>{
                  'ok': true,
                  'id': await host.insertRecord(key, record),
                };
              case 'status':
                return <String, dynamic>{
                  'ok': true,
                  'provider': 'harness-store',
                  'writable': host.writable(),
                  'data_dir': host.dataDir(),
                };
              default:
                return _unknown(method);
            }
          });
          // 第二个真实 provider：内存实现（切换后行为真的不同）。
          ctx.provideSeamProvider('core/storage', 'in-memory',
              '进程内存实现（creator/测试，重启即失，如实标注）', mem.invoke);
        },
      ),

      // ---- core/tools ----
      _CapabilityPlugin(
        id: 'core.tools',
        name: '工具注册表',
        version: v,
        description: '三段式 lookup→validate→execute；含 PTC 批量组合调用',
        seam: 'core/tools',
        definition: '工具注册 / 查重 / 参数校验 / 执行 / 程序化批量调用',
        requires: const <String>['core/storage'],
        consumers: const <String>['agent-loop', 'shell', 'ptc'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider(
              'core/tools', 'tool-registry', '真实 ToolRegistry（11 内置 + MCP 动态挂载）',
              (String method, Map<String, dynamic> args) async {
            switch (method) {
              case 'list':
                return <String, dynamic>{'ok': true, 'tools': host.tools.names};
              case 'describe':
                return <String, dynamic>{
                  'ok': true,
                  'tools': host.tools.describe(),
                };
              case 'count':
                return <String, dynamic>{'ok': true, 'count': host.tools.length};
              case 'run':
                final ToolResult r = await host.tools.run(
                    (args['name'] ?? '').toString(),
                    args['arguments'] is Map
                        ? Map<String, dynamic>.from(args['arguments'] as Map)
                        : <String, dynamic>{});
                return <String, dynamic>{'ok': r.ok, ...r.toJson()};
              case 'ptc_batch':
                // PTC/Code mode：一段"程序"顺序组合多轮真实工具调用。
                final List<dynamic> calls =
                    args['calls'] is List ? args['calls'] as List : <dynamic>[];
                final List<Map<String, dynamic>> results =
                    <Map<String, dynamic>>[];
                for (final dynamic c in calls) {
                  if (c is! Map) continue;
                  final ToolResult r = await host.tools.run(
                      (c['name'] ?? '').toString(),
                      c['arguments'] is Map
                          ? Map<String, dynamic>.from(c['arguments'] as Map)
                          : <String, dynamic>{});
                  results.add(<String, dynamic>{
                    'name': (c['name'] ?? '').toString(),
                    ...r.toJson(),
                  });
                }
                return <String, dynamic>{
                  'ok': true,
                  'executed': results.length,
                  'results': results,
                };
              default:
                return _unknown(method);
            }
          });
          // 插件贡献工具（可逆）：卸载即撤销注册。
          ctx.registerTool(AgentTool(
            name: 'kernel.inspect',
            description: '查看当前插件内核的实时状态（挂载数/接缝/模式）',
            tier: ApprovalTier.read,
            execute: (Map<String, dynamic> a, CancelToken? t) async {
              final Map<String, dynamic> s =
                  await ctx.kernel.handle('describe', <String, dynamic>{});
              return ToolResult.ok(jsonEncodeSafe(s));
            },
          ));
          ctx.registerControlAction(
              'tools.ptc', (Map<String, dynamic> p) => ctx.kernel.invoke(
                    'core/tools', 'ptc_batch',
                    <String, dynamic>{'calls': p['calls'] ?? <dynamic>[]}));
        },
      ),

      // ---- core/session（append-only 会话日志）----
      _CapabilityPlugin(
        id: 'core.session',
        name: '会话与轨迹日志',
        version: v,
        description: 'append-only 会话事件流：记录推理/工具/子Agent/上下文注入',
        seam: 'core/session',
        definition: '只追加的事件流，支持 replay / search / fork 同一份数据',
        requires: const <String>['core/storage'],
        consumers: const <String>['agent-loop', 'super-agent', 'trajectory'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider(
              'core/session', 'append-only-log', '内核 append-only 事件流（真实落盘 jsonl）',
              (String method, Map<String, dynamic> args) async {
            switch (method) {
              case 'append':
                ctx.kernel.emit('session.cell', 'core.session',
                    <String, dynamic>{
                      'kind': (args['kind'] ?? 'context').toString(),
                      'text': (args['text'] ?? '').toString(),
                    });
                return <String, dynamic>{'ok': true, 'seq': ctx.kernel.eventSeq};
              case 'replay':
                final List<KernelEvent> evs = await ctx.kernel.replay(
                    fromSeq: args['from_seq'] is num
                        ? (args['from_seq'] as num).toInt()
                        : null);
                return <String, dynamic>{
                  'ok': true,
                  'events': evs.map((KernelEvent e) => e.toJson()).toList(),
                };
              case 'search':
                final List<KernelEvent> evs =
                    await ctx.kernel.search((args['query'] ?? '').toString());
                return <String, dynamic>{
                  'ok': true,
                  'events': evs.map((KernelEvent e) => e.toJson()).toList(),
                };
              case 'fork':
                return <String, dynamic>{
                  'ok': true,
                  'fork_seq': await ctx.kernel.fork(args['from_seq'] is num
                      ? (args['from_seq'] as num).toInt()
                      : 0),
                };
              default:
                return _unknown(method);
            }
          });
        },
      ),

      // ---- core/system-prompt ----
      _CapabilityPlugin(
        id: 'core.system-prompt',
        name: '系统提示词组装',
        version: v,
        description: '提示词按片段插件化：每段可挂可摘，compose 真实拼接',
        seam: 'core/system-prompt',
        definition: '由各插件贡献的提示词片段组装最终 system prompt',
        requires: const <String>['core/tools'],
        consumers: const <String>['agent-loop', 'model'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider(
              'core/system-prompt', 'composed-sections', '片段化组装（可插拔）',
              (String method, Map<String, dynamic> args) async {
            if (method == 'compose') {
              return <String, dynamic>{
                'ok': true,
                'prompt': ctx.kernel.composeSystemPrompt(),
              };
            }
            return _unknown(method);
          });
          // 一个真实片段：如实描述当前挂载的能力，绝不编造能力。
          ctx.registerPromptSection('kernel.capabilities', () {
            final int mounted = ctx.kernel.mountedCount;
            return '[运行内核] 当前为插件化 harness，已挂载 $mounted 个能力插件，'
                '运行模式 ${ctx.kernel.profile.mode.label}。'
                '能力通过接缝按需替换，工具调用经三段式校验执行。';
          });
        },
      ),

      // ---- core/model ----
      _CapabilityPlugin(
        id: 'core.model',
        name: '模型推理',
        version: v,
        description: '云端 OpenAI 兼容 / 本地 GGUF / 内置 AgentLoop 三条真实分支',
        seam: 'core/model',
        definition: '接收对话参数，返回真实推理结果（失败如实上报，绝不假绿）',
        requires: const <String>['core/tools', 'core/system-prompt'],
        consumers: const <String>['agent-loop', 'super-agent', 'im'],
        build: (PluginContext ctx) {
          Future<Map<String, dynamic>> chat(Map<String, dynamic> args,
                  {bool forceBuiltin = false}) async {
            final Map<String, dynamic> p = <String, dynamic>{
              ...args,
              if (forceBuiltin) 'model_kind': 'builtin',
            };
            final Map<String, dynamic> r = await host.chat(p);
            ctx.kernel.emit('model.chat', 'core.model', <String, dynamic>{
              'engine': (r['engine'] ?? '').toString(),
              'ok': r['ok'] == true,
            });
            return r;
          }

          ctx.provideSeamProvider('core/model', 'auto', '真实自动分派（云端→本地→内置）',
              (String method, Map<String, dynamic> args) async {
            if (method == 'chat') return chat(args);
            if (method == 'describe') {
              return <String, dynamic>{
                'ok': true,
                'engines': <String>['remote-http', 'local-gguf', 'builtin-agent-loop'],
                'note': '由 _chat 依据真实凭据/权重分派，缺凭据如实 remote-failed',
              };
            }
            return _unknown(method);
          });
          ctx.provideSeamProvider('core/model', 'builtin-loop',
              '强制内置 AgentLoop（真实工具/记忆/求值，无外部网络）',
              (String method, Map<String, dynamic> args) async {
            if (method == 'chat') return chat(args, forceBuiltin: true);
            if (method == 'describe') {
              return <String, dynamic>{'ok': true, 'engine': 'builtin-agent-loop'};
            }
            return _unknown(method);
          });
        },
      ),

      // ---- core/sandbox（最能体现 seam：两条真实且分离的执行链）----
      _CapabilityPlugin(
        id: 'core.sandbox',
        name: '执行世界（沙箱）',
        version: v,
        description: 'real-shell 与 isolate-cube 两个真实 provider，切换全链路生效',
        seam: 'core/sandbox',
        definition: '命令/代码执行；本地 shell、SSH、proot、Isolate cube 分离',
        requires: const <String>['core/storage'],
        consumers: const <String>['shell', 'terminal', 'code-task', 'super-agent'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider('core/sandbox', 'real-shell',
              '系统 bash/sh（含 SSH/proot/内置解释器兜底，全部真实）',
              (String method, Map<String, dynamic> args) async {
            if (method == 'exec') {
              final Map<String, dynamic> r = await host.shell(
                  (args['command'] ?? '').toString(),
                  (args['cwd'] ?? '.').toString());
              ctx.kernel.emit('sandbox.exec', 'core.sandbox',
                  <String, dynamic>{'provider': 'real-shell', 'ok': r['ok'] == true});
              return r;
            }
            if (method == 'describe') {
              return <String, dynamic>{
                'ok': true,
                'environment': await host.sandboxEnvironment(),
                'chain': 'bash/sh → SSH → proot → 内置解释器（如实降级）',
              };
            }
            return _unknown(method);
          });
          ctx.provideSeamProvider('core/sandbox', 'isolate-cube',
              '受限 Isolate + cube 能力契约（缺失能力即 REFUSE，5s 看门狗）',
              (String method, Map<String, dynamic> args) async {
            if (method == 'exec') {
              final Map<String, dynamic> r = await host.cube(
                  (args['cube'] ?? 'eval_expression').toString(),
                  args['args'] is Map
                      ? Map<String, dynamic>.from(args['args'] as Map)
                      : <String, dynamic>{});
              ctx.kernel.emit('sandbox.exec', 'core.sandbox',
                  <String, dynamic>{'provider': 'isolate-cube', 'ok': r['ok'] == true});
              return r;
            }
            if (method == 'describe') {
              return <String, dynamic>{
                'ok': true,
                'chain': 'SandboxedShell → Isolate → CubeContract.capability 校验',
              };
            }
            return _unknown(method);
          });
        },
      ),

      // ---- core/skills ----
      _CapabilityPlugin(
        id: 'core.skills',
        name: '技能池',
        version: v,
        description: 'SKILL.md frontmatter 解析并注入提示词（对齐 Claude Code Skills）',
        seam: 'core/skills',
        definition: '列出/启停按需加载的技能指令包',
        requires: const <String>['core/storage'],
        consumers: const <String>['system-prompt', 'agent-loop'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider('core/skills', 'markdown-pool',
              '真实扫描 skills/*.md 并按启用状态注入',
              (String method, Map<String, dynamic> args) async {
            if (method == 'list') {
              return <String, dynamic>{'ok': true, 'skills': await host.skills()};
            }
            return _unknown(method);
          });
        },
      ),

      // ---- core/mcp ----
      _CapabilityPlugin(
        id: 'core.mcp',
        name: 'MCP 动态挂载',
        version: v,
        description: '可逆动态挂载：全量注销→重连→tools/list 注册（对齐 MCP 标准）',
        seam: 'core/mcp',
        definition: '同步 MCP 服务并注册远端工具',
        requires: const <String>['core/tools'],
        consumers: const <String>['agent-loop'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider('core/mcp', 'dynamic-mount',
              '真实 _mcpSync：connected/failed/skipped 如实上报',
              (String method, Map<String, dynamic> args) async {
            if (method == 'sync') return await host.mcpSync();
            if (method == 'describe') {
              return <String, dynamic>{
                'ok': true,
                'note': 'stdio 传输移动端无法 spawn 进程，如实 skipped',
              };
            }
            return _unknown(method);
          });
        },
      ),

      // ---- core/agent-loop ----
      _CapabilityPlugin(
        id: 'core.agent-loop',
        name: 'Agent 循环驱动',
        version: v,
        description: '默认意图路由循环（可替换：对齐 dsh "loop 不是特权代码"）',
        seam: 'core/agent-loop',
        definition: '接收目标，驱动工具/推理回路，产出回复',
        requires: const <String>['core/model', 'core/tools', 'core/sandbox'],
        consumers: const <String>['chat', 'super-agent'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider('core/agent-loop', 'default-loop',
              '内置意图路由 + 真实工具求值 + 记忆检索',
              (String method, Map<String, dynamic> args) async {
            if (method == 'run') {
              return await ctx.kernel.invoke('core/model', 'chat',
                  <String, dynamic>{'text': (args['text'] ?? '').toString()});
            }
            return _unknown(method);
          });
          // 子 Agent / hooks 事件：监听插件生命周期，记录到 append-only 流。
          ctx.on('plugin.mounted', (KernelEvent e) {
            ctx.kernel.emit('agent-loop.observe', 'core.agent-loop',
                <String, dynamic>{'on': 'plugin.mounted', 'seq': e.seq});
          });
        },
      ),

      // ---- core/trajectory ----
      _CapabilityPlugin(
        id: 'core.trajectory',
        name: '工作轨迹',
        version: v,
        description: '真实工作轨迹落盘（work_traces）与 append-only 事件流双视图',
        seam: 'core/trajectory',
        definition: '按来源浏览、检索、回放任务轨迹',
        requires: const <String>['core/storage', 'core/session'],
        consumers: const <String>['chat', 'super-agent'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider('core/trajectory', 'work-traces',
              '真实 work_traces.json 记录 + 内核事件流',
              (String method, Map<String, dynamic> args) async {
            if (method == 'list') {
              return <String, dynamic>{
                'ok': true,
                'traces': await host.records('work_traces'),
              };
            }
            if (method == 'replay') {
              return await ctx.kernel.invoke('core/session', 'replay', args);
            }
            return _unknown(method);
          });
        },
      ),

      // ---- core/scheduler（对齐 Codex automations / WorkBuddy 定时任务）----
      _CapabilityPlugin(
        id: 'core.scheduler',
        name: '调度与主动任务',
        version: v,
        description: 'proactive_rules 真实落盘 + 事件驱动触发',
        seam: 'core/scheduler',
        definition: '增删改查定时/主动任务规则',
        requires: const <String>['core/storage'],
        consumers: const <String>['super-agent'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider('core/scheduler', 'proactive-rules',
              '真实 proactive_rules 集合',
              (String method, Map<String, dynamic> args) async {
            if (method == 'list') {
              return <String, dynamic>{
                'ok': true,
                'rules': await host.records('proactive_rules'),
              };
            }
            if (method == 'add') {
              final int id = await host.insertRecord('proactive_rules',
                  <String, dynamic>{
                    'title': (args['title'] ?? '').toString(),
                    'enabled': 1,
                    'ts': DateTime.now().millisecondsSinceEpoch / 1000.0,
                  });
              return <String, dynamic>{'ok': true, 'id': id};
            }
            return _unknown(method);
          });
        },
      ),

      // ---- core/im ----
      _CapabilityPlugin(
        id: 'core.im',
        name: 'IM 网关',
        version: v,
        description: '微信 iLink / QQ 官方 / 飞书真实网关状态（绝不假绿）',
        seam: 'core/im',
        definition: '查询各通道真实连接状态',
        consumers: const <String>['super-agent'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider('core/im', 'agp-gateway',
              '真实 ImService 适配器快照',
              (String method, Map<String, dynamic> args) async {
            if (method == 'status') {
              return <String, dynamic>{'ok': true, ...host.imStatus()};
            }
            return _unknown(method);
          });
        },
      ),

      // ---- ext/hooks（对齐 Claude Code Hooks：事件驱动的确定性钩子）----
      _CapabilityPlugin(
        id: 'ext.hooks',
        name: '生命周期钩子',
        version: v,
        description: '监听接缝切换/插件挂载/工具调用，确定性执行（非提示词可绕过）',
        seam: 'ext/hooks',
        definition: '注册事件钩子并统计触发',
        build: (PluginContext ctx) {
          int fired = 0;
          for (final String topic in <String>[
            'seam.provider_changed',
            'seam.invoke',
            'plugin.mounted',
            'plugin.unmounted',
            'kernel.mode_changed',
          ]) {
            ctx.on(topic, (KernelEvent e) => fired++);
          }
          ctx.provideSeamProvider('ext/hooks', 'lifecycle-hooks',
              '真实事件订阅（卸载即自动退订）',
              (String method, Map<String, dynamic> args) async {
            if (method == 'fired') {
              return <String, dynamic>{'ok': true, 'fired': fired};
            }
            return _unknown(method);
          });
          ctx.registerControlAction('hooks.fired',
              (Map<String, dynamic> p) async => <String, dynamic>{
                    'ok': true,
                    'fired': fired,
                  });
        },
      ),

      // ---- ui/pages（"UI 也是插件树上的节点"）----
      _CapabilityPlugin(
        id: 'ui.pages',
        name: '界面贡献',
        version: v,
        description: '工作台页面清单作为可查服务（对齐 dsh "UI 也参与组合"）',
        seam: 'ui/pages',
        definition: '列出当前真实注册的界面页',
        consumers: const <String>['creator'],
        build: (PluginContext ctx) {
          ctx.provideSeamProvider('ui/pages', 'workspace-nav',
              '真实侧边栏导航页清单',
              (String method, Map<String, dynamic> args) async {
            if (method == 'list') {
              return <String, dynamic>{'ok': true, 'pages': host.uiPages()};
            }
            return _unknown(method);
          });
        },
      ),
    ];
  }

  /// 默认组装：core bundle + ext bundle，标准模式。
  static RuntimeProfile defaultProfile() => RuntimeProfile(
        'default',
        'Tangram 标准组装',
        RunMode.standard,
        <Bundle>[
          Bundle('core', '核心能力', <String>[
            'core.storage',
            'core.tools',
            'core.session',
            'core.system-prompt',
            'core.model',
            'core.sandbox',
            'core.skills',
            'core.mcp',
            'core.agent-loop',
            'core.trajectory',
            'core.scheduler',
            'core.im',
          ], <String, dynamic>{'runtime': 'tangram-in-process'}),
          Bundle('ext', '扩展与界面', <String>[
            'ext.hooks',
            'ui.pages',
          ], <String, dynamic>{'ui': 'tga'}),
        ],
        <String, dynamic>{'kernel': 'cordis-style'},
      );

  /// 各运行模式允许的插件集合（null = 全部）。
  /// minimal 对齐 dsh/Codex：只留 shell + 文件编辑 + 工具 + 存储 + 会话。
  static Map<RunMode, Set<String>?> modePlugins() => <RunMode, Set<String>?>{
        RunMode.standard: null,
        RunMode.ptc: null,
        RunMode.creator: null,
        RunMode.minimal: <String>{
          'core.storage',
          'core.tools',
          'core.session',
          'core.sandbox',
        },
      };
}

// ---------------------------------------------------------------------------

/// 把内核状态 Map 编成真实 JSON 字符串（工具结果用）。
String jsonEncodeSafe(Object? value) {
  try {
    return jsonEncode(value);
  } on Object {
    return value.toString();
  }
}
