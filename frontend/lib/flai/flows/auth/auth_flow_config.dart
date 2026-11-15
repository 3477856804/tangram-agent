import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

enum SocialAuthType { apple, google, microsoft, phone }

class AuthFlowConfig {
  const AuthFlowConfig({
    this.showAppleSignIn = true,
    this.showGoogleSignIn = true,
    this.showMicrosoftSignIn = false,
    this.showPhoneSignIn = false,
    this.showEmailSignIn = true,
    this.showSignUp = true,
    this.allowGuest = false,
    this.appLogo,
    this.taglines = const [
      "Let's brainstorm",
      "Let's collaborate",
      "Let's create",
    ],
    this.emailHeading = 'Log in or sign up',
    this.emailSubtitle,
    this.termsUrl,
    this.privacyUrl,
    this.onGuestContinue,
  });

  final bool showAppleSignIn;

  final bool showGoogleSignIn;

  final bool showMicrosoftSignIn;

  final bool showPhoneSignIn;

  final bool showEmailSignIn;

  final bool showSignUp;

  final bool allowGuest;

  final Widget? appLogo;

  final List<String> taglines;

  final String emailHeading;

  final String? emailSubtitle;

  final String? termsUrl;

  final String? privacyUrl;

  final VoidCallback? onGuestContinue;

  List<SocialAuthType> get enabledSocialAuth {
    // 只展示「本平台真的能调起来」的登录方式：
    // google_sign_in 只有 Android / iOS / Web 实现，sign_in_with_apple 只有在
    // Apple 平台（含 Web）才有可用实现。Windows / Linux 上这两个按钮点了必然
    // 抛 MissingPluginException——显示出来就是假入口，这里按平台过滤掉。
    // Microsoft 是 RFC 8628 设备码 + 纯 HTTP，不依赖原生插件，全平台可用。
    final bool appleSupported =
        kIsWeb || defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS;
    final bool googleSupported =
        kIsWeb || defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS;
    return [
      if (showAppleSignIn && appleSupported) SocialAuthType.apple,
      if (showGoogleSignIn && googleSupported) SocialAuthType.google,
      if (showMicrosoftSignIn) SocialAuthType.microsoft,
      if (showPhoneSignIn) SocialAuthType.phone,
    ];
  }
}
