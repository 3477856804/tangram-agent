/// 定时任务失败重试策略的纯逻辑测试。
///
/// 不构造真实 BackendClient / PersonaStore，也不触发任何网络或落盘，
/// 只验证 TaskRetryPolicy 的退避表与运行历史裁剪语义。

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/services/task_scheduler.dart';

void main() {
  group('TaskRetryPolicy.delayForAttempt', () {
    test('第 1/2/3 次重试分别返回 60/300/900 秒', () {
      expect(TaskRetryPolicy.delayForAttempt(1), 60);
      expect(TaskRetryPolicy.delayForAttempt(2), 300);
      expect(TaskRetryPolicy.delayForAttempt(3), 900);
    });

    test('超过 3 次（及非正数）返回 null，表示不再重试', () {
      expect(TaskRetryPolicy.delayForAttempt(4), isNull);
      expect(TaskRetryPolicy.delayForAttempt(100), isNull);
      expect(TaskRetryPolicy.delayForAttempt(0), isNull);
      expect(TaskRetryPolicy.delayForAttempt(-1), isNull);
    });

    test('backoffSeconds 单调递增且与实际返回值一致', () {
      final List<int> backoff = TaskRetryPolicy.backoffSeconds;
      expect(backoff.length, 3);
      expect(backoff, <int>[60, 300, 900]);
      for (int i = 1; i < backoff.length; i++) {
        expect(backoff[i], greaterThan(backoff[i - 1]));
      }
      for (int attempt = 1; attempt <= backoff.length; attempt++) {
        expect(TaskRetryPolicy.delayForAttempt(attempt), backoff[attempt - 1]);
      }
    });
  });

  group('runHistory 上限', () {
    test('最多保留最近 100 条，超出时丢弃最旧记录', () {
      final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];
      for (int i = 0; i < 105; i++) {
        TaskRetryPolicy.appendRunHistory(
          history,
          <String, dynamic>{'id': 'task-$i', 'outcome': 'success'},
        );
      }
      expect(history.length, TaskRetryPolicy.maxRunHistory);
      expect(history.length, 100);
      expect(history.first['id'], 'task-5');
      expect(history.last['id'], 'task-104');
    });

    test('未达到上限时完整保留', () {
      final List<Map<String, dynamic>> history = <Map<String, dynamic>>[];
      for (int i = 0; i < 3; i++) {
        TaskRetryPolicy.appendRunHistory(
          history,
          <String, dynamic>{'id': 'task-$i'},
        );
      }
      expect(history.length, 3);
      expect(history.map((Map<String, dynamic> e) => e['id']),
          <String>['task-0', 'task-1', 'task-2']);
    });
  });
}
