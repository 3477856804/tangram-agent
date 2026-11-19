import 'package:flutter/material.dart';

/// TGA (tangram-agent) —— 设计令牌层。
///
/// 视觉规范对齐 DeepSeek Harness（dsh）的设计系统：
/// 品牌主色是**单色**（浅色近黑、深色近白），蓝色（#4176E6）只作为强调色
/// 用于链接、焦点环、发送键与选中态；层级靠 0.5dp 的发丝线而不是阴影。
///
/// 组件只读这里的令牌，不在业务代码里写死颜色。
class DshPalette {
  const DshPalette({
    required this.isDark,
    required this.labelPrimary,
    required this.labelSecondary,
    required this.labelTertiary,
    required this.labelCaption,
    required this.labelDimmed,
    required this.labelOnPrimary,
    required this.bgBase,
    required this.bgLayer1,
    required this.bgLayer2,
    required this.bgLayer3,
    required this.bgModule,
    required this.sidebar,
    required this.sidebarActive,
    required this.bubble,
    required this.inputMajor,
    required this.selector,
    required this.codeBlock,
    required this.menuFill,
    required this.borderL1,
    required this.borderL2,
    required this.borderL3,
    required this.borderL4,
    required this.brandPrimary,
    required this.brandDimmed,
    required this.business,
    required this.businessTertiary,
    required this.link,
    required this.hover,
    required this.pressed,
    required this.hoverSolid,
    required this.hoverDanger,
    required this.success,
    required this.successTertiary,
    required this.warn,
    required this.warnLabel,
    required this.warnTertiary,
    required this.error,
    required this.idle,
    required this.scrim,
    required this.kindSystem,
    required this.kindTools,
    required this.kindMessages,
  });

  final bool isDark;

  // 文本
  final Color labelPrimary;
  final Color labelSecondary;
  final Color labelTertiary;
  final Color labelCaption;
  final Color labelDimmed;
  final Color labelOnPrimary;

  // 表面
  final Color bgBase;
  final Color bgLayer1;
  final Color bgLayer2;
  final Color bgLayer3;
  final Color bgModule;
  final Color sidebar;
  final Color sidebarActive;
  final Color bubble;
  final Color inputMajor;
  final Color selector;
  final Color codeBlock;
  final Color menuFill;

  // 描边
  final Color borderL1;
  final Color borderL2;
  final Color borderL3;
  final Color borderL4;

  // 品牌 / 交互
  final Color brandPrimary;
  final Color brandDimmed;
  final Color business;
  final Color businessTertiary;
  final Color link;
  final Color hover;
  final Color pressed;
  final Color hoverSolid;
  final Color hoverDanger;

  // 状态
  final Color success;
  final Color successTertiary;
  final Color warn;
  final Color warnLabel;
  final Color warnTertiary;
  final Color error;
  final Color idle;
  final Color scrim;

  // 轨迹（上下文 / 工具 / 对话）
  final Color kindSystem;
  final Color kindTools;
  final Color kindMessages;

  /// 对话正文专用前景色：深色模式纯白、浅色模式纯黑。
  /// 输入框与输出区直接使用该令牌，避免半透明/灰阶在特定背景上发灰。
  Color get chatText =>
      isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);

  // ---- 满分配色方案（2026-11-13，见 .trae/skills/unslop/SKILL.md 附表）----
  // 浅色：bg-base 云雾白 #F7F9F7（67%）/ bg-surface 纯白 #FFFFFF（25%，极浅阴影）
  //       / brand-primary 深星蓝 #4A90D9（8%，只上主按钮与选中态）
  //       / text #111111 · #64748B / border 海盐蓝 #B9DDD7
  // 深色：bg-base 极夜黑 #141618 / bg-surface 深海盐蓝 #212B36
  //       / brand-primary 柔光星蓝 #7BB5E3 / text #E2E8F0 · #94A3B8
  //       / border 岩层灰 #38444D
  // 语义：成功 #059669/#10B981 · 错误 #DC2626/#EF4444
  //       警告 #D97706/#F59E0B · 信息 #2563EB/#3B82F6

  static const DshPalette light = DshPalette(
    isDark: false,
    labelPrimary: Color(0xFF000000),
    labelSecondary: Color(0xFF000000),
    labelTertiary: Color(0xFF000000),
    labelCaption: Color(0xFF000000),
    labelDimmed: Color(0xFF000000),
    labelOnPrimary: Color(0xFFFFFFFF),
    // 冷白底 + 纯白卡 + 蓝紫强调，整体更接近豆包的清爽层叠。
    bgBase: Color(0xFFF6F7FB),
    bgLayer1: Color(0xFFFFFFFF),
    bgLayer2: Color(0xFFFFFFFF),
    bgLayer3: Color(0xFFF1F3F9),
    bgModule: Color(0xFFF8F9FC),
    sidebar: Color(0xFFF3F5FA),
    sidebarActive: Color(0xFFE8ECFF),
    bubble: Color(0xFFEAEEFF),
    inputMajor: Color(0xFFFFFFFF),
    selector: Color(0xFFF3F5FA),
    codeBlock: Color(0xFFF6F7FA),
    menuFill: Color(0xFFFFFFFF),
    // 中性冷灰发丝线阶梯。
    borderL1: Color(0xFFEFF1F6),
    borderL2: Color(0xFFE7EAF2),
    borderL3: Color(0xFFDDE1EB),
    borderL4: Color(0xFFC9CFDE),
    brandPrimary: Color(0xFF4D6BFE),
    brandDimmed: Color(0xFFE8ECFF),
    business: Color(0xFF4D6BFE),
    businessTertiary: Color(0xFFE8ECFF),
    link: Color(0xFF3D5AFE),
    hover: Color(0x0A17181C),
    pressed: Color(0x1417181C),
    hoverSolid: Color(0xFFF1F3F9),
    hoverDanger: Color(0x14DC2626),
    success: Color(0xFF059669),
    successTertiary: Color(0xFFE7F5EF),
    warn: Color(0xFFD97706),
    warnLabel: Color(0xFFD97706),
    warnTertiary: Color(0xFFFBF0E1),
    error: Color(0xFFDC2626),
    idle: Color(0xFFCBD2D9),
    scrim: Color(0x61000000),
    kindSystem: Color(0xFF8A90A0),
    kindTools: Color(0xFF7C5CFF),
    kindMessages: Color(0xFF4D6BFE),
  );

  static const DshPalette dark = DshPalette(
    isDark: true,
    labelPrimary: Color(0xFFFFFFFF),
    labelSecondary: Color(0xFFFFFFFF),
    labelTertiary: Color(0xFFFFFFFF),
    labelCaption: Color(0xFFFFFFFF),
    labelDimmed: Color(0xFFFFFFFF),
    labelOnPrimary: Color(0xFFFFFFFF),
    // 近黑打底，深蓝灰承载卡片 / 弹窗。
    bgBase: Color(0xFF0E1014),
    bgLayer1: Color(0xFF171A21),
    bgLayer2: Color(0xFF1C2029),
    bgLayer3: Color(0xFF232833),
    bgModule: Color(0xFF12151B),
    sidebar: Color(0xFF111318),
    sidebarActive: Color(0xFF242C4A),
    bubble: Color(0xFF232B4A),
    inputMajor: Color(0xFF171A21),
    selector: Color(0xFF222733),
    codeBlock: Color(0xFF12151B),
    menuFill: Color(0xFF1C2029),
    // 深色中性描边阶梯。
    borderL1: Color(0xFF232833),
    borderL2: Color(0xFF2A3040),
    borderL3: Color(0xFF333A4A),
    borderL4: Color(0xFF414A5E),
    brandPrimary: Color(0xFF4D6BFE),
    brandDimmed: Color(0xFF262E4D),
    business: Color(0xFF4D6BFE),
    businessTertiary: Color(0xFF252D4D),
    link: Color(0xFF9AA8FF),
    hover: Color(0x14FFFFFF),
    pressed: Color(0x24FFFFFF),
    hoverSolid: Color(0xFF222733),
    hoverDanger: Color(0x26EF4444),
    success: Color(0xFF10B981),
    successTertiary: Color(0xFF14352A),
    warn: Color(0xFFF59E0B),
    warnLabel: Color(0xFFF59E0B),
    warnTertiary: Color(0xFF352A14),
    error: Color(0xFFEF4444),
    idle: Color(0xFF414A5E),
    scrim: Color(0x99000000),
    kindSystem: Color(0xFFA0A7B5),
    kindTools: Color(0xFFB4A0FF),
    kindMessages: Color(0xFF8C9BFF),
  );

  /// 跟随 Theme 的亮暗：默认走浅色（dsh 的默认外观）。
  static DshPalette of(BuildContext context) {
    final Brightness b = Theme.of(context).brightness;
    return b == Brightness.dark ? dark : light;
  }
}

/// dsh 的字号阶梯（--dsw-font-*），height 用行高/字号换算。
class DshType {
  const DshType._();

  static const TextStyle xl24 = TextStyle(
    fontSize: 24,
    height: 32 / 24,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle l20 = TextStyle(
    fontSize: 20,
    height: 28 / 20,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle base16 = TextStyle(fontSize: 16, height: 24 / 16);
  static const TextStyle base16m = TextStyle(
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle s14 = TextStyle(fontSize: 14, height: 22 / 14);
  static const TextStyle s14m = TextStyle(
    fontSize: 14,
    height: 22 / 14,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle xs13 = TextStyle(fontSize: 13, height: 20 / 13);
  static const TextStyle xs13m = TextStyle(
    fontSize: 13,
    height: 20 / 13,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle xxs12 = TextStyle(fontSize: 12, height: 18 / 12);
  static const TextStyle xxs12m = TextStyle(
    fontSize: 12,
    height: 18 / 12,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle xxxs11 = TextStyle(fontSize: 11, height: 14 / 11);
  static const TextStyle xxxs11m = TextStyle(
    fontSize: 11,
    height: 14 / 11,
    fontWeight: FontWeight.w500,
  );

  /// 正文（markdown 14/24）
  static const TextStyle body = TextStyle(fontSize: 14, height: 24 / 14);

  /// 过程行（DisclosureRow 13/24）
  static const TextStyle row13 = TextStyle(fontSize: 13, height: 24 / 13);

  /// 等宽
  static const TextStyle mono11 = TextStyle(
    fontSize: 11,
    height: 16 / 11,
    fontFamily: 'monospace',
  );
  static const TextStyle mono12 = TextStyle(
    fontSize: 12,
    height: 19 / 12,
    fontFamily: 'monospace',
  );
}

/// dsh 的圆角阶梯。
class DshR {
  const DshR._();

  static const double xs = 4;
  static const double sm = 8;
  static const double tile = 10;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double panel = 28;

  static const BorderRadius brXs = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius brPanel = BorderRadius.all(Radius.circular(panel));
  static const BorderRadius brFull = BorderRadius.all(Radius.circular(999));
}

/// 间距走 2/4dp 网格。
class DshSpace {
  const DshSpace._();

  static const double x2 = 2;
  static const double x4 = 4;
  static const double x6 = 6;
  static const double x8 = 8;
  static const double x10 = 10;
  static const double x12 = 12;
  static const double x14 = 14;
  static const double x16 = 16;
  static const double x20 = 20;
  static const double x24 = 24;
  static const double x32 = 32;
}

/// dsh 的发丝线：0.5dp。
const double dshHairline = 0.5;

/// 输入栏（composer）统一几何规格。
///
/// 首屏与对话视图共用同一 `FlaiComposerV2` 组件，这里集中所有尺寸 / 圆角 /
/// 描边 / 阴影 / 偏移，杜绝两处布局数值漂移（审核项 #6）。组件只读本规格，
/// 不在业务代码里写死数字。
class DshComposerSpec {
  const DshComposerSpec._();

  /// 容器圆角（设计稿 2026-11-13：更柔和的大圆角卡片）。
  static const double radius = 24;

  /// 描边宽度（= dshHairline）。
  static const double borderWidth = dshHairline;

  /// 整体下移，制造悬浮底栏的轻微抬升感。
  static const double translateY = 8;

  /// 编辑器最小高度。
  static const double editorMinHeight = 40;

  /// 极淡投影参数（蓝灰底上白卡需要更明显的抬升）。
  static const double shadowBlur = 18;
  static const double shadowLift = 4;
  static const double shadowAlpha = 0.06;
}

/// 平铺表面：底色 + 0.5dp 描边，无阴影。
BoxDecoration dshFlat(
  DshPalette c, {
  double radius = DshR.xl,
  Color? fill,
  Color? stroke,
}) {
  return BoxDecoration(
    color: fill ?? c.bgLayer2,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(color: stroke ?? c.borderL4, width: dshHairline),
  );
}

/// 抬升表面：极淡投影（菜单 / 对话框 / 输入区 / 悬浮键）。
///
/// 保持原有签名与默认参数不变（历史调用点全部兼容）；新增可选 [tint]，
/// 让浅色模式可以用带蓝灰倾向的阴影而不是死黑，层次更自然。
List<BoxShadow> dshSoftShadow({
  double blur = 8,
  double lift = 3,
  double alpha = 0.03,
  Color? tint,
}) {
  return <BoxShadow>[
    BoxShadow(
      color: (tint ?? const Color(0xFF2C3E6B)).withValues(alpha: alpha),
      blurRadius: blur,
      offset: Offset(0, lift),
    ),
  ];
}

/// 主题自适应的双层柔和投影。
///
/// 单层硬阴影在深色底上要么看不见、要么脏成一片黑；这里用「一层大范围
/// 环境光 + 一层贴边接触阴影」模拟真实光照，深浅主题分别调色与调透明度。
/// 只用于卡片 / 输入区 / 悬浮按钮这类需要明显抬升感的表面。
List<BoxShadow> dshLayeredShadow(
  DshPalette c, {
  double blur = 18,
  double lift = 4,
  double alpha = 0.06,
}) {
  final Color base = c.isDark
      ? const Color(0xFF000000)
      : const Color(0xFF2C3E6B);
  final double strength = c.isDark ? alpha * 3.0 : alpha;
  return <BoxShadow>[
    BoxShadow(
      color: base.withValues(alpha: strength),
      blurRadius: blur,
      offset: Offset(0, lift),
    ),
    BoxShadow(
      color: base.withValues(alpha: strength * 0.42),
      blurRadius: blur * 0.42,
      offset: Offset(0, lift * 0.35),
    ),
  ];
}
