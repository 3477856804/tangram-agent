/// Tangram 插件内核（Cordis 风格，纯 Dart，可逆挂载）。
///
/// 对标 DeepSeek Harness「一切皆插件」与 Claude Code / Codex / WorkBuddy 的
/// 分层扩展机制，把参考架构的四个核心概念落成真实可运行的代码：
///
///  * **能力接缝 seam**：一项可替换的能力 = 定义 Definition + 提供方 Provider
///    + 使用方 Consumer。换一个 provider，所有 consumer 一起搬过去，不用给
///    每个工具单写一套远程版本（dsh "换一个提供方，整个产品就变了"）。
///  * **共享上下文 ctx**：插件通过它 provide 服务 / inject 依赖 / register
///    工具与控制域 / listen 事件（对齐 Cordis 的四种参与方式）。所有注册
///    都产生一个可逆 effect，卸载时逆序撤销——"挂上去生效，摘下来就恢复"。
///  * **插件树**：父子节点、挂载顺序、依赖校验（requires 不满足即拒绝挂载）、
///    运行时可逆装载，绝不谎称已挂载。
///  * **配置分层**：profile 的 bundles → profile patch → home patch →
///    runtime patch，越后优先级越高；dump_config 每一项都标来源层。
///
/// 另外把 dsh「每一次运行都有迹可循」落为 **append-only 会话日志**：内核
/// 事件、推理、工具调用、接缝切换、子 Agent 调度全部只追加、不改写，支持
/// replay / search / fork 同一份事件流。
///
/// 设计红线（与本项目一致）：绝不填充假数据、绝不静默降级、绝不谎称已连接。
/// 内核不接管 EmbeddedBackend 现有 24 个控制域、不碰流式 token 的 hot-path
/// 实时流、不合并 cube 契约链与真 shell 链；它是一层并行、可插拔的能力编排。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/kernel_guard.dart';
import 'package:tangram/harness/plugin_tier.dart';

// ---------------------------------------------------------------------------
// 持久化：append-only 事件流 + 原子配置写（可注入内存实现供测试）
// ---------------------------------------------------------------------------

/// 内核持久化契约。事件流只追加；配置整体原子替换。
abstract class KernelPersistence {
  Future<void> appendEvent(Map<String, dynamic> event);
  Future<List<Map<String, dynamic>>> readEvents();
  Future<void> writeConfig(Map<String, dynamic> config);
  Future<Map<String, dynamic>> readConfig();
}

/// 基于真实磁盘的实现：events.jsonl 逐行追加，config.json 临时文件+改名。
class FileKernelPersistence implements KernelPersistence {
  FileKernelPersistence(this.dir);
  final Directory dir;

  File get _eventsFile => File('${dir.path}/kernel_events.jsonl');
  File get _configFile => File('${dir.path}/kernel_config.json');

  /// 串行化追加：并发 emit 时避免多个 FileMode.append 句柄交错写坏行。
  Future<void> _writeChain = Future<void>.value();

  @override
  Future<void> appendEvent(Map<String, dynamic> event) {
    // 单次写失败必须让串行链自愈：若把失败的 future 留在 _writeChain 上，
    // 后续所有 append 的 .then 都不会再执行（级联失败），readEvents 里
    // 的 await _writeChain 也会抛。catchError 把它恢复成一条干净的已完成链。
    _writeChain = _writeChain.then((_) async {
      if (!await dir.exists()) await dir.create(recursive: true);
      final IOSink sink = _eventsFile.openWrite(mode: FileMode.append);
      sink.writeln(jsonEncode(event));
      await sink.flush();
      await sink.close();
    }).catchError((Object _) {
      // 磁盘异常如实吞掉：append-only 日志尽力而为，不冒充已落盘，
      // readEvents 只回放真正写成功的行。
    });
    return _writeChain;
  }

  @override
  Future<List<Map<String, dynamic>>> readEvents() async {
    await _writeChain; // 等所有待写入完成，保证回放看到完整事件流。
    final File f = _eventsFile;
    if (!await f.exists()) return <Map<String, dynamic>>[];
    final String raw = await f.readAsString();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final String line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final dynamic d = jsonDecode(line);
        if (d is Map) out.add(Map<String, dynamic>.from(d));
      } on Object {
        // 半行/损坏行不冒充数据，跳过。
      }
    }
    return out;
  }

  @override
  Future<void> writeConfig(Map<String, dynamic> config) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    final File tmp = File('${_configFile.path}.tmp');
    await tmp.writeAsString(jsonEncode(config), flush: true);
    await tmp.rename(_configFile.path);
  }

  @override
  Future<Map<String, dynamic>> readConfig() async {
    final File f = _configFile;
    if (!await f.exists()) return <String, dynamic>{};
    try {
      final dynamic d = jsonDecode(await f.readAsString());
      if (d is Map) return Map<String, dynamic>.from(d);
    } on Object {
      // 损坏配置回退空态，不编造。
    }
    return <String, dynamic>{};
  }
}

/// 内存实现（单元测试用），与磁盘实现同语义。
class MemoryKernelPersistence implements KernelPersistence {
  final List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];
  Map<String, dynamic> _config = <String, dynamic>{};

  @override
  Future<void> appendEvent(Map<String, dynamic> event) async {
    _events.add(Map<String, dynamic>.from(event));
  }

  @override
  Future<List<Map<String, dynamic>>> readEvents() async =>
      _events.map((Map<String, dynamic> e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<void> writeConfig(Map<String, dynamic> config) async {
    _config = Map<String, dynamic>.from(config);
  }

  @override
  Future<Map<String, dynamic>> readConfig() async =>
      Map<String, dynamic>.from(_config);
}

// ---------------------------------------------------------------------------
// 接缝 / 服务 / 事件
// ---------------------------------------------------------------------------

/// 接缝 provider 的真实调用体：给定方法与参数，返回结构化结果。
typedef SeamInvoke = Future<Map<String, dynamic>> Function(
    String method, Map<String, dynamic> args);

/// 控制域动作处理体（插件可贡献新的控制动作）。
typedef KernelControlAction = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> payload);

/// 提示词片段构造器（系统提示词插件化：每段可挂可摘）。
typedef PromptSectionBuilder = String Function();

/// 一个已注册到某接缝的 provider。
class SeamProviderEntry {
  SeamProviderEntry(this.id, this.description, this.invoke, this.ownerPlugin);
  final String id;
  final String description;
  final SeamInvoke invoke;
  final String ownerPlugin;
}

/// 能力接缝：定义 + 一组 provider + 当前激活 provider + 使用方清单。
class CapabilitySeam {
  CapabilitySeam(this.name, this.definition);
  final String name;
  final String definition;
  final Map<String, SeamProviderEntry> providers = <String, SeamProviderEntry>{};
  final List<String> consumers = <String>[];
  String activeProviderId = '';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'definition': definition,
        'active_provider': activeProviderId,
        'providers': providers.values
            .map((SeamProviderEntry p) => <String, dynamic>{
                  'id': p.id,
                  'description': p.description,
                  'owner': p.ownerPlugin,
                })
            .toList(),
        'consumers': List<String>.of(consumers),
      };
}

/// 类型化事件：带 topic、序号、时间戳、来源与数据。
class KernelEvent {
  const KernelEvent(this.seq, this.topic, this.source, this.ts, this.data);
  final int seq;
  final String topic;
  final String source;
  final String ts;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'seq': seq,
        'topic': topic,
        'source': source,
        'ts': ts,
        'data': data,
      };

  static KernelEvent fromJson(Map<String, dynamic> m) => KernelEvent(
        (m['seq'] as num?)?.toInt() ?? 0,
        (m['topic'] ?? '').toString(),
        (m['source'] ?? '').toString(),
        (m['ts'] ?? '').toString(),
        m['data'] is Map
            ? Map<String, dynamic>.from(m['data'] as Map)
            : <String, dynamic>{},
      );
}

typedef KernelEventHandler = void Function(KernelEvent event);

/// 内核事件总线：具名订阅、可逆退订；每个事件同时只追加进会话日志。
class KernelEventBus {
  final Map<int, _Sub> _subs = <int, _Sub>{};
  int _nextId = 1;

  int on(String topic, KernelEventHandler handler, String owner) {
    final int id = _nextId++;
    _subs[id] = _Sub(topic, handler, owner);
    return id;
  }

  void off(int id) => _subs.remove(id);

  int countFor(String owner) =>
      _subs.values.where((_Sub s) => s.owner == owner).length;

  /// 派发给订阅者；返回本次构造的事件，由内核落盘。
  KernelEvent emit(String topic, String source, Map<String, dynamic> data, int seq) {
    final KernelEvent ev = KernelEvent(
        seq, topic, source, DateTime.now().toIso8601String(), data);
    for (final _Sub s in List<_Sub>.of(_subs.values)) {
      if (s.topic == topic || s.topic == '*') {
        try {
          s.handler(ev);
        } on Object {
          // 单个订阅者异常不影响其他订阅者，也不逃逸内核。
        }
      }
    }
    return ev;
  }
}

class _Sub {
  _Sub(this.topic, this.handler, this.owner);
  final String topic;
  final KernelEventHandler handler;
  final String owner;
}

/// 撤销一个注册动作的闭包（Cordis reversible effect）。
typedef Disposable = void Function();

/// 一条可自定义的界面页注册项。owner = 插件 id 或 'runtime'（用户经 action 写入）。
/// 顺序即渲染顺序，reorder 真实改写这个列表，不是改一个排序标记。
class KernelPage {
  KernelPage(this.id, this.meta, this.owner);
  final String id;
  final Map<String, dynamic> meta;
  final String owner;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'meta': Map<String, dynamic>.from(meta),
        'owner': owner,
      };
}

// ---------------------------------------------------------------------------
// 共享上下文 ctx：插件与内核之间唯一的协作面
// ---------------------------------------------------------------------------

/// 插件上下文。所有注册动作既真实生效，又产生一个 [Disposable] 登记到
/// 当前作用域的 effects；卸载插件时逆序执行，实现"摘下来就恢复"。
class PluginContext {
  PluginContext._(this._kernel, this._effects, this.pluginId,
      {List<String>? caps, PluginTier tier = PluginTier.official})
      : _declaredCaps = caps,
        _declaredTier = tier;
  final PluginKernel _kernel;
  final List<Disposable>? _effects;
  final String pluginId;
  /// 挂载时由 mount() 传入的已声明 caps：apply 期间插件尚未入 _nodes，
  /// 不能靠 pluginOf 查；运行期优先查登记值，与之一致。
  final List<String>? _declaredCaps;
  /// 同上：挂载时传入的分级（apply 期间 pluginOf 同样查不到）。
  final PluginTier _declaredTier;

  List<String> _capsOf() =>
      _declaredCaps ?? _kernel.pluginOf(pluginId)?.caps ?? const <String>[];

  /// 插件看到的内核是受限 facade（round13）：只暴露 invoke/emit/describe/
  /// replay/search/fork/composeSystemPrompt/只读计数与页面读写，绝不交出
  /// 裸 PluginKernel——旧 getter 返回裸内核时，插件可直调 setProvider/
  /// mount/restoreSnapshot 绕过全部仲裁。getter 名不变，调用点不用改名。
  PluginKernelFacade get kernel =>
      PluginKernelFacade._(_kernel, pluginId, _capsOf());

  void _track(Disposable d) => _effects?.add(d);

  /// 提供一个具名服务；撤销时恢复注册前的同名服务（真实可逆）。
  void provideService(String name, Object service) {
    final _ServiceEntry? previous = _kernel._services[name];
    _kernel._services[name] = _ServiceEntry(name, service, pluginId);
    _track(() {
      if (previous == null) {
        _kernel._services.remove(name);
      } else {
        _kernel._services[name] = previous;
      }
    });
  }

  /// 取服务；不存在返回 null（不做静默伪造）。
  T? service<T extends Object>(String name) {
    final _ServiceEntry? e = _kernel._services[name];
    final Object? v = e?.value;
    return v is T ? v : null;
  }

  /// 注入依赖：缺失即抛 [StateError]，由挂载器转为结构化拒绝。
  T require<T extends Object>(String name) {
    final T? v = service<T>(name);
    if (v == null) throw StateError('依赖服务 $name 未挂载');
    return v;
  }

  bool hasService(String name) => _kernel._services.containsKey(name);

  /// 声明/取得一个能力接缝（定义不可变，已存在则复用）。
  /// round13：只返回只读快照 [SeamView]，不再交出可变的 CapabilitySeam
  /// 对象——旧返回可被插件直改 providers/consumers/activeProviderId。
  SeamView seam(String name, String definition) =>
      SeamView.of(_kernel._ensureSeam(name, definition));

  /// 注册一个接缝 provider。
  void provideSeamProvider(String seamName, String id, String description,
      SeamInvoke invoke) {
    final CapabilitySeam s = _kernel._ensureSeam(seamName, '');
    final SeamProviderEntry? previous = s.providers[id];
    s.providers[id] = SeamProviderEntry(id, description, invoke, pluginId);
    if (s.activeProviderId.isEmpty) s.activeProviderId = id;
    _track(() {
      if (previous == null) {
        s.providers.remove(id);
        if (s.activeProviderId == id) {
          s.activeProviderId = s.providers.keys.isEmpty
              ? ''
              : s.providers.keys.first;
        }
      } else {
        s.providers[id] = previous;
      }
    });
  }

  /// 声明自己是某接缝的使用方；切换 provider 时一并感知。
  void consumeSeam(String seamName, String consumerName) {
    // round13：apply 期间插件尚未入 _nodes，pluginOf 查不到——用挂载时
    // 传入的已声明 caps/tier 校验（与登记值一致）；运行期两者一致。
    // 旧代码只在 pluginOf 非空时校验，apply 期间恒为 null，门禁是死的，
    // D 的收紧也就落不了地。
    final Plugin? registered = _kernel.pluginOf(pluginId);
    final List<String> caps =
        _declaredCaps ?? registered?.caps ?? const <String>[];
    final PluginTier tier = registered?.tier ?? _declaredTier;
    if (!seamAllowed(tier, caps, seamName)) {
      throw CapabilityDenied(
          pluginId, seamName, 'caps 未声明该接缝（tier=${tier.wire}）');
    }
    final CapabilitySeam s = _kernel._ensureSeam(seamName, '');
    if (!s.consumers.contains(consumerName)) s.consumers.add(consumerName);
    _track(() => s.consumers.remove(consumerName));
  }

  /// 注册一个工具进真实 [ToolRegistry]；撤销时恢复/移除。
  void registerTool(AgentTool tool) {
    final ToolRegistry? reg = _kernel.toolRegistry;
    if (reg == null) throw StateError('工具注册表未注入，拒绝注册工具');
    final AgentTool? previous = reg.lookup(tool.name);
    reg.register(tool);
    _track(() {
      if (previous == null) {
        reg.unregister(tool.name);
      } else {
        reg.register(previous);
      }
    });
  }

  /// 注册一个内核控制动作；撤销时移除。
  void registerControlAction(String action, KernelControlAction handler) {
    final _ControlEntry? previous = _kernel._controlActions[action];
    _kernel._controlActions[action] = _ControlEntry(action, handler, pluginId);
    _track(() {
      if (previous == null) {
        _kernel._controlActions.remove(action);
      } else {
        _kernel._controlActions[action] = previous;
      }
    });
  }

  /// 注册一个系统提示词片段；撤销时恢复/移除。
  void registerPromptSection(String id, PromptSectionBuilder builder) {
    final PromptSectionBuilder? previous = _kernel._promptSections[id];
    _kernel._promptSections[id] = builder;
    _track(() {
      if (previous == null) {
        _kernel._promptSections.remove(id);
      } else {
        _kernel._promptSections[id] = previous;
      }
    });
  }

  /// 订阅内核事件；撤销时自动退订。
  void on(String topic, KernelEventHandler handler) {
    final int id = _kernel._bus.on(topic, handler, pluginId);
    _track(() => _kernel._bus.off(id));
  }

  /// 发布一个内核事件（记入 append-only 会话日志）。
  /// round13：与 facade 共用同一份白名单（见 kernel_guard.dart），
  /// 禁发 kernel.*/seam.*/plugin.* 前缀，违规即抛，不静默吞掉。
  void emit(String topic, Map<String, dynamic> data) {
    if (!pluginEmitAllowed(topic)) {
      throw StateError('插件 $pluginId 不可发布事件 $topic（不在白名单内）');
    }
    _kernel.emit(topic, pluginId, data);
  }

  // ---- 自定义能力接缝：页面 / 组件槽 / 文案覆盖 / 权限策略 ----
  // 每个注册都既真实写入内核容器，又登记一个幂等 Disposable：
  // 挂载生效，卸载逆序恢复注册前状态；调用方也可直接使用返回值。

  /// 注册一条自定义界面页。顺序即渲染顺序，reorder 真实改写列表。
  Disposable registerPage(String id, Map<String, dynamic> meta) {
    final int idx = _kernel._pages.indexWhere((KernelPage p) => p.id == id);
    final KernelPage? previous = idx >= 0 ? _kernel._pages[idx] : null;
    final KernelPage next =
        KernelPage(id, Map<String, dynamic>.from(meta), pluginId);
    if (idx >= 0) {
      _kernel._pages[idx] = next;
    } else {
      _kernel._pages.add(next);
    }
    void undo() {
      final int cur = _kernel._pages.indexWhere((KernelPage p) => p.id == id);
      if (cur < 0 || !identical(_kernel._pages[cur], next)) return;
      if (previous == null) {
        _kernel._pages.removeAt(cur);
      } else {
        _kernel._pages[cur] = previous;
      }
    }

    _track(undo);
    return undo;
  }

  /// 注册一个可替换的 UI 组件槽（widget slot）元数据。
  Disposable registerWidgetSlot(String id, Map<String, dynamic> meta) {
    final Map<String, dynamic>? previous = _kernel._widgetSlots[id];
    final Map<String, dynamic> next = Map<String, dynamic>.from(meta);
    _kernel._widgetSlots[id] = next;
    void undo() {
      if (!identical(_kernel._widgetSlots[id], next)) return;
      if (previous == null) {
        _kernel._widgetSlots.remove(id);
      } else {
        _kernel._widgetSlots[id] = previous;
      }
    }

    _track(undo);
    return undo;
  }

  /// 按语言注册一条文案覆盖。resolveText 真实返回覆盖值，未覆盖返回 null。
  Disposable registerTextOverride(String locale, String key, String value) {
    final Map<String, String> byKey = _kernel._textOverrides.putIfAbsent(
        locale, () => <String, String>{});
    final String? previous = byKey[key];
    byKey[key] = value;
    void undo() {
      final Map<String, String>? cur = _kernel._textOverrides[locale];
      if (cur == null || !identical(cur, byKey)) return;
      if (previous == null) {
        cur.remove(key);
        if (cur.isEmpty) _kernel._textOverrides.remove(locale);
      } else {
        cur[key] = previous;
      }
    }

    _track(undo);
    return undo;
  }

  /// 注册一条权限策略。策略是纯数据规则，由调用方真实判定，不在此假装放行。
  Disposable registerPermissionPolicy(String id, Map<String, dynamic> policy) {
    final Map<String, dynamic>? previous = _kernel._permissionPolicies[id];
    final Map<String, dynamic> next = Map<String, dynamic>.from(policy);
    _kernel._permissionPolicies[id] = next;
    void undo() {
      if (!identical(_kernel._permissionPolicies[id], next)) return;
      if (previous == null) {
        _kernel._permissionPolicies.remove(id);
      } else {
        _kernel._permissionPolicies[id] = previous;
      }
    }

    _track(undo);
    return undo;
  }
}

/// 能力接缝的只读视图：仅只读字段，无任何改写入口。
/// 由 [PluginContext.seam] 返回；想改 provider 或激活项必须走内核仲裁。
class SeamView {
  SeamView(this.name, this.definition, this.activeProviderId, this.providers,
      this.consumers);

  factory SeamView.of(CapabilitySeam s) => SeamView(
        s.name,
        s.definition,
        s.activeProviderId,
        s.providers.values
            .map((SeamProviderEntry p) => <String, dynamic>{
                  'id': p.id,
                  'description': p.description,
                  'owner': p.ownerPlugin,
                })
            .toList(),
        List<String>.of(s.consumers),
      );

  final String name;
  final String definition;
  final String activeProviderId;
  final List<Map<String, dynamic>> providers;
  final List<String> consumers;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'definition': definition,
        'active_provider': activeProviderId,
        'providers': providers,
        'consumers': consumers,
      };
}

/// 插件眼中的内核（round13）：受限 facade，只由 [PluginContext] 创建。
/// 暴露的每一次调用都在内部固定 caller=_pluginId、caps=_caps，调用方
/// 传不进来——payload 里自称的 caller/caps 永不参与鉴权。
/// 明确不暴露：mount/unmount/setProvider/handle（通用版）/restoreSnapshot/
/// captureSnapshot/registerPlugin/defineModePlugins/boot/dispose/
/// setTextOverride/setPermissionPolicy、profile 对象、seamCaps、invokeGuard、
/// onBeforeMount、CapabilitySeam 对象。
class PluginKernelFacade {
  PluginKernelFacade._(this._kernel, this._pluginId, this._caps);

  final PluginKernel _kernel;
  final String _pluginId;
  final List<String> _caps;

  /// 经内核仲裁调用接缝：caller 固定为登记身份，不接受调用方传入。
  Future<Map<String, dynamic>> invoke(
          String seam, String method, Map<String, dynamic> args) =>
      _kernel.invoke(seam, method, args, caller: _pluginId);

  /// 只放行白名单 topic（见 kernel_guard.dart）；其余抛 StateError，
  /// 且事件流里不留痕迹。
  void emit(String topic, Map<String, dynamic> data) {
    if (!pluginEmitAllowed(topic)) {
      throw StateError('插件 $_pluginId 不可发布事件 $topic（不在白名单内）');
    }
    _kernel.emit(topic, _pluginId, data);
  }

  /// 内核实时状态（只读，与 handle('describe') 同口径）。
  /// round14：含回退脏态字段（只读，插件可见脏态但改不了它）。
  Map<String, dynamic> describe() => <String, dynamic>{
        'ok': true,
        'booted': _kernel._booted,
        'profile': _kernel._profile.id,
        'mode': _kernel._profile.mode.label,
        'mounted': _kernel.mountedCount,
        'seams': _kernel._seams.length,
        'services': _kernel._services.length,
        'control_actions': _kernel._controlActions.length,
        'prompt_sections': _kernel._promptSections.length,
        'event_seq': _kernel._seq,
        'restore_dirty': _kernel._restoreDirty,
        'restore_dirty_reason': _kernel._restoreDirtyReason,
        'restore_dirty_at': _kernel._restoreDirtyAt,
        'restore_dirty_phase': _kernel._restoreDirtyPhase,
        'restore_journal': _kernel._restoreJournalSummary(),
      };

  Future<List<KernelEvent>> replay({int? fromSeq, String? topic}) =>
      _kernel.replay(fromSeq: fromSeq, topic: topic);

  Future<List<KernelEvent>> search(String query) => _kernel.search(query);

  Future<int> fork(int fromSeq) => _kernel.fork(fromSeq);

  String composeSystemPrompt() => _kernel.composeSystemPrompt();

  int get mountedCount => _kernel.mountedCount;

  int get eventSeq => _kernel.eventSeq;

  /// 只给运行模式的 label 字符串，不给 RuntimeProfile 对象。
  String get modeLabel => _kernel._profile.mode.label;

  List<Map<String, dynamic>> listPages() => _kernel.listPages();

  /// 页面写操作须声明 'ui:open' 能力；owner 记为本插件，便于追溯与回收。
  Map<String, dynamic> addPage(String id, Map<String, dynamic> meta) {
    if (!_caps.contains('ui:open')) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 $_pluginId 未声明 ui:open，无权添加页面',
        'missing_caps': <String>['ui:open'],
      };
    }
    return _kernel.addPage(id, meta, owner: _pluginId);
  }

  Map<String, dynamic> removePage(String id) {
    if (!_caps.contains('ui:open')) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 $_pluginId 未声明 ui:open，无权删除页面',
        'missing_caps': <String>['ui:open'],
      };
    }
    return _kernel.removePage(id);
  }

  Map<String, dynamic> reorderPages(List<String> ids) {
    if (!_caps.contains('ui:open')) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 $_pluginId 未声明 ui:open，无权重排页面',
        'missing_caps': <String>['ui:open'],
      };
    }
    return _kernel.reorderPages(ids);
  }
}

class _ServiceEntry {
  _ServiceEntry(this.name, this.value, this.owner);
  final String name;
  final Object value;
  final String owner;
}

class _ControlEntry {
  _ControlEntry(this.action, this.handler, this.owner);
  final String action;
  final KernelControlAction handler;
  final String owner;
}

// ---------------------------------------------------------------------------
// 插件 / 插件树节点
// ---------------------------------------------------------------------------

enum PluginNodeState { mounted, failed }

/// 插件基类：声明依赖与产出，挂载时往 ctx 注册服务/工具/接缝/事件。
abstract class Plugin {
  String get id;
  String get name;
  String get version;
  String get description;
  /// 依赖的具名服务（挂载前校验，缺失即拒绝）。
  List<String> get requires => const <String>[];
  /// 声明贡献的接缝名（仅声明，用于 inspect）。
  List<String> get providesSeams => const <String>[];
  /// 分级（T0–T3）；默认 T1 official，保证仓库内置插件行为不变。
  PluginTier get tier => PluginTier.official;
  /// 声明可用的能力（接缝名）。为空＝不限制（兼容既有插件）。
  List<String> get caps => const <String>[];
  /// 地址函数（`pkg.mod:attr` 语义）；为空表示沿用 id。
  String? get address => null;
  Future<void> apply(PluginContext ctx);
  Future<void> dispose(PluginContext ctx) async {}
}

class PluginNode {
  PluginNode(this.plugin, this.parentId, this.source, this.configLayer);
  final Plugin plugin;
  final String? parentId;
  final String source; // bundle:<id> / profile / runtime
  final String configLayer;
  final List<String> children = <String>[];
  final List<Disposable> effects = <Disposable>[];
  PluginNodeState state = PluginNodeState.mounted;
  String error = '';
  String mountedAt = '';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': plugin.id,
        'name': plugin.name,
        'version': plugin.version,
        'description': plugin.description,
        'parent': parentId,
        'children': List<String>.of(children),
        'source': source,
        'config_layer': configLayer,
        'state': state.name,
        'error': error,
        'effects': effects.length,
        'provides_seams': plugin.providesSeams,
        'requires': plugin.requires,
        'mounted_at': mountedAt,
      };
}

// ---------------------------------------------------------------------------
// 配置分层：profile / bundle / patch
// ---------------------------------------------------------------------------

/// 组合包：一份可分发的"插件 id 顺序 + 配置 patch"。
class Bundle {
  Bundle(this.id, this.name, this.pluginIds, this.patch);
  final String id;
  final String name;
  final List<String> pluginIds;
  final Map<String, dynamic> patch;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'plugins': pluginIds,
        'patch': patch,
      };

  static Bundle fromJson(Map<String, dynamic> m) => Bundle(
        (m['id'] ?? '').toString(),
        (m['name'] ?? '').toString(),
        (m['plugins'] is List)
            ? (m['plugins'] as List).map((dynamic e) => e.toString()).toList()
            : <String>[],
        m['patch'] is Map
            ? Map<String, dynamic>.from(m['patch'] as Map)
            : <String, dynamic>{},
      );
}

/// 一项叠加后的配置：值 + 来源层。
class ConfigEntry {
  ConfigEntry(this.key, this.value, this.layer);
  final String key;
  final Object? value;
  final String layer;
  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'value': value,
        'layer': layer,
      };
}

/// 运行模式（对齐 dsh 四种）：标准 / PTC 程序化工具调用 / 极简 / 创造。
enum RunMode { standard, ptc, minimal, creator }

extension RunModeX on RunMode {
  String get label => switch (this) {
        RunMode.standard => 'standard',
        RunMode.ptc => 'ptc',
        RunMode.minimal => 'minimal',
        RunMode.creator => 'creator',
      };
  String get description => switch (this) {
        RunMode.standard => '完整工具组合，日常默认',
        RunMode.ptc => '程序化工具调用：一段代码组合多轮调用',
        RunMode.minimal => '只留 shell + 文件编辑，最小能力环境',
        RunMode.creator => '内存试验插件、组合新模式',
      };
  static RunMode parse(String s) => switch (s) {
        'ptc' => RunMode.ptc,
        'minimal' => RunMode.minimal,
        'creator' => RunMode.creator,
        _ => RunMode.standard,
      };
}

/// 具名组装：列出 bundles、自身 patch；home/runtime patch 由内核持有。
class RuntimeProfile {
  RuntimeProfile(this.id, this.name, this.mode, this.bundles, this.patch);
  final String id;
  final String name;
  RunMode mode;
  final List<Bundle> bundles;
  final Map<String, dynamic> patch;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'mode': mode.label,
        'bundles': bundles.map((Bundle b) => b.toJson()).toList(),
        'patch': patch,
      };
}

// ---------------------------------------------------------------------------
// 插件内核
// ---------------------------------------------------------------------------

/// 内核主类：插件树 + 接缝 + 服务 + 事件 + 配置叠加 + append-only 日志。
class PluginKernel {
  PluginKernel({
    required this.persistence,
    this.toolRegistry,
    this.onHotEvent,
    this.onBeforeMount,
  });

  final KernelPersistence persistence;
  /// 真实工具注册表（由 EmbeddedBackend 注入，插件可往里注册工具）。
  final ToolRegistry? toolRegistry;
  /// 可选的实时事件回调（只读桥接，绝不改动流式 token 的 hot-path）。
  final void Function(String topic, Map<String, dynamic> data)? onHotEvent;
  /// 挂载前钩子（可选）：用于「装插件前自动快照」。
  /// 默认 null＝不改变既有行为；钩子抛异常即拒绝挂载，不静默继续。
  Future<void> Function(String pluginId, Map<String, dynamic> info)? onBeforeMount;

  /// 调用守卫（G2 仲裁）：null＝不拦截；返回 false 即拒绝本次调用。
  InvokeGuard? invokeGuard;

  /// 接缝 → 需要的 capability 令牌（G2）。默认见 [defaultSeamCaps]；
  /// 一旦配置即强制，root 调用方（UI）除外。
  final Map<String, List<String>> seamCaps = defaultSeamCaps();

  /// 内核态快照（G5）：装配结果可回退，最多保留 [snapshotLimit] 份。
  final List<KernelSnapshot> _kernelSnapshots = <KernelSnapshot>[];
  int snapshotLimit = 20;

  /// 回退过程中不再触发挂载前钩子，避免快照递归。
  bool _restoring = false;

  /// 快照 id 单调递增计数器（round14）：旧 id 用 `_kernelSnapshots.length + 1`
  /// + 毫秒戳，上限淘汰（20 份删最旧）后长度回落，同一毫秒内两次 capture 会
  /// 撞 id；计数器只增不减，彻底消除碰撞（进程内唯一；快照只在内存）。
  int _snapshotSeq = 0;

  /// 回退脏标志（round14）：restoreSnapshot 任一变异阶段失败即置真，直到
  /// 三条出路之一清脏（重试同一快照成功 / 回滚到回退前备份成功 /
  /// resolve_dirty 显式确认）。round16：boot 失败（挂载/卸载失败、启动快
  /// 照预检失败）同样置真（journal phase 'boot_dirty'）。round18：脏态
  /// 跨重启持久化——置脏/清脏时随 _persistConfig 一起写入 kernel_config.json
  /// 的 restore_dirty 键（dirty/reason/at/phase），启动时先恢复（见
  /// _restorePersistedDirty）；脏记录损坏按干净处理并记审计事件，不挡启动。
  /// 内存语义不变。唯一例外：restoreSnapshot 变异开始时的瞬时置脏
  /// （“正在回退到快照 …”）不落盘——进程崩溃时它随进程消失，磁盘保留此前
  /// 已落盘的脏态（失败由 _failRestore 落盘，成功由成功路径清盘）。
  bool _restoreDirty = false;
  String _restoreDirtyReason = '';

  /// round18：置脏时间（ISO 8601，置脏收口写入）与置脏来源 phase
  /// （'boot' = 启动标脏，'restore' = 回退失败）；清脏时与 reason 一起清空。
  String _restoreDirtyAt = '';
  String _restoreDirtyPhase = '';

  /// 回退 journal（Map，不新增类型）：目标快照、回退前备份、当前阶段、
  /// 已完成卸载/挂载、失败插件与阶段、时间戳。失败时随结构化结果返回，
  /// describe()/status 可读摘要。round16：启动标脏复用同一张 journal，
  /// 另记 failed_mounts/failed_unmounts/boot_errors（见
  /// _markBootDirtyIfNeeded）。
  Map<String, dynamic> _restoreJournal = <String, dynamic>{};

  final Map<String, _ServiceEntry> _services = <String, _ServiceEntry>{};
  final Map<String, CapabilitySeam> _seams = <String, CapabilitySeam>{};
  final Map<String, _ControlEntry> _controlActions = <String, _ControlEntry>{};
  final Map<String, PromptSectionBuilder> _promptSections =
      <String, PromptSectionBuilder>{};
  final Map<String, PluginNode> _nodes = <String, PluginNode>{};
  final KernelEventBus _bus = KernelEventBus();
  final Map<String, Plugin> _registry = <String, Plugin>{};

  // ---- 自定义能力容器（与插件注册共用，action 与 ctx.register* 真实读写同一份）----
  final List<KernelPage> _pages = <KernelPage>[];
  final Map<String, Map<String, dynamic>> _widgetSlots =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, String>> _textOverrides =
      <String, Map<String, String>>{};
  final Map<String, Map<String, dynamic>> _permissionPolicies =
      <String, Map<String, dynamic>>{};

  int _seq = 0;
  bool _booted = false;
  late RuntimeProfile _profile;
  Map<String, dynamic> _homePatch = <String, dynamic>{};
  Map<String, dynamic> _runtimePatch = <String, dynamic>{};
  /// 各模式启用的插件 id（null=全部）。切换模式会真实挂载/卸载。
  final Map<RunMode, Set<String>?> _modePlugins = <RunMode, Set<String>?>{};

  bool get booted => _booted;
  RuntimeProfile get profile => _profile;
  int get mountedCount =>
      _nodes.values.where((PluginNode n) => n.state == PluginNodeState.mounted).length;
  int get seamCount => _seams.length;
  int get eventSeq => _seq;

  CapabilitySeam _ensureSeam(String name, String definition) =>
      _seams.putIfAbsent(name, () => CapabilitySeam(name, definition));

  /// 注册一个可挂载插件到内核目录（不立即挂载）。
  void registerPlugin(Plugin plugin) => _registry[plugin.id] = plugin;

  /// 取已挂载节点对应的插件（只读视图，供能力判定使用）。
  Plugin? pluginOf(String pluginId) => _nodes[pluginId]?.plugin;

  /// 设置某运行模式允许的插件集合（null 表示该模式不裁剪）。
  void defineModePlugins(RunMode mode, Set<String>? ids) =>
      _modePlugins[mode] = ids;

  /// 发布事件：先类型化派发，再只追加进会话日志，再可选只读外送。
  KernelEvent emit(String topic, String source, Map<String, dynamic> data) {
    final KernelEvent ev = _bus.emit(topic, source, data, ++_seq);
    unawaited(_persistEvent(ev.toJson()));
    final void Function(String, Map<String, dynamic>)? cb = onHotEvent;
    if (cb != null) cb(topic, ev.toJson());
    return ev;
  }

  /// 事件落盘尽力而为：无论注入的持久化实现是否抛错，都不让它变成
  /// 未捕获异步异常。类型化派发与内存事件流已在 emit 中真实生效，
  /// 落盘失败只是回放少一行，绝不崩掉常驻内核。
  Future<void> _persistEvent(Map<String, dynamic> json) async {
    try {
      await persistence.appendEvent(json);
    } on Object {
      // 如实吞掉，见上方注释。
    }
  }

  /// 装配：读盘 → 建 profile → 按 bundle 顺序挂载 → 应用模式裁剪 → 落盘。
  Future<void> boot({
    required List<Plugin> builtinPlugins,
    required RuntimeProfile defaultProfile,
  }) async {
    for (final Plugin p in builtinPlugins) {
      registerPlugin(p);
    }
    final Map<String, dynamic> saved = await persistence.readConfig();
    // round18：先恢复上轮落盘的脏态（跨重启持久化），再走本次装配——恢复
    // 必须在首个 _persistConfig（_applyProfile 内）之前，否则装配落盘会
    // 把磁盘上的旧脏键冲掉。脏记录损坏按干净处理（见 _restorePersistedDirty）。
    _restorePersistedDirty(saved);
    _profile = _profileFromConfig(saved, defaultProfile);
    _homePatch = saved['home_patch'] is Map
        ? Map<String, dynamic>.from(saved['home_patch'] as Map)
        : <String, dynamic>{};
    _runtimePatch = <String, dynamic>{};
    final List<KernelEvent> past = (await persistence.readEvents())
        .map(KernelEvent.fromJson)
        .toList();
    if (past.isNotEmpty) {
      _seq = past.map((KernelEvent e) => e.seq).reduce(
          (int a, int b) => a > b ? a : b);
    }
    _booted = true;
    emit('kernel.boot', 'kernel', <String, dynamic>{
      'profile': _profile.id,
      'mode': _profile.mode.label,
      'builtin': builtinPlugins.length,
    });
    // round16：启动标脏（脏标志启动缓解，见 docs/CODE-AUDIT-0.0.41.md §11）。
    //
    // 快照只在内存，重启后磁盘上没有可恢复的“最新快照”——boot 的“最新快照”
    // 就是本次装配结果本身：_applyProfile 之后立即 captureSnapshot('启动快照')，
    // 再对它跑 verifyDependencies（活态依赖核查）+ _preflightSnapshot（闭包预检，
    // 复用 round14 判定口径）。任一失败都标脏，但首轮挂载不阻塞：预检
    // 在 _applyProfile 之后跑，脏门禁又只在 handle() 入口，boot 直调
    // _applyProfile 不走 handle()，故脏态不可能卡住启动流程、不会死锁。
    // 出路复用既有 rollback（回滚到启动快照）/ resolve_dirty。round18：
    // _persistConfig 除 profile/home_patch 外还存 restore_dirty 脏态，启动时
    // 先恢复旧脏态（见 _restorePersistedDirty）；快照本身仍只在内存。
    final Map<String, dynamic> applied = await _applyProfile(reset: true);
    final Map<String, dynamic> bootSnapJson = captureSnapshot('启动快照');
    final String bootSnapId = (bootSnapJson['id'] ?? '').toString();
    final Map<String, dynamic> deps = verifyDependencies();
    final Map<String, dynamic> preflight = _preflightSnapshot(
        KernelSnapshot.fromJson(bootSnapJson));
    _markBootDirtyIfNeeded(
      applied: applied,
      deps: deps,
      preflight: preflight,
      bootSnapId: bootSnapId,
    );
    // round18：启动脏态落盘收口（_markBootDirtyIfNeeded 保持同步 void，
    // conformance G5d 按其签名切片，故落盘放 boot 这里 await）。干净启动
    // 不写盘；恢复的旧脏态若在，本次装配已由 _applyProfile 随配置写回，
    // 此处重写同一脏态只是刷新 updated_at，无内容变化。
    if (_restoreDirty) await _persistDirtyState();
  }

  /// round18：启动时恢复上轮落盘的脏态（跨重启持久化）。
  ///
  /// 约定（见 docs/CODE-AUDIT-0.0.41.md §13）：kernel_config.json 的
  /// restore_dirty 键为 {dirty: bool, reason: String, at: String,
  /// phase: 'boot'|'restore'}。dirty==true 且 reason 为字符串（可空）时
  /// 恢复脏态（journal phase 记 'restored_dirty'，便于 describe 追溯）；
  /// 其余形态一律按“干净”处理并记一条 kernel.dirty_record_ignored 审计
  /// 事件，不抛错、不挡启动。dirty==false 或无该键时静默干净（不留脏痕，
  /// 也不发事件）。整文件 JSON 损坏时 readConfig 已回退空态，本处不再处理。
  void _restorePersistedDirty(Map<String, dynamic> saved) {
    final Object? raw = saved['restore_dirty'];
    if (raw == null) return;
    if (raw is! Map) {
      emit('kernel.dirty_record_ignored', 'kernel', <String, dynamic>{
        'detail': 'restore_dirty 不是 Map，按干净处理',
      });
      return;
    }
    final Map<String, dynamic> rec = Map<String, dynamic>.from(raw);
    final Object? dirty = rec['dirty'];
    if (dirty == false) return; // 显式干净，不发事件。
    final Object? reason = rec['reason'];
    if (dirty != true || (reason != null && reason is! String)) {
      emit('kernel.dirty_record_ignored', 'kernel', <String, dynamic>{
        'detail': 'restore_dirty 格式不对（dirty 非 true 或 reason 非字符串），按干净处理',
      });
      return;
    }
    _restoreDirty = true;
    _restoreDirtyReason = (reason as String?) ?? '';
    _restoreDirtyAt = (rec['at'] as String?) ?? '';
    _restoreDirtyPhase = (rec['phase'] as String?) ?? 'restore';
    _restoreJournal = <String, dynamic>{
      'target_snapshot': '',
      'pre_restore_snapshot': '',
      'phase': 'restored_dirty',
      'failed_phase': _restoreDirtyPhase,
      'failed_plugin': '',
      'done_unmounts': <String>[],
      'done_mounts': <String>[],
      'failed_mounts': <Map<String, dynamic>>[],
      'failed_unmounts': <Map<String, dynamic>>[],
      'boot_errors': <String>[],
      'at': _restoreDirtyAt,
    };
  }

  /// round16：启动标脏收口。_applyProfile 的失败挂载/卸载与启动快照的
  /// 预检（verifyDependencies + _preflightSnapshot）任一失败都标脏、
  /// 写 journal、发事件；全部通过则什么都不做（干净启动不留脏痕）。
  /// 脏门禁只拦 handle() 改动类动作，boot 流程本身不受影响。
  /// round18：置脏后由 boot() 收口落盘（phase 'boot'，见 boot 末尾）——
  /// 本函数保持同步 void 签名（conformance G5d 按 'void _markBootDirtyIfNeeded('
  /// 切片），落盘尽力而为（见 _persistDirtyState）。
  void _markBootDirtyIfNeeded({
    required Map<String, dynamic> applied,
    required Map<String, dynamic> deps,
    required Map<String, dynamic> preflight,
    required String bootSnapId,
  }) {
    final List<Map<String, dynamic>> failedMounts =
        ((applied['failed_mounts'] as List?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((Map m) => Map<String, dynamic>.from(m))
            .toList();
    final List<Map<String, dynamic>> failedUnmounts =
        ((applied['failed_unmounts'] as List?) ?? const <dynamic>[])
            .whereType<Map>()
            .map((Map m) => Map<String, dynamic>.from(m))
            .toList();
    final List<String> bootErrors = <String>[];
    if (preflight['ok'] != true) {
      bootErrors.addAll(((preflight['errors'] as List?) ?? const <dynamic>[])
          .map((dynamic e) => e.toString()));
    }
    if (deps['ok'] != true) {
      for (final Map b in ((deps['broken'] as List?) ?? const <dynamic>[])
          .whereType<Map>()) {
        bootErrors.add('插件 ${b['plugin']} 依赖服务 ${b['missing_service']} '
            '在启动后核查中缺失');
      }
    }
    if (failedMounts.isEmpty &&
        failedUnmounts.isEmpty &&
        bootErrors.isEmpty) {
      return;
    }
    // 失败阶段：先发生的为准（挂载/卸载失败先于预检失败）。
    final String failedPhase =
        failedMounts.isNotEmpty || failedUnmounts.isNotEmpty
            ? 'boot_apply'
            : 'boot_verify';
    String failedPlugin = '';
    if (failedMounts.isNotEmpty) {
      failedPlugin = (failedMounts.first['plugin'] ?? '').toString();
    } else if (failedUnmounts.isNotEmpty) {
      failedPlugin = (failedUnmounts.first['plugin'] ?? '').toString();
    } else if (deps['ok'] != true) {
      final List<dynamic> broken =
          (deps['broken'] as List?) ?? const <dynamic>[];
      if (broken.isNotEmpty && broken.first is Map) {
        failedPlugin =
            ((broken.first as Map)['plugin'] ?? '').toString();
      }
    }
    final List<String> reasons = <String>[];
    if (failedMounts.isNotEmpty) {
      reasons.add('启动挂载失败：${failedMounts.map(
          (Map<String, dynamic> m) => '${m['plugin']}（${m['error']}）').join('；')}');
    }
    if (failedUnmounts.isNotEmpty) {
      reasons.add('启动卸载失败：${failedUnmounts.map(
          (Map<String, dynamic> m) => '${m['plugin']}（${m['error']}）').join('；')}');
    }
    if (bootErrors.isNotEmpty) {
      reasons.add('启动预检失败：${bootErrors.join('；')}');
    }
    _restoreDirty = true;
    _restoreDirtyReason = reasons.join('；');
    _restoreDirtyAt = DateTime.now().toIso8601String();
    _restoreDirtyPhase = 'boot';
    _restoreJournal = <String, dynamic>{
      'target_snapshot': bootSnapId,
      'pre_restore_snapshot': '',
      'phase': 'boot_dirty',
      'failed_phase': failedPhase,
      'failed_plugin': failedPlugin,
      // 启动时实际挂上的插件（_applyProfile 不报告成功卸载，
      // done_unmounts 留空，不编造）。
      'done_unmounts': <String>[],
      'done_mounts': _nodes.keys.toList(),
      'failed_mounts': failedMounts,
      'failed_unmounts': failedUnmounts,
      'boot_errors': bootErrors,
      'at': DateTime.now().toIso8601String(),
    };
    if (failedMounts.isNotEmpty || failedUnmounts.isNotEmpty) {
      emit('kernel.boot_mount_failed', 'kernel', <String, dynamic>{
        'failed_mounts': failedMounts,
        'failed_unmounts': failedUnmounts,
        'snapshot': bootSnapId,
        'dirty': true,
      });
    }
    if (bootErrors.isNotEmpty) {
      emit('kernel.boot_dirty', 'kernel', <String, dynamic>{
        'phase': 'boot_verify',
        'errors': bootErrors,
        'snapshot': bootSnapId,
        'dirty': true,
      });
    }
    // round18：落盘由 boot() 在调用本函数后收口（本函数保持同步）。
  }

  RuntimeProfile _profileFromConfig(
      Map<String, dynamic> saved, RuntimeProfile fallback) {
    if (saved['profile'] is Map) {
      final Map<String, dynamic> p =
          Map<String, dynamic>.from(saved['profile'] as Map);
      final List<Bundle> bundles = (p['bundles'] is List)
          ? (p['bundles'] as List)
              .whereType<Map>()
              .map((Map<dynamic, dynamic> m) =>
                  Bundle.fromJson(Map<String, dynamic>.from(m)))
              .toList()
          : fallback.bundles;
      return RuntimeProfile(
        (p['id'] ?? fallback.id).toString(),
        (p['name'] ?? fallback.name).toString(),
        RunModeX.parse((p['mode'] ?? fallback.mode.label).toString()),
        bundles,
        p['patch'] is Map
            ? Map<String, dynamic>.from(p['patch'] as Map)
            : fallback.patch,
      );
    }
    return fallback;
  }

  /// 按当前 profile 的 bundles 顺序挂载，再按模式裁剪。
  ///
  /// round14：返回应用结果（此前 mount/unmount 的返回值被直接丢弃，
  /// _setMode 无法知道模式切换是否真正落完）。失败项只收集、不抛——
  /// 调用方（_setMode）决定是结构化返回还是继续；round16：boot 同样消费
  /// 返回值，失败挂载/卸载写入 journal 并发事件、标脏（见
  /// _markBootDirtyIfNeeded），首轮挂载本身不阻塞。
  Future<Map<String, dynamic>> _applyProfile({required bool reset}) async {
    final List<Map<String, dynamic>> failedMounts = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> failedUnmounts =
        <Map<String, dynamic>>[];
    if (reset) {
      for (final String id in List<String>.of(_nodes.keys)) {
        final Map<String, dynamic> r = await unmount(id, reason: 'reset');
        if (r['ok'] != true) {
          failedUnmounts.add(
              <String, dynamic>{'plugin': id, 'error': r['error']});
        }
      }
    }
    final Set<String>? allowed = _modePlugins[_profile.mode];
    for (final Bundle bundle in _profile.bundles) {
      for (final String pid in bundle.pluginIds) {
        if (allowed != null && !allowed.contains(pid)) continue;
        if (_nodes.containsKey(pid)) continue;
        final Map<String, dynamic> r = await mount(
          pid,
          source: 'bundle:${bundle.id}',
          configLayer: 'bundle',
        );
        if (r['ok'] != true) {
          failedMounts.add(
              <String, dynamic>{'plugin': pid, 'error': r['error']});
        }
      }
    }
    // 模式裁剪：卸载不在允许集合里的插件（真实生效，不是标记）。
    if (allowed != null) {
      for (final String id in List<String>.of(_nodes.keys)) {
        if (!allowed.contains(id)) {
          final Map<String, dynamic> r =
              await unmount(id, reason: 'mode:${_profile.mode.label}');
          if (r['ok'] != true) {
            failedUnmounts.add(
                <String, dynamic>{'plugin': id, 'error': r['error']});
          }
        }
      }
    }
    await _persistConfig();
    return <String, dynamic>{
      'ok': failedMounts.isEmpty && failedUnmounts.isEmpty,
      'failed_mounts': failedMounts,
      'failed_unmounts': failedUnmounts,
    };
  }

  /// round18：脏态落盘收口（尽力而为）。脏标志随 _persistConfig 一起写入
  /// 同一 kernel_config.json（见 _persistConfig）；写盘失败只发
  /// kernel.dirty_persist_failed 审计事件，不抛错、不回滚内存脏态——
  /// writeConfig 是 tmp+rename 原子写，失败时旧文件完好，profile/home_patch
  /// 不受损；调用方重试一次普通写盘（如 set_patch）即可恢复同步。
  Future<void> _persistDirtyState() async {
    try {
      await _persistConfig();
    } on Object catch (e) {
      emit('kernel.dirty_persist_failed', 'kernel', <String, dynamic>{
        'error': '$e',
        'dirty': _restoreDirty,
      });
    }
  }

  Future<void> _persistConfig() async {
    final Map<String, dynamic> config = <String, dynamic>{
      'profile': _profile.toJson(),
      'home_patch': _homePatch,
      'updated_at': DateTime.now().toIso8601String(),
    };
    // round18：脏态随同一文件落盘（脏时写 restore_dirty 键：dirty/reason/
    // at/phase；干净时不写该键——干净启动不留脏痕，清脏时同一收口把键清掉）。
    // 原子 tmp+rename 写：失败时旧文件完好，profile/home_patch 不受损。
    if (_restoreDirty) {
      config['restore_dirty'] = <String, dynamic>{
        'dirty': true,
        'reason': _restoreDirtyReason,
        'at': _restoreDirtyAt,
        'phase': _restoreDirtyPhase,
      };
    }
    await persistence.writeConfig(config);
  }

  /// 挂载一个插件：依赖校验 → 子作用域 apply → 收集 effects → 入树。
  /// 任何一步失败都撤销已产生的 effects，绝不留下半挂载状态。
  Future<Map<String, dynamic>> mount(String pluginId,
      {String? parentId,
      String source = 'runtime',
      String configLayer = 'runtime'}) async {
    final Plugin? plugin = _registry[pluginId];
    if (plugin == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 $pluginId 未注册到内核目录',
      };
    }
    if (_nodes.containsKey(pluginId)) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 $pluginId 已挂载',
      };
    }
    // 依赖校验：requires 的服务必须由已挂载插件提供。
    for (final String dep in plugin.requires) {
      if (!_services.containsKey(dep)) {
        return <String, dynamic>{
          'ok': false,
          'error': '插件 $pluginId 依赖服务 $dep 尚未挂载，拒绝挂载（不假装就绪）',
          'missing_dependency': dep,
        };
      }
    }
    // G1：T3 第三方插件未声明能力即拒绝（fail-closed）。
    if (plugin.tier == PluginTier.thirdParty && plugin.caps.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 $pluginId 为 T3 第三方且未声明 caps，拒绝挂载（fail-closed）',
      };
    }
    // G4：声明了地址就必须可解析，非法即拒绝挂载。
    final String? declaredAddress = plugin.address;
    if (declaredAddress != null) {
      try {
        parsePluginAddress(declaredAddress);
      } on FormatException catch (e) {
        return <String, dynamic>{
          'ok': false,
          'error': '插件 $pluginId 地址非法：$declaredAddress（$e）',
        };
      }
    }
    final Future<void> Function(String, Map<String, dynamic>)? before = onBeforeMount;
    if (before != null && !_restoring) {
      try {
        await before(pluginId, <String, dynamic>{
          'tier': plugin.tier.wire,
          'address': plugin.address ?? pluginId,
          'provides_seams': plugin.providesSeams,
          'source': source,
        });
      } on Object catch (e) {
        return <String, dynamic>{'ok': false, 'error': '挂载前钩子拒绝：$e'};
      }
    }
    final List<Disposable> effects = <Disposable>[];
    final PluginContext scope = PluginContext._(this, effects, pluginId,
        caps: plugin.caps, tier: plugin.tier);
    final PluginNode node =
        PluginNode(plugin, parentId, source, configLayer);
    try {
      await plugin.apply(scope);
      node.effects.addAll(effects);
      node.mountedAt = DateTime.now().toIso8601String();
      _nodes[pluginId] = node;
      if (parentId != null && _nodes[parentId] != null) {
        _nodes[parentId]!.children.add(pluginId);
      }
      emit('plugin.mounted', 'kernel', <String, dynamic>{
        'plugin': pluginId,
        'source': source,
        'effects': effects.length,
        'provides': plugin.providesSeams,
      });
      return <String, dynamic>{
        'ok': true,
        'plugin': pluginId,
        'effects': effects.length,
      };
    } on Object catch (e) {
      // 可逆：逆序撤销所有已注册效果。
      for (final Disposable d in effects.reversed) {
        try {
          d();
        } on Object {
          // 撤销异常不掩盖挂载失败原因。
        }
      }
      node.state = PluginNodeState.failed;
      node.error = '$e';
      emit('plugin.mount_failed', 'kernel', <String, dynamic>{
        'plugin': pluginId,
        'error': '$e',
      });
      return <String, dynamic>{'ok': false, 'error': '挂载失败：$e'};
    }
  }

  /// 卸载：先递归卸载子节点，再逆序撤销自身 effects（真实可逆）。
  Future<Map<String, dynamic>> unmount(String pluginId,
      {String reason = 'user'}) async {
    final PluginNode? node = _nodes[pluginId];
    if (node == null) {
      return <String, dynamic>{'ok': false, 'error': '插件 $pluginId 未挂载'};
    }
    for (final String child in List<String>.of(node.children)) {
      await unmount(child, reason: 'parent:$pluginId');
    }
    final PluginContext scope = PluginContext._(this, null, pluginId,
        caps: node.plugin.caps, tier: node.plugin.tier);
    try {
      await node.plugin.dispose(scope);
    } on Object {
      // dispose 异常不阻断 effects 撤销。
    }
    for (final Disposable d in List<Disposable>.of(node.effects).reversed) {
      try {
        d();
      } on Object {
        // 单个撤销失败不影响其余撤销。
      }
    }
    final String? parentId = node.parentId;
    if (parentId != null && _nodes[parentId] != null) {
      _nodes[parentId]!.children.remove(pluginId);
    }
    _nodes.remove(pluginId);
    emit('plugin.unmounted', 'kernel', <String, dynamic>{
      'plugin': pluginId,
      'reason': reason,
      'effects': node.effects.length,
    });
    return <String, dynamic>{'ok': true, 'plugin': pluginId, 'reason': reason};
  }

  /// 原子热替换：用 [replacement] 替换一个已挂载插件（万物皆可换）。
  ///
  /// 事务语义：卸载旧插件（逆序撤销 effects）→ 注册新插件 → 在同一挂载点
  /// 挂载新插件。任一步失败都尝试把旧插件挂回去，绝不留下「旧的没了、新的
  /// 也没上」的半状态。替换插件须声明相同 id（换实现不换槽位）。
  Future<Map<String, dynamic>> hotSwap(
      String pluginId, Plugin replacement) async {
    final PluginNode? old = _nodes[pluginId];
    if (old == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 $pluginId 未挂载，无法热替换',
      };
    }
    if (replacement.id != pluginId) {
      return <String, dynamic>{
        'ok': false,
        'error': '替换插件 id(${replacement.id}) 必须等于目标槽位($pluginId)',
      };
    }
    final String? parentId = old.parentId;
    final String source = old.source;
    final String layer = old.configLayer;
    final Plugin previous = old.plugin;

    final Map<String, dynamic> off = await unmount(pluginId, reason: 'hot-swap');
    if (off['ok'] != true) {
      return <String, dynamic>{'ok': false, 'error': '卸载旧插件失败：${off['error']}'};
    }
    registerPlugin(replacement);
    final Map<String, dynamic> on = await mount(
      pluginId,
      parentId: parentId,
      source: source,
      configLayer: layer,
    );
    if (on['ok'] == true) {
      emit('plugin.hot_swapped', 'kernel', <String, dynamic>{
        'plugin': pluginId,
        'from_version': previous.version,
        'to_version': replacement.version,
      });
      return <String, dynamic>{
        'ok': true,
        'plugin': pluginId,
        'from_version': previous.version,
        'to_version': replacement.version,
      };
    }

    // 回滚：重新挂载旧插件，恢复原槽位。
    registerPlugin(previous);
    final Map<String, dynamic> rollback = await mount(
      pluginId,
      parentId: parentId,
      source: source,
      configLayer: layer,
    );
    emit('plugin.hot_swap_rolled_back', 'kernel', <String, dynamic>{
      'plugin': pluginId,
      'reason': on['error'],
      'rollback_ok': rollback['ok'] == true,
    });
    return <String, dynamic>{
      'ok': false,
      'error': '热替换失败已回滚：${on['error']}',
      'rollback_ok': rollback['ok'] == true,
    };
  }

  /// 依赖健康检查：遍历已挂载插件，检查每个 requires 服务是否仍存在。
  /// 某个插件被卸载后，依赖它的插件可能处于「仍挂载但依赖已缺失」的不一致态；
  /// 本方法如实报告，供 UI / 控制域发现并修复，绝不静默假装健康。
  Map<String, dynamic> verifyDependencies() {
    final List<Map<String, dynamic>> broken = <Map<String, dynamic>>[];
    for (final MapEntry<String, PluginNode> e in _nodes.entries) {
      for (final String dep in e.value.plugin.requires) {
        if (!_services.containsKey(dep)) {
          broken.add(<String, dynamic>{
            'plugin': e.key,
            'missing_service': dep,
          });
        }
      }
    }
    final Map<String, dynamic> result = <String, dynamic>{
      'ok': broken.isEmpty,
      'checked': _nodes.length,
      'broken': broken,
    };
    emit('kernel.dependencies_verified', 'kernel', result);
    return result;
  }

  /// 切换接缝当前 provider：所有 consumer 一起搬过去。
  Future<Map<String, dynamic>> setProvider(
      String seamName, String providerId) async {
    final CapabilitySeam? s = _seams[seamName];
    if (s == null) {
      return <String, dynamic>{'ok': false, 'error': '接缝 $seamName 不存在'};
    }
    if (!s.providers.containsKey(providerId)) {
      return <String, dynamic>{
        'ok': false,
        'error': '接缝 $seamName 无 provider $providerId',
        'available': s.providers.keys.toList(),
      };
    }
    final String previous = s.activeProviderId;
    s.activeProviderId = providerId;
    emit('seam.provider_changed', 'kernel', <String, dynamic>{
      'seam': seamName,
      'from': previous,
      'to': providerId,
      'affected_consumers': List<String>.of(s.consumers),
    });
    return <String, dynamic>{
      'ok': true,
      'seam': seamName,
      'previous': previous,
      'active': providerId,
      'affected_consumers': List<String>.of(s.consumers),
    };
  }

  /// 通过当前激活 provider 真实调用一个接缝能力。
  ///
  /// round13 可信身份：调用方传入的 `caps` 已废弃（保留签名兼容，永不
  /// 参与鉴权）——能力一律查内核内登记的身份：`caller` 是已挂载插件 id
  /// 时用该插件声明的 caps 与 tier；`caller == 'ui'` 仅当 [trustedRoot]
  /// 为真（进程内 UI 直连）时才算 root，否则按未表明身份处理；未知
  /// caller 名直接拒绝。缺省 caller 仍为 [kRootCaller]（测试与
  /// embedded_backend 直调的约定），但缺省 trustedRoot=false 时它会被
  /// 降级为未表明身份——直调方须显式传 trustedRoot:true 才能走 root。
  Future<Map<String, dynamic>> invoke(String seamName, String method,
      Map<String, dynamic> args,
      {String caller = kRootCaller, List<String> caps = const <String>[],
      bool trustedRoot = false}) async {
    final CapabilitySeam? s = _seams[seamName];
    if (s == null) {
      return <String, dynamic>{'ok': false, 'error': '接缝 $seamName 不存在'};
    }
    // round13：先定可信身份，再仲裁。'ui' 自称只有可信根路径才认。
    final String effectiveCaller =
        (caller == kRootCaller && !trustedRoot) ? kUntrustedCaller : caller;
    // G2 仲裁：root（可信 UI）直通；其余调用方按登记身份查能力。
    if (effectiveCaller != kRootCaller) {
      final Plugin? registered = _nodes[effectiveCaller]?.plugin;
      if (registered == null) {
        emit('seam.denied', 'kernel', <String, dynamic>{
          'seam': seamName,
          'caller': effectiveCaller,
          'reason': 'unknown_caller',
        });
        return <String, dynamic>{
          'ok': false,
          'error': '未知调用方 $effectiveCaller：未在内核登记的插件身份无权调用接缝 $seamName',
        };
      }
      final List<String> need = seamCaps[seamName] ?? const <String>[];
      final List<String> effectiveCaps = registered.caps;
      final List<String> missing =
          need.where((String c) => !effectiveCaps.contains(c)).toList();
      if (registered.tier == PluginTier.thirdParty && effectiveCaps.isEmpty) {
        emit('seam.denied', 'kernel', <String, dynamic>{
          'seam': seamName,
          'caller': effectiveCaller,
          'missing_caps': need,
        });
        return <String, dynamic>{
          'ok': false,
          'error': 'T3 插件 $effectiveCaller 未声明 caps，无权调用接缝 $seamName',
          'missing_caps': need,
        };
      }
      if (missing.isNotEmpty) {
        emit('seam.denied', 'kernel', <String, dynamic>{
          'seam': seamName,
          'caller': effectiveCaller,
          'missing_caps': missing,
        });
        return <String, dynamic>{
          'ok': false,
          'error': '调用方 $effectiveCaller 缺少能力令牌：$missing（接缝 $seamName）',
          'missing_caps': missing,
        };
      }
    }
    final InvokeGuard? guard = invokeGuard;
    if (guard != null) {
      bool allowed = false;
      try {
        allowed = await guard(seamName, method, args, effectiveCaller);
      } on Object catch (e) {
        return <String, dynamic>{'ok': false, 'error': '调用守卫异常，拒绝执行：$e'};
      }
      if (!allowed) {
        emit('seam.denied', 'kernel', <String, dynamic>{
          'seam': seamName,
          'caller': effectiveCaller,
          'reason': 'guard_rejected',
        });
        return <String, dynamic>{
          'ok': false,
          'error': '调用被守卫拒绝：$seamName.$method',
        };
      }
    }
    final SeamProviderEntry? p = s.providers[s.activeProviderId];
    if (p == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '接缝 $seamName 未激活任何 provider（绝不伪造执行）',
      };
    }
    try {
      final Map<String, dynamic> result = await p.invoke(method, args);
      emit('seam.invoke', 'kernel', <String, dynamic>{
        'seam': seamName,
        'provider': p.id,
        'method': method,
        'ok': result['ok'] == true,
      });
      return <String, dynamic>{
        'ok': true,
        'seam': seamName,
        'provider': p.id,
        'method': method,
        'result': result,
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '接缝调用失败：$e'};
    }
  }

  /// 组装所有已注册的提示词片段（系统提示词插件化的产物）。
  String composeSystemPrompt() {
    final StringBuffer buf = StringBuffer();
    for (final MapEntry<String, PromptSectionBuilder> e
        in _promptSections.entries) {
      try {
        final String text = e.value();
        if (text.trim().isNotEmpty) buf.writeln(text.trim());
      } on Object {
        // 单段构造失败不拖垮整体，如实跳过。
      }
    }
    return buf.toString().trim();
  }

  /// 四层配置叠加：bundles → profile patch → home patch → runtime patch。
  List<ConfigEntry> composeConfig() {
    final Map<String, ConfigEntry> out = <String, ConfigEntry>{};
    void layer(String name, Map<String, dynamic> patch) {
      patch.forEach((String k, dynamic v) {
        out[k] = ConfigEntry(k, v, name);
      });
    }
    for (final Bundle b in _profile.bundles) {
      layer('bundle:${b.id}', b.patch);
    }
    layer('profile:${_profile.id}', _profile.patch);
    layer('home', _homePatch);
    layer('runtime', _runtimePatch);
    return out.values.toList();
  }

  Map<String, dynamic> dumpConfig() => <String, dynamic>{
        'profile': _profile.toJson(),
        'home_patch': _homePatch,
        'runtime_patch': _runtimePatch,
        'mode': _profile.mode.label,
        'layers': <String>[
          ..._profile.bundles.map((Bundle b) => 'bundle:${b.id}'),
          'profile:${_profile.id}',
          'home',
          'runtime',
        ],
        'entries': composeConfig()
            .map((ConfigEntry e) => e.toJson())
            .toList(),
      };

  /// append-only 会话日志：回放 / 检索 / 分叉（对齐 dsh "同一份事件流"）。
  Future<List<KernelEvent>> replay({int? fromSeq, String? topic}) async {
    final List<KernelEvent> all = (await persistence.readEvents())
        .map(KernelEvent.fromJson)
        .toList();
    return all
        .where((KernelEvent e) =>
            (fromSeq == null || e.seq >= fromSeq) &&
            (topic == null || e.topic == topic))
        .toList();
  }

  Future<List<KernelEvent>> search(String query) async {
    final List<KernelEvent> all = await replay();
    final String q = query.toLowerCase();
    return all
        .where((KernelEvent e) =>
            e.topic.toLowerCase().contains(q) ||
            jsonEncode(e.data).toLowerCase().contains(q))
        .toList();
  }

  /// fork：以历史事件为前缀追加一条分叉标记，返回新的分叉点 seq。
  Future<int> fork(int fromSeq) async {
    final KernelEvent ev = emit('session.fork', 'kernel', <String, dynamic>{
      'from_seq': fromSeq,
    });
    return ev.seq;
  }

  // ---- 自定义能力：查询与真实写入（action 与 ctx.register* 共用同一份容器）----

  List<Map<String, dynamic>> listPages() =>
      _pages.map((KernelPage p) => p.toJson()).toList();

  Map<String, dynamic> addPage(String id, Map<String, dynamic> meta,
      {String owner = 'runtime'}) {
    if (id.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '页面 id 不能为空'};
    }
    if (_pages.any((KernelPage p) => p.id == id)) {
      return <String, dynamic>{'ok': false, 'error': '页面 $id 已存在'};
    }
    final KernelPage page =
        KernelPage(id, Map<String, dynamic>.from(meta), owner);
    _pages.add(page);
    emit('kernel.page_added', 'kernel', <String, dynamic>{'page': id});
    return <String, dynamic>{'ok': true, 'page': page.toJson()};
  }

  Map<String, dynamic> removePage(String id) {
    final int idx = _pages.indexWhere((KernelPage p) => p.id == id);
    if (idx < 0) {
      return <String, dynamic>{'ok': false, 'error': '页面 $id 不存在'};
    }
    final KernelPage removed = _pages.removeAt(idx);
    emit('kernel.page_removed', 'kernel', <String, dynamic>{'page': id});
    return <String, dynamic>{'ok': true, 'page': removed.toJson()};
  }

  /// ids 必须是当前页面 id 的一个无重复排列；真实改写顺序，不是改排序标记。
  Map<String, dynamic> reorderPages(List<String> ids) {
    final Set<String> current = _pages.map((KernelPage p) => p.id).toSet();
    if (ids.length != _pages.length ||
        ids.toSet().length != ids.length ||
        !ids.every(current.contains)) {
      return <String, dynamic>{
        'ok': false,
        'error': 'reorder 的 ids 必须是当前页面 id 的一个无重复排列',
        'current': current.toList(),
      };
    }
    final Map<String, KernelPage> byId = <String, KernelPage>{
      for (final KernelPage p in _pages) p.id: p,
    };
    _pages.setAll(0, ids.map((String id) => byId[id]!).toList());
    emit('kernel.page_reordered', 'kernel', <String, dynamic>{'order': ids});
    return <String, dynamic>{'ok': true, 'order': listPages()};
  }

  List<Map<String, dynamic>> listWidgetSlots() => _widgetSlots.entries
      .map((MapEntry<String, Map<String, dynamic>> e) => <String, dynamic>{
            'id': e.key,
            'meta': Map<String, dynamic>.from(e.value),
          })
      .toList();

  Map<String, dynamic> setTextOverride(
      String locale, String key, String value) {
    if (locale.isEmpty || key.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': 'locale 与 key 不能为空'};
    }
    _textOverrides.putIfAbsent(locale, () => <String, String>{})[key] = value;
    emit('kernel.text_override_set', 'kernel', <String, dynamic>{
      'locale': locale,
      'key': key,
    });
    return <String, dynamic>{
      'ok': true,
      'entry': <String, dynamic>{'locale': locale, 'key': key, 'value': value},
    };
  }

  /// 真实返回覆盖值；未覆盖返回 null，绝不编造默认文案。
  String? getTextOverride(String locale, String key) =>
      _textOverrides[locale]?[key];

  List<Map<String, dynamic>> listTextOverrides() {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    _textOverrides.forEach((String locale, Map<String, String> byKey) {
      byKey.forEach((String key, String value) {
        out.add(<String, dynamic>{'locale': locale, 'key': key, 'value': value});
      });
    });
    return out;
  }

  Map<String, dynamic> setPermissionPolicy(
      String id, Map<String, dynamic> policy) {
    if (id.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '权限策略 id 不能为空'};
    }
    _permissionPolicies[id] = Map<String, dynamic>.from(policy);
    emit('kernel.permission_policy_set', 'kernel', <String, dynamic>{'id': id});
    return <String, dynamic>{
      'ok': true,
      'entry': <String, dynamic>{
        'id': id,
        'policy': Map<String, dynamic>.from(_permissionPolicies[id]!),
      },
    };
  }

  List<Map<String, dynamic>> listPermissionPolicies() =>
      _permissionPolicies.entries
          .map((MapEntry<String, Map<String, dynamic>> e) => <String, dynamic>{
                'id': e.key,
                'policy': Map<String, dynamic>.from(e.value),
              })
          .toList();

  // ---- 控制域动作分发（plugin_kernel）----

  /// 改动类控制动作：必须由 UI（root）显式发起。
  /// 只读动作（describe/status/tree/seams/modes/dump_config/pages-list/
  /// widget_slots/events/search/snapshots/compose_prompt 等）不受限。
  /// 'invoke' 不在此列——它走自己的仲裁（登记身份 + 调用守卫），
  /// 缺省 caller 时按未表明身份处理，见 'invoke' 分支。
  /// round13：snapshot/fork 也是改动（写快照/写分叉事件），一并入集。
  static const Set<String> _mutationActions = <String>{
    'mount',
    'unmount',
    'set_provider',
    'set_mode',
    'set_patch',
    'rollback',
    'snapshot',
    'fork',
    // round14：脏态人工出路（仅 trustedRoot，须显式 accept）。它本身是改动，
    // 但脏门禁对它豁免（否则脏了就永远清不掉）。
    'resolve_dirty',
  };

  /// 动作 owner 插件自身可执行的改动（须同时满足：pluginId 非空、动作
  /// 在白名单内、目标资源确属该插件）。trustedRoot 为真时不走这条路。
  static const Set<String> _ownerAllowedActions = <String>{
    'pages',
    'text_overrides',
    'permission_policies',
  };

  /// 是否改动类动作：静态改动集 + pages/text_overrides/permission_policies
  /// 的写分支 + default 控制动作分支（未知动作先按改动处理——读不到
  /// 东西也改不了东西，fail-closed）。已知只读动作不在此列。
  bool _isMutation(String action, Map<String, dynamic> p) {
    if (_mutationActions.contains(action)) return true;
    switch (action) {
      case 'pages':
        return <String>{'add', 'remove', 'reorder'}
            .contains((p['op'] ?? 'list').toString());
      case 'text_overrides':
        return (p['op'] ?? 'list').toString() == 'set';
      case 'permission_policies':
        return (p['op'] ?? 'list').toString() == 'set';
      case 'describe':
      case 'status':
      case 'tree':
      case 'seams':
      case 'modes':
      case 'dump_config':
      case 'widget_slots':
      case 'compose_prompt':
      case 'events':
      case 'search':
      case 'snapshots':
      case 'invoke':
        return false;
      default:
        // 插件贡献的控制动作与未知动作：一律按改动处理。
        return true;
    }
  }

  /// 改动门禁。`trustedRoot` 与 `pluginId` 是代码层参数（只由进程内
  /// 可信调用方传入），绝不从 payload 里读——payload 里的 caller/caps
  /// 只作展示，永不参与鉴权：'ui' 自称在不可信路径上等同于未表明身份。
  /// 放行条件：trustedRoot（进程内 UI 直连），或动作 owner 插件自身、
  /// 且动作在 allowlist 内、且目标资源归属该插件。
  bool _mutationAllowed(String action, Map<String, dynamic> p,
      bool trustedRoot, String? pluginId) {
    if (trustedRoot) return true;
    if (pluginId == null || pluginId.isEmpty) return false;
    if (_ownerAllowedActions.contains(action)) {
      return _ownsMutationTarget(action, p, pluginId);
    }
    // 插件贡献的控制动作：只有登记该动作的 owner 插件自身可调。
    final _ControlEntry? entry = _controlActions[action];
    if (entry != null) return entry.owner == pluginId;
    return false;
  }

  /// owner 路径的目标归属判定：pages 的 add 以调用方为 owner 落账，
  /// remove/reorder 只能动归属自己的已有页；text_overrides 与
  /// permission_policies 没有逐条 owner 记录，归属即“调用方身份由
  /// 代码层 pluginId 确立 + 动作在 allowlist 内”。
  bool _ownsMutationTarget(
      String action, Map<String, dynamic> p, String pluginId) {
    switch (action) {
      case 'pages':
        final String op = (p['op'] ?? 'list').toString();
        if (op == 'add') return true;
        if (op == 'remove') {
          final String id = (p['id'] ?? '').toString();
          for (final KernelPage page in _pages) {
            if (page.id == id) return page.owner == pluginId;
          }
          return false;
        }
        if (op == 'reorder') {
          return _pages.every((KernelPage e) => e.owner == pluginId);
        }
        return false;
      case 'text_overrides':
        return (p['op'] ?? 'list').toString() == 'set';
      case 'permission_policies':
        return (p['op'] ?? 'list').toString() == 'set';
      default:
        return false;
    }
  }

  /// 控制域动作分发。
  ///
  /// round13：`trustedRoot` 只由进程内 UI 直连路径（EmbeddedBackend
  /// dispatch → _onPluginKernel）传 true；TCP/stdio 桥接与任何直接
  /// handle 调用缺省为 false。`pluginId` 只由内核内可信调用方传——
  /// 它是动作 owner 插件的已登记身份，不是 payload 字段。
  Future<Map<String, dynamic>> handle(String action, Map<String, dynamic> p,
      {bool trustedRoot = false, String? pluginId}) async {
    // G2：改动类动作必须由 UI（root）显式发起，或由动作 owner 插件自身
    // 在 allowlist 内发起；省略身份即视为未表明身份，一律拒绝。唯一
    // 合法发送方是内核调试页（tga_kernel_page.dart，经 _call 统一带
    // caller: 'ui'，再由进程内 dispatch 标 trustedRoot）。
    if (_isMutation(action, p) &&
        !_mutationAllowed(action, p, trustedRoot, pluginId)) {
      emit('seam.denied', 'kernel', <String, dynamic>{
        'action': action,
        'caller': (p['caller'] ?? kUntrustedCaller).toString(),
        'reason': 'mutation_requires_root',
      });
      return <String, dynamic>{
        'ok': false,
        'error': '改动类动作 $action 须由 UI（root）发起，或由动作 owner 插件自身在 allowlist 内发起；未表明身份的调用方无权执行',
      };
    }
    // round14 脏门禁（round16：启动标脏同样走此门禁）：回退/启动失败置脏后，
    // 改动类动作一律拒绝，只留两条出路——rollback（重试同一快照 / 回滚到
    // 回退前备份 / 回滚到启动快照）与 resolve_dirty（仅 trustedRoot，
    // 显式确认接受当前半态）。只读动作与 invoke 不拦截；
    // 鉴权门禁在前，未表明身份的调用方仍先拿 mutation_requires_root。
    if (_restoreDirty &&
        _isMutation(action, p) &&
        action != 'rollback' &&
        action != 'resolve_dirty') {
      emit('seam.denied', 'kernel', <String, dynamic>{
        'action': action,
        'reason': 'restore_dirty',
        'journal': _restoreJournalSummary(),
      });
      return <String, dynamic>{
        'ok': false,
        'error': '内核处于回退脏态，改动类动作 $action 被拒绝：$_restoreDirtyReason。'
            '请先 rollback（重试同一快照或回滚到备份）或 resolve_dirty 显式确认接受',
        'dirty': true,
        'restore_dirty': true,
        'reason': _restoreDirtyReason,
        'journal': _restoreJournalSummary(),
      };
    }
    switch (action) {
      case 'describe':
      case 'status':
        return <String, dynamic>{
          'ok': true,
          'booted': _booted,
          'profile': _profile.id,
          'mode': _profile.mode.label,
          'mounted': mountedCount,
          'seams': _seams.length,
          'services': _services.length,
          'control_actions': _controlActions.length,
          'prompt_sections': _promptSections.length,
          'event_seq': _seq,
          // round14：脏态可见（只读动作不受限）。
          'restore_dirty': _restoreDirty,
          'restore_dirty_reason': _restoreDirtyReason,
          'restore_dirty_at': _restoreDirtyAt,
          'restore_dirty_phase': _restoreDirtyPhase,
          'restore_journal': _restoreJournalSummary(),
        };
      case 'tree':
        return <String, dynamic>{
          'ok': true,
          'nodes': _nodes.values.map((PluginNode n) => n.toJson()).toList(),
          'catalog': _registry.keys.toList(),
        };
      case 'seams':
        return <String, dynamic>{
          'ok': true,
          'seams': _seams.values.map((CapabilitySeam s) => s.toJson()).toList(),
        };
      case 'modes':
        return <String, dynamic>{
          'ok': true,
          'active': _profile.mode.label,
          'modes': RunMode.values
              .map((RunMode m) => <String, dynamic>{
                    'id': m.label,
                    'description': m.description,
                  })
              .toList(),
        };
      case 'dump_config':
        return <String, dynamic>{'ok': true, ...dumpConfig()};
      case 'set_provider':
        return await setProvider(
            (p['seam'] ?? '').toString(), (p['provider'] ?? '').toString());
      case 'verify_deps':
        // 依赖健康检查：卸载/热替换后如实报告「仍挂载但依赖缺失」的插件。
        return verifyDependencies();
      case 'invoke':
        final Map<String, dynamic> args = p['args'] is Map
            ? Map<String, dynamic>.from(p['args'] as Map)
            : <String, dynamic>{};
        // G2：缺省 caller 不再默认 root——省略身份即视为未表明身份
        //（kUntrustedCaller），再由登记身份与调用守卫仲裁。
        // round13：payload 里的 caps 永不转发给 invoke（调用方自称的
        // 能力一律不认）；'ui' 自称只在 trustedRoot 为真时才算 root。
        return await invoke((p['seam'] ?? '').toString(),
            (p['method'] ?? '').toString(), args,
            caller: (p['caller'] ?? kUntrustedCaller).toString(),
            trustedRoot: trustedRoot);
      case 'set_mode':
        return await _setMode((p['mode'] ?? '').toString());
      case 'set_patch':
        return await _setPatch(
          (p['layer'] ?? 'runtime').toString(),
          p['key']?.toString() ?? '',
          p['value'],
          bundleId: p['bundle']?.toString(),
        );
      case 'pages':
        return _pagesAction(p, owner: pluginId);
      case 'text_overrides':
        return _textOverridesAction(p);
      case 'permission_policies':
        return _permissionPoliciesAction(p);
      case 'widget_slots':
        return <String, dynamic>{'ok': true, 'slots': listWidgetSlots()};
      case 'compose_prompt':
        return <String, dynamic>{'ok': true, 'prompt': composeSystemPrompt()};
      case 'events':
        final int from = (p['from_seq'] is num)
            ? (p['from_seq'] as num).toInt()
            : 0;
        final String? topic = p['topic']?.toString();
        final List<KernelEvent> evs = await replay(
            fromSeq: from > 0 ? from : null, topic: topic);
        return <String, dynamic>{
          'ok': true,
          'events': evs.map((KernelEvent e) => e.toJson()).toList(),
          'count': evs.length,
        };
      case 'search':
        final List<KernelEvent> evs = await search((p['query'] ?? '').toString());
        return <String, dynamic>{
          'ok': true,
          'events': evs.map((KernelEvent e) => e.toJson()).toList(),
          'count': evs.length,
        };
      case 'fork':
        final int from = (p['from_seq'] is num)
            ? (p['from_seq'] as num).toInt()
            : 0;
        return <String, dynamic>{'ok': true, 'fork_seq': await fork(from)};
      case 'mount':
        return await mount((p['plugin'] ?? '').toString());
      case 'unmount':
        return await unmount((p['plugin'] ?? '').toString());
      case 'snapshot':
        return <String, dynamic>{
          'ok': true,
          'snapshot': captureSnapshot((p['label'] ?? '').toString()),
        };
      case 'snapshots':
        return <String, dynamic>{
          'ok': true,
          'snapshots': _kernelSnapshots
              .map((KernelSnapshot s) => s.toJson())
              .toList(),
        };
      case 'rollback':
        return await restoreSnapshot((p['id'] ?? '').toString());
      case 'resolve_dirty':
        // round14：脏态唯一的人工出路——仅 trustedRoot（改动门禁已在入口
        // 拦下不可信调用），须显式 accept，确认接受当前半回退状态；
        // 清脏并写审计事件，journal 保留，供事后追溯。
        if (!_restoreDirty) {
          return <String, dynamic>{
            'ok': false,
            'error': '内核未处于回退脏态，无需 resolve_dirty',
          };
        }
        if (p['accept'] != true) {
          return <String, dynamic>{
            'ok': false,
            'error': 'resolve_dirty 须显式传 accept: true，确认接受当前半回退状态',
          };
        }
        final Map<String, dynamic> resolvedJournal =
            _restoreJournalSummary();
        _restoreDirty = false;
        _restoreDirtyReason = '';
        _restoreDirtyAt = '';
        _restoreDirtyPhase = '';
        _restoreJournal['phase'] = 'resolved';
        // round18：清脏落盘（尽力而为；写失败只记审计事件，不翻供已清的内存态）。
        await _persistDirtyState();
        emit('kernel.restore_dirty_resolved', 'kernel', <String, dynamic>{
          'accepted': true,
          'journal': resolvedJournal,
        });
        return <String, dynamic>{
          'ok': true,
          'cleared': true,
          'journal': resolvedJournal,
        };
      default:
        // 插件贡献的控制动作优先匹配。
        final _ControlEntry? entry = _controlActions[action];
        if (entry != null) {
          try {
            return await entry.handler(p);
          } on Object catch (e) {
            return <String, dynamic>{'ok': false, 'error': '$e'};
          }
        }
        return <String, dynamic>{
          'ok': false,
          'error': '未知内核动作：$action',
        };
    }
  }

  /// G5：捕获内核态快照（节点树 / seam 激活项 / 服务 / 模式 / 事件序号）。
  Map<String, dynamic> captureSnapshot(String label) {
    final KernelSnapshot snap = KernelSnapshot(
      id: 'ksnap-${++_snapshotSeq}-${DateTime.now().millisecondsSinceEpoch}',
      label: label.isEmpty ? '内核快照' : label,
      at: DateTime.now().toIso8601String(),
      nodes: _nodes.values
          .map((PluginNode n) => <String, dynamic>{
                'id': n.plugin.id,
                'parent': n.parentId,
                'source': n.source,
                'config_layer': n.configLayer,
                'tier': n.plugin.tier.wire,
              })
          .toList(),
      seams: _seams.values
          .map((CapabilitySeam sm) => <String, dynamic>{
                'name': sm.name,
                'active': sm.activeProviderId,
                'providers': sm.providers.keys.toList(),
              })
          .toList(),
      services: _services.keys.toList(),
      mode: _booted ? _profile.mode.label : '',
      seq: _seq,
    );
    _kernelSnapshots.add(snap);
    while (_kernelSnapshots.length > snapshotLimit) {
      _kernelSnapshots.removeAt(0);
    }
    emit('kernel.snapshot', 'kernel', <String, dynamic>{
      'id': snap.id,
      'label': snap.label,
      'nodes': snap.nodes.length,
    });
    return snap.toJson();
  }

  /// round14：回退预检（零变异失败路径）。复用 verifyDependencies 的判定
  /// 口径——不是直接调它（它只查当前已挂载态），而是对快照做同一类检查：
  /// 快照节点均已注册、依赖闭包在快照自身服务集内可满足、接缝目标
  /// provider 的 owner 在快照集内或已挂载、模式可解析。任一失败都
  /// 在卸载任何插件前返回，不改动任何插件。
  /// 静态核实不了的两类留给变异阶段兜底（阶段二/三会置脏失败）：
  /// 快照内挂载顺序导致的依赖时序（消费者排在提供者之前）、当前不
  /// 存在、需重挂后才重建的接缝 provider（自提供/时序依赖同理，预检
  /// 只按快照服务集做闭包检查，挂载时序问题由阶段二捕获）。
  Map<String, dynamic> _preflightSnapshot(KernelSnapshot snap) {
    final List<String> errors = <String>[];
    for (final Map<String, dynamic> n in snap.nodes) {
      final String pid = (n['id'] ?? '').toString();
      if (pid.isEmpty) {
        errors.add('快照含空插件 id');
        continue;
      }
      if (!_registry.containsKey(pid)) {
        errors.add('插件 $pid 未注册到内核目录');
      }
    }
    // 依赖闭包：快照服务集是快照时刻的服务全集，提供方当时必在快照
    // 节点集内——要求不在该集内的服务，回退后一定无法满足。
    final Set<String> snapServices = snap.services.toSet();
    for (final Map<String, dynamic> n in snap.nodes) {
      final String pid = (n['id'] ?? '').toString();
      final Plugin? plugin = _registry[pid];
      if (plugin == null) continue;
      for (final String dep in plugin.requires) {
        if (!snapServices.contains(dep)) {
          errors.add('插件 $pid 依赖服务 $dep 在快照服务集内不存在，'
              '回退后无法满足');
        }
      }
    }
    final Set<String> snapIds = snap.nodeIds;
    for (final Map<String, dynamic> sm in snap.seams) {
      final String name = (sm['name'] ?? '').toString();
      final String active = (sm['active'] ?? '').toString();
      if (active.isEmpty) continue;
      final CapabilitySeam? seam = _seams[name];
      if (seam == null) continue; // 需重挂后重建，阶段三兜底
      final SeamProviderEntry? entry = seam.providers[active];
      if (entry == null) continue; // 同上
      final String owner = entry.ownerPlugin;
      if (!snapIds.contains(owner) && !_nodes.containsKey(owner)) {
        errors.add('接缝 $name 目标 provider $active 的 owner $owner '
            '既不在快照集内也未挂载，回退后会被卸载');
      }
    }
    if (snap.mode.isNotEmpty &&
        !<String>{'standard', 'ptc', 'minimal', 'creator'}
            .contains(snap.mode)) {
      errors.add('快照模式 ${snap.mode} 无法解析');
    }
    return <String, dynamic>{'ok': errors.isEmpty, 'errors': errors};
  }

  /// 回退 journal 摘要（只读动作可查的口径）：复制一份，调用方改不动内核内账。
  /// round16：启动标脏另记 failed_mounts/failed_unmounts/boot_errors，
  /// 缺省为空列表（旧调用方按 key 访问，不破坏）。
  Map<String, dynamic> _restoreJournalSummary() => <String, dynamic>{
        'target_snapshot': _restoreJournal['target_snapshot'],
        'pre_restore_snapshot': _restoreJournal['pre_restore_snapshot'],
        'phase': _restoreJournal['phase'],
        'failed_phase': _restoreJournal['failed_phase'],
        'failed_plugin': _restoreJournal['failed_plugin'],
        'done_unmounts': List<String>.from(
            (_restoreJournal['done_unmounts'] as List?) ?? const <String>[]),
        'done_mounts': List<String>.from(
            (_restoreJournal['done_mounts'] as List?) ?? const <String>[]),
        'failed_mounts': ((_restoreJournal['failed_mounts'] as List?) ??
                const <dynamic>[])
            .whereType<Map>()
            .map((Map m) => Map<String, dynamic>.from(m))
            .toList(),
        'failed_unmounts': ((_restoreJournal['failed_unmounts'] as List?) ??
                const <dynamic>[])
            .whereType<Map>()
            .map((Map m) => Map<String, dynamic>.from(m))
            .toList(),
        'boot_errors': List<String>.from(
            (_restoreJournal['boot_errors'] as List?) ?? const <String>[]),
        'at': _restoreJournal['at'],
      };

  /// 变异阶段失败的统一收口：置脏、记 journal、发 kernel.rollback_failed、
  /// 返回结构化失败（含 resume 两条出路）。只在 _restoring 保护内调用。
  /// round18：置脏后随 _persistConfig 落盘（phase 'restore'），使重启后
  /// 仍能恢复本次回退的脏态；调用方 await 本收口，落盘完成才返回。
  Future<Map<String, dynamic>> _failRestore({
    required String phase,
    String failedPlugin = '',
    required String error,
    required List<String> doneUnmounts,
    required List<String> doneMounts,
    Map<String, dynamic>? extra,
  }) async {
    _restoreDirty = true;
    _restoreDirtyAt = DateTime.now().toIso8601String();
    _restoreDirtyPhase = 'restore';
    _restoreJournal['phase'] = phase;
    _restoreJournal['failed_phase'] = phase;
    _restoreJournal['failed_plugin'] = failedPlugin;
    _restoreJournal['done_unmounts'] = List<String>.from(doneUnmounts);
    _restoreJournal['done_mounts'] = List<String>.from(doneMounts);
    final String target =
        (_restoreJournal['target_snapshot'] ?? '').toString();
    final String pre =
        (_restoreJournal['pre_restore_snapshot'] ?? '').toString();
    _restoreDirtyReason = '回退到快照 $target 在 $phase 阶段失败：$error';
    final Map<String, dynamic> result = <String, dynamic>{
      'ok': false,
      'dirty': true,
      'failed_phase': phase,
      'failed_plugin': failedPlugin,
      'error': error,
      'snapshot': target,
      'pre_restore_snapshot': pre,
      'completed': <String, dynamic>{
        'unmounted': List<String>.from(doneUnmounts),
        'mounted': List<String>.from(doneMounts),
      },
      'resume': <String, dynamic>{
        'retry_same': target,
        'restore_pre': pre,
      },
      'journal': _restoreJournalSummary(),
    };
    if (extra != null) result.addAll(extra);
    emit('kernel.rollback_failed', 'kernel', <String, dynamic>{
      'snapshot': target,
      'phase': phase,
      'failed_plugin': failedPlugin,
      'error': error,
      'pre_restore_snapshot': pre,
    });
    // round18：回退失败的脏态落盘（尽力而为；写失败只记审计事件）。
    await _persistDirtyState();
    return result;
  }

  /// G5：回退到某份内核态快照（round14 六步最小闭环）。
  ///
  /// ① 预检（零变异）：见 [_preflightSnapshot]，失败直接返回，不动插件。
  /// ② 预检通过后立即显式 captureSnapshot('回退前自动备份')——不依赖
  ///    onBeforeMount（_restoring 期间它被抑制）。
  /// ③ 变异阶段置 _restoreDirty=true，journal 随阶段推进更新；四阶段
  ///    全成功才清脏。任一阶段失败返回结构化 {ok:false, dirty:true,
  ///    failed_phase, failed_plugin, completed, resume} 并发
  ///    kernel.rollback_failed；脏态下 handle() 的改动类动作被拒，
  ///    只有 rollback（重试同一快照 / 回滚到备份）与 resolve_dirty 豁免。
  Future<Map<String, dynamic>> restoreSnapshot(String id) async {
    KernelSnapshot? snap;
    for (final KernelSnapshot s in _kernelSnapshots) {
      if (s.id == id) snap = s;
    }
    if (snap == null) {
      return <String, dynamic>{'ok': false, 'error': '内核快照不存在：$id'};
    }
    final Map<String, dynamic> preflight = _preflightSnapshot(snap);
    if (preflight['ok'] != true) {
      return <String, dynamic>{
        'ok': false,
        'phase': 'preflight',
        'error': '回退预检失败：${(preflight['errors'] as List).join('；')}',
        'errors': preflight['errors'],
        'snapshot': id,
      };
    }
    final Map<String, dynamic> preSnap =
        captureSnapshot('回退前自动备份');
    final String preSnapId = (preSnap['id'] ?? '').toString();
    final List<String> doneUnmounts = <String>[];
    final List<String> doneMounts = <String>[];
    _restoring = true;
    _restoreDirty = true;
    _restoreDirtyReason = '正在回退到快照 $id';
    _restoreJournal = <String, dynamic>{
      'target_snapshot': id,
      'pre_restore_snapshot': preSnapId,
      'phase': 'unmount',
      'done_unmounts': <String>[],
      'done_mounts': <String>[],
      'failed_plugin': '',
      'failed_phase': '',
      'at': DateTime.now().toIso8601String(),
    };
    try {
      // 阶段一：卸载多余插件（返回值现查，不再丢弃；父节点卸载会连带
      // 递归卸载子节点，遍历前先跳过已被连带卸载的节点）。
      final Set<String> keep = snap.nodeIds;
      for (final String pid in List<String>.of(_nodes.keys)) {
        if (!keep.contains(pid)) {
          if (!_nodes.containsKey(pid)) continue;
          final Set<String> before = _nodes.keys.toSet();
          final Map<String, dynamic> r =
              await unmount(pid, reason: 'rollback');
          doneUnmounts.addAll(before.difference(_nodes.keys.toSet()));
          _restoreJournal['done_unmounts'] = List<String>.from(doneUnmounts);
          if (r['ok'] != true) {
            return await _failRestore(
              phase: 'unmount',
              failedPlugin: pid,
              error: '回退失败：插件 $pid 无法卸载（${r['error']}）',
              doneUnmounts: doneUnmounts,
              doneMounts: doneMounts,
            );
          }
        }
      }
      // 阶段二：按原顺序补挂。
      _restoreJournal['phase'] = 'remount';
      for (final Map<String, dynamic> n in snap.nodes) {
        final String pid = (n['id'] ?? '').toString();
        if (pid.isEmpty || _nodes.containsKey(pid)) continue;
        final Map<String, dynamic> r = await mount(
          pid,
          parentId: n['parent']?.toString(),
          source: (n['source'] ?? 'runtime').toString(),
          configLayer: (n['config_layer'] ?? 'runtime').toString(),
        );
        if (r['ok'] != true) {
          return await _failRestore(
            phase: 'remount',
            failedPlugin: pid,
            error: '回退失败：插件 $pid 无法重新挂载（${r['error']}）',
            doneUnmounts: doneUnmounts,
            doneMounts: doneMounts,
          );
        }
        doneMounts.add(pid);
        _restoreJournal['done_mounts'] = List<String>.from(doneMounts);
      }
      // 阶段三：恢复接缝激活项。目标 provider 缺失不再静默 continue，
      // 而是置脏失败（旧行为返回 ok:true，谎称已回退）。
      _restoreJournal['phase'] = 'seams';
      for (final Map<String, dynamic> sm in snap.seams) {
        final String name = (sm['name'] ?? '').toString();
        final String active = (sm['active'] ?? '').toString();
        if (active.isEmpty) continue;
        final CapabilitySeam? seam = _seams[name];
        if (seam == null || !seam.providers.containsKey(active)) {
          return await _failRestore(
            phase: 'seams',
            error: '回退失败：接缝 $name 的目标 provider $active 不存在',
            doneUnmounts: doneUnmounts,
            doneMounts: doneMounts,
            extra: <String, dynamic>{
              'failed_seam': name,
              'failed_provider': active,
            },
          );
        }
        seam.activeProviderId = active;
      }
      // 阶段四：恢复模式。_setMode 失败收集为结构化返回，不再异常逃逸。
      _restoreJournal['phase'] = 'mode';
      if (_booted && snap.mode.isNotEmpty && snap.mode != _profile.mode.label) {
        final Map<String, dynamic> r = await _setMode(snap.mode);
        if (r['ok'] != true) {
          return await _failRestore(
            phase: 'mode',
            error: '回退失败：模式恢复失败（${r['error']}）',
            doneUnmounts: doneUnmounts,
            doneMounts: doneMounts,
            extra: <String, dynamic>{'mode_result': r},
          );
        }
      }
      _restoreJournal['phase'] = 'done';
      _restoreDirty = false;
      _restoreDirtyReason = '';
      _restoreDirtyAt = '';
      _restoreDirtyPhase = '';
      // round18：重试同一快照 / 回滚到备份成功，清脏落盘（尽力而为）。
      await _persistDirtyState();
      emit('kernel.rollback', 'kernel', <String, dynamic>{
        'snapshot': id,
        'mounted': mountedCount,
        'pre_restore_snapshot': preSnapId,
      });
      return <String, dynamic>{
        'ok': true,
        'snapshot': id,
        'mounted': mountedCount,
        'pre_restore_snapshot': preSnapId,
      };
    } finally {
      _restoring = false;
    }
  }

  Future<Map<String, dynamic>> _setMode(String mode) async {
    final RunMode next = RunModeX.parse(mode);
    _profile.mode = next;
    emit('kernel.mode_changed', 'kernel', <String, dynamic>{'mode': next.label});
    // round14：失败不再以异常穿出——_persistConfig 抛错与 _applyProfile
    // 丢弃的挂载/卸载结果都收集为结构化 {ok:false} 返回；调用方
    // （restoreSnapshot 阶段四）据此置脏。注意模式是先赋值、后应用：
    // _applyProfile 失败时 mode 标签已改，脏标志与 journal 负责记录，
    // 由三条出路恢复——本轮不改赋值顺序（boot 不走 _setMode，语义不变）。
    try {
      final Map<String, dynamic> applied = await _applyProfile(reset: false);
      if (applied['ok'] != true) {
        return <String, dynamic>{
          'ok': false,
          'error': '切换模式 ${next.label} 未完全应用',
          'mode': next.label,
          'failed_mounts': applied['failed_mounts'],
          'failed_unmounts': applied['failed_unmounts'],
        };
      }
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'error': '切换模式失败：$e',
        'mode': next.label,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'mode': next.label,
      'mounted': mountedCount,
    };
  }

  Map<String, dynamic> _pagesAction(Map<String, dynamic> p,
      {String? owner}) {
    final String op = (p['op'] ?? 'list').toString();
    switch (op) {
      case 'list':
        return <String, dynamic>{'ok': true, 'pages': listPages()};
      case 'add':
        return addPage(
          (p['id'] ?? '').toString(),
          p['meta'] is Map
              ? Map<String, dynamic>.from(p['meta'] as Map)
              : <String, dynamic>{},
          owner: owner ?? 'runtime',
        );
      case 'remove':
        return removePage((p['id'] ?? '').toString());
      case 'reorder':
        return reorderPages(p['ids'] is List
            ? (p['ids'] as List).map((dynamic e) => e.toString()).toList()
            : <String>[]);
      default:
        return <String, dynamic>{
          'ok': false,
          'error': '未知 pages 操作：$op（list/add/remove/reorder）',
        };
    }
  }

  Map<String, dynamic> _textOverridesAction(Map<String, dynamic> p) {
    final String op = (p['op'] ?? 'list').toString();
    final String locale = (p['locale'] ?? '').toString();
    final String key = (p['key'] ?? '').toString();
    switch (op) {
      case 'list':
        return <String, dynamic>{'ok': true, 'overrides': listTextOverrides()};
      case 'get':
        final String? v = getTextOverride(locale, key);
        return <String, dynamic>{
          'ok': true,
          'locale': locale,
          'key': key,
          'value': v,
          'found': v != null,
        };
      case 'set':
        return setTextOverride(locale, key, (p['value'] ?? '').toString());
      default:
        return <String, dynamic>{
          'ok': false,
          'error': '未知 text_overrides 操作：$op（set/get/list）',
        };
    }
  }

  Map<String, dynamic> _permissionPoliciesAction(Map<String, dynamic> p) {
    final String op = (p['op'] ?? 'list').toString();
    switch (op) {
      case 'list':
        return <String, dynamic>{
          'ok': true,
          'policies': listPermissionPolicies(),
        };
      case 'set':
        return setPermissionPolicy(
          (p['id'] ?? '').toString(),
          p['policy'] is Map
              ? Map<String, dynamic>.from(p['policy'] as Map)
              : <String, dynamic>{},
        );
      default:
        return <String, dynamic>{
          'ok': false,
          'error': '未知 permission_policies 操作：$op（set/list）',
        };
    }
  }

  /// 写入配置层。bundle 层可指定 bundleId（也接受 layer='bundle:<id>'），
  /// 真实写入对应 bundle.patch 并随 profile 落盘，绝不伪造来源层。
  Future<Map<String, dynamic>> _setPatch(
    String layer,
    String key,
    Object? value, {
    String? bundleId,
  }) async {
    if (key.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '缺少配置 key'};
    }
    String effectiveLayer = layer;
    if (layer == 'bundle' || layer.startsWith('bundle:')) {
      final String bid = bundleId ??
          (layer.contains(':') ? layer.substring(layer.indexOf(':') + 1) : '');
      Bundle? target;
      for (final Bundle b in _profile.bundles) {
        if (b.id == bid) {
          target = b;
          break;
        }
      }
      if (target == null) {
        return <String, dynamic>{
          'ok': false,
          'error': '未知 bundle：$bid（当前 bundles: '
              '${_profile.bundles.map((Bundle b) => b.id).join(', ')}）',
        };
      }
      target.patch[key] = value;
      effectiveLayer = 'bundle:${target.id}';
      await _persistConfig();
    } else {
      switch (layer) {
        case 'home':
          _homePatch[key] = value;
          await _persistConfig();
          break;
        case 'runtime':
          _runtimePatch[key] = value;
          break;
        case 'profile':
          _profile.patch[key] = value;
          await _persistConfig();
          break;
        default:
          return <String, dynamic>{
            'ok': false,
            'error': '未知配置层：$layer（bundle/bundle:<id>/home/runtime/profile）',
          };
      }
    }
    emit('kernel.patch', 'kernel', <String, dynamic>{
      'layer': effectiveLayer,
      'key': key,
    });
    return <String, dynamic>{
      'ok': true,
      'entry': composeConfig()
          .firstWhere((ConfigEntry e) => e.key == key,
              orElse: () => ConfigEntry(key, value, effectiveLayer))
          .toJson(),
    };
  }

  /// 卸载全部插件（进程退出时调用；不动后端热流控制器）。
  Future<void> dispose() async {
    for (final String id in List<String>.of(_nodes.keys)) {
      await unmount(id, reason: 'dispose');
    }
    emit('kernel.shutdown', 'kernel', <String, dynamic>{'mounted': 0});
  }
}
