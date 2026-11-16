/// 录音文件转文字服务测试：验证真实 HTTP 契约与诚实报错。
/// 用 MockClient 模拟网关响应，不伪造识别内容。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tangram/services/audio_transcribe_service.dart';

void main() {
  late Directory tmp;
  late File audio;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tga_asr_test_');
    audio = File('${tmp.path}/voice.m4a');
    // 仅测试 HTTP 契约与载荷，写入一个最小字节序列代表录音文件。
    await audio.writeAsBytes(<int>[0x00, 0x01, 0x02, 0x03]);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('成功后返回网关返回的真实文字', () async {
    final client = MockClient((http.Request req) async {
      expect(req.url.path, '/api/asr');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['audio_b64'], isNotEmpty);
      expect(body['filename'], 'voice.m4a');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'ok': true,
          'text': '今天天气很好',
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final svc = AudioTranscribeService(client: client);
    final result = await svc.transcribeFile(
      audio.path,
      gatewayUrl: 'http://127.0.0.1:50432',
    );
    expect(result.text, '今天天气很好');
    expect(result.gateway, 'http://127.0.0.1:50432');
    svc.dispose();
  });

  test('网关未配置 ASR 后端时如实抛错并附带安装指引', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'asr-unavailable',
            'hint': 'pip install faster-whisper',
          }),
          503,
          headers: <String, String>{'content-type': 'application/json'},
        ));
    final svc = AudioTranscribeService(client: client);
    expect(
      () => svc.transcribeFile(audio.path,
          gatewayUrl: 'http://127.0.0.1:50432'),
      throwsA(isA<TranscriptionException>().having(
        (e) => e.message,
        'message',
        contains('faster-whisper'),
      )),
    );
    svc.dispose();
  });

  test('文件不存在时如实抛错，不产生假文字', () async {
    final svc = AudioTranscribeService(client: MockClient((_) async {
      throw StateError('不应发起请求');
    }));
    expect(
      () => svc.transcribeFile('${tmp.path}/missing.m4a',
          gatewayUrl: 'http://127.0.0.1:50432'),
      throwsA(isA<TranscriptionException>().having(
        (e) => e.message,
        'message',
        contains('不存在'),
      )),
    );
    svc.dispose();
  });

  test('空转写结果如实报错', () async {
    final client = MockClient((_) async => http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'text': '   '}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        ));
    final svc = AudioTranscribeService(client: client);
    expect(
      () => svc.transcribeFile(audio.path,
          gatewayUrl: 'http://127.0.0.1:50432'),
      throwsA(isA<TranscriptionException>()),
    );
    svc.dispose();
  });
}
