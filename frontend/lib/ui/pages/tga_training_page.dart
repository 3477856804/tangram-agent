import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';
import '../../services/model_registry.dart';
import '../../services/persona_store.dart';
import 'tga_traces_page.dart';

/// 训练设置（真实化改造）：
/// - 环境行：真实下拉（内置沙箱 / 远端沙箱(SSH) / 工作区沙箱），选择后
///   rpc sandbox_policy_set{environment} 落盘 + PersonaStore 同步；
///   显示值来自 rpc sandbox_policy 的 environment。
/// - 隔离策略：进入页面拉真实 quota（CPU/内存/超时/超限动作），可编辑并
///   通过 rpc sandbox_policy_set 真实落盘，成功/失败 toast 如实显示。
/// - 工作轨迹：真实条数（distill traces），点击进入 TgaTracesPage。
/// - 模型厂商：扩充预设列表，选择厂商自动填默认 Base URL 与示例教师模型；
///   「自定义」允许手填。
/// - 测试 API 连通：用当前表单值向 {api_base}/chat/completions 发真实小请求；
///   保存为云端模型：ModelRegistry.addCloud（同名/同模型即更新）。
/// - 我添加的云端模型：registry.cloudEntries 真实列表 + 修改/删除菜单。
/// - 本地基底模型：registry.localEntries 真实 GGUF 列表，可删除权重、
///   选为当前（选中态高亮）；切到本地标签时云端区块整体不渲染。
///
/// API Key 仅本地输入、由注册表落盘，不写进日志。
class TgaTrainingPage extends StatefulWidget {
  const TgaTrainingPage({super.key});

  @override
  State<TgaTrainingPage> createState() => _TgaTrainingPageState();
}

/// 教师厂商预设：名称 / 默认 Base URL / 示例教师模型名。
class _VendorPreset {
  const _VendorPreset({
    required this.name,
    required this.baseUrl,
    required this.model,
  });
  final String name;
  final String baseUrl;
  final String model;
}

const List<_VendorPreset> _kVendors = <_VendorPreset>[
  _VendorPreset(
      name: 'DeepSeek 深度求索',
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat'),
  _VendorPreset(
      name: 'Qwen 通义千问',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      model: 'qwen-plus'),
  _VendorPreset(
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini'),
  _VendorPreset(
      name: 'ZhipuAI 智谱',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4-flash'),
  _VendorPreset(
      name: 'Moonshot Kimi',
      baseUrl: 'https://api.moonshot.cn/v1',
      model: 'moonshot-v1-8k'),
  _VendorPreset(
      name: 'MiniMax',
      baseUrl: 'https://api.minimax.chat/v1',
      model: 'abab6.5s-chat'),
  _VendorPreset(
      name: '豆包（火山方舟）',
      baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
      model: 'doubao-pro-32k'),
  _VendorPreset(
      name: 'SiliconFlow 硅基流动',
      baseUrl: 'https://api.siliconflow.cn/v1',
      model: 'deepseek-ai/DeepSeek-V3'),
  _VendorPreset(
      name: 'Groq',
      baseUrl: 'https://api.groq.com/openai/v1',
      model: 'llama-3.3-70b-versatile'),
  _VendorPreset(
      name: 'Mistral',
      baseUrl: 'https://api.mistral.ai/v1',
      model: 'mistral-large-latest'),
  _VendorPreset(
      name: '自定义（OpenAI 兼容）', baseUrl: '', model: ''),
];

/// 环境下拉的选项（与 harness sandbox_policy.environment 的取值一致，
/// 三个值都会真实落盘；远端/工作区沙箱由后端策略字段承载）。
const List<String> _kEnvironments = <String>[
  '内置沙箱',
  '远端沙箱(SSH)',
  '工作区沙箱',
];

/// 按名称查厂商预设（找不到返回 null，即视为自定义）。
_VendorPreset? _vendorByName(String name) {
  for (final _VendorPreset p in _kVendors) {
    if (p.name == name) return p;
  }
  return null;
}

/// 按 Base URL 反查厂商名（修改云端模型时回填下拉用）。
String? _vendorByBaseUrl(String base) {
  final String norm = base.replaceAll(RegExp(r'/+$'), '');
  for (final _VendorPreset p in _kVendors) {
    if (p.baseUrl.isNotEmpty && p.baseUrl.replaceAll(RegExp(r'/+$'), '') == norm) {
      return p.name;
    }
  }
  return null;
}

class _TgaTrainingPageState extends State<TgaTrainingPage> {
  String _teacherTab = '调用 API';
  String _vendor = _kVendors.first.name;
  bool _apiKeyVisible = false;
  final TextEditingController _baseUrl =
      TextEditingController(text: _kVendors.first.baseUrl);
  final TextEditingController _apiKey = TextEditingController();
  final TextEditingController _teacher =
      TextEditingController(text: _kVendors.first.model);

  // ---- 隔离策略（真实值，进入页面时从 rpc sandbox_policy 拉取）----
  String _environment = '内置沙箱';
  final TextEditingController _cpu = TextEditingController(text: '50');
  final TextEditingController _mem = TextEditingController(text: '128');
  final TextEditingController _timeout = TextEditingController(text: '5');
  String _policy = 'refuse';
  bool _savingPolicy = false;
  String _policySource = '默认值'; // 真实策略加载成功后改为「已加载」

  // ---- 工作轨迹真实条数 ----
  int _traceCount = 0;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPolicy();
      _loadTraces();
    });
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _teacher.dispose();
    _cpu.dispose();
    _mem.dispose();
    _timeout.dispose();
    super.dispose();
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Tga.red : null,
      duration: const Duration(seconds: 2),
    ));
  }

  // ------------------------------------------------------------------
  // 真实数据加载
  // ------------------------------------------------------------------

  /// 拉当前沙箱策略（environment + quota），失败时保留默认值并如实标注。
  Future<void> _loadPolicy() async {
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'rpc',
        <String, dynamic>{'action': 'sandbox_policy'},
      );
      final dynamic payload = env.payload;
      if (payload is Map && payload['ok'] == true) {
        final String environment =
            (payload['environment'] ?? '内置沙箱').toString();
        final dynamic gates = payload['gates'];
        final dynamic quota = gates is Map ? gates['quota'] : null;
        setState(() {
          _environment = environment;
          if (quota is Map) {
            _cpu.text = '${quota['cpu_percent'] ?? 50}';
            _mem.text = '${quota['memory_mb'] ?? 128}';
            _timeout.text = '${quota['timeout_seconds'] ?? 5}';
            // 下拉只有 refuse/kill 两项，异常值一律回退 refuse，避免崩溃。
            final String exceed =
                (quota['action_on_exceed'] ?? 'refuse').toString();
            _policy = exceed == 'kill' ? 'kill' : 'refuse';
          }
          _policySource = '真实策略';
        });
      } else {
        setState(() => _policySource = '默认值（后端未就绪）');
      }
    } on Object {
      if (mounted) setState(() => _policySource = '默认值（后端未就绪）');
    }
  }

  /// 拉真实工作轨迹条数（distill traces）。
  Future<void> _loadTraces() async {
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'distill',
        <String, dynamic>{'action': 'traces'},
      );
      final dynamic payload = env.payload;
      final dynamic data = payload is Map ? payload['data'] : null;
      if (mounted) {
        setState(() => _traceCount = data is List ? data.length : 0);
      }
    } on Object {
      if (mounted) setState(() => _traceCount = 0);
    }
  }

  // ------------------------------------------------------------------
  // 环境切换：rpc sandbox_policy_set{environment} + PersonaStore 同步
  // ------------------------------------------------------------------

  Future<void> _applyEnvironment(String picked) async {
    if (picked == _environment) return;
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'rpc',
        <String, dynamic>{'action': 'sandbox_policy_set', 'environment': picked},
      );
      final dynamic payload = env.payload;
      if (!mounted) return;
      if (payload is Map && payload['ok'] == true) {
        // 后端如实回显落盘后的 environment，以其为准。
        final String saved = (payload['environment'] ?? picked).toString();
        setState(() => _environment = saved);
        context.read<PersonaStore>().setSandboxEnvironment(saved);
        _toast('环境已切换为「$saved」');
      } else {
        _toast('切换环境失败：${payload is Map ? payload['error'] : '后端返回异常'}',
            error: true);
      }
    } on Object catch (e) {
      _toast('切换环境失败：$e', error: true);
    }
  }

  // ------------------------------------------------------------------
  // 保存隔离策略：rpc sandbox_policy_set 真实落盘 + 范围校验
  // ------------------------------------------------------------------

  Future<void> _savePolicy() async {
    final int cpu = int.tryParse(_cpu.text.trim()) ?? -1;
    final int mem = int.tryParse(_mem.text.trim()) ?? -1;
    final int timeout = int.tryParse(_timeout.text.trim()) ?? -1;
    if (cpu < 0 || mem < 0 || timeout < 0) {
      _toast('CPU / 内存 / 超时必须是整数', error: true);
      return;
    }
    setState(() => _savingPolicy = true);
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'rpc',
        <String, dynamic>{
          'action': 'sandbox_policy_set',
          'cpu_percent': cpu,
          'memory_mb': mem,
          'timeout_seconds': timeout,
          'action_on_exceed': _policy,
          'environment': _environment,
        },
      );
      final dynamic payload = env.payload;
      if (!mounted) return;
      if (payload is Map && payload['ok'] == true) {
        final dynamic q = payload['quota'];
        final String summary = q is Map
            ? 'CPU ≤${q['cpu_percent']}% · 内存 ≤${q['memory_mb']}MB · '
                '超时 ${q['timeout_seconds']}s · 超限 ${q['action_on_exceed']}'
            : '';
        _toast(summary.isEmpty ? '策略已保存' : '策略已保存：$summary');
        setState(() => _policySource = '真实策略');
      } else {
        _toast('保存失败：${payload is Map ? payload['error'] : '后端返回异常'}',
            error: true);
      }
    } on Object catch (e) {
      if (mounted) _toast('保存失败：$e', error: true);
    }
    if (mounted) setState(() => _savingPolicy = false);
  }

  // ------------------------------------------------------------------
  // 测试 API 连通：真实 HTTP 小请求，显示耗时/成功/失败原因
  // ------------------------------------------------------------------

  Future<void> _testApi() async {
    final String base = _baseUrl.text.trim().replaceAll(RegExp(r'/+$'), '');
    final String key = _apiKey.text.trim();
    final String model = _teacher.text.trim();
    if (base.isEmpty) {
      _toast('请先填写 API Base URL', error: true);
      return;
    }
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      _toast('Base URL 需以 http(s):// 开头', error: true);
      return;
    }
    setState(() => _testing = true);
    final Stopwatch watch = Stopwatch()..start();
    try {
      final http.Response resp = await http
          .post(
            Uri.parse('$base/chat/completions'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              if (key.isNotEmpty) 'Authorization': 'Bearer $key',
            },
            body: jsonEncode(<String, dynamic>{
              'model': model.isEmpty ? 'gpt-3.5-turbo' : model,
              'messages': <Map<String, String>>[
                <String, String>{'role': 'user', 'content': 'ping'},
              ],
              'max_tokens': 1,
            }),
          )
          .timeout(const Duration(seconds: 15));
      watch.stop();
      if (!mounted) return;
      if (resp.statusCode == 200) {
        _toast('连通成功 · ${watch.elapsedMilliseconds} ms');
      } else {
        _toast(
          '连通失败：HTTP ${resp.statusCode} · ${_brief(resp.body)}'
          ' · ${watch.elapsedMilliseconds} ms',
          error: true,
        );
      }
    } on TimeoutException {
      watch.stop();
      if (mounted) _toast('连通失败：请求超时（15s）', error: true);
    } on Object catch (e) {
      watch.stop();
      if (mounted) _toast('连通失败：$e', error: true);
    }
    if (mounted) setState(() => _testing = false);
  }

  /// 失败响应体只截前 120 个字符，避免 toast 过长。
  static String _brief(String body) {
    final String one = body.replaceAll('\n', ' ').trim();
    return one.length <= 120 ? one : '${one.substring(0, 120)}…';
  }

  // ------------------------------------------------------------------
  // 保存为云端模型：ModelRegistry.addCloud（name=教师模型名）
  // ------------------------------------------------------------------

  Future<void> _saveCloud() async {
    final ModelRegistry registry = context.read<ModelRegistry>();
    final String? err = await registry.addCloud(
      name: _teacher.text.trim(),
      apiBase: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      modelId: _teacher.text.trim(),
    );
    if (!mounted) return;
    if (err != null) {
      _toast(err, error: true);
      return;
    }
    // addCloud 成功后 registry 已 notifyListeners，列表即时刷新。
    _toast('已保存为云端模型（同 base+模型 重复保存即更新）');
  }

  // ------------------------------------------------------------------
  // 云端模型条目操作
  // ------------------------------------------------------------------

  /// 修改：把已保存配置回填表单；保存即更新（addCloud 同 id 覆盖）。
  void _editCloud(ModelEntry e) {
    setState(() {
      _teacherTab = '调用 API';
      _baseUrl.text = e.apiBase ?? '';
      _apiKey.text = e.apiKey ?? '';
      _teacher.text = e.modelId ?? '';
      _vendor = _vendorByBaseUrl(e.apiBase ?? '') ?? _kVendors.last.name;
    });
  }

  Future<void> _deleteCloud(ModelEntry e) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除云端模型'),
        content: Text('确认删除「${e.name}」？删除后右下角选择器不再出现。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('删除', style: TextStyle(color: Tga.red))),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await context.read<ModelRegistry>().removeCloud(e.id);
    if (mounted) _toast('已删除云端模型「${e.name}」');
  }

  // ------------------------------------------------------------------
  // 本地基底模型操作
  // ------------------------------------------------------------------

  /// 删除真实权重文件后 registry.refresh()。
  ///
  /// 说明：device_file 控制域只覆盖 sandbox/ 目录，权重位于 models/ 或
  /// downloads/，因此 models/ 下走 distill delete_model（后端真实删除），
  /// 其余路径用 dart:io 直删——两者都是真实磁盘操作，不伪造状态。
  Future<void> _deleteLocalWeight(ModelEntry e) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除本地权重'),
        content: Text('确认删除「${e.name}」的权重文件？'
            '文件将从磁盘真实移除，需重新下载才能恢复。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('删除', style: TextStyle(color: Tga.red))),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final String path = e.path ?? '';
    final String fileName = path.split('/').last;
    bool deleted = false;
    String? failReason;
    try {
      if (fileName.isNotEmpty && path.contains('/models/')) {
        final BridgeEnvelope env = await context.read<BackendClient>()
            .sendControl('distill', <String, dynamic>{
          'action': 'delete_model',
          'name': fileName,
        });
        final dynamic payload = env.payload;
        deleted = payload is Map && payload['ok'] == true;
        if (!deleted) {
          failReason =
              payload is Map ? (payload['error'] ?? '').toString() : null;
        }
      } else if (path.isNotEmpty) {
        final File f = File(path);
        if (await f.exists()) {
          await f.delete();
          deleted = true;
        }
      }
    } on Object catch (e) {
      failReason = '$e';
    }
    if (!mounted) return;
    final ModelRegistry registry = context.read<ModelRegistry>();
    await registry.refresh();
    if (!mounted) return;
    if (deleted) {
      _toast('已删除权重「${e.name}」');
    } else {
      _toast('删除失败：${(failReason?.isNotEmpty ?? false) ? failReason : '权重文件不存在'}',
          error: true);
    }
  }

  Future<void> _selectLocal(ModelEntry e) async {
    await context.read<ModelRegistry>().setSelected(e.id);
    if (mounted) _toast('已选为当前模型：${e.name}');
  }

  // ------------------------------------------------------------------
  // 工作轨迹入口
  // ------------------------------------------------------------------

  Future<void> _openTraces() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext _) => const TgaTracesPage(),
    ));
    // 返回后刷新条数（期间可能聊了新消息产生新轨迹）。
    _loadTraces();
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ModelRegistry registry = context.watch<ModelRegistry>();
    final bool backendReady = context.read<BackendClient>().ready;
    final List<ModelEntry> cloud = registry.cloudEntries;
    final List<ModelEntry> local = registry.localEntries;
    final bool apiTab = _teacherTab == '调用 API';

    return TgaPage(
      title: '训练设置',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
        children: <Widget>[
          // ---------- 沙箱状态 + 沙箱环境（合并一行卡：左状态右环境胶囊）----------
          TgaCard(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                TgaTag(backendReady ? '沙箱已连接' : '后端未就绪',
                    color: backendReady ? Tga.green : Tga.orange),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: '切换沙箱环境',
                  initialValue: _environment,
                  position: PopupMenuPosition.under,
                  itemBuilder: (BuildContext ctx) => _kEnvironments
                      .map((String e) => PopupMenuItem<String>(
                            value: e,
                            child: Text(e,
                                style: TextStyle(
                                    fontWeight: e == _environment
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: e == _environment
                                        ? Tga.primary
                                        : Tga.text)),
                          ))
                      .toList(),
                  onSelected: _applyEnvironment,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: Tga.cardAlt,
                      borderRadius: BorderRadius.circular(Tga.rChip),
                      border: Border.all(color: Tga.border),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(_environment,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Tga.text)),
                        const SizedBox(width: 2),
                        Icon(Icons.keyboard_arrow_down_rounded,
                            size: 18, color: Tga.textDim),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // ---------- 隔离策略（真实 quota，紧凑行式选项）----------
          TgaCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text('隔离策略', style: Tga.h2),
                    const Spacer(),
                    Text(_policySource, style: Tga.caption),
                  ],
                ),
                const SizedBox(height: 10),
                _NumRow(label: 'CPU %', controller: _cpu, hint: '1~100'),
                const SizedBox(height: 8),
                _NumRow(label: '内存 MB', controller: _mem, hint: '16~4096'),
                const SizedBox(height: 8),
                _NumRow(label: '超时 s', controller: _timeout, hint: '1~300'),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Text('超限动作', style: Tga.sub),
                    const SizedBox(width: 10),
                    DropdownButton<String>(
                      value: _policy,
                      underline: const SizedBox.shrink(),
                      isDense: true,
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                            value: 'refuse', child: Text('refuse')),
                        DropdownMenuItem<String>(
                            value: 'kill', child: Text('kill')),
                      ],
                      onChanged: (String? v) =>
                          setState(() => _policy = v ?? 'refuse'),
                    ),
                    const Spacer(),
                    TgaButton(
                      label: _savingPolicy ? '保存中…' : '保存策略',
                      onTap: _savingPolicy ? () {} : _savePolicy,
                      icon: Icons.save_outlined,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // ---------- 工作轨迹（独立入口行）----------
          TgaCard(
            padding: EdgeInsets.zero,
            child: InkWell(
              borderRadius: BorderRadius.circular(Tga.rCard),
              onTap: _openTraces,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                          color: Tga.iconCyanBg,
                          borderRadius: BorderRadius.circular(11)),
                      child: Icon(Icons.receipt_long_outlined,
                          size: 20, color: Tga.iconCyan),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Text('工作轨迹', style: Tga.h2)),
                    TgaTag('$_traceCount 条', color: Tga.cyan),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_right_rounded,
                        size: 19, color: Tga.textDim),
                  ],
                ),
              ),
            ),
          ),

          // ---------- 模型配置 ----------
          const _GroupTitle('模型配置'),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text('选一个教师来源', style: Tga.sub),
          ),
          _SegTab(
            items: const <String>['调用 API', '本地基底模型'],
            value: _teacherTab,
            onChanged: (String v) => setState(() => _teacherTab = v),
          ),
          const SizedBox(height: 10),
          if (apiTab) _apiCard() else ..._localForm(local, registry),

          // ---------- 我添加的云端模型（仅 API 标签渲染）----------
          if (apiTab) ...<Widget>[
            _GroupTitle(
              '我添加的云端模型',
              trailing: TgaTag('${cloud.length} 个', color: Tga.textSub),
            ),
            if (cloud.isEmpty)
              const TgaCard(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: TgaEmpty('还没有云端模型', icon: Icons.cloud_off_outlined),
              )
            else
              ...cloud.map((ModelEntry e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _CloudRow(
                      entry: e,
                      selected: registry.selectedId == e.id,
                      onEdit: () => _editCloud(e),
                      onDelete: () => _deleteCloud(e),
                    ),
                  )),
          ],
        ],
      ),
    );
  }

  /// 模型配置合并卡：厂商下拉 / Base URL / API Key / 教师模型
  /// 同卡内「小标签 + 输入框」分行（行距 10），测速 + 保存按钮同行各占一半。
  Widget _apiCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TgaCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _LabeledRow(
                label: '模型厂商',
                child: DropdownButton<String>(
                  value: _vendor,
                  isExpanded: true,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Tga.text),
                  items: _kVendors
                      .map((_VendorPreset v) => DropdownMenuItem<String>(
                            value: v.name,
                            child:
                                Text(v.name, overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (String? v) {
                    if (v == null) return;
                    final _VendorPreset? preset = _vendorByName(v);
                    setState(() {
                      _vendor = v;
                      // 非自定义：自动填默认 Base URL 与示例教师模型名；
                      // 自定义：保留当前输入允许手填。
                      if (preset != null && preset.baseUrl.isNotEmpty) {
                        _baseUrl.text = preset.baseUrl;
                        _teacher.text = preset.model;
                      }
                    });
                  },
                ),
              ),
              const SizedBox(height: 10),
              _LabeledRow(
                label: 'API Base URL',
                child: _InputBox(
                  child: TextField(
                    controller: _baseUrl,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Tga.text),
                    decoration: const InputDecoration(
                        isCollapsed: true, border: InputBorder.none),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _LabeledRow(
                label: 'API Key',
                child: _InputBox(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _apiKey,
                          obscureText: !_apiKeyVisible,
                          style: TextStyle(fontSize: 14, color: Tga.text),
                          decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: '请输入 API Key',
                              hintStyle:
                                  TextStyle(fontSize: 13, color: Tga.textDim)),
                        ),
                      ),
                      GestureDetector(
                        onTap: () =>
                            setState(() => _apiKeyVisible = !_apiKeyVisible),
                        child: Icon(
                            _apiKeyVisible
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 17,
                            color: Tga.textDim),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _LabeledRow(
                label: '教师模型',
                child: _InputBox(
                  child: TextField(
                    controller: _teacher,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Tga.text),
                    decoration: const InputDecoration(
                        isCollapsed: true, border: InputBorder.none),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // 同一 Row：左「测试 API 连通」右「保存为云端模型」各占一半
              Row(
                children: <Widget>[
                  Expanded(
                    child: _FormButton(
                      label: _testing ? '测试中…' : '测试 API 连通',
                      icon: Icons.wifi_rounded,
                      filled: false,
                      busy: _testing,
                      onTap: _testing ? null : _testApi,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _FormButton(
                      label: '保存为云端模型',
                      icon: Icons.link_rounded,
                      filled: true,
                      onTap: _testing ? null : _saveCloud,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
          child: Text(
            '保存后出现在右下角选择器里（带「云端」标记），选中即可用。可添加多个。'
            'API Key 仅本机存储，不写进日志。',
            style: Tga.sub,
          ),
        ),
      ],
    );
  }

  List<Widget> _localForm(List<ModelEntry> local, ModelRegistry registry) =>
      <Widget>[
        TgaCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('本地基底模型', style: Tga.h2),
              const SizedBox(height: 8),
              Text(
                '选择一个已下载的本地 GGUF 权重作为基底，'
                '通过 harness 跑「模型 → 工具 → 沙箱 → 回写」循环蒸馏。',
                style: Tga.sub,
              ),
              const SizedBox(height: 12),
              if (local.isEmpty)
                TgaTag('暂无本地权重', color: Tga.textSub)
              else
                ...local.map((ModelEntry e) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _LocalRow(
                        entry: e,
                        selected: registry.selectedId == e.id,
                        onSelect: () => _selectLocal(e),
                        onDelete: () => _deleteLocalWeight(e),
                      ),
                    )),
            ],
          ),
        ),
      ];
}

/// 数字输入紧凑行（隔离策略用）：左小标签右输入框。
class _NumRow extends StatelessWidget {
  const _NumRow(
      {required this.label, required this.controller, required this.hint});
  final String label;
  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(width: 64, child: Text(label, style: Tga.sub)),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Tga.cardAlt,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: Tga.border),
            ),
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: Tga.text),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(fontSize: 11, color: Tga.textDim),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 表单底部大按钮（测试 / 保存）。
class _FormButton extends StatelessWidget {
  const _FormButton({
    required this.label,
    required this.icon,
    required this.filled,
    this.busy = false,
    this.onTap,
  });
  final String label;
  final IconData icon;
  final bool filled;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: filled ? Tga.primary : Tga.card,
          borderRadius: BorderRadius.circular(12),
          border: filled
              ? null
              : Border.all(color: Tga.border),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (busy)
              SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Tga.textSub))
            else
              Icon(icon, size: 18, color: filled ? Tga.onPrimary : Tga.text),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: filled ? Tga.onPrimary : Tga.text),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

/// 云端模型条目：名称 + base + model + ⋮ 菜单（修改/删除）。
class _CloudRow extends StatelessWidget {
  const _CloudRow({
    required this.entry,
    required this.selected,
    required this.onEdit,
    required this.onDelete,
  });
  final ModelEntry entry;
  final bool selected;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return TgaCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
                color: Tga.iconBlueBg, borderRadius: BorderRadius.circular(10)),
            child: Icon(Icons.cloud_outlined,
                size: 19, color: Tga.iconBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(entry.name,
                          style: Tga.body,
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (selected) ...<Widget>[
                      const SizedBox(width: 8),
                      TgaTag('当前', color: Tga.green),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text('${entry.apiBase ?? ''} · ${entry.modelId ?? ''}',
                    style: Tga.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: Icon(Icons.more_vert_rounded,
                size: 18, color: Tga.textDim),
            itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
              const PopupMenuItem<String>(value: 'edit', child: Text('修改')),
              PopupMenuItem<String>(
                  value: 'delete', child: Text('删除',
                      style: TextStyle(color: Tga.red))),
            ],
            onSelected: (String v) => v == 'edit' ? onEdit() : onDelete(),
          ),
        ],
      ),
    );
  }
}

/// 本地基底模型条目：名称 + 大小 + ⋮ 菜单（选为当前/删除），选中态高亮。
class _LocalRow extends StatelessWidget {
  const _LocalRow({
    required this.entry,
    required this.selected,
    required this.onSelect,
    required this.onDelete,
  });
  final ModelEntry entry;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final String size = entry.size != null
        ? '${(entry.size! / 1048576).toStringAsFixed(1)} MB'
        : '大小未知';
    return Container(
      decoration: BoxDecoration(
        color: selected ? Tga.iconBlueBg : Tga.cardAlt,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
            color: selected ? Tga.primary : Tga.border,
            width: selected ? 1.4 : 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.memory_rounded,
              size: 18, color: selected ? Tga.primary : Tga.textSub),
          const SizedBox(width: 10),
          Expanded(
            child: Text(entry.name,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: selected ? Tga.primaryDeep : Tga.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Text(size, style: Tga.caption),
          if (selected) ...<Widget>[
            const SizedBox(width: 8),
            Icon(Icons.check_circle_rounded,
                size: 16, color: Tga.primary),
          ],
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: Icon(Icons.more_vert_rounded,
                size: 18, color: Tga.textDim),
            itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
              if (!selected)
                const PopupMenuItem<String>(
                    value: 'select', child: Text('选为当前')),
              PopupMenuItem<String>(
                  value: 'delete',
                  child: Text('删除', style: TextStyle(color: Tga.red))),
            ],
            onSelected: (String v) => v == 'select' ? onSelect() : onDelete(),
          ),
        ],
      ),
    );
  }
}

/// 分组标题（同 TgaGroupTitle 视觉，纵向留白收紧为上 12 / 下 8）。
class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text, {this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Row(
        children: <Widget>[
          Text(text,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: Tga.groupTitle)),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 合并卡内的「小标签 + 输入框」行。
class _LabeledRow extends StatelessWidget {
  const _LabeledRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(width: 84, child: Text(label, style: Tga.sub)),
        Expanded(child: child),
      ],
    );
  }
}

/// 行内输入框外观（浅底 + 描边圆角）。
class _InputBox extends StatelessWidget {
  const _InputBox({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: Tga.cardAlt,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Tga.border),
        ),
        child: child,
      );
}

class _SegTab extends StatelessWidget {
  const _SegTab(
      {required this.items, required this.value, required this.onChanged});
  final List<String> items;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Tga.card,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: <Widget>[
          for (final String it in items) ...<Widget>[
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(it),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: it == value ? Tga.card : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: it == value
                        ? <BoxShadow>[Tga.softShadow]
                        : <BoxShadow>[],
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    it,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: it == value ? Tga.primary : Tga.textSub,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
