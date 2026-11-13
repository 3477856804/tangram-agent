import 'package:flutter/material.dart';

import '../../../../design/dsh_tokens.dart';
import '../settings_config.dart';

/// 设置行：统一 16dp 内边距、14/22 标题、13/20 说明，尾随控件靠右。
class SettingsRowWidget extends StatelessWidget {
  final SettingsRow row;

  final VoidCallback? onNavigate;

  const SettingsRowWidget({
    super.key,
    required this.row,
    this.onNavigate,
  });

  Widget _base({
    required BuildContext context,
    required Widget child,
    VoidCallback? onTap,
    double vertical = 12,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: vertical),
        child: child,
      ),
    );
  }

  Widget _leading(DshPalette c, IconData? icon) {
    if (icon == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: DshSpace.x10),
      child: Icon(icon, size: 18, color: c.labelSecondary),
    );
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);

    if (row is NavigationRow) {
      final NavigationRow r = row as NavigationRow;
      return _base(
        context: context,
        onTap: r.onTap ?? onNavigate,
        child: Row(
          children: <Widget>[
            _leading(c, r.icon),
            Expanded(
              child: Text(
                r.label,
                style: DshType.s14.copyWith(color: c.labelPrimary),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.labelCaption),
          ],
        ),
      );
    }

    if (row is DropdownRow) {
      final DropdownRow r = row as DropdownRow;
      return _base(
        context: context,
        child: Row(
          children: <Widget>[
            _leading(c, r.icon),
            Expanded(
              child: Text(
                r.label,
                style: DshType.s14.copyWith(color: c.labelPrimary),
              ),
            ),
            DropdownButton<String>(
              value: r.value,
              isDense: true,
              underline: const SizedBox.shrink(),
              dropdownColor: c.menuFill,
              borderRadius: BorderRadius.circular(DshR.md),
              icon: Icon(
                Icons.expand_more_rounded,
                size: 16,
                color: c.labelTertiary,
              ),
              style: DshType.s14.copyWith(color: c.labelSecondary),
              items: r.options
                  .map(
                    (String o) => DropdownMenuItem<String>(
                      value: o,
                      child: Text(o, style: DshType.s14),
                    ),
                  )
                  .toList(),
              onChanged: r.onChanged == null
                  ? null
                  : (String? v) {
                      if (v != null) r.onChanged!(v);
                    },
            ),
          ],
        ),
      );
    }

    if (row is ToggleRow) {
      final ToggleRow r = row as ToggleRow;
      return _base(
        context: context,
        vertical: 6,
        child: Row(
          children: <Widget>[
            _leading(c, r.icon),
            Expanded(
              child: Text(
                r.label,
                style: DshType.s14.copyWith(color: c.labelPrimary),
              ),
            ),
            Switch(
              value: r.value,
              onChanged: r.onChanged,
              activeThumbColor: Colors.white,
              activeTrackColor: c.business,
              inactiveThumbColor: Colors.white,
              inactiveTrackColor: c.labelDimmed,
              trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      );
    }

    if (row is InfoRow) {
      final InfoRow r = row as InfoRow;
      return _base(
        context: context,
        vertical: 10,
        child: Row(
          children: <Widget>[
            _leading(c, r.icon),
            Expanded(
              child: Text(
                r.label,
                style: DshType.s14.copyWith(color: c.labelPrimary),
              ),
            ),
            Text(
              r.value,
              style: DshType.xs13.copyWith(color: c.labelTertiary),
            ),
          ],
        ),
      );
    }

    if (row is CustomRow) {
      final CustomRow r = row as CustomRow;
      return r.builder(context);
    }

    return const SizedBox.shrink();
  }
}
