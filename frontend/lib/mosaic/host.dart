// mosaic · 宿主：左侧导航 + 右侧面板；支持热替换 registry 与空态兜底。

import 'package:flutter/material.dart';

import 'panel.dart';
import 'registry.dart';

class MosaicHost extends StatefulWidget {
  const MosaicHost({
    super.key,
    required this.registry,
    required this.available,
    this.safeMode = false,
    this.initialId,
  });

  final MosaicRegistry registry;
  final Set<MosaicCapability> available;
  final bool safeMode;
  final String? initialId;

  @override
  State<MosaicHost> createState() => _MosaicHostState();
}

class _MosaicHostState extends State<MosaicHost> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final List<MosaicPanel> panels =
        widget.registry.visible(widget.available, safeMode: widget.safeMode);
    if (panels.isEmpty) {
      return const Center(
          child: Text('没有可用面板：检查能力令牌或安全模式'));
    }
    final MosaicPanel current = widget.registry
            .find(_selectedId ?? widget.initialId ?? '') ??
        panels.first;
    return Row(
      children: <Widget>[
        NavigationRail(
          selectedIndex:
              panels.indexWhere((MosaicPanel p) => p.id == current.id),
          // 此前是空实现 `(_) {}`，点导航栏不切换面板；现在真正切面板，
          // _KeepAlive 在 id 变化时重建内容（旧面板状态不保留）。
          onDestinationSelected: (int index) {
            setState(() {
              _selectedId = panels[index].id;
            });
          },
          labelType: NavigationRailLabelType.all,
          destinations: panels
              .map((MosaicPanel p) => NavigationRailDestination(
                  icon: Icon(_icon(p.icon)), label: Text(p.title)))
              .toList(),
        ),
        const VerticalDivider(width: 1),
        Expanded(child: _KeepAlive(page: current)),
      ],
    );
  }

  static IconData _icon(String name) {
    switch (name) {
      case 'chat':
        return Icons.chat_bubble_outline;
      case 'settings':
        return Icons.settings_outlined;
      case 'model':
        return Icons.memory;
      case 'channel':
        return Icons.forum_outlined;
      default:
        return Icons.dashboard_outlined;
    }
  }
}

class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.page});

  final MosaicPanel page;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> {
  Widget? _child;

  @override
  void initState() {
    super.initState();
    _child = widget.page.builder(context);
  }

  @override
  void didUpdateWidget(covariant _KeepAlive oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page.id != widget.page.id) {
      _child = widget.page.builder(context);
    }
  }

  @override
  Widget build(BuildContext context) => _child ?? const SizedBox.shrink();
}
