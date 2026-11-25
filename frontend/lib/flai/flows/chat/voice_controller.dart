import 'dart:async';
import 'dart:math' as math;

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

  /// 转写序号：每收到一次非空最终转写就 +1。
  /// UI 用它判断「是否有新转写」，而不是比较文本字符串——
  /// 连续两次说出相同内容时文本不变，字符串比较会漏掉第二次，
  /// 导致「识别成功却没进输入框」。这是语音输入曾不可用的根因之一。
  int _transcriptSeq = 0;

  int get transcriptSeq => _transcriptSeq;

  /// 最新一次真实麦克风声级（0.0 ~ 1.0），由 VoiceAmplitude 事件驱动。
  /// 提供方不发声级事件时恒为 0；界面用「是否收到过声级样本」区分
  /// 「无声级来源」与「真实静音」，见 composer 的 _InlineWaveform。
  final ValueNotifier<double> amplitude = ValueNotifier<double>(0.0);

  bool get isRecording => _isRecording;

  bool get isTranscribing => _isTranscribing;

  String? get lastTranscript => _lastTranscript;

  bool get isBusy => _isRecording || _isTranscribing;

  Future<void> startRecording() async {
    if (_isRecording) return;

    _isRecording = true;
    amplitude.value = 0.0;
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
          _transcriptSeq++;
          _isTranscribing = false;
          notifyListeners();
          onTranscribed?.call(text.trim());
        }
      case VoiceAmplitude(:final level):
        amplitude.value = math.min(1.0, math.max(0.0, level));
      case VoiceError(:final message):
        _isRecording = false;
        _isTranscribing = false;
        amplitude.value = 0.0;
        notifyListeners();
        onError?.call(message);
      case VoiceConversationDone():
        _isRecording = false;
        _isTranscribing = false;
        amplitude.value = 0.0;
        notifyListeners();
      case VoiceAudio():
        break;
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    amplitude.dispose();
    super.dispose();
  }
}
