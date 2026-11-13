/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/services/model_registry.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';

/// 模型商店：数据源为魔塔 ModelScope，下载命令由内置沙箱执行。
/// 硬件感知做推荐与 token/s 估算；离线时统一诚实空态，不编造条目。
class DependencyPanel extends StatefulWidget {
  const DependencyPanel({super.key});

  @override
  State<DependencyPanel> createState() => _DependencyPanelState();
}

class _DependencyPanelState extends State<DependencyPanel>
    with AsyncPanelMixin {
  final TextEditingController _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];
  Map<String, dynamic> _hardware = <String, dynamic>{};
  String _lastCommand = '';
  String _downloadJobId = '';

  @override
  void initState() {
    super.initState();
    _loadHardware();
    _search('');
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadHardware() async {
    try {
      final backend = context.read<BackendClient>();
      final env = await backend.sendControl('model_store', {
        'action': 'hardware',
      });
      final payload = env.payload;
      if (payload is Map) {
        _hardware = payload.map(
          (dynamic k, dynamic v) => MapEntry(k.toString(), v),
        );
      }
    } on Object {
      _hardware = <String, dynamic>{};
    }
    if (mounted) setState(() {});
  }

  Future<void> _search(String query) => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env = await backend.sendControl('model_store', {
          'action': 'search',
          'query': query,
        });
        final payload = env.payload;
        _models = <Map<String, dynamic>>[];
        if (payload is Map && payload['models'] is List) {
          for (final dynamic m in payload['models'] as List) {
            if (m is Map) {
              _models.add(
                m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
              );
            }
          }
        }
      });

  /// 硬件感知推荐：内存越大越能容纳大参数模型。
  bool _recommended(Map<String, dynamic> m) {
    final double memoryGb = _asDouble(_hardware['memory_gb'], 0);
    if (memoryGb <= 0) return false;
    final double params = _paramBillion(m);
    if (params <= 0) return false;
    return params * 2 <= memoryGb;
  }

  /// 估算 token/s：按参数量与可用内存的粗略线性模型，明确标注为估算。
  String _estimate(Map<String, dynamic> m) {
    final double params = _paramBillion(m);
    final double memoryGb = _asDouble(_hardware['memory_gb'], 0);
    if (params <= 0 || memoryGb <= 0) return '需硬件信息';
    final double tps = (memoryGb * 6) / params;
    return '约 ${tps.toStringAsFixed(1)} token/s（估算）';
  }

  static double _paramBillion(Map<String, dynamic> m) {
    final String raw = (m['params'] ?? m['parameter'] ?? '').toString();
    final RegExp re = RegExp(r'(\d+(?:\.\d+)?)\s*[Bb亿]');
    final RegExpMatch? match = re.firstMatch(raw);
    if (match != null) return double.tryParse(match.group(1) ?? '') ?? 0;
    return double.tryParse(raw.replaceAll('B', '')) ?? 0;
  }

  static double _asDouble(dynamic v, double fallback) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  Future<void> _download(Map<String, dynamic> m) => runGuarded(() async {
        final String id = (m['id'] ?? m['name'] ?? '').toString();
        if (id.isEmpty) return;
        final backend = context.read<BackendClient>();
        final env = await backend.sendControl('model_store', {
          'action': 'download',
          'model_id': id,
        });
        final payload = env.payload;
        if (payload is Map) {
          if (payload['ok'] == true) {
            _downloadJobId = (payload['job_id'] ?? '').toString();
            _lastCommand = '下载已启动\n'
                '模型：${payload['model_id'] ?? id}\n'
                '任务：$_downloadJobId\n'
                '状态：${payload['status'] ?? ''}\n'
                '目标目录：${payload['target'] ?? ''}\n'
                '${payload['note'] ?? ''}';
          } else {
            _downloadJobId = '';
            _lastCommand = '下载未启动：${payload['error'] ?? '未知原因'}';
          }
        } else {
          _downloadJobId = '';
          _lastCommand = '返回数据异常';
        }
      });

  /// 查询后端真实下载进度（字节数 / 状态 / 已落盘文件），不编造进度。
  Future<void> _refreshDownloadStatus() => runGuarded(() async {
        if (_downloadJobId.isEmpty) return;
        final backend = context.read<BackendClient>();
        final ModelRegistry registry = context.read<ModelRegistry>();
        final env = await backend.sendControl('model_store', {
          'action': 'download_status',
          'job_id': _downloadJobId,
        });
        final payload = env.payload;
        if (payload is Map && payload['job'] is Map) {
          final Map<dynamic, dynamic> job = payload['job'] as Map;
          final int done = _asDouble(job['downloaded'], 0).round();
          final int total = _asDouble(job['total'], 0).round();
          final List<dynamic> files = job['files'] is List
              ? job['files'] as List
              : <dynamic>[];
          final String err = (job['error'] ?? '').toString();
          final String status = (job['status'] ?? '').toString();
          // 下载完成 → 刷新真实模型注册表，权重立即以「（本地）」出现在
          // 右下角模型选择器里（注册表扫描 downloads/ 里已合并完成的权重文件）。
          bool registered = false;
          if (status == 'done') {
            await registry.refresh();
            registered = true;
          }
          _lastCommand = '下载进度\n'
              '模型：${job['model_id'] ?? ''}\n'
              '状态：$status\n'
              '已下载：$done 字节${total > 0 ? ' / $total 字节' : ''}\n'
              '当前文件：${job['current'] ?? ''}\n'
              '已存文件：${files.length} 个\n'
              '目标目录：${job['target'] ?? ''}\n'
              '${registered ? '✓ 已登记为本地模型，右下角可选\n' : ''}'
              '${err.isEmpty ? '' : '错误：$err'}';
        } else {
          _lastCommand = '进度查询失败：${payload is Map ? payload['error'] ?? '' : '非预期结构'}';
        }
      });

  /// 已下载完成的本地权重（真实磁盘文件）。下载完成会自动登记，
  /// 并出现在聊天右下角模型选择器里，名称带「（本地）」。
  Widget _buildLocalModels() {
    final ModelRegistry registry = context.watch<ModelRegistry>();
    final List<ModelEntry> locals = registry.localEntries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                '我已下载的本地模型',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            StatusPill(
              label: '${locals.length} 个',
              color: TangramColors.success,
              dense: true,
            ),
            IconButton(
              tooltip: '刷新已下载模型',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => registry.refresh(),
            ),
          ],
        ),
        const SizedBox(height: TangramSpacing.sm),
        if (locals.isEmpty)
          GlassCard(
            child: const Text(
              '还没有本地模型。下载完成后会自动登记到右下角选择器。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          )
        else
          ...locals.map(
            (ModelEntry e) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.storage_outlined,
                title: e.displayName,
                subtitle: e.subtitle,
                color: TangramColors.success,
              ),
            ),
          ),
        const SizedBox(height: TangramSpacing.lg),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final double memoryGb = _asDouble(_hardware['memory_gb'], 0);
    final int cores = _asDouble(_hardware['cpu_cores'], 0).round();
    return PanelPage(
      children: <Widget>[
        const SectionTitle(
          title: '模型商店',
          subtitle: '魔搭 ModelScope · 下载到本地',
          icon: Icons.storefront_outlined,
          accent: TangramColors.gold,
        ),
        GlassCard(
          padding: const EdgeInsets.all(TangramSpacing.md),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  memoryGb > 0
                      ? '硬件：${memoryGb.toStringAsFixed(1)} GB 内存 · '
                          '$cores 核 · 已标注推荐'
                      : '暂无硬件信息，推荐与估算不可用',
                  style: const TextStyle(
                    color: TangramColors.textSecondary,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: TangramSpacing.md),
        buildStatusBlock(),
        const SizedBox(height: TangramSpacing.md),
        _buildLocalModels(),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  hintText: '搜索魔搭模型，例如 qwen',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: _search,
              ),
            ),
            const SizedBox(width: TangramSpacing.sm),
            FilledButton.icon(
              onPressed: loading ? null : () => _search(_searchCtrl.text.trim()),
              icon: const Icon(Icons.search, size: 16),
              label: const Text('搜索'),
            ),
          ],
        ),
        const SizedBox(height: TangramSpacing.lg),
        if (_models.isEmpty && !loading)
          GlassCard(
            child: EmptyState(
              icon: Icons.cloud_off_outlined,
              title: '暂无模型数据',
              message: offline
                  ? kOfflineHint
                  : '换个关键词试试',
              compact: true,
            ),
          )
        else
          ..._models.map(
            (Map<String, dynamic> m) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.model_training_outlined,
                title: (m['name'] ?? m['id'] ?? '未命名模型').toString(),
                subtitle:
                    '${m['id'] ?? ''}  ·  ${m['params'] ?? '参数未知'}  ·  '
                    '${_estimate(m)}',
                color: _recommended(m)
                    ? TangramColors.success
                    : TangramColors.textSecondary,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (_recommended(m))
                      const StatusPill(
                        label: '推荐',
                        color: TangramColors.success,
                        dense: true,
                      ),
                    const SizedBox(width: TangramSpacing.sm),
                    TextButton(
                      onPressed: loading ? null : () => _download(m),
                      child: const Text('下载'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (_lastCommand.isNotEmpty) ...<Widget>[
          const SizedBox(height: TangramSpacing.lg),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  '下载任务',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: TangramSpacing.sm),
                Text(
                  _lastCommand,
                  style: const TextStyle(fontSize: 12, height: 1.5),
                ),
                if (_downloadJobId.isNotEmpty) ...<Widget>[
                  const SizedBox(height: TangramSpacing.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _refreshDownloadStatus,
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('刷新进度'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
