import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/cloud_error.dart';

void main() {
  group('isRateLimitError', () {
    test('识别 HTTP 429', () {
      expect(isRateLimitError('HTTP 429：{"error":{"code":429}}'), isTrue);
    });
    test('识别网关 temporarily 文案', () {
      expect(
        isRateLimitError(
          'HTTP 429：{"error":{"message":"baidu/ernie-5.5-flash-preview:free '
          'is temporarily unavailable"}}',
        ),
        isTrue,
      );
    });
    test('识别 rate limit / too many requests', () {
      expect(isRateLimitError('Error: rate limit exceeded'), isTrue);
      expect(isRateLimitError('Too Many Requests'), isTrue);
      expect(isRateLimitError('quota exhausted'), isTrue);
    });
    test('非限流错误返回 false', () {
      expect(isRateLimitError('HTTP 401 Unauthorized'), isFalse);
      expect(isRateLimitError('SocketException: network unreachable'), isFalse);
      expect(isRateLimitError('模型推理成功'), isFalse);
    });
  });

  group('friendlyCloudError', () {
    test('429 裸 JSON 转成人话，去掉模型名与裸 JSON', () {
      const raw =
          'HTTP 429：{"error":{"message":"baidu/ernie-5.5-flash-preview:free '
          'is tempor","code":429,"metadata":{}}}';
      final String out = friendlyCloudError(raw);
      expect(out, contains('429'));
      expect(out, contains('重新生成'));
      expect(out, isNot(contains('{')));
      expect(out, isNot(contains('ernie-5.5')));
    });
    test('401 转 API Key 提示', () {
      expect(
        friendlyCloudError('HTTP 401: invalid api key'),
        contains('API Key'),
      );
    });
    test('404 转模型不存在提示', () {
      expect(
        friendlyCloudError('HTTP 404: model does not exist'),
        contains('不存在'),
      );
    });
    test('网络错误转连接提示', () {
      expect(
        friendlyCloudError('SocketException: connection timed out'),
        contains('无法连接'),
      );
    });
    test('兜底去除裸 JSON 噪声', () {
      final String out = friendlyCloudError(
        'HTTP 500：{"error":{"message":"internal server error","code":500}}',
      );
      expect(out, contains('internal server error'));
      expect(out, isNot(contains('{"error"')));
      expect(out, isNot(contains('"code"')));
    });
  });
}
