/// Routine 时间表：纯 Dart 的 cron 解析、时区换算、下次运行计算与展示文案。
///
/// 对照 Rakazo `packages/core/src/routines/schedule.ts` 的语义重写：
///   * 5 段 cron（分/时/日/月/周），支持 `*`、`*/n`、`a-b`、`a-b/n` 与逗号列表；
///   * `@once` 一次性任务（必须由调用方提供 next_run_at）；
///   * 预设（每小时/每天/工作日/每周/每月/间隔/高级）与 cron 双向转换；
///   * 多时间表取最近一次；间隔步长按锚点递推，避免 `*/7` 在整点边界跳变；
///   * 时区：设备本地（真实 DST）、UTC、固定偏移与常见无 DST 的 IANA 名称。
///
/// 这里不碰任何 Flutter / 网络 / 磁盘 API，便于单元测试；RoutineStore 负责落盘。
library;

/// `@once` 一次性时间表标记。
const String onceCron = '@once';

/// 一次性时间表只允许单独存在。
bool isOneShotCron(String cron) => cron.trim() == onceCron;

bool isOneShotCrons(List<String> crons) =>
    crons.length == 1 && isOneShotCron(crons.first);

/// 一次性与其它时间表混用永远无效（一次性没有「下一次」可以计算）。
bool hasMixedOneShotSchedule(List<String> crons) =>
    crons.length > 1 && crons.any(isOneShotCron);

/// 时区：offsetMinutes 为相对 UTC 的分钟数；local 时使用设备真实时区（含 DST）。
class RoutineZone {
  const RoutineZone._(this.label, this.offsetMinutes, {this.local = false});

  final String label;
  final int offsetMinutes;
  final bool local;

  static const RoutineZone deviceLocal =
      RoutineZone._('设备本地', 0, local: true);
  static const RoutineZone utc = RoutineZone._('UTC', 0);

  /// 常见且当前不使用夏令时的 IANA 时区。含 DST 的时区不在这里，
  /// 避免固定偏移在换季时算错；需要时应选择「设备本地」。
  static const Map<String, int> _ianaFixed = <String, int>{
    'asia/shanghai': 480,
    'asia/chongqing': 480,
    'asia/harbin': 480,
    'asia/urumqi': 480,
    'asia/hong_kong': 480,
    'asia/macau': 480,
    'asia/taipei': 480,
    'asia/singapore': 480,
    'asia/kuala_lumpur': 480,
    'asia/manila': 480,
    'asia/brunei': 480,
    'asia/tokyo': 540,
    'asia/seoul': 540,
    'asia/pyongyang': 540,
    'asia/bangkok': 420,
    'asia/jakarta': 420,
    'asia/ho_chi_minh': 420,
    'asia/yangon': 390,
    'asia/dhaka': 360,
    'asia/almaty': 360,
    'asia/kolkata': 330,
    'asia/colombo': 330,
    'asia/kathmandu': 345,
    'asia/dubai': 240,
    'asia/muscat': 240,
    'asia/baku': 240,
    'asia/tbilisi': 240,
    'asia/yerevan': 240,
    'asia/riyadh': 180,
    'asia/baghdad': 180,
    'asia/kuwait': 180,
    'asia/qatar': 180,
    'africa/nairobi': 180,
    'africa/addis_ababa': 180,
    'africa/dar_es_salaam': 180,
    'africa/johannesburg': 120,
    'africa/cairo': 120,
    'africa/lagos': 60,
    'africa/accra': 0,
    'africa/casablanca': 60,
    'europe/istanbul': 180,
    'europe/moscow': 180,
    'europe/athens': 120,
    'europe/helsinki': 120,
    'europe/kiev': 120,
    'europe/kyiv': 120,
    'america/sao_paulo': -180,
    'america/argentina/buenos_aires': -180,
    'america/bogota': -300,
    'america/lima': -300,
    'america/panama': -300,
    'america/mexico_city': -360,
    'australia/brisbane': 600,
    'australia/perth': 480,
    'pacific/guam': 600,
    'pacific/port_moresby': 600,
    'pacific/honolulu': -600,
    'pacific/fiji': 720,
    'atlantic/reykjavik': 0,
    'utc': 0,
    'gmt': 0,
    'etc/utc': 0,
    'etc/gmt': 0,
    'z': 0,
  };

  /// 可在界面上直接选择的时区（本地 + 固定偏移 + 常用 IANA）。
  static const List<String> selectable = <String>[
    'local',
    'UTC',
    'Asia/Shanghai',
    'Asia/Tokyo',
    'Asia/Seoul',
    'Asia/Singapore',
    'Asia/Kolkata',
    'Asia/Dubai',
    'Europe/Moscow',
    'Europe/Istanbul',
    'Australia/Brisbane',
    'America/Sao_Paulo',
  ];

  /// 是否受支持（供 UI 做校验，不抛异常）。
  static bool isSupported(String raw) {
    try {
      parse(raw);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// 解析时区名称。无法确定偏移时抛 [FormatException]，绝不静默按 UTC 计算。
  ///
  /// 支持：`local` / `UTC` / `GMT` / `Asia/Shanghai`（无 DST 表内）/ `UTC+8` /
  /// `UTC+08:00` / `GMT-5` / `+08:00`。
  static RoutineZone parse(String raw) {
    final String text = raw.trim();
    if (text.isEmpty || text.toLowerCase() == 'local') {
      return deviceLocal;
    }
    final String lower = text.toLowerCase();
    final int? iana = _ianaFixed[lower];
    if (iana != null) {
      if (iana == 0) return utc;
      return RoutineZone._(text, iana);
    }
    final RegExpMatch? m = RegExp(
      r'^(?:UTC|GMT)?\s*([+-])(\d{1,2})(?::?(\d{2}))?$',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) {
      final int sign = m.group(1) == '-' ? -1 : 1;
      final int hour = int.parse(m.group(2)!);
      final int minute = int.tryParse(m.group(3) ?? '0') ?? 0;
      if (hour > 14 || minute > 59) {
        throw FormatException('时区偏移超出范围：$text');
      }
      final int offset = sign * (hour * 60 + minute);
      if (offset == 0) return utc;
      return RoutineZone._(text, offset);
    }
    throw FormatException('暂不支持该时区：$text');
  }

  /// 把某一瞬间换算成该时区的「墙上时间」（只取年月日时分秒，不携带偏移）。
  DateTime wallOf(DateTime instant) {
    if (local) return instant.toLocal();
    return instant.toUtc().add(Duration(minutes: offsetMinutes));
  }

  /// 把墙上时间换算成真实瞬间（UTC）。设备本地时区由 Dart 处理 DST；
  /// 固定偏移没有 DST。夏令时缺口里的时间会返回规范化后的偏移结果，
  /// 调用方可用 [wallOf] 回读校验并跳过不存在的时刻。
  DateTime instantOf(DateTime wall) {
    if (local) {
      return DateTime(
        wall.year,
        wall.month,
        wall.day,
        wall.hour,
        wall.minute,
        wall.second,
        wall.millisecond,
        wall.microsecond,
      );
    }
    return DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
      wall.microsecond,
    ).subtract(Duration(minutes: offsetMinutes));
  }

  /// 展示用：`每天 09:00（Asia/Shanghai）`。
  String labelFor(String cronLabel) => '$cronLabel（$label）';

  @override
  String toString() => label;
}

/// 单个 cron 字段解析结果（内部结构，但作为 [CronExpression] 的公开字段类型）。
class CronField {
  CronField(this.values, this.restricted);

  final Set<int> values;
  final bool restricted;

  bool matches(int value) => values.contains(value);
}

/// 5 段 cron 表达式。
class CronExpression {
  CronExpression._({
    required this.minutes,
    required this.hours,
    required this.daysOfMonth,
    required this.months,
    required this.daysOfWeek,
  });

  final CronField minutes;
  final CronField hours;
  final CronField daysOfMonth;
  final CronField months;
  final CronField daysOfWeek;

  /// 单个 cron 最多向后搜索 10 年（覆盖 2 月 29 日这类稀疏表达式）。
  static const int _maxDays = 366 * 10;

  /// 解析 5 段 cron；非法时抛 [FormatException]。
  static CronExpression parse(String raw) {
    final String text = raw.trim();
    if (isOneShotCron(text)) {
      throw FormatException('@once 不是可重复计算的 cron 表达式');
    }
    final List<String> parts = text.split(RegExp(r'\s+'));
    if (parts.length != 5) {
      throw const FormatException('cron 表达式必须为 5 段：分 时 日 月 周');
    }
    return CronExpression._(
      minutes: _parseField(parts[0], 0, 59, name: '分钟'),
      hours: _parseField(parts[1], 0, 23, name: '小时'),
      daysOfMonth: _parseField(parts[2], 1, 31, name: '日期'),
      months: _parseField(parts[3], 1, 12, name: '月份'),
      daysOfWeek: _parseField(parts[4], 0, 7, name: '星期', dayOfWeek: true),
    );
  }

  /// 语法是否合法。
  static bool isValid(String raw) {
    try {
      parse(raw);
      return true;
    } on FormatException {
      return false;
    }
  }

  static CronField _parseField(
    String expr,
    int min,
    int max, {
    required String name,
    bool dayOfWeek = false,
  }) {
    final String text = expr.trim();
    if (text.isEmpty) throw FormatException('$name字段为空');
    final Set<int> out = <int>{};
    for (final String part in text.split(',')) {
      final String p = part.trim();
      if (p.isEmpty) throw FormatException('$name字段包含空项');
      int step = 1;
      String base = p;
      final int slash = p.indexOf('/');
      if (slash >= 0) {
        base = p.substring(0, slash).trim();
        final int? parsedStep = int.tryParse(p.substring(slash + 1).trim());
        if (parsedStep == null || parsedStep <= 0) {
          throw FormatException('$name步长无效：$p');
        }
        step = parsedStep;
      }
      int start;
      int end;
      if (base == '*') {
        start = min;
        end = max;
      } else if (base.contains('-')) {
        final List<String> range = base.split('-');
        if (range.length != 2) throw FormatException('$name范围无效：$p');
        final int? a = int.tryParse(range[0].trim());
        final int? b = int.tryParse(range[1].trim());
        if (a == null || b == null) throw FormatException('$name范围无效：$p');
        start = a;
        end = b;
      } else {
        final int? value = int.tryParse(base);
        if (value == null) throw FormatException('$name包含非数字：$p');
        start = value;
        end = value;
      }
      if (start < min || end > max || start > end) {
        throw FormatException('$name超出范围 $min-$max：$p');
      }
      for (int v = start; v <= end; v += step) {
        out.add(dayOfWeek && v == 7 ? 0 : v);
      }
    }
    // 覆盖整个字段（如 `0-7`、`1-31`）等价于 `*`，不应触发「日/周同时受限」的或语义。
    final bool full = dayOfWeek
        ? out.containsAll(<int>{0, 1, 2, 3, 4, 5, 6})
        : out.length == max - min + 1;
    return CronField(out, !full);
  }

  /// 日期是否匹配（日与周同时受限时按 cron 传统取「或」）。
  bool matchesDate(DateTime day) {
    if (!months.matches(day.month)) return false;
    final bool dom = daysOfMonth.matches(day.day);
    final bool dow = daysOfWeek.matches(day.weekday % 7);
    if (daysOfMonth.restricted && daysOfWeek.restricted) return dom || dow;
    if (daysOfMonth.restricted) return dom;
    if (daysOfWeek.restricted) return dow;
    return true;
  }

  /// 返回严格晚于 [from] 的下一次触发瞬间（UTC）；没有则返回 null。
  DateTime? nextAfter(DateTime from, RoutineZone zone) {
    final DateTime wall = zone.wallOf(from);
    final List<int> hourValues = hours.values.toList()..sort();
    final List<int> minuteValues = minutes.values.toList()..sort();
    for (int dayOffset = 0; dayOffset <= _maxDays; dayOffset++) {
      final DateTime day = DateTime(
        wall.year,
        wall.month,
        wall.day + dayOffset,
      );
      if (!matchesDate(day)) continue;
      for (final int h in hourValues) {
        if (dayOffset == 0 && h < wall.hour) continue;
        for (final int m in minuteValues) {
          if (dayOffset == 0 && h == wall.hour && m <= wall.minute) continue;
          final DateTime candidateWall =
              DateTime(day.year, day.month, day.day, h, m);
          final DateTime instant = zone.instantOf(candidateWall);
          final DateTime back = zone.wallOf(instant);
          // 夏令时缺口里的墙上时间不存在，回读会落到别的时刻，跳过。
          if (back.day != day.day ||
              back.hour != h ||
              back.minute != m ||
              back.month != day.month) {
            continue;
          }
          if (instant.isAfter(from)) return instant.toUtc();
        }
      }
    }
    return null;
  }
}

/// 预设频率。
enum CronFreq { hourly, daily, weekdays, weekly, monthly, interval, advanced, once }

/// 间隔单位。
enum CronUnit { minutes, hours, days }

const Map<CronUnit, int> cronIntervalMax = <CronUnit, int>{
  CronUnit.minutes: 59,
  CronUnit.hours: 23,
  CronUnit.days: 31,
};

const List<int> _intervalAmounts = <int>[1, 2, 3, 5, 10, 15, 30, 45];

/// 某个单位下可选的间隔数量（cron 步长不能超过字段范围）。
List<int> cronIntervalAmounts(CronUnit unit, [int? current]) {
  final int max = cronIntervalMax[unit]!;
  final List<int> amounts =
      _intervalAmounts.where((int n) => n <= max).toList(growable: true);
  if (current == null || current > max || amounts.contains(current)) {
    return amounts;
  }
  return <int>[...amounts, current]..sort();
}

/// 把间隔夹到该单位的合法上限。
int clampIntervalAmount(int n, CronUnit unit) {
  final int max = cronIntervalMax[unit]!;
  if (n <= max) return n;
  final List<int> amounts = cronIntervalAmounts(unit);
  return amounts.isEmpty ? 1 : amounts.last;
}

/// 界面预设值。`time` 为 24 小时制 `HH:mm`。
class CronPreset {
  const CronPreset({
    required this.freq,
    this.n = 3,
    this.unit = CronUnit.minutes,
    this.hour = 9,
    this.minute = 0,
    this.cron = '',
  });

  final CronFreq freq;
  final int n;
  final CronUnit unit;
  final int hour;
  final int minute;
  final String cron;

  factory CronPreset.defaultPreset() => const CronPreset(freq: CronFreq.daily);

  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  CronPreset copyWith({
    CronFreq? freq,
    int? n,
    CronUnit? unit,
    int? hour,
    int? minute,
    String? cron,
  }) {
    return CronPreset(
      freq: freq ?? this.freq,
      n: n ?? this.n,
      unit: unit ?? this.unit,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      cron: cron ?? this.cron,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'freq': freq.name,
        'n': n,
        'unit': unit.name,
        'time': timeLabel,
        'cron': cron,
      };

  static CronPreset fromJson(Map<String, dynamic> raw) {
    final String freqName = (raw['freq'] ?? '').toString();
    final CronFreq freq = CronFreq.values.firstWhere(
      (CronFreq f) => f.name == freqName,
      orElse: () => CronFreq.daily,
    );
    final String unitName = (raw['unit'] ?? '').toString();
    final CronUnit unit = CronUnit.values.firstWhere(
      (CronUnit u) => u.name == unitName,
      orElse: () => CronUnit.minutes,
    );
    final String time = (raw['time'] ?? '09:00').toString();
    final RegExpMatch? mt =
        RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(time.trim());
    return CronPreset(
      freq: freq,
      n: raw['n'] is num ? (raw['n'] as num).toInt() : 3,
      unit: unit,
      hour: int.tryParse(mt?.group(1) ?? '') ?? 9,
      minute: int.tryParse(mt?.group(2) ?? '') ?? 0,
      cron: (raw['cron'] ?? '').toString(),
    );
  }
}

/// 预设 → cron。
String cronFromPreset(CronPreset preset) {
  final String advanced = preset.cron.trim();
  switch (preset.freq) {
    case CronFreq.advanced:
      if (advanced.isNotEmpty && isOneShotCron(advanced)) return onceCron;
      return advanced.isEmpty ? '*/3 * * * *' : advanced;
    case CronFreq.once:
      return onceCron;
    case CronFreq.hourly:
      return '0 * * * *';
    case CronFreq.interval:
      final int n = preset.n > 0 ? preset.n : 5;
      switch (preset.unit) {
        case CronUnit.days:
          return '0 0 */$n * *';
        case CronUnit.hours:
          return '0 */$n * * *';
        case CronUnit.minutes:
          return '*/$n * * * *';
      }
    case CronFreq.weekdays:
      return '${preset.minute} ${preset.hour} * * 1-5';
    case CronFreq.weekly:
      return '${preset.minute} ${preset.hour} * * 1';
    case CronFreq.monthly:
      return '${preset.minute} ${preset.hour} 1 * *';
    case CronFreq.daily:
      return '${preset.minute} ${preset.hour} * * *';
  }
}

int? _stepValue(String expr) {
  final RegExpMatch? m = RegExp(r'^\*/(\d+)$').firstMatch(expr);
  if (m == null) return null;
  final int? n = int.tryParse(m.group(1)!);
  return n != null && n > 0 ? n : null;
}

bool _isInt(String expr) => RegExp(r'^\d+$').hasMatch(expr);

bool _isClock(String minute, String hour) =>
    _isInt(minute) &&
    int.parse(minute) <= 59 &&
    _isInt(hour) &&
    int.parse(hour) <= 23;

/// cron → 最接近的预设；无法归类的进入「高级」。
CronPreset presetFromCron(String cron) {
  final CronPreset base = CronPreset.defaultPreset();
  final String trimmed = cron.trim();
  if (isOneShotCron(trimmed)) {
    return base.copyWith(freq: CronFreq.advanced, cron: onceCron);
  }
  final List<String> parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length < 5) {
    return base.copyWith(freq: CronFreq.advanced, cron: trimmed);
  }
  final String minute = parts[0];
  final String hour = parts[1];
  final String day = parts[2];
  final String month = parts[3];
  final String dow = parts[4];
  if (month != '*') {
    return base.copyWith(freq: CronFreq.advanced, cron: trimmed);
  }
  final int? minuteStep = _stepValue(minute);
  final int? hourStep = _stepValue(hour);
  final int? dayStep = _stepValue(day);
  if (minute == '0' && hour == '*' && day == '*' && dow == '*') {
    return base.copyWith(freq: CronFreq.hourly);
  }
  if (minuteStep != null && hour == '*' && day == '*' && dow == '*') {
    return base.copyWith(
      freq: CronFreq.interval,
      n: minuteStep,
      unit: CronUnit.minutes,
    );
  }
  if (minute == '0' &&
      hourStep != null &&
      day == '*' &&
      dow == '*') {
    return base.copyWith(
      freq: CronFreq.interval,
      n: hourStep,
      unit: CronUnit.hours,
    );
  }
  if (minute == '0' && hour == '0' && dayStep != null && dow == '*') {
    return base.copyWith(
      freq: CronFreq.interval,
      n: dayStep,
      unit: CronUnit.days,
    );
  }
  if (!_isClock(minute, hour)) {
    return base.copyWith(freq: CronFreq.advanced, cron: trimmed);
  }
  final int h = int.parse(hour);
  final int m = int.parse(minute);
  if (day == '*' && dow == '1-5') {
    return base.copyWith(freq: CronFreq.weekdays, hour: h, minute: m);
  }
  if (day == '*' && dow == '1') {
    return base.copyWith(freq: CronFreq.weekly, hour: h, minute: m);
  }
  if (day == '1' && dow == '*') {
    return base.copyWith(freq: CronFreq.monthly, hour: h, minute: m);
  }
  if (day == '*' && dow == '*') {
    return base.copyWith(freq: CronFreq.daily, hour: h, minute: m);
  }
  return base.copyWith(freq: CronFreq.advanced, cron: trimmed);
}

String _two(int n) => n.toString().padLeft(2, '0');

const List<String> _weekdayNames = <String>[
  '周日',
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
];

/// 把 cron 转成中文说明；无法识别的形状保留 `Cron <expr>`。
String formatCron(String cron) {
  final String trimmed = cron.trim();
  if (isOneShotCron(trimmed)) return '一次性';
  final String? described = _describeCronFields(trimmed);
  if (described != null) return described;
  final CronPreset p = presetFromCron(trimmed);
  switch (p.freq) {
    case CronFreq.hourly:
      return '每小时';
    case CronFreq.daily:
      return '每天 ${p.timeLabel}';
    case CronFreq.weekdays:
      return '工作日 ${p.timeLabel}';
    case CronFreq.weekly:
      return '每周一 ${p.timeLabel}';
    case CronFreq.monthly:
      return '每月 1 日 ${p.timeLabel}';
    case CronFreq.interval:
      switch (p.unit) {
        case CronUnit.minutes:
          return '每 ${p.n} 分钟';
        case CronUnit.hours:
          return '每 ${p.n} 小时';
        case CronUnit.days:
          return '每 ${p.n} 天';
      }
    case CronFreq.advanced:
      return 'Cron ${p.cron.isEmpty ? trimmed : p.cron}';
    case CronFreq.once:
      return '一次性';
  }
}

/// 多时间表展示：`每天 09:00、周五 18:00`。
String formatCrons(List<String> crons) {
  if (crons.isEmpty) return '未设置时间表';
  return crons.map(formatCron).join('、');
}

String? _describeCronFields(String cron) {
  final List<String> parts = cron.split(RegExp(r'\s+'));
  if (parts.length != 5) return null;
  final String minute = parts[0];
  final String hour = parts[1];
  final String day = parts[2];
  final String month = parts[3];
  final String dow = parts[4];
  if (month != '*') return null;
  if (hour == '*' &&
      day == '*' &&
      dow == '*' &&
      _isInt(minute)) {
    final int m = int.parse(minute);
    return m >= 1 && m <= 59 ? '每小时第 $m 分' : null;
  }
  final int? hours = _stepValue(hour);
  if (hours != null && day == '*' && dow == '*' && _isInt(minute)) {
    final int m = int.parse(minute);
    if (hours >= 2 && hours < 24 && 24 % hours == 0 && m >= 1 && m <= 59) {
      return '每 $hours 小时第 $m 分';
    }
    return null;
  }
  if (!_isClock(minute, hour)) return null;
  final String time = '${_two(int.parse(hour))}:${_two(int.parse(minute))}';
  if (day == '*' && dow != '*') {
    final Set<int>? days = _cronWeekdays(dow);
    if (days == null) return null;
    return '${_describeWeekdays(days)} $time';
  }
  if (dow == '*' && _isInt(day)) {
    final int d = int.parse(day);
    if (d >= 1 && d <= 31) return '每月 $d 日 $time';
  }
  return null;
}

Set<int>? _cronWeekdays(String field) {
  final Set<int> days = <int>{};
  for (final String part in field.split(',')) {
    final RegExpMatch? m = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(part);
    if (m == null) return null;
    final int from = int.parse(m.group(1)!);
    final int to = m.group(2) == null ? from : int.parse(m.group(2)!);
    if (from > to || to > 7) return null;
    for (int d = from; d <= to; d++) {
      days.add(d % 7);
    }
  }
  return days;
}

String _describeWeekdays(Set<int> days) {
  if (days.length == 7) return '每天';
  if (days.length == 5 && !days.contains(0) && !days.contains(6)) {
    return '工作日';
  }
  if (days.length == 2 && days.contains(0) && days.contains(6)) {
    return '周末';
  }
  // 周一优先，让周五到周日读起来是连续的。
  const List<int> order = <int>[1, 2, 3, 4, 5, 6, 0];
  final List<int> ordered =
      order.where((int d) => days.contains(d)).toList(growable: false);
  if (ordered.length >= 3) {
    final int span =
        order.indexOf(ordered.last) - order.indexOf(ordered.first);
    if (span == ordered.length - 1) {
      return '${_weekdayNames[ordered.first]}至${_weekdayNames[ordered.last]}';
    }
  }
  return '每${ordered.map((int d) => _weekdayNames[d]).join('、')}';
}

/// 严格晚于 [from] 的下一次 cron 触发；`@once` 或非法表达式返回 null。
DateTime? nextCronDate(String cron, DateTime from, RoutineZone zone) {
  if (isOneShotCron(cron)) return null;
  try {
    return CronExpression.parse(cron).nextAfter(from, zone);
  } on FormatException {
    return null;
  }
}

/// 多时间表里最近的一次；忽略 `@once` 与非法表达式。
DateTime? nextCronDateAcross(
  List<String> crons,
  DateTime from,
  RoutineZone zone,
) {
  DateTime? earliest;
  for (final String cron in crons) {
    final DateTime? next = nextCronDate(cron, from, zone);
    if (next == null) continue;
    if (earliest == null || next.isBefore(earliest)) earliest = next;
  }
  return earliest;
}

/// 严格校验：任一重复时间表非法就抛出，避免落库后永远不触发。
DateTime? nextCronDateAcrossStrict(
  List<String> crons,
  DateTime from,
  RoutineZone zone,
) {
  DateTime? earliest;
  for (final String cron in crons) {
    if (isOneShotCron(cron)) continue;
    final DateTime? next = CronExpression.parse(cron).nextAfter(from, zone);
    if (next == null) {
      throw FormatException('cron 没有未来的触发时间：$cron');
    }
    if (earliest == null || next.isBefore(earliest)) earliest = next;
  }
  return earliest;
}

/// 非整除步长（如 `*/7` 分钟、`*/5` 小时）按锚点递推，而不是在每个字段
/// 边界重新开始。返回 null 表示这是普通 cron，应按墙上时间匹配。
CronPreset? unevenInterval(String cron) {
  final List<String> parts = cron.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return null;
  final CronPreset preset = presetFromCron(cron);
  if (preset.freq != CronFreq.interval) return null;
  final int max = cronIntervalMax[preset.unit]!;
  if (preset.n > max) return null;
  switch (preset.unit) {
    case CronUnit.minutes:
      return 60 % preset.n == 0 ? null : preset;
    case CronUnit.hours:
      return 24 % preset.n == 0 ? null : preset;
    case CronUnit.days:
      return preset.n == 1 ? null : preset;
  }
}

/// 单个时间表从 [anchor] 起按相位推算的下一次运行。
DateTime? nextRoutineRunDate(
  String cron,
  DateTime anchor,
  DateTime now,
  RoutineZone zone,
) {
  final DateTime from = anchor.isAfter(now) ? anchor : now;
  final CronPreset? preset = unevenInterval(cron);
  if (preset == null) return nextCronDate(cron, from, zone);
  if (preset.unit == CronUnit.minutes || preset.unit == CronUnit.hours) {
    final int gapMs = preset.n *
        (preset.unit == CronUnit.hours ? 3600000 : 60000);
    final int anchorMs = anchor.millisecondsSinceEpoch;
    final int fromMs = from.millisecondsSinceEpoch;
    int steps = ((fromMs - anchorMs) / gapMs).floor() + 1;
    if (steps < 1) steps = 1;
    return DateTime.fromMillisecondsSinceEpoch(
      anchorMs + steps * gapMs,
      isUtc: true,
    );
  }
  // 天间隔：保持锚点的时刻（通常是 00:00），按自然日递增。
  final DateTime anchorWall = zone.wallOf(anchor);
  for (int steps = 1; steps <= 10000; steps++) {
    final DateTime day = DateTime(
      anchorWall.year,
      anchorWall.month,
      anchorWall.day + steps * preset.n,
    );
    final DateTime candidateWall = DateTime(
      day.year,
      day.month,
      day.day,
      anchorWall.hour,
      anchorWall.minute,
    );
    final DateTime instant = zone.instantOf(candidateWall);
    if (instant.isAfter(from)) return instant.toUtc();
  }
  return null;
}

/// 多时间表的下一次运行；单一重复时间表保留间隔相位。
DateTime? nextRoutineRunDateAcross(
  List<String> crons,
  DateTime anchor,
  DateTime now,
  RoutineZone zone,
) {
  final List<String> recurring =
      crons.where((String c) => !isOneShotCron(c)).toList(growable: false);
  if (recurring.isEmpty) return null;
  if (recurring.length == 1) {
    return nextRoutineRunDate(recurring.first, anchor, now, zone);
  }
  DateTime? earliest;
  for (final String cron in recurring) {
    final DateTime? next = nextCronDate(cron, now, zone);
    if (next == null) continue;
    if (earliest == null || next.isBefore(earliest)) earliest = next;
  }
  return earliest;
}

/// 超过 5 分钟宽限仍未运行 → 视为调度延迟（不是失败诊断）。
bool routineScheduleDelayed(
  bool active,
  DateTime? nextRunAt,
  DateTime now,
) {
  if (!active || nextRunAt == null) return false;
  return now.difference(nextRunAt).inMilliseconds > 5 * 60 * 1000;
}

/// 紧凑耗时：`850ms` / `4.2s` / `1m 05s`；无有效耗时时返回 null。
String? compactDuration(num? durationMs) {
  if (durationMs == null || durationMs.isNaN || durationMs < 0) return null;
  final double ms = durationMs.toDouble();
  if (ms < 1000) return '${ms.round()}ms';
  if (ms < 10000) {
    final double seconds = (ms / 100).round() / 10;
    return seconds == seconds.roundToDouble()
        ? '${seconds.round()}s'
        : '${seconds.toStringAsFixed(1)}s';
  }
  if (ms < 60000) return '${(ms / 1000).round()}s';
  final int totalSeconds = (ms / 1000).round();
  final int minutes = totalSeconds ~/ 60;
  final int seconds = totalSeconds % 60;
  return '${minutes}m ${_two(seconds)}s';
}

/// 运行迟到时长；准时返回 null。
({String unit, int count})? routineRunLateness(
  DateTime? lateSince,
  DateTime? startedAt,
) {
  if (lateSince == null || startedAt == null) return null;
  final int minutes = startedAt.difference(lateSince).inMinutes;
  if (minutes <= 0) return null;
  if (minutes < 60) return (unit: '分钟', count: minutes);
  final int hours = minutes ~/ 60;
  if (hours < 24) return (unit: '小时', count: hours);
  return (unit: '天', count: hours ~/ 24);
}

/// 运行时间展示：`10-25 09:00`，跨年补年份。
String formatRunAt(DateTime at, {DateTime? now}) {
  final DateTime local = at.toLocal();
  final DateTime current = (now ?? DateTime.now()).toLocal();
  final String date = local.year == current.year
      ? '${_two(local.month)}-${_two(local.day)}'
      : '${local.year}-${_two(local.month)}-${_two(local.day)}';
  return '$date ${_two(local.hour)}:${_two(local.minute)}';
}
