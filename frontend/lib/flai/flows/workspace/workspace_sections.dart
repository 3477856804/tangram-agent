import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/harness/ui_customization.dart';
import 'package:tangram/ui/pages/tga_3d_page.dart';
import 'package:tangram/ui/pages/tga_account_ops_page.dart';
import 'package:tangram/ui/pages/tga_app_market_page.dart';
import 'package:tangram/ui/pages/tga_channels_page.dart';
import 'package:tangram/ui/pages/tga_cognition_page.dart';
import 'package:tangram/ui/pages/tga_compute_page.dart';
import 'package:tangram/ui/pages/tga_computer_page.dart';
import 'package:tangram/ui/pages/tga_creator_page.dart';
import 'package:tangram/ui/pages/tga_customize_page.dart';
import 'package:tangram/ui/pages/tga_experience_page.dart';
import 'package:tangram/ui/pages/tga_group_chat_page.dart';
import 'package:tangram/ui/pages/tga_knowledge_page.dart';
import 'package:tangram/ui/pages/tga_mapping_page.dart';
import 'package:tangram/ui/pages/tga_image_page.dart';
import 'package:tangram/ui/pages/tga_models_page.dart';
import 'package:tangram/ui/pages/tga_pages_page.dart';
import 'package:tangram/ui/pages/tga_performance_page.dart';
import 'package:tangram/ui/pages/tga_persona_page.dart';
import 'package:tangram/ui/pages/tga_overview_page.dart';
import 'package:tangram/ui/pages/tga_run_page.dart';
import 'package:tangram/ui/pages/tga_sandbox_page.dart';
import 'package:tangram/ui/pages/tga_schedule_page.dart';
import 'package:tangram/ui/pages/tga_security_page.dart';
import 'package:tangram/ui/pages/tga_snapshot_page.dart';
import 'package:tangram/ui/pages/tga_sphere_graph_page.dart';
import 'package:tangram/ui/pages/tga_store_page.dart';
import 'package:tangram/ui/pages/tga_sun_run_page.dart';
import 'package:tangram/ui/pages/tga_team_page.dart';
import 'package:tangram/ui/pages/tga_training_page.dart';
import 'package:tangram/ui/pages/tga_ui_plugins_page.dart';
import 'package:tangram/ui/pages/tga_video_studio_page.dart';
import 'package:tangram/ui/pages/tga_workflow_page.dart';
import 'package:tangram/ui/pages/tga_workspace_page.dart';

import '../sidebar/sidebar_config.dart';

/// 侧边栏工作台入口（设计稿 2026-11-12 全面换版）。
///
/// 全部入口均为「浅蓝灰底 + 白卡片 + 蓝色分组标题」的新设计稿页面，
/// 自带完整 Scaffold，`fullPage: true` 让侧栏整页 push、不再套旧顶栏。
/// 用户实测反馈 2026-11-13：「设置」「个人」不再作为「更多…」导航条目，
/// 改由侧栏底部左下角「设置」按钮与右下角「个人」chip 直达整页。
///
/// 2026-11 架构收敛：**「万物皆插件」内核与 Super Agent 是内置核心**，
/// 随进程常驻、由内嵌后端自动装配，不再作为可点选的选项页/操作页暴露在
/// 导航里（对应 `tga_plugins_page` / `tga_kernel_page` / `tga_super_agent_page`
/// 三个入口已移除，能力仍在 `PluginKernel` / `SuperAgent` 里真实运行）。
/// [visibleKeys] 为空 / 全部未知时回退全部入口：配置损坏也绝不把侧栏清空。
/// 过滤只按 key 保留原声明顺序，NavItem 字段与页面绑定保持不变。
List<NavItem> buildWorkspaceNavItems({Iterable<String>? visibleKeys}) {
  final List<NavItem> all = _allWorkspaceNavItems();
  if (visibleKeys == null) return all;
  final List<String> keys = visibleKeys.toList();
  if (keys.isEmpty) return all;
  final Map<String, NavItem> byKey = <String, NavItem>{
    for (final NavItem item in all) item.labelKey: item,
  };
  // List 输入代表用户拖拽后的明确顺序；Set 输入保持原有声明顺序（测试/旧调用）。
  final List<NavItem> filtered = <NavItem>[];
  if (visibleKeys is List<String>) {
    for (final String key in keys) {
      final NavItem? item = byKey[key];
      if (item != null) filtered.add(item);
    }
  } else {
    for (final NavItem item in all) {
      if (keys.contains(item.labelKey)) filtered.add(item);
    }
  }
  return filtered.isEmpty ? all : filtered;
}

List<NavItem> _allWorkspaceNavItems() => <NavItem>[
  NavItem(
    icon: Icons.dashboard_outlined,
    labelKey: 'sidebar.overview',
    page: const TgaOverviewPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.tune_outlined,
    labelKey: 'sidebar.training',
    page: const TgaTrainingPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.psychology_outlined,
    labelKey: 'sidebar.persona',
    page: const TgaPersonaPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.terminal_outlined,
    labelKey: 'sidebar.sandbox',
    page: const TgaSandboxPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.directions_run_rounded,
    labelKey: 'sidebar.sunRun',
    page: const TgaSunRunPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.storefront_outlined,
    labelKey: 'sidebar.store',
    page: const TgaStorePage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.play_circle_outline_rounded,
    labelKey: 'sidebar.run',
    page: const TgaRunPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.schedule_rounded,
    labelKey: 'sidebar.schedule',
    page: const TgaSchedulePage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.folder_outlined,
    labelKey: 'sidebar.workspace',
    page: const TgaWorkspacePage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.folder_copy_outlined,
    labelKey: 'sidebar.mapping',
    page: const TgaMappingPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.menu_book_outlined,
    labelKey: 'sidebar.knowledge',
    page: const TgaKnowledgePage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.account_tree_outlined,
    labelKey: 'sidebar.workflow',
    page: const TgaWorkflowPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.auto_awesome_mosaic_outlined,
    labelKey: 'sidebar.pages',
    page: const TgaPagesPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.inventory_2_outlined,
    labelKey: 'sidebar.snapshot',
    page: const TgaSnapshotPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.auto_stories_outlined,
    labelKey: 'sidebar.experience',
    page: const TgaExperiencePage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.psychology_alt_outlined,
    labelKey: 'sidebar.cognition',
    page: const TgaCognitionPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.storefront_rounded,
    labelKey: 'sidebar.appMarket',
    page: const TgaAppMarketPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.extension_outlined,
    labelKey: 'sidebar.creator',
    page: const TgaCreatorPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.palette_outlined,
    labelKey: 'sidebar.customize',
    page: const _SharedCustomizePage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.widgets_outlined,
    labelKey: 'sidebar.uiPlugins',
    page: const TgaUiPluginsPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.brush_outlined,
    labelKey: 'sidebar.imageStudio',
    page: const TgaImageStudioPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.movie_filter_outlined,
    labelKey: 'sidebar.videoStudio',
    page: const TgaVideoStudioPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.view_in_ar_outlined,
    labelKey: 'sidebar.model3d',
    page: const Tga3DPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.forum_outlined,
    labelKey: 'sidebar.channels',
    page: const TgaChannelsPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.memory_outlined,
    labelKey: 'sidebar.models',
    page: const TgaModelsPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.speed_rounded,
    labelKey: 'sidebar.compute',
    page: const TgaComputePage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.gpp_good_outlined,
    labelKey: 'sidebar.security',
    page: const TgaSecurityPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.monitor_heart_outlined,
    labelKey: 'sidebar.performance',
    page: const TgaPerformancePage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.forum_rounded,
    labelKey: 'sidebar.groupChat',
    page: const TgaGroupChatPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.groups_2_outlined,
    labelKey: 'sidebar.team',
    page: const TgaTeamPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.desktop_windows_outlined,
    labelKey: 'sidebar.computer',
    page: const TgaComputerPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.alternate_email_rounded,
    labelKey: 'sidebar.accountOps',
    page: const TgaAccountOpsPage(),
    fullPage: true,
  ),
  NavItem(
    icon: Icons.hub_outlined,
    labelKey: 'sidebar.graph',
    page: const TgaSphereGraphPage(),
    fullPage: true,
  ),
];

/// 复用 main.dart 提供的同一个 [UiCustomizationStore]：保存/切换后主题立即生效。
/// 没有 Provider（独立测试或单独复用页面）时回退到页面自行加载，行为不变。
class _SharedCustomizePage extends StatelessWidget {
  const _SharedCustomizePage();

  @override
  Widget build(BuildContext context) {
    UiCustomizationStore? store;
    try {
      store = Provider.of<UiCustomizationStore>(context);
    } on Object {
      store = null;
    }
    return TgaCustomizePage(customization: store);
  }
}
