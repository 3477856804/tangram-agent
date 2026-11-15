import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/tga_3d_page.dart';

/// 鹿桌宠：项目鹿 logo 的程序化桌宠形态。
///
/// 设计取向：
///  * 常驻在 App 根层（MaterialApp.builder），浮在所有业务页之上，
///    但只有它自己的圆形区域接收手势，其余区域 `IgnorePointer`，
///    不会挡住聊天/终端/表单操作。
///  * 可拖到任意位置，位置按屏幕比例持久化（换设备/旋转仍合理）。
///  * 单击换一句「真实能力提示」（说的都是项目里真的有的东西），
///    双击直接打开 3D 建模页看同一只鹿的低模网格，长按出快捷菜单。
///  * 呼吸、眨眼、尾巴摆动全部由 AnimationController 驱动，不耗 CPU 轮询。
class DeerPetOverlay extends StatefulWidget {
  const DeerPetOverlay({super.key});

  @override
  State<DeerPetOverlay> createState() => _DeerPetOverlayState();
}

class _DeerPetOverlayState extends State<DeerPetOverlay>
    with SingleTickerProviderStateMixin {
  static const String _kX = 'tangram.pet.x';
  static const String _kY = 'tangram.pet.y';

  static const List<String> _quips = <String>[
    '沙箱里只有一套 Linux 环境，不会再冒出第二台机器。',
    '沙箱终端里 apk / python / pip 都是真跑，装不上会如实报错。',
    '双击我，能看我这只鹿的低模 3D 网格。',
    '「更多通信」右上角可以主动给微信/QQ/飞书发消息。',
    '万物皆插件和 Super Agent 是内置核心，没有开关页。',
    '3D 建模支持 OBJ / STL / PLY，导出会真写进沙箱目录。',
    '长按我，可以把位置挪回角落。',
    '本地模型推理有前缀缓存和分块预填充，能少的计算就不重算。',
  ];

  late final AnimationController _breath;
  double _fx = 0.86; // 屏宽比例
  double _fy = 0.72; // 屏高比例
  bool _loaded = false;
  String _say = '';
  Timer? _sayTimer;
  bool _dragging = false;
  int _qi = 0;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
    _restore();
  }

  @override
  void dispose() {
    _sayTimer?.cancel();
    _breath.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final double? x = p.getDouble(_kX);
      final double? y = p.getDouble(_kY);
      if (!mounted) return;
      setState(() {
        if (x != null) _fx = x.clamp(0.02, 0.94);
        if (y != null) _fy = y.clamp(0.08, 0.88);
        _loaded = true;
      });
    } on Object {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _save() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setDouble(_kX, _fx);
      await p.setDouble(_kY, _fy);
    } on Object {
      // 存不上就只在本次会话生效，不弹错误打扰用户。
    }
  }

  void _speak(String text) {
    _sayTimer?.cancel();
    setState(() => _say = text);
    _sayTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _say = '');
    });
  }

  void _nextQuip() {
    _qi = (_qi + 1) % _quips.length;
    _speak(_quips[_qi]);
  }

  Future<void> _openMenu() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B2333),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.view_in_ar_outlined, color: Colors.white70),
              title: const Text('看我的 3D 低模', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.of(ctx).pop();
                _open3d();
              },
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline, color: Colors.white70),
              title: const Text('换一句', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.of(ctx).pop();
                _nextQuip();
              },
            ),
            ListTile(
              leading: const Icon(Icons.place_outlined, color: Colors.white70),
              title: const Text('回到右下角', style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.of(ctx).pop();
                setState(() {
                  _fx = 0.86;
                  _fy = 0.72;
                });
                unawaited(_save());
              },
            ),
          ],
        ),
      ),
    );
  }

  void _open3d() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext _) => const Tga3DPage(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final Size screen = MediaQuery.sizeOf(context);
    const double size = 86;
    final double left = (_fx * screen.width).clamp(0, screen.width - size);
    final double top = (_fy * screen.height).clamp(0, screen.height - size);

    return Positioned(
      left: left,
      top: top,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          if (_say.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxWidth: 190),
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF23303F),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _say,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _nextQuip,
            onDoubleTap: _open3d,
            onLongPress: _openMenu,
            onPanStart: (_) => setState(() => _dragging = true),
            onPanUpdate: (DragUpdateDetails d) {
              setState(() {
                _fx = ((left + d.delta.dx) / screen.width).clamp(0.0, 0.94);
                _fy = ((top + d.delta.dy) / screen.height).clamp(0.0, 0.88);
              });
            },
            onPanEnd: (_) {
              setState(() => _dragging = false);
              unawaited(_save());
            },
            child: AnimatedBuilder(
              animation: _breath,
              builder: (BuildContext ctx, Widget? _) {
                final double t = _breath.value;
                final double bob = _dragging ? 0 : math.sin(t * math.pi * 2) * 1.6;
                final bool blink = (t * 1000).round() % 24 < 1;
                return Transform.translate(
                  offset: Offset(0, bob),
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0x14FFFFFF),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x22000000),
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    // 用项目自带的鹿 logo（assets/logo/tangram_deer.png）作为
                    // 桌宠本体；rare 情况下资源缺失才回退到矢量绘制。
                    child: Transform.scale(
                      scaleY: blink ? 0.96 : 1.0,
                      child: Image.asset(
                        'assets/logo/tangram_deer.png',
                        fit: BoxFit.contain,
                        errorBuilder: (_, Object error, Object? stack) =>
                            CustomPaint(painter: _DeerPainter(t: t, blink: blink)),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 鹿的矢量绘制（纯 Canvas）：身体、脖子、头、鹿角、四肢、尾巴、眼睛。
/// 所有坐标按 100×100 画布设计，再由 size 缩放。
class _DeerPainter extends CustomPainter {
  _DeerPainter({required this.t, required this.blink});

  final double t;
  final bool blink;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    final double s = size.width / 100;
    canvas.scale(s, s);

    const Color fur = Color(0xFFC98C57);
    const Color furDark = Color(0xFF8E5C34);
    const Color belly = Color(0xFFF2D9BC);
    const Color antler = Color(0xFFE6C07B);
    const Color ink = Color(0xFF2B1B12);

    final Paint fill = Paint()..style = PaintingStyle.fill;
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.6
      ..color = furDark;

    // 尾巴（轻微摆动）
    final double wag = math.sin(t * math.pi * 4) * 4;
    fill.color = furDark;
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(26 + wag * 0.2, 52), width: 14, height: 8),
      fill,
    );

    // 四肢
    stroke.strokeWidth = 4.2;
    canvas.drawLine(const Offset(40, 66), const Offset(38, 82), stroke);
    canvas.drawLine(const Offset(52, 66), const Offset(50, 82), stroke);
    canvas.drawLine(const Offset(62, 64), const Offset(61, 80), stroke);
    canvas.drawLine(const Offset(72, 62), const Offset(73, 78), stroke);

    // 身体
    fill.color = fur;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(32, 40, 46, 26),
        const Radius.circular(13),
      ),
      fill,
    );
    // 腹部浅色
    fill.color = belly;
    canvas.drawOval(
      const Rect.fromLTWH(44, 56, 26, 10),
      fill,
    );

    // 脖子
    final Path neck = Path()
      ..moveTo(68, 44)
      ..quadraticBezierTo(78, 34, 80, 26)
      ..lineTo(90, 30)
      ..quadraticBezierTo(84, 44, 78, 50)
      ..close();
    fill.color = fur;
    canvas.drawPath(neck, fill);

    // 头
    fill.color = fur;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(76, 18, 20, 14),
        const Radius.circular(7),
      ),
      fill,
    );
    // 吻部
    fill.color = furDark;
    canvas.drawOval(const Rect.fromLTWH(90, 24, 8, 6), fill);

    // 鹿角（两支，带分叉）
    stroke
      ..strokeWidth = 2.4
      ..color = antler;
    canvas.drawLine(const Offset(80, 18), const Offset(76, 8), stroke);
    canvas.drawLine(const Offset(78, 13), const Offset(72, 10), stroke);
    canvas.drawLine(const Offset(84, 17), const Offset(84, 6), stroke);
    canvas.drawLine(const Offset(84, 10), const Offset(90, 7), stroke);

    // 耳朵
    fill.color = furDark;
    canvas.drawOval(const Rect.fromLTWH(72, 20, 7, 4), fill);

    // 眼睛（眨眼时压扁）
    fill.color = ink;
    if (blink) {
      canvas.drawRect(const Rect.fromLTWH(83, 24, 4, 1.2), fill);
    } else {
      canvas.drawOval(const Rect.fromLTWH(83, 22.5, 3.4, 3.4), fill);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DeerPainter old) =>
      old.t != t || old.blink != blink;
}