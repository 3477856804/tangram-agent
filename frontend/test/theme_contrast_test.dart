/// 深浅主题文字对比度回归测试。
/// 锁定「次要文字在深浅主题下均可读」，防止再次出现深色模式文字发暗不可见。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangram/design/dsh_tokens.dart';
import 'package:tangram/design/tga_design.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';

double _luminance(Color c) {
  // Flutter 3.27+ 的 Color.r/g/b 已是 0..1 的 double；兼容旧版 0..255。
  double norm(num v) => v > 1 ? v / 255 : v.toDouble();
  double f(num v) {
    final double s = norm(v);
    if (s <= 0.03928) return s / 12.92;
    final double t = (s + 0.055) / 1.055;
    return t * t * t;
  }

  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

double contrast(Color fg, Color bg) {
  final double a = _luminance(fg);
  final double b = _luminance(bg);
  final double hi = a > b ? a : b;
  final double lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('浅色主题文字对比度（WCAG AA ≥ 4.5:1）', () {
    test('正文 textPrimary on surface', () {
      expect(contrast(TangramColors.textPrimary, TangramColors.surface),
          greaterThanOrEqualTo(4.5));
    });
    test('次要 textMuted on surface（曾为 2.97:1）', () {
      expect(contrast(TangramColors.textMuted, TangramColors.surface),
          greaterThanOrEqualTo(4.5));
    });
  });

  group('深色主题文字对比度（WCAG AA ≥ 4.5:1）', () {
    test('正文 textPrimary on background', () {
      expect(contrast(TangramColorsDark.textPrimary, TangramColorsDark.background),
          greaterThanOrEqualTo(4.5));
    });
    test('次要 textMuted on background（曾为 5.02:1，容器上仅 3.66:1）', () {
      expect(contrast(TangramColorsDark.textMuted, TangramColorsDark.background),
          greaterThanOrEqualTo(4.5));
      expect(contrast(TangramColorsDark.textMuted, TangramColorsDark.surfaceHigh),
          greaterThanOrEqualTo(4.5));
    });
    test('思考正文 textPrimary on 思考块容器 surfaceHigh', () {
      expect(contrast(TangramColorsDark.textPrimary, TangramColorsDark.surfaceHigh),
          greaterThanOrEqualTo(4.5));
    });
  });

  group('Tga 设计系统：搜索状态条详情文字对比度（WCAG AA ≥ 4.5:1）', () {
    test('深色 textSub on card（曾用 textDim 仅 2.71:1）', () {
      expect(contrast(TgaTokens.dark.textSub, TgaTokens.dark.card),
          greaterThanOrEqualTo(4.5));
    });
    test('浅色 textSub on card', () {
      expect(contrast(TgaTokens.light.textSub, TgaTokens.light.card),
          greaterThanOrEqualTo(4.5));
    });
  });

  group('对话输入/输出区前景：深色纯白、浅色纯黑', () {
    test('浅色 chatText 为纯黑且对比度达标', () {
      expect(DshPalette.light.chatText, const Color(0xFF000000));
      expect(contrast(DshPalette.light.chatText, DshPalette.light.bgModule),
          greaterThanOrEqualTo(4.5));
      expect(contrast(DshPalette.light.chatText, DshPalette.light.inputMajor),
          greaterThanOrEqualTo(4.5));
    });
    test('深色 chatText 为纯白且对比度达标', () {
      expect(DshPalette.dark.chatText, const Color(0xFFFFFFFF));
      expect(contrast(DshPalette.dark.chatText, DshPalette.dark.bgModule),
          greaterThanOrEqualTo(4.5));
      expect(contrast(DshPalette.dark.chatText, DshPalette.dark.bubble),
          greaterThanOrEqualTo(4.5));
    });
  });
}
