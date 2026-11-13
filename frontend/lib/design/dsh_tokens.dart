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
    labelPrimary: Color(0xFF111111),
    labelSecondary: Color(0xFF64748B),
    labelTertiary: Color(0xFF8A97A8),
    labelCaption: Color(0xFFA3AEBD),
    labelDimmed: Color(0xFFD6DBE3),
    labelOnPrimary: Color(0xFFFFFFFF),
    // 页面底色云雾白，卡片 / 输入区纯白，靠色差 + 极浅阴影分层。
    bgBase: Color(0xFFF7F9F7),
    bgLayer1: Color(0xFFFFFFFF),
    bgLayer2: Color(0xFFFFFFFF),
    bgLayer3: Color(0xFFF1F4F6),
    bgModule: Color(0xFFF7F9F7),
    sidebar: Color(0xFFF2F5F3),
    sidebarActive: Color(0xFFE4EEF7),
    bubble: Color(0xFFE4EEF7),
    inputMajor: Color(0xFFFFFFFF),
    selector: Color(0xFFF1F4F6),
    codeBlock: Color(0xFFF5F7F8),
    menuFill: Color(0xFFFFFFFF),
    // 海盐蓝 #B9DDD7 的透明度阶梯（发丝线体系保持不变）。
    borderL1: Color(0x14B9DDD7),
    borderL2: Color(0x29B9DDD7),
    borderL3: Color(0xFFB9DDD7),
    borderL4: Color(0x4DB9DDD7),
    brandPrimary: Color(0xFF4A90D9),
    brandDimmed: Color(0xFFE4EEF7),
    business: Color(0xFF4A90D9),
    businessTertiary: Color(0xFFE4EEF7),
    link: Color(0xFF2563EB),
    hover: Color(0x0A111111),
    pressed: Color(0x14111111),
    hoverSolid: Color(0xFFF1F4F6),
    hoverDanger: Color(0x14DC2626),
    success: Color(0xFF059669),
    successTertiary: Color(0xFFE7F5EF),
    warn: Color(0xFFD97706),
    warnLabel: Color(0xFFD97706),
    warnTertiary: Color(0xFFFBF0E1),
    error: Color(0xFFDC2626),
    idle: Color(0xFFCBD2D9),
    scrim: Color(0x61000000),
    kindSystem: Color(0xFF94A3B8),
    kindTools: Color(0xFF8B5CF6),
    kindMessages: Color(0xFF4A90D9),
  );

  static const DshPalette dark = DshPalette(
    isDark: true,
    labelPrimary: Color(0xFFE2E8F0),
    labelSecondary: Color(0xFF94A3B8),
    labelTertiary: Color(0xFF7A8899),
    labelCaption: Color(0xFF64748B),
    labelDimmed: Color(0xFF38444D),
    labelOnPrimary: Color(0xFF141618),
    // 极夜黑打底，深海盐蓝承载卡片 / 弹窗。
    bgBase: Color(0xFF141618),
    bgLayer1: Color(0xFF212B36),
    bgLayer2: Color(0xFF212B36),
    bgLayer3: Color(0xFF2A3540),
    bgModule: Color(0xFF1B2027),
    sidebar: Color(0xFF141618),
    sidebarActive: Color(0xFF2A3A4A),
    bubble: Color(0xFF2A3A4A),
    inputMajor: Color(0xFF212B36),
    selector: Color(0xFF26313C),
    codeBlock: Color(0xFF1A1F26),
    menuFill: Color(0xFF212B36),
    // 岩层灰 #38444D 的明度阶梯。
    borderL1: Color(0xFF262E36),
    borderL2: Color(0xFF303A44),
    borderL3: Color(0xFF38444D),
    borderL4: Color(0xFF46545F),
    brandPrimary: Color(0xFF7BB5E3),
    brandDimmed: Color(0xFF2A3A4A),
    business: Color(0xFF7BB5E3),
    businessTertiary: Color(0xFF24344A),
    link: Color(0xFF7BB5E3),
    hover: Color(0x14FFFFFF),
    pressed: Color(0x24FFFFFF),
    hoverSolid: Color(0xFF26313C),
    hoverDanger: Color(0x26EF4444),
    success: Color(0xFF10B981),
    successTertiary: Color(0xFF14352A),
    warn: Color(0xFFF59E0B),
    warnLabel: Color(0xFFF59E0B),
    warnTertiary: Color(0xFF352A14),
    error: Color(0xFFEF4444),
    idle: Color(0xFF46545F),
    scrim: Color(0x99000000),
    kindSystem: Color(0xFF94A3B8),
    kindTools: Color(0xFFA78BFA),
    kindMessages: Color(0xFF7BB5E3),
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

/// 抬升表面：0.5dp 描边 + 极淡投影（菜单 / 对话框 / 输入区 / 悬浮键）。
List<BoxShadow> dshSoftShadow({
  double blur = 8,
  double lift = 3,
  double alpha = 0.03,
}) {
  return <BoxShadow>[
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, alpha),
      blurRadius: blur,
      offset: Offset(0, lift),
    ),
  ];
}
