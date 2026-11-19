import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../design/tga_design.dart';
import '../../harness/sun_run.dart';

/// 「爱阳光跑」——插件 `capability.sunrun` 的独立界面。
///
/// 页面只负责展示与操作：真正的轨迹/速度/GNSS 噪声由 [SunRunRuntime] 的
/// 引擎在后台按真实 1 秒推进。关闭页面只会取消 UI 刷新（运行继续），
/// App 重启后运行时会如实回到待机，不伪造「仍在运行」。
class TgaSunRunPage extends StatefulWidget {
  const TgaSunRunPage({super.key});

  @override
  State<TgaSunRunPage> createState() => _TgaSunRunPageState();
}

class _TgaSunRunPageState extends State<TgaSunRunPage> {
  final SunRunRuntime _runtime = SunRunRuntime.instance;
  final TextEditingController _paceController = TextEditingController();
  final MapController _mapController = MapController();

  // 默认坐标沿用原「阳光跑」的山东科技大学点位；点击地图可改起点。
  double _startLat = 36.667662;
  double _startLng = 117.027707;

  SunRunMode _mode = SunRunMode.run;
  int _targetKm = 5;
  Timer? _timer;
  bool _busy = false;
  String _error = '';
  String _previousState = 'idle';
  Map<String, dynamic> _status = const <String, dynamic>{};
  List<Map<String, dynamic>> _history = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    unawaited(_runtime.ensureStore());
    unawaited(_refreshAll());
    // 只刷新界面；运行中的 Timer 由运行时自己持有。
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_refreshStatus());
    });
  }

  @override
  void dispose() {
    // 页面关闭不停止模拟：仅取消 UI 刷新。
    _timer?.cancel();
    _paceController.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await _refreshStatus();
    await _loadHistory();
  }

  Future<void> _refreshStatus() async {
    final Map<String, dynamic> r =
        await _runtime.handle('status', const <String, dynamic>{});
    if (!mounted) return;
    final String state = (r['state'] ?? 'idle').toString();
    setState(() {
      _status = r;
      if (r['ok'] != true) {
        _error = (r['error'] ?? '状态读取失败').toString();
      } else {
        _error = '';
      }
    });
    final bool justStopped =
        (state == 'finished' || state == 'idle') &&
            (_previousState == 'running' || _previousState == 'paused');
    _previousState = state;
    if (justStopped) unawaited(_loadHistory());
  }

  Future<void> _loadHistory() async {
    final Map<String, dynamic> r =
        await _runtime.handle('history', const <String, dynamic>{});
    if (!mounted) return;
    if (r['ok'] == true) {
      setState(() => _history = _mapList(r['items']));
    }
  }

  Map<String, dynamic> _buildConfig() => <String, dynamic>{
        'mode': _mode.name,
        'targetKm': _targetKm.toDouble(),
        'paceSecPerKm': int.tryParse(_paceController.text.trim()) ?? 0,
        'seed': DateTime.now().millisecondsSinceEpoch % 1000000,
        'startLat': _startLat,
        'startLng': _startLng,
        'loop': true,
        'realism': 0.75,
        'weightKg': 65,
      };

  Future<void> _run(String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> payload = <String, dynamic>{
        'action': action,
        if (action == 'start') 'config': _buildConfig(),
      };
      final Map<String, dynamic> r = await _runtime.handle(action, payload);
      if (!mounted) return;
      if (r['ok'] != true) {
        _toast((r['error'] ?? '操作失败').toString());
      } else if (action == 'start') {
        _toast('模拟已开始，页面关闭也会继续运行');
      } else if (action == 'stop') {
        _toast('本次会话已结束并写入本地历史');
      }
      await _refreshStatus();
      if (action == 'stop' || (r['state'] == 'finished')) {
        await _loadHistory();
      }
    } on Object catch (e) {
      if (mounted) _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 3),
      ));
  }

  Map<String, dynamic> _asMap(Object? raw) => raw is Map
      ? raw.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v))
      : <String, dynamic>{};

  List<Map<String, dynamic>> _mapList(Object? raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((Map<dynamic, dynamic> m) => m.map(
              (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)))
          .toList()
      : <Map<String, dynamic>>[];

  double _num(Map<String, dynamic> m, String key) {
    final Object? v = m[key];
    return v is num ? v.toDouble() : 0.0;
  }

  String _stateLabel(String state) => switch (state) {
        'running' => '运行中',
        'paused' => '已暂停',
        'finished' => '已完成',
        _ => '待机',
      };

  Color _stateColor(String state) => switch (state) {
        'running' => Tga.green,
        'paused' => Tga.orange,
        'finished' => Tga.primary,
        _ => Tga.textDim,
      };

  String _fmtDuration(double seconds) {
    final int total = seconds.round();
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _fmtPace(double paceSecPerKm) {
    if (!paceSecPerKm.isFinite || paceSecPerKm <= 0) return '--';
    final int total = paceSecPerKm.round();
    final int m = total ~/ 60;
    final int s = total % 60;
    return "$m'${s.toString().padLeft(2, '0')}\"/km";
  }

  String _fmtTime(Object? raw) {
    final DateTime? dt = raw is String ? DateTime.tryParse(raw) : null;
    if (dt == null) return '--';
    final DateTime local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> stats = _asMap(_status['stats']);
    final Map<String, dynamic> current = _asMap(_status['current']);
    final Map<String, dynamic> config = _asMap(_status['config']);
    final List<Map<String, dynamic>> route =
        _mapList(_status['route']);
    final String state = (_status['state'] ?? 'idle').toString();
    final double distanceM = _num(stats, 'distanceM');
    final double distanceKm = distanceM / 1000.0;
    final double elapsed = _num(stats, 'elapsedSec');
    final double pace = _num(stats, 'paceSecPerKm');
    final double calories = _num(stats, 'calories');
    final double steps = _num(stats, 'steps');
    final int satellites = (current['satellites'] is num)
        ? (current['satellites'] as num).toInt()
        : 0;
    final int satellitesUsed = (current['satellitesUsed'] is num)
        ? (current['satellitesUsed'] as num).toInt()
        : 0;
    final double accuracy = _num(current, 'accuracyM');
    final double routeKm = _num(_status, 'route_length_m') / 1000.0;
    final String modeLabel =
        (config['mode'] is String) ? _modeLabelOf(config['mode']) : _mode.label;

    return TgaPage(
      title: '爱阳光跑',
      actions: <Widget>[
        IconButton(
          onPressed: _busy ? null : () => unawaited(_refreshAll()),
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          if (_error.isNotEmpty)
            TgaCard(
              child: Text(_error,
                  style: Tga.body.copyWith(color: Tga.red)),
            ),
          TgaGroupTitle('当前状态'),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    TgaTag('插件已挂载', color: Tga.green),
                    const SizedBox(width: 8),
                    TgaTag(_stateLabel(state), color: _stateColor(state)),
                    const Spacer(),
                    Text(modeLabel, style: Tga.sub),
                  ],
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 22,
                  runSpacing: 14,
                  children: <Widget>[
                    _metric('距离', '${distanceKm.toStringAsFixed(2)} km'),
                    _metric('时长', _fmtDuration(elapsed)),
                    _metric('配速', _fmtPace(pace)),
                    _metric('卡路里', calories.toStringAsFixed(0)),
                    _metric('步数', steps.toStringAsFixed(0)),
                    _metric('卫星',
                        satellites > 0 ? '$satellitesUsed/$satellites' : '--'),
                    _metric(
                        '精度',
                        accuracy > 0
                            ? '±${accuracy.toStringAsFixed(1)} m'
                            : '--'),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  state == 'idle'
                      ? '待机：配置参数后开始一次模拟。'
                      : '目标 ${_num(config, 'targetKm').toStringAsFixed(0)} km'
                          '${config['loop'] == false ? ' · 点到点' : ' · 闭合环线'}'
                          ' · 路线 ${routeKm.toStringAsFixed(2)} km',
                  style: Tga.caption,
                ),
              ],
            ),
          ),
          TgaGroupTitle('模拟配置'),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('运动模式', style: Tga.sub),
                const SizedBox(height: 8),
                TgaSegmented<SunRunMode>(
                  items: SunRunMode.values,
                  value: _mode,
                  labelOf: (SunRunMode m) => m.label,
                  onChanged: (SunRunMode m) => setState(() => _mode = m),
                ),
                const SizedBox(height: 14),
                Text('目标距离', style: Tga.sub),
                const SizedBox(height: 8),
                TgaSegmented<int>(
                  items: const <int>[1, 3, 5, 10],
                  value: _targetKm,
                  labelOf: (int km) => '$km km',
                  onChanged: (int km) => setState(() => _targetKm = km),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _paceController,
                  keyboardType: TextInputType.number,
                  style: TextStyle(fontSize: 13.5, color: Tga.text),
                  decoration: InputDecoration(
                    labelText: '配速（秒/公里，可空）',
                    labelStyle: TextStyle(fontSize: 12, color: Tga.textDim),
                    hintText: "例如 330 = 5'30\"/km",
                    hintStyle: TextStyle(fontSize: 12, color: Tga.textDim),
                    isDense: true,
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          BorderSide(color: Tga.border, width: 0.8),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Tga.primary, width: 1.2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    if (state == 'idle' || state == 'finished')
                      TgaButton(
                        label: '开始',
                        icon: Icons.play_arrow_rounded,
                        onTap: () {
                          if (!_busy) unawaited(_run('start'));
                        },
                      ),
                    if (state == 'running')
                      TgaButton(
                        label: '暂停',
                        icon: Icons.pause_rounded,
                        filled: false,
                        onTap: () {
                          if (!_busy) unawaited(_run('pause'));
                        },
                      ),
                    if (state == 'paused')
                      TgaButton(
                        label: '继续',
                        icon: Icons.play_arrow_rounded,
                        onTap: () {
                          if (!_busy) unawaited(_run('resume'));
                        },
                      ),
                    if (state != 'idle')
                      TgaButton(
                        label: '结束',
                        icon: Icons.stop_rounded,
                        color: Tga.red,
                        filled: false,
                        onTap: () {
                          if (!_busy) unawaited(_run('stop'));
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
          TgaGroupTitle('地图轨迹'),
          TgaCard(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  height: 300,
                  width: double.infinity,
                  child: ClipRRect(
                    borderRadius: BorderRadius.vertical(
                        top: Radius.circular(Tga.rCard)),
                    child: _buildMap(route, current),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: <Widget>[
                      _legend(Tga.green, '起点'),
                      const SizedBox(width: 14),
                      _legend(Tga.red, '终点'),
                      const SizedBox(width: 14),
                      _legend(Tga.primary, '当前位置'),
                      const Spacer(),
                      Text('已走 ${distanceKm.toStringAsFixed(2)} km',
                          style: Tga.body),
                    ],
                  ),
                ),
              ],
            ),
          ),
          TgaGroupTitle('历史记录'),
          TgaCard(
            child: _history.isEmpty
                ? Text('暂无历史会话：结束一次模拟后会写入本地记录。',
                    style: Tga.sub)
                : Column(
                    children: <Widget>[
                      for (int i = 0; i < _history.length; i++) ...<Widget>[
                        if (i > 0)
                          Divider(height: 14, color: Tga.divider),
                        _historyRow(_history[i]),
                      ],
                    ],
                  ),
          ),
          TgaGroupTitle('说明'),
          TgaCard(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.info_outline_rounded, size: 18, color: Tga.cyan),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '这是 GPS/传感器轨迹模拟，用于生成可复现的路线、速度、步频与 GNSS 噪声数据。'
                    '系统级位置注入需要 Android 开发者选项中的「模拟位置信息」应用授权；'
                    '本页不会伪造「已注入」，也不会改写系统位置服务。 '
                    '关闭页面后模拟继续在后台运行，App 重启后如实回到待机。',
                    style: Tga.sub,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabelOf(Object? raw) => SunRunMode.parse(raw).label;

  Widget _metric(String label, String value) => SizedBox(
        width: 88,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(value,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Tga.text,
                )),
            const SizedBox(height: 2),
            Text(label, style: Tga.caption),
          ],
        ),
      );

  /// 真实地图底图（OpenStreetMap）+ 轨迹/起点/终点/当前位置。
  /// 点击地图可把起点移到点击位置；轨迹运行时自动出现。
  Widget _buildMap(
    List<Map<String, dynamic>> route,
    Map<String, dynamic> current,
  ) {
    final List<ll.LatLng> points = <ll.LatLng>[
      for (final Map<String, dynamic> p in route)
        ll.LatLng(_num(p, 'lat'), _num(p, 'lng')),
    ];
    final ll.LatLng fallback = ll.LatLng(_startLat, _startLng);
    final ll.LatLng center = points.isNotEmpty ? points.first : fallback;
    final double curLat = _num(current, 'lat');
    final double curLng = _num(current, 'lng');
    final bool hasCurrent = curLat != 0 && curLng != 0;

    final List<Marker> markers = <Marker>[
      if (points.isNotEmpty)
        Marker(
          point: points.first,
          width: 30,
          height: 30,
          child: _pin(Tga.green, Icons.trip_origin_rounded),
        ),
      if (points.isNotEmpty)
        Marker(
          point: points.last,
          width: 30,
          height: 30,
          child: _pin(Tga.red, Icons.flag_rounded),
        ),
      if (hasCurrent)
        Marker(
          point: ll.LatLng(curLat, curLng),
          width: 34,
          height: 34,
          child: _pin(Tga.primary, Icons.directions_run_rounded),
        ),
    ];

    return Stack(
      children: <Widget>[
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 16,
            minZoom: 3,
            maxZoom: 19,
            onTap: (TapPosition tap, ll.LatLng point) {
              setState(() {
                _startLat = point.latitude;
                _startLng = point.longitude;
              });
              _toast(
                  '起点已设为 ${_startLat.toStringAsFixed(5)}, ${_startLng.toStringAsFixed(5)}');
            },
          ),
          children: <Widget>[
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.tangram.agent.tangram',
              maxNativeZoom: 19,
            ),
            if (points.length >= 2)
              PolylineLayer(
                polylines: <Polyline>[
                  Polyline(
                    points: points,
                    strokeWidth: 4,
                    color: Tga.primary.withValues(alpha: 0.9),
                  ),
                ],
              ),
            MarkerLayer(markers: markers),
            const RichAttributionWidget(
              attributions: <SourceAttribution>[
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),
        Positioned(
          right: 10,
          top: 10,
          child: Column(
            children: <Widget>[
              _mapButton(Icons.add_rounded, () {
                _mapController.move(
                    _mapController.camera.center, _mapController.camera.zoom + 1);
              }),
              const SizedBox(height: 8),
              _mapButton(Icons.remove_rounded, () {
                _mapController.move(
                    _mapController.camera.center, _mapController.camera.zoom - 1);
              }),
              const SizedBox(height: 8),
              _mapButton(Icons.my_location_rounded, () {
                _mapController.move(center, 16);
              }),
            ],
          ),
        ),
        Positioned(
          left: 10,
          top: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: Tga.card.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text('点击地图设起点',
                style: Tga.caption.copyWith(color: Tga.textSub)),
          ),
        ),
      ],
    );
  }

  Widget _mapButton(IconData icon, VoidCallback onTap) => Material(
        color: Tga.card.withValues(alpha: 0.95),
        shape: const CircleBorder(),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 20, color: Tga.primary),
          ),
        ),
      );

  Widget _pin(Color color, IconData icon) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: color.withValues(alpha: 0.35),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, size: 16, color: Colors.white),
      );

  Widget _legend(Color color, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label, style: Tga.caption),
        ],
      );

  Widget _historyRow(Map<String, dynamic> item) {
    final String label = (item['mode_label'] ?? '--').toString();
    final double km = _num(item, 'distance_km');
    final double pace = _num(item, 'pace_sec_per_km');
    return Row(
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Tga.iconBlueBg,
            shape: BoxShape.circle,
            border:
                Border.all(color: Tga.iconBlue.withValues(alpha: 0.14)),
          ),
          child: Icon(Icons.directions_run_rounded,
              size: 17, color: Tga.iconBlue),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: Tga.body),
              const SizedBox(height: 2),
              Text(
                '${km.toStringAsFixed(2)} km · ${_fmtPace(pace)} · '
                '${_fmtTime(item['started_at'] ?? item['ts'])}',
                style: Tga.caption,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 轻量轨迹绘制（不依赖任何地图 SDK）：折线 + 起点/终点 + 当前位置。
