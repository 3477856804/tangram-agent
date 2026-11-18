/// 回归测试：深色模式下 AI 对话正文必须清晰可读（白色/近白），
/// 浅色模式下为黑色/近黑，且前景色跟随应用主题真源 FlaiTheme。
///
/// 背景（2026-11-19 用户截图反馈）：深色主题下正文近乎全黑、完全不可见。
/// 根因：正文前景 chatFg 曾读取 Theme.of(context).brightness（Material 主题），
/// 在 Material 亮度与 FlaiTheme 不同步时退化为 Colors.black（对比度约 1.05:1）。
/// 本测试锁定修复后的契约：chatForegroundColor 只由 FlaiTheme 决定。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangram/flai/components/message_bubble/message_bubble.dart';
import 'package:tangram/flai/core/theme/flai_theme.dart';

double luminance(Color c) => c.computeLuminance();

void main() {
  group('AI 对话正文前景色（深色白字 / 浅色黑字）', () {
    test('深色主题前景为浅色（近白），对照深色背景对比度 >= 4.5:1', () {
      final Color fg = chatForegroundColor(FlaiThemeData.dark());
      final Color bg = FlaiThemeData.dark().colors.background;
      final double cr = (luminance(fg) + 0.05) / (luminance(bg) + 0.05);
      expect(luminance(fg), greaterThan(0.5), reason: '深色模式正文应为浅色字');
      expect(cr, greaterThanOrEqualTo(4.5), reason: '深色正文与背景对比度不足');
    });

    test('浅色主题前景为深色（近黑），对照浅色背景对比度 >= 4.5:1', () {
      final Color fg = chatForegroundColor(FlaiThemeData.light());
      final Color bg = FlaiThemeData.light().colors.background;
      final double cr = (luminance(bg) + 0.05) / (luminance(fg) + 0.05);
      expect(luminance(fg), lessThan(0.5), reason: '浅色模式正文应为深色字');
      expect(cr, greaterThanOrEqualTo(4.5), reason: '浅色正文与背景对比度不足');
    });

    test('前景色由 FlaiTheme 决定，与 Material 亮度无关', () {
      // 直接以 FlaiTheme 实例求色，不引入任何 Material Theme 依赖。
      // 即使外部 Material brightness 为 light，深色 FlaiTheme 仍返回浅色字。
      final Color darkFg = chatForegroundColor(FlaiThemeData.dark());
      final Color lightFg = chatForegroundColor(FlaiThemeData.light());
      expect(darkFg, isNot(Colors.black));
      expect(lightFg, isNot(Colors.white));
      expect(luminance(darkFg), greaterThan(luminance(lightFg)));
    });
  });
}
