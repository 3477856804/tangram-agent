/// OpenAI 兼容语音后端：走已有 HTTP 能力（package:http），不引入新依赖。
///
///  - STT：POST {baseUrl}/audio/transcriptions（multipart，兼容硅基流动 /
///    本地 whisper-server / OpenAI 等 OpenAI 兼容端点）。
///  - TTS：POST {baseUrl}/audio/speech，返回音频字节。
///  - 实时会话：HTTP 后端不支持麦克风实时会话，startConversation 如实
///    抛 UnsupportedError（voice_controller 会把它转成错误提示，不会假装
///    已开始录音）；transcribe / synthesize 可正常用。
///  - 密钥：每次调用前一刻才从 [VoiceCredentials] 读，绝不缓存为字段、
///    绝不进日志与错误消息；无密钥时抛 [VoiceNotConfiguredException]，
///    绝不伪造成功。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'voice_credentials.dart';
import 'voice_provider.dart';

class OpenAiCompatibleVoiceProvider implements VoiceProvider {
  OpenAiCompatibleVoiceProvider({
    required VoiceCredentials credentials,
    required this.baseUrl,
    http.Client? client,
    this.sttModel = 'whisper-1',
    this.ttsModel = 'tts-1',
    this.ttsVoice = 'alloy',
    this.language,
  })  : _credentials = credentials,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final VoiceCredentials _credentials;

  /// OpenAI 兼容 Base URL，如 https://api.siliconflow.cn/v1。
  /// 不含密钥；拼 URL 前去掉末尾斜杠。
  final String baseUrl;
  final String sttModel;
  final String ttsModel;
  final String ttsVoice;

  /// STT 语言（如 'zh'）；为 null 时不传 language 字段，让服务端自动检测。
  final String? language;

  final http.Client _client;
  final bool _ownsClient;

  static const Duration _timeout = Duration(seconds: 90);

  final StreamController<VoiceEvent> _events =
      StreamController<VoiceEvent>.broadcast();

  @override
  VoiceProviderKind get kind => VoiceProviderKind.openAiCompatible;

  @override
  Future<void> checkAvailable() async {
    if (baseUrl.trim().isEmpty) {
      throw VoiceNotConfiguredException(
        VoiceProviderKind.openAiCompatible.label,
        '未配置 Base URL',
      );
    }
    if (!await _credentials.hasApiKey(kind)) {
      throw VoiceNotConfiguredException(
        VoiceProviderKind.openAiCompatible.label,
        '未在安全存储中配置 API Key',
      );
    }
  }

  Future<String> _apiKey() async {
    final String? key = await _credentials.readApiKey(kind);
    if (key == null) {
      throw VoiceNotConfiguredException(
        VoiceProviderKind.openAiCompatible.label,
        '未在安全存储中配置 API Key',
      );
    }
    return key;
  }

  String get _base => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  @override
  Stream<VoiceEvent> get conversationEvents => _events.stream;

  @override
  bool get isListening => false;

  @override
  bool get isSpeaking => false;

  @override
  Future<void> startConversation() {
    throw UnsupportedError(
      'OpenAI 兼容后端不支持实时语音会话（无麦克风流式链路），'
      '请用 transcribe / synthesize，或切换回本地语音',
    );
  }

  @override
  Future<void> stopConversation() async {}

  @override
  Future<String> transcribe(Uint8List audio) async {
    final String key = await _apiKey();
    if (audio.isEmpty) throw ArgumentError('待转写音频为空');
    final Uri uri = Uri.parse('$_base/audio/transcriptions');
    final http.MultipartRequest req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $key'
      ..fields['model'] = sttModel
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        audio,
        filename: 'audio.wav',
      ));
    if (language != null && language!.trim().isNotEmpty) {
      req.fields['language'] = language!.trim();
    }
    final http.StreamedResponse resp;
    try {
      resp = await _client.send(req).timeout(_timeout);
    } on TimeoutException {
      throw TimeoutException('语音转写超时（${_timeout.inSeconds}s）');
    }
    final String body = await resp.stream.transform(utf8.decoder).join();
    if (resp.statusCode != 200) {
      throw StateError('语音转写失败：HTTP ${resp.statusCode}');
    }
    final Object? decoded = jsonDecode(body);
    final String text =
        decoded is Map ? '${decoded['text'] ?? ''}'.trim() : '';
    if (text.isEmpty) throw StateError('语音转写返回空文字');
    return text;
  }

  @override
  Future<Uint8List> synthesize(String text) async {
    final String key = await _apiKey();
    if (text.trim().isEmpty) throw ArgumentError('合成文本为空');
    final Uri uri = Uri.parse('$_base/audio/speech');
    final http.Response resp;
    try {
      resp = await _client
          .post(
            uri,
            headers: <String, String>{
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, dynamic>{
              'model': ttsModel,
              'input': text,
              'voice': ttsVoice,
              'response_format': 'mp3',
            }),
          )
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw TimeoutException('语音合成超时（60s）');
    }
    if (resp.statusCode != 200) {
      throw StateError('语音合成失败：HTTP ${resp.statusCode}');
    }
    if (resp.bodyBytes.isEmpty) throw StateError('语音合成返回空音频');
    return resp.bodyBytes;
  }

  Future<void> dispose() async {
    await _events.close();
    if (_ownsClient) _client.close();
  }
}
