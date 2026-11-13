/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/services/model_state.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';

class ModelVersion {
  ModelVersion(this.tag, this.active);
  final String tag;
  bool active;
}

/// 模型文件列表（训练页与模型管理页共用）。
///
/// 每条记录右侧提供 ⋮ 菜单：分享 / 删除 / 编辑。
class ModelFileList extends StatelessWidget {
  const ModelFileList({
    super.key,
    required this.models,
    required this.onShare,
    required this.onDelete,
    required this.onRename,
    this.emptyMessage,
  });

  final List<Map<String, dynamic>> models;
  final void Function(Map<String, dynamic> model) onShare;
  final void Function(Map<String, dynamic> model) onDelete;
  final void Function(Map<String, dynamic> model) onRename;
  final String? emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (models.isEmpty) {
      return GlassCard(
        child: EmptyState(
          icon: Icons.auto_awesome,
          title: '还没有模型文件',
          message: emptyMessage ??
              '先去训练页采集轨迹，再蒸馏出你的模型',
          compact: true,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: models
          .map(
            (Map<String, dynamic> m) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: ModelFileTile(
                model: m,
                onShare: () => onShare(m),
                onDelete: () => onDelete(m),
                onRename: () => onRename(m),
              ),
            ),
          )
          .toList(),
    );
  }
}

class ModelFileTile extends StatelessWidget {
  const ModelFileTile({
    super.key,
    required this.model,
    required this.onShare,
    required this.onDelete,
    required this.onRename,
  });

  final Map<String, dynamic> model;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback onRename;

  @override
  Widget build(BuildContext context) {
    final String name = (model['name'] ?? 'my-agent').toString();
    final String path = (model['path'] ?? '').toString();
    final String version = (model['version'] ?? '0.0.1').toString();
    final String samples = (model['samples'] ?? 0).toString();
    return InfoTile(
      icon: Icons.auto_awesome,
      title: name,
      subtitle: path.isEmpty
          ? 'v$version  ·  样本 $samples'
          : '$path  ·  v$version  ·  样本 $samples',
      color: TangramColors.success,
      trailing: PopupMenuButton<String>(
        tooltip: '模型操作',
        onSelected: (String value) {
          switch (value) {
            case 'share':
              onShare();
            case 'delete':
              onDelete();
            case 'rename':
              onRename();
          }
        },
        itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'share', child: Text('分享')),
          PopupMenuItem<String>(value: 'rename', child: Text('编辑')),
          PopupMenuItem<String>(value: 'delete', child: Text('删除')),
        ],
      ),
    );
  }
}

class ModelManagerPanel extends StatefulWidget {
  const ModelManagerPanel({super.key});

  @override
  State<ModelManagerPanel> createState() => _ModelManagerPanelState();
}

class _ModelManagerPanelState extends State<ModelManagerPanel>
    with AsyncPanelMixin {
  final List<ModelVersion> _versions = <ModelVersion>[];
  final List<Map<String, dynamic>> _modelFiles = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env = await backend.sendControl('model_route', {'action': 'list'});
        final payload = env.payload;
        _versions.clear();
        if (payload is Map) {
          final list = payload['versions'];
          if (list is List) {
            for (final v in list) {
              if (v is! Map) continue;
              _versions.add(
                ModelVersion(
                  (v['tag'] ?? v['name'] ?? '未知').toString(),
                  v['active'] == true,
                ),
              );
            }
          }
        }
        final res = await backend.distill('models');
        final data = res['data'];
        _modelFiles.clear();
        if (data is Map && data['own_models'] is List) {
          for (final dynamic m in data['own_models'] as List) {
            if (m is Map) {
              _modelFiles.add(
                m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
              );
            }
          }
        }
      });

  Future<void> _rollback(String tag) => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final modelState = context.read<ModelState>();
        await backend.sendControl('model_route', {
          'action': 'activate',
          'tag': tag,
        });
        await backend.sendControl('reload', <String, dynamic>{});
        for (final v in _versions) {
          v.active = v.tag == tag;
        }
        modelState.load(backend);
      });

  @override
  Widget build(BuildContext context) {
    final int activeCount = _versions
        .where((ModelVersion v) => v.active)
        .length;
    return PanelPage(
      children: <Widget>[
        const SectionTitle(
          title: '模型管理',
          subtitle: '当前使用的模型',
          icon: Icons.memory,
          accent: TangramColors.gold,
        ),
        Consumer<ModelState>(
          builder: (context, modelState, _) => InfoTile(
            icon: Icons.memory,
            title: '当前模型',
            subtitle: modelState.hasActive
                ? modelState.summary
                : '还没加载模型',
            color: modelState.hasActive
                ? TangramColors.success
                : TangramColors.textMuted,
            trailing: StatusPill(
              label: modelState.hasActive ? '已加载' : '未加载',
              color: modelState.hasActive
                  ? TangramColors.success
                  : TangramColors.textMuted,
              dense: true,
            ),
          ),
        ),
        const SizedBox(height: TangramSpacing.xl),
        SectionTitle(
          title: '模型文件',
          subtitle: '训练产出的模型文件',
          icon: Icons.folder_copy_outlined,
          trailing: StatusPill(
            label: '${_modelFiles.length} 个',
            color: TangramColors.jade,
            dense: true,
          ),
        ),
        ModelFileList(
          models: _modelFiles,
          onShare: (Map<String, dynamic> m) =>
              _modelAction(context, m, 'share'),
          onDelete: (Map<String, dynamic> m) =>
              _modelAction(context, m, 'delete'),
          onRename: (Map<String, dynamic> m) =>
              _modelAction(context, m, 'rename'),
        ),
        const SizedBox(height: TangramSpacing.xl),
        SectionTitle(
          title: '模型版本池',
          subtitle: '版本切换与回滚',
          icon: Icons.layers,
          trailing: StatusPill(
            label: '${_versions.length} 个版本',
            color: TangramColors.jade,
            dense: true,
          ),
        ),
        if (_versions.isEmpty && !loading)
          const GlassCard(
            child: EmptyState(
              icon: Icons.layers_clear,
              title: '暂无模型版本',
              message: '训练完成或导入 GGUF 后会出现在这里',
              compact: true,
            ),
          )
        else
          ..._versions.map(
            (ModelVersion v) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: v.active ? Icons.star : Icons.memory,
                title: v.tag,
                subtitle: v.active ? '当前版本' : '可回滚到此版本',
                color: v.active
                    ? TangramColors.gold
                    : TangramColors.textSecondary,
                trailing: v.active
                    ? const StatusPill(
                        label: '当前',
                        color: TangramColors.success,
                        dense: true,
                      )
                    : TextButton(
                        onPressed: loading ? null : () => _rollback(v.tag),
                        child: const Text('回滚'),
                      ),
              ),
            ),
          ),
        const SizedBox(height: TangramSpacing.xl),
        SectionTitle(
          title: '训练与调度',
          subtitle: '${activeCount > 0 ? '可以开始训练' : '先激活一个模型'}',
          icon: Icons.auto_awesome,
        ),
        const InfoTile(
          icon: Icons.auto_awesome,
          title: '训练流水线',
          subtitle: '蒸馏 → LoRA → 合并 GGUF → 晋升 → 回滚',
          color: TangramColors.gold,
        ),
        const SizedBox(height: TangramSpacing.sm),
        const InfoTile(
          icon: Icons.rule,
          title: '学习调度',
          subtitle: '经验回放 / 遗忘曲线 / 技能巩固',
          color: TangramColors.jade,
        ),
        const SizedBox(height: TangramSpacing.xl),
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: loading ? null : _load,
          ),
        ),
        buildStatusBlock(),
      ],
    );
  }

  Future<void> _modelAction(
    BuildContext context,
    Map<String, dynamic> model,
    String action,
  ) async {
    final backend = context.read<BackendClient>();
    final String name = (model['name'] ?? '').toString();
    if (name.isEmpty) return;
    if (action == 'share') {
      await _shareModel(context, model);
      return;
    }
    if (action == 'rename') {
      await _renameModel(context, backend, name);
      return;
    }
    await runGuarded(() async {
      final res = await backend.distill(
        'delete_model',
        args: <String, dynamic>{'name': name},
      );
      if (res['ok'] == true) {
        _modelFiles.removeWhere(
          (Map<String, dynamic> m) => m['name'].toString() == name,
        );
      }
    });
    await _load();
  }

  Future<void> _shareModel(
    BuildContext context,
    Map<String, dynamic> model,
  ) async {
    try {
      await Share.share(
        '我的模型：${model['name'] ?? 'my-agent'}\n'
        '版本：${model['version'] ?? '0.0.1'}\n'
        '路径：${model['path'] ?? ''}',
      );
    } on Object catch (e) {
      if (context.mounted) setError('分享失败：$e');
    }
  }

  Future<void> _renameModel(
    BuildContext context,
    BackendClient backend,
    String oldName,
  ) async {
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
      await backend.distill(
        'rename_model',
        args: <String, dynamic>{'name': oldName, 'new_name': newName},
      );
    });
    await _load();
  }
}
