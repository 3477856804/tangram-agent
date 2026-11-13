import 'providers/auth_provider.dart';
import 'providers/storage_provider.dart';
import 'providers/ai_provider.dart';
import 'providers/voice_provider.dart';
import 'core/theme/flai_theme.dart';
import 'flows/auth/auth_flow_config.dart';
import 'flows/onboarding/onboarding_config.dart';
import 'flows/chat/chat_experience_config.dart';
import 'flows/sidebar/sidebar_config.dart';
import 'flows/sidebar/settings_config.dart';

class AppScaffoldConfig {
  final AuthProvider authProvider;

  final StorageProvider? storageProvider;

  final AiProvider? aiProvider;

  final VoiceProvider? voiceProvider;

  final FlaiThemeData? theme;

  final AuthFlowConfig authFlowConfig;

  final OnboardingConfig? onboardingConfig;

  final ChatExperienceConfig chatExperienceConfig;

  final SidebarConfig? sidebarConfig;

  final SettingsConfig settingsConfig;

  final String appTitle;

  final bool showSplash;

  const AppScaffoldConfig({
    required this.authProvider,
    this.storageProvider,
    this.aiProvider,
    this.voiceProvider,
    this.theme,
    this.authFlowConfig = const AuthFlowConfig(),
    this.onboardingConfig,
    this.chatExperienceConfig = const ChatExperienceConfig(),
    this.sidebarConfig,
    this.settingsConfig = const SettingsConfig(),
    this.appTitle = 'FlAI Chat',
    this.showSplash = true,
  });
}
