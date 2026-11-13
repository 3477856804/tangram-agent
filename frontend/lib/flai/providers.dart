import 'package:flutter/widgets.dart';

import 'providers/auth_provider.dart';
import 'providers/storage_provider.dart';
import 'providers/ai_provider.dart';
import 'providers/voice_provider.dart';

class FlaiProviders extends InheritedWidget {
  final AuthProvider authProvider;

  final StorageProvider storageProvider;

  final AiProvider? aiProvider;

  final VoiceProvider? voiceProvider;

  const FlaiProviders({
    super.key,
    required this.authProvider,
    required this.storageProvider,
    this.aiProvider,
    this.voiceProvider,
    required super.child,
  });

  static FlaiProviders of(BuildContext context) {
    final result =
        context.dependOnInheritedWidgetOfExactType<FlaiProviders>();
    assert(result != null, 'No FlaiProviders found in widget tree');
    return result!;
  }

  @override
  bool updateShouldNotify(FlaiProviders oldWidget) =>
      authProvider != oldWidget.authProvider ||
      storageProvider != oldWidget.storageProvider ||
      aiProvider != oldWidget.aiProvider ||
      voiceProvider != oldWidget.voiceProvider;
}
