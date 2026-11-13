import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../design/dsh_tokens.dart';
import '../../../../design/dsh_widgets.dart';
import '../../../../services/persona_store.dart';
import '../../../../ui/i18n/tga_strings.dart';
import '../../../../ui/pages/tga_profile_page.dart';
import '../../../../ui/pages/tga_settings_page.dart';
import '../sidebar_config.dart';
import '../widgets/chat_list_item.dart';

/// 侧栏：dsh 的会话抽屉 —— 品牌字标 · 新会话 · 导航 · 会话列表 · 底部设置。
class FlaiSidebarDrawer extends StatefulWidget {
  final SidebarConfig config;

  final UserProfile? userProfile;

  final List<ConversationItem> starred;

  final List<ConversationItem> recents;

  final String? selectedConversationId;

  const FlaiSidebarDrawer({
    super.key,
    required this.config,
    this.userProfile,
    this.starred = const <ConversationItem>[],
    this.recents = const <ConversationItem>[],
    this.selectedConversationId,
  });

  @override
  State<FlaiSidebarDrawer> createState() => _FlaiSidebarDrawerState();
}

class _FlaiSidebarDrawerState extends State<FlaiSidebarDrawer> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<ConversationItem> _filtered(List<ConversationItem> items) {
    if (_searchQuery.isEmpty) return items;
    final String q = _searchQuery.toLowerCase();
    return items
        .where(
          (ConversationItem item) =>
              item.title.toLowerCase().contains(q) ||
              item.preview.toLowerCase().contains(q),
        )
        .toList();
  }

  void _openSettings(BuildContext context) {
    // 用户实测反馈 2026-11-13：「设置」改整页 push 新版 TgaSettingsPage，
    // 不再打开旧版 showSettingsDrawer 抽屉。
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext _) => const TgaSettingsPage(),
      ),
    );
  }

  void _openNavItem(BuildContext context, NavItem item) {
    final Widget? page = item.page;
    if (page == null) return;
    // 设计稿 2026-11-12：新页面自带完整 Scaffold，整页 push，不再套旧顶栏。
    if (item.fullPage) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (BuildContext _) => page),
      );
      return;
    }
    final String label = context.t(item.labelKey);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) {
          final DshPalette c = DshPalette.of(ctx);
          return Scaffold(
            backgroundColor: c.bgBase,
            body: SafeArea(
              bottom: false,
              child: Column(
                children: <Widget>[
                  DshTopBar(
                    title: label,
                    onBack: () => Navigator.of(ctx).maybePop(),
                  ),
                  Expanded(child: page),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _openAllNav(BuildContext context) {
    final List<NavItem> items = widget.config.navItems;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext ctx) {
          final DshPalette c = DshPalette.of(ctx);
          return Scaffold(
            backgroundColor: c.bgBase,
            body: SafeArea(
              bottom: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  DshTopBar(
                    title: ctx.t('sidebar.more', zh: '更多…'),
                    onBack: () => Navigator.of(ctx).maybePop(),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: DshSpace.x8,
                      ),
                      children: items
                          .map(
                            (NavItem item) => _NavRow(
                              icon: item.icon,
                              label: ctx.t(item.labelKey),
                              onTap: () => _openNavItem(ctx, item),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // PersonaStore.language 驱动 MaterialApp.locale：watch 保证切语言时
    // 整个抽屉即时重建（context.t 亦会注册 Localizations 依赖）。
    context.watch<PersonaStore>();
    final DshPalette c = DshPalette.of(context);
    final List<ConversationItem> starred = _filtered(widget.starred);
    final List<ConversationItem> recents = _filtered(widget.recents);

    return Drawer(
      width: 300,
      backgroundColor: c.sidebar,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(DshR.xl)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // 品牌字标
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DshSpace.x16,
                DshSpace.x12,
                DshSpace.x6,
                DshSpace.x8,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: DshWordmark(
                      glyphSize: 32,
                      title: widget.config.appName,
                      suffix: 'TANGRAM',
                      titleSize: 17,
                    ),
                  ),
                  DshIconButton(
                    icon: Icons.vertical_split_rounded,
                    iconSize: 18,
                    tint: c.labelSecondary,
                    tooltip: context.t('sidebar.collapse', zh: '收起'),
                    onTap: () => Scaffold.maybeOf(context)?.closeDrawer(),
                  ),
                ],
              ),
            ),

            // 新会话
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DshSpace.x12),
              child: _DrawerButton(
                icon: Icons.add_circle_outline_rounded,
                label: context.t('sidebar.newChat', zh: '新会话'),
                onTap: () {
                  widget.config.onNewChat?.call();
                  Scaffold.maybeOf(context)?.closeDrawer();
                },
              ),
            ),

            // 导航项（最多 4 条，其余收进“全部工作台”，保证会话列表始终可见）
            if (widget.config.navItems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: DshSpace.x8),
                child: Column(
                  children: <Widget>[
                    ...widget.config.navItems
                        .take(4)
                        .map(
                          (NavItem item) => _NavRow(
                            icon: item.icon,
                            label: context.t(item.labelKey),
                            onTap: () => _openNavItem(context, item),
                          ),
                        ),
                    if (widget.config.navItems.length > 4)
                      _NavRow(
                        icon: Icons.apps_rounded,
                        label: context.t('sidebar.more', zh: '更多…'),
                        onTap: () => _openAllNav(context),
                      ),
                  ],
                ),
              ),

            // 会话列表头
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DshSpace.x16,
                DshSpace.x12,
                DshSpace.x6,
                DshSpace.x4,
              ),
              child: Row(
                children: <Widget>[
                  Text(
                    context.t('sidebar.conversations', zh: '会话'),
                    style: DshType.xs13m.copyWith(color: c.labelTertiary),
                  ),
                  const Spacer(),
                  if (widget.config.enableSearch)
                    DshIconButton(
                      icon: Icons.search_rounded,
                      size: 32,
                      iconSize: 17,
                      tint: c.labelTertiary,
                      onTap: () => setState(() => _searching = !_searching),
                      tooltip: context.t('sidebar.search', zh: '搜索会话'),
                    ),
                ],
              ),
            ),
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  DshSpace.x12,
                  0,
                  DshSpace.x12,
                  DshSpace.x8,
                ),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: DshSpace.x10),
                  decoration: BoxDecoration(
                    color: c.bgModule,
                    borderRadius: BorderRadius.circular(DshR.md),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.search_rounded,
                        size: 15,
                        color: c.labelTertiary,
                      ),
                      const SizedBox(width: DshSpace.x6),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          autofocus: true,
                          onChanged: (String v) =>
                              setState(() => _searchQuery = v.trim()),
                          style: DshType.s14.copyWith(color: c.labelPrimary),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText:
                                context.t('sidebar.search', zh: '搜索会话'),
                            hintStyle: DshType.s14.copyWith(
                              color: c.labelCaption,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(
                  left: DshSpace.x6,
                  right: DshSpace.x6,
                  bottom: DshSpace.x8,
                ),
                children: <Widget>[
                  if (starred.isNotEmpty) ...<Widget>[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        DshSpace.x10,
                        DshSpace.x6,
                        DshSpace.x10,
                        DshSpace.x2,
                      ),
                      child: Text(
                        context.t('sidebar.starred', zh: '已收藏'),
                        style: DshType.xxxs11m.copyWith(
                          color: c.labelTertiary,
                        ),
                      ),
                    ),
                    ...starred.map((ConversationItem item) => _item(item)),
                  ],
                  ...recents.map((ConversationItem item) => _item(item)),
                  if (starred.isEmpty && recents.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(DshSpace.x16),
                      child: Text(
                        _searchQuery.isEmpty
                            ? context.t('sidebar.empty', zh: '还没有会话')
                            : context
                                .t('sidebar.noMatch',
                                    zh: '没有匹配“{q}”的会话')
                                .replaceAll('{q}', _searchQuery),
                        textAlign: TextAlign.center,
                        style: DshType.xs13.copyWith(color: c.labelTertiary),
                      ),
                    ),
                ],
              ),
            ),

            DshDivider(color: c.borderL2),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                DshSpace.x12,
                DshSpace.x8,
                DshSpace.x12,
                DshSpace.x8,
              ),
              child: Row(
                children: <Widget>[
                  InkWell(
                    onTap: () => _openSettings(context),
                    borderRadius: BorderRadius.circular(DshR.sm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: DshSpace.x4,
                        vertical: DshSpace.x6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.settings_outlined,
                            size: 18,
                            color: c.labelSecondary,
                          ),
                          const SizedBox(width: DshSpace.x6),
                          Text(
                            context.t('sidebar.settings', zh: '设置'),
                            style: DshType.s14.copyWith(
                              color: c.labelPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  _account(context, c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(ConversationItem item) {
    return ChatListItem(
      item: item,
      isSelected: item.id == widget.selectedConversationId,
      onTap: () {
        widget.config.onConversationTap?.call(item);
        Scaffold.maybeOf(context)?.closeDrawer();
      },
      onStar: () => widget.config.onConversationStar?.call(item),
      onRename: () => widget.config.onConversationRename?.call(item),
      onShare: () => widget.config.onConversationShare?.call(item),
      onDelete: () => widget.config.onConversationDelete?.call(item),
    );
  }

  Widget _account(BuildContext context, DshPalette c) {
    // 用户实测反馈 2026-11-13：「个人」入口整页 push 新版 TgaProfilePage，
    // 不再打开旧版身份设置面板。
    final String name = context.watch<PersonaStore>().displayName;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => const TgaProfilePage(),
        ),
      ),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: DshSpace.x8,
          vertical: 4,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.borderL3, width: dshHairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.person_outline, size: 16, color: c.labelSecondary),
            const SizedBox(width: DshSpace.x6),
            Text(
              name.isEmpty
                  ? context.t('sidebar.profile', zh: '个人')
                  : name,
              style: DshType.xs13.copyWith(color: c.labelPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerButton extends StatelessWidget {
  const _DrawerButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshR.md),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: c.brandDimmed,
            borderRadius: BorderRadius.circular(DshR.md),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(icon, size: 16, color: c.labelPrimary),
              const SizedBox(width: DshSpace.x6),
              Text(
                label,
                style: DshType.s14m.copyWith(color: c.labelPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DshR.md),
        child: Container(
          height: 42,
          margin: const EdgeInsets.symmetric(horizontal: DshSpace.x6),
          padding: const EdgeInsets.symmetric(horizontal: DshSpace.x10),
          child: Row(
            children: <Widget>[
              Icon(icon, size: 18, color: c.labelSecondary),
              const SizedBox(width: DshSpace.x10),
              Expanded(
                child: Text(
                  label,
                  style: DshType.s14.copyWith(color: c.labelPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: c.labelCaption,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
