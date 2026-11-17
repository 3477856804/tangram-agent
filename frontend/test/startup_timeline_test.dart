/// 启动时间线单元测试：注入假时钟验证真实耗时、预算判定与报告结构。
import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/startup_timeline.dart';

class _FakeClock {
  _FakeClock(this._nowMs);

  int _nowMs;

  DateTime now() => DateTime.fromMillisecondsSinceEpoch(_nowMs);

  void advance(int ms) => _nowMs += ms;
}

void main() {
  group('StartupTimeline', () {
    test('阶段耗时取距上一个打点的差值，首个阶段为 0', () {
      final _FakeClock clock = _FakeClock(1000000);
      final StartupTimeline timeline = StartupTimeline(clock: clock.now);

      // 首个打点之前的等待不属于任何阶段。
      clock.advance(999);
      timeline.mark('backend.enter');
      clock.advance(120);
      timeline.mark('store.ready', budgetMs: 800);
      clock.advance(30);
      timeline.mark('kernel.ready', budgetMs: 10, background: true);

      final Map<String, dynamic> report = timeline.report();
      final List<Map<String, dynamic>> stages =
          (report['stages'] as List).cast<Map<String, dynamic>>();

      expect(stages.length, 3);
      expect(stages[0]['name'], 'backend.enter');
      expect(stages[0]['duration_ms'], 0);
      expect(stages[0]['started_at_ms'], 1000999);
      expect(stages[1]['duration_ms'], 120);
      expect(stages[1]['started_at_ms'], 1000999);
      expect(stages[2]['duration_ms'], 30);
      expect(stages[2]['background'], isTrue);
      expect(report['total_ms'], 150);
      expect(report['over_budget'], <String>['kernel.ready']);
    });

    test('预算判定严格大于才超预算，且 budgetMs 为 0 不参与判定', () {
      final _FakeClock clock = _FakeClock(2000000);
      final StartupTimeline timeline = StartupTimeline(clock: clock.now);

      timeline.mark('first');
      clock.advance(100);
      timeline.mark('exact', budgetMs: 100);
      clock.advance(50);
      timeline.mark('over', budgetMs: 10);
      clock.advance(70);
      timeline.mark('no_budget');

      final Map<String, dynamic> report = timeline.report();
      expect(report['over_budget'], <String>['over']);

      final List<Map<String, dynamic>> stages =
          (report['stages'] as List).cast<Map<String, dynamic>>();
      expect(stages[1]['budget_ms'], 100);
      expect(stages[1]['duration_ms'], 100);
      expect(stages[3]['budget_ms'], 0);
      expect(stages[3]['duration_ms'], 70);
    });

    test('报告结构包含 stages / total_ms / over_budget 与阶段字段', () {
      final _FakeClock clock = _FakeClock(3000000);
      final StartupTimeline timeline = StartupTimeline(clock: clock.now);

      timeline.mark('defaults.start', budgetMs: 2500);
      clock.advance(80);
      timeline.mark('defaults.done', budgetMs: 2500);

      final Map<String, dynamic> report = timeline.report();
      expect(report.keys.toSet(), <String>{'stages', 'total_ms', 'over_budget'});
      expect(report['total_ms'], 80);
      expect(report['over_budget'], isEmpty);

      final Map<String, dynamic> stage =
          ((report['stages'] as List).first as Map).cast<String, dynamic>();
      expect(stage.keys.toSet(), <String>{
        'name', 'started_at_ms', 'duration_ms', 'budget_ms', 'background',
      });
      expect(stage['name'], 'defaults.start');
      expect(stage['started_at_ms'], 3000000);
      expect(stage['duration_ms'], 0);
      expect(stage['budget_ms'], 2500);
      expect(stage['background'], isFalse);
    });

    test('reset 清空阶段并让下一次打点重新从 0 计时', () {
      final _FakeClock clock = _FakeClock(4000000);
      final StartupTimeline timeline = StartupTimeline(clock: clock.now);

      timeline.mark('a');
      clock.advance(200);
      timeline.mark('b', budgetMs: 50);
      expect(timeline.report()['total_ms'], 200);

      timeline.reset();
      expect(timeline.report()['stages'], isEmpty);
      expect(timeline.report()['total_ms'], 0);
      expect(timeline.report()['over_budget'], isEmpty);

      clock.advance(500);
      timeline.mark('fresh');
      final Map<String, dynamic> stage = ((timeline.report()['stages'] as List)
          .single as Map).cast<String, dynamic>();
      expect(stage['duration_ms'], 0);
      expect(stage['started_at_ms'], 4000700);
      expect(timeline.report()['total_ms'], 0);
    });
  });
}
