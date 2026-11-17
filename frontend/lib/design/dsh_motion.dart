import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// TGA 统一动效令牌与交互反馈原语。
///
/// 目的：把散落在各页面里的「硬编码毫秒数 / 生硬的无反馈点击」收敛成一套
/// 有节奏的缓动规范，让界面切换、入场、按压都更接近人工打磨的质感：
///   * 所有动画都是**一次性有限动画**，不会常驻逐帧刷新（省电、省 GPU）；
///   * 统一尊重系统「减少动态效果」无障碍开关，关闭时不播放动画；
///   * [DshFadeSlideIn] 的错落延时用 [Interval] 曲线实现，不需要额外 Timer，
///     在 widget test 的 pumpAndSettle 里能稳定收敛。
class DshMotion {
  const DshMotion._();

  /// 按压反馈：轻、快，不拖泥带水。
  static const Duration instant = Duration(milliseconds: 110);

  /// 状态切换（选中、聚焦、显隐）。
  static const Duration fast = Duration(milliseconds: 180);

  /// 常规位移 / 淡入。
  static const Duration normal = Duration(milliseconds: 260);

  /// 页面级入场。
  static const Duration entrance = Duration(milliseconds: 420);

  /// 默认曲线：起步略快、收尾轻缓，接近真实物体的减速。
  static const Curve standard = Curves.easeOutCubic;

  /// 对称曲线，用于循环 / 往复的显隐。
  static const Curve gentle = Curves.easeInOutCubic;

  /// 按下时的缩放比例：幅度很小，只提供「有回应」的手感。
  static const double pressScale = 0.965;

  /// 系统是否要求减少动态效果。关闭动画不只是无障碍合规，
  /// 也能让低性能设备与自动化测试保持确定性。
  static bool reduced(BuildContext context) =>
      MediaQuery.of(context).disableAnimations;
}

/// 一次性「淡入 + 轻微上浮 + 微缩放」入场动画。
///
/// [delay] 用于列表 / 分组的错落入场，通过 [Interval] 在没有真实 Timer
/// 的前提下实现，因此不会在测试里留下待处理的定时任务。
/// [child] 作为缓存子树传入，动画期间不会重建业务内容。
class DshFadeSlideIn extends StatelessWidget {
  const DshFadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = DshMotion.entrance,
    this.offsetY = 12,
    this.beginScale = 0.985,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final double offsetY;
  final double beginScale;

  @override
  Widget build(BuildContext context) {
    if (DshMotion.reduced(context)) return child;
    final Duration total = duration + delay;
    final double start = total.inMicroseconds == 0
        ? 0.0
        : delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: total,
      curve: Interval(start, 1.0, curve: DshMotion.standard),
      child: child,
      builder: (BuildContext context, double t, Widget? cached) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, offsetY * (1 - t)),
            child: Transform.scale(
              scale: 1 - (1 - beginScale) * (1 - t),
              child: cached,
            ),
          ),
        );
      },
    );
  }
}

/// 统一的「可按压」容器：水波纹 + 高亮 + 轻微缩放 + 可选触感。
///
/// 用 [InkWell.onHighlightChanged] 驱动缩放，而不是在外层再套一个
/// GestureDetector —— 后者会与 InkWell 争夺点击竞技场，导致部分回调丢失。
/// 组件自带透明 [Material]，因此在任意 Scaffold / 页面下都能画出水波纹。
class DshPressable extends StatefulWidget {
  const DshPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius,
    this.splashColor,
    this.highlightColor,
    this.haptic = false,
    this.enabled = true,
    this.scale = DshMotion.pressScale,
    this.tooltip,
    this.semanticsLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius? borderRadius;
  final Color? splashColor;
  final Color? highlightColor;
  final bool haptic;
  final bool enabled;
  final double scale;
  final String? tooltip;
  final String? semanticsLabel;

  @override
  State<DshPressable> createState() => _DshPressableState();
}

class _DshPressableState extends State<DshPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool reduced = DshMotion.reduced(context);
    final bool allowScale = !reduced && widget.enabled;
    final Color pressTint =
        widget.highlightColor ??
        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.07);

    Widget content = InkWell(
      onTap: widget.enabled
          ? () {
              if (widget.haptic) HapticFeedback.selectionClick();
              widget.onTap?.call();
            }
          : null,
      onLongPress: widget.enabled ? widget.onLongPress : null,
      onHighlightChanged: allowScale
          ? (bool value) {
              if (_pressed != value) setState(() => _pressed = value);
            }
          : null,
      borderRadius: widget.borderRadius,
      splashColor: widget.splashColor,
      highlightColor: widget.highlightColor,
      // 卡片 / 按钮的 child 通常自带不透明背景，会盖住 InkWell 画在
      // Material 上的水波纹。这里用 foregroundDecoration 把按压高亮画在
      // child 之上，保证任何表面都能看到「点到了」的即时反馈。
      child: AnimatedContainer(
        duration: reduced ? Duration.zero : DshMotion.instant,
        curve: DshMotion.standard,
        foregroundDecoration: BoxDecoration(
          color: _pressed && allowScale ? pressTint : Colors.transparent,
          borderRadius: widget.borderRadius,
        ),
        child: AnimatedScale(
          scale: _pressed && allowScale ? widget.scale : 1.0,
          duration: reduced ? Duration.zero : DshMotion.instant,
          curve: DshMotion.standard,
          child: widget.child,
        ),
      ),
    );

    if (widget.tooltip != null) {
      content = Tooltip(message: widget.tooltip!, child: content);
    }
    if (widget.semanticsLabel != null) {
      content = Semantics(
        button: true,
        enabled: widget.enabled,
        label: widget.semanticsLabel,
        child: content,
      );
    }
    return Material(color: Colors.transparent, child: content);
  }
}
