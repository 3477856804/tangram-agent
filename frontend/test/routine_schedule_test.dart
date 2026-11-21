/// Routine 时间表纯逻辑测试：cron 解析、时区换算、预设双向转换与展示文案。
///
/// 全部使用 UTC / 固定偏移，不依赖运行机器的本地时区，结果可重复。

import 'package:test/test.dart';
import 'package:tangram/harness/routine_schedule.dart';

void main() {
  group('cron 解析与下次运行', () {
    test('每天 09:30（UTC+8）按墙上时间计算', () {
      final RoutineZone zone = RoutineZone.parse('UTC+8');
      final DateTime from = DateTime.utc(2026, 1, 1, 0, 30);
      final DateTime? next = nextCronDate('30 9 * * *', from, zone);
      expect(next, isNotNull);
      expect(next!.toUtc(), DateTime.utc(2026, 1, 1, 1, 30));
    });

    test('工作日从周五跳到下周一', () {
      final DateTime friday = DateTime.utc(2026, 1, 2, 10, 0);
      final DateTime? next =
          nextCronDate('0 9 * * 1-5', friday, RoutineZone.utc);
      // 2026-01-02 是周五；下一次工作日 09:00 为 01-05 周一。
      expect(next!.toUtc(), DateTime.utc(2026, 1, 5, 9, 0));
    });

    test('每月 1 日跨月', () {
      final DateTime from = DateTime.utc(2026, 1, 15, 12);
      final DateTime? next =
          nextCronDate('0 9 1 * *', from, RoutineZone.utc);
      expect(next!.toUtc(), DateTime.utc(2026, 2, 1, 9));
    });

    test('*/15 分钟步长', () {
      final DateTime from = DateTime.utc(2026, 1, 1, 10, 7);
      final DateTime? next =
          nextCronDate('*/15 * * * *', from, RoutineZone.utc);
      expect(next!.toUtc(), DateTime.utc(2026, 1, 1, 10, 15));
    });

    test('每小时整点', () {
      final DateTime from = DateTime.utc(2026, 1, 1, 10, 7);
      final DateTime? next =
          nextCronDate('0 * * * *', from, RoutineZone.utc);
      expect(next!.toUtc(), DateTime.utc(2026, 1, 1, 11));
    });

    test('星期 7 等价于星期日', () {
      final DateTime from = DateTime.utc(2026, 1, 1, 12); // 周四
      final DateTime? next =
          nextCronDate('0 9 * * 7', from, RoutineZone.utc);
      expect(next!.toUtc(), DateTime.utc(2026, 1, 4, 9));
    });

    test('日与周同时受限时取「或」语义', () {
      final DateTime from = DateTime.utc(2026, 1, 2, 12); // 周五
      // 每月 15 日或每周一；最近的是 01-05 周一。
      final DateTime? next =
          nextCronDate('0 9 15 * 1', from, RoutineZone.utc);
      expect(next!.toUtc(), DateTime.utc(2026, 1, 5, 9));
    });

    test('严格晚于起点：同一分钟不重复触发', () {
      final DateTime from = DateTime.utc(2026, 1, 1, 10, 0);
      final DateTime? next =
          nextCronDate('* * * * *', from, RoutineZone.utc);
      expect(next!.toUtc(), DateTime.utc(2026, 1, 1, 10, 1));
    });

    test('非法表达式返回 null 而不是伪造时间', () {
      final DateTime from = DateTime.utc(2026, 1, 1);
      expect(nextCronDate('60 * * * *', from, RoutineZone.utc), isNull);
      expect(nextCronDate('* * * *', from, RoutineZone.utc), isNull);
      expect(nextCronDate('a * * * *', from, RoutineZone.utc), isNull);
      expect(CronExpression.isValid('0 0 31 2 *'), isTrue);
    });

    test('@once 没有重复的下次运行', () {
      expect(isOneShotCron(' @once '), isTrue);
      expect(
        nextCronDate('@once', DateTime.utc(2026), RoutineZone.utc),
        isNull,
      );
      expect(
        hasMixedOneShotSchedule(<String>['@once', '0 9 * * *']),
        isTrue,
      );
      expect(hasMixedOneShotSchedule(<String>['@once']), isFalse);
    });

    test('多时间表取最近一次', () {
      final DateTime from = DateTime.utc(2026, 1, 1, 8);
      final DateTime? next = nextCronDateAcross(
        <String>['0 9 * * *', '30 8 * * *', '@once'],
        from,
        RoutineZone.utc,
      );
      expect(next!.toUtc(), DateTime.utc(2026, 1, 1, 8, 30));
    });

    test('严格校验遇到非法 cron 直接抛错', () {
      expect(
        () => nextCronDateAcrossStrict(
          <String>['0 9 * * *', 'bad'],
          DateTime.utc(2026),
          RoutineZone.utc,
        ),
        throwsFormatException,
      );
    });
  });

  group('间隔相位', () {
    test('*/7 分钟从锚点递推而不是整点重置', () {
      final DateTime anchor = DateTime.utc(2026, 1, 1, 0, 0);
      final DateTime now = DateTime.utc(2026, 1, 1, 0, 8);
      final DateTime? next = nextRoutineRunDate(
        '*/7 * * * *',
        anchor,
        now,
        RoutineZone.utc,
      );
      expect(next!.toUtc(), DateTime.utc(2026, 1, 1, 0, 14));
    });

    test('整除步长仍按 cron 墙上时间', () {
      final DateTime anchor = DateTime.utc(2026, 1, 1, 0, 0);
      final DateTime now = DateTime.utc(2026, 1, 1, 0, 8);
      final DateTime? next = nextRoutineRunDate(
        '*/5 * * * *',
        anchor,
        now,
        RoutineZone.utc,
      );
      expect(next!.toUtc(), DateTime.utc(2026, 1, 1, 0, 10));
      expect(unevenInterval('*/5 * * * *'), isNull);
      expect(unevenInterval('*/7 * * * *'), isNotNull);
    });

    test('天间隔从锚点自然日递增', () {
      final DateTime anchor = DateTime.utc(2026, 1, 1, 0, 0);
      final DateTime now = DateTime.utc(2026, 1, 2, 1, 0);
      final DateTime? next = nextRoutineRunDate(
        '0 0 */3 * *',
        anchor,
        now,
        RoutineZone.utc,
      );
      expect(next!.toUtc(), DateTime.utc(2026, 1, 4));
    });
  });

  group('预设双向转换', () {
    test('每个预设都能生成合法 cron 并识别回来', () {
      final List<CronPreset> presets = <CronPreset>[
        const CronPreset(freq: CronFreq.hourly),
        const CronPreset(freq: CronFreq.daily, hour: 9, minute: 30),
        const CronPreset(freq: CronFreq.weekdays, hour: 8, minute: 15),
        const CronPreset(freq: CronFreq.weekly, hour: 18, minute: 0),
        const CronPreset(freq: CronFreq.monthly, hour: 7, minute: 5),
        const CronPreset(
          freq: CronFreq.interval,
          n: 15,
          unit: CronUnit.minutes,
        ),
        const CronPreset(
          freq: CronFreq.interval,
          n: 5,
          unit: CronUnit.hours,
        ),
        const CronPreset(
          freq: CronFreq.interval,
          n: 3,
          unit: CronUnit.days,
        ),
        const CronPreset(freq: CronFreq.advanced, cron: '0 9 15 * 2'),
      ];
      for (final CronPreset preset in presets) {
        final String cron = cronFromPreset(preset);
        expect(CronExpression.isValid(cron), isTrue, reason: cron);
        final CronPreset back = presetFromCron(cron);
        expect(back.freq, preset.freq, reason: cron);
        if (preset.freq == CronFreq.daily ||
            preset.freq == CronFreq.weekdays ||
            preset.freq == CronFreq.weekly ||
            preset.freq == CronFreq.monthly) {
          expect(back.hour, preset.hour, reason: cron);
          expect(back.minute, preset.minute, reason: cron);
        }
        if (preset.freq == CronFreq.interval) {
          expect(back.n, preset.n, reason: cron);
          expect(back.unit, preset.unit, reason: cron);
        }
      }
    });

    test('高级 @once 往返保持一次性', () {
      const CronPreset once =
          CronPreset(freq: CronFreq.advanced, cron: onceCron);
      expect(cronFromPreset(once), onceCron);
      expect(presetFromCron(onceCron).cron, onceCron);
    });

    test('间隔数量不超过字段上限', () {
      expect(cronIntervalAmounts(CronUnit.minutes).last, 45);
      expect(cronIntervalAmounts(CronUnit.hours).every((int n) => n <= 23), isTrue);
      expect(clampIntervalAmount(90, CronUnit.minutes), 45);
      expect(clampIntervalAmount(8, CronUnit.hours), 8);
    });
  });

  group('中文展示', () {
    test('常见形状可读', () {
      expect(formatCron('30 9 * * 1-5'), '工作日 09:30');
      expect(formatCron('0 9 * * 1'), '每周一 09:00');
      expect(formatCron('0 9 1 * *'), '每月 1 日 09:00');
      expect(formatCron('*/15 * * * *'), '每 15 分钟');
      expect(formatCron('0 * * * *'), '每小时');
      expect(formatCron('5 * * * *'), '每小时第 5 分');
      expect(formatCron('0 */6 * * *'), '每 6 小时');
      expect(formatCron('7 10 * * 1,3,5'), '每周一、周三、周五 10:07');
      expect(formatCron('0 9 * * 0,6'), '周末 09:00');
      expect(formatCron('@once'), '一次性');
    });

    test('无法归类的表达式保留 cron 原文', () {
      expect(formatCron('0 9 15 * 2'), contains('Cron'));
      expect(formatCron('0 9 15 * 2'), contains('0 9 15 * 2'));
    });

    test('多时间表用顿号连接', () {
      expect(
        formatCrons(<String>['0 9 * * *', '30 18 * * 5']),
        '每天 09:00、每周五 18:30',
      );
      expect(formatCrons(<String>[]), '未设置时间表');
    });
  });

  group('运行记录辅助', () {
    test('调度延迟宽限 5 分钟', () {
      final DateTime now = DateTime.utc(2026, 1, 1, 10);
      expect(
        routineScheduleDelayed(true, DateTime.utc(2026, 1, 1, 9, 55), now),
        isFalse,
      );
      expect(
        routineScheduleDelayed(true, DateTime.utc(2026, 1, 1, 9, 54), now),
        isTrue,
      );
      expect(
        routineScheduleDelayed(false, DateTime.utc(2026, 1, 1, 9), now),
        isFalse,
      );
      expect(routineScheduleDelayed(true, null, now), isFalse);
    });

    test('紧凑耗时', () {
      expect(compactDuration(850), '850ms');
      expect(compactDuration(4200), '4.2s');
      expect(compactDuration(59000), '59s');
      expect(compactDuration(65000), '1m 05s');
      expect(compactDuration(null), isNull);
      expect(compactDuration(-1), isNull);
    });

    test('迟到按最大整数单位展示', () {
      final DateTime started = DateTime.utc(2026, 1, 1, 10, 30);
      expect(
        routineRunLateness(DateTime.utc(2026, 1, 1, 10), started),
        (unit: '分钟', count: 30),
      );
      expect(
        routineRunLateness(DateTime.utc(2026, 1, 1, 7), started),
        (unit: '小时', count: 3),
      );
      expect(
        routineRunLateness(DateTime.utc(2025, 12, 30), started),
        (unit: '天', count: 2),
      );
      expect(routineRunLateness(null, started), isNull);
    });
  });

  group('时区解析', () {
    test('支持本地、UTC、固定偏移与常见 IANA', () {
      expect(RoutineZone.parse('local').local, isTrue);
      expect(RoutineZone.parse('UTC').offsetMinutes, 0);
      expect(RoutineZone.parse('UTC+8').offsetMinutes, 480);
      expect(RoutineZone.parse('GMT-05:30').offsetMinutes, -330);
      expect(RoutineZone.parse('Asia/Shanghai').offsetMinutes, 480);
      expect(RoutineZone.parse('Asia/Kolkata').offsetMinutes, 330);
    });

    test('不支持的时区如实报错', () {
      expect(RoutineZone.isSupported('America/New_York'), isFalse);
      expect(
        () => RoutineZone.parse('America/New_York'),
        throwsFormatException,
      );
      expect(
        () => RoutineZone.parse('UTC+15'),
        throwsFormatException,
      );
    });
  });
}
