/// 「爱阳光跑」——GPS 轨迹与运动数据模拟引擎。
///
/// 纯 Dart 实现（除 [HarnessStore] 外零依赖）：不引入任何第三方包，
/// 所有随机数都由 `seed` 驱动，同一 seed + 同一 dt 序列可复现。
///
/// 真实感来自组合模型，而不是「固定速度 + 随机抖动」：
/// - 加速度受限的平滑速度（走/跑 0.8 m/s²、骑行 1.2 m/s²）；
/// - 疲劳线性衰减、10–20s 配速因子波动、红绿灯减速停车再起步；
/// - 东北向 OU 过程模拟 GPS 噪声，叠加多径突发与慢漂移高度；
/// - 卫星数/可用数/载噪比偶发跳变；bearing 由路线切线 + 噪声得到。
///
/// [SunRunRuntime] 是供插件与 UI 共用的单例：真实 1s Timer 推进引擎，
/// stop 时把会话摘要写入 `sun_run/history.json`（保留最近 50 条）。
/// 页面关闭不会停止运行；App 重启后单例回到 idle，不伪造「仍在运行」。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/sun_run_native.dart';

// ---------------------------------------------------------------------------
// 1. 模型
// ---------------------------------------------------------------------------

/// 运动模式：中文标签 / 基础速度 / MET。
enum SunRunMode {
  walk('步行', 1.35, 3.5),
  run('跑步', 2.9, 8.3),
  ride('骑行', 4.8, 6.8);

  const SunRunMode(this.label, this.baseSpeedMps, this.met);

  final String label;
  final double baseSpeedMps;
  final double met;

  static SunRunMode parse(Object? raw) {
    final String name = (raw ?? '').toString();
    for (final SunRunMode m in values) {
      if (m.name == name || m.label == name) return m;
    }
    return SunRunMode.run;
  }
}

double _asDouble(Object? raw, double fallback) {
  if (raw is num && raw.isFinite) return raw.toDouble();
  if (raw is String) {
    final double? parsed = double.tryParse(raw.trim());
    if (parsed != null && parsed.isFinite) return parsed;
  }
  return fallback;
}

int _asInt(Object? raw, int fallback) {
  if (raw is num && raw.isFinite) return raw.toInt();
  if (raw is String) {
    final int? parsed = int.tryParse(raw.trim());
    if (parsed != null) return parsed;
  }
  return fallback;
}

/// 一次模拟的完整配置。全部字段可直接 JSON 往返。
class SunRunConfig {
  const SunRunConfig({
    this.mode = SunRunMode.run,
    this.targetKm = 5,
    this.paceSecPerKm = 0,
    this.startLat = 39.9042,
    this.startLng = 116.4074,
    this.seed = 20261119,
    this.loop = true,
    this.realism = 0.75,
    this.weightKg = 65,
  });

  final SunRunMode mode;
  final double targetKm;

  /// 目标配速（秒/公里）；0 表示按 [mode] 的默认速度。
  final int paceSecPerKm;
  final double startLat;
  final double startLng;
  final int seed;
  final bool loop;

  /// 真实感强度 0..1：影响 GPS 噪声幅度与疲劳程度。
  final double realism;
  final double weightKg;

  factory SunRunConfig.fromJson(Map<String, dynamic> json) => SunRunConfig(
        mode: SunRunMode.parse(json['mode']),
        targetKm: _asDouble(json['targetKm'] ?? json['target_km'], 5),
        paceSecPerKm: _asInt(
            json['paceSecPerKm'] ?? json['pace_sec_per_km'], 0),
        startLat: _asDouble(json['startLat'] ?? json['start_lat'], 39.9042),
        startLng: _asDouble(json['startLng'] ?? json['start_lng'], 116.4074),
        seed: _asInt(json['seed'], 20261119),
        loop: json['loop'] is bool ? json['loop'] as bool : true,
        realism:
            _asDouble(json['realism'], 0.75).clamp(0.0, 1.0).toDouble(),
        weightKg: _asDouble(json['weightKg'] ?? json['weight_kg'], 65),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.name,
        'targetKm': targetKm,
        'paceSecPerKm': paceSecPerKm,
        'startLat': startLat,
        'startLng': startLng,
        'seed': seed,
        'loop': loop,
        'realism': realism,
        'weightKg': weightKg,
      };
}

/// 每一个采样点的完整 GNSS 轨迹固定数据。
class SunRunFix {
  const SunRunFix({
    required this.ts,
    required this.lat,
    required this.lng,
    required this.altitude,
    required this.speedMps,
    required this.bearingDeg,
    required this.accuracyM,
    required this.verticalAccuracyM,
    required this.satellites,
    required this.satellitesUsed,
    required this.cn0,
    required this.distanceM,
    required this.elapsedSec,
  });

  final DateTime ts;
  final double lat;
  final double lng;
  final double altitude;
  final double speedMps;
  final double bearingDeg;
  final double accuracyM;
  final double verticalAccuracyM;
  final int satellites;
  final int satellitesUsed;
  final double cn0;
  final double distanceM;
  final double elapsedSec;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ts': ts.toIso8601String(),
        'lat': lat,
        'lng': lng,
        'altitude': altitude,
        'speedMps': speedMps,
        'bearingDeg': bearingDeg,
        'accuracyM': accuracyM,
        'verticalAccuracyM': verticalAccuracyM,
        'satellites': satellites,
        'satellitesUsed': satellitesUsed,
        'cn0': cn0,
        'distanceM': distanceM,
        'elapsedSec': elapsedSec,
      };
}

/// 聚合统计（运行时状态 / 会话摘要共用）。
class SunRunStats {
  const SunRunStats({
    required this.distanceM,
    required this.elapsedSec,
    required this.speedMps,
    required this.paceSecPerKm,
    required this.calories,
    required this.steps,
    required this.cadence,
    required this.fixes,
    required this.state,
  });

  final double distanceM;
  final double elapsedSec;
  final double speedMps;
  final double paceSecPerKm;
  final double calories;
  final double steps;
  final double cadence;
  final int fixes;
  final String state;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'distanceM': distanceM,
        'elapsedSec': elapsedSec,
        'speedMps': speedMps,
        'paceSecPerKm': paceSecPerKm,
        'calories': calories,
        'steps': steps,
        'cadence': cadence,
        'fixes': fixes,
        'state': state,
      };
}

// ---------------------------------------------------------------------------
// 2. 确定性随机数（跨平台可复现，不依赖 dart:math Random 的实现细节）
// ---------------------------------------------------------------------------

class _Rng {
  _Rng(int seed) : _state = (seed.abs() % 0xFFFFFFFF) + 1;

  int _state;

  int _next32() {
    int x = _state & 0xFFFFFFFF;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    _state = x & 0xFFFFFFFF;
    return _state;
  }

  double nextDouble() => _next32() / 4294967296.0;

  double range(double a, double b) => a + nextDouble() * (b - a);

  int intRange(int a, int b) {
    if (b <= a) return a;
    return a + (_next32() % (b - a + 1));
  }

  /// Box-Muller 标准正态；每次消耗 2 个均匀数。
  double gauss() {
    double u1 = nextDouble();
    if (u1 < 1e-12) u1 = 1e-12;
    final double u2 = nextDouble();
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2);
  }
}

// ---------------------------------------------------------------------------
// 3. 地理工具 + 路线
// ---------------------------------------------------------------------------

const double _earthRadiusM = 6371000.0;

/// 两点球面距离（米）。供热力图与测试复用。
double sunRunHaversine(double lat1, double lng1, double lat2, double lng2) {
  final double dLat = (lat2 - lat1) * math.pi / 180.0;
  final double dLng = (lng2 - lng1) * math.pi / 180.0;
  final double a = (math.sin(dLat / 2) * math.sin(dLat / 2) +
          math.cos(lat1 * math.pi / 180.0) *
              math.cos(lat2 * math.pi / 180.0) *
              math.sin(dLng / 2) *
              math.sin(dLng / 2))
      .clamp(0.0, 1.0)
      .toDouble();
  return 2 * _earthRadiusM * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class _LocalFrame {
  _LocalFrame(this.lat0, this.lng0);

  final double lat0;
  final double lng0;
  static const double mPerDegLat = 111320.0;
  late final double mPerDegLng = mPerDegLat *
      math.cos(lat0 * math.pi / 180.0).abs().clamp(0.05, 1.0).toDouble();

  Map<String, double> toLatLng(double east, double north) => <String, double>{
        'lat': lat0 + north / mPerDegLat,
        'lng': lng0 + east / mPerDegLng,
      };
}

class _XY {
  const _XY(this.x, this.y);
  final double x;
  final double y;
}

class _RoutePoint {
  _RoutePoint({
    required this.lat,
    required this.lng,
    required this.distanceM,
    required this.bearing,
  });

  final double lat;
  final double lng;
  final double distanceM;
  final double bearing;

  _RoutePoint copyWith({double? lat, double? lng, double? bearing}) =>
      _RoutePoint(
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        distanceM: distanceM,
        bearing: bearing ?? this.bearing,
      );
}

/// 由 seed 生成、按约 5m 重采样的路线。
///
/// loop=true：极坐标 Fourier 半径扰动形成闭合星形曲线，径向函数恒正，
/// 因此曲线不会自交；loop=false：x 单调递增的蜿蜒折线（点到点）。
class SunRunRoute {
  SunRunRoute._(this._points, this.lengthM, this.isLoop);

  final List<_RoutePoint> _points;
  final double lengthM;
  final bool isLoop;

  int get pointCount => _points.length;

  Map<String, double> get startPoint =>
      <String, double>{'lat': _points.first.lat, 'lng': _points.first.lng};

  Map<String, double> get endPoint =>
      <String, double>{'lat': _points.last.lat, 'lng': _points.last.lng};

  factory SunRunRoute.generate(SunRunConfig config) {
    final _Rng rng = _Rng(config.seed * 2654435761 + 97);
    final _LocalFrame frame = _LocalFrame(config.startLat, config.startLng);
    final double targetM =
        (config.targetKm * 1000).clamp(200.0, 100000.0).toDouble();
    final List<_XY> dense = <_XY>[];

    if (config.loop) {
      // 星形径向函数：r(θ)=R(1+Σ ak·cos(kθ+φk))，Σak < 0.35 保证不自交。
      final double baseR = rng.range(260, 420);
      final double a2 = rng.range(0.05, 0.11);
      final double a3 = rng.range(0.03, 0.07);
      final double a4 = rng.range(0.02, 0.045);
      final double a5 = rng.range(0.01, 0.025);
      final double p2 = rng.range(0, 2 * math.pi);
      final double p3 = rng.range(0, 2 * math.pi);
      final double p4 = rng.range(0, 2 * math.pi);
      final double p5 = rng.range(0, 2 * math.pi);
      const int n = 1440;
      for (int i = 0; i < n; i++) {
        final double t = 2 * math.pi * i / n;
        final double radius = baseR *
            (1 +
                a2 * math.cos(2 * t + p2) +
                a3 * math.cos(3 * t + p3) +
                a4 * math.cos(4 * t + p4) +
                a5 * math.cos(5 * t + p5));
        dense.add(_XY(radius * math.cos(t), radius * math.sin(t)));
      }
      // 闭合：末点与首点重合。
      dense.add(_XY(dense.first.x, dense.first.y));
    } else {
      // 点到点：x 严格递增，天然不会回折自交。
      const double baseLen = 2600;
      final double p1 = rng.range(0, 2 * math.pi);
      final double p2 = rng.range(0, 2 * math.pi);
      const int n = 720;
      for (int i = 0; i <= n; i++) {
        final double t = i / n;
        final double x = baseLen * t;
        final double y = 180 *
                math.sin(2 * math.pi * 1.3 * t + p1) *
                (0.35 + 0.65 * t) +
            70 * math.sin(2 * math.pi * 2.7 * t + p2) * t;
        dense.add(_XY(x, y));
      }
    }

    double baseLength = 0;
    for (int i = 1; i < dense.length; i++) {
      final double dx = dense[i].x - dense[i - 1].x;
      final double dy = dense[i].y - dense[i - 1].y;
      baseLength += math.sqrt(dx * dx + dy * dy);
    }
    final double scale =
        baseLength <= 0 ? 1.0 : targetM / baseLength;
    final List<_XY> world = <_XY>[
      for (final _XY p in dense) _XY(p.x * scale, p.y * scale),
    ];
    final List<double> cum = <double>[0];
    for (int i = 1; i < world.length; i++) {
      final double dx = world[i].x - world[i - 1].x;
      final double dy = world[i].y - world[i - 1].y;
      cum.add(cum[i - 1] + math.sqrt(dx * dx + dy * dy));
    }
    final double total = cum.last;

    _RoutePoint sampleAt(double d) {
      final double clamped = d.clamp(0.0, total).toDouble();
      int lo = 0;
      int hi = world.length - 1;
      while (lo + 1 < hi) {
        final int mid = (lo + hi) >> 1;
        if (cum[mid] <= clamped) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      final double span = cum[hi] - cum[lo];
      final double f = span <= 0
          ? 0.0
          : ((clamped - cum[lo]) / span).clamp(0.0, 1.0).toDouble();
      final double x = world[lo].x + (world[hi].x - world[lo].x) * f;
      final double y = world[lo].y + (world[hi].y - world[lo].y) * f;
      final Map<String, double> ll = frame.toLatLng(x, y);
      return _RoutePoint(
          lat: ll['lat']!, lng: ll['lng']!, distanceM: clamped, bearing: 0);
    }

    final List<_RoutePoint> points = <_RoutePoint>[];
    for (double d = 0; d < total; d += 5.0) {
      points.add(sampleAt(d));
    }
    final _RoutePoint tail = sampleAt(total);
    if (config.loop) {
      // 首尾严格重合，闭合误差为 0。
      points.add(_RoutePoint(
        lat: points.first.lat,
        lng: points.first.lng,
        distanceM: total,
        bearing: 0,
      ));
    } else {
      points.add(tail);
    }

    for (int i = 0; i < points.length; i++) {
      final _RoutePoint prev = i > 0 ? points[i - 1] : points[i];
      final _RoutePoint next =
          i < points.length - 1 ? points[i + 1] : points[i];
      final double dx = (next.lng - prev.lng) * frame.mPerDegLng;
      final double dy = (next.lat - prev.lat) * _LocalFrame.mPerDegLat;
      double bearing = math.atan2(dx, dy) * 180.0 / math.pi;
      if (bearing < 0) bearing += 360;
      points[i] = points[i].copyWith(bearing: bearing);
    }

    return SunRunRoute._(points, total, config.loop);
  }

  /// 沿路线按距离取点（loop 自动取模回绕），返回经纬度与切线方位角。
  Map<String, double> pointAt(double distanceM) {
    double d = distanceM;
    if (isLoop && lengthM > 0) {
      d = d % lengthM;
      if (d < 0) d += lengthM;
    }
    d = d.clamp(0.0, lengthM).toDouble();
    int lo = 0;
    int hi = _points.length - 1;
    while (lo + 1 < hi) {
      final int mid = (lo + hi) >> 1;
      if (_points[mid].distanceM <= d) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final _RoutePoint a = _points[lo];
    final _RoutePoint b = _points[hi];
    final double span = b.distanceM - a.distanceM;
    final double f = span <= 0
        ? 0.0
        : ((d - a.distanceM) / span).clamp(0.0, 1.0).toDouble();
    return <String, double>{
      'lat': a.lat + (b.lat - a.lat) * f,
      'lng': a.lng + (b.lng - a.lng) * f,
      'bearing': a.bearing,
    };
  }

  /// 抽稀后的路线点（UI 绘制用）。
  List<Map<String, double>> sample(int maxPoints) {
    if (maxPoints <= 1 || _points.length <= maxPoints) {
      return <Map<String, double>>[
        for (final _RoutePoint p in _points)
          <String, double>{'lat': p.lat, 'lng': p.lng},
      ];
    }
    final double stride = (_points.length - 1) / (maxPoints - 1);
    return <Map<String, double>>[
      for (int i = 0; i < maxPoints; i++)
        <String, double>{
          'lat': _points[(i * stride).round()].lat,
          'lng': _points[(i * stride).round()].lng,
        },
    ];
  }
}

// ---------------------------------------------------------------------------
// 4. 运动模型引擎
// ---------------------------------------------------------------------------

/// 单次模拟引擎：构造后从 0 开始，[tick] 推进运动并产出 [SunRunFix]。
class SunRunEngine {
  SunRunEngine(this.config, {DateTime? startTs})
      : _startTs = startTs ?? DateTime.utc(2026, 1, 1),
        route = SunRunRoute.generate(config),
        _rngPace = _Rng(config.seed * 1664525 + 1013904223),
        _rngStop = _Rng(config.seed * 1103515245 + 12345),
        _rngGps = _Rng(config.seed * 2654435761 + 7),
        _rngSat = _Rng(config.seed * 40503 + 3) {
    _realism = config.realism.clamp(0.0, 1.0).toDouble();
    _baseSpeed =
        config.paceSecPerKm > 0 ? 1000.0 / config.paceSecPerKm : config.mode.baseSpeedMps;
    _maxAccel = config.mode == SunRunMode.ride ? 1.2 : 0.8;
    _fatigueRate = 0.03 + 0.03 * _realism;
    _noiseSigma = 1.0 + 1.5 * _realism;
    _targetDistanceM =
        math.min(config.targetKm * 1000.0, route.lengthM);
    _nextPaceChange = _rngPace.range(10, 20);
    _nextStopAt = _rngStop.range(45, 120);
    _nextBurstAt = _rngGps.range(40, 90);
    _altBase = _rngGps.range(30, 80);
    _altPhase = _rngGps.range(0, 2 * math.pi);
    _satTotal = _rngSat.intRange(12, 24);
    _satUsed = math.min(_satTotal, _rngSat.intRange(9, 20));
    _cn0 = _rngSat.range(26, 46);
    _nextSatChange = _rngSat.range(30, 90);
    _lastFix = _buildFix();
  }

  final SunRunConfig config;
  final SunRunRoute route;
  final DateTime _startTs;

  final _Rng _rngPace;
  final _Rng _rngStop;
  final _Rng _rngGps;
  final _Rng _rngSat;

  late final double _realism;
  late final double _baseSpeed;
  late final double _maxAccel;
  late final double _fatigueRate;
  late final double _noiseSigma;
  late final double _targetDistanceM;

  double _speed = 0;
  double _distanceM = 0;
  double _elapsedSec = 0;
  double _paceFactor = 1;
  double _targetPaceFactor = 1;
  double _nextPaceChange = 0;

  /// 红绿灯：下一次触发时刻 / 当前剩余停顿秒数。
  double _nextStopAt = 0;
  double _stopRemaining = 0;

  // GPS 东北向 OU 噪声 + 多径突发。
  double _noiseE = 0;
  double _noiseN = 0;
  double _nextBurstAt = 0;
  double _burstRemaining = 0;
  double _burstE = 0;
  double _burstN = 0;

  double _altBase = 0;
  double _altPhase = 0;
  int _satTotal = 12;
  int _satUsed = 9;
  double _cn0 = 30;
  double _nextSatChange = 0;

  double _cadence = 0;
  double _steps = 0;
  int _fixCount = 0;
  String _state = 'running';
  SunRunFix? _lastFix;

  String get state => _state;
  SunRunFix? get currentFix => _lastFix;

  /// 与 [stats] 等价的只读状态视图（插件/工具语义）。
  SunRunStats get status => stats;

  SunRunStats get stats => SunRunStats(
        distanceM: _distanceM,
        elapsedSec: _elapsedSec,
        speedMps: _speed,
        paceSecPerKm:
            _distanceM > 1 ? _elapsedSec / _distanceM * 1000.0 : 0.0,
        calories: config.mode.met * config.weightKg * (_elapsedSec / 3600.0),
        steps: _steps,
        cadence: _cadence,
        fixes: _fixCount,
        state: _state,
      );

  void pause() {
    if (_state == 'running') _state = 'paused';
  }

  void resume() {
    if (_state == 'paused') _state = 'running';
  }

  /// 推进 [dtSec] 秒。暂停时只让速度衰减，距离/时长不增长。
  SunRunFix tick(double dtSec) {
    final double dt = dtSec.isFinite ? dtSec.clamp(0.0, 10.0).toDouble() : 0.0;
    if (_state == 'finished' || dt <= 0) {
      return _lastFix ??= _buildFix();
    }
    if (_state == 'paused') {
      _approachSpeed(0, dt);
      _cadence = 0;
      _fixCount++;
      return _lastFix = _buildFix();
    }

    _elapsedSec += dt;

    // 疲劳：按 elapsed 线性衰减（以 15 分钟为参考尺度，下限 0.7）。
    final double fatigue =
        (1.0 - _fatigueRate * (_elapsedSec / 900.0))
            .clamp(0.70, 1.0)
            .toDouble();

    // 配速波动：每 10–20s 生成新目标因子，再低通平滑过去。
    if (_elapsedSec >= _nextPaceChange) {
      _targetPaceFactor = _rngPace.range(0.92, 1.08);
      _nextPaceChange = _elapsedSec + _rngPace.range(10, 20);
    }
    _paceFactor +=
        (_targetPaceFactor - _paceFactor) * (1 - math.exp(-dt / 4.0));

    // 红绿灯：闭合环线才触发；减速到 0，停 3–12s 后重新起步。
    bool stopping = false;
    if (config.loop) {
      if (_stopRemaining <= 0 && _elapsedSec >= _nextStopAt) {
        _stopRemaining = _rngStop.range(3, 12);
        _nextStopAt =
            _elapsedSec + _stopRemaining + _rngStop.range(45, 120);
      }
      if (_stopRemaining > 0) {
        _stopRemaining = math.max(0.0, _stopRemaining - dt);
        stopping = true;
      }
    }

    final double targetSpeed =
        _baseSpeed * fatigue * _paceFactor * (stopping ? 0.0 : 1.0);
    _approachSpeed(targetSpeed, dt);

    _distanceM += _speed * dt;
    if (_distanceM >= _targetDistanceM) {
      _distanceM = _targetDistanceM;
      _speed = 0;
      _cadence = 0;
      _state = 'finished';
    } else {
      _cadence = _speed < 0.2
          ? 0.0
          : (150.0 + (_speed - config.mode.baseSpeedMps) * 7.0)
              .clamp(150.0, 185.0)
              .toDouble();
      if (_speed >= 0.2) _steps += _cadence / 60.0 * dt;
    }

    _advanceGps(dt);
    _fixCount++;
    return _lastFix = _buildFix();
  }

  /// 低通 + 加速度上限：既平滑又不出现瞬时跳变。
  void _approachSpeed(double target, double dt) {
    final double lowpass =
        target + (_speed - target) * math.exp(-dt / 2.0);
    final double maxDelta = _maxAccel * dt;
    double next = lowpass;
    if (next - _speed > maxDelta) next = _speed + maxDelta;
    if (_speed - next > maxDelta) next = _speed - maxDelta;
    _speed = next.clamp(0.0, 20.0).toDouble();
  }

  void _advanceGps(double dt) {
    const double tau = 8.0;
    final double dtc = dt.clamp(0.0, 5.0).toDouble();
    final double k = math.sqrt(2.0 * dtc / tau);
    _noiseE += -_noiseE / tau * dtc + _noiseSigma * k * _rngGps.gauss();
    _noiseN += -_noiseN / tau * dtc + _noiseSigma * k * _rngGps.gauss();

    // 多径突发：40–90s 一次，持续 2–5s，额外 2–8m 偏移。
    if (_elapsedSec >= _nextBurstAt) {
      final double angle = _rngGps.range(0, 2 * math.pi);
      final double magnitude = _rngGps.range(2, 8);
      _burstE = magnitude * math.cos(angle);
      _burstN = magnitude * math.sin(angle);
      _burstRemaining = _rngGps.range(2, 5);
      _nextBurstAt = _elapsedSec + _burstRemaining + _rngGps.range(40, 90);
    }
    if (_burstRemaining > 0) {
      _burstRemaining = math.max(0.0, _burstRemaining - dtc);
      if (_burstRemaining == 0) {
        _burstE = 0;
        _burstN = 0;
      }
    }

    // 卫星偶发跳变。
    if (_elapsedSec >= _nextSatChange) {
      _satTotal = _rngSat.intRange(12, 24);
      _satUsed = math.min(_satTotal, _rngSat.intRange(9, 20));
      _cn0 = _rngSat.range(26, 46);
      _nextSatChange = _elapsedSec + _rngSat.range(30, 90);
    }
  }

  SunRunFix _buildFix() {
    final Map<String, double> base = route.pointAt(_distanceM);
    final double east = _noiseE + (_burstRemaining > 0 ? _burstE : 0);
    final double north = _noiseN + (_burstRemaining > 0 ? _burstN : 0);
    final _LocalFrame frame = _LocalFrame(config.startLat, config.startLng);
    final Map<String, double> shifted = frame.toLatLng(
      (base['lng']! - config.startLng) * frame.mPerDegLng + east,
      (base['lat']! - config.startLat) * _LocalFrame.mPerDegLat + north,
    );

    final double noiseMag = math.sqrt(east * east + north * north);
    final double accuracy =
        (3.0 + noiseMag * 0.9 + _rngGps.range(-0.2, 0.8))
            .clamp(3.0, 8.0)
            .toDouble();
    final double verticalAccuracy = _rngGps.range(1, 4);
    final double altitude =
        _altBase + 2.2 * math.sin(_elapsedSec / 180.0 + _altPhase);
    final double cn0 = (_cn0 + _rngGps.range(-2, 2)).clamp(26.0, 46.0).toDouble();
    final double bearing = _speed < 0.3
        ? 0.0
        : (base['bearing']! +
                (_rngGps.nextDouble() < 0.5 ? -1 : 1) * _rngGps.range(1, 3)) %
            360;

    return SunRunFix(
      ts: _startTs.add(
          Duration(milliseconds: (_elapsedSec * 1000).round())),
      lat: shifted['lat']!,
      lng: shifted['lng']!,
      altitude: altitude,
      speedMps: _speed,
      bearingDeg: bearing.isNegative ? bearing + 360 : bearing,
      accuracyM: accuracy,
      verticalAccuracyM: verticalAccuracy,
      satellites: _satTotal,
      satellitesUsed: _satUsed,
      cn0: cn0,
      distanceM: _distanceM,
      elapsedSec: _elapsedSec,
    );
  }
}

// ---------------------------------------------------------------------------
// 5. 运行时单例（插件 / UI 共用）
// ---------------------------------------------------------------------------

/// 进程级运行时：真实 1 秒 Timer 推进引擎，stop 时真实写历史文件。
///
/// - 页面关闭不 stop（后台继续），只有显式 stop 才结束；
/// - App 重启后单例是全新的 idle，不会恢复旧 timer；
/// - 所有 IO 异常都转成结构化 `{ok:false,error:...}`，绝不伪造成功。
class SunRunRuntime {
  SunRunRuntime._();

  static final SunRunRuntime instance = SunRunRuntime._();

  static const String historyFile = 'sun_run/history.json';

  HarnessStore? _store;
  SunRunEngine? _engine;
  Map<String, dynamic> _nativeStatus = const <String, dynamic>{};
  Timer? _timer;
  DateTime? _startedAt;
  bool _recorded = false;
  String _state = 'idle';
  String _lastError = '';
  Map<String, dynamic>? _lastSummary;
  Map<String, dynamic> _lastStats = const <String, dynamic>{};
  Map<String, dynamic> _lastFix = const <String, dynamic>{};
  SunRunConfig? _lastConfig;

  bool get isRunning => _timer != null;

  /// 惰性挂载真实存储（同步生效，返回 Future 便于调用方按需 await）。
  Future<void> attach(HarnessStore store) async {
    _store = store;
  }

  /// 供 UI 在进入页面时预热存储；失败只记录结构化错误。
  Future<void> ensureStore() async {
    await _ensureStore();
  }

  Future<HarnessStore?> _ensureStore() async {
    final HarnessStore? existing = _store;
    if (existing != null) return existing;
    try {
      final HarnessStore store = await HarnessStore.instance();
      _store = store;
      return store;
    } on Object catch (e) {
      _lastError = '存储不可用：$e';
      return null;
    }
  }

  SunRunConfig _configFromArgs(Map<String, dynamic> args) {
    final Object? raw = args['config'];
    if (raw is Map) {
      return SunRunConfig.fromJson(
          raw.map((dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)));
    }
    return SunRunConfig.fromJson(args);
  }

  /// 统一入口：seam provider / 工具 / 控制动作都走这里。
  Future<Map<String, dynamic>> handle(
      Object? method, Map<String, dynamic> args) async {
    final String action = (method ?? '').toString();
    switch (action) {
      case 'start':
        return _start(args);
      case 'pause':
        return _pause();
      case 'resume':
        return _resume();
      case 'stop':
        return _stop();
      case 'status':
        return _status();
      case 'history':
        return _history();
      default:
        return <String, dynamic>{
          'ok': false,
          'error': '未知方法：$action（支持 start/pause/resume/stop/status/history）',
        };
    }
  }

  // ---- 面向 UI / 测试的具名 API（与 handle 等价）----
  Future<Map<String, dynamic>> start(SunRunConfig config) =>
      _start(<String, dynamic>{'config': config.toJson()});

  Future<Map<String, dynamic>> pause() async => _pause();

  Future<Map<String, dynamic>> resume() async => _resume();

  Future<Map<String, dynamic>> stop() => _stop();

  Map<String, dynamic> status() => _status();

  Future<Map<String, dynamic>> history() => _history();

  Future<Map<String, dynamic>> _start(Map<String, dynamic> args) async {
    if (_timer != null ||
        (_engine != null && _engine!.state != 'finished')) {
      return <String, dynamic>{'ok': false, 'error': '已有进行中的会话'};
    }
    try {
      final SunRunConfig config = _configFromArgs(args);
      if (config.targetKm <= 0) {
        return <String, dynamic>{'ok': false, 'error': 'targetKm 必须大于 0'};
      }
      _timer?.cancel();
      _engine = SunRunEngine(config, startTs: DateTime.now().toUtc());
      _lastConfig = config;
      _startedAt = DateTime.now();
      _state = 'running';
      _recorded = false;
      _lastSummary = null;
      _lastError = '';
      _lastStats = _engine!.stats.toJson();
      _lastFix = _engine!.currentFix?.toJson() ?? const <String, dynamic>{};
      _nativeStatus = await SunRunNative.start(_lastFix);
      _timer = Timer.periodic(const Duration(seconds: 1), _onTick);
      unawaited(_ensureStore());
      return <String, dynamic>{
        'ok': true,
        'state': _state,
        ..._livePayload(),
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '启动失败：$e'};
    }
  }

  void _onTick(Timer timer) {
    final SunRunEngine? engine = _engine;
    if (engine == null) {
      timer.cancel();
      _timer = null;
      return;
    }
    try {
      engine.tick(1.0);
      _lastStats = engine.stats.toJson();
      _lastFix = engine.currentFix?.toJson() ?? const <String, dynamic>{};
      final Map<String, dynamic> fix = _lastFix;
      if (fix.isNotEmpty) unawaited(SunRunNative.update(fix));
      if (engine.state == 'finished') {
        timer.cancel();
        _timer = null;
        _state = 'finished';
        unawaited(SunRunNative.stop());
        _nativeStatus = const <String, dynamic>{};
        if (!_recorded) {
          _recorded = true;
          unawaited(_writeHistory(_sessionSummary(engine)));
        }
      }
    } on Object catch (e) {
      _lastError = '推进失败：$e';
    }
  }

  Map<String, dynamic> _pause() {
    final SunRunEngine? engine = _engine;
    if (engine == null) {
      return <String, dynamic>{'ok': false, 'error': '没有进行中的会话'};
    }
    if (engine.state != 'running') {
      return <String, dynamic>{
        'ok': false,
        'error': '当前状态为 ${engine.state}，无法暂停',
      };
    }
    engine.pause();
    _state = 'paused';
    return <String, dynamic>{'ok': true, 'state': _state, ..._livePayload()};
  }

  Map<String, dynamic> _resume() {
    final SunRunEngine? engine = _engine;
    if (engine == null) {
      return <String, dynamic>{'ok': false, 'error': '没有进行中的会话'};
    }
    if (engine.state != 'paused') {
      return <String, dynamic>{
        'ok': false,
        'error': '当前状态为 ${engine.state}，无法继续',
      };
    }
    engine.resume();
    _state = 'running';
    return <String, dynamic>{'ok': true, 'state': _state, ..._livePayload()};
  }

  Future<Map<String, dynamic>> _stop() async {
    unawaited(SunRunNative.stop());
    _nativeStatus = const <String, dynamic>{};
    final SunRunEngine? engine = _engine;
    _timer?.cancel();
    _timer = null;
    if (engine == null) {
      _state = 'idle';
      return <String, dynamic>{
        'ok': true,
        'state': 'idle',
        'note': '没有进行中的会话',
        if (_lastSummary != null) 'last': _lastSummary,
      };
    }
    final Map<String, dynamic> summary = _sessionSummary(engine);
    _lastSummary = summary;
    _lastStats = engine.stats.toJson();
    _lastFix = engine.currentFix?.toJson() ?? <String, dynamic>{};
    _state = 'idle';
    _engine = null;
    if (!_recorded) {
      _recorded = true;
      final Map<String, dynamic> written = await _writeHistory(summary);
      if (written['ok'] != true) {
        _lastError = (written['error'] ?? '历史写入失败').toString();
      }
    }
    return <String, dynamic>{
      'ok': _lastError.isEmpty,
      'state': 'idle',
      if (_lastError.isNotEmpty) 'error': _lastError,
      'session': summary,
    };
  }

  Map<String, dynamic> _status() {
    final SunRunEngine? engine = _engine;
    if (engine == null) {
      return <String, dynamic>{
        'ok': true,
        'state': 'idle',
        'running': false,
        if (_lastSummary != null) 'last': _lastSummary,
        if (_lastConfig != null) 'config': _lastConfig!.toJson(),
        if (_lastStats.isNotEmpty) 'stats': _lastStats,
        if (_lastFix.isNotEmpty) 'current': _lastFix,
        'last_error': _lastError,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'state': engine.state,
      'running': _timer != null,
      ..._livePayload(),
      'last_error': _lastError,
    };
  }

  Map<String, dynamic> _livePayload() {
    final SunRunEngine? engine = _engine;
    if (engine == null) return const <String, dynamic>{};
    final Map<String, dynamic> stats = engine.stats.toJson();
    return <String, dynamic>{
      'config': engine.config.toJson(),
      'stats': stats,
      'current': engine.currentFix?.toJson() ?? <String, dynamic>{},
      'route': engine.route.sample(96),
      'start': engine.route.startPoint,
      'end': engine.route.endPoint,
      'route_length_m': engine.route.lengthM,
      'mode_label': engine.config.mode.label,
      'native': _nativeStatus,
      'distance_km': stats['distanceM'] is num
          ? (stats['distanceM'] as num).toDouble() / 1000.0
          : 0.0,
    };
  }

  Map<String, dynamic> _sessionSummary(SunRunEngine engine) {
    final SunRunStats stats = engine.stats;
    final DateTime finishedAt = DateTime.now();
    return <String, dynamic>{
      'ts': finishedAt.toUtc().toIso8601String(),
      'started_at': _startedAt?.toUtc().toIso8601String(),
      'mode': engine.config.mode.name,
      'mode_label': engine.config.mode.label,
      'seed': engine.config.seed,
      'distance_m': stats.distanceM,
      'distance_km': stats.distanceM / 1000.0,
      'elapsed_sec': stats.elapsedSec,
      'pace_sec_per_km': stats.paceSecPerKm,
      'calories': stats.calories,
      'steps': stats.steps,
      'state': engine.state,
    };
  }

  Future<Map<String, dynamic>> _history() async {
    final HarnessStore? store = await _ensureStore();
    if (store == null) {
      return <String, dynamic>{
        'ok': false,
        'error': _lastError.isEmpty ? '存储不可用' : _lastError,
      };
    }
    try {
      final List<dynamic> raw = await store.readList(historyFile);
      final List<Map<String, dynamic>> items = raw
          .whereType<Map>()
          .map((Map<dynamic, dynamic> m) =>
              m.map((dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)))
          .toList();
      return <String, dynamic>{'ok': true, 'items': items};
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '读取历史失败：$e'};
    }
  }

  Future<Map<String, dynamic>> _writeHistory(
      Map<String, dynamic> summary) async {
    final HarnessStore? store = await _ensureStore();
    if (store == null) {
      return <String, dynamic>{
        'ok': false,
        'error': _lastError.isEmpty ? '存储不可用' : _lastError,
      };
    }
    try {
      final List<dynamic> raw = await store.readList(historyFile);
      final List<Map<String, dynamic>> items = raw
          .whereType<Map>()
          .map((Map<dynamic, dynamic> m) =>
              m.map((dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)))
          .toList();
      items.insert(0, summary);
      while (items.length > 50) {
        items.removeLast();
      }
      await store.writeJson(historyFile, items);
      return <String, dynamic>{'ok': true, 'count': items.length};
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '写入历史失败：$e'};
    }
  }

  /// 仅测试使用：清空内存态并取消 timer，不碰磁盘历史。
  void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _engine = null;
    _startedAt = null;
    _recorded = false;
    _state = 'idle';
    _lastError = '';
    _lastSummary = null;
    _lastStats = const <String, dynamic>{};
    _lastFix = const <String, dynamic>{};
    _lastConfig = null;
  }
}
