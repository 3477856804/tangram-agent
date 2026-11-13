import 'package:flutter/material.dart';

import '../../design/dsh_tokens.dart';
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

  /// 顶栏标题：当前会话的标题（对齐 dsh 的 "会话名"）。
  String _activeTitle() {
    final String? id = widget.activeConversationId;
    if (id == null) return widget.sidebarConfig.appName;
    for (final ConversationItem item in widget.conversations) {
      if (item.id == id && item.title.trim().isNotEmpty) return item.title;
    }
    return widget.sidebarConfig.appName;
  }

  Widget _composer(BuildContext context) {
    final FlaiVoiceController? vc = _voiceController;
    return FlaiComposerV2(
      config: widget.chatExperienceConfig,
      onSend: widget.onSendMessage ?? ((_, __, ___) {}),
      isRecording: vc?.isRecording ?? false,
      isTranscribing: vc?.isTranscribing ?? false,
      voiceTranscript: vc?.lastTranscript,
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
                        tooltip: '会话',
                        onTap: () => _scaffoldKey.currentState?.openDrawer(),
                      ),
                      const SizedBox(width: DshSpace.x4),
                      Expanded(
                        child: Text(
                          hasActiveChat ? _activeTitle() : '',
                          style: DshType.s14m.copyWith(color: c.labelPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      ...effectiveConfig.topNavActions,
                      const SizedBox(width: DshSpace.x6),
                      if (widget.onNewChat != null)
                        _CircleButton(
                          icon: Icons.add_rounded,
                          iconSize: 20,
                          tooltip: '新会话',
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
  });

  final IconData icon;
  final VoidCallback onTap;
  final double iconSize;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final Widget button = InkWell(
      onTap: onTap,
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
        child: Icon(icon, size: iconSize, color: c.labelPrimary),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
