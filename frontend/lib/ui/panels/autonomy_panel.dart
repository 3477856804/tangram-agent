/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';

class RuleItem {
  RuleItem(this.name, this.enabled);
  final String name;
  bool enabled;
}

class TimerItem {
  TimerItem(this.label);
  final String label;
}

/// 「主动」子分区：已并入人格设置页，复用 proactive_task 后端。
/// 不再作为侧边栏独立菜单，也不再单独渲染离线状态块（由父页面统一一份）。
class ProactiveSection extends StatefulWidget {
  const ProactiveSection({super.key});

  @override
  State<ProactiveSection> createState() => _ProactiveSectionState();
}

class _ProactiveSectionState extends State<ProactiveSection>
    with AsyncPanelMixin {
  final List<RuleItem> _rules = <RuleItem>[];
  final List<TimerItem> _timers = <TimerItem>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env =
            await backend.sendControl('proactive_task', {'action': 'list'});
        final payload = env.payload;
        _rules.clear();
        _timers.clear();
        if (payload is Map) {
          final rules = payload['rules'];
          if (rules is List) {
            for (final r in rules) {
              if (r is! Map) continue;
              _rules.add(
                RuleItem(
                  (r['name'] ?? '规则').toString(),
                  r['enabled'] == true,
                ),
              );
            }
          }
          final timers = payload['timers'];
          if (timers is List) {
            for (final t in timers) {
              _timers.add(TimerItem(t.toString()));
            }
          }
        }
      });

  Future<void> _toggleRule(int index, bool value) => runGuarded(() async {
        final item = _rules[index];
        item.enabled = value;
        final backend = context.read<BackendClient>();
        await backend.sendControl('proactive_task', {
          'action': 'set_rule',
          'name': item.name,
          'enabled': value,
        });
      });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionTitle(
          title: '主动',
          subtitle: '按情境自动触发',
          icon: Icons.bolt_outlined,
          accent: TangramColors.gold,
        ),
        if (_rules.isEmpty && !loading)
          const GlassCard(
            child: EmptyState(
              icon: Icons.rule,
              title: '暂无主动规则',
              message: '启动沙箱后同步规则',
              compact: true,
            ),
          )
        else
          ..._rules.asMap().entries.map(
                (MapEntry<int, RuleItem> e) => _RuleTile(
                  rule: e.value,
                  enabled: !loading,
                  onChanged: (bool v) => _toggleRule(e.key, v),
                ),
              ),
        const SizedBox(height: TangramSpacing.xl),
        const SectionTitle(
          title: '定时触发',
          subtitle: '周期任务',
          icon: Icons.schedule,
        ),
        if (_timers.isEmpty && !loading)
          const GlassCard(
            child: EmptyState(
              icon: Icons.schedule_outlined,
              title: '暂无定时任务',
              message: '可在这里查看周期同步与提醒',
              compact: true,
            ),
          )
        else
          ..._timers.map(
            (TimerItem t) => Padding(
              padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
              child: InfoTile(
                icon: Icons.schedule,
                title: t.label,
                subtitle: '自动触发 · 可随时暂停',
                color: TangramColors.gold,
                trailing: const StatusPill(
                  label: '已规划',
                  color: TangramColors.gold,
                  dense: true,
                ),
              ),
            ),
          ),
        const SizedBox(height: TangramSpacing.xl),
        const SectionTitle(
          title: '内在动机',
          subtitle: '好奇心与主动性',
          icon: Icons.psychology,
        ),
        const InfoTile(
          icon: Icons.psychology,
          title: '内在动机引擎',
          subtitle: '还在规划中，尚未接入',
          color: TangramColors.gold,
          trailing: StatusPill(
            label: '已规划',
            color: TangramColors.gold,
            dense: true,
          ),
        ),
        const SizedBox(height: TangramSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            tooltip: '刷新主动规则',
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: loading ? null : _load,
          ),
        ),
      ],
    );
  }
}

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.enabled,
    required this.onChanged,
  });

  final RuleItem rule;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final Color color =
        rule.enabled ? TangramColors.jade : TangramColors.textMuted;
    return GlassCard(
      margin: const EdgeInsets.only(bottom: TangramSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: TangramSpacing.lg,
        vertical: TangramSpacing.md,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(TangramRadii.sm),
              border: Border.all(color: color.withOpacity(0.22)),
            ),
            child: Icon(Icons.bolt, size: 20, color: color),
          ),
          const SizedBox(width: TangramSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(rule.name, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  rule.enabled ? '已启用 · 自动评估' : '已暂停',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: TangramColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          Switch(value: rule.enabled, onChanged: enabled ? onChanged : null),
        ],
      ),
    );
  }
}
