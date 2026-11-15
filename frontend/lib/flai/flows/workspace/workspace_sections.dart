import 'package:flutter/material.dart';

import 'package:tangram/ui/pages/tga_3d_page.dart';
import 'package:tangram/ui/pages/tga_channels_page.dart';
import 'package:tangram/ui/pages/tga_models_page.dart';
import 'package:tangram/ui/pages/tga_persona_page.dart';
import 'package:tangram/ui/pages/tga_sandbox_page.dart';
import 'package:tangram/ui/pages/tga_sphere_graph_page.dart';
import 'package:tangram/ui/pages/tga_store_page.dart';
import 'package:tangram/ui/pages/tga_training_page.dart';
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
        icon: Icons.folder_outlined,
        labelKey: 'sidebar.workspace',
        page: const TgaWorkspacePage(),
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
        icon: Icons.hub_outlined,
        labelKey: 'sidebar.graph',
        page: const TgaSphereGraphPage(),
        fullPage: true,
      ),
    ];