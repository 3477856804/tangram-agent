import 'package:flutter/material.dart';

import '../../design/dsh_motion.dart';
import '../../design/dsh_tokens.dart';
import '../../services/presence_store.dart';
import '../../ui/i18n/tga_strings.dart';
import '../../ui/panels/presence_sheet.dart';
import '../flows/chat/chat_experience_config.dart';
import '../flows/chat/screens/empty_chat_state.dart';
import '../flows/chat/voice_controller.dart';
import '../flows/chat/widgets/composer_v2.dart';
import '../flows/sidebar/screens/sidebar_drawer.dart';
import '../flows/sidebar/settings_config.dart';
import '../flows/sidebar/sidebar_config.dart';
import '../providers.dart';

class FlaiHomeScreen extends StatefulWidget {
  final SidebarConfig sidebarConfig;

  final ChatExperienceConfig chatExperienceConfig;

  final SettingsConfig settingsConfig;

  final UserProfile? userProfile;

  final List<ConversationItem> conversations;

  final List<ConversationItem> starredConversations;

  final String? activeConversationId;

  final Widget? chatContent;

  /// 发送回调：文本 + 深度思考 / 智能搜索开关（见 composer_v2 的 FlaiSendHandler）。
  final FlaiSendHandler? onSendMessage;

  final VoidCallback? onNewChat;

  final void Function(ConversationItem)? onConversationTap;

  final VoidCallback? onOpenSettings;

  /// 打开「在场状态」底部弹窗的回调，由主流程注入。
  /// 为空时不渲染模式按钮，页面本身不直接依赖 Provider。
  final VoidCallback? onPresenceTap;

  /// 当前场景模式，仅用于切换顶栏按钮图标；由主流程随 PresenceStore 更新。
  final PresenceMode? presenceMode;

  const FlaiHomeScreen({
    super.key,
    required this.sidebarConfig,
    required this.chatExperienceConfig,
    required this.settingsConfig,
    this.userProfile,
    this.conversations = const [],
    this.starredConversations = const [],
    this.activeConversationId,
    this.chatContent,
    this.onSendMessage,
    this.onNewChat,
    this.onConversationTap,
    this.onOpenSettings,
    this.onPresenceTap,
    this.presenceMode,
  });

  @override
  State<FlaiHomeScreen> createState() => _FlaiHomeScreenState();
}

class _FlaiHomeScreenState extends State<FlaiHomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  FlaiVoiceController? _voiceController;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _initVoiceController();
  }

  void _initVoiceController() {
    if (_voiceController != null) return;
    if (!widget.chatExperienceConfig.enableVoice) return;

    final voiceProvider = FlaiProviders.of(context).voiceProvider;
    if (voiceProvider == null) return;

    _voiceController = FlaiVoiceController(
      provider: voiceProvider,
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      },
    )..addListener(_onVoiceStateChanged);
  }

  void _onVoiceStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _voiceController?.removeListener(_onVoiceStateChanged);
    _voiceController?.dispose();
    super.dispose();
  }

  SidebarConfig get _effectiveSidebarConfig {
    return SidebarConfig(
      appName: widget.sidebarConfig.appName,
      appLogo: widget.sidebarConfig.appLogo,
      navItems: widget.sidebarConfig.navItems,
      enableSearch: widget.sidebarConfig.enableSearch,
      topNavActions: widget.sidebarConfig.topNavActions,
      settingsConfig: widget.settingsConfig,
      onNewChat: widget.onNewChat ?? widget.sidebarConfig.onNewChat,
      onConversationTap:
          widget.onConversationTap ?? widget.sidebarConfig.onConversationTap,
      onConversationStar: widget.sidebarConfig.onConversationStar,
      onConversationRename: widget.sidebarConfig.onConversationRename,
      onConversationShare: widget.sidebarConfig.onConversationShare,
      onConversationDelete: widget.sidebarConfig.onConversationDelete,
    );
  }

  /// 顶栏标题：当前会话的标题；空会话时展示产品名，避免标题区留白。
  String _activeTitle() {
    final String appName = widget.sidebarConfig.appName.trim().isEmpty
        ? 'TGA'
        : widget.sidebarConfig.appName.trim();
    final String? id = widget.activeConversationId;
    if (id == null) return appName;
    for (final ConversationItem item in widget.conversations) {
      if (item.id == id && item.title.trim().isNotEmpty) return item.title;
    }
    return appName;
  }

  Widget _composer(BuildContext context) {
    final FlaiVoiceController? vc = _voiceController;
    return FlaiComposerV2(
      config: widget.chatExperienceConfig,
      onSend: widget.onSendMessage ?? ((_, __, ___) {}),
      isRecording: vc?.isRecording ?? false,
      isTranscribing: vc?.isTranscribing ?? false,
      voiceTranscript: vc?.lastTranscript,
      voiceTranscriptSeq: vc?.transcriptSeq ?? 0,
      amplitude: vc?.amplitude,
      onVoiceStart: vc != null ? () => vc.startRecording() : null,
      onVoiceStop: vc != null ? () => vc.stopRecording() : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final SidebarConfig effectiveConfig = _effectiveSidebarConfig;
    final bool hasActiveChat = widget.chatContent != null;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bgBase,
      drawerScrimColor: c.scrim,
      drawer: FlaiSidebarDrawer(
        config: effectiveConfig,
        userProfile: widget.userProfile,
        starred: widget.starredConversations,
        recents: widget.conversations,
        selectedConversationId: widget.activeConversationId,
      ),
      body: SafeArea(
        bottom: false,
        child: Container(
          color: c.bgBase,
          child: Column(
            children: <Widget>[
              // 顶栏（设计稿 2026-11-13）：白底圆形按钮 —— 菜单 · 标题 · 静音 · 新会话。
              SizedBox(
                height: 56,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: DshSpace.x12),
                  child: Row(
                    children: <Widget>[
                      _CircleButton(
                        icon: Icons.menu_rounded,
                        tooltip: context.t('sidebar.openDrawer', zh: '打开侧边栏'),
                        semanticsLabel: context.t(
                          'sidebar.openDrawer',
                          zh: '打开侧边栏',
                        ),
                        onTap: () => _scaffoldKey.currentState?.openDrawer(),
                      ),
                      const SizedBox(width: DshSpace.x4),
                      Expanded(
                        child: Semantics(
                          header: true,
                          // 切换会话时标题淡入淡出，而不是硬生生换字。
                          child: AnimatedSwitcher(
                            duration: DshMotion.fast,
                            switchInCurve: DshMotion.standard,
                            layoutBuilder:
                                (
                                  Widget? currentChild,
                                  List<Widget> previousChildren,
                                ) {
                                  return Stack(
                                    alignment: Alignment.centerLeft,
                                    children: <Widget>[
                                      ...previousChildren,
                                      if (currentChild != null) currentChild,
                                    ],
                                  );
                                },
                            child: Text(
                              _activeTitle(),
                              key: ValueKey<String>(_activeTitle()),
                              style: DshType.s14m.copyWith(
                                color: c.labelPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                      ...effectiveConfig.topNavActions,
                      if (widget.onPresenceTap != null) ...<Widget>[
                        const SizedBox(width: DshSpace.x6),
                        _CircleButton(
                          icon: presenceModeIcon(
                            widget.presenceMode ?? PresenceMode.chat,
                          ),
                          iconSize: 19,
                          tooltip: context.t('presence.open', zh: '在场状态'),
                          semanticsLabel: context.t(
                            'presence.open',
                            zh: '在场状态',
                          ),
                          onTap: widget.onPresenceTap!,
                        ),
                      ],
                      const SizedBox(width: DshSpace.x6),
                      if (widget.onNewChat != null)
                        _CircleButton(
                          icon: Icons.add_rounded,
                          iconSize: 20,
                          tooltip: context.t('sidebar.newChat', zh: '新会话'),
                          semanticsLabel: context.t(
                            'sidebar.newChat',
                            zh: '新会话',
                          ),
                          onTap: widget.onNewChat!,
                        ),
                    ],
                  ),
                ),
              ),
              if (hasActiveChat) ...<Widget>[
                Expanded(child: widget.chatContent!),
              ] else
                Expanded(
                  // 设计稿 2026-11-13：logo + 问候语在剩余空间居中，
                  // 输入区固定在屏幕底部。
                  child: Column(
                    children: <Widget>[
                      Expanded(
                        child: FlaiEmptyChatState(
                          config: widget.chatExperienceConfig,
                          // 空态快捷指令无开关语义，固定 false/false。
                          onSuggestion: widget.onSendMessage == null
                              ? null
                              : (String text) =>
                                    widget.onSendMessage!(text, false, false),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          DshSpace.x8,
                          0,
                          DshSpace.x8,
                          MediaQuery.paddingOf(context).bottom + DshSpace.x10,
                        ),
                        child: _composer(context),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶栏白底圆形图标按钮（设计稿 2026-11-13）：极淡投影，浮在蓝灰底上。
class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.iconSize = 18,
    this.tooltip,
    this.semanticsLabel,
  });

  final IconData icon;
  final VoidCallback onTap;
  final double iconSize;
  final String? tooltip;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return DshPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      tooltip: tooltip,
      semanticsLabel: semanticsLabel ?? tooltip,
      haptic: true,
      child: Container(
        // 统一 40dp 点击区，避免不同图标按钮热区大小不一。
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: c.inputMajor,
          shape: BoxShape.circle,
          border: Border.all(color: c.borderL1, width: 0.6),
          // 主题自适应的双层投影：深色模式下也看得见按钮的抬升。
          boxShadow: dshLayeredShadow(c, blur: 12, lift: 2, alpha: 0.05),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: iconSize, color: c.labelPrimary),
      ),
    );
  }
}
