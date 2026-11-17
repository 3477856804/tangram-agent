import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design/dsh_motion.dart';
import '../../../../design/dsh_tokens.dart';
import '../../../../design/dsh_widgets.dart';
import '../../../../ui/i18n/tga_strings.dart';
import '../chat_experience_config.dart';

class _QuickPrompt {
  const _QuickPrompt(this.icon, this.label);

  final IconData icon;
  final String label;
}

/// 空态快捷指令：仅在调用方提供 onSuggestion 时展示（无回调的旧调用点
/// 保持原视觉），点击即把文案交给真实发送链路。
const List<_QuickPrompt> _quickPrompts = <_QuickPrompt>[
  _QuickPrompt(Icons.auto_awesome_rounded, '帮我梳理这段内容'),
  _QuickPrompt(Icons.lightbulb_outline_rounded, '用一句话解释这个概念'),
  _QuickPrompt(Icons.edit_note_rounded, '帮我起草一段文案'),
];

/// 空会话态（设计稿 2026-11-12）：居中的品牌组合（七巧板鹿标 + 问候语），
/// 紧跟输入区。底部功能行（加号 / 深度思考 / 智能搜索 / TGA 引擎）由输入区
/// composer 承载；此处仅保留一排轻量快捷指令，带语义标签与按压反馈。
class FlaiEmptyChatState extends StatelessWidget {
  final ChatExperienceConfig config;

  /// 输入区（由 home 页传入，保证与空态一起垂直居中）。
  final Widget? footer;

  /// 快捷指令回调：非空时展示一排快捷指令，点击把文案交给真实发送链路；
  /// 为 null 的旧调用点不渲染快捷指令，保持原有视觉。
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
            // 品牌标、问候语、副标题、快捷指令依次错落淡入：像人打开
            // 一个新会话时的节奏，而不是整屏「啪」地一次性出现。
            // 系统开启「减少动态效果」时 DshFadeSlideIn 会自动退化为直出。
            DshFadeSlideIn(
              duration: DshMotion.entrance,
              offsetY: 10,
              child: TangramGlyph(size: 56, color: c.labelPrimary),
            ),
            const SizedBox(height: DshSpace.x24),
            DshFadeSlideIn(
              delay: const Duration(milliseconds: 70),
              duration: DshMotion.normal,
              offsetY: 8,
              child: Padding(
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
            ),
            if (config.resolvedGreetingSubtitle.isNotEmpty)
              DshFadeSlideIn(
                delay: const Duration(milliseconds: 130),
                duration: DshMotion.normal,
                offsetY: 8,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    DshSpace.x24,
                    DshSpace.x8,
                    DshSpace.x24,
                    0,
                  ),
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
              ),
            if (onSuggestion != null) ...<Widget>[
              const SizedBox(height: DshSpace.x20),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DshSpace.x16),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: DshSpace.x8,
                  runSpacing: DshSpace.x8,
                  children: _quickPrompts
                      .asMap()
                      .entries
                      .map(
                        (MapEntry<int, _QuickPrompt> e) => DshFadeSlideIn(
                          delay: Duration(milliseconds: 180 + e.key * 55),
                          duration: DshMotion.normal,
                          offsetY: 10,
                          child: _QuickPromptChip(
                            prompt: e.value,
                            onTap: () => onSuggestion!(e.value.label),
                          ),
                        ),
                      )
                      .toList(),
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

class _QuickPromptChip extends StatelessWidget {
  const _QuickPromptChip({required this.prompt, required this.onTap});

  final _QuickPrompt prompt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Semantics(
      button: true,
      label: '快捷指令：${prompt.label}',
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: BoxDecoration(
            color: c.inputMajor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: c.borderL3, width: 0.8),
          ),
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            borderRadius: BorderRadius.circular(999),
            splashColor: c.pressed,
            highlightColor: c.hover,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: DshSpace.x10,
                vertical: DshSpace.x6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(prompt.icon, size: 14, color: c.labelSecondary),
                  const SizedBox(width: DshSpace.x6),
                  Text(
                    prompt.label,
                    style: DshType.xxs12.copyWith(
                      fontSize: 12.5,
                      color: c.labelPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
