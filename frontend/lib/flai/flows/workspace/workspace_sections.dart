import 'package:flutter/material.dart';

import 'package:tangram/ui/pages/tga_channels_page.dart';
import 'package:tangram/ui/pages/tga_models_page.dart';
import 'package:tangram/ui/pages/tga_persona_page.dart';
import 'package:tangram/ui/pages/tga_plugins_page.dart';
import 'package:tangram/ui/pages/tga_sandbox_page.dart';
import 'package:tangram/ui/pages/tga_sphere_graph_page.dart';
import 'package:tangram/ui/pages/tga_store_page.dart';
import 'package:tangram/ui/pages/tga_training_page.dart';
import 'package:tangram/ui/pages/tga_workspace_page.dart';

import '../sidebar/sidebar_config.dart';

/// 侧边栏工作台入口（设计稿 2026-11-12 全面换版）。
///
/// 全部 9 个入口均为「浅蓝灰底 + 白卡片 + 蓝色分组标题」的新设计稿页面，
/// 自带完整 Scaffold，`fullPage: true` 让侧栏整页 push、不再套旧顶栏。
/// 用户实测反馈 2026-11-13：「设置」「个人」不再作为「更多…」导航条目，
/// 改由侧栏底部左下角「设置」按钮与右下角「个人」chip 直达整页。
/// 真实蒸馏业务逻辑仍保留在 `ui/panels/distill_panel.dart`；新训练设置页
/// 的「保存为云端模型 / 测试 API 连通」按钮预留了 onTap 接入点，接真实
/// 后端时把 onTap 接到原逻辑即可，此处不谎称已连通。
List<NavItem> buildWorkspaceNavItems() => <NavItem>[
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
        icon: Icons.storefront_outlined,
        labelKey: 'sidebar.store',
        page: const TgaStorePage(),
        fullPage: true,
      ),
      NavItem(
        icon: Icons.extension_outlined,
        labelKey: 'sidebar.plugins',
        page: const TgaPluginsPage(),
        fullPage: true,
      ),
      NavItem(
        icon: Icons.folder_outlined,
        labelKey: 'sidebar.workspace',
        page: const TgaWorkspacePage(),
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
        icon: Icons.hub_outlined,
        labelKey: 'sidebar.graph',
        page: const TgaSphereGraphPage(),
        fullPage: true,
      ),
    ];
