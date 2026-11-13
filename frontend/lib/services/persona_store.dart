import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 应用配置唯一落盘处：人格设定、对话参数、模型选择、全局设置、身份与工作区域。
///
/// 全平台统一走 flutter_secure_storage（Android / iOS / 桌面 / Web 均有实现），
/// 读写失败时降级为内存态，不阻塞 UI。
class PersonaStore extends ChangeNotifier {
  static final FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _key = 'tangram.persona.v1';

  // 空表示尚未选择任何真实模型；不再预置编造的 'tangram-my-model'
  String selectedModelId = '';
  String systemPrompt = '';
  double temperature = 0.7;
  double topP = 0.9;
  int maxTokens = 2048;

  String language = '简体中文';
  String themeMode = '浅色';
  bool permissionFiles = false;
  bool permissionNotifications = false;

  /// TTS 音色（edge-tts voice shortName，如 zh-CN-XiaoyiNeural）；
  /// 空串 = 未选择，UI 显示默认「晓伊」。
  String voiceName = '';
  String voiceShortName = '';

  String? modelName;
  bool modelNameLocked = false;

  String? workspaceRoot;
  String sandboxEnvironment = '内置沙箱';
  String displayName = '个人';

  // ---- 人格 / 头像 / AI 名字（2026-11-13 真实化）----
  /// AI 名字（默认 TGA），人格页与系统提示词共用；
  /// 始终镜像当前激活人格的名字。
  String aiName = 'TGA';
  /// 自定义头像的应用文档目录绝对路径；null 表示使用内置 TGA 鹿标；
  /// 始终镜像当前激活人格的独立头像。
  String? avatarPath;
  /// 人格列表：每项含 name / avatarPath / identity / personality / audience。
  List<Persona> personas = <Persona>[Persona.defaultPersona()];
  /// 当前激活的人格 id。
  String activePersonaId = Persona.defaultId;
  /// 定时任务真实执行的防重记录：规则 id → 最近执行日（YYYY-MM-DD）。
  Map<String, String> taskLastRun = <String, String>{};

  bool _loaded = false;
  bool get loaded => _loaded;

  static Future<PersonaStore> load() async {
    final store = PersonaStore();
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final Map<String, dynamic> m =
              decoded.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
          store.selectedModelId =
              (m['selectedModelId'] ?? store.selectedModelId).toString();
          store.systemPrompt = (m['systemPrompt'] ?? '').toString();
          store.temperature = _asDouble(m['temperature'], 0.7);
          store.topP = _asDouble(m['topP'], 0.9);
          store.maxTokens = _asInt(m['maxTokens'], 2048);
          store.language = (m['language'] ?? store.language).toString();
          store.themeMode = (m['themeMode'] ?? store.themeMode).toString();
          store.voiceName = (m['voiceName'] ?? store.voiceName).toString();
          store.voiceShortName =
              (m['voiceShortName'] ?? store.voiceShortName).toString();
          store.permissionFiles = m['permissionFiles'] == true;
          store.permissionNotifications = m['permissionNotifications'] == true;
          store.modelName = m['modelName']?.toString();
          store.modelNameLocked = m['modelNameLocked'] == true;
          store.workspaceRoot = m['workspaceRoot']?.toString();
          store.sandboxEnvironment =
              (m['sandboxEnvironment'] ?? store.sandboxEnvironment).toString();
          store.displayName = (m['displayName'] ?? store.displayName).toString();
          // 新增字段全部向后兼容：旧 json 缺失时用默认值，绝不抛错。
          store.aiName = (m['aiName'] ?? store.aiName).toString();
          store.avatarPath = m['avatarPath']?.toString();
          final dynamic rawPersonas = m['personas'];
          if (rawPersonas is List && rawPersonas.isNotEmpty) {
            store.personas = rawPersonas
                .whereType<Map<dynamic, dynamic>>()
                .map((Map<dynamic, dynamic> e) => Persona.fromJson(
                    e.map((dynamic k, dynamic v) =>
                        MapEntry(k.toString(), v))))
                .toList();
            if (store.personas.isEmpty) {
              store.personas = <Persona>[Persona.defaultPersona()];
            }
          }
          final String activeId = (m['activePersonaId'] ?? '').toString();
          store.activePersonaId = store.personas.any((Persona p) => p.id == activeId)
              ? activeId
              : store.personas.first.id;
          // 老数据兼容：旧版只有全局头像，迁移给当时的激活人格，避免升级后头像丢失。
          if (store.avatarPath != null &&
              store.activePersona.avatarPath == null) {
            store.activePersona.avatarPath = store.avatarPath;
          }
          final dynamic rawLastRun = m['taskLastRun'];
          if (rawLastRun is Map) {
            store.taskLastRun = rawLastRun.map((dynamic k, dynamic v) =>
                MapEntry(k.toString(), v.toString()));
          }
        }
      }
    } on Object {
      // 存储不可用时保持默认内存态。
    }
    store._loaded = true;
    return store;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'selectedModelId': selectedModelId,
        'systemPrompt': systemPrompt,
        'temperature': temperature,
        'topP': topP,
        'maxTokens': maxTokens,
        'language': language,
        'themeMode': themeMode,
        'voiceName': voiceName,
        'voiceShortName': voiceShortName,
        'permissionFiles': permissionFiles,
        'permissionNotifications': permissionNotifications,
        'modelName': modelName,
        'modelNameLocked': modelNameLocked,
        'workspaceRoot': workspaceRoot,
        'sandboxEnvironment': sandboxEnvironment,
        'displayName': displayName,
        'aiName': aiName,
        'avatarPath': avatarPath,
        'personas': personas.map((Persona p) => p.toJson()).toList(),
        'activePersonaId': activePersonaId,
        'taskLastRun': taskLastRun,
      };

  Future<void> _persist() async {
    try {
      await _storage.write(key: _key, value: jsonEncode(toJson()));
    } on Object {
      // 落盘失败不阻断交互（例如桌面缺少密钥环）。
    }
  }

  void _update(void Function() mutate) {
    mutate();
    notifyListeners();
    _persist();
  }

  void setSelectedModelId(String id) => _update(() => selectedModelId = id);
  void setSystemPrompt(String v) => _update(() => systemPrompt = v);
  void setTemperature(double v) => _update(() => temperature = v);
  void setTopP(double v) => _update(() => topP = v);
  void setMaxTokens(int v) => _update(() => maxTokens = v);
  void setLanguage(String v) => _update(() => language = v);
  void setThemeMode(String v) => _update(() => themeMode = v);
  void setVoice(String name, String shortName) => _update(() {
        voiceName = name;
        voiceShortName = shortName;
      });
  void setPermissionFiles(bool v) => _update(() => permissionFiles = v);
  void setPermissionNotifications(bool v) =>
      _update(() => permissionNotifications = v);
  void setSandboxEnvironment(String v) =>
      _update(() => sandboxEnvironment = v);
  void setDisplayName(String v) => _update(() => displayName = v);
  void setWorkspaceRoot(String? v) => _update(() => workspaceRoot = v);

  // ---- 人格 / 头像 / AI 名字 ----

  void setAiName(String v) => _update(() => aiName = v);

  void setAvatarPath(String? v) => _update(() => avatarPath = v);

  /// 当前激活人格；id 失效（如外部导入旧数据）时兜底回第一项。
  Persona get activePersona {
    for (final Persona p in personas) {
      if (p.id == activePersonaId) return p;
    }
    final Persona first = personas.isNotEmpty
        ? personas.first
        : Persona.defaultPersona();
    activePersonaId = first.id;
    return first;
  }

  /// 把全局 [aiName] / [avatarPath] 镜像为当前激活人格的名字与头像：
  /// 人格页顶部、其他页面与系统提示词始终跟随激活人格。
  void _syncGlobalsFromActive() {
    final Persona p = activePersona;
    aiName = p.name;
    avatarPath = p.avatarPath;
  }

  /// 切换激活人格，并把新人格设定同步进系统提示词（真实影响对话）。
  void setActivePersonaId(String id) {
    if (!personas.any((Persona p) => p.id == id)) return;
    _update(() {
      activePersonaId = id;
      _syncGlobalsFromActive();
      systemPrompt = composeSystemPrompt();
    });
  }

  /// 新建人格（字段留空待用户编辑），并自动切换过去。
  void addPersona(String name) {
    final String trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final Persona p = Persona(
      id: 'persona-${DateTime.now().microsecondsSinceEpoch}',
      name: trimmed,
    );
    _update(() {
      personas.add(p);
      activePersonaId = p.id;
      _syncGlobalsFromActive();
      systemPrompt = composeSystemPrompt();
    });
  }

  /// 更新当前激活人格的任一设定字段，并同步系统提示词。
  void updateActivePersona({
    String? name,
    String? identity,
    String? personality,
    String? audience,
  }) {
    _update(() {
      final Persona p = activePersona;
      if (name != null && name.trim().isNotEmpty) p.name = name.trim();
      if (identity != null) p.identity = identity;
      if (personality != null) p.personality = personality;
      if (audience != null) p.audience = audience;
      _syncGlobalsFromActive();
      systemPrompt = composeSystemPrompt();
    });
  }

  /// 设置当前激活人格的独立头像（应用文档目录绝对路径；
  /// null = 恢复内置鹿标），并同步全局镜像字段。
  void setActivePersonaAvatar(String? v) {
    _update(() {
      activePersona.avatarPath = v;
      _syncGlobalsFromActive();
    });
  }

  /// 重置当前激活人格：三段文案恢复默认（保留名字）。
  void resetActivePersona() {
    _update(() {
      final Persona p = activePersona;
      p.identity = Persona.defaultIdentity;
      p.personality = Persona.defaultPersonality;
      p.audience = Persona.defaultAudience;
      systemPrompt = composeSystemPrompt();
    });
  }

  /// 删除人格；删空时自动补回默认人格，激活项失效时切到剩余第一项。
  void removePersona(String id) {
    _update(() {
      personas.removeWhere((Persona p) => p.id == id);
      if (personas.isEmpty) personas = <Persona>[Persona.defaultPersona()];
      if (!personas.any((Persona p) => p.id == activePersonaId)) {
        activePersonaId = personas.first.id;
      }
      _syncGlobalsFromActive();
      systemPrompt = composeSystemPrompt();
    });
  }

  /// 记录某条定时任务最近执行日，防止同一天重复触发。
  void setTaskLastRun(String id, String day) {
    if (taskLastRun[id] == day) return;
    _update(() => taskLastRun[id] = day);
  }

  /// 由当前激活人格组装系统提示词；三段全空时返回空串。
  /// 人格相关操作会把它同步到 [systemPrompt]，人格即对话系统提示词的唯一真源。
  String composeSystemPrompt() {
    final Persona p = activePersona;
    final List<String> parts = <String>[];
    if (p.identity.trim().isNotEmpty) {
      parts.add('【身份设置】\n${p.identity.trim()}');
    }
    if (p.personality.trim().isNotEmpty) {
      parts.add('【个性设定】\n${p.personality.trim()}');
    }
    if (p.audience.trim().isNotEmpty) {
      parts.add('【为谁服务】\n${p.audience.trim()}');
    }
    if (parts.isEmpty) return '';
    return '你是${aiName}。\n${parts.join('\n\n')}';
  }

  /// 模型名称仅允许首次设置；训练完成后由 [lockModelName] 锁定。
  void setModelName(String v) {
    if (modelNameLocked) return;
    _update(() => modelName = v);
  }

  void lockModelName() {
    if (modelNameLocked) return;
    _update(() => modelNameLocked = true);
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
}

/// 单个人格设定：名字 + 独立头像 + 身份 / 个性 / 为谁服务 三段文案。
///
/// 三段文案随人格持久化在 [PersonaStore]，并在保存时组装进系统提示词，
/// 真实影响每一次对话推理（agent = model + harness）。
class Persona {
  Persona({
    required this.id,
    required this.name,
    this.identity = '',
    this.personality = '',
    this.audience = '',
    this.avatarPath,
    this.createdAt = 0,
  });

  /// 默认人格的固定 id：旧数据迁移与「切回默认」都指向它。
  static const String defaultId = 'persona-default';

  /// 默认三段文案（内容充实：名字/角色定位/核心信条/能力边界等）。
  static const String defaultIdentity = '名字：TGA\n'
      '角色定位：工作区里的工程师人格（AI）——负责写代码、跑命令、'
      '整理模型与数据。\n'
      '核心信条：agent = model + harness；先做再说，结论先行再给理由；'
      '不确定就直说，绝不编造。\n'
      '能力边界：只在当前工作区与沙箱内操作；动工作区外的文件、'
      '花真钱的 API、不可逆的删除，都会先问再动手。';

  static const String defaultPersonality = '语气风格：冷静、直接，不奉承、不堆废话。\n'
      '表达节奏：短句、分段、列表化；一件事一段，不揉在一起。\n'
      '主动性：中高——发现风险或遗漏会主动指出，但不插嘴无关话题。\n'
      '幽默度：低——允许偶尔一句冷幽默，前提是不影响准确性。';

  static const String defaultAudience = '服务对象：你本人——这个工作区的主人。\n'
      '使用场景：模型训练与管理、代码开发、数据整理、定时简报与夜间归档。\n'
      '偏好：中文、简洁回答、可验证的步骤；重要操作先确认再执行。\n'
      '禁忌：不编造数据、不泄露密钥、不擅自做不可逆的删除。';

  static Persona defaultPersona() => Persona(
        id: defaultId,
        name: '工作区里的工程师人格（AI）',
        identity: defaultIdentity,
        personality: defaultPersonality,
        audience: defaultAudience,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

  final String id;
  String name;
  String identity;
  String personality;
  String audience;
  /// 该人格独立头像的应用文档目录绝对路径；null = 内置默认鹿标。
  String? avatarPath;
  final int createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'identity': identity,
        'personality': personality,
        'audience': audience,
        'avatarPath': avatarPath,
        'createdAt': createdAt,
      };

  /// 向后兼容：缺字段一律用空串 / 0 / null 兜底，不抛错；
  /// 老数据无 avatarPath 时为 null，UI 回退默认鹿标。
  static Persona fromJson(Map<String, dynamic> m) => Persona(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '未命名人格').toString(),
        identity: (m['identity'] ?? '').toString(),
        personality: (m['personality'] ?? '').toString(),
        audience: (m['audience'] ?? '').toString(),
        avatarPath: m['avatarPath']?.toString(),
        createdAt: m['createdAt'] is num
            ? (m['createdAt'] as num).toInt()
            : int.tryParse('${m['createdAt']}') ?? 0,
      );
}
