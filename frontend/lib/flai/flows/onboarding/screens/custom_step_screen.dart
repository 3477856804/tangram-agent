import 'package:flutter/material.dart';
import '../onboarding_config.dart';
import '../onboarding_controller.dart';

class FlaiCustomStepScreen extends StatelessWidget {
  const FlaiCustomStepScreen({
    super.key,
    required this.controller,
    required this.step,
  });

  final OnboardingController controller;
  final CustomStep step;

  @override
  Widget build(BuildContext context) {
    return step.builder(context, controller.next);
  }
}
