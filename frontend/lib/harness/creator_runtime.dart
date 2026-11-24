/// Tangram Creator 创造模式 —— 声明式插件包运行时。
///
/// 设计边界（不撒谎、不做假热加载）：
///  * **不动态编译 Dart**。Flutter AOT 下没有可用的运行时编译链，本文件
///    只实现真实的**声明式插件包**：一份 JSON manifest 描述插件元数据、
///    权限与动作（prompt / http / shell），运行时解释执行这些动作。
///  * manifest 真实落盘到 `plugins/creator/<id>.json`，`list` 每次从磁盘
///    装载并缓存为本地 catalog；`save` / `import` 立即写盘并进 catalog。
///  * `activate` 把动作真实注册为 [AgentTool]（注入 [PluginKernel] 时）并
///    登记为已激活；`deactivate` 调 `kernel.unmount` 逆序撤销 effects。
///    未注入 kernel 时仍维护内部激活表，`list` / `run` 直接可用，供集成方
///    自行接线——两条路径都不伪造"已挂载"。
///  * `run` 只执行已激活插件的动作：prompt 走注入的 chat 回调，http 用真实
///    [HttpClient]（超时 / 响应上限 / 仅 http(s) / host allowlist / 默认
///    不发送 Authorization 与 Cookie），shell 走注入的 shell 回调且必须
///    在 manifest 里显式声明 `shell` 权限，默认拒绝。任何缺失都如实返回
///    `ok=false` 与原因，绝不编造成功。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/plugin_kernel.dart';
import 'package:tangram/harness/plugin_tier.dart';
import 'package:tangram/harness/store.dart';

/// prompt 动作的注入回调：拿到渲染后的提示词与原始参数，返回结构化结果。
typedef CreatorChatHandler = Future<Map<String, dynamic>> Function(
    String prompt, Map<String, dynamic> args);

/// shell 动作的注入回调：命令与工作目录由运行时给出，执行由宿主负责。
typedef CreatorShellHandler = Future<Map<String, dynamic>> Function(
    String command, String cwd);
typedef CreatorMcpHandler = Future<Map<String, dynamic>> Function(
    String server, String tool, Map<String, dynamic> args);

/// HTTP 客户端工厂（测试可注入，业务默认直接 new HttpClient）。
typedef CreatorHttpClientFactory = HttpClient Function();

const Set<String> _actionTypes = <String>{'prompt', 'http', 'shell', 'mcp'};
const List<String> _httpMethods = <String>[
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'HEAD',
];

final RegExp _manifestIdPattern =
    RegExp(r'^[a-z][a-z0-9]*([._-][a-z0-9]+)*$');
final RegExp _actionIdPattern = RegExp(r'^[a-z][a-z0-9_-]*$');
final RegExp _versionPattern =
    RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$');
final RegExp _placeholderPattern =
    RegExp(r'\{\{\s*([A-Za-z0-9_.-]+)\s*\}\}');

/// 一个声明式动作。字段按类型取用，未使用的字段保持默认值。
class CreatorAction {
  const CreatorAction({
    required this.id,
    required this.type,
    this.description = '',
    this.promptTemplate = '',
    this.method = 'GET',
    this.url = '',
    this.headers = const <String, String>{},
    this.command = '',
    this.server = '',
    this.tool = '',
    this.timeoutMs = 8000,
    this.requiredArgs = const <String>[],
  });

  final String id;

  /// `prompt` / `http` / `shell`；未知类型由校验报错，不在运行时猜测。
  final String type;
  final String description;

  /// prompt 动作的模板，支持 `{{key}}` 占位符。
  final String promptTemplate;

  /// http 动作字段。
  final String method;
  final String url;
  final Map<String, String> headers;
  final int timeoutMs;

  /// shell 动作字段。
  final String command;

  /// mcp 动作字段：已配置的 MCP 服务端 id 与工具名。
  final String server;
  final String tool;

  /// 必填参数名（prompt 会校验；其余动作同样拒绝缺参）。
  final List<String> requiredArgs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type,
        if (description.isNotEmpty) 'description': description,
        if (promptTemplate.isNotEmpty) 'template': promptTemplate,
        if (type == 'http') ...<String, dynamic>{
          'method': method,
          'url': url,
          if (headers.isNotEmpty) 'headers': headers,
        },
        if (command.isNotEmpty) 'command': command,
        if (server.isNotEmpty) 'server': server,
        if (tool.isNotEmpty) 'tool': tool,
        if (requiredArgs.isNotEmpty) 'required': requiredArgs,
        'timeout_ms': timeoutMs,
      };

  static CreatorAction fromJson(Map<String, dynamic> m) {
    String text(Object? v) => v == null ? '' : v.toString().trim();
    final Object? headersRaw = m['headers'];
    final Map<String, String> headers = <String, String>{};
    if (headersRaw is Map) {
      headersRaw.forEach((dynamic k, dynamic v) {
        headers[k.toString()] = v.toString();
      });
    }
    final Object? requiredRaw = m['required'];
    final List<String> required = requiredRaw is List
        ? requiredRaw
            .map((dynamic e) => e.toString().trim())
            .where((String e) => e.isNotEmpty)
            .toList()
        : const <String>[];
    final Object? timeoutRaw = m['timeout_ms'];
    return CreatorAction(
      id: text(m['id']),
      type: text(m['type']),
      description: text(m['description']),
      promptTemplate: m['template'] == null ? '' : m['template'].toString(),
      method: m['method'] == null ? 'GET' : text(m['method']).toUpperCase(),
      url: text(m['url']),
      headers: Map<String, String>.unmodifiable(headers),
      command: m['command'] == null ? '' : m['command'].toString(),
      server: text(m['server']),
      tool: text(m['tool']),
      timeoutMs: timeoutRaw is num ? timeoutRaw.toInt() : 8000,
      requiredArgs: required,
    );
  }
}

/// 声明式插件 manifest。`tryParse` 只做结构解析，语义问题交给
/// [CreatorRuntime.validate] 汇总为 errors / warnings。
class CreatorManifest {
  const CreatorManifest({
    required this.id,
    required this.name,
    required this.version,
    this.description = '',
    this.permissions = const <String>[],
    this.dependencies = const <String>[],
    this.actions = const <CreatorAction>[],
    this.uiSlots = const <String, Map<String, dynamic>>{},
    this.policies = const <String, Map<String, dynamic>>{},
  });

  final String id;
  final String name;
  final String version;
  final String description;

  /// 能力声明，如 `prompt` / `network` / `shell`。
  final List<String> permissions;

  /// 依赖的其它 Creator 插件 id（激活时必须是已激活状态）。
  final List<String> dependencies;
  final List<CreatorAction> actions;

  /// UI 插件槽：key 为槽位 id，value 为声明式组件树；激活时注册到插件内核。
  final Map<String, Map<String, dynamic>> uiSlots;

  /// 权限策略插件：key 为策略 id，value 为 allow/ask/deny 策略；激活时注册。
  final Map<String, Map<String, dynamic>> policies;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'version': version,
        'description': description,
        'permissions': List<String>.of(permissions),
        'dependencies': List<String>.of(dependencies),
        'actions': actions.map((CreatorAction a) => a.toJson()).toList(),
        'ui_slots': uiSlots,
        'policies': policies,
      };

  static CreatorManifest? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> m = raw.map(
        (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v));
    final Object? actionsRaw = m['actions'];
    if (actionsRaw is! List) return null;
    final List<CreatorAction> actions = <CreatorAction>[];
    for (final Object? item in actionsRaw) {
      if (item is! Map) return null;
      actions.add(CreatorAction.fromJson(
          item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))));
    }
    String text(Object? v) => v == null ? '' : v.toString().trim();
    List<String> strings(Object? v) => v is List
        ? v
            .map((dynamic e) => e.toString().trim())
            .where((String e) => e.isNotEmpty)
            .toList()
        : <String>[];
    Map<String, Map<String, dynamic>> maps(Object? v) {
      if (v is! Map) return <String, Map<String, dynamic>>{};
      final Map<String, Map<String, dynamic>> out =
          <String, Map<String, dynamic>>{};
      v.forEach((dynamic key, dynamic value) {
        if (value is Map) {
          out[key.toString()] = value.map(
              (dynamic k, dynamic val) => MapEntry(k.toString(), val));
        }
      });
      return out;
    }

    return CreatorManifest(
      id: text(m['id']),
      name: text(m['name']),
      version: text(m['version']),
      description: text(m['description']),
      permissions: strings(m['permissions']),
      dependencies: strings(m['dependencies']),
      actions: actions,
      uiSlots: maps(m['ui_slots']),
      policies: maps(m['policies']),
    );
  }
}

/// 校验结果：errors 为空才可通过；warnings 是真实风险提示，不阻断保存。
class CreatorValidation {
  const CreatorValidation(this.errors, this.warnings);

  final List<String> errors;
  final List<String> warnings;

  bool get ok => errors.isEmpty;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'errors': List<String>.of(errors),
        'warnings': List<String>.of(warnings),
      };
}

class _ActiveCreator {
  _ActiveCreator({
    required this.manifest,
    required this.pluginId,
    required this.toolNames,
    required this.registeredToKernel,
  });

  final CreatorManifest manifest;
  final String pluginId;
  final List<String> toolNames;
  final bool registeredToKernel;
}

/// Creator 运行时。`kernel` 可为空：为空时仍真实维护激活表与动作执行，
/// 只是不往内核注册工具，由集成方通过 [list] / [run] 自行接线。
class CreatorRuntime {
  CreatorRuntime(
    this.store, {
    this.kernel,
    this.chat,
    this.shell,
    this.mcp,
    this.httpClientFactory,
    Set<String> allowedHosts = const <String>{},
    this.httpTimeout = const Duration(seconds: 8),
    this.maxResponseBytes = 256 * 1024,
    this.allowCredentialHeaders = false,
  }) : allowedHosts = Set<String>.unmodifiable(allowedHosts);

  final HarnessStore store;
  final PluginKernel? kernel;
  final CreatorChatHandler? chat;
  final CreatorShellHandler? shell;
  final CreatorMcpHandler? mcp;
  final CreatorHttpClientFactory? httpClientFactory;

  /// http 动作目标 host 白名单，支持精确匹配与 `*.example.com` 通配。
  /// 空集合 = 默认拒绝任何网络目标。
  final Set<String> allowedHosts;
  final Duration httpTimeout;

  /// 单次响应最多读取的字节数，超过即中止并如实报错。
  final int maxResponseBytes;

  /// 是否允许透传 Authorization / Cookie / Proxy-Authorization 头。
  /// 默认 false：manifest 里声明的凭据头会被丢弃并在结果里列出。
  final bool allowCredentialHeaders;

  static const String creatorDir = 'plugins/creator';

  final Map<String, CreatorManifest> _catalog = <String, CreatorManifest>{};
  final Map<String, _ActiveCreator> _active = <String, _ActiveCreator>{};
  bool _loaded = false;

  /// 装载 catalog 时的真实错误（损坏文件不冒充数据）。
  String loadError = '';

  bool get hasChat => chat != null;
  bool get hasShell => shell != null;
  List<String> get activeIds => List<String>.unmodifiable(_active.keys);

  bool isActive(String id) => _active.containsKey(id);

  String pluginIdFor(String id) => 'creator.$id';

  /// 动作对应的 AgentTool 名（kernel 注入时真实注册，也可供集成方查找）。
  String toolName(String pluginId, String actionId) {
    final String p =
        pluginId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    final String a =
        actionId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
    return 'creator_${p}_$a';
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final List<Map<String, dynamic>> files =
        store.scanFiles(creatorDir, extensions: const <String>{'.json'});
    for (final Map<String, dynamic> f in files) {
      final String name = (f['name'] ?? '').toString();
      if (name.isEmpty || name.startsWith('_')) continue;
      final Map<String, dynamic> raw =
          await store.readJson('$creatorDir/$name');
      final CreatorManifest? manifest = CreatorManifest.tryParse(raw);
      if (manifest == null || manifest.id.isEmpty) {
        loadError = '跳过无法解析的插件文件：$creatorDir/$name';
        continue;
      }
      _catalog[manifest.id] = manifest;
    }
  }

  /// 本地 catalog：manifest + 真实激活状态 + 工具名 + 落盘路径。
  Future<List<Map<String, dynamic>>> list() async {
    await _ensureLoaded();
    final List<Map<String, dynamic>> out = _catalog.values.map(
      (CreatorManifest m) {
        final _ActiveCreator? active = _active[m.id];
        return <String, dynamic>{
          ...m.toJson(),
          'active': active != null,
          'plugin_id': active?.pluginId ?? '',
          'tools': active?.toolNames ?? const <String>[],
          'registered_to_kernel': active?.registeredToKernel ?? false,
          'file': '$creatorDir/${m.id}.json',
        };
      },
    ).toList();
    out.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));
    return out;
  }

  Future<CreatorManifest?> manifest(String id) async {
    await _ensureLoaded();
    return _catalog[id];
  }

  /// 校验 manifest（接受 JSON 字符串、已解码 Map 或 [CreatorManifest]）。
  /// 不写盘、不改状态。
  CreatorValidation validate(Object json) {
    final List<String> errors = <String>[];
    final List<String> warnings = <String>[];
    Object? decoded = json is CreatorManifest ? json.toJson() : json;
    if (json is String) {
      try {
        decoded = jsonDecode(json);
      } on Object catch (e) {
        return CreatorValidation(<String>['JSON 解析失败：$e'], const <String>[]);
      }
    }
    final CreatorManifest? manifest = CreatorManifest.tryParse(decoded);
    if (manifest == null) {
      return CreatorValidation(
        <String>['manifest 必须是 JSON 对象，且 actions 必须是对象数组'],
        warnings,
      );
    }
    _validateManifest(manifest, errors, warnings);
    return CreatorValidation(errors, warnings);
  }

  void _validateManifest(
    CreatorManifest m,
    List<String> errors,
    List<String> warnings,
  ) {
    if (m.id.isEmpty) {
      errors.add('缺少 id');
    } else if (m.id.length > 80 || !_manifestIdPattern.hasMatch(m.id)) {
      errors.add(
          'id「${m.id}」不合法：需小写开头，只含 a-z0-9 与 . _ -，且不以分隔符结尾');
    }
    if (m.name.isEmpty) {
      errors.add('缺少 name');
    } else if (m.name.length > 80) {
      errors.add('name 不能超过 80 个字符');
    }
    if (m.description.isEmpty) {
      warnings.add('缺少 description（建议说明插件用途）');
    }
    if (m.version.isEmpty) {
      errors.add('缺少 version');
    } else if (!_versionPattern.hasMatch(m.version)) {
      errors.add('version「${m.version}」不是合法语义版本（示例 1.0.0）');
    }
    const Set<String> knownPermissions = <String>{'prompt', 'network', 'shell'};
    for (final String p in m.permissions) {
      if (!knownPermissions.contains(p)) warnings.add('未知权限声明：$p');
    }
    if (m.permissions.contains('shell')) {
      warnings.add('已声明 shell 权限：插件可执行本机命令，请只激活可信 manifest');
    }
    if (m.actions.isEmpty && m.uiSlots.isEmpty && m.policies.isEmpty) {
      errors.add('actions / ui_slots / policies 至少需要一项');
    }
    if (m.actions.length > 64) {
      errors.add('actions 数量过多（上限 64）');
    }
    for (final MapEntry<String, Map<String, dynamic>> slot
        in m.uiSlots.entries) {
      if (slot.value.isEmpty) {
        warnings.add('UI 槽位「${slot.key}」为空对象，界面将没有可渲染内容');
      }
    }
    for (final MapEntry<String, Map<String, dynamic>> policy
        in m.policies.entries) {
      if (!policy.value.containsKey('allow') &&
          !policy.value.containsKey('ask') &&
          !policy.value.containsKey('deny')) {
        warnings.add('权限策略「${policy.key}」未声明 allow/ask/deny');
      }
    }
    final Set<String> actionIds = <String>{};
    for (final CreatorAction a in m.actions) {
      final String prefix = a.id.isEmpty ? '未命名动作' : '动作「${a.id}」';
      if (a.id.isEmpty) {
        errors.add('有动作缺少 id');
      } else if (!_actionIdPattern.hasMatch(a.id)) {
        errors.add('$prefix 的 id 不合法：需小写开头，只含 a-z0-9 _ -');
      } else if (!actionIds.add(a.id)) {
        errors.add('动作 id「${a.id}」重复');
      }
      if (!_actionTypes.contains(a.type)) {
        errors.add('$prefix 的类型「${a.type}」未知（仅支持 prompt/http/shell/mcp）');
        continue;
      }
      if (a.type == 'mcp' && (a.server.isEmpty || a.tool.isEmpty)) {
        errors.add('$prefix 的 mcp 动作必须声明 server 与 tool');
      }
      for (final String r in a.requiredArgs) {
        if (!_actionIdPattern.hasMatch(r)) {
          warnings.add('$prefix 的必填参数名「$r」不是标准标识符，模板替换仍按字面匹配');
        }
      }
      switch (a.type) {
        case 'prompt':
          if (a.promptTemplate.trim().isEmpty) {
            errors.add('$prefix 是 prompt 动作，必须提供非空 template');
          }
          break;
        case 'http':
          if (!_httpMethods.contains(a.method.toUpperCase())) {
            errors.add('$prefix 的 method「${a.method}」不支持（仅 $_httpMethods）');
          }
          final Uri? uri = Uri.tryParse(a.url);
          if (uri == null || !uri.hasScheme) {
            errors.add('$prefix 的 url 必须是绝对的 http/https 地址');
          } else if (uri.scheme != 'http' && uri.scheme != 'https') {
            errors.add('$prefix 的 url 协议「${uri.scheme}」被拒绝（仅 http/https）');
          } else {
            if (uri.host.isEmpty) {
              errors.add('$prefix 的 url 缺少主机名');
            }
            if (uri.userInfo.isNotEmpty) {
              errors.add('$prefix 的 url 不得内嵌凭据（user:pass@host）');
            }
            if (!isHostAllowed(uri.host)) {
              warnings.add(
                  '$prefix 的主机「${uri.host}」不在 HTTP allowlist 内，运行时将拒绝网络请求');
            }
          }
          if (!m.permissions.contains('network')) {
            errors.add('$prefix 是 http 动作，permissions 必须包含 network');
          }
          for (final String h in a.headers.keys) {
            final String lower = h.toLowerCase();
            if (lower == 'authorization' ||
                lower == 'cookie' ||
                lower == 'proxy-authorization') {
              warnings.add(
                  '$prefix 的 $h 头默认不会发送（allowCredentialHeaders=false）');
            }
          }
          break;
        case 'shell':
          if (a.command.trim().isEmpty) {
            errors.add('$prefix 是 shell 动作，必须提供非空 command');
          }
          if (!m.permissions.contains('shell')) {
            errors.add(
                '$prefix 需要 permissions 显式包含 shell（默认拒绝执行本机命令）');
          }
          break;
      }
    }
    for (final String dep in m.dependencies) {
      if (!_active.containsKey(dep)) {
        warnings.add('依赖「$dep」当前未激活，激活本插件时会被拒绝');
      }
    }
  }

  /// host 白名单匹配：精确 host 或 `*.suffix`。空 allowlist 一律拒绝。
  bool isHostAllowed(String host) {
    final String target = host.toLowerCase();
    if (target.isEmpty || allowedHosts.isEmpty) return false;
    for (final String rule in allowedHosts) {
      final String r = rule.toLowerCase();
      if (r == target) return true;
      if (r.startsWith('*.')) {
        final String suffix = r.substring(1); // ".example.com"
        if (target.endsWith(suffix) && target.length > suffix.length) {
          return true;
        }
      }
    }
    return false;
  }

  /// 保存 manifest 到 `plugins/creator/<id>.json` 并进 catalog。
  /// 已激活的插件会在保存后重载（停用 → 激活）；重载失败会如实附在结果里。
  Future<Map<String, dynamic>> save(Object json) async {
    await _ensureLoaded();
    final CreatorValidation v = validate(json);
    if (!v.ok) {
      return <String, dynamic>{
        'ok': false,
        'error': '校验未通过：${v.errors.join('；')}',
        'errors': v.errors,
        'warnings': v.warnings,
      };
    }
    Object? decoded = json is CreatorManifest ? json.toJson() : json;
    if (json is String) decoded = jsonDecode(json);
    if (decoded is Map) {
      decoded = decoded.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v));
    }
    final CreatorManifest? manifest = CreatorManifest.tryParse(decoded);
    if (manifest == null) {
      return <String, dynamic>{'ok': false, 'error': 'manifest 结构无法解析'};
    }
    final bool wasActive = _active.containsKey(manifest.id);
    if (wasActive) {
      final Map<String, dynamic> off = await deactivate(manifest.id);
      if (off['ok'] != true) {
        return <String, dynamic>{
          'ok': false,
          'error': '停用旧版本失败，未覆盖文件：${off['error']}',
        };
      }
    }
    final String relative = '$creatorDir/${manifest.id}.json';
    await store.writeJson(relative, manifest.toJson());
    final bool replaced = _catalog.containsKey(manifest.id);
    _catalog[manifest.id] = manifest;
    final Map<String, dynamic> result = <String, dynamic>{
      'ok': true,
      'id': manifest.id,
      'path': store.file(relative).path,
      'replaced': replaced,
      'warnings': v.warnings,
    };
    if (wasActive) {
      final Map<String, dynamic> on = await activate(manifest.id);
      result['reactivated'] = on['ok'] == true;
      if (on['ok'] != true) result['reactivate_error'] = on['error'];
    }
    return result;
  }

  /// 把已保存插件真实注册进注入的 kernel；未注入时登记内部激活表。
  Future<Map<String, dynamic>> activate(String id) async {
    await _ensureLoaded();
    final CreatorManifest? manifest = _catalog[id];
    if (manifest == null) {
      return <String, dynamic>{'ok': false, 'error': '插件 $id 未保存到本地 catalog'};
    }
    if (_active.containsKey(id)) {
      return <String, dynamic>{'ok': false, 'error': '插件 $id 已激活'};
    }
    final CreatorValidation v = validate(manifest.toJson());
    if (!v.ok) {
      return <String, dynamic>{
        'ok': false,
        'error': '校验未通过，拒绝激活：${v.errors.join('；')}',
        'errors': v.errors,
        'warnings': v.warnings,
      };
    }
    for (final CreatorAction a in manifest.actions) {
      if (a.type == 'http' && !manifest.permissions.contains('network')) {
        return <String, dynamic>{
          'ok': false,
          'error': '动作「${a.id}」需要 network 权限，拒绝激活',
        };
      }
      if (a.type == 'shell' && !manifest.permissions.contains('shell')) {
        return <String, dynamic>{
          'ok': false,
          'error': '动作「${a.id}」需要显式 shell 授权，拒绝激活',
        };
      }
    }
    for (final String dep in manifest.dependencies) {
      if (!_active.containsKey(dep)) {
        return <String, dynamic>{
          'ok': false,
          'error': '依赖插件「$dep」未激活，拒绝激活（不假装就绪）',
          'missing_dependency': dep,
        };
      }
    }
    final String pluginId = pluginIdFor(id);
    final List<String> tools = manifest.actions
        .map((CreatorAction a) => toolName(pluginId, a.id))
        .toList();
    if (kernel != null) {
      final _CreatorPlugin plugin = _CreatorPlugin(manifest, this);
      kernel!.registerPlugin(plugin);
      Map<String, dynamic> mounted =
          await kernel!.mount(pluginId, source: 'creator');
      if (mounted['ok'] != true &&
          (mounted['error'] ?? '').toString().contains('已挂载')) {
        await kernel!.unmount(pluginId, reason: 'creator:reload');
        kernel!.registerPlugin(plugin);
        mounted = await kernel!.mount(pluginId, source: 'creator');
      }
      if (mounted['ok'] != true) {
        return <String, dynamic>{
          'ok': false,
          'error': '注册到内核失败：${mounted['error'] ?? '未知原因'}',
        };
      }
    }
    _active[id] = _ActiveCreator(
      manifest: manifest,
      pluginId: pluginId,
      toolNames: tools,
      registeredToKernel: kernel != null,
    );
    return <String, dynamic>{
      'ok': true,
      'id': id,
      'plugin_id': pluginId,
      'tools': tools,
      'registered_to_kernel': kernel != null,
      'warnings': v.warnings,
    };
  }

  /// 停用：先在 kernel 上真实卸载（失败就保持激活状态，不谎称已停用），
  /// 再移除内部激活表。停用后 [run] 一律拒绝。
  Future<Map<String, dynamic>> deactivate(String id) async {
    await _ensureLoaded();
    final _ActiveCreator? active = _active[id];
    if (active == null) {
      return <String, dynamic>{'ok': false, 'error': '插件 $id 未激活'};
    }
    if (kernel != null) {
      final Map<String, dynamic> unmounted =
          await kernel!.unmount(active.pluginId, reason: 'creator:deactivate');
      if (unmounted['ok'] != true) {
        return <String, dynamic>{
          'ok': false,
          'error': '撤销内核挂载失败：${unmounted['error'] ?? '未知原因'}',
        };
      }
    }
    _active.remove(id);
    return <String, dynamic>{'ok': true, 'id': id};
  }

  /// 执行已激活插件的一个动作。`pluginId` 用于动作 id 跨插件重名时消歧。
  Future<Map<String, dynamic>> run(
    String actionId, [
    Map<String, dynamic> args = const <String, dynamic>{},
    String? pluginId,
  ]) async {
    await _ensureLoaded();
    _ActiveCreator? owner;
    if (pluginId != null && pluginId.isNotEmpty) {
      owner = _active[pluginId];
      if (owner == null) {
        return <String, dynamic>{
          'ok': false,
          'error': '插件 $pluginId 未激活，拒绝运行',
        };
      }
    } else {
      final List<_ActiveCreator> matches = _active.values
          .where((_ActiveCreator a) =>
              a.manifest.actions.any((CreatorAction x) => x.id == actionId))
          .toList();
      if (matches.isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'error': '动作「$actionId」未激活（请先激活对应插件）',
        };
      }
      if (matches.length > 1) {
        return <String, dynamic>{
          'ok': false,
          'error': '动作「$actionId」存在于多个已激活插件，请指定 pluginId',
          'candidates': matches.map((_ActiveCreator a) => a.manifest.id).toList(),
        };
      }
      owner = matches.first;
    }
    final List<CreatorAction> found = owner.manifest.actions
        .where((CreatorAction a) => a.id == actionId)
        .toList();
    if (found.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': '插件 ${owner.manifest.id} 没有动作「$actionId」',
      };
    }
    final CreatorAction action = found.first;
    final List<String> missing = action.requiredArgs
        .where((String k) => !args.containsKey(k))
        .toList();
    if (missing.isNotEmpty) {
      return <String, dynamic>{
        'ok': false,
        'type': action.type,
        'error': '缺少必填参数：${missing.join(', ')}',
      };
    }
    try {
      switch (action.type) {
        case 'prompt':
          return await _runPrompt(owner.manifest, action, args);
        case 'http':
          return await _runHttp(action, args);
        case 'shell':
          return await _runShell(owner.manifest, action, args);
        case 'mcp':
          return await _runMcp(action, args);
      }
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'type': action.type,
        'error': '执行失败：$e',
      };
    }
    return <String, dynamic>{
      'ok': false,
      'type': action.type,
      'error': '未知 action 类型「${action.type}」',
    };
  }

  /// `{{key}}` 模板替换；未提供的占位符按字面保留，并在 [unresolved] 记录。
  String renderTemplate(
    String template,
    Map<String, dynamic> args, {
    List<String>? unresolved,
  }) {
    return template.replaceAllMapped(_placeholderPattern, (Match match) {
      final String key = match.group(1) ?? '';
      if (args.containsKey(key) && args[key] != null) {
        return args[key].toString();
      }
      unresolved?.add(key);
      return match.group(0) ?? '';
    });
  }

  Future<Map<String, dynamic>> _runPrompt(
    CreatorManifest manifest,
    CreatorAction action,
    Map<String, dynamic> args,
  ) async {
    final CreatorChatHandler? handler = chat;
    if (handler == null) {
      return <String, dynamic>{
        'ok': false,
        'type': 'prompt',
        'error': '未注入 chat 回调，拒绝伪造模型回复',
      };
    }
    final List<String> unresolved = <String>[];
    final String prompt =
        renderTemplate(action.promptTemplate, args, unresolved: unresolved);
    final Map<String, dynamic> reply =
        await handler(prompt, Map<String, dynamic>.of(args));
    if (reply['ok'] == false) {
      return <String, dynamic>{
        'ok': false,
        'type': 'prompt',
        'prompt': prompt,
        'error': (reply['error'] ?? 'chat 回调返回失败').toString(),
      };
    }
    return <String, dynamic>{
      'ok': true,
      'type': 'prompt',
      'plugin': manifest.id,
      'action': action.id,
      'prompt': prompt,
      if (unresolved.isNotEmpty) 'unresolved': unresolved,
      'result': reply,
    };
  }

  Future<Map<String, dynamic>> _runHttp(
    CreatorAction action,
    Map<String, dynamic> args,
  ) async {
    final Uri? uri = Uri.tryParse(action.url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'type': 'http',
        'error': '仅允许 http/https 绝对地址，且必须包含主机名',
      };
    }
    if (!isHostAllowed(uri.host)) {
      return <String, dynamic>{
        'ok': false,
        'type': 'http',
        'error': '目标主机「${uri.host}」不在 HTTP allowlist 内，拒绝网络请求',
        'allowlist': allowedHosts.toList(),
      };
    }
    final int timeoutMs = action.timeoutMs.clamp(500, 30000).toInt();
    final Duration timeout = Duration(milliseconds: timeoutMs);
    final HttpClient client = httpClientFactory?.call() ?? HttpClient();
    client.connectionTimeout = timeout;
    final List<String> dropped = <String>[];
    try {
      final HttpClientRequest request =
          await client.openUrl(action.method.toUpperCase(), uri).timeout(timeout);
      // 不跟随重定向，避免 allowlist 之外的地址被间接触达。
      request.followRedirects = false;
      action.headers.forEach((String key, String value) {
        final String lower = key.toLowerCase();
        if (!allowCredentialHeaders &&
            (lower == 'authorization' ||
                lower == 'cookie' ||
                lower == 'proxy-authorization')) {
          dropped.add(key);
          return;
        }
        if (lower == 'host' || lower == 'content-length') return;
        request.headers.set(key, value);
      });
      request.headers.set('User-Agent', 'TangramCreatorRuntime/1.0');
      final HttpClientResponse response =
          await request.close().timeout(timeout);
      final Map<String, String> responseHeaders = <String, String>{};
      response.headers.forEach((String name, List<String> values) {
        responseHeaders[name] = values.join(', ');
      });
      if (response.statusCode >= 300 && response.statusCode < 400) {
        await response.drain<void>().timeout(timeout);
        return <String, dynamic>{
          'ok': true,
          'type': 'http',
          'status': response.statusCode,
          'headers': responseHeaders,
          'location': response.headers.value('location') ?? '',
          'body': '',
          'redirect_blocked': true,
          'dropped_headers': dropped,
        };
      }
      final List<int> bytes = <int>[];
      await for (final List<int> chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > maxResponseBytes) {
          return <String, dynamic>{
            'ok': false,
            'type': 'http',
            'status': response.statusCode,
            'error': '响应超过 $maxResponseBytes 字节上限，已中止读取',
            'dropped_headers': dropped,
          };
        }
        bytes.addAll(chunk);
      }
      return <String, dynamic>{
        'ok': true,
        'type': 'http',
        'status': response.statusCode,
        'headers': responseHeaders,
        'body': utf8.decode(bytes, allowMalformed: true),
        'bytes': bytes.length,
        'dropped_headers': dropped,
      };
    } on TimeoutException {
      return <String, dynamic>{
        'ok': false,
        'type': 'http',
        'error': '请求超时（${timeoutMs}ms）',
      };
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'type': 'http',
        'error': 'HTTP 请求失败：$e',
      };
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _runShell(
    CreatorManifest manifest,
    CreatorAction action,
    Map<String, dynamic> args,
  ) async {
    if (!manifest.permissions.contains('shell')) {
      return <String, dynamic>{
        'ok': false,
        'type': 'shell',
        'error': '插件未声明 shell 权限，默认拒绝执行',
      };
    }
    final CreatorShellHandler? handler = shell;
    if (handler == null) {
      return <String, dynamic>{
        'ok': false,
        'type': 'shell',
        'error': '未注入 shell 回调，拒绝执行',
      };
    }
    final String command = renderTemplate(action.command, args);
    if (command.trim().isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'type': 'shell',
        'error': 'shell 命令为空',
      };
    }
    final Map<String, dynamic> result = await handler(command, store.root.path);
    if (result['ok'] == false) {
      return <String, dynamic>{
        'ok': false,
        'type': 'shell',
        'command': command,
        'error': (result['error'] ?? 'shell 回调返回失败').toString(),
      };
    }
    return <String, dynamic>{
      'ok': true,
      'type': 'shell',
      'plugin': manifest.id,
      'action': action.id,
      'command': command,
      'result': result,
    };
  }

  Future<Map<String, dynamic>> _runMcp(
    CreatorAction action,
    Map<String, dynamic> args,
  ) async {
    final CreatorMcpHandler? handler = mcp;
    if (handler == null) {
      return <String, dynamic>{
        'ok': false,
        'type': 'mcp',
        'error': '未接入 MCP 执行器（请在宿主注入 mcp 回调）',
      };
    }
    final Map<String, dynamic> result =
        await handler(action.server, action.tool, args);
    return <String, dynamic>{
      'ok': result['ok'] != false,
      'type': 'mcp',
      'server': action.server,
      'tool': action.tool,
      'result': result,
      if (result['ok'] == false)
        'error': (result['error'] ?? 'MCP 工具返回失败').toString(),
    };
  }

  /// 导出单个 manifest 的格式化 JSON。
  Future<Map<String, dynamic>> exportJson(String id) async {
    await _ensureLoaded();
    final CreatorManifest? m = _catalog[id];
    if (m == null) {
      return <String, dynamic>{'ok': false, 'error': '插件 $id 不存在'};
    }
    return <String, dynamic>{
      'ok': true,
      'id': id,
      'json': const JsonEncoder.withIndent('  ').convert(m.toJson()),
    };
  }

  /// 导入 manifest JSON：先校验，通过后走 [save] 真实落盘。
  Future<Map<String, dynamic>> importJson(String json) async {
    final CreatorValidation v = validate(json);
    if (!v.ok) {
      return <String, dynamic>{
        'ok': false,
        'error': '导入被拒绝：${v.errors.join('；')}',
        'errors': v.errors,
        'warnings': v.warnings,
      };
    }
    final Map<String, dynamic> saved = await save(json);
    return <String, dynamic>{...saved, 'imported': saved['ok'] == true};
  }

  /// 删除插件文件并从 catalog 移除；激活中的插件先真实停用。
  Future<Map<String, dynamic>> delete(String id) async {
    await _ensureLoaded();
    if (!_catalog.containsKey(id)) {
      return <String, dynamic>{'ok': false, 'error': '插件 $id 不存在'};
    }
    if (_active.containsKey(id)) {
      final Map<String, dynamic> off = await deactivate(id);
      if (off['ok'] != true) {
        return <String, dynamic>{
          'ok': false,
          'error': '停用失败，取消删除：${off['error']}',
        };
      }
    }
    final File file = store.file('$creatorDir/$id.json');
    final bool existed = await file.exists();
    if (existed) await file.delete();
    _catalog.remove(id);
    return <String, dynamic>{'ok': true, 'id': id, 'deleted': existed};
  }
}

/// 激活到内核的桥接插件：每个动作注册一个真实 [AgentTool]，
/// 由 [PluginContext.registerTool] 的可逆 effect 在 unmount 时撤销。
class _CreatorPlugin extends Plugin {
  _CreatorPlugin(this.manifest, this.runtime);

  final CreatorManifest manifest;
  final CreatorRuntime runtime;

  @override
  String get id => runtime.pluginIdFor(manifest.id);

  @override
  String get name => manifest.name;

  @override
  String get version => manifest.version;

  @override
  String get description => manifest.description;

  /// 用户自建插件＝T2（不是内核自带的 T1）。
  /// 分级目前只在 consumeSeam 判定，等能力门接线后此处即生效。
  @override
  PluginTier get tier => PluginTier.user;

  @override
  List<String> get providesSeams => const <String>[];

  @override
  Future<void> apply(PluginContext ctx) async {
    ctx.provideService('creator.${manifest.id}', this);
    for (final MapEntry<String, Map<String, dynamic>> slot
        in manifest.uiSlots.entries) {
      ctx.registerWidgetSlot(
        'creator.${manifest.id}.${slot.key}',
        <String, dynamic>{
          ...slot.value,
          'plugin': manifest.id,
          'slot': slot.key,
        },
      );
    }
    for (final MapEntry<String, Map<String, dynamic>> policy
        in manifest.policies.entries) {
      ctx.registerPermissionPolicy(
        'creator.${manifest.id}.${policy.key}',
        <String, dynamic>{
          ...policy.value,
          'plugin': manifest.id,
        },
      );
    }
    for (final CreatorAction action in manifest.actions) {
      final String toolName = runtime.toolName(manifest.id, action.id);
      ctx.registerTool(AgentTool(
        name: toolName,
        label: '${manifest.name} · ${action.id}',
        description: '${manifest.description.isEmpty ? manifest.name : manifest.description}'
            '（${action.type} 动作）',
        tier: action.type == 'prompt' ? ApprovalTier.read : ApprovalTier.exec,
        parameters: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            for (final String key in action.requiredArgs)
              key: <String, dynamic>{'type': 'string'},
          },
          'required': action.requiredArgs,
        },
        execute: (Map<String, dynamic> arguments, CancelToken? cancelToken) async {
          final Map<String, dynamic> result =
              await runtime.run(action.id, arguments, manifest.id);
          if (result['ok'] == true) {
            return ToolResult.ok(jsonEncode(result), data: result);
          }
          return ToolResult.error(
              (result['error'] ?? 'Creator 动作执行失败').toString());
        },
      ));
    }
  }
}
