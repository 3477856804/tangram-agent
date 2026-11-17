import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/dsh_motion.dart';
import '../../design/dsh_tokens.dart';
import '../../design/tga_design.dart';
import '../components/message_bubble/message_bubble.dart';
import '../components/typing_indicator/typing_indicator.dart';
import '../core/models/chat_event.dart';
import '../core/models/message.dart';
import '../core/theme/flai_theme.dart';
import '../flows/chat/chat_experience_config.dart';
import '../flows/chat/voice_controller.dart';
import '../flows/chat/widgets/composer_v2.dart';
import '../providers.dart';

class FlaiChatContent extends StatefulWidget {
  final List<Message> messages;
  final ChatExperienceConfig config;
  final FlaiSendHandler onSend;
  final bool isStreaming;
  final void Function(Message)? onRetry;
  final void Function(Message)? onRegenerate;

  /// 后端 chat_status 真实过程事件（联网检索 / 深度推理，问题 #4b），
  /// 仅在本次流式回复期间渲染于流式气泡上方。
  final List<SearchStatus> streamingStatus;

  const FlaiChatContent({
    super.key,
    required this.messages,
    required this.config,
    required this.onSend,
    this.isStreaming = false,
    this.onRetry,
    this.onRegenerate,
    this.streamingStatus = const <SearchStatus>[],
  });

  @override
  State<FlaiChatContent> createState() => _FlaiChatContentState();
}

class _FlaiChatContentState extends State<FlaiChatContent> {
  final ScrollController _scrollController = ScrollController();
  FlaiVoiceController? _voiceController;
  VoidCallback? _voiceListener;
  bool _showScrollToBottom = false;

  /// 用户是否处于「贴底阅读」。上翻查看历史时置 false，流式新内容不再
  /// 强行把视图拽回底部，避免打断阅读；点「回到底部」后恢复。
  bool _stickToBottom = true;

  /// 合并同一帧内的多次滚动请求。流式输出时原本每个 token 都会启动一条
  /// 150ms 滚动动画，动画互相打断既抖动又掉帧。
  bool _scrollScheduled = false;

  /// itemBuilder 内向前找上一条用户消息会让整列表退化成 O(n²)；
  /// 改在每次 build 前线性预计算一次，构建时按索引直接取。
  List<Message?> _previousUsers = const <Message?>[];

  static const double _stickThreshold = 96;
  static const double _buttonThreshold = 200;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final ScrollPosition pos = _scrollController.position;
    final double distance = pos.maxScrollExtent - pos.pixels;
    _stickToBottom = distance <= _stickThreshold;
    final bool shouldShow = distance > _buttonThreshold;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _initVoice();
  }

  void _initVoice() {
    if (_voiceController != null) return;
    if (!widget.config.enableVoice) return;
    final vp = FlaiProviders.of(context).voiceProvider;
    if (vp == null) return;
    // 持有具名回调，dispose 时才能正确摘除监听；原先的匿名闭包会
    // 在语音控制器释放后仍被引用，属于潜在的内存 / 回调泄漏。
    _voiceListener = () {
      if (mounted) setState(() {});
    };
    _voiceController = FlaiVoiceController(
      provider: vp,
      onError: (msg) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(msg)));
        }
      },
    )..addListener(_voiceListener!);
  }

  @override
  void didUpdateWidget(FlaiChatContent old) {
    super.didUpdateWidget(old);
    final bool countChanged = widget.messages.length != old.messages.length;
    final bool lastChanged =
        widget.messages.isNotEmpty &&
        old.messages.isNotEmpty &&
        widget.messages.last.content != old.messages.last.content;
    if (!countChanged && !lastChanged) return;

    // 用户刚发出一条消息时回到输入流；否则只在用户本来就贴底时跟随，
    // 上翻查看历史期间收到回复不会被强行拽回底部。
    final bool userJustSent =
        countChanged &&
        widget.messages.length > old.messages.length &&
        widget.messages[old.messages.length].role == MessageRole.user;
    _followBottom(animated: countChanged, force: userJustSent);
  }

  /// 跟随到底部：高频流式更新走无动画 [ScrollController.jumpTo]，
  /// 低频的新消息追加才走短动画；同一帧内多次请求合并为一次。
  void _followBottom({required bool animated, bool force = false}) {
    if (!force && !_stickToBottom) return;
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!_scrollController.hasClients) return;
      final ScrollPosition pos = _scrollController.position;
      final double target = pos.maxScrollExtent;
      if ((pos.pixels - target).abs() < 1) return;
      if (animated) {
        _scrollController.animateTo(
          target,
          duration: DshMotion.normal,
          curve: DshMotion.standard,
        );
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }

  void _jumpToBottomFromButton() {
    HapticFeedback.lightImpact();
    _stickToBottom = true;
    _scrollScheduled = false;
    _followBottom(animated: true, force: true);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    final VoidCallback? listener = _voiceListener;
    if (listener != null) _voiceController?.removeListener(listener);
    _voiceController?.dispose();
    super.dispose();
  }

  /// 一次线性扫描为所有消息预存「上一条用户消息」，供「重新生成」使用。
  void _recomputePreviousUsers() {
    final int n = widget.messages.length;
    final List<Message?> result = List<Message?>.filled(
      n,
      null,
      growable: false,
    );
    Message? lastUser;
    for (int i = 0; i < n; i++) {
      result[i] = lastUser;
      if (widget.messages[i].role == MessageRole.user) {
        lastUser = widget.messages[i];
      }
    }
    _previousUsers = result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FlaiTheme.of(context);
    final vc = _voiceController;
    _recomputePreviousUsers();

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              ListView.builder(
                controller: _scrollController,
                // 拖动消息列表时收起键盘：手机上更自然，也避免键盘压住输入区。
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                itemCount:
                    widget.messages.length +
                    (widget.isStreaming && _isWaitingForFirstToken ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index == widget.messages.length) {
                    final Widget indicator = const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: FlaiTypingIndicator(),
                      ),
                    );
                    // 等待首 token 期间，检索/推理状态条显示在指示器上方。
                    if (widget.streamingStatus.isEmpty) return indicator;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ChatStatusStrip(
                          statuses: widget.streamingStatus
                              .map((SearchStatus s) => s.toProcessStatus())
                              .toList(),
                        ),
                        indicator,
                      ],
                    );
                  }

                  final msg = widget.messages[index];

                  if (msg.isStreaming && msg.content.isEmpty) {
                    return const SizedBox.shrink();
                  }

                  if (msg.role == MessageRole.assistant && !msg.isStreaming) {
                    final Message? previousUser = index < _previousUsers.length
                        ? _previousUsers[index]
                        : null;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 历史消息仍可展开查看当时的检索/推理路径。
                          if (msg.processStatuses != null &&
                              msg.processStatuses!.isNotEmpty)
                            _ChatStatusStrip(statuses: msg.processStatuses!),
                          MessageBubble(message: msg, onRetry: widget.onRetry),
                          if (msg.status == MessageStatus.complete &&
                              previousUser != null &&
                              widget.onRegenerate != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 2, top: 2),
                              child: GestureDetector(
                                onTap: () => widget.onRegenerate!(previousUser),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.refresh_rounded,
                                      size: 16,
                                      color: theme.colors.mutedForeground,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '重新生成',
                                      style: theme.typography.bodySmall(
                                        color: theme.colors.mutedForeground,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  }

                  final Widget bubble = MessageBubble(
                    message: msg,
                    onRetry: widget.onRetry,
                  );
                  // 流式气泡已有内容时，状态条继续渲染在其上方。
                  if (msg.isStreaming && widget.streamingStatus.isNotEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ChatStatusStrip(
                            statuses: widget.streamingStatus
                                .map((SearchStatus s) => s.toProcessStatus())
                                .toList(),
                          ),
                          bubble,
                        ],
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: bubble,
                  );
                },
              ),
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: IgnorePointer(
                    ignoring: !_showScrollToBottom,
                    child: AnimatedOpacity(
                      opacity: _showScrollToBottom ? 1.0 : 0.0,
                      duration: DshMotion.fast,
                      curve: DshMotion.standard,
                      child: AnimatedScale(
                        scale: _showScrollToBottom ? 1.0 : 0.82,
                        duration: DshMotion.fast,
                        curve: DshMotion.standard,
                        child: DshPressable(
                          onTap: _jumpToBottomFromButton,
                          borderRadius: BorderRadius.circular(999),
                          semanticsLabel: '回到最新消息',
                          tooltip: '回到最新消息',
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: theme.colors.card,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: theme.colors.border,
                                width: 0.6,
                              ),
                              boxShadow: dshLayeredShadow(
                                DshPalette.of(context),
                                blur: 14,
                                lift: 3,
                              ),
                            ),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 21,
                              color: theme.colors.foreground,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: FlaiComposerV2(
              config: widget.config,
              onSend: widget.onSend,
              isRecording: vc?.isRecording ?? false,
              isTranscribing: vc?.isTranscribing ?? false,
              voiceTranscript: vc?.lastTranscript,
              onVoiceStart: vc != null ? () => vc.startRecording() : null,
              onVoiceStop: vc != null ? () => vc.stopRecording() : null,
            ),
          ),
        ),
      ],
    );
  }

  bool get _isWaitingForFirstToken {
    if (!widget.isStreaming) return false;
    if (widget.messages.isEmpty) return true;
    final last = widget.messages.last;
    return last.isStreaming && last.content.isEmpty;
  }
}

/// 流式气泡上方的真实过程状态条（问题 #4b）：内容全部来自后端
/// chat_status 热点事件（联网检索开始/完成、深度推理规划完成），
/// 不展示任何编造进度；来源列表可折叠展开查看标题 + URL。
class _ChatStatusStrip extends StatefulWidget {
  const _ChatStatusStrip({required this.statuses});

  /// 用可持久化的 ProcessStatus，流式与历史消息统一渲染。
  final List<ProcessStatus> statuses;

  @override
  State<_ChatStatusStrip> createState() => _ChatStatusStripState();
}

class _ChatStatusStripState extends State<_ChatStatusStrip> {
  bool _expanded = false;

  static String _clip(String s, [int max = 48]) =>
      s.length > max ? '${s.substring(0, max)}…' : s;

  Widget _line(TgaTokens t, IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: t.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: TextStyle(fontSize: 11.5, height: 1.4, color: t.textSub),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TgaTokens t = Tga.tokens;

    String? searchingQuery;
    ProcessStatus? searchDone;
    ProcessStatus? thinkingDone;
    for (final ProcessStatus s in widget.statuses) {
      switch (s.phase) {
        case 'searching':
          searchingQuery = s.query ?? '';
          break;
        case 'search_done':
          searchDone = s;
          break;
        case 'thinking_done':
          thinkingDone = s;
          break;
      }
    }
    // 检索已完成后不再显示「正在检索」（该阶段真实结束）。
    if (searchDone != null) searchingQuery = null;

    final List<Widget> lines = <Widget>[];
    if (searchingQuery != null) {
      lines.add(
        _line(
          t,
          Icons.wifi_tethering_rounded,
          '正在联网检索：${_clip(searchingQuery)}…',
        ),
      );
    }
    if (searchDone != null) {
      if (searchDone.results.isEmpty) {
        lines.add(_line(t, Icons.search_off_rounded, '联网检索未获取到来源'));
      } else {
        final String titles = searchDone.results
            .map((Map<String, String> r) => _clip(r['title'] ?? '', 20))
            .join('、');
        lines.add(
          _line(
            t,
            Icons.public_rounded,
            '检索到 ${searchDone.results.length} 个来源：$titles',
          ),
        );
      }
    }
    if (thinkingDone != null) {
      lines.add(_line(t, Icons.psychology_rounded, '已完成深度推理'));
    }
    if (lines.isEmpty) return const SizedBox.shrink();

    final bool hasDetails =
        (searchDone?.results.isNotEmpty ?? false) ||
        ((thinkingDone?.points ?? '').isNotEmpty);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          color: t.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: t.divider, width: 0.8),
        ),
        padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: lines,
                  ),
                ),
                if (hasDetails)
                  DshPressable(
                    onTap: () => setState(() => _expanded = !_expanded),
                    borderRadius: BorderRadius.circular(999),
                    semanticsLabel: _expanded ? '收起检索详情' : '展开检索详情',
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: AnimatedRotation(
                        turns: _expanded ? 0.5 : 0.0,
                        duration: DshMotion.fast,
                        curve: DshMotion.standard,
                        child: Icon(
                          Icons.expand_more_rounded,
                          size: 16,
                          color: t.textSub,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            // 详情展开 / 收起走高度缓动，不再「啪」地跳一下。
            AnimatedSize(
              duration: DshMotion.fast,
              curve: DshMotion.standard,
              alignment: Alignment.topLeft,
              child: (hasDetails && _expanded)
                  ? Padding(
                      padding: const EdgeInsets.only(top: 4, right: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (searchDone != null)
                            for (final Map<String, String> r
                                in searchDone.results)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 1.5,
                                ),
                                child: Text(
                                  '· ${r['title'] ?? ''} — ${r['url'] ?? ''}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    height: 1.4,
                                    color: t.textSub,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          if (thinkingDone != null &&
                              (thinkingDone.points ?? '').isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 1.5,
                              ),
                              child: Text(
                                thinkingDone.points!,
                                style: TextStyle(
                                  fontSize: 11,
                                  height: 1.4,
                                  color: t.textSub,
                                ),
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}
