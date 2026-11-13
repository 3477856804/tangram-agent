import 'package:flutter/material.dart';

import '../../design/dsh_tokens.dart';
import '../../design/dsh_widgets.dart';
import '../core/theme/tangram_palette.dart';

enum GlassQuality { minimal, standard, premium }

/// 品牌标记：单色的七巧板图形（对应 dsh 的鲸鱼标）。
///
/// 旧参数（label / fontSize / elevated）保留，方便已有调用点不改代码。
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 44,
    this.radius,
    this.label = '檀',
    this.fontSize,
    this.elevated = true,
  });

  final double size;
  final double? radius;
  final String label;
  final double? fontSize;
  final bool elevated;

  @override
  Widget build(BuildContext context) {
    return TangramGlyph(size: size, color: DshPalette.of(context).labelPrimary);
  }
}

/// 页面底色：dsh 是纯色表面，没有背景光晕/网格。
class BrandBackground extends StatelessWidget {
  const BrandBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return ColoredBox(
      color: c.bgBase,
      child: child ?? const SizedBox.expand(),
    );
  }
}

/// 卡片：平铺表面 + 0.5dp 描边（旧 GlassCard 的名字保持不变）。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(TangramSpacing.lg),
    this.margin = EdgeInsets.zero,
    this.radius = TangramRadii.lg,
    this.blur = 0,
    this.gradient,
    this.tint,
    this.borderColor,
    this.onTap,
    this.quality = GlassQuality.minimal,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double radius;
  final double blur;
  final Gradient? gradient;
  final Color? tint;
  final Color? borderColor;
  final VoidCallback? onTap;
  final GlassQuality quality;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final BorderRadius shape = BorderRadius.circular(radius);
    final Widget surface = Container(
      decoration: BoxDecoration(
        color: tint ?? c.bgLayer2,
        borderRadius: shape,
        border: Border.all(
          color: borderColor ?? c.borderL4,
          width: dshHairline,
        ),
      ),
      padding: padding,
      child: child,
    );
    final Widget wrapped = onTap == null
        ? surface
        : Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: shape,
              onTap: onTap,
              child: surface,
            ),
          );
    return Padding(padding: margin, child: wrapped);
  }
}

/// 面板：R28 的大容器（旧名 GlassPanel）。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(TangramSpacing.xl),
    this.margin = EdgeInsets.zero,
    this.radius = TangramRadii.panel,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: padding,
      margin: margin,
      radius: radius,
      child: child,
    );
  }
}

/// 分组标题：dsh 用一枚次级色小标题，不用色条。
class SectionTitle extends StatelessWidget {
  const SectionTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.accent,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: TangramSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 16, color: c.labelTertiary),
            const SizedBox(width: DshSpace.x6),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: DshType.xs13m.copyWith(color: c.labelTertiary),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: DshType.xxs12.copyWith(color: c.labelCaption),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 状态胶囊（dsh Tag）。
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final Color fg = color ?? c.business;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 7 : 8,
        vertical: 1,
      ),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: dense ? 11 : 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: (dense ? DshType.xxxs11m : DshType.xxs12m).copyWith(
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态：图标 + 标题 + 说明 + 动作，全部中性色。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: TangramSpacing.xl,
          vertical: compact ? TangramSpacing.lg : TangramSpacing.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: compact ? 40 : 52,
              height: compact ? 40 : 52,
              decoration: BoxDecoration(
                color: c.bgModule,
                borderRadius: BorderRadius.circular(DshR.md),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: compact ? 20 : 24, color: c.labelTertiary),
            ),
            const SizedBox(height: TangramSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: DshType.s14m.copyWith(color: c.labelPrimary),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: DshSpace.x6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: DshType.xs13.copyWith(color: c.labelTertiary),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: TangramSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误态：图标 + 中文原因 +（可选）技术详情 +（可选）重试。
/// 中性偏警示配色，与 EmptyState 同源但表达失败，供云端调用失败等场景复用。
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.title,
    this.message,
    this.details,
    this.onRetry,
    this.icon = Icons.error_outline_rounded,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? details;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: TangramSpacing.xl,
          vertical: compact ? TangramSpacing.lg : TangramSpacing.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: compact ? 40 : 52,
              height: compact ? 40 : 52,
              decoration: BoxDecoration(
                color: c.warnTertiary,
                borderRadius: BorderRadius.circular(DshR.md),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: compact ? 20 : 24, color: c.warn),
            ),
            const SizedBox(height: TangramSpacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: DshType.s14m.copyWith(color: c.labelPrimary),
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: DshSpace.x6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: DshType.xs13.copyWith(color: c.labelTertiary),
              ),
            ],
            if (details != null) ...<Widget>[
              const SizedBox(height: DshSpace.x6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(DshSpace.x8),
                decoration: BoxDecoration(
                  color: c.bgModule,
                  borderRadius: BorderRadius.circular(DshR.sm),
                ),
                child: Text(
                  details!,
                  style: DshType.xxxs11.copyWith(color: c.labelCaption),
                ),
              ),
            ],
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: TangramSpacing.lg),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 信息行：图标 + 标题 + 副标题 + 尾随控件。
class InfoTile extends StatelessWidget {
  const InfoTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.color,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final Color fg = color ?? c.labelSecondary;
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: TangramSpacing.lg,
        vertical: TangramSpacing.md,
      ),
      radius: TangramRadii.md,
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(DshR.sm),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: fg, size: 17),
          ),
          const SizedBox(width: TangramSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: DshType.s14.copyWith(color: c.labelPrimary),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: DshType.xs13.copyWith(color: c.labelTertiary),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class PanelPage extends StatelessWidget {
  const PanelPage({
    super.key,
    required this.children,
    this.padding,
    this.maxWidth = 1120,
  });

  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double horizontal = constraints.maxWidth >= 720
            ? TangramSpacing.xxl
            : TangramSpacing.lg;
        return ListView(
          padding:
              padding ??
              EdgeInsets.symmetric(
                horizontal: horizontal,
                vertical: TangramSpacing.xl,
              ),
          children: <Widget>[
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
