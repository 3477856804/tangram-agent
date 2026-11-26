import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dsh_tokens.dart';

/// TGA 液态玻璃视觉令牌与基础组件。
///
/// 设计目标：在现有 dsh 令牌之上提供半透明表面、细发丝描边、柔和高光与
/// 克制投影；不替换业务页面现有布局，只作为可复用外观层。
class TgaGlass {
  const TgaGlass._();

  /// 玻璃卡片背景：浅色偏白、深色偏冷灰，带轻微透明度供背景透出。
  static BoxDecoration card({
    required BuildContext context,
    double radius = 18,
    BorderRadius? customRadius,
    double opacity = 0.72,
  }) {
    final DshPalette c = DshPalette.of(context);
    final Color surface = c.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: opacity);
    return BoxDecoration(
      color: surface,
      borderRadius: customRadius ?? BorderRadius.circular(radius),
      border: Border.all(
        color: c.borderL2.withValues(alpha: c.isDark ? 0.35 : 0.55),
        width: 1,
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: Colors.black.withValues(alpha: c.isDark ? 0.18 : 0.08),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }

  /// 顶部高光描边：用于玻璃卡片上沿，模拟薄玻璃反光。
  static Paint highlightPaint(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Paint()
      ..color = Colors.white.withValues(alpha: c.isDark ? 0.16 : 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
  }

  /// 标准玻璃间距。
  static double get spaceXs => DshSpace.x4;
  static double get spaceSm => DshSpace.x8;
  static double get spaceMd => DshSpace.x12;
  static double get spaceLg => DshSpace.x16;

  /// 玻璃节点半径建议：图谱与悬浮标记使用较小半径，避免球体臃肿。
  static double nodeRadius(double degreeFactor, double zoom) {
    const double base = 1.05;
    const double depthBoost = 1.15;
    return (base + depthBoost * math.min(degreeFactor, 1.55)) * zoom;
  }
}

/// 玻璃容器组件：包裹子内容并应用统一玻璃外观。
class TgaGlassCard extends StatelessWidget {
  const TgaGlassCard({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding,
    this.opacity = 0.72,
    this.alignment,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double opacity;
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: alignment,
      padding: padding ?? const EdgeInsets.all(DshSpace.x12),
      decoration: TgaGlass.card(
        context: context,
        radius: radius,
        opacity: opacity,
      ),
      child: child,
    );
  }
}
