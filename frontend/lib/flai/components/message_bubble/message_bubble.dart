import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../core/models/message.dart';
import '../../../design/dsh_motion.dart';
import '../../../design/dsh_tokens.dart';
import '../../core/theme/flai_theme.dart';

/// AI 对话正文前景色：必须跟随应用主题真源 FlaiTheme。
///
/// 不可改用 Theme.of(context).brightness——Material 主题在局部 Theme 覆盖、
/// 路由缓存或深浅切换过渡时会与 FlaiTheme 不同步，深色背景下将取到
/// Colors.black（对比度约 1.05:1，正文完全不可见，2026-11-19 用户截图反馈）。
/// theme.colors.foreground 由 _resolveTheme 独立决定：
/// 深色 #EDEFF5（近白）、浅色 #17181C（近黑）。
Color chatForegroundColor(FlaiThemeData theme) => theme.colors.foreground;

class MessageBubble extends StatelessWidget {
  final Message message;

  final void Function(Citation citation)? onTapCitation;

  final void Function(Message message)? onRetry;

  final void Function(Message message)? onLongPress;

  const MessageBubble({
    super.key,
    required this.message,
    this.onTapCitation,
    this.onRetry,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FlaiTheme.of(context);

    return switch (message.role) {
      MessageRole.system => _SystemLayout(
        message: message,
        theme: theme,
        onLongPress: onLongPress,
      ),
      MessageRole.tool => _ToolLayout(
        message: message,
        theme: theme,
        onLongPress: onLongPress,
      ),
      _ => _ChatLayout(
        message: message,
        theme: theme,
        onTapCitation: onTapCitation,
        onRetry: onRetry,
        onLongPress: onLongPress,
      ),
    };
  }
}

class _ChatLayout extends StatelessWidget {
  final Message message;
  final FlaiThemeData theme;
  final void Function(Citation)? onTapCitation;
  final void Function(Message)? onRetry;
  final void Function(Message)? onLongPress;

  const _ChatLayout({
    required this.message,
    required this.theme,
    this.onTapCitation,
    this.onRetry,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;

    final isError = message.status == MessageStatus.error;
    // 需求：深色模式输出区文字白色、浅色模式黑色。
    // 关键：前景色必须跟随【应用主题真源 FlaiTheme】，而不是 Material 的
    // Theme.of(context).brightness。后者在局部 Theme 覆盖、路由缓存或深浅
    // 切换过渡时会与 FlaiTheme 不同步，导致深色背景下正文取到 Colors.black
    // （对比度约 1.05:1，完全不可见）。theme.colors.foreground 由 app.dart
    // 的 _resolveTheme 独立决定：深色 #EDEFF5（近白）、浅色 #17181C（近黑），
    // 从根上消除双主题源不同步造成的黑字。
    final Color chatFg = chatForegroundColor(theme);
    // 用户气泡改用主题自带的前景色，避免深色气泡（浅色主题下的用户气泡）
    // 上出现低对比度文字。
    final Color bubbleFg = isUser ? theme.colors.userBubbleForeground : chatFg;
    // FlaiTheme.dark 的 destructive 是深红底色，直接当文字色在深底上不可读；
    // 错误提示统一取 dsh 语义错误色（深色 #EF4444 / 浅色 #DC2626）。
    final Color errorFg = DshPalette.of(context).error;

    return Semantics(
      label: isError ? '消息发送失败，可重试' : null,
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82,
          ),
          child: Padding(
            padding: EdgeInsets.only(
              left: isUser ? theme.spacing.xl : theme.spacing.md,
              right: isUser ? theme.spacing.md : theme.spacing.xl,
              bottom: theme.spacing.sm,
            ),
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (message.hasThinking) ...[
                  _ThinkingBlock(
                    content: message.thinkingContent!,
                    theme: theme,
                  ),
                  SizedBox(height: theme.spacing.xs),
                ],

                if (!isUser && message.hasToolCalls) ...[
                  _ToolCallChips(toolCalls: message.toolCalls!, theme: theme),
                  SizedBox(height: theme.spacing.xs),
                ],

                if (isError) ...[
                  _ErrorNotice(theme: theme, color: errorFg),
                  SizedBox(height: theme.spacing.xs),
                ],

                GestureDetector(
                  onLongPress: onLongPress != null
                      ? () => onLongPress!(message)
                      : () => _copy(context),
                  child: Container(
                    padding: isUser
                        ? const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          )
                        : EdgeInsets.zero,
                    decoration: BoxDecoration(
                      color: isUser
                          ? theme.colors.userBubble
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(DshR.xl),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _MessageContent(
                          content: message.content,
                          isStreaming: message.isStreaming,
                          style: theme.typography.bodyBase(color: bubbleFg),
                          cursorColor: bubbleFg,
                        ),

                        if (message.hasCitations) ...[
                          SizedBox(height: theme.spacing.sm),
                          ...message.citations!.map(
                            (c) => _CitationCard(
                              citation: c,
                              theme: theme,
                              onTap: onTapCitation != null
                                  ? () => onTapCitation!(c)
                                  : null,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // 长消息不再只能靠长按猜操作：气泡下方常驻复制 / 重试入口。
                if (!message.isStreaming &&
                    message.content.trim().isNotEmpty) ...[
                  SizedBox(height: theme.spacing.xs),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _BubbleAction(
                        icon: Icons.copy_rounded,
                        label: '复制',
                        theme: theme,
                        onTap: () => _copy(context),
                      ),
                      if (isError && onRetry != null) ...[
                        SizedBox(width: theme.spacing.xs),
                        _BubbleAction(
                          icon: Icons.refresh_rounded,
                          label: '重试',
                          theme: theme,
                          tone: errorFg,
                          onTap: () {
                            HapticFeedback.lightImpact();
                            onRetry!(message);
                          },
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _copy(BuildContext context) {
    if (message.content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: message.content));
    HapticFeedback.lightImpact();
    // 连续复制时先撤掉上一条提示，避免 SnackBar 排队堆叠。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.check_circle_outline_rounded,
                size: 16,
                color: Theme.of(context).colorScheme.onInverseSurface,
              ),
              const SizedBox(width: 8),
              const Text('已复制到剪贴板'),
            ],
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

/// 错误气泡顶部提示：用图标 + 文案直说失败，而不是只靠一个重试按钮。
class _ErrorNotice extends StatelessWidget {
  final FlaiThemeData theme;
  final Color color;

  const _ErrorNotice({required this.theme, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, size: 14, color: color),
        SizedBox(width: theme.spacing.xs),
        Flexible(
          child: Text(
            '消息发送失败',
            style: theme.typography.bodySmall(color: theme.colors.foreground),
          ),
        ),
      ],
    );
  }
}

/// 气泡可见操作（复制 / 重试）：常驻显示，避免长按才有入口。
class _BubbleAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final FlaiThemeData theme;
  final VoidCallback onTap;
  final Color? tone;

  const _BubbleAction({
    required this.icon,
    required this.label,
    required this.theme,
    required this.onTap,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = tone ?? theme.colors.mutedForeground;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(theme.radius.sm),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: theme.spacing.sm,
                vertical: theme.spacing.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 13, color: color),
                  SizedBox(width: theme.spacing.xs),
                  Text(label, style: theme.typography.bodySmall(color: color)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SystemLayout extends StatelessWidget {
  final Message message;
  final FlaiThemeData theme;
  final void Function(Message)? onLongPress;

  const _SystemLayout({
    required this.message,
    required this.theme,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        onLongPress: onLongPress != null ? () => onLongPress!(message) : null,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.65,
          ),
          margin: EdgeInsets.symmetric(
            horizontal: theme.spacing.lg,
            vertical: theme.spacing.xs,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: theme.spacing.md,
            vertical: theme.spacing.sm,
          ),
          decoration: BoxDecoration(
            color: theme.colors.muted.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(theme.radius.md),
            border: Border.all(
              color: theme.colors.border.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            message.content,
            textAlign: TextAlign.center,
            style: theme.typography.bodySmall(
              color: theme.colors.mutedForeground,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolLayout extends StatelessWidget {
  final Message message;
  final FlaiThemeData theme;
  final void Function(Message)? onLongPress;

  const _ToolLayout({
    required this.message,
    required this.theme,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: onLongPress != null ? () => onLongPress!(message) : null,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          margin: EdgeInsets.only(
            left: theme.spacing.md,
            right: theme.spacing.xl,
            bottom: theme.spacing.sm,
          ),
          padding: EdgeInsets.symmetric(
            horizontal: theme.spacing.md,
            vertical: theme.spacing.sm,
          ),
          decoration: BoxDecoration(
            color: theme.colors.muted.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(theme.radius.md),
            border: Border.all(
              color: theme.colors.border.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.build_rounded,
                size: 14,
                color: theme.colors.mutedForeground,
              ),
              SizedBox(width: theme.spacing.sm),
              Flexible(
                child: Text(
                  message.content,
                  style: theme.typography.bodySmall(
                    color: theme.colors.mutedForeground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThinkingBlock extends StatefulWidget {
  final String content;
  final FlaiThemeData theme;

  const _ThinkingBlock({required this.content, required this.theme});

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock>
    with SingleTickerProviderStateMixin {
  // 默认直接展示思考过程：用户可点击收起，再点展开（状态仅在本气泡生命周期内）。
  bool _expanded = true;
  late final AnimationController _controller;
  late final Animation<double> _expandAnimation;
  late final Animation<double> _rotationAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    // 已展开状态直接就位，避免每条历史消息入场时都播一次展开动画。
    _controller.value = 1.0;
    _expandAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _rotationAnimation = Tween<double>(
      begin: 0.0,
      end: 0.5,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;

    return Semantics(
      button: true,
      expanded: _expanded,
      label: _expanded ? '思考过程，已展开，点击收起' : '思考过程，已收起，点击展开',
      onTap: _toggle,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: _toggle,
        child: Container(
          padding: EdgeInsets.all(theme.spacing.sm),
          decoration: BoxDecoration(
            // 用不透明容器而非 0.5 透明：半透明容器会与深色底混合，把正文
            // 对比度从 5:1 拉低到 3.6:1（截图里整段思考内容发暗的根因）。
            color: theme.colors.muted,
            borderRadius: BorderRadius.circular(theme.radius.md),
            border: Border.all(color: theme.colors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.psychology_rounded,
                    size: 14,
                    color: theme.colors.mutedForeground,
                  ),
                  SizedBox(width: theme.spacing.xs),
                  Text(
                    '思考过程',
                    style: theme.typography.sm.copyWith(
                      color: theme.colors.mutedForeground,
                    ),
                  ),
                  const Spacer(),
                  // 明确的折叠状态提示：收起时显示「展开」，展开时显示「收起」。
                  Text(
                    _expanded ? '收起' : '展开',
                    style: theme.typography.sm.copyWith(
                      fontSize: 12,
                      color: theme.colors.mutedForeground,
                    ),
                  ),
                  RotationTransition(
                    turns: _rotationAnimation,
                    child: Icon(
                      Icons.expand_more,
                      size: 16,
                      color: theme.colors.mutedForeground,
                    ),
                  ),
                ],
              ),
              SizeTransition(
                sizeFactor: _expandAnimation,
                axisAlignment: -1.0,
                child: Padding(
                  padding: EdgeInsets.only(top: theme.spacing.xs),
                  child: Text(
                    widget.content,
                    // 思考内容是真实信息，用正文前景色保证深浅主题均清晰；
                    // 不再用 mutedForeground + 斜体（小字斜体叠加低对比度不可读）。
                    style: theme.typography.bodySmall(
                      color: theme.colors.foreground,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolCallChips extends StatelessWidget {
  final List<ToolCall> toolCalls;
  final FlaiThemeData theme;

  const _ToolCallChips({required this.toolCalls, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: theme.spacing.xs,
      runSpacing: theme.spacing.xs,
      children: toolCalls
          .map((tc) => _ToolCallChip(toolCall: tc, theme: theme))
          .toList(),
    );
  }
}

class _ToolCallChip extends StatelessWidget {
  final ToolCall toolCall;
  final FlaiThemeData theme;

  const _ToolCallChip({required this.toolCall, required this.theme});

  @override
  Widget build(BuildContext context) {
    final isComplete = toolCall.isComplete;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: theme.spacing.sm,
        vertical: theme.spacing.xs,
      ),
      decoration: BoxDecoration(
        color: theme.colors.muted.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(theme.radius.sm),
        border: Border.all(color: theme.colors.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isComplete ? Icons.check_circle : Icons.hourglass_top,
            size: 12,
            // 完成态用正文前景色（主题感知，深浅均清晰）；不再硬编码
            // #4ADE80——它在浅色 chip 上对比度偏低且完全不随主题切换。
            color: isComplete
                ? theme.colors.foreground
                : theme.colors.mutedForeground,
          ),
          SizedBox(width: theme.spacing.xs),
          Text(
            toolCall.name,
            style: theme.typography.mono(
              color: theme.colors.assistantBubbleForeground,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _CitationCard extends StatelessWidget {
  final Citation citation;
  final FlaiThemeData theme;
  final VoidCallback? onTap;

  const _CitationCard({
    required this.citation,
    required this.theme,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: theme.spacing.xs),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: theme.spacing.sm,
            vertical: theme.spacing.xs + 2,
          ),
          decoration: BoxDecoration(
            color: theme.colors.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(theme.radius.sm),
            border: Border.all(
              color: theme.colors.accent.withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.link_rounded, size: 13, color: theme.colors.accent),
              SizedBox(width: theme.spacing.xs),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      citation.title,
                      style: theme.typography.bodySmall(
                        color: theme.colors.accentForeground,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    if (citation.snippet != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        citation.snippet!,
                        style: theme.typography.bodySmall(
                          color: theme.colors.mutedForeground,
                        ),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageContent extends StatelessWidget {
  final String content;
  final bool isStreaming;
  final TextStyle style;
  final Color cursorColor;

  const _MessageContent({
    required this.content,
    required this.isStreaming,
    required this.style,
    required this.cursorColor,
  });

  /// 同一套前景色 / 字号的 MarkdownStyleSheet 只构造一次。
  /// 长会话滚动时，原本每个气泡重建都会 new 出约 30 个 TextStyle 与
  /// 若干 BoxDecoration —— 纯 GC 压力，且与最终渲染结果无关。
  static final Map<int, MarkdownStyleSheet> _sheetCache =
      <int, MarkdownStyleSheet>{};

  static MarkdownStyleSheet _sheetFor(TextStyle style, Color cursorColor) {
    final int key = Object.hash(
      style.color,
      style.fontSize,
      style.fontWeight,
      style.fontFamily,
      style.height,
      cursorColor,
    );
    final MarkdownStyleSheet? cached = _sheetCache[key];
    if (cached != null) return cached;
    // UI 自定义字号是连续值，给缓存设上限，避免长期运行无限增长。
    if (_sheetCache.length >= 24) _sheetCache.clear();
    final MarkdownStyleSheet sheet = _buildSheet(style, cursorColor);
    _sheetCache[key] = sheet;
    return sheet;
  }

  static MarkdownStyleSheet _buildSheet(TextStyle style, Color cursorColor) {
    // 所有文本样式都显式沿用气泡前景色：MarkdownStyleSheet 未设置的
    // 元素会回退到 Theme 默认前景色，深色模式下标题/加粗/引用/表格
    // 会与 AI 气泡背景近同色而不可见（问题 #1）。
    final TextStyle heading = style.copyWith(
      fontWeight: FontWeight.w700,
      height: 1.3,
    );
    final TextStyle bold = style.copyWith(fontWeight: FontWeight.w700);
    return MarkdownStyleSheet(
      p: style,
      pPadding: EdgeInsets.zero,
      h1: heading,
      h2: heading.copyWith(fontSize: (style.fontSize ?? 14) + 4),
      h3: heading.copyWith(fontSize: (style.fontSize ?? 14) + 2),
      h4: heading,
      h5: heading,
      h6: heading,
      h1Padding: EdgeInsets.zero,
      h2Padding: EdgeInsets.zero,
      h3Padding: EdgeInsets.zero,
      h4Padding: EdgeInsets.zero,
      h5Padding: EdgeInsets.zero,
      h6Padding: EdgeInsets.zero,
      em: style.copyWith(fontStyle: FontStyle.italic),
      strong: bold,
      del: style.copyWith(decoration: TextDecoration.lineThrough),
      blockquote: style.copyWith(color: style.color?.withValues(alpha: 0.85)),
      blockquotePadding: const EdgeInsets.only(left: 10),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: style.color?.withValues(alpha: 0.35) ?? Colors.grey,
            width: 3,
          ),
        ),
      ),
      listBullet: style,
      listBulletPadding: const EdgeInsets.only(left: 18, top: 2),
      listIndent: 18,
      tableHead: bold,
      tableBody: style,
      tableHeadAlign: TextAlign.center,
      tableBorder: TableBorder.all(
        color: style.color?.withValues(alpha: 0.25) ?? Colors.grey,
        width: 1,
      ),
      a: style.copyWith(
        color: cursorColor,
        decoration: TextDecoration.underline,
      ),
      code: style.copyWith(
        fontFamily: 'monospace',
        backgroundColor: Colors.transparent,
      ),
      codeblockDecoration: BoxDecoration(
        color: style.color?.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.fromLTRB(12, 32, 12, 12),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: style.color?.withValues(alpha: 0.25) ?? Colors.grey,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!isStreaming) {
      return MarkdownBody(
        data: content,
        styleSheet: _sheetFor(style, cursorColor),
        builders: {'code': _CodeBlockBuilder(codeColor: style.color)},
        selectable: true,
        shrinkWrap: true,
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(child: Text(content, style: style)),
        const SizedBox(width: 2),
        _BlinkingCursor(color: cursorColor),
      ],
    );
  }
}

class _BlinkingCursor extends StatefulWidget {
  final Color color;

  const _BlinkingCursor({required this.color});

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    // 系统要求减少动态效果时保持常亮光标：不常驻逐帧刷新，也更省电。
    if (DshMotion.reduced(context)) {
      _controller.value = 1.0;
    } else {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Container(
        width: 2,
        height: 16,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: widget.color,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  final Color? codeColor;

  _CodeBlockBuilder({this.codeColor});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (element.tag != 'code') return null;
    final parent = element.attributes['class'];
    final lang = parent != null && parent.startsWith('language-')
        ? parent.substring(9)
        : null;
    final code = element.textContent.trimRight();
    return _CodeBlockWidget(code: code, language: lang, codeColor: codeColor);
  }
}

class _CodeBlockWidget extends StatelessWidget {
  final String code;
  final String? language;
  final Color? codeColor;

  const _CodeBlockWidget({required this.code, this.language, this.codeColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: codeColor?.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: codeColor?.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(8),
              ),
            ),
            child: Row(
              children: [
                // 语言名占满剩余宽度并省略，复制入口始终固定在右上角。
                Expanded(
                  child: Text(
                    language ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: codeColor?.withValues(alpha: 0.7),
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  button: true,
                  label: '复制代码',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: code));
                      HapticFeedback.lightImpact();
                      ScaffoldMessenger.of(context)
                        ..hideCurrentSnackBar()
                        ..showSnackBar(
                          const SnackBar(
                            content: Text('已复制到剪贴板'),
                            duration: Duration(seconds: 1),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 28,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.copy_rounded,
                            size: 13,
                            color: codeColor?.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '复制',
                            style: TextStyle(
                              fontSize: 11,
                              color: codeColor?.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            // 超长单行代码横向滚动，避免把气泡撑出屏幕。
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                code,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: codeColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
