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
/// - 斐波那契球面布局 + 透视投影：近大远小、近亮远暗；
///   节点带径向光晕、按词哈希分五色类别配色、度数越大节点越大；
///   边按共现权重调粗细/透明度；球面经纬网格更精致；
///   拖拽旋转带惯性衰减，空闲时缓慢自转；双指/滚轮缩放。
/// - 标签：度数 Top12 常显，其余随缩放渐显。
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

  /// 每帧：非拖拽时应用惯性 + 缓慢自转。
  void _onTick(Duration dt) {
    if (_dragging || _names.isEmpty) return;
    if (_velY.abs() < 0.00012 && _velX.abs() < 0.00012) {
      // 惯性耗尽后仅保持极慢自转，避免无意义高频重绘。
      setState(() => _rotY += 0.0016);
      return;
    }
    setState(() {
      _rotY += _velY;
      _rotX = (_rotX + _velX).clamp(-1.4, 1.4).toDouble();
      _velY *= 0.94;
      _velX *= 0.94;
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
    if (bi >= 0) _showDetails(bi);
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
  });

  final double rotX, rotY, zoom;
  final List<_V3> pos;
  final List<int> degrees;
  final List<String> names;
  final List<int> rank;
  final List<_Edge> edges;
  final int maxWeight;
  final int revision;

  /// 投影结果写回（命中测试用）。
  final List<Offset> screen;
  final List<double> zs;

  /// 标签常显的度数 Top N。
  static const int _labelTop = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double radius = math.min(size.width, size.height) / 2 * 0.82 * zoom;

    // 背景辉光：整体球体一层柔和径向光。
    final Rect glowRect = Rect.fromCircle(center: center, radius: radius * 1.4);
    canvas.drawCircle(
      center,
      radius * 1.4,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            Tga.primary.withValues(alpha: 0.10),
            Tga.primary.withValues(alpha: 0.0),
          ],
        ).createShader(glowRect),
    );

    // 外圈轮廓。
    canvas.drawCircle(
      center,
      radius * 1.02,
      Paint()
        ..color = Tga.primary.withValues(alpha: 0.24)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1,
    );

    // 旋转 + 透视投影（写回 screen/zs 供命中测试）。
    screen.clear();
    zs.clear();
    for (final _V3 v in pos) {
      final _V3 r = v.rotateX(rotX).rotateY(rotY);
      final double persp = 1 + r.z * 0.32;
      screen.add(Offset(center.dx + r.x * radius * persp,
          center.dy + r.y * radius * persp));
      zs.add(r.z);
    }

    _drawMesh(canvas, center, radius);

    // 连线：按深度从远到近；粗细/透明度随共现权重。
    final List<_Edge> sortedEdges = List<_Edge>.from(edges)
      ..sort((_Edge a, _Edge b) {
        final double za = (zs[a.a] + zs[a.b]) / 2;
        final double zb = (zs[b.a] + zs[b.b]) / 2;
        return za.compareTo(zb);
      });
    final double invMax = 1.0 / math.max(1, maxWeight);
    for (final _Edge e in sortedEdges) {
      final Offset p = screen[e.a];
      final Offset q = screen[e.b];
      final double depth = ((zs[e.a] + zs[e.b]) / 2 + 1) / 2; // 0 远 → 1 近
      final double w = (e.weight * invMax).clamp(0.0, 1.0);
      final double alpha = (0.04 + depth * 0.20) * (0.45 + w * 0.55);
      canvas.drawLine(
        p,
        q,
        Paint()
          ..color = const Color(0xFF8FA0C4).withValues(alpha: alpha)
          ..strokeWidth = 0.4 + w * 1.7 + depth * 0.5
          ..strokeCap = StrokeCap.round,
      );
    }

    // 节点：按深度从远到近（近大远小、近亮远暗 + 径向光晕）。
    final List<int> order = List<int>.generate(pos.length, (int i) => i)
      ..sort((int a, int b) => zs[a].compareTo(zs[b]));
    final List<double> nodeRs = List<double>.filled(pos.length, 0);
    for (final int i in order) {
      final double depth = (zs[i] + 1) / 2;
      final double degFactor =
          1.0 + math.sqrt((degrees[i] > 0 ? degrees[i] : 1).toDouble()) / 6;
      final double nodeR =
          (2.0 + depth * 2.6) * math.min(degFactor, 2.4) * zoom;
      nodeRs[i] = nodeR;
      final Color base =
          Tga.sphereNodes[names[i].hashCode.abs() % Tga.sphereNodes.length];
      final Color c = Color.lerp(
              base.withValues(alpha: 0.42), base, 0.35 + depth * 0.65) ??
          base;
      // 径向光晕（近端更强）。
      if (depth > 0.45) {
        final double haloR = nodeR * 3.0;
        canvas.drawCircle(
          screen[i],
          haloR,
          Paint()
            ..shader = RadialGradient(
              colors: <Color>[
                c.withValues(alpha: 0.30 * depth),
                c.withValues(alpha: 0.0),
              ],
            ).createShader(Rect.fromCircle(center: screen[i], radius: haloR)),
        );
      }
      canvas.drawCircle(screen[i], nodeR, Paint()..color = c);
    }

    // 标签：Top N 常显，其余随缩放渐显；只画前半球。
    for (final int i in order.reversed) {
      if (zs[i] < 0.1) continue;
      final double depth = (zs[i] + 1) / 2;
      final double rankAlpha = rank[i] < _labelTop
          ? 1.0
          : ((zoom - 1.0) / 1.2).clamp(0.0, 1.0);
      final double alpha =
          rankAlpha * ((depth - 0.5) / 0.5).clamp(0.0, 1.0);
      if (alpha <= 0.03) continue;
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: names[i],
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: Tga.text.withValues(alpha: alpha * 0.92),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 110);
      tp.paint(canvas,
          Offset(screen[i].dx + nodeRs[i] + 3, screen[i].dy - tp.height / 2));
    }
  }

  /// 球面经纬网格：3 条纬线 + 2 条经线，细淡蓝。
  void _drawMesh(Canvas canvas, Offset center, double radius) {
    final Paint p = Paint()
      ..color = Tga.primary.withValues(alpha: 0.055)
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
    for (final double y in <double>[-0.55, 0.0, 0.55]) {
      final double r = math.sqrt(math.max(0, 1 - y * y));
      drawCircle3D((int k, int steps) {
        final double t = k / steps * 2 * math.pi;
        return _V3(math.cos(t) * r, y, math.sin(t) * r);
      });
    }
    // 经线
    for (final double ph in <double>[0.0, math.pi / 2]) {
      drawCircle3D((int k, int steps) {
        final double t = k / steps * 2 * math.pi;
        return _V3(
            math.cos(t) * math.cos(ph), math.sin(t), -math.cos(t) * math.sin(ph));
      });
    }
  }

  @override
  bool shouldRepaint(covariant _SpherePainter old) =>
      old.rotX != rotX ||
      old.rotY != rotY ||
      old.zoom != zoom ||
      old.revision != revision;
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
