import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../providers/voice_provider.dart';

class FlaiVoiceController extends ChangeNotifier {
  final VoiceProvider provider;

  final ValueChanged<String>? onTranscribed;

  final ValueChanged<String>? onError;

  FlaiVoiceController({
    required this.provider,
    this.onTranscribed,
    this.onError,
  }) {
    _subscription = provider.conversationEvents.listen(_onVoiceEvent);
  }

  StreamSubscription<VoiceEvent>? _subscription;

  bool _isRecording = false;
  bool _isTranscribing = false;
  String? _lastTranscript;

  bool get isRecording => _isRecording;

  bool get isTranscribing => _isTranscribing;

  String? get lastTranscript => _lastTranscript;

  bool get isBusy => _isRecording || _isTranscribing;

  Future<void> startRecording() async {
    if (_isRecording) return;

    _isRecording = true;
    notifyListeners();

    try {
      await provider.startConversation();
    } catch (e) {
      _isRecording = false;
      notifyListeners();
      onError?.call('Could not start voice recording');
    }
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;

    _isRecording = false;
    _isTranscribing = true;
    notifyListeners();

    try {
      await provider.stopConversation();
    } catch (e) {
      onError?.call('Could not stop voice recording');
    } finally {
      _isTranscribing = false;
      notifyListeners();
    }
  }

  Future<void> cancelRecording() async {
    if (!_isRecording) return;

    _isRecording = false;
    notifyListeners();

    try {
      await provider.stopConversation();
    } catch (_) {
    }
  }

  void _onVoiceEvent(VoiceEvent event) {
    switch (event) {
      case VoiceTranscript(:final text):
        if (text.trim().isNotEmpty) {
          _lastTranscript = text.trim();
          _isTranscribing = false;
          notifyListeners();
          onTranscribed?.call(text.trim());
        }
      case VoiceError(:final message):
        _isRecording = false;
        _isTranscribing = false;
        notifyListeners();
        onError?.call(message);
      case VoiceConversationDone():
        _isRecording = false;
        _isTranscribing = false;
        notifyListeners();
      case VoiceAudio():
        break;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
