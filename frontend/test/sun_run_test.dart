/// 「爱阳光跑」引擎的真实行为测试（纯 Dart，无 UI、无外部网络）。
///
/// 断言全部来自引擎真实输出：同 seed 可复现、运动学合理、红绿灯会真实
/// 减速到 0、疲劳让后半程变慢、达到目标后停止、暂停不增长，以及历史
/// JSON 在临时 [HarnessStore] 上的真实往返。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/sun_run.dart';

double _avg(Iterable<double> xs) {
  if (xs.isEmpty) return 0.0;
  double sum = 0;
  for (final double x in xs) {
    sum += x;
  }
  return sum / xs.length;
}

void main() {
  group('确定性', () {
    test('同一 seed 生成相同路线与 fix 序列', () {
      const SunRunConfig config = SunRunConfig(
        mode: SunRunMode.run,
        targetKm: 5,
        seed: 12345,
        realism: 0.7,
      );
      final SunRunEngine a = SunRunEngine(config);
      final SunRunEngine b = SunRunEngine(config);
      SunRunFix? fa;
      SunRunFix? fb;
      for (int i = 0; i < 600; i++) {
        fa = a.tick(1);
        fb = b.tick(1);
      }
      expect(a.route.sample(40), b.route.sample(40));
      expect(a.stats.toJson(), b.stats.toJson());
      expect(fa!.toJson(), fb!.toJson());
    });

    test('不同 seed 生成不同路线', () {
      final SunRunEngine a =
          SunRunEngine(const SunRunConfig(targetKm: 3, seed: 111));
      final SunRunEngine b =
          SunRunEngine(const SunRunConfig(targetKm: 3, seed: 222));
      expect(a.route.sample(30), isNot(equals(b.route.sample(30))));
    });
  });

  group('真实运动数据', () {
    test('10 分钟跑步的配速/步数/卡路里/卫星/精度合理', () {
      final SunRunEngine engine = SunRunEngine(
        const SunRunConfig(
          mode: SunRunMode.run,
          targetKm: 10,
          seed: 777,
          realism: 0.75,
        ),
      );
      SunRunFix? last;
      for (int i = 0; i < 600; i++) {
        last = engine.tick(1);
      }
      final SunRunStats s = engine.stats;
      expect(s.distanceM, greaterThan(0));
      // 3–8 min/km。
      expect(s.paceSecPerKm, inInclusiveRange(180, 480));
      expect(s.steps, greaterThan(0));
      expect(s.calories, greaterThan(0));
      expect(last!.satellites, inInclusiveRange(12, 24));
      expect(last.satellitesUsed, inInclusiveRange(9, 20));
      expect(last.accuracyM, inInclusiveRange(3.0, 10.0));
      expect(s.state, 'running');
    });

    test('红绿灯停顿会让速度降到 0 后恢复，疲劳让后半程更慢', () {
      final SunRunEngine engine = SunRunEngine(
        const SunRunConfig(
          mode: SunRunMode.run,
          targetKm: 20,
          seed: 20261119,
          realism: 0.8,
        ),
      );
      final List<double> speeds = <double>[];
      for (int i = 0; i < 1200; i++) {
        speeds.add(engine.tick(1).speedMps);
      }
      final int stopIndex = speeds.indexWhere((double s) => s < 0.2);
      expect(stopIndex, greaterThan(0), reason: '应当出现红绿灯停顿');
      expect(
        speeds.skip(stopIndex).any((double s) => s > 1.0),
        isTrue,
        reason: '停顿后应当重新起步',
      );

      // 只看运动中的速度，避免把停顿长度差异混入疲劳比较。
      final double firstHalf =
          _avg(speeds.take(600).where((double s) => s > 1.5));
      final double secondHalf =
          _avg(speeds.skip(600).where((double s) => s > 1.5));
      expect(secondHalf, lessThanOrEqualTo(firstHalf));
    });

    test('达到目标距离后 state=finished 且不再增长', () {
      final SunRunEngine engine = SunRunEngine(
        const SunRunConfig(
          mode: SunRunMode.run,
          targetKm: 0.3,
          seed: 9,
        ),
      );
      for (int i = 0; i < 400; i++) {
        engine.tick(1);
      }
      expect(engine.state, 'finished');
      final double distance = engine.stats.distanceM;
      final double elapsed = engine.stats.elapsedSec;
      expect(distance, closeTo(300, 1));
      for (int i = 0; i < 10; i++) {
        engine.tick(1);
      }
      expect(engine.stats.distanceM, distance);
      expect(engine.stats.elapsedSec, elapsed);
      expect(engine.stats.speedMps, 0);
    });

    test('暂停期间距离/时长不变，继续后恢复增长', () {
      final SunRunEngine engine = SunRunEngine(
        const SunRunConfig(
          mode: SunRunMode.walk,
          targetKm: 5,
          seed: 321,
        ),
      );
      for (int i = 0; i < 60; i++) {
        engine.tick(1);
      }
      final double d0 = engine.stats.distanceM;
      final double t0 = engine.stats.elapsedSec;
      engine.pause();
      for (int i = 0; i < 30; i++) {
        engine.tick(1);
      }
      expect(engine.stats.distanceM, d0);
      expect(engine.stats.elapsedSec, t0);
      engine.resume();
      for (int i = 0; i < 60; i++) {
        engine.tick(1);
      }
      expect(engine.stats.distanceM, greaterThan(d0));
      expect(engine.stats.elapsedSec, greaterThan(t0));
    });
  });

  group('路线', () {
    test('loop=true 时起点终点距离小于 20m', () {
      final SunRunRoute route = SunRunRoute.generate(
        const SunRunConfig(targetKm: 3, seed: 1, loop: true),
      );
      final Map<String, double> start = route.startPoint;
      final Map<String, double> end = route.endPoint;
      final double gap = sunRunHaversine(
          start['lat']!, start['lng']!, end['lat']!, end['lng']!);
      expect(gap, lessThan(20));
      expect(route.isLoop, isTrue);
      expect(route.lengthM, closeTo(3000, 20));
    });

    test('loop=false 时生成点到点路线且不闭合', () {
      final SunRunRoute route = SunRunRoute.generate(
        const SunRunConfig(targetKm: 3, seed: 2, loop: false),
      );
      final Map<String, double> start = route.startPoint;
      final Map<String, double> end = route.endPoint;
      final double gap = sunRunHaversine(
          start['lat']!, start['lng']!, end['lat']!, end['lng']!);
      expect(gap, greaterThan(100));
      expect(route.isLoop, isFalse);
    });
  });

  group('配置与历史', () {
    test('SunRunConfig JSON 往返', () {
      const SunRunConfig config = SunRunConfig(
        mode: SunRunMode.ride,
        targetKm: 33.3,
        paceSecPerKm: 300,
        seed: 4242,
        loop: false,
        realism: 0.4,
        weightKg: 72,
      );
      final SunRunConfig back = SunRunConfig.fromJson(config.toJson());
      expect(back.mode, SunRunMode.ride);
      expect(back.targetKm, closeTo(33.3, 1e-9));
      expect(back.paceSecPerKm, 300);
      expect(back.seed, 4242);
      expect(back.loop, isFalse);
      expect(back.realism, closeTo(0.4, 1e-9));
      expect(back.weightKg, closeTo(72, 1e-9));
    });

    test('会话摘要真实写入并在临时 HarnessStore 上读回', () async {
      final Directory tmp =
          await Directory.systemTemp.createTemp('sun_run_history_test_');
      addTearDown(() async {
        SunRunRuntime.instance.resetForTest();
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      HarnessStore.overrideForTest(tmp);
      final HarnessStore store = await HarnessStore.instance();

      final SunRunRuntime runtime = SunRunRuntime.instance;
      runtime.resetForTest();
      await runtime.attach(store);

      final Map<String, dynamic> started = await runtime.handle(
        'start',
        <String, dynamic>{
          'config': <String, dynamic>{
            'mode': 'run',
            'targetKm': 1.5,
            'seed': 555,
          },
        },
      );
      expect(started['ok'], isTrue);

      final Map<String, dynamic> stopped =
          await runtime.handle('stop', <String, dynamic>{});
      expect(stopped['ok'], isTrue);

      final Map<String, dynamic> history =
          await runtime.handle('history', <String, dynamic>{});
      expect(history['ok'], isTrue);
      final List<dynamic> items = history['items'] as List<dynamic>;
      expect(items.length, 1);
      final Map<String, dynamic> first =
          Map<String, dynamic>.from(items.first as Map);
      expect(first['mode'], 'run');
      expect(first['seed'], 555);
      expect(first['distance_km'], isA<num>());
      expect(first['pace_sec_per_km'], isA<num>());

      // 再跑一次会话，历史按最新在前追加。
      await runtime.handle(
        'start',
        <String, dynamic>{
          'config': <String, dynamic>{'mode': 'walk', 'targetKm': 1, 'seed': 7},
        },
      );
      await runtime.handle('stop', <String, dynamic>{});
      final Map<String, dynamic> again =
          await runtime.handle('history', <String, dynamic>{});
      expect((again['items'] as List<dynamic>).length, 2);
      final Map<String, dynamic> newest = Map<String, dynamic>.from(
          (again['items'] as List<dynamic>).first as Map);
      expect(newest['mode'], 'walk');

      // 状态在 stop 后如实回到 idle，不伪造仍在运行。
      final Map<String, dynamic> status =
          await runtime.handle('status', <String, dynamic>{});
      expect(status['state'], 'idle');
      expect(status['running'], isFalse);
    });

    test('未知方法与非法参数返回结构化 error', () async {
      final SunRunRuntime runtime = SunRunRuntime.instance;
      runtime.resetForTest();
      final Map<String, dynamic> unknown =
          await runtime.handle('nope', <String, dynamic>{});
      expect(unknown['ok'], isFalse);
      expect(unknown['error'].toString(), contains('未知方法'));

      final Map<String, dynamic> bad = await runtime.handle(
        'start',
        <String, dynamic>{'config': <String, dynamic>{'targetKm': 0}},
      );
      expect(bad['ok'], isFalse);
    });
  });
}
