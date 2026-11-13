/// 统一模型注册表 —— 右下角模型选择器的唯一真实数据源。
///
/// 设计原则（对齐 harness 的「真实来源、无伪造」语义）：
///   * 云端模型 = 用户在「训练设置」里保存的 OpenAI 兼容 API 配置，真实写入
///     [HarnessStore] 的 model_registry.json，重启后可恢复。
///   * 本地模型 = 真实扫描 downloads/ 与 models/ 目录里**已完成**的 .gguf/.bin
///     权重文件（.partN 分片与下载 sidecar 不会被误算），下载完即自动出现。
///   * 内置引擎 = 开箱即用的兜底项，始终本地可用。
///   * 内置免费模型 = Kilo Code 网关的 OpenAI 兼容免费端点（无需 API 密钥），
///     全部经 curl 实测可调（见 [kBuiltinFreeModels]），归入选择器「内置」区。
///
/// 不把「还没下载」的商店 catalog 塞进选择器，也不预置任何编造的模型名或
/// 未实测调通的端点。
/// 选中云端模型后 [chatParams] 会产出真实 api_base / api_key / model，
/// 由 TangramAiProvider 注入聊天请求，让后端真正发起 HTTP 推理。

library;

import 'package:flutter/foundation.dart';

import '../harness/store.dart';

enum ModelKind { local, cloud }

/// 一条真实模型记录。
class ModelEntry {
  const ModelEntry({
    required this.id,
    required this.name,
    required this.kind,
    this.apiBase,
    this.apiKey,
    this.modelId,
    this.path,
    this.size,
    this.builtin = false,
    this.free = false,
  });

  final String id;
  final String name;

  /// 不含括号标记的显示名（用户配置/文件名）。
  final ModelKind kind;

  /// 云端：OpenAI 兼容 Base URL / Key / 实际模型名。
  final String? apiBase;
  final String? apiKey;
  final String? modelId;

  /// 本地：权重文件真实路径与字节数。
  final String? path;
  final int? size;

  /// 是否为内置兜底引擎（不可删除）。
  final bool builtin;

  /// 内置免费云端模型：无需 API 密钥即可真实推理（端点已 curl 实测）。
  final bool free;

  String get tag =>
      free ? '云端·免费' : (kind == ModelKind.cloud ? '云端' : '本地');

  /// 右下角与选择器里展示的名字，带（本地）/（云端）标记。
  String get displayName => '$name（$tag）';

  /// 选择器副标题：如实说明来源，不夸大能力。
  String get subtitle {
    if (free) {
      return '免费·无需密钥 · Kilo 网关 OpenAI 兼容 · ${modelId ?? ''}';
    }
    if (builtin) return '内置 AgentLoop · 表达式 / 工具 / 记忆 / 自检，离线可用';
    if (kind == ModelKind.cloud) {
      return 'OpenAI 兼容 API · ${apiBase ?? ''} · ${modelId ?? ''}';
    }
    final mb = size != null ? '${(size! / 1048576).toStringAsFixed(1)} MB' : '';
    return '本地权重${mb.isEmpty ? '' : ' · $mb'} · 需端侧推理运行时';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.name,
        if (apiBase != null) 'api_base': apiBase,
        if (apiKey != null) 'api_key': apiKey,
        if (modelId != null) 'model_id': modelId,
        if (path != null) 'path': path,
        if (size != null) 'size': size,
      };

  static ModelEntry fromCloudJson(Map<dynamic, dynamic> m) => ModelEntry(
        id: (m['id'] ?? '').toString(),
        name: (m['name'] ?? '云端模型').toString(),
        kind: ModelKind.cloud,
        apiBase: m['api_base']?.toString(),
        apiKey: m['api_key']?.toString(),
        modelId: m['model_id']?.toString(),
      );
}

/// 内置兜底引擎（始终存在，标本地）。
final ModelEntry kBuiltinEngine = const ModelEntry(
  id: 'builtin-agent-loop',
  name: 'TGA 内置引擎',
  kind: ModelKind.local,
  builtin: true,
);

/// 内置免费云端模型（Kilo Code 网关，OpenAI 兼容，无需 API 密钥）。
///
/// 2026-11-14 全部 curl 实测通过（HTTP 200、返回真实 content、usage.cost=0、
/// 请求不带 Authorization 头）：
///   * 模型列表：GET https://api.kilo.ai/api/gateway/models（isFree=true 档）
///   * 推理端点：POST https://api.kilo.ai/api/gateway/chat/completions
/// 下方 6 个 id 均取自该列表接口真实返回，且逐个实测过
/// system+user+temperature+max_tokens+top_p 完整请求体（与后端
/// _remoteChat 发出的请求一致）可正常作答。禁止注册未实测调通的模型。
final List<ModelEntry> kBuiltinFreeModels = <ModelEntry>[
  const ModelEntry(
    id: 'kilo-free:kilo-auto/free',
    name: 'Kilo Auto 免费路由',
    kind: ModelKind.cloud,
    apiBase: 'https://api.kilo.ai/api/gateway',
    modelId: 'kilo-auto/free',
    builtin: true,
    free: true,
  ),
  const ModelEntry(
    id: 'kilo-free:liquid/lfm-3-1.7b:free',
    name: 'Liquid LFM3 1.7B',
    kind: ModelKind.cloud,
    apiBase: 'https://api.kilo.ai/api/gateway',
    modelId: 'liquid/lfm-3-1.7b:free',
    builtin: true,
    free: true,
  ),
  const ModelEntry(
    id: 'kilo-free:baidu/ernie-5.5-flash-preview:free',
    name: '文心 ERNIE 5.5 Flash',
    kind: ModelKind.cloud,
    apiBase: 'https://api.kilo.ai/api/gateway',
    modelId: 'baidu/ernie-5.5-flash-preview:free',
    builtin: true,
    free: true,
  ),
  const ModelEntry(
    id: 'kilo-free:cohere/north-mini-code:free',
    name: 'Cohere North Mini Code',
    kind: ModelKind.cloud,
    apiBase: 'https://api.kilo.ai/api/gateway',
    modelId: 'cohere/north-mini-code:free',
    builtin: true,
    free: true,
  ),
  const ModelEntry(
    id: 'kilo-free:particle-ai/particle-1:free',
    name: 'Particle AI 1',
    kind: ModelKind.cloud,
    apiBase: 'https://api.kilo.ai/api/gateway',
    modelId: 'particle-ai/particle-1:free',
    builtin: true,
    free: true,
  ),
  const ModelEntry(
    id: 'kilo-free:nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
    name: 'NVIDIA Nemotron 3 Nano 30B',
    kind: ModelKind.cloud,
    apiBase: 'https://api.kilo.ai/api/gateway',
    modelId: 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
    builtin: true,
    free: true,
  ),
];

class ModelRegistry extends ChangeNotifier {
  ModelRegistry._(this.store);

  static const String _file = 'model_registry.json';
  final HarnessStore store;

  List<ModelEntry> _cloud = <ModelEntry>[];
  List<ModelEntry> _local = <ModelEntry>[];
  String _selectedId = kBuiltinEngine.id;
  bool _loaded = false;

  static Future<ModelRegistry> load() async {
    final s = await HarnessStore.instance();
    final r = ModelRegistry._(s);
    await r.refresh();
    return r;
  }

  /// 供测试注入自定义存储根目录后构造。
  static Future<ModelRegistry> forTest(HarnessStore s) async {
    final r = ModelRegistry._(s);
    await r.refresh();
    return r;
  }

  bool get loaded => _loaded;

  /// 云端 + 本地 + 内置免费云端（Kilo）+ 内置兜底，用户添加的模型排在前面。
  List<ModelEntry> get entries =>
      List<ModelEntry>.unmodifiable(<ModelEntry>[
        ..._cloud,
        ..._local,
        ...kBuiltinFreeModels,
        kBuiltinEngine,
      ]);

  /// 内置免费模型（选择器「内置」区，无需密钥即可真实推理）。
  List<ModelEntry> get freeEntries =>
      List<ModelEntry>.unmodifiable(kBuiltinFreeModels);

  List<ModelEntry> get cloudEntries => List<ModelEntry>.unmodifiable(_cloud);
  List<ModelEntry> get localEntries => List<ModelEntry>.unmodifiable(_local);

  String get selectedId => _selectedId;

  ModelEntry? byId(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  ModelEntry get selected => byId(_selectedId) ?? kBuiltinEngine;

  /// 重新读取真实来源：云端配置（json）+ 本地权重文件（磁盘扫描）。
  /// 每次打开选择器、添加/删除后都会调用，保证列表永远反映真实状态。
  Future<void> refresh() async {
    final cfg = await store.readJson(_file);
    final rawCloud = cfg['cloud'];
    final cloud = <ModelEntry>[];
    if (rawCloud is List) {
      for (final dynamic m in rawCloud) {
        if (m is Map && (m['id'] ?? '').toString().isNotEmpty) {
          cloud.add(ModelEntry.fromCloudJson(m));
        }
      }
    }
    final sel = (cfg['selected_id'] ?? kBuiltinEngine.id).toString();

    // 真实磁盘扫描：只有合并完成的权重文件才会出现（.partN / sidecar 不匹配）。
    final local = <ModelEntry>[];
    final seenPaths = <String>{};
    for (final dir in <String>['downloads', 'models']) {
      for (final f in store.scanFiles(dir,
          extensions: <String>{'.gguf', '.bin'})) {
        final path = (f['path'] ?? '').toString();
        if (path.isEmpty || seenPaths.contains(path)) continue;
        seenPaths.add(path);
        final fileName = (f['name'] ?? '').toString();
        final friendly = fileName.replaceAll(RegExp(r'\.(gguf|bin)$',
            caseSensitive: false), '');
        local.add(ModelEntry(
          id: 'local:$fileName',
          name: friendly.isEmpty ? fileName : friendly,
          kind: ModelKind.local,
          path: path,
          size: f['size'] is int ? f['size'] as int : null,
        ));
      }
    }
    local.sort((a, b) => a.name.compareTo(b.name));

    _cloud = cloud;
    _local = local;
    // 选中的模型若已被删除/文件消失，诚实回退到内置引擎。
    final candidate = byId(sel);
    // 额外防御：若选中的是用户自配云端模型但 API Key 为空（用户添加后未填/
    // 被清空），直接回退内置引擎，避免开箱首条消息就 401，违背「无需联网」
    // 承诺。内置免费模型（free=true）本就无需密钥，不受该防御影响。
    _selectedId = candidate != null &&
            !(candidate.kind == ModelKind.cloud &&
                !candidate.free &&
                (candidate.apiKey ?? '').trim().isEmpty)
        ? candidate.id
        : kBuiltinEngine.id;
    _loaded = true;
    // refresh 内部不能调用 byId 之前 _cloud/_local 已赋值，上面顺序正确。
    notifyListeners();
  }

  Future<void> _persist() async {
    await store.writeJson(_file, <String, dynamic>{
      'cloud': _cloud.map((ModelEntry e) => e.toJson()).toList(),
      'selected_id': _selectedId,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// 保存一个云端 API 模型。返回空表示成功，否则返回具体原因。
  Future<String?> addCloud({
    required String name,
    required String apiBase,
    required String apiKey,
    required String modelId,
  }) async {
    final n = name.trim();
    final b = apiBase.trim().replaceAll(RegExp(r'/+$'), '');
    final k = apiKey.trim();
    final m = modelId.trim();
    if (b.isEmpty) return '请填写 API Base URL';
    if (k.isEmpty) return '请填写 API Key';
    if (m.isEmpty) return '请填写模型名称（如 deepseek-chat）';
    final display = n.isEmpty ? m : n;
    final id = 'cloud:${Uri.encodeComponent(b)}:${Uri.encodeComponent(m)}';
    final entry = ModelEntry(
      id: id,
      name: display,
      kind: ModelKind.cloud,
      apiBase: b,
      apiKey: k,
      modelId: m,
    );
    // 同一 base+model 只保留一份，重复保存视为更新（改 Key / 名称）。
    _cloud.removeWhere((ModelEntry e) => e.id == id);
    _cloud.insert(0, entry);
    // 首次添加自动选中，让用户立刻能在右下角看到并使用。
    _selectedId = id;
    await _persist();
    await refresh();
    return null;
  }

  Future<void> removeCloud(String id) async {
    _cloud.removeWhere((ModelEntry e) => e.id == id);
    if (_selectedId == id) _selectedId = kBuiltinEngine.id;
    await _persist();
    await refresh();
  }

  Future<void> setSelected(String id) async {
    _selectedId = byId(id) != null ? id : kBuiltinEngine.id;
    await _persist();
    notifyListeners();
  }

  /// 选中模型对应的真实聊天参数。
  ///   * 内置免费模型 → 真实 api_base + model，api_key 为空并带 free=true，
  ///     后端据此省略 Authorization 头直连 Kilo 网关真实推理（已 curl 实测）。
  ///   * 云端 → api_base / api_key / model，后端据此发起真实 HTTP 推理。
  ///   * 本地权重 → 带上真实权重路径与来源标记，后端如实记录，不冒充推理。
  ///   * 内置引擎 → 不带任何外部参数，走内置 AgentLoop。
  Map<String, dynamic> chatParams() {
    final e = selected;
    if (e.free) {
      return <String, dynamic>{
        'api_base': e.apiBase ?? '',
        'api_key': '',
        'model': e.modelId ?? '',
        'model_kind': 'cloud',
        'free': true,
      };
    }
    if (e.kind == ModelKind.cloud) {
      return <String, dynamic>{
        'api_base': e.apiBase ?? '',
        'api_key': e.apiKey ?? '',
        'model': e.modelId ?? '',
        'model_kind': 'cloud',
      };
    }
    if (!e.builtin && e.path != null) {
      return <String, dynamic>{
        'model': e.id,
        'model_kind': 'local',
        'local_model_path': e.path,
      };
    }
    return <String, dynamic>{
      'model': kBuiltinEngine.id,
      'model_kind': 'builtin',
    };
  }
}
