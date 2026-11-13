import 'package:flutter/material.dart';

import '../../../design/dsh_tokens.dart';
import 'flai_colors.dart';
import 'flai_radius.dart';
import 'flai_spacing.dart';
import 'flai_theme.dart';

/// TGA的调色板。
///
/// 规范与 dsh（DeepSeek Harness）一致：**单色品牌**（近黑 / 近白）承载结构，
/// 蓝色只做强调（链接、选中、发送），状态色只表达状态。
/// 这里保留旧字段名（jade / violet / gold …），是为了让业务面板不必逐处改名，
/// 但它们现在都落在 dsh 的中性色阶上。
class TangramColors {
  TangramColors._();

  // 表面：页面底色云雾白 #F7F9F7（67%），卡片 / 输入区纯白（25%），靠色差分层。
  static const Color background = Color(0xFFF7F9F7);
  static const Color backgroundAlt = Color(0xFFF2F5F3);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceHigh = Color(0xFFF7F9F7);
  static const Color surfaceRaised = Color(0xFFF1F4F6);

  // 文本：墨黑 / 贝壳灰
  static const Color textPrimary = Color(0xFF111111);
  static const Color textSecondary = Color(0xFF64748B);
  static const Color textMuted = Color(0xFF8A97A8);
  static const Color textCaption = Color(0xFFA3AEBD);

  // 描边（海盐蓝 #B9DDD7 透明度阶梯）
  static const Color borderL1 = Color(0x14B9DDD7);
  static const Color borderL2 = Color(0x29B9DDD7);
  static const Color borderL3 = Color(0xFFB9DDD7);
  static const Color borderL4 = Color(0x4DB9DDD7);

  // 品牌 / 点缀：深星蓝 #4A90D9，只上主按钮与选中态（8% 纪律）。
  static const Color brand = Color(0xFF4A90D9);
  static const Color brandDimmed = Color(0xFFE4EEF7);
  static const Color onBrand = Color(0xFFFFFFFF);

  static const Color accent = Color(0xFF4A90D9);
  static const Color accentSoft = Color(0xFFE4EEF7);

  // 旧字段：语义对齐
  static const Color ruiMu = Color(0xFF111111);
  static const Color ruiMuLight = Color(0xFF64748B);
  static const Color tanMu = Color(0xFFA3AEBD);
  static const Color jade = Color(0xFF4A90D9);
  static const Color jadeDeep = Color(0xFF2563EB);
  static const Color gold = Color(0xFFD97706);
  static const Color goldLight = Color(0xFFF59E0B);
  static const Color violet = Color(0xFF8B5CF6);
  static const Color magenta = Color(0xFFDC2626);

  // 状态（浅色语义）
  static const Color success = Color(0xFF059669);
  static const Color successSoft = Color(0xFFE7F5EF);
  static const Color warning = Color(0xFFD97706);
  static const Color warningSoft = Color(0xFFFBF0E1);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerSoft = Color(0xFFFCE8E8);
  static const Color idle = Color(0xFFCBD2D9);

  // 用户气泡
  static const Color bubble = Color(0xFFE4EEF7);
}

/// 深色模式色板（极夜黑 / 深海盐蓝 / 柔光星蓝），与 DshPalette.dark 同源。
class TangramColorsDark {
  TangramColorsDark._();

  static const Color background = Color(0xFF141618);
  static const Color backgroundAlt = Color(0xFF1B2027);
  static const Color surface = Color(0xFF212B36);
  static const Color surfaceHigh = Color(0xFF26313C);
  static const Color surfaceRaised = Color(0xFF2A3540);

  static const Color textPrimary = Color(0xFFE2E8F0);
  static const Color textSecondary = Color(0xFF94A3B8);
  static const Color textMuted = Color(0xFF7A8899);
  static const Color textCaption = Color(0xFF64748B);

  static const Color borderL1 = Color(0xFF262E36);
  static const Color borderL2 = Color(0xFF303A44);
  static const Color borderL3 = Color(0xFF38444D);
  static const Color borderL4 = Color(0xFF46545F);

  static const Color brand = Color(0xFF7BB5E3);
  static const Color brandDimmed = Color(0xFF2A3A4A);
  static const Color onBrand = Color(0xFF141618);

  static const Color accent = Color(0xFF7BB5E3);
  static const Color accentSoft = Color(0xFF24344A);

  static const Color ruiMu = Color(0xFFE2E8F0);
  static const Color ruiMuLight = Color(0xFF94A3B8);
  static const Color tanMu = Color(0xFF64748B);
  static const Color jade = Color(0xFF7BB5E3);
  static const Color jadeDeep = Color(0xFF3B82F6);
  static const Color gold = Color(0xFFF59E0B);
  static const Color goldLight = Color(0xFFF7AD31);
  static const Color violet = Color(0xFFA78BFA);
  static const Color magenta = Color(0xFFEF4444);

  static const Color success = Color(0xFF10B981);
  static const Color successSoft = Color(0xFF14352A);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningSoft = Color(0xFF352A14);
  static const Color danger = Color(0xFFEF4444);
  static const Color dangerSoft = Color(0xFF3B1518);
  static const Color idle = Color(0xFF46545F);

  static const Color bubble = Color(0xFF2A3A4A);
}

/// dsh 不用渐变做层级；这里保留类型，全部收敛成平色/单色。
class TangramGradients {
  TangramGradients._();

  static const LinearGradient backdrop = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFFFFFFFF), Color(0xFFFFFFFF)],
  );

  static const LinearGradient card = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFFFFFFFF), Color(0xFFFFFFFF)],
  );

  static const LinearGradient panel = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFFFFFFFF), Color(0xFFFFFFFF)],
  );

  static const LinearGradient brandMark = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF0F1115), Color(0xFF353638)],
  );

  static const LinearGradient neural = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFF0F1115), Color(0xFF4176E6)],
  );

  static const LinearGradient accent = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[Color(0xFF4176E6), Color(0xFF4176E6)],
  );

  static const LinearGradient rail = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[Color(0xFFF9FAFB), Color(0xFFF9FAFB)],
  );
}

class TangramSpacing {
  TangramSpacing._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  static const EdgeInsets page = EdgeInsets.symmetric(
    horizontal: lg,
    vertical: xl,
  );
}

class TangramRadii {
  TangramRadii._();

  static const double xs = DshR.xs;
  static const double sm = DshR.sm;
  static const double tile = DshR.tile;
  static const double md = DshR.md;
  static const double lg = DshR.lg;
  static const double xl = DshR.xl;
  static const double panel = DshR.panel;
  static const double pill = 999;
}

class TangramTheme {
  TangramTheme._();

  /// dsh 配色映射到 FlaiColors（浅色）。
  static const FlaiColors flaiColors = FlaiColors(
    background: TangramColors.background,
    foreground: TangramColors.textPrimary,
    card: TangramColors.surface,
    cardForeground: TangramColors.textPrimary,
    popover: TangramColors.surface,
    popoverForeground: TangramColors.textPrimary,
    primary: TangramColors.brand,
    primaryForeground: TangramColors.onBrand,
    secondary: TangramColors.surfaceHigh,
    secondaryForeground: TangramColors.textPrimary,
    muted: TangramColors.surfaceHigh,
    mutedForeground: TangramColors.textMuted,
    accent: TangramColors.accentSoft,
    accentForeground: TangramColors.accent,
    destructive: TangramColors.danger,
    destructiveForeground: Colors.white,
    border: TangramColors.borderL3,
    input: TangramColors.borderL2,
    ring: TangramColors.accent,
    userBubble: TangramColors.bubble,
    userBubbleForeground: TangramColors.textPrimary,
    assistantBubble: Colors.transparent,
    assistantBubbleForeground: TangramColors.textPrimary,
  );

  /// 深色 FlaiColors（极夜黑 / 深海盐蓝 / 柔光星蓝）。
  static const FlaiColors flaiColorsDark = FlaiColors(
    background: TangramColorsDark.background,
    foreground: TangramColorsDark.textPrimary,
    card: TangramColorsDark.surface,
    cardForeground: TangramColorsDark.textPrimary,
    popover: TangramColorsDark.surface,
    popoverForeground: TangramColorsDark.textPrimary,
    primary: TangramColorsDark.brand,
    primaryForeground: TangramColorsDark.onBrand,
    secondary: TangramColorsDark.surfaceHigh,
    secondaryForeground: TangramColorsDark.textPrimary,
    muted: TangramColorsDark.surfaceHigh,
    mutedForeground: TangramColorsDark.textMuted,
    accent: TangramColorsDark.accentSoft,
    accentForeground: TangramColorsDark.accent,
    destructive: TangramColorsDark.danger,
    destructiveForeground: Colors.white,
    border: TangramColorsDark.borderL3,
    input: TangramColorsDark.borderL2,
    ring: TangramColorsDark.accent,
    userBubble: TangramColorsDark.bubble,
    userBubbleForeground: TangramColorsDark.textPrimary,
    assistantBubble: Colors.transparent,
    assistantBubbleForeground: TangramColorsDark.textPrimary,
  );

  /// Material 3 主题（浅色）。
  static ThemeData light() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: TangramColors.accent,
      brightness: Brightness.light,
    ).copyWith(
      primary: TangramColors.brand,
      onPrimary: TangramColors.onBrand,
      primaryContainer: TangramColors.brandDimmed,
      onPrimaryContainer: TangramColors.textPrimary,
      secondary: TangramColors.accent,
      onSecondary: Colors.white,
      secondaryContainer: TangramColors.accentSoft,
      onSecondaryContainer: const Color(0xFF0E3074),
      tertiary: TangramColors.accent,
      surface: TangramColors.surface,
      onSurface: TangramColors.textPrimary,
      onSurfaceVariant: TangramColors.textSecondary,
      outline: TangramColors.borderL4,
      outlineVariant: TangramColors.borderL2,
      error: TangramColors.danger,
      surfaceTint: Colors.transparent,
    );
    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: TangramColors.background,
      splashFactory: InkSparkle.splashFactory,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: TangramColors.textPrimary,
        displayColor: TangramColors.textPrimary,
      ),
      iconTheme: const IconThemeData(
        color: TangramColors.textSecondary,
        size: 20,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: TangramColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: const DividerThemeData(
        color: TangramColors.borderL2,
        thickness: 0.5,
        space: 0.5,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: TangramColors.backgroundAlt,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: TangramColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: TangramColors.accent,
        selectionColor: TangramColors.accent.withValues(alpha: 0.24),
        selectionHandleColor: TangramColors.accent,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: false,
        border: InputBorder.none,
        hintStyle: TextStyle(color: TangramColors.textCaption),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) {
          return s.contains(WidgetState.selected) ? Colors.white : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) {
          return s.contains(WidgetState.selected)
              ? TangramColors.accent
              : const Color(0xFFE1E5EE);
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }

  /// Material 3 主题（深色）：极夜黑打底、深海盐蓝承载卡片、柔光星蓝只做点缀。
  static ThemeData dark() {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: TangramColorsDark.accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: TangramColorsDark.brand,
      onPrimary: TangramColorsDark.onBrand,
      primaryContainer: TangramColorsDark.brandDimmed,
      onPrimaryContainer: TangramColorsDark.textPrimary,
      secondary: TangramColorsDark.accent,
      onSecondary: TangramColorsDark.onBrand,
      secondaryContainer: TangramColorsDark.accentSoft,
      onSecondaryContainer: TangramColorsDark.textPrimary,
      tertiary: TangramColorsDark.accent,
      surface: TangramColorsDark.surface,
      onSurface: TangramColorsDark.textPrimary,
      onSurfaceVariant: TangramColorsDark.textSecondary,
      outline: TangramColorsDark.borderL4,
      outlineVariant: TangramColorsDark.borderL2,
      error: TangramColorsDark.danger,
      surfaceTint: Colors.transparent,
    );
    final ThemeData base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: TangramColorsDark.background,
      splashFactory: InkSparkle.splashFactory,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(
        bodyColor: TangramColorsDark.textPrimary,
        displayColor: TangramColorsDark.textPrimary,
      ),
      iconTheme: const IconThemeData(
        color: TangramColorsDark.textSecondary,
        size: 20,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: TangramColorsDark.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      dividerTheme: const DividerThemeData(
        color: TangramColorsDark.borderL2,
        thickness: 0.5,
        space: 0.5,
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: TangramColorsDark.backgroundAlt,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: TangramColorsDark.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: TangramColorsDark.accent,
        selectionColor: Color(0x3D7BB5E3),
        selectionHandleColor: TangramColorsDark.accent,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: false,
        border: InputBorder.none,
        hintStyle: TextStyle(color: TangramColorsDark.textCaption),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) {
          return s.contains(WidgetState.selected)
              ? TangramColorsDark.onBrand
              : TangramColorsDark.textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((Set<WidgetState> s) {
          return s.contains(WidgetState.selected)
              ? TangramColorsDark.accent
              : TangramColorsDark.borderL2;
        }),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }

  static FlaiThemeData flaiTheme() => FlaiThemeData(
    colors: flaiColors,
    radius: const FlaiRadius(
      sm: TangramRadii.xs,
      md: TangramRadii.sm,
      lg: TangramRadii.lg,
      xl: TangramRadii.xl,
      full: TangramRadii.pill,
    ),
    spacing: const FlaiSpacing(
      xs: TangramSpacing.xs,
      sm: TangramSpacing.sm,
      md: TangramSpacing.md,
      lg: TangramSpacing.lg,
      xl: TangramSpacing.xl,
      xxl: TangramSpacing.xxl,
    ),
  );

  /// 深色 FlaiThemeData：app.dart 在深色 / 跟随系统命中暗色时注入。
  static FlaiThemeData flaiThemeDark() => FlaiThemeData(
    colors: flaiColorsDark,
    radius: const FlaiRadius(
      sm: TangramRadii.xs,
      md: TangramRadii.sm,
      lg: TangramRadii.lg,
      xl: TangramRadii.xl,
      full: TangramRadii.pill,
    ),
    spacing: const FlaiSpacing(
      xs: TangramSpacing.xs,
      sm: TangramSpacing.sm,
      md: TangramSpacing.md,
      lg: TangramSpacing.lg,
      xl: TangramSpacing.xl,
      xxl: TangramSpacing.xxl,
    ),
  );
}
