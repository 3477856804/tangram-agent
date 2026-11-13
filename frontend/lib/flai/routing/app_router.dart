import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app_config.dart';
import '../providers/auth_provider.dart';
import '../flows/auth/auth_flow.dart';
import '../flows/chat/chat_experience_config.dart';
import '../flows/onboarding/onboarding_flow.dart';
import '../flows/sidebar/settings_config.dart';
import '../flows/sidebar/sidebar_config.dart';
import '../providers.dart';
import '../screens/chat_content.dart';
import '../screens/home_controller.dart';
import '../screens/home_screen.dart';

abstract final class AppRoutes {
  static const splash = 'splash';

  static const auth = 'auth';

  static const onboarding = 'onboarding';

  static const home = 'home';
}

abstract final class AppPaths {
  static const splash = '/splash';

  static const auth = '/auth';

  static const onboarding = '/onboarding';

  static const home = '/';
}

GoRouter createAppRouter({required AppScaffoldConfig config}) {
  return GoRouter(
    initialLocation:
        config.showSplash ? AppPaths.splash : AppPaths.auth,
    refreshListenable: _AuthStateNotifier(config.authProvider),
    redirect: (context, state) {
      final user = config.authProvider.currentUser;
      final location = state.matchedLocation;

      final isAuthRoute = location == AppPaths.auth;
      final isSplashRoute = location == AppPaths.splash;
      final isOnboardingRoute = location == AppPaths.onboarding;

      if (user == null && !isAuthRoute && !isSplashRoute) {
        return AppPaths.auth;
      }

      if (user != null && (isAuthRoute || isSplashRoute)) {
        if (config.onboardingConfig != null && !isOnboardingRoute) {
          return AppPaths.onboarding;
        }
        return AppPaths.home;
      }

      return null;
    },
    routes: [
      GoRoute(
        path: AppPaths.splash,
        name: AppRoutes.splash,
        builder: (context, state) => FlaiSplashScreen(
          logo: config.onboardingConfig?.splashLogo,
          onReady: () => GoRouter.of(context).go(AppPaths.auth),
        ),
      ),

      GoRoute(
        path: AppPaths.auth,
        name: AppRoutes.auth,
        builder: (context, state) => _AuthFlowPage(config: config),
      ),

      GoRoute(
        path: AppPaths.onboarding,
        name: AppRoutes.onboarding,
        builder: (context, state) =>
            _OnboardingFlowPage(config: config),
      ),

      GoRoute(
        path: AppPaths.home,
        name: AppRoutes.home,
        builder: (context, state) => _WiredHomePage(config: config),
      ),
    ],
  );
}


class _AuthFlowPage extends StatefulWidget {
  const _AuthFlowPage({required this.config});

  final AppScaffoldConfig config;

  @override
  State<_AuthFlowPage> createState() => _AuthFlowPageState();
}

class _AuthFlowPageState extends State<_AuthFlowPage> {
  late final AuthController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AuthController(
      provider: widget.config.authProvider,
      config: widget.config.authFlowConfig,
      onAuthenticated: (user) {
        if (widget.config.onboardingConfig != null) {
          context.go(AppPaths.onboarding);
        } else {
          context.go(AppPaths.home);
        }
      },
      onGuestContinue: () => context.go(AppPaths.home),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return switch (_controller.currentScreen) {
          AuthScreen.loginLanding =>
            FlaiLoginLanding(controller: _controller),
          AuthScreen.emailEntry =>
            FlaiEmailEntry(controller: _controller),
          AuthScreen.passwordEntry =>
            FlaiPasswordEntry(controller: _controller),
          AuthScreen.forgotPassword =>
            FlaiForgotPassword(controller: _controller),
          AuthScreen.verificationCode =>
            FlaiVerificationCode(controller: _controller),
          AuthScreen.resetPassword =>
            FlaiResetPassword(controller: _controller),
        };
      },
    );
  }
}


class _OnboardingFlowPage extends StatefulWidget {
  const _OnboardingFlowPage({required this.config});

  final AppScaffoldConfig config;

  @override
  State<_OnboardingFlowPage> createState() => _OnboardingFlowPageState();
}

class _OnboardingFlowPageState extends State<_OnboardingFlowPage> {
  late final OnboardingController _controller;

  @override
  void initState() {
    super.initState();
    final onboardingConfig = widget.config.onboardingConfig!;
    _controller = OnboardingController(
      config: OnboardingConfig(
        splashLogo: onboardingConfig.splashLogo,
        steps: onboardingConfig.steps,
        revealLogo: onboardingConfig.revealLogo,
        revealGradient: onboardingConfig.revealGradient,
        onComplete: (result) {
          onboardingConfig.onComplete(result);
          if (context.mounted) context.go(AppPaths.home);
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final step = _controller.currentStep;
        if (step == null) return const SizedBox.shrink();

        return switch (step) {
          NamingStep() =>
            FlaiNamingScreen(controller: _controller, step: step),
          MultiSelectStep() =>
            FlaiMultiSelectScreen(controller: _controller, step: step),
          CustomStep() =>
            FlaiCustomStepScreen(controller: _controller, step: step),
          RevealStep() =>
            FlaiRevealScreen(controller: _controller, step: step),
        };
      },
    );
  }
}


class _WiredHomePage extends StatefulWidget {
  const _WiredHomePage({required this.config});
  final AppScaffoldConfig config;

  @override
  State<_WiredHomePage> createState() => _WiredHomePageState();
}

class _WiredHomePageState extends State<_WiredHomePage> {
  HomeController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    final providers = FlaiProviders.of(context);
    _controller = HomeController(
      storage: providers.storageProvider,
      ai: providers.aiProvider,
      auth: widget.config.authProvider,
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red.shade700,
            duration: const Duration(seconds: 5),
          ),
        );
      },
    );
    _controller!.addListener(_onChanged);
    _controller!.loadConversations();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<String?> _showRenameSheet(BuildContext ctx, String currentTitle) {
    final controller = TextEditingController(text: currentTitle);
    return showModalBottomSheet<String>(
      context: ctx,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
          left: 24,
          right: 24,
          top: 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Rename conversation',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Conversation name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) =>
                  Navigator.of(sheetCtx).pop(value.trim()),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(sheetCtx).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(sheetCtx).pop(controller.text.trim()),
                  child: const Text('Rename'),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    ).whenComplete(() => controller.dispose());
  }

  @override
  void dispose() {
    _controller?.removeListener(_onChanged);
    _controller?.dispose();
    super.dispose();
  }

  SettingsConfig get _effectiveSettingsConfig {
    final base = widget.config.settingsConfig;
    return SettingsConfig(
      drawerHeightRatio: base.drawerHeightRatio,
      showWorkspaceSwitcher: base.showWorkspaceSwitcher,
      sections: base.sections.map((section) {
        return SettingsSection(
          title: section.title,
          rows: section.rows.map((row) {
            if (row is NavigationRow && row.label == 'Sign Out') {
              return NavigationRow(
                icon: row.icon,
                label: row.label,
                onTap: () {
                  widget.config.authProvider.signOut();
                },
              );
            }
            return row;
          }).toList(),
        );
      }).toList(),
      infoItems: base.infoItems,
      appVersion: base.appVersion,
    );
  }

  ChatExperienceConfig get _effectiveChatConfig {
    final chatConfig = widget.config.chatExperienceConfig;
    if (widget.config.voiceProvider != null && !chatConfig.enableVoice) {
      return ChatExperienceConfig(
        assistantName: chatConfig.assistantName,
        assistantAvatar: chatConfig.assistantAvatar,
        greeting: chatConfig.greeting,
        greetingSubtitle: chatConfig.greetingSubtitle,
        composerPlaceholder: chatConfig.composerPlaceholder,
        composerConfig: chatConfig.composerConfig,
        availableModels: chatConfig.availableModels,
        enableVoice: true,
        enableGhostMode: chatConfig.enableGhostMode,
        enablePerMessageModelSwitch: chatConfig.enablePerMessageModelSwitch,
      );
    }
    return chatConfig;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    if (ctrl == null) return const SizedBox.shrink();

    final chatConfig = _effectiveChatConfig;
    final hasActiveChat = ctrl.activeConversationId != null;

    final baseSidebar = widget.config.sidebarConfig ??
        SidebarConfig(appName: widget.config.appTitle);

    return FlaiHomeScreen(
      sidebarConfig: SidebarConfig(
        appName: baseSidebar.appName,
        appLogo: baseSidebar.appLogo,
        navItems: baseSidebar.navItems,
        enableSearch: baseSidebar.enableSearch,
        topNavActions: baseSidebar.topNavActions,
        settingsConfig: baseSidebar.settingsConfig,
        onNewChat: baseSidebar.onNewChat,
        onConversationTap: baseSidebar.onConversationTap,
        onConversationStar: baseSidebar.onConversationStar ?? (item) => ctrl.starConversation(item),
        onConversationRename: baseSidebar.onConversationRename ?? (item) async {
          final ctx = context;
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (!ctx.mounted) return;
          final newTitle = await _showRenameSheet(ctx, item.title);
          if (newTitle != null && newTitle.isNotEmpty) {
            await ctrl.renameConversation(item, newTitle);
          }
        },
        onConversationShare: baseSidebar.onConversationShare ?? (item) => ctrl.shareConversation(item),
        onConversationDelete: baseSidebar.onConversationDelete ?? (item) => ctrl.deleteConversation(item),
      ),
      chatExperienceConfig: chatConfig,
      settingsConfig: _effectiveSettingsConfig,
      userProfile: ctrl.userProfile,
      conversations: ctrl.conversations,
      starredConversations: ctrl.starred,
      activeConversationId: ctrl.activeConversationId,
      onNewChat: () => ctrl.newChat(),
      onSendMessage: (text, thinking, search) =>
          ctrl.sendMessage(text, thinking: thinking, search: search),
      onConversationTap: (item) => ctrl.selectConversation(item),
      chatContent: hasActiveChat
          ? FlaiChatContent(
              messages: ctrl.messages,
              config: chatConfig,
              onSend: (text, thinking, search) =>
                  ctrl.sendMessage(text, thinking: thinking, search: search),
              isStreaming: ctrl.isStreaming,
              onRetry: (msg) => ctrl.sendMessage(msg.content),
              onRegenerate: (msg) => ctrl.sendMessage(msg.content),
            )
          : null,
    );
  }
}


class _AuthStateNotifier extends ChangeNotifier {
  late final StreamSubscription<AuthUser?> _subscription;

  _AuthStateNotifier(AuthProvider authProvider) {
    _subscription = authProvider.authStateChanges().listen((_) {
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
