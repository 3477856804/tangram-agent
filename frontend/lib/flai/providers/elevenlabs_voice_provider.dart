/// ElevenLabs 语音后端：接口层 + 配置，不含真实密钥调用。
///
///  - TTS：POST https://api.elevenlabs.io/v1/text-to-speech/{voice_id}，
///    xi-api-key 走请求头；密钥每次调用前一刻才从 [VoiceCredentials]
///    读，绝不缓存为字段、绝不进日志与错误消息。
///  - STT：本实现未接 Scribe 转写，transcribe 如实抛 UnsupportedError，
///    不伪造转写结果。
///  - 实时会话：同 OpenAI 兼容后端，startConversation 如实抛
///    UnsupportedError；无密钥时抛 [VoiceNotConfiguredException]。
///
/// 本文件不含任何真实密钥；默认 voiceId 是 ElevenLabs 公开的示例音色
/// （Rachel），用户应在配置里换成自己的音色 ID。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'voice_credentials.dart';
import 'voice_provider.dart';

class ElevenLabsVoiceProvider implements VoiceProvider {
  ElevenLabsVoiceProvider({
    required VoiceCredentials credentials,
    http.Client? client,
    this.voiceId = '21m00Tcm4TlvDq8ikWAM',
    this.modelId = 'eleven_multilingual_v2',
  })  : _credentials = credentials,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final VoiceCredentials _credentials;

  /// ElevenLabs 音色 ID（默认公开示例音色 Rachel）。
  final String voiceId;

  /// ElevenLabs 模型 ID。
  final String modelId;

  final http.Client _client;
  final bool _ownsClient;

  static const String _apiBase = 'https://api.elevenlabs.io/v1';
  static const Duration _timeout = Duration(seconds: 60);

  final StreamController<VoiceEvent> _events =
      StreamController<VoiceEvent>.broadcast();

  @override
  VoiceProviderKind get kind => VoiceProviderKind.elevenLabs;

  @override
  Future<void> checkAvailable() async {
    if (!await _credentials.hasApiKey(kind)) {
      throw VoiceNotConfiguredException(
        VoiceProviderKind.elevenLabs.label,
        '未在安全存储中配置 API Key',
      );
    }
  }

  Future<String> _apiKey() async {
    final String? key = await _credentials.readApiKey(kind);
    if (key == null) {
      throw VoiceNotConfiguredException(
        VoiceProviderKind.elevenLabs.label,
        '未在安全存储中配置 API Key',
      );
    }
    return key;
  }

  @override
  Stream<VoiceEvent> get conversationEvents => _events.stream;

  @override
  bool get isListening => false;

  @override
  bool get isSpeaking => false;

  @override
  Future<void> startConversation() {
    throw UnsupportedError(
      'ElevenLabs 后端不支持实时语音会话（仅提供单次语音合成），'
      '请用 synthesize，或切换回本地语音',
    );
  }

  @override
  Future<void> stopConversation() async {}

  @override
  Future<String> transcribe(Uint8List audio) {
    throw UnsupportedError(
      'ElevenLabs 本实现只提供语音合成，未接 Scribe 转写',
    );
  }

  @override
  Future<Uint8List> synthesize(String text) async {
    final String key = await _apiKey();
    if (text.trim().isEmpty) throw ArgumentError('合成文本为空');
    final Uri uri =
        Uri.parse('$_apiBase/text-to-speech/${Uri.encodeComponent(voiceId)}');
    final http.Response resp;
    try {
      resp = await _client
          .post(
            uri,
            headers: <String, String>{
              'xi-api-key': key,
              'Content-Type': 'application/json',
              'Accept': 'audio/mpeg',
            },
            body: jsonEncode(<String, dynamic>{
              'text': text,
              'model_id': modelId,
            }),
          )
          .timeout(_timeout);
    } on TimeoutException {
      throw TimeoutException('ElevenLabs 合成超时（${_timeout.inSeconds}s）');
    }
    if (resp.statusCode == 401) {
      throw StateError('ElevenLabs 密钥无效或已过期，请重新配置');
    }
    if (resp.statusCode != 200) {
      throw StateError('ElevenLabs 合成失败：HTTP ${resp.statusCode}');
    }
    if (resp.bodyBytes.isEmpty) throw StateError('ElevenLabs 合成返回空音频');
    return resp.bodyBytes;
  }

  Future<void> dispose() async {
    await _events.close();
    if (_ownsClient) _client.close();
  }
}
