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
  PluginContext._(this._kernel, this._effects, this.pluginId);
  final PluginKernel _kernel;
  final List<Disposable>? _effects;
  final String pluginId;

  /// 供插件在提示词片段/控制动作里读取内核实时状态（只读视图，不绕过注册）。
  PluginKernel get kernel => _kernel;

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
  CapabilitySeam seam(String name, String definition) =>
      _kernel._ensureSeam(name, definition);

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
    final Plugin? self = _kernel.pluginOf(pluginId);
    if (self != null && !seamAllowed(self.tier, self.caps, seamName)) {
      throw CapabilityDenied(
          pluginId, seamName, 'caps 未声明该接缝（tier=${self.tier.wire}）');
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
  void emit(String topic, Map<String, dynamic> data) =>
      _kernel.emit(topic, pluginId, data);

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
    await _applyProfile(reset: true);
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
  Future<void> _applyProfile({required bool reset}) async {
    if (reset) {
      for (final String id in List<String>.of(_nodes.keys)) {
        await unmount(id, reason: 'reset');
      }
    }
    final Set<String>? allowed = _modePlugins[_profile.mode];
    for (final Bundle bundle in _profile.bundles) {
      for (final String pid in bundle.pluginIds) {
        if (allowed != null && !allowed.contains(pid)) continue;
        if (_nodes.containsKey(pid)) continue;
        await mount(pid, source: 'bundle:${bundle.id}', configLayer: 'bundle');
      }
    }
    // 模式裁剪：卸载不在允许集合里的插件（真实生效，不是标记）。
    if (allowed != null) {
      for (final String id in List<String>.of(_nodes.keys)) {
        if (!allowed.contains(id)) {
          await unmount(id, reason: 'mode:${_profile.mode.label}');
        }
      }
    }
    await _persistConfig();
  }

  Future<void> _persistConfig() async {
    await persistence.writeConfig(<String, dynamic>{
      'profile': _profile.toJson(),
      'home_patch': _homePatch,
      'updated_at': DateTime.now().toIso8601String(),
    });
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
    final PluginContext scope = PluginContext._(this, effects, pluginId);
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
    final PluginContext scope = PluginContext._(this, null, pluginId);
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
  Future<Map<String, dynamic>> invoke(String seamName, String method,
      Map<String, dynamic> args,
      {String caller = kRootCaller, List<String> caps = const <String>[]}) async {
    final CapabilitySeam? s = _seams[seamName];
    if (s == null) {
      return <String, dynamic>{'ok': false, 'error': '接缝 $seamName 不存在'};
    }
    // G2 仲裁：root（UI）直通；其他调用方必须满足 seamCaps 与自带 caps。
    if (caller != kRootCaller) {
      final List<String> need = seamCaps[seamName] ?? const <String>[];
      final List<String> missing =
          need.where((String c) => !caps.contains(c)).toList();
      if (missing.isNotEmpty) {
        emit('seam.denied', 'kernel', <String, dynamic>{
          'seam': seamName,
          'caller': caller,
          'missing_caps': missing,
        });
        return <String, dynamic>{
          'ok': false,
          'error': '调用方 $caller 缺少能力令牌：$missing（接缝 $seamName）',
          'missing_caps': missing,
        };
      }
    }
    final InvokeGuard? guard = invokeGuard;
    if (guard != null) {
      bool allowed = false;
      try {
        allowed = await guard(seamName, method, args, caller);
      } on Object catch (e) {
        return <String, dynamic>{'ok': false, 'error': '调用守卫异常，拒绝执行：$e'};
      }
      if (!allowed) {
        emit('seam.denied', 'kernel', <String, dynamic>{
          'seam': seamName,
          'caller': caller,
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

  Future<Map<String, dynamic>> handle(String action, Map<String, dynamic> p) async {
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
        return await invoke((p['seam'] ?? '').toString(),
            (p['method'] ?? '').toString(), args,
            caller: (p['caller'] ?? kRootCaller).toString(),
            caps: (p['caps'] is List)
                ? (p['caps'] as List).map((dynamic e) => e.toString()).toList()
                : const <String>[]);
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
        return _pagesAction(p);
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
      id: 'ksnap-${_kernelSnapshots.length + 1}-${DateTime.now().millisecondsSinceEpoch}',
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

  /// G5：回退到某份内核态快照：先卸载多余插件，再按原顺序补挂，最后恢复激活项与模式。
  Future<Map<String, dynamic>> restoreSnapshot(String id) async {
    KernelSnapshot? snap;
    for (final KernelSnapshot s in _kernelSnapshots) {
      if (s.id == id) snap = s;
    }
    if (snap == null) {
      return <String, dynamic>{'ok': false, 'error': '内核快照不存在：$id'};
    }
    _restoring = true;
    try {
      final Set<String> keep = snap.nodeIds;
      for (final String pid in List<String>.of(_nodes.keys)) {
        if (!keep.contains(pid)) {
          await unmount(pid, reason: 'rollback');
        }
      }
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
          return <String, dynamic>{
            'ok': false,
            'error': '回退失败：插件 $pid 无法重新挂载（${r['error']}）',
            'snapshot': id,
          };
        }
      }
      for (final Map<String, dynamic> sm in snap.seams) {
        final CapabilitySeam? seam = _seams[(sm['name'] ?? '').toString()];
        final String active = (sm['active'] ?? '').toString();
        if (seam == null || active.isEmpty) continue;
        if (seam.providers.containsKey(active)) seam.activeProviderId = active;
      }
      if (_booted && snap.mode.isNotEmpty && snap.mode != _profile.mode.label) {
        await _setMode(snap.mode);
      }
      emit('kernel.rollback', 'kernel', <String, dynamic>{
        'snapshot': id,
        'mounted': mountedCount,
      });
      return <String, dynamic>{
        'ok': true,
        'snapshot': id,
        'mounted': mountedCount,
      };
    } finally {
      _restoring = false;
    }
  }

  Future<Map<String, dynamic>> _setMode(String mode) async {
    final RunMode next = RunModeX.parse(mode);
    _profile.mode = next;
    emit('kernel.mode_changed', 'kernel', <String, dynamic>{'mode': next.label});
    await _applyProfile(reset: false);
    return <String, dynamic>{
      'ok': true,
      'mode': next.label,
      'mounted': mountedCount,
    };
  }

  Map<String, dynamic> _pagesAction(Map<String, dynamic> p) {
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
