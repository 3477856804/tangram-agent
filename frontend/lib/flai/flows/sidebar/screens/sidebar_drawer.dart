import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../../design/dsh_tokens.dart';
import '../../../../design/dsh_widgets.dart';
import '../../../../harness/ui_customization.dart';
import '../../../../services/persona_store.dart';
import '../../../../ui/i18n/tga_strings.dart';
import '../../../../ui/pages/tga_profile_page.dart';
import '../../../../ui/pages/tga_settings_page.dart';
import '../sidebar_config.dart';
import '../widgets/chat_list_item.dart';

/// i18n 词典尚未收录的新导航 key 的中文兜底（显示为可读文案而不是裸 key）。
const Map<String, String> _navFallbackZh = <String, String>{
  'sidebar.uiPlugins': 'UI 插件槽',
};

/// 侧栏导航的业务分组。顺序即渲染顺序；未知 labelKey 回落到系统组，
/// 保证以后新增入口不会因为没登记分组而消失。
enum _NavGroup {
  reports('sidebar.group.reports', '报告与真实'),
  creation('sidebar.group.creation', '创作'),
  collaboration('sidebar.group.collaboration', '协作'),
  system('sidebar.group.system', '系统');

  const _NavGroup(this.labelKey, this.zh);

  final String labelKey;
  final String zh;
}

/// 现有导航项 → 业务分组（以 labelKey 为准，顺序保持 workspace_sections 的声明顺序）。
const Map<String, _NavGroup> _navGroupByLabelKey = <String, _NavGroup>{
  'sidebar.overview': _NavGroup.reports,
  'sidebar.knowledge': _NavGroup.reports,
  'sidebar.graph': _NavGroup.reports,
  'sidebar.snapshot': _NavGroup.reports,
  'sidebar.experience': _NavGroup.reports,
  'sidebar.cognition': _NavGroup.reports,
  'sidebar.workspace': _NavGroup.creation,
  'sidebar.mapping': _NavGroup.creation,
  'sidebar.model3d': _NavGroup.creation,
  'sidebar.store': _NavGroup.creation,
  'sidebar.appMarket': _NavGroup.creation,
  'sidebar.creator': _NavGroup.creation,
  'sidebar.customize': _NavGroup.creation,
  'sidebar.uiPlugins': _NavGroup.creation,
  'sidebar.imageStudio': _NavGroup.creation,
  'sidebar.videoStudio': _NavGroup.creation,
  'sidebar.groupChat': _NavGroup.collaboration,
  'sidebar.team': _NavGroup.collaboration,
  'sidebar.computer': _NavGroup.collaboration,
  'sidebar.channels': _NavGroup.collaboration,
  'sidebar.accountOps': _NavGroup.collaboration,
  'sidebar.training': _NavGroup.system,
  'sidebar.persona': _NavGroup.system,
  'sidebar.sandbox': _NavGroup.system,
  'sidebar.workflow': _NavGroup.system,
  'sidebar.pages': _NavGroup.creation,
  'sidebar.models': _NavGroup.system,
  'sidebar.run': _NavGroup.system,
  'sidebar.schedule': _NavGroup.system,
  'sidebar.compute': _NavGroup.system,
  'sidebar.security': _NavGroup.system,
  'sidebar.performance': _NavGroup.system,
};

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

  /// labelKey 未登记时按页面类型兜底，未来新增入口也能落到稳定分组。
  _NavGroup _groupOf(NavItem item) {
    final _NavGroup? mapped = _navGroupByLabelKey[item.labelKey];
    if (mapped != null) return mapped;
    final String type = item.page.runtimeType.toString().toLowerCase();
    if (type.contains('knowledge') ||
        type.contains('graph') ||
        type.contains('snapshot') ||
        type.contains('report')) {
      return _NavGroup.reports;
    }
    if (type.contains('team') ||
        type.contains('groupchat') ||
        type.contains('channel') ||
        type.contains('collab')) {
      return _NavGroup.collaboration;
    }
    if (type.contains('studio') ||
        type.contains('store') ||
        type.contains('market') ||
        type.contains('workspace') ||
        type.contains('training') ||
        type.contains('persona')) {
      return _NavGroup.creation;
    }
    return _NavGroup.system;
  }

  /// 分组后仍保持原 navItems 的声明顺序（组内顺序不变）。
  Map<_NavGroup, List<NavItem>> _groupedNavItems() {
    final Map<_NavGroup, List<NavItem>> grouped = <_NavGroup, List<NavItem>>{};
    for (final NavItem item in widget.config.navItems) {
      grouped.putIfAbsent(_groupOf(item), () => <NavItem>[]).add(item);
    }
    return grouped;
  }

  /// UI 自定义仓库可能不存在（独立测试 / 单独复用抽屉）：缺失时保持原有分组形态。
  UiCustomizationStore? _uiCustomizationOf(BuildContext context) {
    try {
      return Provider.of<UiCustomizationStore>(context);
    } on Object {
      return null;
    }
  }

  String _labelOf(BuildContext context, NavItem item) =>
      context.t(item.labelKey, zh: _navFallbackZh[item.labelKey]);

  /// sidebarGrouping=false → 平铺；true → 现有业务分组。
  /// 可见性过滤已在 config 层（visibleNavKeys）完成，这里绝不二次过滤。
  List<Widget> _buildNavList(
    BuildContext context,
    DshPalette c, {
    required bool grouped,
  }) {
    if (!grouped) {
      return widget.config.navItems
          .map(
            (NavItem item) => _NavRow(
              icon: item.icon,
              label: _labelOf(context, item),
              onTap: () => _openNavItem(context, item),
            ),
          )
          .toList();
    }
    return _buildNavGroups(context, c);
  }

  List<Widget> _buildNavGroups(BuildContext context, DshPalette c) {
    final Map<_NavGroup, List<NavItem>> grouped = _groupedNavItems();
    final List<Widget> children = <Widget>[];
    for (final _NavGroup group in _NavGroup.values) {
      final List<NavItem>? items = grouped[group];
      if (items == null || items.isEmpty) continue;
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            DshSpace.x12,
            DshSpace.x8,
            DshSpace.x12,
            DshSpace.x2,
          ),
          child: Semantics(
            header: true,
            child: Text(
              context.t(group.labelKey, zh: group.zh),
              style: DshType.xxxs11m.copyWith(
                color: c.labelTertiary,
                letterSpacing: 0.4,
              ),
            ),
          ),
        ),
      );
      children.addAll(
        items.map(
          (NavItem item) => _NavRow(
            icon: item.icon,
            label: _labelOf(context, item),
            onTap: () => _openNavItem(context, item),
          ),
        ),
      );
    }
    return children;
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
      Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (BuildContext _) => page));
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

  @override
  Widget build(BuildContext context) {
    // PersonaStore.language 驱动 MaterialApp.locale：watch 保证切语言时
    // 整个抽屉即时重建（context.t 亦会注册 Localizations 依赖）。
    context.watch<PersonaStore>();
    // UI 自定义：只有显式关闭分组时才平铺；仓库缺失时保持既有分组形态。
    // 取已保存的当前作用域配置，未保存的草稿不改变侧栏结构。
    final UiCustomizationStore? uiStore = _uiCustomizationOf(context);
    final bool grouped = uiStore?.apply(uiStore.scope).sidebarGrouping ?? true;
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

            // 导航项按业务分组，限高滚动：小屏也不把会话列表挤掉，
            // 同时保证 12+ 个入口全部可达（不再截断成「更多…」）。
            if (widget.config.navItems.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: DshSpace.x4),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: (MediaQuery.sizeOf(context).height * 0.32).clamp(
                      96.0,
                      240.0,
                    ),
                  ),
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: DshSpace.x4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _buildNavList(context, c, grouped: grouped),
                      ),
                    ),
                  ),
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
                      onTap: () => setState(() {
                        _searching = !_searching;
                        // 收起搜索时同步清空过滤词，避免列表被隐藏条件继续筛掉。
                        if (!_searching) {
                          _searchController.clear();
                          _searchQuery = '';
                        }
                      }),
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
                            hintText: context.t('sidebar.search', zh: '搜索会话'),
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
                        style: DshType.xxxs11m.copyWith(color: c.labelTertiary),
                      ),
                    ),
                    ...starred.map((ConversationItem item) => _item(item)),
                  ],
                  ...recents.map((ConversationItem item) => _item(item)),
                  if (starred.isEmpty && recents.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        DshSpace.x16,
                        DshSpace.x24,
                        DshSpace.x16,
                        DshSpace.x16,
                      ),
                      child: Column(
                        children: <Widget>[
                          Icon(
                            _searchQuery.isEmpty
                                ? Icons.forum_outlined
                                : Icons.search_off_rounded,
                            size: 28,
                            color: c.labelCaption,
                          ),
                          const SizedBox(height: DshSpace.x8),
                          Text(
                            _searchQuery.isEmpty
                                ? context.t('sidebar.empty', zh: '还没有会话')
                                : context
                                      .t('sidebar.noMatch', zh: '没有匹配“{q}”的会话')
                                      .replaceAll('{q}', _searchQuery),
                            textAlign: TextAlign.center,
                            style: DshType.xs13.copyWith(
                              color: c.labelTertiary,
                            ),
                          ),
                          if (_searchQuery.isNotEmpty) ...<Widget>[
                            const SizedBox(height: DshSpace.x4),
                            Semantics(
                              button: true,
                              label: context.t(
                                'sidebar.clearSearch',
                                zh: '清除搜索',
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(DshR.sm),
                                onTap: () {
                                  _searchController.clear();
                                  setState(() => _searchQuery = '');
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: DshSpace.x10,
                                    vertical: DshSpace.x6,
                                  ),
                                  child: Text(
                                    context.t(
                                      'sidebar.clearSearch',
                                      zh: '清除搜索',
                                    ),
                                    style: DshType.xs13m.copyWith(
                                      color: c.link,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
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
                            style: DshType.s14.copyWith(color: c.labelPrimary),
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
              name.isEmpty ? context.t('sidebar.profile', zh: '个人') : name,
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
    return Semantics(
      button: true,
      label: label,
      child: Material(
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
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Semantics(
      button: true,
      label: label,
      child: Material(
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
      ),
    );
  }
}
