/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/bridge/bridge_protocol.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';

class GraphNode {
  GraphNode(this.id, this.label, this.degree);
  final String id;
  final String label;
  final int degree;
}

class GraphViewer extends StatefulWidget {
  const GraphViewer({super.key});

  @override
  State<GraphViewer> createState() => _GraphViewerState();
}

class _GraphViewerState extends State<GraphViewer> with AsyncPanelMixin {
  final List<GraphNode> _nodes = <GraphNode>[];
  StreamSubscription<BridgeEnvelope>? _sub;

  @override
  void initState() {
    super.initState();
    _subscribeHotPath();
    _load();
  }

  void _subscribeHotPath() {
    final backend = context.read<BackendClient>();
    _sub = backend.onHotPath
        .where(
          (e) =>
              e.channel == BridgeChannel.hotPath && e.topic == 'graph_result',
        )
        .listen(_onHotPath);
  }

  void _onHotPath(BridgeEnvelope e) {
    final payload = e.payload;
    if (payload is! Map) return;
    final nodes = payload['nodes'];
    if (nodes is List) {
      _mergeNodes(nodes);
      if (mounted) setState(() {});
    }
  }

  void _mergeNodes(List<dynamic> list) {
    for (final n in list) {
      if (n is! Map) continue;
      final id = (n['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final label = (n['label'] ?? id).toString();
      final degree = (n['degree'] is num) ? (n['degree'] as num).toInt() : 0;
      final idx = _nodes.indexWhere((x) => x.id == id);
      if (idx >= 0) {
        _nodes[idx] = GraphNode(id, label, degree);
      } else {
        _nodes.add(GraphNode(id, label, degree));
      }
    }
  }

  Future<void> _load() => runGuarded(() async {
    final backend = context.read<BackendClient>();
    final env = await backend.sendControl('rpc', {'action': 'graph_query'});
    final payload = env.payload;
    if (payload is Map) {
      final nodes = payload['nodes'];
      if (nodes is List) _mergeNodes(nodes);
    }
    // 无数据即真实空态，不再填充硬编码示例节点。
  });

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PanelPage(
      children: <Widget>[
        SectionTitle(
          title: '知识图谱',
          subtitle: '实时更新的节点',
          icon: Icons.hub,
          accent: TangramColors.jade,
          trailing: StatusPill(
            label: '${_nodes.length} 节点',
            color: TangramColors.jade,
            dense: true,
          ),
        ),
        const InfoTile(
          icon: Icons.hub,
          title: '图谱节点',
          subtitle: '本地数据，只读',
          color: TangramColors.gold,
          trailing: StatusPill(
            label: '只读',
            color: TangramColors.textMuted,
            dense: true,
          ),
        ),
        const SizedBox(height: TangramSpacing.lg),
        if (_nodes.isEmpty && !loading)
          GlassCard(
            child: const EmptyState(
              icon: Icons.hub_outlined,
              title: '暂无图谱节点',
              message: '沙箱未启动或暂无数据',
              compact: true,
            ),
          )
        else
          ..._nodes.map(
            (GraphNode n) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.circle,
                title: n.label,
                subtitle: 'id = ${n.id}',
                color: n.degree >= 12 ? TangramColors.gold : TangramColors.jade,
                trailing: StatusPill(
                  label: '度数 ${n.degree}',
                  color: n.degree >= 12
                      ? TangramColors.gold
                      : TangramColors.jade,
                  dense: true,
                ),
              ),
            ),
          ),
        const SizedBox(height: TangramSpacing.xl),
        Row(
          children: <Widget>[
            FilledButton.icon(
              onPressed: loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新'),
            ),
          ],
        ),
        buildStatusBlock(),
      ],
    );
  }
}
