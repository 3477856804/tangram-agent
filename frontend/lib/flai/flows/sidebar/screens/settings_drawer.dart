import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:tangram/app_version.dart';

import '../../../../design/dsh_tokens.dart';
import '../../../../design/dsh_widgets.dart';
import '../../../../services/persona_store.dart';
import '../settings_config.dart';
import '../sidebar_config.dart';
import '../widgets/settings_row_widget.dart';
import '../widgets/workspace_switcher.dart';

void showSettingsDrawer({
  required BuildContext context,
  required SettingsConfig config,
  UserProfile? userProfile,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SettingsDrawerSheet(
      config: config,
      userProfile: userProfile,
    ),
  );
}

class _SettingsDrawerSheet extends StatefulWidget {
  final SettingsConfig config;
  final UserProfile? userProfile;

  const _SettingsDrawerSheet({
    required this.config,
    required this.userProfile,
  });

  @override
  State<_SettingsDrawerSheet> createState() => _SettingsDrawerSheetState();
}

class _SettingsDrawerSheetState extends State<_SettingsDrawerSheet> {
  final List<Widget> _pageStack = <Widget>[];

  void _pushPage(Widget page) => setState(() => _pageStack.add(page));

  void _popPage() {
    if (_pageStack.isNotEmpty) {
      setState(() => _pageStack.removeLast());
    }
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final double ratio = widget.config.drawerHeightRatio.clamp(0.4, 1.0);

    return DraggableScrollableSheet(
      initialChildSize: ratio,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (BuildContext context, ScrollController scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: c.bgBase,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(DshR.panel),
            ),
            border: Border.all(color: c.borderL2, width: dshHairline),
          ),
          clipBehavior: Clip.antiAlias,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (Widget child, Animation<double> animation) {
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(1, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              );
            },
            child: _pageStack.isEmpty
                ? _RootSettingsPage(
                    key: const ValueKey<String>('root'),
                    config: widget.config,
                    userProfile: widget.userProfile,
                    scrollController: scrollController,
                    pushPage: _pushPage,
                    popPage: _popPage,
                  )
                : KeyedSubtree(
                    key: ValueKey<int>(_pageStack.length),
                    child: _pageStack.last,
                  ),
          ),
        );
      },
    );
  }
}

class _RootSettingsPage extends StatelessWidget {
  final SettingsConfig config;
  final UserProfile? userProfile;
  final ScrollController scrollController;
  final void Function(Widget) pushPage;
  final VoidCallback popPage;

  const _RootSettingsPage({
    super.key,
    required this.config,
    required this.userProfile,
    required this.scrollController,
    required this.pushPage,
    required this.popPage,
  });

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    // 应用全局设置：全部落到 PersonaStore，重启后保持。
    final PersonaStore persona = context.watch<PersonaStore>();
    final List<SettingsSection> sections = <SettingsSection>[
      SettingsSection(
        title: '应用权限',
        rows: <SettingsRow>[
          ToggleRow(
            icon: Icons.folder_outlined,
            label: '文件访问',
            value: persona.permissionFiles,
            onChanged: persona.setPermissionFiles,
          ),
          ToggleRow(
            icon: Icons.notifications_outlined,
            label: '通知',
            value: persona.permissionNotifications,
            onChanged: persona.setPermissionNotifications,
          ),
        ],
      ),
      SettingsSection(
        title: '语言与主题',
        rows: <SettingsRow>[
          DropdownRow(
            icon: Icons.language_outlined,
            label: '语言',
            value: persona.language,
            options: const <String>['简体中文', '繁體中文', 'English'],
            onChanged: persona.setLanguage,
          ),
          DropdownRow(
            icon: Icons.palette_outlined,
            label: '主题',
            value: persona.themeMode,
            options: const <String>['浅色', '深色', '跟随系统'],
            onChanged: persona.setThemeMode,
          ),
        ],
      ),
      SettingsSection(
        title: '关于',
        rows: <SettingsRow>[
          const InfoRow(label: '产品', value: 'tangram-agent'),
          const InfoRow(label: '内核', value: 'agent = model + harness'),
          InfoRow(label: '版本', value: config.appVersion ?? kAppVersion),
          const InfoRow(label: '能力', value: '工作蒸馏 · 产出私人模型'),
        ],
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 抓手
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: DshSpace.x8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: c.labelDimmed,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: DshSpace.x6),
            child: Row(
              children: <Widget>[
                const SizedBox(width: DshSpace.x10),
                Expanded(
                  child: Text(
                    '设置',
                    style: DshType.base16m.copyWith(color: c.labelPrimary),
                  ),
                ),
                DshIconButton(
                  icon: Icons.close_rounded,
                  iconSize: 18,
                  tint: c.labelSecondary,
                  tooltip: '关闭',
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
            children: <Widget>[
              if (userProfile != null) ...<Widget>[
                _AccountCard(profile: userProfile!),
                const SizedBox(height: DshSpace.x12),
              ],
              if (config.showWorkspaceSwitcher) ...<Widget>[
                WorkspaceSwitcher(
                  workspaceLabel: userProfile?.workspaceLabel,
                ),
                const SizedBox(height: DshSpace.x12),
              ],
              for (final SettingsSection section in sections) ...<Widget>[
                if (section.title.isNotEmpty) DshGroupLabel(label: section.title),
                DshSettingsCard(
                  radius: DshR.xl,
                  children: section.rows
                      .map(
                        (SettingsRow row) => SettingsRowWidget(
                          row: row,
                          onNavigate: row is NavigationRow ? row.onTap : null,
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: DshSpace.x4),
              ],
              if (config.infoItems.isNotEmpty) ...<Widget>[
                const SizedBox(height: DshSpace.x12),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DshSpace.x4,
                  ),
                  child: Wrap(
                    spacing: DshSpace.x12,
                    runSpacing: DshSpace.x4,
                    children: config.infoItems
                        .map(
                          (InfoItem item) => GestureDetector(
                            onTap: item.onTap,
                            child: Text(
                              item.label,
                              style: DshType.xs13.copyWith(color: c.labelTertiary),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
              if (config.appVersion != null) ...<Widget>[
                const SizedBox(height: DshSpace.x12),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DshSpace.x4,
                  ),
                  child: Text(
                    'v${config.appVersion}',
                    style: DshType.xxs12.copyWith(color: c.labelCaption),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Container(
      decoration: dshFlat(c, radius: DshR.xl),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.brandDimmed,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            clipBehavior: Clip.antiAlias,
            child: profile.avatarUrl != null
                ? Image.network(
                    profile.avatarUrl!,
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                  )
                : Text(
                    profile.initials,
                    style: DshType.s14m.copyWith(color: c.labelPrimary),
                  ),
          ),
          const SizedBox(width: DshSpace.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  profile.name,
                  style: DshType.s14m.copyWith(color: c.labelPrimary),
                ),
                const SizedBox(height: 2),
                const Text(
                  '仅保存在本机 · 无账号体系',
                  style: TextStyle(color: Color(0xFF81858C), fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
