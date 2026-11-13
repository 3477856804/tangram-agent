import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 一个自定义智能体：人格化 system prompt + 启用开关。
class TgaAgent {
  TgaAgent({
    required this.id,
    required this.name,
    this.description = '',
    this.systemPrompt = '',
    this.enabled = true,
  });

  final String id;
  String name;
  String description;
  String systemPrompt;
  bool enabled;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'description': description,
        'systemPrompt': systemPrompt,
        'enabled': enabled,
      };

  factory TgaAgent.fromJson(Map<String, dynamic> m) => TgaAgent(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        description: (m['description'] ?? '').toString(),
        systemPrompt: (m['systemPrompt'] ?? '').toString(),
        enabled: m['enabled'] != false,
      );
}

/// 智能体中心持久化：App 文档目录 agents.json，真实落盘、重启可恢复。
///
/// 「启用」的智能体经 [enabledSystemPromptBlock] 注入对话 system prompt
/// （见 flai/providers/tangram_ai_provider.dart 的 persona 注入点）。
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

  /// 新建智能体（名称必填由 UI 校验），默认启用。
  Future<TgaAgent> create({
    required String name,
    String description = '',
    String systemPrompt = '',
  }) async {
    final TgaAgent agent = TgaAgent(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name.trim(),
      description: description.trim(),
      systemPrompt: systemPrompt.trim(),
    );
    _agents.add(agent);
    await _save();
    return agent;
  }

  /// 更新既有智能体的三个文本字段。
  Future<void> update(TgaAgent agent) async {
    final int idx = _agents.indexWhere((TgaAgent a) => a.id == agent.id);
    if (idx < 0) return;
    _agents[idx]
      ..name = agent.name.trim()
      ..description = agent.description.trim()
      ..systemPrompt = agent.systemPrompt.trim();
    await _save();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final TgaAgent? agent = _find(id);
    if (agent == null || agent.enabled == enabled) return;
    agent.enabled = enabled;
    await _save();
  }

  Future<void> remove(String id) async {
    _agents.removeWhere((TgaAgent a) => a.id == id);
    await _save();
  }

  TgaAgent? _find(String id) {
    for (final TgaAgent a in _agents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// 对话注入块：所有「启用且写了人设」的智能体 systemPrompt 拼成一段文本；
  /// 无启用项或读取失败返回空串（system prompt 保持原样，绝不影响对话）。
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
      }
      return sb.toString();
    } on Object {
      return '';
    }
  }
}
