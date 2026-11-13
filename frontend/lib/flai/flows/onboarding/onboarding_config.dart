import 'package:flutter/widgets.dart';

class PillOption {
  const PillOption({required this.label, this.icon});

  final String label;

  final IconData? icon;
}

sealed class OnboardingStep {
  const OnboardingStep();

  const factory OnboardingStep.naming({
    required String title,
    String? subtitle,
    List<String> suggestions,
    String defaultName,
  }) = NamingStep;

  const factory OnboardingStep.multiSelect({
    required String title,
    String? subtitle,
    required List<PillOption> options,
    int minSelections,
    int? maxSelections,
  }) = MultiSelectStep;

  const factory OnboardingStep.custom({
    required Widget Function(BuildContext context, VoidCallback onNext) builder,
  }) = CustomStep;

  const factory OnboardingStep.reveal({
    String? title,
    String? subtitle,
    Duration holdDuration,
  }) = RevealStep;
}

class NamingStep extends OnboardingStep {
  const NamingStep({
    required this.title,
    this.subtitle,
    this.suggestions = const ['Atlas', 'Nova', 'Sage', 'Aria', 'Kai'],
    this.defaultName = 'Assistant',
  });

  final String title;
  final String? subtitle;
  final List<String> suggestions;
  final String defaultName;
}

class MultiSelectStep extends OnboardingStep {
  const MultiSelectStep({
    required this.title,
    this.subtitle,
    required this.options,
    this.minSelections = 0,
    this.maxSelections,
  });

  final String title;
  final String? subtitle;
  final List<PillOption> options;
  final int minSelections;
  final int? maxSelections;
}

class CustomStep extends OnboardingStep {
  const CustomStep({required this.builder});

  final Widget Function(BuildContext context, VoidCallback onNext) builder;
}

class RevealStep extends OnboardingStep {
  const RevealStep({
    this.title,
    this.subtitle,
    this.holdDuration = const Duration(milliseconds: 1500),
  });

  final String? title;

  final String? subtitle;

  final Duration holdDuration;
}

class OnboardingResult {
  const OnboardingResult({
    required this.assistantName,
    this.selectedOptions = const [],
  });

  final String assistantName;

  final List<String> selectedOptions;
}

class OnboardingConfig {
  const OnboardingConfig({
    this.splashLogo,
    required this.steps,
    this.revealLogo,
    this.revealGradient = const [Color(0xFF818CF8), Color(0xFF34D399)],
    required this.onComplete,
  });

  final Widget? splashLogo;

  final List<OnboardingStep> steps;

  final Widget? revealLogo;

  final List<Color> revealGradient;

  final void Function(OnboardingResult result) onComplete;
}
