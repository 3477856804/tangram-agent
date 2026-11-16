import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';

/// 3D 建模工作台。
///
/// 全部几何数据来自内嵌后端 `code_task{action:model3d_*}` 的真实解析结果
/// （OBJ / STL / PLY），本页只做投影绘制与交互：拖拽旋转、双指/滚轮缩放、
/// 自动旋转、视角复位。统计（顶点/三角面/尺寸/体积/是否闭合）都是实算值，
/// 不显示任何写死的示例数字。
class Tga3DPage extends StatefulWidget {
  const Tga3DPage({super.key});

  @override
  State<Tga3DPage> createState() => _Tga3DPageState();
}

class _Tga3DPageState extends State<Tga3DPage> {
  List<double> _vertices = <double>[];
  List<int> _faces = <int>[];
  Map<String, dynamic> _stats = const <String, dynamic>{};
  String _format = '';
  String _name = '';
  int _totalTriangles = 0;
  bool _truncated = false;

  double _rotX = -0.35;
  double _rotY = 0.7;
  double _zoom = 1;
  bool _autoRotate = true;
  bool _busy = false;
  String _error = '';
  Timer? _spin;

  @override
  void initState() {
    super.initState();
    _spin = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!_autoRotate || !mounted) return;
      setState(() => _rotY += 0.012);
    });
    _loadPrimitive('deer');
  }

  @override
  void dispose() {
    _spin?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
      String action, Map<String, dynamic> args) async {
    final BackendClient backend = context.read<BackendClient>();
    final BridgeEnvelope env = await backend.sendControl(
      'code_task',
      <String, dynamic>{'action': action, ...args},
    );
    final dynamic payload = env.payload;
    if (payload is Map) {
      return payload.map((k, v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{'ok': false, 'error': '后端返回了非预期结构'};
  }

  void _apply(Map<String, dynamic> r) {
    if (r['ok'] != true) {
      setState(() {
        _error = (r['error'] ?? '操作失败').toString();
        _busy = false;
      });
      return;
    }
    final dynamic mesh = r['mesh'];
    final List<double> verts = <double>[];
    final List<int> faces = <int>[];
    if (mesh is Map) {
      final dynamic v = mesh['vertices'];
      if (v is List) {
        for (final dynamic e in v) {
          if (e is num) verts.add(e.toDouble());
        }
      }
      final dynamic f = mesh['faces'];
      if (f is List) {
        for (final dynamic e in f) {
          if (e is num) faces.add(e.toInt());
        }
      }
    }
    setState(() {
      _vertices = verts;
      _faces = faces;
      _stats = (r['stats'] is Map)
          ? (r['stats'] as Map).map((k, v) => MapEntry(k.toString(), v))
          : const <String, dynamic>{};
      _format = (r['format'] ?? '').toString();
      _name = (r['name'] ?? '').toString();
      _totalTriangles =
          (mesh is Map ? mesh['triangle_count'] as num? : null)?.toInt() ??
              faces.length ~/ 3;
      _truncated = mesh is Map && mesh['truncated'] == true;
      _error = '';
      _busy = false;
    });
  }

  Future<void> _loadPrimitive(String kind) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final Map<String, dynamic> r =
          await _call('model3d_primitive', <String, dynamic>{'kind': kind});
      _apply(r);
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = '后端未就绪：$e';
      });
    }
  }

  Future<void> _importModel() async {
    final TextEditingController ctrl = TextEditingController();
    final String? path = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('导入模型', style: Tga.h2),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: Tga.body,
          decoration: const InputDecoration(
            hintText: '沙箱内相对路径，如 models3d/lamp.obj',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (path == null || path.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final Map<String, dynamic> r =
          await _call('model3d_import', <String, dynamic>{'path': path});
      _apply(r);
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = '导入失败：$e';
      });
    }
  }

  Future<void> _export(String format) async {
    setState(() => _busy = true);
    try {
      final Map<String, dynamic> r = await _call(
          'model3d_export', <String, dynamic>{'format': format});
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['ok'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已导出 ${r['name']}.$format'
              '（${r['bytes']} 字节）\n${r['path']}'),
        ));
      } else {
        setState(() => _error = (r['error'] ?? '导出失败').toString());
      }
    } on Object catch (e) {
      setState(() {
        _busy = false;
        _error = '导出失败：$e';
      });
    }
  }

  String _fmt(dynamic v, [int digits = 3]) {
    if (v is num) {
      if (v.abs() >= 1000) return v.toStringAsFixed(0);
      return v.toStringAsFixed(digits);
    }
    return '—';
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final Map<String, dynamic> bounds = _stats['bounds'] is Map
        ? Map<String, dynamic>.from(_stats['bounds'] as Map)
        : const <String, dynamic>{};
    final Map<String, dynamic> size = bounds['size'] is Map
        ? Map<String, dynamic>.from(bounds['size'] as Map)
        : const <String, dynamic>{};
    return TgaPage(
      title: '3D 建模',
      actions: <Widget>[
        IconButton(
          tooltip: '导入 OBJ / STL / PLY',
          icon: Icon(Icons.file_open_outlined, color: Tga.primary),
          onPressed: _busy ? null : _importModel,
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 28),
        children: <Widget>[
          TgaCard(
            padding: const EdgeInsets.all(10),
            child: AspectRatio(
              aspectRatio: 1.15,
              child: GestureDetector(
                onPanUpdate: (DragUpdateDetails d) => setState(() {
                  _autoRotate = false;
                  _rotY += d.delta.dx * 0.012;
                  _rotX = (_rotX + d.delta.dy * 0.012).clamp(-1.5, 1.5);
                }),
                onScaleUpdate: (ScaleUpdateDetails d) => setState(() {
                  _zoom = (_zoom * (1 + (d.scale - 1) * 0.6)).clamp(0.35, 4.5);
                }),
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _MeshPainter(
                          vertices: _vertices,
                          faces: _faces,
                          rotX: _rotX,
                          rotY: _rotY,
                          zoom: _zoom,
                          line: Tga.primary,
                          shade: Tga.primaryDeep,
                          background: Tga.cardAlt,
                        ),
                      ),
                    ),
                    if (_vertices.isEmpty)
                      Center(
                        child: Text(
                          _busy ? '加载中…' : '还没有模型',
                          style: Tga.sub,
                        ),
                      ),
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Row(
                        children: <Widget>[
                          _chip(
                            icon: _autoRotate
                                ? Icons.pause_circle_outline
                                : Icons.play_circle_outline,
                            onTap: () =>
                                setState(() => _autoRotate = !_autoRotate),
                          ),
                          const SizedBox(width: 6),
                          _chip(
                            icon: Icons.center_focus_strong_outlined,
                            onTap: () => setState(() {
                              _rotX = -0.35;
                              _rotY = 0.7;
                              _zoom = 1;
                            }),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_error.isNotEmpty)
            TgaCard(
              child: Text(_error,
                  style: Tga.sub.copyWith(color: Tga.red)),
            ),
          const TgaGroupTitle('模型'),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _name.isEmpty ? '未载入' : _name,
                        style: Tga.h2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_format.isNotEmpty) TgaTag(_format),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '顶点 ${_stats['vertices'] ?? 0} · '
                  '三角面 ${_stats['triangles'] ?? 0}'
                  '${_truncated ? '（显示前 $_totalTriangles 中的一部分）' : ''}',
                  style: Tga.sub,
                ),
                const SizedBox(height: 4),
                Text(
                  '尺寸 ${_fmt(size['x'], 2)} × ${_fmt(size['y'], 2)} × '
                  '${_fmt(size['z'], 2)} · 表面积 ${_fmt(_stats['surface_area'], 2)}',
                  style: Tga.caption,
                ),
                const SizedBox(height: 4),
                Text(
                  '体积 ${_fmt(_stats['volume'])} · '
                  '${_stats['watertight'] == true ? '闭合（可打印）' : '非闭合'}',
                  style: Tga.caption,
                ),
              ],
            ),
          ),
          const TgaGroupTitle('生成与导出'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.pets_outlined,
                  iconBg: Tga.iconGoldBg,
                  iconColor: Tga.iconGold,
                  title: '低模鹿（品牌形象）',
                  subtitle: '按项目鹿 logo 程序化生成的真实网格，可导出继续加工',
                  onTap: _busy ? () {} : () => _loadPrimitive('deer'),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.crop_square_rounded,
                  iconBg: Tga.iconBlueBg,
                  iconColor: Tga.iconBlue,
                  title: '立方体',
                  subtitle: '单位立方体（1×1×1），用于验证缩放与导出链路',
                  onTap: _busy ? () {} : () => _loadPrimitive('cube'),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.save_alt_rounded,
                  iconBg: Tga.iconCyanBg,
                  iconColor: Tga.iconCyan,
                  title: '导出 OBJ',
                  subtitle: '写入沙箱 models3d/，可直接给切片或渲染工具',
                  onTap: _busy ? () {} : () => _export('obj'),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.layers_outlined,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: '导出二进制 STL',
                  subtitle: '50 字节/面，保留法向，通用 3D 打印格式',
                  onTap: _busy ? () {} : () => _export('stl'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '拖拽旋转、双指缩放；「导入」支持 OBJ / STL（ASCII+二进制）/ '
              'PLY（ASCII）。所有数值由网格真算，导出文件真实写进沙箱目录。',
              style: Tga.caption,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip({required IconData icon, required VoidCallback onTap}) {
    return Material(
      color: Tga.card,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, size: 18, color: Tga.primary),
        ),
      ),
    );
  }
}

/// 线框 + 半透明面片投影绘制。
///
/// 旋转 → 透视投影 → 按平均深度排序（远到近），面片亮度按法向与光源夹角
/// 变化，避免纯线框看不出结构。空网格直接跳过，不画任何占位图形。
class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.vertices,
    required this.faces,
    required this.rotX,
    required this.rotY,
    required this.zoom,
    required this.line,
    required this.shade,
    required this.background,
  });

  final List<double> vertices;
  final List<int> faces;
  final double rotX;
  final double rotY;
  final double zoom;
  final Color line;
  final Color shade;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    if (vertices.length < 9 || faces.length < 3) return;
    final int count = vertices.length ~/ 3;
    double radius = 0.0001;
    for (int i = 0; i < count; i++) {
      final double x = vertices[i * 3];
      final double y = vertices[i * 3 + 1];
      final double z = vertices[i * 3 + 2];
      radius = math.max(radius, math.sqrt(x * x + y * y + z * z));
    }
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final double base = math.min(size.width, size.height) / (2.6 * radius) * zoom;

    final double sx = math.sin(rotX), cxr = math.cos(rotX);
    final double sy = math.sin(rotY), cyr = math.cos(rotY);

    final List<Offset> pts = List<Offset>.filled(count, Offset.zero);
    final List<double> depth = List<double>.filled(count, 0);
    for (int i = 0; i < count; i++) {
      double x = vertices[i * 3];
      double y = vertices[i * 3 + 1];
      double z = vertices[i * 3 + 2];
      // X 轴
      final double y1 = y * cxr - z * sx;
      final double z1 = y * sx + z * cxr;
      // Y 轴
      final double x2 = x * cyr + z1 * sy;
      final double z2 = -x * sy + z1 * cyr;
      depth[i] = z2;
      pts[i] = Offset(cx + x2 * base, cy - y1 * base);
    }

    final List<int> order = List<int>.generate(faces.length ~/ 3, (int i) => i);
    order.sort((int a, int b) {
      final int ia = faces[a * 3], ib = faces[b * 3];
      final int ja = faces[a * 3 + 1], jb = faces[b * 3 + 1];
      final int ka = faces[a * 3 + 2], kb = faces[b * 3 + 2];
      final double za = (depth[ia] + depth[ja] + depth[ka]) / 3;
      final double zb = (depth[ib] + depth[jb] + depth[kb]) / 3;
      return za.compareTo(zb);
    });

    final Paint fill = Paint()..style = PaintingStyle.fill;
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = line.withValues(alpha: 0.55);

    for (final int f in order) {
      final int a = faces[f * 3];
      final int b = faces[f * 3 + 1];
      final int c = faces[f * 3 + 2];
      if (a >= count || b >= count || c >= count) continue;
      final Offset p1 = pts[a];
      final Offset p2 = pts[b];
      final Offset p3 = pts[c];
      // 屏幕空间法向（叉积 z 分量）用于判断朝向与做平面着色。
      final double cross =
          (p2.dx - p1.dx) * (p3.dy - p1.dy) - (p2.dy - p1.dy) * (p3.dx - p1.dx);
      final double shadeMix = (cross.abs() / 900).clamp(0.0, 1.0);
      fill.color = Color.lerp(shade.withValues(alpha: 0.16),
          shade.withValues(alpha: 0.5), shadeMix)!;
      final Path path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..lineTo(p2.dx, p2.dy)
        ..lineTo(p3.dx, p3.dy)
        ..close();
      if (cross >= 0) {
        canvas.drawPath(path, fill);
      }
      canvas.drawPath(path, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _MeshPainter old) =>
      old.rotX != rotX ||
      old.rotY != rotY ||
      old.zoom != zoom ||
      old.vertices != vertices ||
      old.faces != faces ||
      old.line != line ||
      old.background != background;
}