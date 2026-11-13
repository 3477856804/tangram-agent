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
    return [
      if (showAppleSignIn) SocialAuthType.apple,
      if (showGoogleSignIn) SocialAuthType.google,
      if (showMicrosoftSignIn) SocialAuthType.microsoft,
      if (showPhoneSignIn) SocialAuthType.phone,
    ];
  }
}
