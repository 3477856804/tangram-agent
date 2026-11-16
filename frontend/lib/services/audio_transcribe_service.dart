import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../harness/gateway_discovery.dart';
import '../harness/im_service.dart' show kDefaultGatewayUrl;

/// 录音文件转文字结果。
class TranscriptionResult {
  final String text;
  final String gateway;

  const TranscriptionResult({required this.text, required this.gateway});
}

/// 转写失败（如实抛给上层显示，绝不返回假文字）。
class TranscriptionException implements Exception {
  final String message;
  const TranscriptionException(this.message);

  @override
  String toString() => message;
}

/// 录音文件 → 真实 ASR 转文字。
///
/// 链路：选择本地录音文件 → base64 → POST {网关}/api/asr → 返回文字。
/// 后端用 whisper/在线 ASR 真实转写；未配置后端时如实返回错误。
/// 绝不生成、猜测或占位任何识别文字。
class AudioTranscribeService {
  AudioTranscribeService({http.Client? client, SharedPreferences? prefs})
      : _client = client ?? http.Client(),
        _prefs = prefs;

  final http.Client _client;
  final SharedPreferences? _prefs;

  /// IM 面板保存网关地址的共享键（与 UI 面板约定一致）。
  static const String gatewayPrefKey = 'tangram.gateway.url';

  /// 单次上传音频上限（18 MiB 原始，对应网关 _ASR_MAX_BODY 的 base64 膨胀）。
  static const int maxAudioBytes = 18 * 1024 * 1024;

  /// 解析网关地址：显式传入 > 用户在 IM 面板保存的地址 > dart-define > 局域网发现。
  Future<String> resolveGateway({String? explicit}) async {
    final String explicitUrl = explicit?.trim() ?? '';
    if (explicitUrl.isNotEmpty) return _normalize(explicitUrl);

    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      final String saved = (prefs.getString(gatewayPrefKey) ?? '').trim();
      if (saved.isNotEmpty) return _normalize(saved);
    } catch (_) {
      // 存储不可用时继续尝试其它来源
    }

    if (kDefaultGatewayUrl.trim().isNotEmpty) {
      return _normalize(kDefaultGatewayUrl);
    }

    final String? discovered = await GatewayDiscovery.discover();
    if (discovered != null && discovered.trim().isNotEmpty) {
      return _normalize(discovered);
    }

    throw const TranscriptionException(
      '未找到可用的网关地址。请先在「更多通信」中启动/填写网关，'
      '或在构建时用 TANGRAM_GATEWAY_URL 注入。',
    );
  }

  String _normalize(String url) {
    String u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'http://$u';
    }
    return u.replaceAll(RegExp(r'/+$'), '');
  }

  /// 转写本地录音文件。失败抛 [TranscriptionException]。
  Future<TranscriptionResult> transcribeFile(
    String filePath, {
    String? gatewayUrl,
    String language = 'zh',
  }) async {
    final File file = File(filePath);
    if (!file.existsSync()) {
      throw TranscriptionException('录音文件不存在：$filePath');
    }
    final int size = await file.length();
    if (size == 0) {
      throw const TranscriptionException('录音文件为空，无法转写。');
    }
    if (size > maxAudioBytes) {
      throw TranscriptionException(
        '录音文件超过 ${(maxAudioBytes / 1048576).toStringAsFixed(0)}MB 上限（当前 '
        '${(size / 1048576).toStringAsFixed(1)}MB），请截取较短片段后重试。',
      );
    }

    final String gateway = await resolveGateway(explicit: gatewayUrl);
    final String b64 = base64Encode(await file.readAsBytes());

    http.Response response;
    try {
      response = await _client.post(
        Uri.parse('$gateway/api/asr'),
        headers: <String, String>{'Content-Type': 'application/json; charset=utf-8'},
        body: jsonEncode(<String, String>{
          'audio_b64': b64,
          'filename': _fileName(filePath),
          'language': language,
        }),
      ).timeout(const Duration(seconds: 120));
    } on SocketException catch (e) {
      throw TranscriptionException('无法连接网关 $gateway：$e');
    } on http.ClientException catch (e) {
      throw TranscriptionException('请求网关失败：$e');
    } on FlutterError catch (e) {
      throw TranscriptionException('请求异常：$e');
    }

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw TranscriptionException(
        '网关返回了无法解析的响应（HTTP ${response.statusCode}）：'
        '${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
      );
    }

    if (response.statusCode != 200 || data['ok'] != true) {
      final String err = (data['error'] ?? 'unknown').toString();
      final String hint = (data['hint'] ?? data['reason'] ?? '').toString();
      throw TranscriptionException(_friendlyError(err, hint));
    }

    final String text = (data['text'] ?? '').toString().trim();
    if (text.isEmpty) {
      throw const TranscriptionException('网关返回的转写结果为空，请重试或换一段录音。');
    }
    return TranscriptionResult(text: text, gateway: gateway);
  }

  String _fileName(String path) {
    final parts = path.replaceAll('\\', '/').split('/');
    return parts.isEmpty ? 'audio' : parts.last;
  }

  String _friendlyError(String code, String hint) {
    switch (code) {
      case 'asr-unavailable':
        return '网关尚未配置语音转文字后端：\n$hint';
      case 'audio-too-large':
      case 'payload-too-large-or-invalid':
        return '录音文件过大，网关拒绝处理，请截取较短片段。';
      case 'unauthorized':
        return '网关拒绝了本次请求（来源校验未通过），请检查网关安全配置。';
      case 'empty-transcript':
        return '未从录音中识别出文字（可能是静音或噪声），请换一段清晰的录音。';
      case 'asr-failed':
        return '网关转写失败：${hint.isEmpty ? code : hint}';
      default:
        return '转写失败（$code）${hint.isEmpty ? '' : '：$hint'}';
    }
  }

  void dispose() => _client.close();
}
