import 'package:flutter/widgets.dart';

class InfoItem {
  final String label;

  final String? url;

  final VoidCallback? onTap;

  const InfoItem({
    required this.label,
    this.url,
    this.onTap,
  });
}

sealed class SettingsRow {
  final IconData? icon;

  final String label;

  const SettingsRow({this.icon, required this.label});
}

class NavigationRow extends SettingsRow {
  final VoidCallback? onTap;

  const NavigationRow({
    super.icon,
    required super.label,
    this.onTap,
  });
}

class DropdownRow extends SettingsRow {
  final String value;

  final List<String> options;

  final void Function(String)? onChanged;

  const DropdownRow({
    super.icon,
    required super.label,
    required this.value,
    required this.options,
    this.onChanged,
  });
}

class ToggleRow extends SettingsRow {
  final bool value;

  final ValueChanged<bool>? onChanged;

  const ToggleRow({
    super.icon,
    required super.label,
    required this.value,
    this.onChanged,
  });
}

class InfoRow extends SettingsRow {
  final String value;

  const InfoRow({
    super.icon,
    required super.label,
    required this.value,
  });
}

class CustomRow extends SettingsRow {
  final WidgetBuilder builder;

  const CustomRow({
    super.icon,
    required super.label,
    required this.builder,
  });
}

class SettingsSection {
  final String title;

  final List<SettingsRow> rows;

  const SettingsSection({
    required this.title,
    required this.rows,
  });
}

class SettingsConfig {
  final double drawerHeightRatio;

  final bool showWorkspaceSwitcher;

  final List<SettingsSection> sections;

  final List<InfoItem> infoItems;

  final String? appVersion;

  const SettingsConfig({
    this.drawerHeightRatio = 0.7,
    this.showWorkspaceSwitcher = false,
    this.sections = const [],
    this.infoItems = const [],
    this.appVersion,
  });
}
