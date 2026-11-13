/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/agent/skill.dart';
import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';
import 'package:tangram/ui/panels/plugin_panel.dart';

/// 插件社区：拉取 GitHub / Gitee 的 md 技能、DSH 插件、.cosmo 插件，
/// 按热度排序、一键安装；后端复用 plugin_host.py，技能侧复用 skill.dart。
/// 原生物识别审计日志已移除，个人身份设置改为独立页面。
class IdentityPanel extends StatefulWidget {
  const IdentityPanel({super.key});

  @override
  State<IdentityPanel> createState() => _IdentityPanelState();
}

class _IdentityPanelState extends State<IdentityPanel> with AsyncPanelMixin {
  static const List<String> _filters = <String>[
    '全部',
    'md 技能',
    'DSH 插件',
    '.cosmo 插件',
  ];

  String _filter = '全部';
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  final SkillRegistry _skills = SkillRegistry();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env = await backend.sendControl('plugin_community', {
          'action': 'catalog',
        });
        final payload = env.payload;
        _items = <Map<String, dynamic>>[];
        if (payload is Map && payload['items'] is List) {
          for (final dynamic p in payload['items'] as List) {
            if (p is Map) {
              _items.add(
                p.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
              );
            }
          }
        }
        _items.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
            _heat(b).compareTo(_heat(a)));
      });

  static int _heat(Map<String, dynamic> m) {
    final dynamic v = m['heat'] ?? m['stars'] ?? 0;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  Future<void> _install(Map<String, dynamic> item) => runGuarded(() async {
        final backend = context.read<BackendClient>();
        await backend.sendControl('plugin_community', {
          'action': 'install',
          'name': (item['name'] ?? '').toString(),
          'source': (item['source'] ?? '').toString(),
          'kind': (item['kind'] ?? '').toString(),
        });
        await _load();
      });

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> visible = _filter == '全部'
        ? _items
        : _items
            .where((Map<String, dynamic> m) =>
                (m['kind'] ?? '').toString() == _filter)
            .toList();

    return PanelPage(
      children: <Widget>[
        const SectionTitle(
          title: '插件社区',
          subtitle: 'GitHub / Gitee 技能与插件',
          icon: Icons.extension_outlined,
          accent: TangramColors.gold,
        ),
        GlassCard(
          padding: const EdgeInsets.all(TangramSpacing.md),
          child: Text(
            '本地已注册 ${_skills.count} 个技能。社区条目需沙箱启动后拉取。',
            style: const TextStyle(
              color: TangramColors.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: TangramSpacing.md),
        buildStatusBlock(),
        const SizedBox(height: TangramSpacing.md),
        Wrap(
          spacing: TangramSpacing.sm,
          children: _filters
              .map(
                (String f) => FilterChip(
                  label: Text(f),
                  selected: _filter == f,
                  onSelected: (bool _) => setState(() => _filter = f),
                ),
              )
              .toList(),
        ),
        const SizedBox(height: TangramSpacing.lg),
        if (visible.isEmpty && !loading)
          GlassCard(
            child: EmptyState(
              icon: Icons.extension_off,
              title: '暂无社区条目',
              message: offline
                  ? kOfflineHint
                  : '启动沙箱后从 GitHub / Gitee 拉取',
              compact: true,
            ),
          )
        else
          ...visible.map(
            (Map<String, dynamic> m) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.widgets_outlined,
                title: (m['name'] ?? '未命名').toString(),
                subtitle:
                    '${m['source'] ?? 'GitHub'}  ·  ${m['kind'] ?? '技能'}  ·  '
                    '热度 ${_heat(m)}',
                color: TangramColors.jade,
                trailing: m['installed'] == true
                    ? const StatusPill(
                        label: '已安装',
                        color: TangramColors.success,
                        dense: true,
                      )
                    : TextButton(
                        onPressed: loading ? null : () => _install(m),
                        child: const Text('安装'),
                      ),
              ),
            ),
          ),
        const SizedBox(height: TangramSpacing.xl),
        const PluginLifecycleSection(),
      ],
    );
  }
}
