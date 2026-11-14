import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final distanceFromBottom = pos.maxScrollExtent - pos.pixels;
    final shouldShow = distanceFromBottom > 200;
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
    _voiceController =
        FlaiVoiceController(
          provider: vp,
          onError: (msg) {
            if (mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(msg)));
            }
          },
        )..addListener(() {
          if (mounted) setState(() {});
        });
  }

  @override
  void didUpdateWidget(FlaiChatContent old) {
    super.didUpdateWidget(old);
    if (widget.messages.length != old.messages.length ||
        (widget.messages.isNotEmpty &&
            old.messages.isNotEmpty &&
            widget.messages.last.content != old.messages.last.content)) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _voiceController?.dispose();
    super.dispose();
  }

  Message? _findPreviousUserMessage(int assistantIndex) {
    for (var i = assistantIndex - 1; i >= 0; i--) {
      if (widget.messages[i].role == MessageRole.user) {
        return widget.messages[i];
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = FlaiTheme.of(context);
    final vc = _voiceController;

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
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
                        _ChatStatusStrip(statuses: widget.streamingStatus),
                        indicator,
                      ],
                    );
                  }

                  final msg = widget.messages[index];

                  if (msg.isStreaming && msg.content.isEmpty) {
                    return const SizedBox.shrink();
                  }

                  if (msg.role == MessageRole.assistant && !msg.isStreaming) {
                    final previousUser = _findPreviousUserMessage(index);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MessageBubble(
                            message: msg,
                            onRetry: widget.onRetry,
                          ),
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

                  final Widget bubble =
                      MessageBubble(message: msg, onRetry: widget.onRetry);
                  // 流式气泡已有内容时，状态条继续渲染在其上方。
                  if (msg.isStreaming && widget.streamingStatus.isNotEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _ChatStatusStrip(statuses: widget.streamingStatus),
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
                bottom: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: _showScrollToBottom ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: IgnorePointer(
                      ignoring: !_showScrollToBottom,
                      child: GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _scrollToBottom();
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: theme.colors.card,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colors.border,
                              width: 0.5,
                            ),
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            size: 20,
                            color: theme.colors.foreground,
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

  final List<SearchStatus> statuses;

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
    SearchStatus? searchDone;
    SearchStatus? thinkingDone;
    for (final SearchStatus s in widget.statuses) {
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
      lines.add(_line(t, Icons.wifi_tethering_rounded,
          '正在联网检索：${_clip(searchingQuery)}…'));
    }
    if (searchDone != null) {
      if (searchDone.results.isEmpty) {
        lines.add(_line(t, Icons.search_off_rounded, '联网检索未获取到来源'));
      } else {
        final String titles = searchDone.results
            .map((Map<String, String> r) => _clip(r['title'] ?? '', 20))
            .join('、');
        lines.add(_line(t, Icons.public_rounded,
            '检索到 ${searchDone.results.length} 个来源：$titles'));
      }
    }
    if (thinkingDone != null) {
      lines.add(_line(t, Icons.psychology_rounded, '已完成深度推理'));
    }
    if (lines.isEmpty) return const SizedBox.shrink();

    final bool hasDetails = (searchDone?.results.isNotEmpty ?? false) ||
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
                  GestureDetector(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 16,
                        color: t.textDim,
                      ),
                    ),
                  ),
              ],
            ),
            if (hasDetails && _expanded) ...<Widget>[
              const SizedBox(height: 4),
              if (searchDone != null)
                for (final Map<String, String> r in searchDone.results)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Text(
                      '· ${r['title'] ?? ''} — ${r['url'] ?? ''}',
                      style: TextStyle(fontSize: 11, height: 1.4, color: t.textDim),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              if (thinkingDone != null &&
                  (thinkingDone.points ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1.5),
                  child: Text(
                    thinkingDone.points!,
                    style: TextStyle(
                        fontSize: 11, height: 1.4, color: t.textDim),
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
