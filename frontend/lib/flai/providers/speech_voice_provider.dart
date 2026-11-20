import 'dart:async';
import 'dart:typed_data';

import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'voice_provider.dart';

/// 基于平台语音识别（speech_to_text，已在 pubspec 声明的依赖）的 VoiceProvider。
///
/// 录音链路全部真实：`startConversation` 初始化平台识别器并开始监听，
/// 识别结果经 `VoiceTranscript` 回流，最终文本由平台识别器给出；
/// 麦克风实时声级经 `onSoundLevelChange` 回调，以 `VoiceAmplitude`
/// 事件发出（平台声级归一化到 0..1，见 [normalizeSoundLevelDb]）。
///
/// 诚实边界：
/// - `transcribe`：平台识别器只支持实时麦克风输入，不支持离线音频字节
///   转写，调用即抛 [UnsupportedError]，绝不假装转写成功。
/// - `synthesize`：本实现不含 TTS，调用即抛 [UnsupportedError]。
/// - 初始化失败（无识别器/无麦克风权限）时发出 `VoiceError` 说明真实原因，
///   不谎称已开始录音。
class SpeechToTextVoiceProvider implements VoiceProvider {
  SpeechToTextVoiceProvider({SpeechToText? speech})
      : _speech = speech ?? SpeechToText();

  final SpeechToText _speech;
  final StreamController<VoiceEvent> _events =
      StreamController<VoiceEvent>.broadcast();
  bool _listening = false;

  /// 会话代次：start 期间用户点停止时递增，使尚未完成的 start 在
  /// await 返回后自行收尾，不留「界面已停、识别器还在听」的假状态。
  int _session = 0;

  /// 平台声级归一化到 0.0 ~ 1.0，仅做显示缩放。
  ///
  /// 包文档原话：声级值在 Android 与 iOS 上并不相同，Android 值的含义
  /// 未能从官方文档确定，iOS 上返回的是分贝（dB）。但同一设备上该值
  /// 随输入响度单调变化（包文档建议用它「随输入多少更新 UI」），因此
  /// 单调映射到条形高度是如实的显示方式：取 -60 作静音底、0 作满幅
  /// 线性映射并钳制，静音贴近 0、响亮输入封顶为 1。绝对刻度未经真机
  /// 校准，如需微调只改这里；声级本身的相对变化不受映射影响。
  static double normalizeSoundLevelDb(double db) =>
      ((db + 60.0) / 60.0).clamp(0.0, 1.0);

  @override
  Stream<VoiceEvent> get conversationEvents => _events.stream;

  @override
  bool get isListening => _listening && _speech.isListening;

  @override
  bool get isSpeaking => false;

  @override
  Future<void> startConversation() async {
    if (_listening) return;
    final int session = ++_session;
    final bool available = await _speech.initialize(
      onError: _onSpeechError,
      onStatus: _onSpeechStatus,
    );
    // start 期间用户已点停止：放弃本次启动，不碰识别器状态。
    if (session != _session) return;
    if (!available) {
      _events.add(const VoiceError('语音识别不可用：设备无识别器或未授予麦克风权限'));
      return;
    }
    await _speech.listen(
      onResult: _onSpeechResult,
      onSoundLevelChange: (double level) {
        if (!_listening) return;
        _events.add(VoiceAmplitude(normalizeSoundLevelDb(level)));
      },
      // 录音会话最长 10 分钟；停顿 5 秒后识别器自动结束本次会话，
      // 由 onStatus('done') 回流 VoiceConversationDone。系统可能施加
      // 更短的上限（Android 无语音时约十秒），届时同样由状态流收尾。
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(minutes: 10),
        pauseFor: const Duration(seconds: 5),
        partialResults: true,
      ),
    );
    if (session != _session) {
      // listen 期间用户已点停止：立即停掉刚起的识别器，不留假监听。
      try {
        await _speech.stop();
      } catch (_) {
        // 收尾失败不抛给界面：会话本就已被用户取消。
      }
      return;
    }
    // listen 成功返回后才标记监听中：抛异常时不留「假监听」状态。
    _listening = true;
  }

  @override
  Future<void> stopConversation() async {
    ++_session; // 使进行中的 start 在 await 返回后自行放弃。
    if (!_listening) return;
    _listening = false;
    try {
      await _speech.stop();
    } finally {
      _events.add(const VoiceConversationDone());
    }
  }

  void _onSpeechResult(SpeechRecognitionResult result) {
    // 只回流最终识别结果；中间结果不写入输入框，避免被后续修正推翻。
    if (!result.finalResult) return;
    final String text = result.recognizedWords.trim();
    if (text.isEmpty) return;
    _events.add(VoiceTranscript(text));
  }

  void _onSpeechStatus(String status) {
    // 识别器自行结束（超时/静音/被系统打断）时如实结束会话；
    // 用户主动 stop 时 stopConversation 已发过 Done 事件，这里不重复发。
    if (!_listening) return;
    if (status == 'done' || status == 'doneNoResult' || status == 'notListening') {
      _listening = false;
      _events.add(const VoiceConversationDone());
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    // 只有永久性错误才提示用户；no_match / speech_timeout 这类瞬时错误
    // 由状态流正常结束会话，不弹无意义的报错。
    if (error.permanent) {
      _events.add(VoiceError('语音识别失败：${error.errorMsg}'));
    }
  }

  @override
  Future<String> transcribe(Uint8List audio) {
    throw UnsupportedError(
      'SpeechToTextVoiceProvider 只支持实时麦克风识别，不支持离线音频转写',
    );
  }

  @override
  Future<Uint8List> synthesize(String text) {
    throw UnsupportedError('SpeechToTextVoiceProvider 不含语音合成功能');
  }
}
