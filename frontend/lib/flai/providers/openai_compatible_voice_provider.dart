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
///    绝不伪造成功。例外：本地无密钥服务（如 Kokoro，见
///    [OpenAiCompatibleVoiceProvider.kokoro]）可用 [allowEmptyApiKey]
///    显式放行空密钥，此时请求不带 Authorization 头；默认仍要求密钥。
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
    this.allowEmptyApiKey = false,
  })  : _credentials = credentials,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Kokoro 本地 TTS（Kokoro-FastAPI 的 OpenAI 兼容端点）：
  /// 默认 http://localhost:8880/v1、模型 kokoro、音色 af_heart，
  /// 本地服务通常无密钥，[allowEmptyApiKey] 为 true，无密钥时请求
  /// 不带 Authorization 头；有密钥时仍发 Bearer，行为与通用后端一致。
  /// 只构造、不联网、不验证服务是否真的在跑——服务未起时调用如实抛错。
  factory OpenAiCompatibleVoiceProvider.kokoro({
    required VoiceCredentials credentials,
    String baseUrl = kokoroDefaultBaseUrl,
    http.Client? client,
    String ttsModel = kokoroDefaultModel,
    String ttsVoice = kokoroDefaultVoice,
    String? language,
  }) => OpenAiCompatibleVoiceProvider(
    credentials: credentials,
    baseUrl: baseUrl,
    client: client,
    ttsModel: ttsModel,
    ttsVoice: ttsVoice,
    language: language,
    allowEmptyApiKey: true,
  );

  /// Kokoro-FastAPI 默认监听地址（OpenAI 兼容路径前缀 /v1）。
  static const String kokoroDefaultBaseUrl = 'http://localhost:8880/v1';

  /// Kokoro 默认模型名（/audio/speech 的 model 字段）。
  static const String kokoroDefaultModel = 'kokoro';

  /// Kokoro 默认音色（美式女声 af_heart；服务端须有该音色，否则如实报错）。
  static const String kokoroDefaultVoice = 'af_heart';

  final VoiceCredentials _credentials;

  /// OpenAI 兼容 Base URL，如 https://api.siliconflow.cn/v1。
  /// 不含密钥；拼 URL 前去掉末尾斜杠。
  final String baseUrl;
  final String sttModel;
  final String ttsModel;
  final String ttsVoice;

  /// STT 语言（如 'zh'）；为 null 时不传 language 字段，让服务端自动检测。
  final String? language;

  /// 允许无密钥调用（本地无密钥服务，如 Kokoro）。默认 false：
  /// 通用云端后端无密钥时仍抛 [VoiceNotConfiguredException]，行为不变。
  final bool allowEmptyApiKey;

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
    if (!allowEmptyApiKey && !await _credentials.hasApiKey(kind)) {
      throw VoiceNotConfiguredException(
        VoiceProviderKind.openAiCompatible.label,
        '未在安全存储中配置 API Key',
      );
    }
  }

  /// 读密钥：[allowEmptyApiKey] 为 true 且存储中无密钥时返回 null
  /// （本地无密钥服务）；否则无密钥仍抛 [VoiceNotConfiguredException]。
  /// 返回的密钥只用于当次请求的 Authorization 头，绝不缓存、不进日志。
  Future<String?> _apiKey() async {
    final String? key = await _credentials.readApiKey(kind);
    if (key == null && !allowEmptyApiKey) {
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
    final String? key = await _apiKey();
    if (audio.isEmpty) throw ArgumentError('待转写音频为空');
    final Uri uri = Uri.parse('$_base/audio/transcriptions');
    final http.MultipartRequest req = http.MultipartRequest('POST', uri)
      ..fields['model'] = sttModel
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        audio,
        filename: 'audio.wav',
      ));
    // 无密钥的本地服务不发 Authorization 头；有密钥时仍发 Bearer。
    if (key != null) req.headers['Authorization'] = 'Bearer $key';
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
    final String? key = await _apiKey();
    if (text.trim().isEmpty) throw ArgumentError('合成文本为空');
    final Uri uri = Uri.parse('$_base/audio/speech');
    // 无密钥的本地服务不发 Authorization 头；有密钥时仍发 Bearer。
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (key != null) headers['Authorization'] = 'Bearer $key';
    final http.Response resp;
    try {
      resp = await _client
          .post(
            uri,
            headers: headers,
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
