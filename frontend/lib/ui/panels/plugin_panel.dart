/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';

class PluginItem {
  PluginItem(this.name, this.permission, this.depStatus, this.installed);
  final String name;
  final String permission;
  String depStatus;
  bool installed;
}

/// 插件生命周期子分区：已合并进「插件社区」页，不再是侧边栏独立菜单。
/// 离线状态由父页面统一渲染一份，这里不重复。
class PluginLifecycleSection extends StatefulWidget {
  const PluginLifecycleSection({super.key});

  @override
  State<PluginLifecycleSection> createState() =>
      _PluginLifecycleSectionState();
}

class _PluginLifecycleSectionState extends State<PluginLifecycleSection>
    with AsyncPanelMixin {
  final List<PluginItem> _plugins = <PluginItem>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env = await backend.sendControl('plugin_lifecycle', {
          'action': 'list',
        });
        final payload = env.payload;
        _plugins.clear();
        if (payload is Map && payload['plugins'] is List) {
          for (final dynamic p in payload['plugins'] as List) {
            if (p is! Map) continue;
            _plugins.add(
              PluginItem(
                (p['name'] ?? '插件').toString(),
                (p['permission'] ?? '').toString(),
                (p['dep_status'] ?? '未知').toString(),
                p['installed'] == true,
              ),
            );
          }
        }
      });

  Future<void> _install(PluginItem item) => runGuarded(() async {
        final backend = context.read<BackendClient>();
        await backend.sendControl('plugin_lifecycle', {
          'action': 'install',
          'name': item.name,
        });
        await _load();
      });

  @override
  Widget build(BuildContext context) {
    final int installed = _plugins.where((PluginItem p) => p.installed).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionTitle(
          title: '已安装插件',
          subtitle: '本地插件与版本',
          icon: Icons.verified_user_outlined,
          accent: TangramColors.jade,
          trailing: StatusPill(
            label: '$installed / ${_plugins.length} 已安装',
            color: installed > 0
                ? TangramColors.success
                : TangramColors.textMuted,
            dense: true,
          ),
        ),
        if (_plugins.isEmpty && !loading)
          const GlassCard(
            child: EmptyState(
              icon: Icons.extension_off,
              title: '暂无已安装插件',
              message: '从上方社区安装后会出现在这里',
              compact: true,
            ),
          )
        else
          ..._plugins.map(
            (PluginItem p) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.extension,
                title: p.name,
                subtitle: '权限：${p.permission}',
                color: p.installed
                    ? TangramColors.jade
                    : TangramColors.textSecondary,
                trailing: p.installed
                    ? StatusPill(
                        label: p.depStatus,
                        color: p.depStatus.contains('就绪')
                            ? TangramColors.success
                            : TangramColors.warning,
                        dense: true,
                      )
                    : TextButton(
                        onPressed: loading ? null : () => _install(p),
                        child: const Text('安装'),
                      ),
              ),
            ),
          ),
        const SizedBox(height: TangramSpacing.md),
        const InfoTile(
          icon: Icons.inventory_2,
          title: '版本池',
          subtitle: '插件版本存放在应用目录里',
          color: TangramColors.gold,
        ),
        const SizedBox(height: TangramSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            tooltip: '刷新插件',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: loading ? null : _load,
          ),
        ),
      ],
    );
  }
}
