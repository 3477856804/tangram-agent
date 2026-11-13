import 'package:flutter/material.dart';

import '../../../core/theme/flai_theme.dart';
import '../auth_controller.dart';
import '../widgets/social_auth_button.dart';
import '../widgets/typing_tagline.dart';

class FlaiLoginLanding extends StatelessWidget {
  const FlaiLoginLanding({
    super.key,
    required this.controller,
  });

  final AuthController controller;

  @override
  Widget build(BuildContext context) {
    final theme = FlaiTheme.of(context);
    final config = controller.config;

    return Scaffold(
      backgroundColor: theme.colors.background,
      body: SafeArea(
        child: Stack(
          children: [
            if (config.allowGuest)
              Positioned(
                top: theme.spacing.md,
                right: theme.spacing.md,
                child: IconButton(
                  onPressed: controller.onGuestContinue,
                  icon: Icon(
                    Icons.close,
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ),

            Column(
              children: [
                Expanded(
                  flex: 3,
                  child: Center(
                    child: TypingTagline(taglines: config.taglines),
                  ),
                ),

                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: theme.spacing.lg,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ...config.enabledSocialAuth.map(
                          (type) => Padding(
                            padding: EdgeInsets.only(bottom: theme.spacing.sm),
                            child: SocialAuthButton(
                              type: type,
                              onTap: () => controller.signInWithSocial(type),
                            ),
                          ),
                        ),

                        if (config.showSignUp)
                          Padding(
                            padding: EdgeInsets.only(bottom: theme.spacing.sm),
                            child: SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: TextButton(
                                onPressed: () {
                                  controller.goToEmailEntry(isSignUp: true);
                                },
                                style: TextButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  foregroundColor: theme.colors.foreground,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      theme.radius.full,
                                    ),
                                    side: BorderSide(
                                      color: theme.colors.border,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  '注册',
                                  style: theme.typography.base,
                                ),
                              ),
                            ),
                          ),

                        if (config.showEmailSignIn)
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: TextButton(
                              onPressed: () {
                                controller.goToEmailEntry(isSignUp: false);
                              },
                              style: TextButton.styleFrom(
                                foregroundColor: theme.colors.foreground,
                              ),
                              child: Text(
                                'Log in',
                                style: theme.typography.base,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
