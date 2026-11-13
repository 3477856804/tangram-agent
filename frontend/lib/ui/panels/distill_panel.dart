/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/services/model_registry.dart';
import 'package:tangram/services/persona_store.dart';
import 'package:tangram/services/sandbox_runtime.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';
import 'package:tangram/ui/panels/code_workspace.dart';
import 'package:tangram/ui/panels/model_manager_panel.dart';
import 'package:tangram/ui/panels/teacher_vendors.dart';
import 'package:tangram/ui/widgets/backend_status_banner.dart';

class DistillPanel extends StatefulWidget {
  const DistillPanel({super.key});

  @override
  State<DistillPanel> createState() => _DistillPanelState();
}

class _DistillPanelState extends State<DistillPanel> with AsyncPanelMixin {
  String _source = 'api';
  String _vendorId = kTeacherVendors.first.id;
  final TextEditingController _baseCtrl = TextEditingController();
  final TextEditingController _apiBaseCtrl = TextEditingController(
    text: kTeacherVendors.first.baseUrl,
  );
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _apiModelCtrl = TextEditingController(
    text: kTeacherVendors.first.defaultModel,
  );
  final TextEditingController _taskCtrl = TextEditingController();
  late final TextEditingController _nameCtrl;

  List<Map<String, dynamic>> _baseModels = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _ownModels = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _traceRows = <Map<String, dynamic>>[];
  int _traces = 0;
  String _equation = 'agent = model + harness';
  String _version = '0.0.1';
  String _lastResult = '';

  @override
  void initState() {
    super.initState();
    final persona = context.read<PersonaStore>();
    _nameCtrl = TextEditingController(text: persona.modelName ?? 'my-agent');
    _refresh();
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _apiBaseCtrl.dispose();
    _apiKeyCtrl.dispose();
    _apiModelCtrl.dispose();
    _taskCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _commonArgs => <String, dynamic>{
        'source': _source,
        'base': _baseCtrl.text.trim(),
        'api_base': _apiBaseCtrl.text.trim(),
        'api_key': _apiKeyCtrl.text.trim(),
        'api_model': _apiModelCtrl.text.trim(),
        'vendor': _vendorId,
        'name': _nameCtrl.text.trim().isEmpty ? 'my-agent' : _nameCtrl.text.trim(),
        'epochs': 8,
      };

  Future<Map<String, dynamic>> _call(
    BackendClient backend,
    String action, [
    Map<String, dynamic> extra = const <String, dynamic>{},
  ]) {
    return backend.distill(action, args: <String, dynamic>{
      ..._commonArgs,
      ...extra,
    });
  }

  static List<Map<String, dynamic>> _listOfMaps(dynamic v) {
    if (v is! List) return <Map<String, dynamic>>[];
    return v
        .whereType<Map>()
        .map((Map<dynamic, dynamic> m) =>
            m.map((dynamic k, dynamic val) => MapEntry(k.toString(), val)))
        .toList(growable: false);
  }

  Future<void> _refresh() => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final modelsRes = await _call(backend, 'models');
        final descRes = await _call(backend, 'describe');
        final modelsData = modelsRes['data'];
        if (modelsData is Map) {
          _baseModels = _listOfMaps(modelsData['base_models']);
          _ownModels = _listOfMaps(modelsData['own_models']);
        }
        final desc = descRes['data'];
        if (desc is Map) {
          _equation = (desc['equation'] ?? _equation).toString();
          _version = (desc['version'] ?? _version).toString();
          final harness = desc['harness'];
          if (harness is Map) {
            _traces = int.tryParse('${harness['work_traces'] ?? 0}') ?? 0;
          }
        }
      });

  Future<void> _refreshModels(BackendClient backend) async {
    try {
      final res = await _call(backend, 'models');
      final d = res['data'];
      if (d is Map) {
        _baseModels = _listOfMaps(d['base_models']);
        _ownModels = _listOfMaps(d['own_models']);
      }
    } on Object {
      // 离线时保持当前列表，不编造数据。
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadTraces() async {
    try {
      final backend = context.read<BackendClient>();
      final res = await _call(backend, 'traces');
      final data = res['data'];
      _traceRows = data is List
          ? data
              .whereType<Map>()
              .map((Map<dynamic, dynamic> m) => m.map(
                    (dynamic k, dynamic v) => MapEntry(k.toString(), v),
                  ))
              .toList()
          : <Map<String, dynamic>>[];
    } on Object {
      _traceRows = <Map<String, dynamic>>[];
    }
    if (mounted) setState(() {});
  }

  Future<void> _work() => runGuarded(() async {
        final task = _taskCtrl.text.trim();
        if (task.isEmpty) {
          setError('请先填写工作任务');
          return;
        }
        final backend = context.read<BackendClient>();
        final res = await _call(backend, 'work', <String, dynamic>{'task': task});
        _lastResult = res['ok'] == true
            ? '工作已采集：${(res['data'] is Map) ? res['data']['completion'] : ''}'
            : '工作失败：${res['error']}';
        if (res['ok'] == true && res['data'] is Map) {
          _traces = int.tryParse('${res['data']['traces'] ?? _traces}') ?? _traces;
        }
        _taskCtrl.clear();
        await _loadTraces();
      });

  Future<void> _distill() => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final persona = context.read<PersonaStore>();
        final res = await _call(backend, 'distill');
        _lastResult = res['ok'] == true
            ? '蒸馏完成，模型文件在下方'
            : '蒸馏失败：${res['error']}';
        if (res['ok'] == true) {
          persona.lockModelName();
        }
        await _refreshModels(backend);
      });

  void _applyVendor(String id) {
    final TeacherVendor v = vendorById(id);
    _vendorId = id;
    if (v.id != 'custom') {
      _apiBaseCtrl.text = v.baseUrl;
      _apiModelCtrl.text = v.defaultModel;
    }
    setState(() {});
  }

  /// 把当前填好的 API 配置真实保存为可选云端模型。
  /// 保存后立刻出现在右下角模型选择器里，并带「（云端）」标记。
  Future<void> _saveCloudModel() async {
    final ModelRegistry registry = context.read<ModelRegistry>();
    final String? err = await registry.addCloud(
      name: _apiModelCtrl.text.trim(),
      apiBase: _apiBaseCtrl.text.trim(),
      apiKey: _apiKeyCtrl.text.trim(),
      modelId: _apiModelCtrl.text.trim(),
    );
    if (!mounted) return;
    if (err != null) {
      setError(err);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已添加云端模型，在右下角选择器里选'),
        duration: Duration(seconds: 2),
      ),
    );
    setState(() {});
  }

  /// 真实发起一次 OpenAI 兼容 API 调用，验证凭据/地址/模型是否可用。
  /// 不编造结果：成功展示真实回复，失败如实展示错误。
  Future<void> _testApi() => runGuarded(() async {
        final BackendClient backend = context.read<BackendClient>();
        final env = await backend.sendControl(
          'chat',
          <String, dynamic>{
            'text': '请只回复两个字：正常',
            'api_base': _apiBaseCtrl.text.trim(),
            'api_key': _apiKeyCtrl.text.trim(),
            'model': _apiModelCtrl.text.trim(),
          },
        );
        final dynamic p = env.payload;
        final bool ok = p is Map &&
            (p['engine'] ?? '').toString().startsWith('openai-compatible');
        _lastResult = ok
            ? 'API 连通成功：${(p['reply'] ?? '').toString()}'
            : 'API 调用失败：${p is Map ? (p['reply'] ?? p['error'] ?? '未知错误') : p}';
      });

  Future<void> _showWorkTraces() async {
    await _loadTraces();
    if (!mounted) return;
    final SandboxRuntime runtime = context.read<SandboxRuntime>();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: SizedBox(
          height: 420,
          child: Padding(
            padding: const EdgeInsets.all(TangramSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  '工作轨迹 · 任务历史',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: TangramSpacing.md),
                BackendStatusBanner(offline: !runtime.online),
                Expanded(
                  child: _traceRows.isEmpty
                      ? EmptyState(
                          icon: Icons.work_history_outlined,
                          title: '暂无工作轨迹',
                          message: runtime.online
                              ? '执行任务后，记录会显示在这里'
                              : '沙箱未启动，暂无记录',
                          compact: true,
                        )
                      : ListView.builder(
                          itemCount: _traceRows.length,
                          itemBuilder: (BuildContext c, int i) {
                            final Map<String, dynamic> t = _traceRows[i];
                            return Padding(
                              padding: const EdgeInsets.only(
                                bottom: TangramSpacing.sm,
                              ),
                              child: InfoTile(
                                icon: Icons.work_history,
                                title: (t['task'] ?? '未命名任务').toString(),
                                subtitle:
                                    '${t['ts'] ?? ''}  ·  ${t['source'] ?? 'harness'}  ·  '
                                    '${t['accepted'] == true ? '已采纳' : '未采纳'}',
                                color: t['accepted'] == true
                                    ? TangramColors.success
                                    : TangramColors.textMuted,
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _shareModel(Map<String, dynamic> m) async {
    try {
      await Share.share(
        '我的模型：${m['name'] ?? 'my-agent'}\n'
        '版本：${m['version'] ?? '0.0.1'}\n'
        '路径：${m['path'] ?? ''}',
      );
    } on Object catch (e) {
      setError('分享失败：$e');
    }
  }

  Future<void> _deleteModel(Map<String, dynamic> m) async {
    final String name = (m['name'] ?? '').toString();
    if (name.isEmpty) return;
    await runGuarded(() async {
      final backend = context.read<BackendClient>();
      await _call(backend, 'delete_model', <String, dynamic>{'name': name});
      await _refreshModels(backend);
    });
  }

  Future<void> _renameModel(Map<String, dynamic> m) async {
    final String oldName = (m['name'] ?? '').toString();
    if (oldName.isEmpty) return;
    final TextEditingController ctrl = TextEditingController(text: oldName);
    final String? newName = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('编辑模型名称'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (newName == null || newName.isEmpty || newName == oldName) return;
    await runGuarded(() async {
      final backend = context.read<BackendClient>();
      await _call(backend, 'rename_model', <String, dynamic>{
        'name': oldName,
        'new_name': newName,
      });
      await _refreshModels(backend);
    });
  }

  @override
  Widget build(BuildContext context) {
    final PersonaStore persona = context.watch<PersonaStore>();
    final bool nameLocked = persona.modelNameLocked;

    return PanelPage(
      children: <Widget>[
        SectionTitle(
          title: '训练我的模型',
          subtitle: '$_equation  ·  tangram-agent v$_version',
          icon: Icons.auto_awesome,
          accent: TangramColors.jade,
          trailing: InkWell(
            onTap: _showWorkTraces,
            borderRadius: BorderRadius.circular(8),
            child: StatusPill(
              label: '$_traces 条工作轨迹',
              color: TangramColors.jade,
              dense: true,
            ),
          ),
        ),
        const InfoTile(
          icon: Icons.hub,
          title: '本地模型 + 工具循环',
          color: TangramColors.jade,
        ),
        const SizedBox(height: TangramSpacing.xl),
        const SandboxControls(),
        buildStatusBlock(),
        const SizedBox(height: TangramSpacing.md),

        SectionTitle(
          title: '模型配置',
          subtitle: '选一个教师来源',
          icon: Icons.tune_outlined,
        ),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: 'api',
              icon: Icon(Icons.api, size: 16),
              label: Text('调用 API'),
            ),
            ButtonSegment<String>(
              value: 'local',
              icon: Icon(Icons.storage_outlined, size: 16),
              label: Text('本地基底模型'),
            ),
          ],
          selected: <String>{_source},
          onSelectionChanged: (Set<String> s) =>
              setState(() => _source = s.first),
        ),
        const SizedBox(height: TangramSpacing.md),
        if (_source == 'local') ..._localSource() else ..._apiSource(),
        const SizedBox(height: TangramSpacing.xl),
        _buildCloudModels(),
        const SizedBox(height: TangramSpacing.xl),
        TextField(
          controller: _nameCtrl,
          enabled: !nameLocked,
          onChanged: (String v) => persona.setModelName(v.trim()),
          decoration: const InputDecoration(
            labelText: '我的模型名称',
            hintText: '只能设置一次，训练后不能改',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: TangramSpacing.xl),

        SectionTitle(
          title: '做任务',
          subtitle: '做任务 → 采集轨迹 → 训练信号',
          icon: Icons.work_outline,
          accent: TangramColors.gold,
        ),
        TextField(
          controller: _taskCtrl,
          minLines: 2,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '工作任务',
            hintText: '例如：帮我写一个 Python 快排函数',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: TangramSpacing.sm),
        Wrap(
          spacing: TangramSpacing.sm,
          children: <Widget>[
            FilledButton.icon(
              onPressed: loading ? null : _work,
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('执行并采集'),
            ),
            OutlinedButton.icon(
              onPressed: loading ? null : _distill,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('蒸馏出我的模型'),
            ),
          ],
        ),
        const SizedBox(height: TangramSpacing.xl),

        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            tooltip: '刷新模型文件',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: loading
                ? null
                : () => _refreshModels(context.read<BackendClient>()),
          ),
        ),
        SectionTitle(
          title: '我训练的模型',
          subtitle: '模型文件 · 右侧 ⋮ 可分享 / 删除 / 编辑',
          icon: Icons.memory_outlined,
          trailing: StatusPill(
            label: '${_ownModels.length} 个',
            color: TangramColors.success,
            dense: true,
          ),
        ),
        ModelFileList(
          models: _ownModels,
          onShare: _shareModel,
          onDelete: _deleteModel,
          onRename: _renameModel,
        ),
        const SizedBox(height: TangramSpacing.xl),

        if (_baseModels.isNotEmpty) ...<Widget>[
          SectionTitle(
            title: '已下载的本地基底模型',
            subtitle: '模型权重文件',
            icon: Icons.check_circle_outline,
            accent: TangramColors.success,
          ),
          ..._baseModels.map(
            (Map<String, dynamic> b) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.storage,
                title: (b['id'] ?? 'base').toString(),
                subtitle: (b['path'] ?? '').toString(),
                color: TangramColors.success,
              ),
            ),
          ),
          const SizedBox(height: TangramSpacing.xl),
        ],

        if (_lastResult.isNotEmpty)
          if (_lastResult.contains(RegExp('失败|错误|无效|无法连接')))
            ErrorState(
              compact: true,
              icon: Icons.cloud_off_outlined,
              title: '云端调用未成功',
              message: _lastResult,
              details: '已尝试 Base URL：${_apiBaseCtrl.text.trim()}',
              onRetry: loading ? null : _testApi,
            )
          else
            GlassCard(
              child: Text(
                _lastResult,
                style: const TextStyle(fontSize: 12, height: 1.5),
              ),
            ),
      ],
    );
  }

  List<Widget> _apiSource() => <Widget>[
        InputDecorator(
          decoration: const InputDecoration(
            labelText: '模型厂商',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _vendorId,
              isDense: true,
              isExpanded: true,
              items: kTeacherVendors
                  .map(
                    (TeacherVendor v) => DropdownMenuItem<String>(
                      value: v.id,
                      child: Text(v.name),
                    ),
                  )
                  .toList(),
              onChanged: (String? v) {
                if (v != null) _applyVendor(v);
              },
            ),
          ),
        ),
        const SizedBox(height: TangramSpacing.sm),
        TextField(
          controller: _apiBaseCtrl,
          decoration: const InputDecoration(
            labelText: 'API Base URL',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: TangramSpacing.sm),
        TextField(
          controller: _apiKeyCtrl,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'API Key',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: TangramSpacing.sm),
        TextField(
          controller: _apiModelCtrl,
          decoration: const InputDecoration(
            labelText: '教师模型',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: TangramSpacing.md),
        Wrap(
          spacing: TangramSpacing.sm,
          runSpacing: TangramSpacing.sm,
          children: <Widget>[
            FilledButton.icon(
              onPressed: loading ? null : _saveCloudModel,
              icon: const Icon(Icons.add_link_rounded, size: 18),
              label: const Text('保存为云端模型'),
            ),
            OutlinedButton.icon(
              onPressed: loading ? null : _testApi,
              icon: const Icon(Icons.network_check, size: 18),
              label: const Text('测试 API 连通'),
            ),
          ],
        ),
        const SizedBox(height: TangramSpacing.sm),
        const Text(
          '保存后出现在右下角选择器里（带「云端」标记），选中即可用。可添加多个。',
          style: TextStyle(fontSize: 11.5, height: 1.6, color: TangramColors.textMuted),
        ),
      ];

  /// 已添加的云端模型（真实落盘，可删除）。监听注册表即时刷新。
  Widget _buildCloudModels() {
    final ModelRegistry registry = context.watch<ModelRegistry>();
    final List<ModelEntry> clouds = registry.cloudEntries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                '我添加的云端模型',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            StatusPill(
              label: '${clouds.length} 个',
              color: TangramColors.jade,
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: TangramSpacing.sm),
        if (clouds.isEmpty)
          GlassCard(
            child: const Text(
              '还没有云端模型。填好上方 API 后点「保存为云端模型」。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          )
        else
          ...clouds.map(
            (ModelEntry e) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.cloud_outlined,
                title: e.displayName,
                subtitle: e.subtitle,
                color: TangramColors.jade,
                trailing: IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => registry.removeCloud(e.id),
                ),
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _localSource() => <Widget>[
        TextField(
          controller: _baseCtrl,
          decoration: const InputDecoration(
            labelText: '本地基底模型',
            hintText: '本地模型路径',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ];
}
