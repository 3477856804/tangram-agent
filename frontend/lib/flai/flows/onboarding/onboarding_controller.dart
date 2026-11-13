import 'package:flutter/foundation.dart';
import 'onboarding_config.dart';

class OnboardingController extends ChangeNotifier {
  OnboardingController({
    required OnboardingConfig config,
  }) : _config = config;

  final OnboardingConfig _config;

  int _currentIndex = 0;

  String _assistantName = '';

  List<String> _selectedOptions = [];

  bool _isComplete = false;


  OnboardingConfig get config => _config;
  int get currentIndex => _currentIndex;
  int get totalSteps => _config.steps.length;
  bool get isComplete => _isComplete;
  String get assistantName =>
      _assistantName.isEmpty ? _defaultName : _assistantName;

  OnboardingStep? get currentStep =>
      _currentIndex < _config.steps.length ? _config.steps[_currentIndex] : null;

  bool get canGoBack => _currentIndex > 0;

  List<String> get selectedOptions => _selectedOptions;


  void next() {
    if (_currentIndex < _config.steps.length - 1) {
      _currentIndex++;
      notifyListeners();
    } else {
      _complete();
    }
  }

  void back() {
    if (_currentIndex > 0) {
      _currentIndex--;
      notifyListeners();
    }
  }

  void skip() => next();


  void setAssistantName(String name) {
    _assistantName = name.trim();
    notifyListeners();
  }

  void setSelectedOptions(List<String> options) {
    _selectedOptions = options;
    notifyListeners();
  }


  String get _defaultName {
    for (final step in _config.steps) {
      if (step is NamingStep) return step.defaultName;
    }
    return 'Assistant';
  }

  void _complete() {
    _isComplete = true;
    notifyListeners();
    _config.onComplete(OnboardingResult(
      assistantName: assistantName,
      selectedOptions: _selectedOptions,
    ));
  }
}
