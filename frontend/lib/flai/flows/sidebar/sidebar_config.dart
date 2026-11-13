import 'package:flutter/widgets.dart';

import 'settings_config.dart';

class NavItem {
  final IconData icon;

  /// i18n 词典 key（sidebar.*）。侧栏在 build 时用 `context.t(labelKey)`
  /// 运行时解析，语言切换即时刷新，不再持有构造期中文常量。
  final String labelKey;

  final Widget? page;

  /// 设计稿 2026-11-12：新页面自带完整 Scaffold + 浅蓝灰 AppBar。
  /// 为 true 时侧栏直接整页 push，不再套旧的 DshTopBar（避免双标题栏）。
  final bool fullPage;

  const NavItem({
    required this.icon,
    required this.labelKey,
    this.page,
    this.fullPage = false,
  });
}

class UserProfile {
  final String name;

  final String email;

  final String? avatarUrl;

  final String initials;

  final String? workspaceLabel;

  const UserProfile({
    required this.name,
    required this.email,
    this.avatarUrl,
    required this.initials,
    this.workspaceLabel,
  });
}

class ConversationItem {
  final String id;

  final String title;

  final String preview;

  final DateTime timestamp;

  final bool isStarred;

  final int unreadCount;

  const ConversationItem({
    required this.id,
    required this.title,
    required this.preview,
    required this.timestamp,
    this.isStarred = false,
    this.unreadCount = 0,
  });

  ConversationItem copyWith({
    String? id,
    String? title,
    String? preview,
    DateTime? timestamp,
    bool? isStarred,
    int? unreadCount,
  }) {
    return ConversationItem(
      id: id ?? this.id,
      title: title ?? this.title,
      preview: preview ?? this.preview,
      timestamp: timestamp ?? this.timestamp,
      isStarred: isStarred ?? this.isStarred,
      unreadCount: unreadCount ?? this.unreadCount,
    );
  }
}

class SidebarConfig {
  final String appName;

  final Widget? appLogo;

  final List<NavItem> navItems;

  final bool enableSearch;

  final List<Widget> topNavActions;

  final SettingsConfig? settingsConfig;

  final VoidCallback? onNewChat;

  final void Function(ConversationItem)? onConversationTap;

  final void Function(ConversationItem)? onConversationStar;

  final void Function(ConversationItem)? onConversationRename;

  final void Function(ConversationItem)? onConversationShare;

  final void Function(ConversationItem)? onConversationDelete;

  const SidebarConfig({
    required this.appName,
    this.appLogo,
    this.navItems = const [],
    this.enableSearch = false,
    this.topNavActions = const [],
    this.settingsConfig,
    this.onNewChat,
    this.onConversationTap,
    this.onConversationStar,
    this.onConversationRename,
    this.onConversationShare,
    this.onConversationDelete,
  });
}
