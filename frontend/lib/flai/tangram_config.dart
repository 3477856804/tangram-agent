import 'package:flutter/material.dart';

import '../design/dsh_tokens.dart';
import 'app_config.dart';
import 'flows/sidebar/settings_config.dart';
import 'core/theme/tangram_palette.dart';
import 'flows/chat/chat_experience_config.dart';
import 'flows/sidebar/sidebar_config.dart';
import 'flows/workspace/workspace_sections.dart';
import 'providers/ai_provider.dart';
import 'providers/storage_provider.dart';
import 'providers/tangram_auth_provider.dart';
import 'widgets/tangram_surfaces.dart';

/// 主页顶栏「静音」开关（设计稿 2026-11-13：白底圆形按钮，与顶栏其他按钮同构）。
/// 仅本地 UI 态，切换图标；不谎称已关闭系统音量。
class _MuteAction extends StatefulWidget {
  const _MuteAction();
  @override
  State<_MuteAction> createState() => _MuteActionState();
}

class _MuteActionState extends State<_MuteAction> {
  bool _muted = false;
  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Tooltip(
      message: _muted ? '取消静音' : '静音',
      child: InkWell(
        onTap: () => setState(() => _muted = !_muted),
        customBorder: const CircleBorder(),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: c.inputMajor,
            shape: BoxShape.circle,
            boxShadow: dshSoftShadow(blur: 10, lift: 2, alpha: 0.05),
          ),
          alignment: Alignment.center,
          child: Icon(
            _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            size: 18,
            color: c.labelPrimary,
          ),
        ),
      ),
    );
  }
}

AppScaffoldConfig buildTangramConfig({
  required AiProvider aiProvider,
  required StorageProvider storageProvider,
  // 由 main.dart 从后端 model_route{list} 拉取真实模型卡；没有模型就是空列表，
  // 不再预置「我训练的模型 / 本地基底 / API 教师」这类编造条目。
  List<ModelOption> availableModels = const <ModelOption>[],
}) => AppScaffoldConfig(
  authProvider: TangramLocalAuthProvider(),
  aiProvider: aiProvider,
  storageProvider: storageProvider,
  theme: TangramTheme.flaiTheme(),
  // 应用显示名：产品名 tangram-agent 的简称，短到 Android 启动器不会截断。
  // 产品全称仍为 tangram-agent（见「关于」区），版本 0.0.1 冻结不变。
  appTitle: 'TGA',
  showSplash: false,
  onboardingConfig: null,
  chatExperienceConfig: ChatExperienceConfig(
    assistantName: '我的 Agent',
    // 设计稿 2026-11-12：居中问候语改为完整一句。
    greeting: '你好，有什么我能帮你的吗？',
    greetingSubtitle: '',
    composerPlaceholder: '输入消息，/ 查看指令',
    enableGhostMode: true,
    enablePerMessageModelSwitch: true,
    availableModels: availableModels,
  ),
  settingsConfig: const SettingsConfig(
    drawerHeightRatio: 0.62,
    appVersion: '0.0.1',
    sections: <SettingsSection>[
      SettingsSection(
        title: '外观',
        rows: <SettingsRow>[
          InfoRow(label: '主题', value: '在「设置 · 语言与主题」中配置'),
          InfoRow(label: '正文', value: '跟随应用主题'),
        ],
      ),
      SettingsSection(
        title: '关于',
        rows: <SettingsRow>[
          InfoRow(label: '产品', value: 'tangram-agent'),
          InfoRow(label: '内核', value: 'agent = model + harness'),
          InfoRow(label: '版本', value: '0.0.1'),
          InfoRow(label: '能力', value: '工作蒸馏 · 产出私人模型'),
        ],
      ),
    ],
  ),
  sidebarConfig: SidebarConfig(
    appName: 'TGA',
    appLogo: const BrandMark(size: 36),
    navItems: buildWorkspaceNavItems(),
    enableSearch: true,
    // 设计稿 2026-11-12 主页顶栏：菜单 · 静音 · 新对话加号。
    // 菜单与新对话由 HomeScreen 自身渲染，这里补「静音」开关。
    topNavActions: <Widget>[_MuteAction()],
  ),
);
