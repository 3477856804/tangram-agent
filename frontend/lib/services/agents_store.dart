import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一个自定义智能体的完整定义：对话人设 + 子 Agent 角色配置。
///
/// 所有字段都真实持久化在 agents.json；旧版只有
/// id/name/description/systemPrompt/enabled，缺失字段在 [fromJson] 中回退默认。
class TgaAgent {
  TgaAgent({
    required this.id,
    required this.name,
    this.description = '',
    this.systemPrompt = '',
    this.enabled = true,
    String? role,
    List<String>? knowledgeIds,
    Map<String, dynamic>? permissions,
    int maxSteps = defaultMaxSteps,
    this.executionEnabled = false,
    String? modelId,
    String memoryScope = 'isolated',
    this.updatedAt = 0,
  })  : role = normalizeRole(role),
        knowledgeIds = normalizeKnowledgeIds(knowledgeIds),
        permissions = permissions ?? defaultPermissions(),
        maxSteps = clampMaxSteps(maxSteps),
        modelId = normalizeModelId(modelId),
        memoryScope = normalizeMemoryScope(memoryScope);

  static const int defaultMaxSteps = 6;
  static const int minMaxSteps = 1;
  static const int maxMaxSteps = 20;
  static const String scopeIsolated = 'isolated';
  static const String scopeShared = 'shared';
  static const Set<String> _permissionKeys = <String>{'tools', 'files', 'note'};
  static const Set<String> _toolModes = <String>{'allow', 'ask', 'deny'};

  final String id;
  final String name;
  final String description;
  final String systemPrompt;

  /// 对话人设注入开关（与 [executionEnabled] 完全独立）。
  final bool enabled;

  /// 角色标签，如 researcher / writer / reviewer / operator；null 表示未设置。
  final String? role;

  /// 绑定的私有知识库 id（KnowledgeBase 的 library id）。
  final List<String> knowledgeIds;

  /// 权限策略：tools(allow/ask/deny) + files(正则) + note。
  /// 默认最小权限：不 allow 任何工具、deny `*`、无文件规则。
  final Map<String, dynamic> permissions;

  /// 作为子 Agent 执行时的最大步数，构造时强制 clamp 到 1~20。
  final int maxSteps;

  /// 是否允许作为子 Agent 被调度（与 [enabled] 独立）。
  final bool executionEnabled;

  /// 偏好模型 id；null 表示沿用全局模型。
  final String? modelId;

  /// 'isolated'（默认，仅自己的记忆文件）或 'shared'（可只读全局 turns）。
  final String memoryScope;

  /// 最近一次变更时间（毫秒时间戳），0 表示旧数据从未记录。
  final int updatedAt;

  // ------------------------------------------------------------------
  // 默认值 / 归一化 / 校验
  // ------------------------------------------------------------------

  static Map<String, dynamic> defaultPermissions() => <String, dynamic>{
        'tools': <String, dynamic>{
          'allow': <String>[],
          'ask': <String>[],
          'deny': <String>['*'],
        },
        'files': '',
        'note': '',
      };

  static int clampMaxSteps(int value) =>
      value.clamp(minMaxSteps, maxMaxSteps).toInt();

  static String? normalizeRole(String? value) {
    final String v = (value ?? '').trim();
    return v.isEmpty ? null : v;
  }

  static String? normalizeModelId(String? value) {
    final String v = (value ?? '').trim();
    return v.isEmpty ? null : v;
  }

  static String normalizeMemoryScope(String value) =>
      value == scopeShared ? scopeShared : scopeIsolated;

  static List<String> normalizeKnowledgeIds(List<String>? raw) {
    if (raw == null) return <String>[];
    final List<String> out = <String>[];
    for (final String id in raw) {
      final String v = id.trim();
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }
    return out;
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return <String>[];
    final List<String> out = <String>[];
    for (final dynamic item in raw) {
      final String v = item.toString().trim();
      if (v.isNotEmpty && !out.contains(v)) out.add(v);
    }
    return out;
  }

  /// 校验权限结构；返回 null 表示合法，否则返回可直接展示的错误文案。
  ///
  /// 结构：`{tools:{allow:[],ask:[],deny:[]}, files:"正则", note:"说明"}`。
  /// tools 只允许 allow/ask/deny 三个键；allow/ask 与 deny 不允许冲突。
  static String? validatePermissions(Map<String, dynamic>? permissions) {
    if (permissions == null) return null;
    for (final String key in permissions.keys) {
      if (!_permissionKeys.contains(key)) return '未知权限字段：$key';
    }
    final dynamic tools = permissions['tools'];
    if (tools != null) {
      if (tools is! Map) return 'tools 必须是对象';
      for (final dynamic rawKey in tools.keys) {
        final String key = rawKey.toString();
        if (!_toolModes.contains(key)) return 'tools 仅支持 allow/ask/deny';
        final dynamic list = tools[rawKey];
        if (list is! List) return 'tools.$key 必须是数组';
        final Set<String> seen = <String>{};
        for (final dynamic item in list) {
          if (item is! String || item.trim().isEmpty) {
            return 'tools.$key 只能包含非空字符串';
          }
          if (!seen.add(item.trim())) {
            return 'tools.$key 存在重复工具：${item.trim()}';
          }
        }
      }
      final Set<String> allow = _stringList(tools['allow']).toSet();
      final Set<String> ask = _stringList(tools['ask']).toSet();
      final Set<String> deny = _stringList(tools['deny']).toSet();
      final Set<String> allowDeny = allow.intersection(deny);
      if (allowDeny.isNotEmpty) {
        return '工具不能同时 allow 与 deny：${allowDeny.first}';
      }
      final Set<String> askDeny = ask.intersection(deny);
      if (askDeny.isNotEmpty) {
        return '工具不能同时 ask 与 deny：${askDeny.first}';
      }
    }
    final dynamic files = permissions['files'];
    if (files != null) {
      if (files is! String) return 'files 必须是正则字符串';
      if (files.trim().isNotEmpty) {
        try {
          RegExp(files.trim());
        } on FormatException catch (e) {
          return 'files 不是合法正则：${e.message}';
        }
      }
    }
    final dynamic note = permissions['note'];
    if (note != null && note is! String) return 'note 必须是字符串';
    return null;
  }

  /// 把任意输入归一化为完整权限结构；结构非法时回退最小权限。
  static Map<String, dynamic> normalizePermissions(
      Map<String, dynamic>? raw) {
    if (raw == null || raw.isEmpty) return defaultPermissions();
    if (validatePermissions(raw) != null) return defaultPermissions();
    final dynamic rawTools = raw['tools'];
    final Map<String, dynamic> tools =
        rawTools is Map ? Map<String, dynamic>.from(rawTools) : <String, dynamic>{};
    final String files = (raw['files'] ?? '').toString().trim();
    final String note = (raw['note'] ?? '').toString().trim();
    return <String, dynamic>{
      'tools': <String, dynamic>{
        'allow': _stringList(tools['allow']),
        'ask': _stringList(tools['ask']),
        'deny': _stringList(tools['deny']),
      },
      'files': files,
      'note': note,
    };
  }

  static Map<String, dynamic> _sanitizePermissions(dynamic raw) {
    if (raw is Map) {
      final Map<String, dynamic> m = raw.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v));
      return normalizePermissions(m);
    }
    return defaultPermissions();
  }

  /// 校验整个智能体定义；返回 null 表示可保存。
  String? validate() {
    if (name.trim().isEmpty) return '名称不能为空';
    final String? permissionError = validatePermissions(permissions);
    if (permissionError != null) return permissionError;
    if (memoryScope != scopeIsolated && memoryScope != scopeShared) {
      return 'memoryScope 仅支持 isolated/shared';
    }
    return null;
  }

  // ------------------------------------------------------------------
  // 摘要（供列表与 system prompt 注入；绝不输出文件绝对路径）
  // ------------------------------------------------------------------

  int get toolAllowCount => _stringList(_tools['allow']).length;
  int get toolAskCount => _stringList(_tools['ask']).length;
  int get toolDenyCount => _stringList(_tools['deny']).length;

  String get _filesRule => (permissions['files'] ?? '').toString().trim();
  String get _note => (permissions['note'] ?? '').toString().trim();
  Map<dynamic, dynamic> get _tools =>
      permissions['tools'] is Map ? permissions['tools'] as Map : const <dynamic, dynamic>{};

  /// 列表展示的一行权限摘要（只给数量与是否配置，不泄露具体路径）。
  String get permissionSummary =>
      '工具 允许$toolAllowCount/确认$toolAskCount/禁止$toolDenyCount'
      '${_filesRule.isEmpty ? ' · 文件不限' : ' · 文件有规则'}'
      '${_note.isEmpty ? '' : ' · 有备注'}';

  /// 注入 system prompt 的权限边界摘要，刻意不包含 files 正则原文与 note 内容。
  String get permissionBoundarySummary =>
      '工具允许 $toolAllowCount 个、需确认 $toolAskCount 个、禁止 $toolDenyCount 个；'
      '文件范围${_filesRule.isEmpty ? '未限制' : '已配置正则规则（不展示内容）'}'
      '${_note.isEmpty ? '' : '；备注已配置'}';

  // ------------------------------------------------------------------
  // 序列化
  // ------------------------------------------------------------------

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'systemPrompt': systemPrompt,
        'enabled': enabled,
        'role': role,
        'knowledgeIds': knowledgeIds,
        'permissions': permissions,
        'maxSteps': maxSteps,
        'executionEnabled': executionEnabled,
        'modelId': modelId,
        'memoryScope': memoryScope,
        'updatedAt': updatedAt,
      };

  factory TgaAgent.fromJson(Map<String, dynamic> m) {
    final dynamic rawKnowledge = m['knowledgeIds'];
    final List<String> knowledge = <String>[];
    if (rawKnowledge is List) {
      for (final dynamic item in rawKnowledge) {
        final String v = item.toString().trim();
        if (v.isNotEmpty && !knowledge.contains(v)) knowledge.add(v);
      }
    }
    final dynamic rawSteps = m['maxSteps'];
    final int steps = rawSteps is num
        ? rawSteps.toInt()
        : int.tryParse('${rawSteps ?? ''}') ?? defaultMaxSteps;
    final dynamic rawUpdated = m['updatedAt'];
    final int updated = rawUpdated is num
        ? rawUpdated.toInt()
        : int.tryParse('${rawUpdated ?? ''}') ?? 0;
    return TgaAgent(
      id: (m['id'] ?? '').toString(),
      name: (m['name'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      systemPrompt: (m['systemPrompt'] ?? '').toString(),
      enabled: m['enabled'] != false,
      role: m['role']?.toString(),
      knowledgeIds: knowledge,
      permissions: _sanitizePermissions(m['permissions']),
      maxSteps: steps,
      executionEnabled: m['executionEnabled'] == true,
      modelId: m['modelId']?.toString(),
      memoryScope: (m['memoryScope'] ?? scopeIsolated).toString(),
      updatedAt: updated,
    );
  }

  static const Object _unset = Object();

  TgaAgent copyWith({
    String? id,
    String? name,
    String? description,
    String? systemPrompt,
    bool? enabled,
    Object? role = _unset,
    List<String>? knowledgeIds,
    Map<String, dynamic>? permissions,
    int? maxSteps,
    bool? executionEnabled,
    Object? modelId = _unset,
    String? memoryScope,
    int? updatedAt,
  }) =>
      TgaAgent(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        enabled: enabled ?? this.enabled,
        role: identical(role, _unset) ? this.role : role as String?,
        knowledgeIds: knowledgeIds ?? this.knowledgeIds,
        permissions: permissions ?? this.permissions,
        maxSteps: maxSteps ?? this.maxSteps,
        executionEnabled: executionEnabled ?? this.executionEnabled,
        modelId: identical(modelId, _unset) ? this.modelId : modelId as String?,
        memoryScope: memoryScope ?? this.memoryScope,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// 智能体中心持久化：App 文档目录 agents.json，真实落盘、重启可恢复。
///
/// 「启用」的智能体经 [enabledSystemPromptBlock] 注入对话 system prompt
/// （见 flai/providers/tangram_ai_provider.dart 的 persona 注入点）；
/// `executionEnabled` 只决定是否可作为子 Agent 被调度，不影响对话注入。
class AgentsStore {
  AgentsStore._(this._file);

  static AgentsStore? _instance;

  final File _file;
  final List<TgaAgent> _agents = <TgaAgent>[];

  List<TgaAgent> get agents => List<TgaAgent>.unmodifiable(_agents);

  /// 全局单例：解析文档目录并加载（读失败回退空态，绝不抛给 UI）。
  static Future<AgentsStore> instance() async {
    final AgentsStore? existing = _instance;
    if (existing != null) return existing;
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } on Object {
      base = Directory.systemTemp;
    }
    final AgentsStore store = AgentsStore._(File('${base.path}/agents.json'));
    await store._load();
    _instance = store;
    return store;
  }

  /// 在指定路径打开一个独立实例（用于测试/导入工具），真实读取磁盘。
  static Future<AgentsStore> openAt(String path) async {
    final AgentsStore store = AgentsStore._(File(path));
    await store._load();
    return store;
  }

  /// 测试注入全局单例；传 null 清除。仅影响 [instance]/[enabledSystemPromptBlock]。
  static void overrideForTest(AgentsStore? store) {
    _instance = store;
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final dynamic raw = jsonDecode(await _file.readAsString());
      if (raw is! List) return;
      _agents
        ..clear()
        ..addAll(raw.whereType<Map>().map((Map<dynamic, dynamic> m) =>
            TgaAgent.fromJson(m.map((dynamic k, dynamic v) =>
                MapEntry<String, dynamic>(k.toString(), v)))));
    } on Object {
      // 文件损坏按空态处理，不冒充数据。
    }
  }

  Future<void> _save() async {
    try {
      final File tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(
          jsonEncode(_agents.map((TgaAgent a) => a.toJson()).toList()),
          flush: true);
      await tmp.rename(_file.path);
    } on Object {
      // 落盘失败保持内存态，由 UI 如实提示重试。
    }
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  /// 新建智能体；名称/权限不合法时抛 [ArgumentError]，不写入任何数据。
  Future<TgaAgent> create({
    required String name,
    String description = '',
    String systemPrompt = '',
    String? role,
    List<String> knowledgeIds = const <String>[],
    Map<String, dynamic>? permissions,
    int maxSteps = TgaAgent.defaultMaxSteps,
    bool executionEnabled = false,
    String? modelId,
    String memoryScope = TgaAgent.scopeIsolated,
  }) async {
    final String? permissionError =
        TgaAgent.validatePermissions(permissions);
    if (permissionError != null) throw ArgumentError(permissionError);
    final TgaAgent agent = TgaAgent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      description: description.trim(),
      systemPrompt: systemPrompt.trim(),
      role: role,
      knowledgeIds: knowledgeIds,
      permissions:
          permissions == null ? null : TgaAgent.normalizePermissions(permissions),
      maxSteps: maxSteps,
      executionEnabled: executionEnabled,
      modelId: modelId,
      memoryScope: memoryScope,
      updatedAt: _now(),
    );
    final String? error = agent.validate();
    if (error != null) throw ArgumentError(error);
    _agents.add(agent);
    await _save();
    return agent;
  }

  /// 更新既有智能体的全部字段；校验失败抛 [ArgumentError]，不落盘。
  Future<void> update(TgaAgent agent) async {
    final int idx = _agents.indexWhere((TgaAgent a) => a.id == agent.id);
    if (idx < 0) return;
    final String? permissionError =
        TgaAgent.validatePermissions(agent.permissions);
    if (permissionError != null) throw ArgumentError(permissionError);
    final TgaAgent next = agent.copyWith(
      name: agent.name.trim(),
      description: agent.description.trim(),
      systemPrompt: agent.systemPrompt.trim(),
      knowledgeIds: TgaAgent.normalizeKnowledgeIds(agent.knowledgeIds),
      permissions: TgaAgent.normalizePermissions(agent.permissions),
      maxSteps: TgaAgent.clampMaxSteps(agent.maxSteps),
      memoryScope: TgaAgent.normalizeMemoryScope(agent.memoryScope),
      updatedAt: _now(),
    );
    final String? error = next.validate();
    if (error != null) throw ArgumentError(error);
    _agents[idx] = next;
    await _save();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final TgaAgent? agent = resolve(id);
    if (agent == null || agent.enabled == enabled) return;
    _agents[_agents.indexOf(agent)] =
        agent.copyWith(enabled: enabled, updatedAt: _now());
    await _save();
  }

  /// 翻转「对话注入」开关，返回翻转后的值；不存在返回 false。
  Future<bool> toggle(String id) async {
    final TgaAgent? agent = resolve(id);
    if (agent == null) return false;
    final bool next = !agent.enabled;
    await setEnabled(id, next);
    return next;
  }

  /// 独立设置「是否允许作为子 Agent 被调度」。
  Future<void> setExecution(String id, bool enabled) async {
    final TgaAgent? agent = resolve(id);
    if (agent == null || agent.executionEnabled == enabled) return;
    _agents[_agents.indexOf(agent)] =
        agent.copyWith(executionEnabled: enabled, updatedAt: _now());
    await _save();
  }

  Future<void> setKnowledge(String id, List<String> knowledgeIds) async {
    final TgaAgent? agent = resolve(id);
    if (agent == null) return;
    _agents[_agents.indexOf(agent)] = agent.copyWith(
      knowledgeIds: TgaAgent.normalizeKnowledgeIds(knowledgeIds),
      updatedAt: _now(),
    );
    await _save();
  }

  Future<void> remove(String id) async {
    _agents.removeWhere((TgaAgent a) => a.id == id);
    await _save();
  }

  /// 按 id 查找智能体（不存在返回 null）。
  TgaAgent? resolve(String id) {
    for (final TgaAgent a in _agents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// 导出全部智能体为格式化 JSON 数组（与 agents.json 同构）。
  String exportJson() =>
      const JsonEncoder.withIndent('  ').convert(
          _agents.map((TgaAgent a) => a.toJson()).toList(growable: false));

  /// 导入全部智能体 JSON：支持裸数组或 `{"agents":[...]}`。
  ///
  /// 任一条目名称/权限结构非法则整体拒绝（不写入半份数据）；
  /// 同 id 覆盖旧记录，缺 id 自动生成。返回 `{ok, imported}` 或 `{ok:false,error}`。
  Future<Map<String, dynamic>> importJson(String json) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'JSON 解析失败：$e'};
    }
    dynamic rawList;
    if (decoded is List) {
      rawList = decoded;
    } else if (decoded is Map && decoded['agents'] is List) {
      rawList = decoded['agents'];
    } else {
      return <String, dynamic>{
        'ok': false,
        'error': '需要 JSON 数组或 {"agents":[...]} 结构',
      };
    }
    final List<TgaAgent> parsed = <TgaAgent>[];
    final Set<String> seenIds = <String>{};
    for (int i = 0; i < (rawList as List).length; i++) {
      final dynamic raw = rawList[i];
      if (raw is! Map) {
        return <String, dynamic>{'ok': false, 'error': '第 ${i + 1} 条不是对象'};
      }
      final Map<String, dynamic> m = raw.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v));
      if ((m['name'] ?? '').toString().trim().isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'error': '第 ${i + 1} 条名称不能为空',
        };
      }
      final dynamic rawPermissions = m['permissions'];
      if (rawPermissions != null) {
        if (rawPermissions is! Map) {
          return <String, dynamic>{
            'ok': false,
            'error': '第 ${i + 1} 条 permissions 必须是对象',
          };
        }
        final Map<String, dynamic> permissions = rawPermissions
            .map((dynamic k, dynamic v) =>
                MapEntry<String, dynamic>(k.toString(), v));
        final String? permissionError =
            TgaAgent.validatePermissions(permissions);
        if (permissionError != null) {
          return <String, dynamic>{
            'ok': false,
            'error': '第 ${i + 1} 条权限不合法：$permissionError',
          };
        }
      }
      TgaAgent agent = TgaAgent.fromJson(m);
      if (agent.id.trim().isEmpty) {
        agent = agent.copyWith(
            id: '${DateTime.now().microsecondsSinceEpoch}-$i');
      }
      if (!seenIds.add(agent.id)) {
        return <String, dynamic>{
          'ok': false,
          'error': '导入数据存在重复 id：${agent.id}',
        };
      }
      if (agent.updatedAt <= 0) {
        agent = agent.copyWith(updatedAt: _now());
      }
      parsed.add(agent);
    }
    for (final TgaAgent imported in parsed) {
      final int idx = _agents.indexWhere((TgaAgent a) => a.id == imported.id);
      if (idx >= 0) {
        _agents[idx] = imported;
      } else {
        _agents.add(imported);
      }
    }
    await _save();
    return <String, dynamic>{'ok': true, 'imported': parsed.length};
  }

  /// 对话注入块：所有「启用且写了人设」的智能体 systemPrompt 拼成一段文本；
  /// 附带角色/权限边界摘要（不含文件绝对路径）。无启用项或读取失败返回空串。
  ///
  /// 只受 [TgaAgent.enabled] 影响；[TgaAgent.executionEnabled] 不参与此处判断。
  static Future<String> enabledSystemPromptBlock() async {
    try {
      final AgentsStore store = await instance();
      final List<TgaAgent> on = store._agents
          .where((TgaAgent a) => a.enabled && a.systemPrompt.trim().isNotEmpty)
          .toList();
      if (on.isEmpty) return '';
      final StringBuffer sb =
          StringBuffer('【自定义智能体人设（用户已启用，请在对话中遵循）】');
      for (final TgaAgent a in on) {
        sb.write('\n「${a.name}」：${a.systemPrompt.trim()}');
        final String role = a.role ?? '';
        if (role.isNotEmpty) sb.write('\n  角色：$role');
        sb.write('\n  权限边界：${a.permissionBoundarySummary}；'
            '记忆：${a.memoryScope}');
      }
      return sb.toString();
    } on Object {
      return '';
    }
  }
}
