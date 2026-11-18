import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import 'dsh_motion.dart';

/// TGA 设计系统双主题色板（2026-11-13 深/浅两套满分配色）。
///
/// [TgaTokens.light] / [TgaTokens.dark] 是两个不可变实例；
/// [Tga] 的静态 getter 始终读取 [Tga.syncFrom] 同步后的当前激活实例。
class TgaTokens {
  const TgaTokens({
    required this.bg,
    required this.bgSoft,
    required this.card,
    required this.cardAlt,
    required this.primary,
    required this.primaryDeep,
    required this.groupTitle,
    required this.onPrimary,
    required this.text,
    required this.textSub,
    required this.textDim,
    required this.divider,
    required this.border,
    required this.iconBlueBg,
    required this.iconBlue,
    required this.iconPurpleBg,
    required this.iconPurple,
    required this.iconCyanBg,
    required this.iconCyan,
    required this.iconGoldBg,
    required this.iconGold,
    required this.iconPinkBg,
    required this.iconPink,
    required this.iconGreenBg,
    required this.iconGreen,
    required this.iconRedBg,
    required this.iconRed,
    required this.green,
    required this.orange,
    required this.red,
    required this.cyan,
    required this.purple,
    required this.gold,
    required this.pink,
    required this.sphereNodes,
    required this.shadowBase,
    required this.shadowAlpha,
  });

  // ---- 浅色：冷白底 + 纯白卡 + 蓝紫主色 #4D6BFE（豆包式清爽） ----
  static const TgaTokens light = TgaTokens(
    bg: Color(0xFFF6F7FB),
    bgSoft: Color(0xFFF3F5FA),
    card: Color(0xFFFFFFFF),
    cardAlt: Color(0xFFFBFCFE),
    primary: Color(0xFF4D6BFE),
    primaryDeep: Color(0xFF3D5AFE),
    groupTitle: Color(0xFF17181C),
    onPrimary: Color(0xFFFFFFFF),
    text: Color(0xFF17181C),
    textSub: Color(0xFF5F6673),
    textDim: Color(0xFFA0A5B2),
    divider: Color(0xFFEDEFF5),
    border: Color(0xFFE5E8F0),
    iconBlueBg: Color(0xFFE9EDFF),
    iconBlue: Color(0xFF4D6BFE),
    iconPurpleBg: Color(0xFFF0EBFF),
    iconPurple: Color(0xFF7C5CFF),
    iconCyanBg: Color(0xFFE6F7F8),
    iconCyan: Color(0xFF14B8C4),
    iconGoldBg: Color(0xFFFFF3DE),
    iconGold: Color(0xFFF0A020),
    iconPinkBg: Color(0xFFFFEAF3),
    iconPink: Color(0xFFF0559A),
    iconGreenBg: Color(0xFFE6F8EF),
    iconGreen: Color(0xFF12B76A),
    iconRedBg: Color(0xFFFFECEC),
    iconRed: Color(0xFFF04438),
    green: Color(0xFF12B76A),
    orange: Color(0xFFF0A020),
    red: Color(0xFFF04438),
    cyan: Color(0xFF14B8C4),
    purple: Color(0xFF7C5CFF),
    gold: Color(0xFFF0A020),
    pink: Color(0xFFF0559A),
    sphereNodes: <Color>[
      Color(0xFF4D6BFE), // 蓝
      Color(0xFF7C5CFF), // 紫
      Color(0xFF14B8C4), // 青
      Color(0xFFF0559A), // 粉
      Color(0xFFF0A020), // 金
    ],
    shadowBase: Color(0xFF1B2559),
    shadowAlpha: 0.06,
  );

  // ---- 深色：近黑底 + 深蓝灰卡 + 柔光蓝紫主色 ----
  static const TgaTokens dark = TgaTokens(
    bg: Color(0xFF0E1014),
    bgSoft: Color(0xFF12151B),
    card: Color(0xFF171A21),
    cardAlt: Color(0xFF1C2029),
    primary: Color(0xFF8C9BFF),
    primaryDeep: Color(0xFFA5B0FF),
    groupTitle: Color(0xFFEDEFF5),
    onPrimary: Color(0xFF0E1014),
    text: Color(0xFFEDEFF5),
    textSub: Color(0xFFA0A7B5),
    textDim: Color(0xFF6B7280),
    divider: Color(0xFF232833),
    border: Color(0xFF2A3040),
    iconBlueBg: Color(0xFF252D4D),
    iconBlue: Color(0xFF8C9BFF),
    iconPurpleBg: Color(0xFF2C2545),
    iconPurple: Color(0xFFB4A0FF),
    iconCyanBg: Color(0xFF16363A),
    iconCyan: Color(0xFF5EE0E8),
    iconGoldBg: Color(0xFF3A2E18),
    iconGold: Color(0xFFF7C15C),
    iconPinkBg: Color(0xFF3A2232),
    iconPink: Color(0xFFF58AB8),
    iconGreenBg: Color(0xFF14352A),
    iconGreen: Color(0xFF34D399),
    iconRedBg: Color(0xFF3B1518),
    iconRed: Color(0xFFF87171),
    green: Color(0xFF10B981),
    orange: Color(0xFFF59E0B),
    red: Color(0xFFEF4444),
    cyan: Color(0xFF5EE0E8),
    purple: Color(0xFFB4A0FF),
    gold: Color(0xFFF7C15C),
    pink: Color(0xFFF58AB8),
    sphereNodes: <Color>[
      Color(0xFF8C9BFF), // 蓝
      Color(0xFFB4A0FF), // 紫
      Color(0xFF5EE0E8), // 青
      Color(0xFFF58AB8), // 粉
      Color(0xFFF7C15C), // 金
    ],
    shadowBase: Color(0xFF000000),
    shadowAlpha: 0.45,
  );

  // ---- 背景与卡片 ----
  final Color bg;
  final Color bgSoft;
  final Color card;
  final Color cardAlt;

  // ---- 品牌与文字 ----
  final Color primary;
  final Color primaryDeep;
  final Color groupTitle;

  /// filled 主按钮 / 选中胶囊上的前景色（深底主题下转深色保证对比）。
  final Color onPrimary;
  final Color text;
  final Color textSub;
  final Color textDim;
  final Color divider;

  /// 输入框 / 胶囊描边（浅色海盐蓝 #B9DDD7 系）。
  final Color border;

  // ---- 圆形图标底 ----
  final Color iconBlueBg;
  final Color iconBlue;
  final Color iconPurpleBg;
  final Color iconPurple;
  final Color iconCyanBg;
  final Color iconCyan;
  final Color iconGoldBg;
  final Color iconGold;
  final Color iconPinkBg;
  final Color iconPink;
  final Color iconGreenBg;
  final Color iconGreen;
  final Color iconRedBg;
  final Color iconRed;

  // ---- 语义色 ----
  final Color green;
  final Color orange;
  final Color red;
  final Color cyan;
  final Color purple;
  final Color gold;
  final Color pink;

  // ---- 知识图谱七彩节点 ----
  final List<Color> sphereNodes;

  // ---- 卡片投影 ----
  final Color shadowBase;
  final double shadowAlpha;
}

/// TGA 新设计稿统一视觉系统（2026-11-12 老板提供的 13 张设计稿）。
///
/// 浅蓝灰底 + 白色圆角卡片 + 蓝色分组标题，圆形浅蓝 / 浅紫图标底 +
/// 线性图标，胶囊分段，统计双卡。深/浅两套色板由 [TgaTokens] 承载，
/// [TgaPage.build] 每帧经 [Tga.syncFrom] 跟随 [ThemeData.brightness]。
/// 纯 Flutter 实现，不引入第三方包，所有页面共用。
class Tga {
  // ---- 当前激活色板（TgaPage 构建时按主题亮度同步）----
  static TgaTokens _active = TgaTokens.light;

  /// 按最近一次 [syncFrom] 的上下文主题读取激活色板（供自定义绘制等场景）。
  static TgaTokens get tokens => _active;

  /// 依据 [context] 的主题亮度切换全局激活色板。
  static void syncFrom(BuildContext context) {
    _active = Theme.of(context).brightness == Brightness.dark
        ? TgaTokens.dark
        : TgaTokens.light;
  }

  // ---- 背景与卡片 ----
  static Color get bg => _active.bg;
  static Color get bgSoft => _active.bgSoft;
  static Color get card => _active.card;
  static Color get cardAlt => _active.cardAlt;

  // ---- 品牌与文字 ----
  static Color get primary => _active.primary;
  static Color get primaryDeep => _active.primaryDeep;
  static Color get groupTitle => _active.groupTitle;
  static Color get onPrimary => _active.onPrimary;
  static Color get text => _active.text;
  static Color get textSub => _active.textSub;
  static Color get textDim => _active.textDim;
  static Color get divider => _active.divider;
  static Color get border => _active.border;

  // ---- 圆形图标底 ----
  static Color get iconBlueBg => _active.iconBlueBg;
  static Color get iconBlue => _active.iconBlue;
  static Color get iconPurpleBg => _active.iconPurpleBg;
  static Color get iconPurple => _active.iconPurple;
  static Color get iconCyanBg => _active.iconCyanBg;
  static Color get iconCyan => _active.iconCyan;
  static Color get iconGoldBg => _active.iconGoldBg;
  static Color get iconGold => _active.iconGold;
  static Color get iconPinkBg => _active.iconPinkBg;
  static Color get iconPink => _active.iconPink;
  static Color get iconGreenBg => _active.iconGreenBg;
  static Color get iconGreen => _active.iconGreen;
  static Color get iconRedBg => _active.iconRedBg;
  static Color get iconRed => _active.iconRed;

  // ---- 语义色 ----
  static Color get green => _active.green;
  static Color get orange => _active.orange;
  static Color get red => _active.red;
  static Color get cyan => _active.cyan;
  static Color get purple => _active.purple;
  static Color get gold => _active.gold;
  static Color get pink => _active.pink;

  // ---- 知识图谱七彩节点 ----
  static List<Color> get sphereNodes => _active.sphereNodes;

  // ---- 尺寸（豆包式大圆角、宽松留白）----
  static const double rCard = 20;
  static const double rChip = 999;
  static const double pagePad = 18;

  static TextStyle get h1 => TextStyle(
      fontSize: 24, fontWeight: FontWeight.w700, color: text, height: 1.25);
  static TextStyle get h2 => TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: text,
    height: 1.4,
  );
  static TextStyle get body => TextStyle(
      fontSize: 14, fontWeight: FontWeight.w500, color: text, height: 1.45);
  static TextStyle get sub => TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    color: textSub,
    height: 1.45,
  );
  static TextStyle get caption => TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: textDim,
    height: 1.4,
  );

  static BoxShadow get softShadow => BoxShadow(
        color: _active.shadowBase.withValues(alpha: _active.shadowAlpha),
        blurRadius: 24,
        offset: const Offset(0, 6),
      );

  /// 卡片专用双层投影：大范围环境光 + 贴边接触阴影，比单层投影更接近
  /// 真实材质的抬升感；深色主题下自动压低强度，避免糊成黑块。
  static List<BoxShadow> get cardShadow => <BoxShadow>[
    BoxShadow(
      color: _active.shadowBase.withValues(alpha: _active.shadowAlpha * 0.85),
      blurRadius: 20,
      offset: const Offset(0, 6),
    ),
    BoxShadow(
      color: _active.shadowBase.withValues(alpha: _active.shadowAlpha * 0.38),
      blurRadius: 6,
      offset: const Offset(0, 1),
    ),
  ];
}

/// 页面骨架：主题底色 + 可选标题栏。构建时同步全局激活色板。
class TgaPage extends StatelessWidget {
  const TgaPage({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.bottom,
  });

  final String title;
  final Widget child;
  final List<Widget>? actions;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Scaffold(
      backgroundColor: Tga.bg,
      appBar: AppBar(
        backgroundColor: Tga.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        title: Text(title, style: Tga.h1),
        actions: actions,
        // 顶栏与内容之间加一条发丝线：滚动时标题区不再和内容糊在一起。
        flexibleSpace: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Tga.divider.withValues(alpha: 0.55),
                width: 0.6,
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: bottom,
      // 页面首次进入时轻微上浮淡入，避免硬切；动画一次性结束，
      // 且尊重系统「减少动态效果」设置。
      body: SafeArea(
        child: DshFadeSlideIn(
          duration: DshMotion.normal,
          offsetY: 8,
          child: child,
        ),
      ),
    );
  }
}

/// 蓝色分组标题。
class TgaGroupTitle extends StatelessWidget {
  const TgaGroupTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: Tga.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: Tga.groupTitle,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 白色圆角卡片容器。
class TgaCard extends StatelessWidget {
  const TgaCard({super.key, required this.child, this.padding, this.onTap});

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final BorderRadius radius = BorderRadius.circular(Tga.rCard);
    final Widget inner = Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Tga.card,
        borderRadius: radius,
        // 发丝描边 + 双层投影：卡片边界更清晰，深浅主题下都立得住。
        border: Border.all(
          color: Tga.divider.withValues(alpha: 0.6),
          width: 0.6,
        ),
        boxShadow: Tga.cardShadow,
      ),
      child: child,
    );
    if (onTap == null) return inner;
    return DshPressable(
      onTap: onTap,
      borderRadius: radius,
      haptic: true,
      splashColor: Tga.primary.withValues(alpha: 0.08),
      child: inner,
    );
  }
}

/// 圆形浅色图标底 + 线性图标 + 标题 + 副标题 + 尾部。
class TgaIconTile extends StatelessWidget {
  const TgaIconTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconBg,
    this.iconColor,
    this.trailing,
    this.onTap,
    this.showArrow = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? iconBg;
  final Color? iconColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showArrow;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final Color bg = iconBg ?? Tga.iconBlueBg;
    final Color fg = iconColor ?? Tga.iconBlue;
    return DshPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      haptic: true,
      splashColor: fg.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: <Widget>[
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                border: Border.all(
                  color: fg.withValues(alpha: 0.14),
                  width: 0.6,
                ),
              ),
              child: Icon(icon, size: 19, color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(title, style: Tga.body),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(subtitle!, style: Tga.sub),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (showArrow)
              Icon(Icons.chevron_right_rounded, size: 18, color: Tga.textDim),
          ],
        ),
      ),
    );
  }
}

/// 卡片内分隔线。
class TgaTileDivider extends StatelessWidget {
  const TgaTileDivider({super.key});
  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Divider(height: 1, thickness: 1, color: Tga.divider, indent: 64);
  }
}

/// 通用胶囊分段控件（如：跟随系统 / 浅色 / 深色）。
class TgaSegmented<T> extends StatelessWidget {
  const TgaSegmented({
    super.key,
    required this.items,
    required this.value,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> items;
  final T value;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final T item in items) ...<Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _SegPill<T>(
                label: labelOf(item),
                selected: item == value,
                onTap: () => onChanged(item),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SegPill<T> extends StatelessWidget {
  const _SegPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return DshPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tga.rChip),
      haptic: true,
      splashColor: Tga.primary.withValues(alpha: 0.12),
      child: AnimatedContainer(
        duration: DshMotion.fast,
        curve: DshMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Tga.primary : Tga.card,
          borderRadius: BorderRadius.circular(Tga.rChip),
          border: Border.all(
            color: selected ? Tga.primary : Tga.border,
            width: 0.8,
          ),
          boxShadow: selected ? Tga.cardShadow : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Tga.onPrimary : Tga.textSub,
          ),
        ),
      ),
    );
  }
}

/// 小标签（状态 / 类型 / 计数）。
class TgaTag extends StatelessWidget {
  const TgaTag(this.label, {super.key, this.color, this.filled = false});

  final String label;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final Color c = color ?? Tga.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3.5),
      decoration: BoxDecoration(
        color: filled ? c : c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(7),
        border: filled
            ? null
            : Border.all(color: c.withValues(alpha: 0.16), width: 0.6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: filled ? Tga.onPrimary : c,
        ),
      ),
    );
  }
}

/// 统计数字卡（模型管理顶部双卡、更多通信计数等）。
class TgaStatCard extends StatelessWidget {
  const TgaStatCard({
    super.key,
    required this.value,
    required this.label,
    required this.color,
    this.icon,
  });

  final String value;
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Expanded(
      child: TgaCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      color.withValues(alpha: 0.16),
                      color.withValues(alpha: 0.07),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(
                    color: color.withValues(alpha: 0.14),
                    width: 0.6,
                  ),
                ),
                child: Icon(icon, size: 19, color: color),
              ),
              const SizedBox(width: 12),
            ],
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: color,
                    height: 1.1,
                    // 数字等宽：数值刷新时不会左右跳动。
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(label, style: Tga.caption),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 空态。
class TgaEmpty extends StatelessWidget {
  const TgaEmpty(this.text, {super.key, this.icon = Icons.inbox_outlined});
  final String text;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 34, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 柔和的圆形底座让空态不再是「孤零零一个灰图标」。
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: Tga.cardAlt,
                shape: BoxShape.circle,
                border: Border.all(
                  color: Tga.divider.withValues(alpha: 0.7),
                  width: 0.6,
                ),
                boxShadow: Tga.cardShadow,
              ),
              child: Icon(icon, size: 28, color: Tga.textDim),
            ),
            const SizedBox(height: 14),
            Text(text, style: Tga.sub, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// 线性小按钮（对话 / 启动 / 删除 / 去授权 / 下载）。
class TgaButton extends StatelessWidget {
  const TgaButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color,
    this.filled = true,
    this.compact = true,
    this.icon,
  });

  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool filled;
  final bool compact;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final Color c = color ?? Tga.primary;
    final Color fg = filled ? Tga.onPrimary : c;
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (icon != null) ...<Widget>[
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: fg,
          ),
        ),
      ],
    );
    return DshPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Tga.rChip),
      haptic: true,
      splashColor: fg.withValues(alpha: 0.18),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 18,
          vertical: compact ? 8 : 11,
        ),
        decoration: BoxDecoration(
          color: filled ? c : c.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(Tga.rChip),
          border: filled ? null : Border.all(color: c.withValues(alpha: 0.32)),
          boxShadow: filled
              ? <BoxShadow>[
                  BoxShadow(
                    color: c.withValues(alpha: 0.20),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: content,
      ),
    );
  }
}

/// 搜索框（可粘贴名字、链接）。
///
/// 交互补全：聚焦时描边点亮、输入后提供一键清除、清除后保持焦点继续输入。
/// 外部传入的 [controller] 只订阅不销毁，内部创建的才在 dispose 时释放。
class TgaSearchField extends StatefulWidget {
  const TgaSearchField({
    super.key,
    required this.hint,
    this.onChanged,
    this.controller,
  });
  final String hint;
  final ValueChanged<String>? onChanged;
  final TextEditingController? controller;

  @override
  State<TgaSearchField> createState() => _TgaSearchFieldState();
}

class _TgaSearchFieldState extends State<TgaSearchField> {
  final FocusNode _focusNode = FocusNode();
  TextEditingController? _ownController;
  bool _focused = false;
  bool _hasText = false;

  TextEditingController get _controller =>
      widget.controller ?? (_ownController ??= TextEditingController());

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
    _controller.addListener(_onTextChange);
    _hasText = _controller.text.isNotEmpty;
  }

  void _onFocusChange() {
    final bool value = _focusNode.hasFocus;
    if (_focused != value) setState(() => _focused = value);
  }

  void _onTextChange() {
    final bool value = _controller.text.isNotEmpty;
    if (_hasText != value) setState(() => _hasText = value);
  }

  @override
  void didUpdateWidget(TgaSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onTextChange);
      _controller.addListener(_onTextChange);
      _hasText = _controller.text.isNotEmpty;
    }
  }

  void _clear() {
    _controller.clear();
    widget.onChanged?.call('');
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.removeListener(_onTextChange);
    _ownController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final bool reduced = DshMotion.reduced(context);
    return AnimatedContainer(
      duration: reduced ? Duration.zero : DshMotion.fast,
      curve: DshMotion.standard,
      height: 44,
      decoration: BoxDecoration(
        color: Tga.bgSoft,
        borderRadius: BorderRadius.circular(Tga.rChip),
        border: Border.all(
          color: _focused
              ? Tga.primary.withValues(alpha: 0.65)
              : Tga.border.withValues(alpha: 0.5),
          width: _focused ? 1.2 : 0.8,
        ),
        boxShadow: Tga.cardShadow,
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 12),
          Icon(
            Icons.search_rounded,
            size: 18,
            color: _focused ? Tga.primary : Tga.textDim,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              onChanged: widget.onChanged,
              style: TextStyle(fontSize: 13.5, color: Tga.text),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: TextStyle(fontSize: 13, color: Tga.textDim),
                border: InputBorder.none,
                isCollapsed: true,
              ),
            ),
          ),
          if (_hasText)
            DshPressable(
              onTap: _clear,
              borderRadius: BorderRadius.circular(999),
              semanticsLabel: '清除输入',
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.close_rounded, size: 15, color: Tga.textDim),
              ),
            )
          else
            const SizedBox(width: 6),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

/// 数学工具：斐波那契球面采样（知识图谱 3D 球体用）。
List<Offset> fibonacciSphere(int count, double radius) {
  final List<Offset> pts = <Offset>[];
  final double golden = math.pi * (3 - math.sqrt(5));
  for (int i = 0; i < count; i++) {
    final double y = 1 - (i / (count - 1)) * 2;
    final double r = math.sqrt(math.max(0, 1 - y * y));
    final double theta = golden * i;
    pts.add(Offset(math.cos(theta) * r, y)); // x,z 平面 + 高度
  }
  return pts;
}
