import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';

/// 知识图谱（真实化改造）：
///
/// - 节点/边来自后端 rpc graph_query：基于真实对话 turns 的词共现统计
///   （nodes:[{name,degree}]，edges:[{subject,predicate:'co-occur',obj}]），
///   节点数如实展示；无对话记录时显示空态 + 刷新按钮。
/// - 斐波那契球面布局 + 透视投影：近大远小、近亮远暗；背面（z<0）的
///   节点/连线/标签统一降透明度（约 0.32），正面加亮，立体感更强；
/// - 节点径向渐变填充（中心亮边缘深）+ 同色外发光，按词哈希分五色、
///   度数越大节点越大；选中节点白描边 + 放大动画；
/// - 连线为沿球面微弯的贝塞尔曲线，线宽随共现权重、透明度随深度渐隐；
/// - 球壳淡经纬网格（8 段椭圆弧，alpha 0.06）+ 顶部高光弧；配色全部取
///   Tga.* 主题令牌，深浅主题皆适配；
/// - 拖拽旋转带惯性衰减，空闲时缓慢自转（0.0015 rad/帧），触摸暂停；
///   双指/滚轮缩放。
/// - 标签：较近（z>0.25）或度数 Top8 常显，带半透明圆角底衬并贪心避让
///   防叠字，其余节点点击选中后才显示。
/// - 点击节点弹底部详情：实体名 / 度数 / 关联实体（真实边），
///   并从 memory_event diary 检索包含该词的真实对话摘录（最多 5 条，含日期），
///   摘录里的 URL 可复制；没有图片视频数据就不放假媒体。
class TgaSphereGraphPage extends StatefulWidget {
  const TgaSphereGraphPage({super.key});

  @override
  State<TgaSphereGraphPage> createState() => _TgaSphereGraphPageState();
}

class _TgaSphereGraphPageState extends State<TgaSphereGraphPage>
    with SingleTickerProviderStateMixin {
  // ---- 视角 / 惯性 ----
  double _rotY = 0.5;
  double _rotX = -0.35;
  double _zoom = 1.0;
  double _lastScale = 1.0;
  double _velY = 0.0; // 角速度（rad/帧），松手后惯性衰减
  double _velX = 0.0;
  bool _dragging = false;

  // ---- 选中节点（白描边 + 放大动画 + 显示其标签）----
  int _selected = -1;
  double _selT = 1.0; // 0→1 放大动画进度

  late final Ticker _ticker;

  // ---- 真实图谱数据（rpc graph_query）----
  List<String> _names = <String>[];
  List<int> _degrees = <int>[];
  List<_V3> _pos = <_V3>[];
  List<_Edge> _edges = <_Edge>[];
  Map<int, List<int>> _neighbors = <int, List<int>>{};
  List<int> _rank = <int>[]; // 按度数排名的名次（0 = 最大）
  int _maxWeight = 1;
  int _revision = 0; // 数据版本号，驱动重绘

  bool _loading = true;
  String _error = '';

  /// 投影缓存：paint 时填充，供点击命中测试。
  final List<Offset> _screen = <Offset>[];
  final List<double> _zs = <double>[];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// 每帧：触摸时暂停；非拖拽时应用惯性 + 缓慢自转，并推进选中放大动画。
  void _onTick(Duration dt) {
    if (_dragging || _names.isEmpty) return;
    setState(() {
      if (_selT < 1.0) _selT = math.min(1.0, _selT + 0.07);
      if (_velY.abs() < 0.00012 && _velX.abs() < 0.00012) {
        // 惯性耗尽后仅保持极慢自转。
        _rotY += 0.0015;
      } else {
        _rotY += _velY;
        _rotX = (_rotX + _velX).clamp(-1.4, 1.4).toDouble();
        _velY *= 0.94;
        _velX *= 0.94;
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 真实数据装载
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    final BackendClient client = context.read<BackendClient>();
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final BridgeEnvelope env = await client.sendControl(
          'rpc', <String, dynamic>{'action': 'graph_query'});
      final dynamic p = env.payload;
      final Map<String, dynamic> m =
          p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{};
      if (m['ok'] != true) {
        throw StateError((m['error'] ?? 'graph_query 未返回数据').toString());
      }
      final List<String> names = <String>[];
      final List<int> degrees = <int>[];
      final Map<String, int> index = <String, int>{};
      for (final dynamic n in (m['nodes'] as List? ?? <dynamic>[])) {
        if (n is! Map) continue;
        final String name = (n['name'] ?? '').toString();
        if (name.isEmpty || index.containsKey(name)) continue;
        index[name] = names.length;
        names.add(name);
        degrees.add((n['degree'] is num) ? (n['degree'] as num).toInt() : 1);
      }
      // 边去重并累计共现权重（graph_query 的 edges 是逐 turn 相邻词对）。
      final Map<String, int> wmap = <String, int>{};
      final Map<int, List<int>> neighbors = <int, List<int>>{};
      for (final dynamic e in (m['edges'] as List? ?? <dynamic>[])) {
        if (e is! Map) continue;
        final int? a = index[(e['subject'] ?? '').toString()];
        final int? b = index[(e['obj'] ?? '').toString()];
        if (a == null || b == null || a == b) continue;
        final int lo = math.min(a, b);
        final int hi = math.max(a, b);
        final String key = '$lo-$hi';
        wmap[key] = (wmap[key] ?? 0) + 1;
        neighbors.putIfAbsent(lo, () => <int>[]).add(hi);
        neighbors.putIfAbsent(hi, () => <int>[]).add(lo);
      }
      final List<_Edge> edges = <_Edge>[];
      int maxW = 1;
      wmap.forEach((String key, int w) {
        final List<String> ab = key.split('-');
        edges.add(_Edge(int.parse(ab[0]), int.parse(ab[1]), w));
        if (w > maxW) maxW = w;
      });
      // 邻居去重。
      final Map<int, List<int>> dedup = <int, List<int>>{};
      neighbors.forEach((int k, List<int> v) {
        dedup[k] = v.toSet().toList();
      });
      // 度数排名（标签优先级）。
      final List<int> order = List<int>.generate(names.length, (int i) => i)
        ..sort((int a, int b) => degrees[b].compareTo(degrees[a]));
      final List<int> rank = List<int>.filled(names.length, 0);
      for (int i = 0; i < order.length; i++) {
        rank[order[i]] = i;
      }
      if (!mounted) return;
      setState(() {
        _names = names;
        _degrees = degrees;
        _edges = edges;
        _neighbors = dedup;
        _rank = rank;
        _maxWeight = maxW;
        _pos = _fibonacciSphere(names.length);
        _revision++;
        _selected = -1;
        _selT = 1.0;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 斐波那契球面均匀布点。
  static List<_V3> _fibonacciSphere(int n) {
    if (n <= 0) return <_V3>[];
    if (n == 1) return <_V3>[_V3(0, 0, 1)];
    final List<_V3> pts = <_V3>[];
    final double golden = math.pi * (3 - math.sqrt(5));
    for (int i = 0; i < n; i++) {
      final double y = 1 - (i / (n - 1)) * 2;
      final double r = math.sqrt(math.max(0, 1 - y * y));
      final double t = golden * i;
      pts.add(_V3(math.cos(t) * r, y, math.sin(t) * r));
    }
    return pts;
  }

  /// 点击命中：取离触点最近的前半球节点。
  void _onTapUp(TapUpDetails d) {
    if (_names.isEmpty) return;
    double best = 26 * 26;
    int bi = -1;
    for (int i = 0; i < _screen.length && i < _names.length; i++) {
      if (_zs[i] < 0) continue; // 只点得到前半球
      final double dd = (_screen[i] - d.localPosition).distanceSquared;
      if (dd < best) {
        best = dd;
        bi = i;
      }
    }
    if (bi >= 0) {
      // 选中节点：白描边 + 放大动画，其标签随之显示（详情弹层逻辑不变）。
      setState(() {
        _selected = bi;
        _selT = 0.0;
      });
      _showDetails(bi);
    } else if (_selected >= 0) {
      setState(() => _selected = -1);
    }
  }

  void _showDetails(int idx) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext ctx) => _NodeDetailSheet(
        client: context.read<BackendClient>(),
        name: _names[idx],
        degree: _degrees[idx],
        related: (_neighbors[idx] ?? <int>[])
            .take(12)
            .map((int i) => _names[i])
            .toList(),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '知识图谱',
      actions: <Widget>[
        if (!_loading && _names.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TgaTag('${_names.length} 节点', color: Tga.cyan),
          ),
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: Tga.textSub),
          tooltip: '重新拉取图谱',
          onPressed: _loading ? null : _load,
        ),
        IconButton(
          icon: Icon(Icons.center_focus_strong_outlined,
              color: Tga.textSub),
          tooltip: '复位视角',
          onPressed: () => setState(() {
            _rotY = 0.5;
            _rotX = -0.35;
            _zoom = 1.0;
            _velY = 0;
            _velX = 0;
          }),
        ),
      ],
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('拖拽旋转（带惯性）· 双指/滚轮缩放 · 点击节点查看详情',
                  style: Tga.sub),
            ),
          ),
          Expanded(
            child: _loading
                ? Center(
                    child: SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.6, color: Tga.primary)),
                  )
                : _names.isEmpty
                    ? _emptyState()
                    : _sphereView(),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: _error.isNotEmpty
                ? TgaCard(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.error_outline_rounded,
                            size: 16, color: Tga.red),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text('图谱数据获取失败：$_error',
                                style: Tga.sub)),
                        TgaButton(label: '重试', onTap: _load, filled: false),
                      ],
                    ),
                  )
                : TgaCard(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: <Widget>[
                        Icon(Icons.info_outline_rounded,
                            size: 16, color: Tga.textSub),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '节点与连线来自真实对话记录的词共现统计（rpc graph_query）',
                            style: Tga.sub,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.account_tree_outlined,
              size: 42, color: Tga.textDim),
          const SizedBox(height: 12),
          Text('还没有对话记录，聊几句就会生成知识图谱', style: Tga.sub),
          const SizedBox(height: 16),
          TgaButton(
              label: '刷新',
              onTap: _load,
              icon: Icons.refresh_rounded,
              filled: false),
        ],
      ),
    );
  }

  Widget _sphereView() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double size =
            math.min(constraints.maxWidth, constraints.maxHeight) * 0.86;
        return Center(
          child: SizedBox(
            width: size,
            height: size,
            child: GestureDetector(
              onTapUp: _onTapUp,
              onScaleStart: (ScaleStartDetails _) {
                _lastScale = 1.0;
                _dragging = true;
              },
              onScaleUpdate: (ScaleUpdateDetails d) {
                setState(() {
                  if (d.pointerCount >= 2) {
                    // 双指缩放
                    _zoom = (_zoom * (d.scale / _lastScale))
                        .clamp(0.6, 2.4)
                        .toDouble();
                    _lastScale = d.scale;
                  } else {
                    // 单指拖拽旋转 + 记录角速度供惯性使用
                    final double dy = d.focalPointDelta.dx * 0.008;
                    final double dx = -d.focalPointDelta.dy * 0.008;
                    _rotY += dy;
                    _rotX = (_rotX + dx).clamp(-1.4, 1.4).toDouble();
                    _velY = _velY * 0.6 + dy * 0.4;
                    _velX = _velX * 0.6 + dx * 0.4;
                  }
                });
              },
              onScaleEnd: (ScaleEndDetails _) {
                _dragging = false;
              },
              child: Listener(
                onPointerSignal: (PointerSignalEvent e) {
                  if (e is PointerScrollEvent) {
                    setState(() {
                      _zoom = (_zoom - e.scrollDelta.dy * 0.0012)
                          .clamp(0.6, 2.4)
                          .toDouble();
                    });
                  }
                },
                child: CustomPaint(
                  painter: _SpherePainter(
                    rotX: _rotX,
                    rotY: _rotY,
                    zoom: _zoom,
                    pos: _pos,
                    degrees: _degrees,
                    names: _names,
                    rank: _rank,
                    edges: _edges,
                    maxWeight: _maxWeight,
                    revision: _revision,
                    screen: _screen,
                    zs: _zs,
                    selected: _selected,
                    selT: _selT,
                  ),
                  size: Size(size, size),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Edge {
  const _Edge(this.a, this.b, this.weight);
  final int a, b, weight;
}

class _SpherePainter extends CustomPainter {
  _SpherePainter({
    required this.rotX,
    required this.rotY,
    required this.zoom,
    required this.pos,
    required this.degrees,
    required this.names,
    required this.rank,
    required this.edges,
    required this.maxWeight,
    required this.revision,
    required this.screen,
    required this.zs,
    required this.selected,
    required this.selT,
  });

  final double rotX, rotY, zoom;
  final List<_V3> pos;
  final List<int> degrees;
  final List<String> names;
  final List<int> rank;
  final List<_Edge> edges;
  final int maxWeight;
  final int revision;
  final int selected;
  final double selT;

  /// 投影结果写回（命中测试用）。
  final List<Offset> screen;
  final List<double> zs;

  /// 标签常显的度数 Top N（其余点击选中后才显示）。
  static const int _labelTop = 8;

  /// 背面（z<0）节点/连线/标签统一降透明度系数。
  static const double _backDim = 0.32;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2 * 0.82 * zoom;

    // 背景辉光：整体球体一层柔和径向光（跟随主题主色）。
    final Rect glowRect = Rect.fromCircle(center: center, radius: radius * 1.4);
    canvas.drawCircle(
      center,
      radius * 1.4,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            Tga.primary.withValues(alpha: 0.12),
            Tga.primary.withValues(alpha: 0.0),
          ],
        ).createShader(glowRect),
    );

    // 外圈轮廓。
    canvas.drawCircle(
      center,
      radius * 1.02,
      Paint()
        ..color = Tga.primary.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );

    // 旋转 + 透视投影（写回 screen/zs 供命中测试）。
    screen.clear();
    zs.clear();
    final List<_V3> rot = <_V3>[];
    for (final _V3 v in pos) {
      final _V3 r = v.rotateX(rotX).rotateY(rotY);
      final double persp = 1 + r.z * 0.32;
      screen.add(Offset(center.dx + r.x * radius * persp,
          center.dy + r.y * radius * persp));
      zs.add(r.z);
      rot.add(r);
    }

    // 球壳经纬网格 + 顶部高光弧。
    _drawMesh(canvas, center, radius);
    _drawTopHighlight(canvas, center, radius);

    _drawEdges(canvas, center, radius, rot);
    final List<double> nodeRs = _drawNodes(canvas);
    _drawLabels(canvas, size, nodeRs);
  }

  /// 连线：沿球面微弯的贝塞尔曲线；线宽随共现权重，透明度随深度平方渐隐，
  /// 背面（平均 z<0）统一降透明度，只有近端连线明显。
  void _drawEdges(Canvas canvas, Offset center, double radius, List<_V3> rot) {
    final List<_Edge> sortedEdges = List<_Edge>.from(edges)
      ..sort((_Edge a, _Edge b) {
        final double za = (zs[a.a] + zs[a.b]) / 2;
        final double zb = (zs[b.a] + zs[b.b]) / 2;
        return za.compareTo(zb);
      });
    final double invMax = 1.0 / math.max(1, maxWeight);
    final Color edgeColor = Color.lerp(Tga.primary, Tga.cyan, 0.45)!;
    for (final _Edge e in sortedEdges) {
      final double avgZ = (zs[e.a] + zs[e.b]) / 2;
      final double depth = (avgZ + 1) / 2; // 0 远 → 1 近
      final double w = (e.weight * invMax).clamp(0.0, 1.0);
      double alpha = (0.05 + depth * depth * 0.30) * (0.45 + w * 0.55);
      if (avgZ < 0) alpha *= _backDim;
      if (alpha < 0.012) continue;

      // 控制点取大圆中点外推，使连线沿球面微弯而非直穿球心。
      final _V3 a = rot[e.a], b = rot[e.b];
      final _V3 sum = _V3(a.x + b.x, a.y + b.y, a.z + b.z);
      final double sl =
          math.sqrt(sum.x * sum.x + sum.y * sum.y + sum.z * sum.z);
      final _V3 ctrl = sl < 1e-3
          ? _V3(a.x, a.y + 0.5, a.z)
          : _V3(sum.x / sl * 1.05, sum.y / sl * 1.05, sum.z / sl * 1.05);
      final double cp = 1 + ctrl.z * 0.32;
      final Offset c = Offset(center.dx + ctrl.x * radius * cp,
          center.dy + ctrl.y * radius * cp);

      final Path path = Path()
        ..moveTo(screen[e.a].dx, screen[e.a].dy)
        ..quadraticBezierTo(c.dx, c.dy, screen[e.b].dx, screen[e.b].dy);
      canvas.drawPath(
        path,
        Paint()
          ..color = edgeColor.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.45 + w * 1.7 + depth * 0.6
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  /// 节点：径向渐变填充（中心亮、边缘深）+ 同色外发光大圆；背面整体压暗，
  /// 正面随深度加亮；选中节点白描边并按 selT 缓动放大。
  /// 按深度从远到近绘制，返回各节点屏幕半径（标签避让用）。
  List<double> _drawNodes(Canvas canvas) {
    final List<int> order = List<int>.generate(pos.length, (int i) => i)
      ..sort((int a, int b) => zs[a].compareTo(zs[b]));
    final List<double> nodeRs = List<double>.filled(pos.length, 0);
    for (final int i in order) {
      final double depth = (zs[i] + 1) / 2;
      final bool back = zs[i] < 0;
      final bool isSel = i == selected;
      final double degFactor =
          1.0 + math.sqrt((degrees[i] > 0 ? degrees[i] : 1).toDouble()) / 6;
      double nodeR = (2.0 + depth * 2.6) * math.min(degFactor, 2.4) * zoom;
      if (isSel) nodeR *= 1 + 0.45 * _easeOutBack(selT);
      nodeRs[i] = nodeR;

      final Color base =
          Tga.sphereNodes[names[i].hashCode.abs() % Tga.sphereNodes.length];

      // 外发光：同色大圆（alpha 峰值 0.15），近端更强。
      final double glowA =
          (back ? 0.15 * 0.35 : 0.15 * (0.45 + depth * 0.55)) +
              (isSel ? 0.10 : 0.0);
      final double haloR = nodeR * 3.0;
      canvas.drawCircle(
        screen[i],
        haloR,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              base.withValues(alpha: glowA),
              base.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: screen[i], radius: haloR)),
      );

      // 本体：径向渐变，中心亮、边缘深。
      final double bodyA = back ? _backDim + 0.02 : 0.72 + depth * 0.28;
      final Color inner = Color.lerp(base, Colors.white, 0.30 + depth * 0.30)!;
      final Color outer = Color.lerp(base, Tga.bg, 0.45)!;
      canvas.drawCircle(
        screen[i],
        nodeR,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.3, -0.35),
            colors: <Color>[
              inner.withValues(alpha: bodyA),
              outer.withValues(alpha: bodyA),
            ],
          ).createShader(Rect.fromCircle(center: screen[i], radius: nodeR)),
      );

      if (isSel) {
        canvas.drawCircle(
          screen[i],
          nodeR + 1.6,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.92)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      }
    }
    return nodeRs;
  }

  /// 标签：只画"较近（z>0.25）或度数 Top8"的节点，其余点击选中后才显示；
  /// 半透明圆角底衬 + 贪心避让防叠字；背面降透明度。
  void _drawLabels(Canvas canvas, Size size, List<double> nodeRs) {
    final List<int> cands = <int>[];
    for (int i = 0; i < names.length && i < zs.length; i++) {
      if (i == selected) continue; // 最后画，压在最上层
      if (zs[i] > 0.25 || rank[i] < _labelTop) cands.add(i);
    }
    cands.sort((int a, int b) {
      final int c = zs[b].compareTo(zs[a]);
      return c != 0 ? c : rank[a].compareTo(rank[b]);
    });
    if (selected >= 0 && selected < names.length && selected < zs.length) {
      cands.add(selected);
    }

    const double padX = 4.5, padY = 2.0;
    final List<Rect> placed = <Rect>[];
    for (final int i in cands) {
      final bool isSel = i == selected;
      final double alpha =
          zs[i] < 0 ? 0.32 : 0.55 + 0.45 * zs[i].clamp(0.0, 1.0);
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: names[i],
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Tga.text.withValues(alpha: alpha),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 100);

      double dx = screen[i].dx + nodeRs[i] + 5;
      if (dx + tp.width + padX * 2 > size.width - 2) {
        dx = screen[i].dx - nodeRs[i] - 5 - tp.width - padX * 2;
      }
      final double dy = (screen[i].dy - tp.height / 2)
          .clamp(padY, size.height - tp.height - padY * 2)
          .toDouble();
      final Rect pill =
          Rect.fromLTWH(dx, dy, tp.width + padX * 2, tp.height + padY * 2);
      if (!isSel) {
        bool hit = false;
        for (final Rect r in placed) {
          if (r.overlaps(pill)) {
            hit = true;
            break;
          }
        }
        if (hit) continue;
      }
      placed.add(pill);

      final RRect bg = RRect.fromRectAndRadius(pill, const Radius.circular(5));
      canvas.drawRRect(
        bg,
        Paint()
          ..color =
              Tga.card.withValues(alpha: 0.82 * alpha.clamp(0.35, 1.0)),
      );
      canvas.drawRRect(
        bg,
        Paint()
          ..color = (isSel ? Tga.primary : Tga.divider)
              .withValues(alpha: isSel ? 0.75 : 0.6 * alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = isSel ? 1.1 : 0.7,
      );
      tp.paint(canvas, Offset(dx + padX, dy + padY));
    }
  }

  /// 选中放大动画缓动（轻微回弹）。
  static double _easeOutBack(double t) {
    const double c1 = 1.70158, c3 = c1 + 1;
    final double p = t - 1;
    return 1 + c3 * p * p * p + c1 * p * p;
  }

  /// 球壳经纬网格：4 条纬线 + 4 条经线共 8 段椭圆弧，淡蓝低透明。
  void _drawMesh(Canvas canvas, Offset center, double radius) {
    final Paint p = Paint()
      ..color = Tga.primary.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    void drawCircle3D(_V3 Function(int k, int steps) gen) {
      const int steps = 72;
      final Path path = Path();
      bool started = false;
      for (int k = 0; k <= steps; k++) {
        final _V3 r = gen(k % steps, steps).rotateX(rotX).rotateY(rotY);
        final double persp = 1 + r.z * 0.32;
        final Offset o = Offset(
            center.dx + r.x * radius * persp, center.dy + r.y * radius * persp);
        if (!started) {
          path.moveTo(o.dx, o.dy);
          started = true;
        } else {
          path.lineTo(o.dx, o.dy);
        }
      }
      canvas.drawPath(path, p);
    }

    // 纬线
    for (final double y in <double>[-0.72, -0.24, 0.24, 0.72]) {
      final double r = math.sqrt(math.max(0, 1 - y * y));
      drawCircle3D((int k, int steps) {
        final double t = k / steps * 2 * math.pi;
        return _V3(math.cos(t) * r, y, math.sin(t) * r);
      });
    }
    // 经线
    for (final double ph in <double>[
      0.0,
      math.pi / 4,
      math.pi / 2,
      3 * math.pi / 4,
    ]) {
      drawCircle3D((int k, int steps) {
        final double t = k / steps * 2 * math.pi;
        return _V3(math.cos(t) * math.cos(ph), math.sin(t),
            -math.cos(t) * math.sin(ph));
      });
    }
  }

  /// 顶部高光弧：沿外圈左上段的横向渐变描边，深浅主题下都读作顶部受光。
  void _drawTopHighlight(Canvas canvas, Offset center, double radius) {
    final Color hi = Color.lerp(Tga.primary, Tga.text, 0.35)!;
    final Rect ring = Rect.fromCircle(center: center, radius: radius * 1.02);
    canvas.drawArc(
      ring,
      -math.pi * 0.90,
      math.pi * 0.42,
      false,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.topRight,
          colors: <Color>[
            hi.withValues(alpha: 0.0),
            hi.withValues(alpha: 0.22),
            hi.withValues(alpha: 0.0),
          ],
        ).createShader(ring)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _SpherePainter old) =>
      old.rotX != rotX ||
      old.rotY != rotY ||
      old.zoom != zoom ||
      old.revision != revision ||
      old.selected != selected ||
      old.selT != selT;
}

class _V3 {
  const _V3(this.x, this.y, this.z);
  final double x, y, z;

  _V3 rotateY(double a) {
    final double c = math.cos(a), s = math.sin(a);
    return _V3(x * c + z * s, y, -x * s + z * c);
  }

  _V3 rotateX(double a) {
    final double c = math.cos(a), s = math.sin(a);
    return _V3(x, y * c - z * s, y * s + z * c);
  }
}

// ---------------------------------------------------------------------------
// 节点详情底部弹层：真实度数 / 关联实体 / diary 检索摘录 / 可复制 URL
// ---------------------------------------------------------------------------
class _Excerpt {
  const _Excerpt(this.day, this.role, this.text);
  final String day, role, text;
}

class _NodeDetailSheet extends StatefulWidget {
  const _NodeDetailSheet({
    required this.client,
    required this.name,
    required this.degree,
    required this.related,
  });
  final BackendClient client;
  final String name;
  final int degree;
  final List<String> related;

  @override
  State<_NodeDetailSheet> createState() => _NodeDetailSheetState();
}

class _NodeDetailSheetState extends State<_NodeDetailSheet> {
  static final RegExp _urlRe =
      RegExp(r"""https?://[^\s，。；、！？)）】>"'<>]+""");

  bool _loading = true;
  String _error = '';
  List<_Excerpt> _excerpts = <_Excerpt>[];

  @override
  void initState() {
    super.initState();
    _loadExcerpts();
  }

  /// 从 memory_event diary 真实检索包含该词的对话摘录（最多 5 条）。
  Future<void> _loadExcerpts() async {
    try {
      final BridgeEnvelope env = await widget.client
          .sendControl('memory_event', <String, dynamic>{'action': 'diary'});
      final dynamic p = env.payload;
      final Map<String, dynamic> m =
          p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{};
      final List<_Excerpt> out = <_Excerpt>[];
      for (final dynamic d in (m['days'] as List? ?? <dynamic>[])) {
        if (d is! Map) continue;
        final String day = (d['day'] ?? '').toString();
        for (final dynamic e in (d['entries'] as List? ?? <dynamic>[])) {
          if (e is! Map) continue;
          final String text = (e['text'] ?? '').toString();
          if (text.contains(widget.name)) {
            out.add(_Excerpt(day, (e['role'] ?? '').toString(), text));
            if (out.length >= 5) break;
          }
        }
        if (out.length >= 5) break;
      }
      if (!mounted) return;
      setState(() {
        _excerpts = out;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _roleLabel(String role) => switch (role) {
        'user' => '我',
        'assistant' => 'AI',
        'memory' => '记忆',
        _ => role.isEmpty ? '记录' : role,
      };

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('链接已复制到剪贴板')));
  }

  @override
  Widget build(BuildContext context) {
    final List<String> urls = <String>[];
    for (final _Excerpt e in _excerpts) {
      for (final RegExpMatch m in _urlRe.allMatches(e.text)) {
        final String u = m.group(0)!;
        if (!urls.contains(u)) urls.add(u);
      }
    }
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (BuildContext ctx, ScrollController scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: Tga.card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: ListView(
          controller: scrollCtrl,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: Tga.divider,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                    child: Text(widget.name,
                        style: Tga.h2,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis)),
                TgaTag('度数 ${widget.degree}', color: Tga.cyan),
              ],
            ),
            const SizedBox(height: 14),
            Text('关联实体（${widget.related.length}）', style: Tga.h2),
            const SizedBox(height: 8),
            if (widget.related.isEmpty)
              Text('暂无共现关联词', style: Tga.sub)
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final String r in widget.related) TgaTag(r, color: Tga.purple),
                ],
              ),
            const SizedBox(height: 16),
            Text('对话摘录（真实检索，最多 5 条）', style: Tga.h2),
            const SizedBox(height: 8),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.2, color: Tga.primary))),
              )
            else if (_error.isNotEmpty)
              Text('摘录检索失败：$_error', style: Tga.sub)
            else if (_excerpts.isEmpty)
              Text('没有找到包含「${widget.name}」的对话记录', style: Tga.sub)
            else
              for (final _Excerpt e in _excerpts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Tga.bgSoft,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('${e.day} · ${_roleLabel(e.role)}',
                            style: Tga.caption),
                        const SizedBox(height: 4),
                        Text(e.text,
                            style: Tga.sub,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ),
            if (urls.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text('来源链接', style: Tga.h2),
              const SizedBox(height: 6),
              for (final String u in urls)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                          child: Text(u,
                              style: TextStyle(
                                  fontSize: 12, color: Tga.primary),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis)),
                      IconButton(
                        icon: Icon(Icons.copy_rounded,
                            size: 16, color: Tga.textSub),
                        tooltip: '复制链接',
                        onPressed: () => _copyUrl(u),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
