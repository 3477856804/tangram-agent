import 'package:flutter/material.dart';

import '../../../../design/dsh_tokens.dart';
import '../../../../design/dsh_widgets.dart';
import '../../../../ui/i18n/tga_strings.dart';
import '../chat_experience_config.dart';

/// 空会话态（设计稿 2026-11-12）：居中的品牌组合（七巧板鹿标 + 问候语），
/// 紧跟输入区。按设计稿去掉了「算一算 / 看能力 / 本地状态 / 跑自检」这一排
/// 快捷胶囊；底部功能行（加号 / 深度思考 / 智能搜索 / TGA 引擎）由输入区
/// composer 承载，此处不再重复渲染任何快捷入口。
class FlaiEmptyChatState extends StatelessWidget {
  final ChatExperienceConfig config;

  /// 输入区（由 home 页传入，保证与空态一起垂直居中）。
  final Widget? footer;

  /// 兼容旧调用点保留该参数；设计稿已去掉快捷指令区，不再使用。
  final ValueChanged<String>? onSuggestion;

  const FlaiEmptyChatState({
    super.key,
    required this.config,
    this.footer,
    this.onSuggestion,
  });

  /// 问候语按时段动态（用户实测反馈 2026-11-13）：
  /// <5 夜深了 / <9 早上好 / <12 上午好 / <14 中午好 / <18 下午好 / 其余 晚上好。
  static String _greetKey() {
    final int hour = DateTime.now().hour;
    if (hour < 5) return 'home.greet.night';
    if (hour < 9) return 'home.greet.early';
    if (hour < 12) return 'home.greet.am';
    if (hour < 14) return 'home.greet.noon';
    if (hour < 18) return 'home.greet.afternoon';
    return 'home.greet.evening';
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final String title = context.t(_greetKey());

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: DshSpace.x16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.sizeOf(context).height * 0.55,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            // 设计稿 2026-11-13 用户反馈：去掉鹿标外的白色圆角卡片背景，
            // 直接显示 logo 图片本身（尺寸保持 56）。
            TangramGlyph(size: 56, color: c.labelPrimary),
            const SizedBox(height: DshSpace.x24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: DshSpace.x16),
              child: Text(
                title,
                style: DshType.s14m.copyWith(
                  fontSize: 24,
                  height: 32 / 24,
                  fontWeight: FontWeight.w700,
                  color: c.labelPrimary,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            if (config.resolvedGreetingSubtitle.isNotEmpty) ...<Widget>[
              const SizedBox(height: DshSpace.x8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DshSpace.x24),
                child: Text(
                  config.resolvedGreetingSubtitle,
                  style: DshType.xs13.copyWith(
                    fontSize: 13,
                    color: c.labelSecondary,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            const SizedBox(height: DshSpace.x24),
            if (footer != null) footer!,
          ],
        ),
      ),
    );
  }
}
