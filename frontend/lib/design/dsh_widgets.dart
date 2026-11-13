import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dsh_tokens.dart';

/// TGA (tangram-agent) —— dsh 风格的基础组件。
///
/// 尺寸/圆角/描边全部来自 [DshSpace] / [DshR] / [DshPalette]，
/// 业务代码只负责组合，不重新发明样式。

/// 品牌标记：七巧板**鹿**，来自用户提供的唯一真源 logo/tangram.svg。
///
/// 对应 dsh 空会话页的鲸鱼标：那个位置放的是各自的产品 logo，不是通用方块。
/// 资产由 scripts/gen_brand_assets.py 从真源裁出纯鹿并渲染为透明 PNG，
/// 这里用 colorBlendMode.srcIn 按当前主题色染色，浅色/深色都能显示。
/// 旧的「四个方片 CustomPaint」是占位图形、不是品牌 logo，已删除。
class TangramGlyph extends StatelessWidget {
  const TangramGlyph({super.key, this.size = 24, this.color});

  final double size;
  final Color? color;

  /// 鹿 PNG 在 assets/logo/ 下，pubspec 已声明该目录。
  static const String assetPath = 'assets/logo/tangram_deer.png';

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? DshPalette.of(context).labelPrimary;
    return Image.asset(
      assetPath,
      width: size,
      height: size,
      color: c,
      colorBlendMode: BlendMode.srcIn,
      filterQuality: FilterQuality.high,
      // 资产恒定存在；若打包遗漏也要显式留白，而不是画出假方块。
      errorBuilder: (_, __, ___) => SizedBox(width: size, height: size),
    );
  }
}

/// 品牌字标：鹿标 + 应用名 + 拉丁代号（对应 dsh 的鲸鱼 + deepseek + HARNESS）。
class DshWordmark extends StatelessWidget {
  const DshWordmark({
    super.key,
    this.glyphSize = 24,
    this.title = 'TGA',
    this.suffix = 'TANGRAM',
    this.titleSize = 18,
    this.showSuffix = true,
  });

  final double glyphSize;
  final String title;
  final String suffix;
  final double titleSize;
  final bool showSuffix;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TangramGlyph(size: glyphSize, color: c.labelPrimary),
        SizedBox(width: DshSpace.x8),
        Flexible(
          child: Text(
            title,
            style: TextStyle(
              fontSize: titleSize,
              height: 24 / titleSize,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: c.labelPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (showSuffix) ...<Widget>[
          SizedBox(width: DshSpace.x6),
          Text(
            suffix,
            style: DshType.xxxs11m.copyWith(
              letterSpacing: 1,
              color: c.labelTertiary,
            ),
          ),
        ],
      ],
    );
  }
}

/// 紧凑图标按钮（dsh R8 图标按钮，视觉 40dp）。
class DshIconButton extends StatelessWidget {
  const DshIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
    this.iconSize = 18,
    this.tint,
    this.background,
    this.tooltip,
    this.radius = DshR.sm,
    this.enabled = true,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? tint;
  final Color? background;
  final String? tooltip;
  final double radius;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final bool on = enabled && onTap != null;
    final Widget button = Opacity(
      opacity: enabled ? 1 : 0.4,
      child: InkWell(
        onTap: on ? onTap : null,
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(radius),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: iconSize,
            color: tint ?? c.labelSecondary,
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

enum DshButtonVariant { primary, outline, ghost, danger }

/// dsh 按钮：sm 28 / md 36 / lg 44，圆角分别 8 / 12 / 16。
class DshButton extends StatelessWidget {
  const DshButton({
    super.key,
    required this.label,
    this.onTap,
    this.variant = DshButtonVariant.primary,
    this.height = 36,
    this.radius = DshR.md,
    this.icon,
    this.expand = false,
    this.enabled = true,
    this.fontSize = 14,
    this.padding = 14,
  });

  final String label;
  final VoidCallback? onTap;
  final DshButtonVariant variant;
  final double height;
  final double radius;
  final IconData? icon;
  final bool expand;
  final bool enabled;
  final double fontSize;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    Color bg = Colors.transparent;
    Color fg = c.labelPrimary;
    Color? stroke;
    if (variant == DshButtonVariant.primary) {
      bg = c.brandPrimary;
      fg = c.labelOnPrimary;
    } else if (variant == DshButtonVariant.outline) {
      fg = c.labelPrimary;
      stroke = c.borderL3;
    } else if (variant == DshButtonVariant.ghost) {
      fg = c.labelSecondary;
    } else {
      bg = c.hoverDanger;
      fg = c.error;
    }
    final bool on = enabled && onTap != null;
    final Widget body = Container(
      height: height,
      padding: EdgeInsets.symmetric(horizontal: padding),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
        border: stroke == null
            ? null
            : Border.all(color: stroke, width: dshHairline),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: fg),
            SizedBox(width: DshSpace.x4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              height: 22 / fontSize,
              fontWeight: FontWeight.w500,
              color: fg,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: on ? onTap : null,
          borderRadius: BorderRadius.circular(radius),
          child: body,
        ),
      ),
    );
  }
}

/// 输入区的胶囊小控件：高 28，圆角 8，13/20 medium 次级色，尾部带 chevron。
class DshChip extends StatelessWidget {
  const DshChip({
    super.key,
    this.icon,
    this.label,
    this.onTap,
    this.tint,
    this.background,
    this.showChevron = true,
    this.maxLabelWidth = 132,
  });

  final IconData? icon;
  final String? label;
  final VoidCallback? onTap;
  final Color? tint;
  final Color? background;
  final bool showChevron;
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final Color fg = tint ?? c.labelSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DshR.sm),
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: EdgeInsets.only(
          left: icon == null ? DshSpace.x8 : DshSpace.x6,
          right: DshSpace.x4,
        ),
        decoration: BoxDecoration(
          color: background ?? Colors.transparent,
          borderRadius: BorderRadius.circular(DshR.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) Icon(icon, size: 14, color: fg),
            if (label != null) ...<Widget>[
              if (icon != null) SizedBox(width: DshSpace.x4),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxLabelWidth),
                child: Text(
                  label!,
                  style: DshType.xs13m.copyWith(color: fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (showChevron) ...<Widget>[
              SizedBox(width: DshSpace.x2),
              Icon(Icons.expand_more_rounded, size: 14, color: c.labelTertiary),
            ],
          ],
        ),
      ),
    );
  }
}

enum DshTone { neutral, info, success, warn, error }

/// 只读胶囊（dsh Tag）。
class DshTag extends StatelessWidget {
  const DshTag({
    super.key,
    required this.label,
    this.tone = DshTone.neutral,
    this.mono = false,
  });

  final String label;
  final DshTone tone;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    Color bg = c.selector;
    Color fg = c.labelSecondary;
    if (tone == DshTone.info) {
      bg = c.businessTertiary;
      fg = c.business;
    } else if (tone == DshTone.success) {
      bg = c.successTertiary;
      fg = c.success;
    } else if (tone == DshTone.warn) {
      bg = c.warnTertiary;
      fg = c.warnLabel;
    } else if (tone == DshTone.error) {
      bg = c.hoverDanger;
      fg = c.error;
    }
    final TextStyle style = mono
        ? DshType.mono11.copyWith(color: fg)
        : DshType.xxxs11m.copyWith(color: fg, height: 18 / 11);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: style, maxLines: 1),
    );
  }
}

/// 圆点状态（dsh StateDot）：6dp。
class DshDot extends StatelessWidget {
  const DshDot({super.key, required this.color, this.size = 6});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// 旋转弧线（dsh 的进行中指示）。
class DshSpinner extends StatefulWidget {
  const DshSpinner({super.key, this.size = 14, this.color, this.stroke = 1.5});

  final double size;
  final Color? color;
  final double stroke;

  @override
  State<DshSpinner> createState() => _DshSpinnerState();
}

class _DshSpinnerState extends State<DshSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          return Transform.rotate(
            angle: _controller.value * 2 * math.pi,
            child: CustomPaint(
              painter: _SpinnerPainter(
                color: widget.color ?? c.labelTertiary,
                stroke: widget.stroke,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter({required this.color, required this.stroke});

  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    final double inset = stroke / 2;
    final Rect rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - stroke,
      size.height - stroke,
    );
    final Paint track = Paint()
      ..color = color.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    final Paint arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, 2 * math.pi, false, track);
    canvas.drawArc(rect, -math.pi / 2, 1.75, false, arc);
  }

  @override
  bool shouldRepaint(_SpinnerPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.stroke != stroke;
}

/// 发送键：34dp 蓝色圆，空稿时降透明度；运行时是停止。
class DshSendButton extends StatelessWidget {
  const DshSendButton({
    super.key,
    required this.enabled,
    required this.onSend,
    this.running = false,
    this.onStop,
    this.size = 34,
  });

  final bool enabled;
  final VoidCallback onSend;
  final bool running;
  final VoidCallback? onStop;
  final double size;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final bool stop = running && !enabled;
    final bool on = stop || enabled;
    return Opacity(
      opacity: on ? 1 : 0.4,
      child: InkWell(
        onTap: () {
          if (stop) {
            onStop?.call();
          } else if (enabled) {
            onSend();
          }
        },
        customBorder: const CircleBorder(),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: c.business, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: CustomPaint(
            size: Size(size * 0.47, size * 0.47),
            painter: _SendGlyphPainter(stop: stop),
          ),
        ),
      ),
    );
  }
}

class _SendGlyphPainter extends CustomPainter {
  const _SendGlyphPainter({required this.stop});

  final bool stop;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()..color = Colors.white;
    if (stop) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(size.width * 0.18, size.height * 0.18,
              size.width * 0.64, size.height * 0.64),
          const Radius.circular(3),
        ),
        p,
      );
      return;
    }
    final double w = size.width * 0.1;
    final double cx = size.width / 2;
    final double top = size.height * 0.08;
    final double bottom = size.height * 0.92;
    final Paint line = Paint()
      ..color = Colors.white
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(cx, top), Offset(cx, bottom), line);
    final double head = size.width * 0.26;
    canvas.drawLine(Offset(cx, top), Offset(cx - head, top + head), line);
    canvas.drawLine(Offset(cx, top), Offset(cx + head, top + head), line);
  }

  @override
  bool shouldRepaint(_SendGlyphPainter oldDelegate) => oldDelegate.stop != stop;
}

/// 0.5dp 发丝分隔线。
class DshDivider extends StatelessWidget {
  const DshDivider({super.key, this.indent = 0, this.color});

  final double indent;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Container(
      height: dshHairline,
      margin: EdgeInsets.only(left: indent),
      color: color ?? c.borderL2,
    );
  }
}

/// 次级页统一顶栏：返回 / 标题 / 右侧动作，高 52。
class DshTopBar extends StatelessWidget implements PreferredSizeWidget {
  const DshTopBar({
    super.key,
    required this.title,
    this.onBack,
    this.actions = const <Widget>[],
    this.leading,
    this.padding = const EdgeInsets.symmetric(horizontal: 6),
  });

  final String title;
  final VoidCallback? onBack;
  final List<Widget> actions;
  final Widget? leading;
  final EdgeInsetsGeometry padding;

  @override
  Size get preferredSize => const Size.fromHeight(52);

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return SizedBox(
      height: 52,
      child: Padding(
        padding: padding,
        child: Row(
          children: <Widget>[
            if (leading != null)
              leading!
            else if (onBack != null)
              DshIconButton(
                icon: Icons.chevron_left_rounded,
                iconSize: 22,
                tint: c.labelPrimary,
                onTap: onBack,
                tooltip: '返回',
              )
            else
              const SizedBox(width: DshSpace.x8),
            const SizedBox(width: DshSpace.x4),
            Expanded(
              child: Text(
                title,
                style: DshType.s14m.copyWith(color: c.labelPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }
}

/// 设置卡片：R20，0.5dp 描边，内部行用发丝线分隔。
class DshSettingsCard extends StatelessWidget {
  const DshSettingsCard({super.key, required this.children, this.radius = DshR.xl});

  final List<Widget> children;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < children.length; i++) {
      if (i > 0) rows.add(DshDivider(indent: 16, color: c.borderL2));
      rows.add(children[i]);
    }
    return Container(
      decoration: dshFlat(c, radius: radius),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    );
  }
}

/// 设置行：标题 / 说明 / 尾随控件。
class DshSettingsRow extends StatelessWidget {
  const DshSettingsRow({
    super.key,
    required this.title,
    this.description,
    this.leading,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.stacked = false,
  });

  final String title;
  final String? description;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final Widget labels = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          style: DshType.s14.copyWith(color: titleColor ?? c.labelPrimary),
        ),
        if (description != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            description!,
            style: DshType.xs13.copyWith(color: c.labelTertiary),
          ),
        ],
      ],
    );
    final Widget body = stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              labels,
              if (trailing != null) ...<Widget>[
                const SizedBox(height: DshSpace.x8),
                trailing!,
              ],
            ],
          )
        : Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: DshSpace.x12),
              ],
              Expanded(child: labels),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: DshSpace.x12),
                trailing!,
              ],
            ],
          );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: body,
      ),
    );
  }
}

/// 分组标题（设置页用）。
class DshGroupLabel extends StatelessWidget {
  const DshGroupLabel({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Text(label, style: DshType.xs13m.copyWith(color: c.labelTertiary)),
    );
  }
}

/// 底部动作面板：dsh 菜单材质（近不透明填充 + R16 + 发丝描边）。
Future<T?> showDshSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: DshPalette.of(context).scrim,
    isScrollControlled: true,
    builder: (BuildContext ctx) {
      final DshPalette c = DshPalette.of(ctx);
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Container(
            decoration: BoxDecoration(
              color: c.isDark ? const Color(0xFF303136) : const Color(0xFFF8F9FA),
              borderRadius: BorderRadius.circular(DshR.lg),
              border: Border.all(color: c.borderL2, width: dshHairline),
            ),
            child: builder(ctx),
          ),
        ),
      );
    },
  );
}
