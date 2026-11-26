import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../design/dsh_motion.dart';
import '../../../../design/dsh_tokens.dart';
import '../../../../design/dsh_widgets.dart';
import '../../../../design/tga_glass.dart';
import '../../../../services/model_registry.dart';
import '../../../../services/persona_store.dart';
import '../../../../services/audio_transcribe_service.dart';
import '../../../../ui/i18n/tga_strings.dart';
import '../chat_experience_config.dart';
import 'attachment_menu.dart';
import 'attachment_picker.dart';
import 'model_selector_sheet.dart';

/// 发送回调：文本 + 「深度思考 / 智能搜索」两个胶囊的真实开关状态。
/// 标志沿 onSend → HomeController.sendMessage → ChatRequest →
/// TangramAiProvider._payload 一路透传进后端 chat payload。
typedef FlaiSendHandler =
    void Function(String text, bool thinking, bool search);

/// 输入区：dsh 的 InputBar —— R28 的白色卡片 + 发丝描边 + 极淡投影。
/// 编辑器在上，工具行在下：[+] · 模型 · …… · 麦克风 · 发送。
class FlaiComposerV2 extends StatefulWidget {
  final ChatExperienceConfig config;

  final FlaiSendHandler onSend;

  final String? currentModelId;

  final ValueChanged<ModelOption>? onModelChanged;

  final VoidCallback? onVoiceStart;

  final VoidCallback? onVoiceStop;

  final bool isRecording;

  final bool isTranscribing;

  final String? voiceTranscript;

  /// 转写序号：每次新转写递增。UI 用它判断「有无新转写」，比文本差异可靠
  /// （连续两次相同内容文本不变，字符串比较会漏；且序号能避免覆盖用户已输入文字）。
  final int voiceTranscriptSeq;

  /// 实时麦克风声级（0.0 ~ 1.0），由 FlaiVoiceController.amplitude 提供。
  /// 为空表示当前录音链路没有声级来源，波形区继续如实显示「振幅未接入」。
  final ValueListenable<double>? amplitude;

  const FlaiComposerV2({
    super.key,
    required this.config,
    required this.onSend,
    this.currentModelId,
    this.onModelChanged,
    this.onVoiceStart,
    this.onVoiceStop,
    this.isRecording = false,
    this.isTranscribing = false,
    this.voiceTranscript,
    this.voiceTranscriptSeq = 0,
    this.amplitude,
  });

  @override
  State<FlaiComposerV2> createState() => _FlaiComposerV2State();
}

class _FlaiComposerV2State extends State<FlaiComposerV2> {
  final TextEditingController _textController = TextEditingController();
  final List<PickedAttachment> _pendingAttachments = <PickedAttachment>[];

  /// 输入状态用 ValueNotifier 承载：打字时只重建编辑器行与发送键，
  /// 不再让每次按键都重建整个输入区（含模型下拉、附件预览、Provider 订阅）。
  final ValueNotifier<bool> _hasText = ValueNotifier<bool>(false);

  /// 编辑器聚焦状态，用于给整张输入卡一个柔和的点亮反馈。
  final FocusNode _focusNode = FocusNode();
  bool _focused = false;

  // 已应用到输入框的转写序号：避免同一段转写在多次重建中被重复追加。
  int _appliedTranscriptSeq = 0;

  // 录音文件转文字：真实上传网关 ASR，状态与结果如实呈现。
  final AudioTranscribeService _asr = AudioTranscribeService();
  bool _audioTranscribing = false;
  String? _audioNotice;

  // 设计稿 2026-11-12 主页底部功能开关：深度思考 / 智能搜索。
  // 模型切换的唯一入口是底部「TGA 引擎」下拉（_openModelSelector），
  // 旧输入行里的模型 chip 是重复入口，已删除。
  // 开关状态经 SharedPreferences 真实落盘（问题 #4a）：initState 恢复、
  // 切换即保存；发送 / 新会话 / 重启都不会重置。
  bool _deepThink = false;
  bool _smartSearch = false;

  static const String _kPrefDeepThink = 'tga.deepThink';
  static const String _kPrefSmartSearch = 'tga.smartSearch';

  Future<void> _restoreToggles() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _deepThink = prefs.getBool(_kPrefDeepThink) ?? _deepThink;
        _smartSearch = prefs.getBool(_kPrefSmartSearch) ?? _smartSearch;
      });
    } on Object {
      // 持久化不可用（如无平台实现）时降级为内存态，不阻塞输入区。
    }
  }

  Future<void> _persistToggles() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPrefDeepThink, _deepThink);
      await prefs.setBool(_kPrefSmartSearch, _smartSearch);
    } on Object {
      // 保存失败静默：开关仍在本会话内生效，绝不弹假错误。
    }
  }

  void _toggleDeepThink() {
    setState(() => _deepThink = !_deepThink);
    _persistToggles();
  }

  void _toggleSmartSearch() {
    setState(() => _smartSearch = !_smartSearch);
    _persistToggles();
  }

  @override
  void initState() {
    super.initState();
    _restoreToggles();
    _textController.addListener(() {
      final bool has = _textController.text.trim().isNotEmpty;
      if (has != _hasText.value) _hasText.value = has;
    });
    _focusNode.addListener(() {
      final bool value = _focusNode.hasFocus;
      if (_focused != value) setState(() => _focused = value);
    });
  }

  @override
  void didUpdateWidget(FlaiComposerV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    // seq 变小说明换了新会话 / 新语音控制器：重置计数，避免新会话首条
    // 转写被旧的更大序号挡住导致「语音输入又不能用了」。
    if (widget.voiceTranscriptSeq < _appliedTranscriptSeq) {
      _appliedTranscriptSeq = 0;
    }
    // 用序号而非文本差异判断新转写：连续两次相同内容也能正确填入，
    // 且只在真正有新转写时追加一次，绝不覆盖用户已输入的文字。
    if (widget.voiceTranscriptSeq > _appliedTranscriptSeq &&
        widget.voiceTranscript != null &&
        widget.voiceTranscript!.isNotEmpty) {
      _appliedTranscriptSeq = widget.voiceTranscriptSeq;
      final String incoming = widget.voiceTranscript!.trim();
      final String existing = _textController.text.trim();
      if (existing.isEmpty) {
        _textController.text = incoming;
      } else if (!existing.endsWith(incoming)) {
        _textController.text = '$existing $incoming';
      }
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
      _hasText.value = true;
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _hasText.dispose();
    _focusNode.dispose();
    _asr.dispose();
    super.dispose();
  }

  void _handleSend() {
    final String text = _textController.text.trim();
    if (text.isEmpty && _pendingAttachments.isEmpty) return;
    // 附件是真实功能：把文件元信息与可解码的文本内容一并交给内嵌后端，
    // 后端会真实解析并回应；不再弹「未接入」提示，也不发送假占位。
    final String payload = _composePayload(text);
    _textController.clear();
    if (_pendingAttachments.isNotEmpty) {
      setState(() => _pendingAttachments.clear());
    }
    // 「深度思考 / 智能搜索」的真实开关状态随本次发送一并透传给后端。
    widget.onSend(payload, _deepThink, _smartSearch);
  }

  /// 把已选附件真实拼进消息。文本类附件读取真实文件内容（限制 8KB），
  /// 二进制/不可解码附件只登记元信息并如实说明，绝不伪造文本内容。
  /// 注意：'[附件]' 等标记是内嵌后端的路由协议（embedded_backend
  /// ._routeIntent / _summarizeAttachments 按 '[附件]' 切块解析），
  /// 属消息数据而非界面文案，故不做本地化。
  String _composePayload(String text) {
    if (_pendingAttachments.isEmpty) return text;
    final buf = StringBuffer();
    if (text.isNotEmpty) buf.writeln(text);
    for (final PickedAttachment a in _pendingAttachments) {
      final String size = a.sizeBytes == null
          ? '大小未知'
          : _humanSize(a.sizeBytes!);
      // 图片走真实本地路径：内嵌后端会把它交给带 mmproj 的视觉模型；
      // 不再当成二进制附件只登记元信息。
      if (a.mimeType?.startsWith('image/') == true && a.file.existsSync()) {
        buf.writeln('[图片] ${a.file.path}');
        continue;
      }
      buf.writeln('[附件] ${a.name}（${a.mimeType ?? '未知类型'}，$size）');
      final String? content = _readTextAttachment(a);
      if (content != null) {
        buf.writeln('--- 文件内容 ---');
        buf.writeln(content);
        buf.writeln('--- 内容结束 ---');
      } else {
        buf.writeln('（二进制或不可解码附件：仅登记元信息，不伪造文本内容。）');
      }
    }
    return buf.toString().trim();
  }

  static const Set<String> _textExtensions = <String>{
    '.txt',
    '.md',
    '.json',
    '.yaml',
    '.yml',
    '.csv',
    '.log',
    '.dart',
    '.py',
    '.js',
    '.ts',
    '.xml',
    '.html',
    '.css',
    '.sh',
    '.toml',
    '.ini',
    '.conf',
  };

  String? _readTextAttachment(PickedAttachment a) {
    final String lower = a.name.toLowerCase();
    final bool isText =
        a.mimeType?.startsWith('text/') == true ||
        _textExtensions.any(lower.endsWith);
    if (!isText) return null;
    try {
      final File file = a.file;
      if (!file.existsSync()) return null;
      final List<int> data = file.readAsBytesSync();
      if (data.length > 256 * 1024) return null;
      final String decoded = utf8.decode(data);
      return decoded.length > 8000
          ? '${decoded.substring(0, 8000)}\n…（内容已截断至 8000 字符）'
          : decoded;
    } on Object {
      return null;
    }
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _openAttachmentMenu() async {
    await showAttachmentMenu(
      context: context,
      config: widget.config.composerConfig,
      onAttachmentPicked: (PickedAttachment picked) {
        setState(() => _pendingAttachments.add(picked));
      },
      onAudioPicked: _handleAudioForTranscription,
    );
  }

  /// 录音文件 → 真实 ASR 转写 → 文字填入输入框展示。
  /// 全程不伪造：转写中显示进度，失败如实展示可读原因。
  Future<void> _handleAudioForTranscription(PickedAttachment audio) async {
    setState(() {
      _audioTranscribing = true;
      _audioNotice = '正在转写「${audio.name}」…';
    });
    try {
      final TranscriptionResult result = await _asr.transcribeFile(audio.path);
      if (!mounted) return;
      // 转写文字填入输入框：用户可见、可编辑、可继续发送给模型。
      final String existing = _textController.text.trim();
      _textController.text = existing.isEmpty
          ? result.text
          : '$existing\n${result.text}';
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
      setState(() {
        _audioTranscribing = false;
        _audioNotice = '已从录音提取文字，可编辑后发送。';
      });
    } on TranscriptionException catch (e) {
      if (!mounted) return;
      setState(() {
        _audioTranscribing = false;
        _audioNotice = '转写失败：${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _audioTranscribing = false;
        _audioNotice = '转写失败：$e';
      });
    }
  }

  /// 把真实注册表转换成选择器选项：带（本地）/（云端）标记、分组、来源副标题。
  /// 分组标题走 i18n 词典，随语言即时切换。
  List<ModelOption> _optionsOf(BuildContext context, ModelRegistry r) => r
      .entries
      .map((ModelEntry e) {
        final String group = e.builtin
            ? context.t('home.modelGroupBuiltin', zh: '内置')
            : (e.kind == ModelKind.cloud
                  ? context.t('home.modelGroupCloud', zh: '云端模型（API）')
                  : context.t('home.modelGroupLocal', zh: '本地模型（权重）'));
        final IconData icon = e.builtin
            ? Icons.bolt_rounded
            : (e.kind == ModelKind.cloud
                  ? Icons.cloud_outlined
                  : Icons.storage_outlined);
        return ModelOption(
          id: e.id,
          name: e.displayName,
          description: e.subtitle,
          icon: icon,
          group: group,
        );
      })
      .toList(growable: false);

  Future<void> _openModelSelector() async {
    final ModelRegistry registry = context.read<ModelRegistry>();
    final PersonaStore persona = context.read<PersonaStore>();
    // 每次打开都重读真实磁盘/配置：新下载的权重、刚保存的 API 立即出现。
    await registry.refresh();
    if (!mounted) return;
    final ModelOption? model = await showModelSelector(
      context: context,
      models: _optionsOf(context, registry),
      currentModelId: registry.selectedId,
    );
    if (model == null || !mounted) return;
    // 真实落盘选中项（重启可恢复），并同步旧的 PersonaStore 字段。
    await registry.setSelected(model.id);
    if (!mounted) return;
    // 底部模型按钮文案立即联动新选中项（问题 #2a）。
    setState(() {});
    persona.setSelectedModelId(model.id);
    widget.onModelChanged?.call(model);
  }

  void _handleMicTap() {
    if (widget.isRecording) {
      widget.onVoiceStop?.call();
    } else {
      widget.onVoiceStart?.call();
    }
  }

  /// 按住说话：按下开始录音、松开停止。
  /// 参考主流输入法与 WorkBuddy/Qoder 的交互，同时保留单击切换作为兜底，
  /// 让「点一下开始 / 再点一下停止」与「按住说话」都能用。
  void _handleMicLongPressStart(LongPressStartDetails _) {
    if (!widget.isRecording) widget.onVoiceStart?.call();
  }

  void _handleMicLongPressEnd(LongPressEndDetails _) {
    if (widget.isRecording) widget.onVoiceStop?.call();
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);

    // 保留语言 / 人格配置订阅（切换语言时输入区文案即时刷新），
    // 但把高频的模型注册表订阅下沉到「TGA 引擎」入口的 Builder 子树：
    // 模型下载 / 切换只重建那一小块，不再把整个输入区（含正在编辑的
    // TextField）一起重建。
    context.watch<PersonaStore>();
    // 设计稿 2026-11-13：编辑器行在上（浅灰输入框 + 发送键），功能行在下
    // （加号 / 深度思考 / 智能搜索 / TGA 引擎）。模型切换只保留底部
    // 「TGA 引擎」这一个下拉入口，不再在输入行重复渲染模型 chip。
    // 无障碍 / 自动化友好：Ctrl/⌘ + M 仍可直接打开模型选择器。
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyM, control: true):
            _openModelSelector,
        const SingleActivator(LogicalKeyboardKey.keyM, meta: true):
            _openModelSelector,
      },
      child: Transform.translate(
        offset: const Offset(0, DshComposerSpec.translateY),
        child: AnimatedContainer(
          duration: DshMotion.reduced(context) ? Duration.zero : DshMotion.fast,
          curve: DshMotion.standard,
          decoration: BoxDecoration(
            color: c.isDark
                ? c.inputMajor.withValues(alpha: 0.82)
                : c.inputMajor.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(DshComposerSpec.radius),
            // 聚焦时描边点亮、投影略抬升，明确告诉用户「现在在输入」。
            border: Border.all(
              color: _focused ? c.business.withValues(alpha: 0.45) : c.borderL2,
              width: _focused ? 1.2 : DshComposerSpec.borderWidth,
            ),
            boxShadow: dshLayeredShadow(
              c,
              blur: DshComposerSpec.shadowBlur,
              lift: DshComposerSpec.shadowLift,
              alpha: _focused
                  ? DshComposerSpec.shadowAlpha * 1.6
                  : DshComposerSpec.shadowAlpha,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(
            DshSpace.x12,
            DshSpace.x10,
            DshSpace.x12,
            DshSpace.x10,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_pendingAttachments.isNotEmpty)
                _AttachmentPreviewRow(
                  attachments: _pendingAttachments,
                  onRemove: (int index) {
                    setState(() => _pendingAttachments.removeAt(index));
                  },
                ),
              if (_audioNotice != null) _buildAudioNotice(c),
              if (widget.isRecording || widget.isTranscribing)
                _buildRecordingRow(c)
              else ...<Widget>[
                _buildEditorRow(c),
                const SizedBox(height: DshSpace.x10),
                _buildFeatureRow(c),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 录音转文字状态条：转写中显示进度，成功/失败如实呈现，
  /// 颜色全部取自语义调色板，深浅主题均清晰可读。
  Widget _buildAudioNotice(DshPalette c) {
    final bool isError = _audioNotice!.startsWith('转写失败');
    final Color fg = isError ? c.link : c.labelSecondary;
    return Semantics(
      liveRegion: true,
      label: _audioNotice,
      child: Padding(
        padding: const EdgeInsets.only(bottom: DshSpace.x8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            if (_audioTranscribing)
              SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.brandPrimary,
                ),
              )
            else
              Icon(
                isError ? Icons.error_outline : Icons.audiotrack_rounded,
                size: 15,
                color: fg,
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _audioNotice!,
                style: TextStyle(fontSize: 12, color: fg),
              ),
            ),
            if (!_audioTranscribing)
              GestureDetector(
                onTap: () => setState(() => _audioNotice = null),
                behavior: HitTestBehavior.opaque,
                child: Icon(Icons.close, size: 14, color: c.labelTertiary),
              ),
          ],
        ),
      ),
    );
  }

  /// 编辑器行：浅灰圆角输入框 + 发送键。
  ///
  /// 只有这一行订阅输入状态：打字时不再触发整张输入卡的重建。
  Widget _buildEditorRow(DshPalette c) {
    return ValueListenableBuilder<bool>(
      valueListenable: _hasText,
      builder: (BuildContext context, bool hasText, Widget? _) {
        final bool canSend = hasText || _pendingAttachments.isNotEmpty;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: DshComposerSpec.editorMinHeight,
                ),
                child: AnimatedContainer(
                  duration: DshMotion.reduced(context)
                      ? Duration.zero
                      : DshMotion.fast,
                  curve: DshMotion.standard,
                  padding: const EdgeInsets.symmetric(
                    horizontal: DshSpace.x12,
                    vertical: DshSpace.x8,
                  ),
                  decoration: BoxDecoration(
                    color: c.bgModule,
                    borderRadius: BorderRadius.circular(DshR.md),
                    border: Border.all(
                      color: _focused
                          ? c.business.withValues(alpha: 0.16)
                          : Colors.transparent,
                      width: 0.8,
                    ),
                  ),
                  child: TextField(
                    controller: _textController,
                    focusNode: _focusNode,
                    maxLines: 8,
                    minLines: 1,
                    onSubmitted: (_) => _handleSend(),
                    textInputAction: TextInputAction.send,
                    cursorColor: c.business,
                    cursorWidth: 1.5,
                    // 需求：深色模式输入文字纯白、浅色模式纯黑。
                    // 使用专用对话前景令牌，不随次要文字色阶变化。
                    style: DshType.s14.copyWith(color: c.chatText),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: widget.isRecording
                          ? context.t('home.listening', zh: '正在听…')
                          : (widget.config.enableVoice
                              ? context.t('home.voicePlaceholder',
                                  zh: '发消息或按住说话')
                              : context.t(
                                  'home.inputHint',
                                  zh: widget.config.resolvedPlaceholder,
                                )),
                      hintStyle: DshType.s14.copyWith(color: c.labelCaption),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ),
            ),
            if (widget.config.enableVoice) ...<Widget>[
              const SizedBox(width: DshSpace.x6),
              Semantics(
                button: true,
                label: widget.isRecording
                    ? context.t('home.stopRecording', zh: '停止录音')
                    : context.t('home.voiceInput', zh: '按住说话'),
                child: GestureDetector(
                  // 长按 = 按住说话（按下开始、松开停止）；单击 = 切换，二者兼容。
                  onLongPressStart: _handleMicLongPressStart,
                  onLongPressEnd: _handleMicLongPressEnd,
                  behavior: HitTestBehavior.opaque,
                  child: DshIconButton(
                    icon: widget.isRecording
                        ? Icons.graphic_eq_rounded
                        : Icons.mic_none_rounded,
                    iconSize: 19,
                    size: 30,
                    tint: widget.isRecording ? c.link : c.labelSecondary,
                    onTap: _handleMicTap,
                    tooltip: context.t('home.voiceInput', zh: '按住说话'),
                  ),
                ),
              ),
            ],
            const SizedBox(width: DshSpace.x8),
            _sendButton(context, enabled: canSend, size: 40),
          ],
        );
      },
    );
  }

  /// 发送键统一语义：禁用态也明确告知“暂无可发送内容”。
  Widget _sendButton(
    BuildContext context, {
    required bool enabled,
    double size = 34,
  }) {
    final String label = enabled
        ? context.t('home.send', zh: '发送消息')
        : context.t('home.sendDisabled', zh: '发送消息（暂无可发送内容）');
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: DshSendButton(enabled: enabled, onSend: _handleSend, size: size),
    );
  }

  /// 设计稿底部功能行：加号 / 深度思考 / 智能搜索 / TGA 引擎（唯一模型入口）。
  Widget _buildFeatureRow(DshPalette c) {
    Widget pill({
      required String label,
      required IconData icon,
      required bool active,
      required VoidCallback onTap,
    }) {
      return Semantics(
        button: true,
        toggled: active,
        label: label,
        child: DshPressable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          haptic: true,
          child: AnimatedContainer(
            duration: DshMotion.reduced(context)
                ? Duration.zero
                : DshMotion.fast,
            curve: DshMotion.standard,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: active ? c.businessTertiary : c.inputMajor,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: active ? c.business.withValues(alpha: 0.36) : c.borderL3,
                width: 0.8,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  icon,
                  size: 13,
                  color: active ? c.business : c.labelSecondary,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: DshType.xxs12.copyWith(
                    fontSize: 11.5,
                    color: active ? c.business : c.labelSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      children: <Widget>[
        // “[+]” 添加附件
        Semantics(
          button: true,
          label: context.t('home.attach', zh: '添加附件'),
          child: Tooltip(
            message: context.t('home.attach', zh: '添加附件'),
            child: InkWell(
              onTap: _openAttachmentMenu,
              customBorder: const CircleBorder(),
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: c.selector,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(Icons.add_rounded, size: 18, color: c.labelPrimary),
              ),
            ),
          ),
        ),
        const SizedBox(width: DshSpace.x8),
        pill(
          label: context.t('home.deepThink', zh: '深度思考'),
          icon: Icons.psychology_outlined,
          active: _deepThink,
          onTap: _toggleDeepThink,
        ),
        const SizedBox(width: DshSpace.x8),
        pill(
          label: context.t('home.smartSearch', zh: '智能搜索'),
          icon: Icons.travel_explore_outlined,
          active: _smartSearch,
          onTap: _toggleSmartSearch,
        ),
        const Spacer(),
        _buildModelEntry(c),
      ],
    );
  }

  /// 底部模型按钮的标签（问题 #2a）：不再硬编码「TGA 引擎」，
  /// 联动 ModelRegistry 当前 selected 的真实名称；超过 8 个字符截断加省略号。
  /// 仅选中内置兜底引擎（builtin 且本地）时才显示「TGA 引擎」；
  /// 内置免费云端模型（如文心 ERNIE 5.5 Flash）显示其真实名称。
  String _modelEntryLabel(ModelEntry selected) {
    if (selected.builtin && selected.kind == ModelKind.local) {
      return context.t('home.engine', zh: 'TGA 引擎');
    }
    final String name = selected.name;
    return name.length > 8 ? '${name.substring(0, 8)}…' : name;
  }

  /// 模型切换的唯一入口：「TGA 引擎」下拉，点击打开真实模型选择器。
  /// 旧输入行里的模型 chip 已删除，避免两处入口互相打架。
  Widget _buildModelEntry(DshPalette c) {
    // 用 Builder 拿到子 context，把模型注册表的订阅限制在这棵小子树里。
    return Builder(
      builder: (BuildContext context) {
        final ModelEntry selected = context.watch<ModelRegistry>().selected;
        return Semantics(
          button: true,
          label: context.t(
            'home.switchModelSemantics',
            zh: '切换模型，快捷键 Ctrl 或 Command 加 M',
          ),
          child: Tooltip(
            message: context.t('home.switchModelTooltip', zh: '切换模型（Ctrl + M）'),
            child: InkWell(
              onTap: _openModelSelector,
              borderRadius: BorderRadius.circular(DshR.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: DshSpace.x4,
                  vertical: DshSpace.x4,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      _modelEntryLabel(selected),
                      style: DshType.xs13m.copyWith(color: c.labelPrimary),
                    ),
                    const SizedBox(width: DshSpace.x2),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: c.labelTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRecordingRow(DshPalette c) {
    return Semantics(
      liveRegion: true,
      label: widget.isTranscribing
          ? context.t('home.transcribing', zh: '识别中…')
          : context.t('home.recording', zh: '正在录音'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          DshSpace.x8,
          0,
          DshSpace.x8,
          DshSpace.x8,
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: widget.isTranscribing
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        DshSpinner(size: 14, color: c.labelTertiary),
                        const SizedBox(width: DshSpace.x8),
                        Text(
                          context.t('home.transcribing', zh: '识别中…'),
                          style: DshType.xs13.copyWith(color: c.labelTertiary),
                        ),
                      ],
                    )
                  : _InlineWaveform(
                      color: c.labelPrimary,
                      dim: c.labelCaption,
                      amplitude: widget.amplitude,
                    ),
            ),
            const SizedBox(width: DshSpace.x8),
            Semantics(
              button: true,
              label: context.t('home.stopRecording', zh: '停止录音'),
              child: DshIconButton(
                icon: Icons.stop_rounded,
                size: 28,
                iconSize: 16,
                tint: c.labelPrimary,
                background: c.selector,
                onTap: () => widget.onVoiceStop?.call(),
                tooltip: context.t('home.stopRecording', zh: '停止录音'),
              ),
            ),
            const SizedBox(width: DshSpace.x4),
            ValueListenableBuilder<bool>(
              valueListenable: _hasText,
              builder: (BuildContext ctx, bool hasText, Widget? _) =>
                  _sendButton(ctx, enabled: hasText),
            ),
          ],
        ),
      ),
    );
  }
}

/// 录音时的波形：最近 24 个真实麦克风声级样本画成的竖条 + 计时
/// （沿用 dsh 的克制风格）。声级样本来自录音链路的 VoiceAmplitude 事件，
/// 经 FlaiVoiceController.amplitude 回流；没有声级来源时只画固定基线并
/// 如实标注「振幅未接入」，绝不用随机波形冒充。
class _InlineWaveform extends StatefulWidget {
  const _InlineWaveform({
    required this.color,
    required this.dim,
    this.amplitude,
  });

  final Color color;
  final Color dim;
  final ValueListenable<double>? amplitude;

  @override
  State<_InlineWaveform> createState() => _InlineWaveformState();
}

class _InlineWaveformState extends State<_InlineWaveform> {
  static const int _maxSamples = 24;

  late final Timer _timerTick;
  int _elapsedSeconds = 0;

  /// 收到的真实声级样本（0.0 ~ 1.0），新样本追加在末尾，只留最近 24 个。
  /// 为空表示本次录音尚未收到任何声级样本（无声级来源，或全程静音）。
  List<double> _samples = const <double>[];

  @override
  void initState() {
    super.initState();
    widget.amplitude?.addListener(_onAmplitude);
    // 秒表每秒刷新一次（此前 AnimationController.repeat() 每帧驱动
    // AnimatedBuilder 纯空转的问题已在固定基线时期修掉）。
    _timerTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
    });
  }

  @override
  void didUpdateWidget(_InlineWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.amplitude != widget.amplitude) {
      oldWidget.amplitude?.removeListener(_onAmplitude);
      widget.amplitude?.addListener(_onAmplitude);
    }
  }

  void _onAmplitude() {
    if (!mounted) return;
    final double level = widget.amplitude?.value ?? 0.0;
    setState(() {
      final List<double> next = <double>[
        ..._samples,
        level.clamp(0.0, 1.0).toDouble(),
      ];
      _samples = next.length > _maxSamples
          ? next.sublist(next.length - _maxSamples)
          : next;
    });
  }

  @override
  void dispose() {
    _timerTick.cancel();
    widget.amplitude?.removeListener(_onAmplitude);
    super.dispose();
  }

  String get _formattedTime {
    final String m = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final String s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    // 只有收到真实声级样本后才去掉「振幅未接入」标注：标注的消失本身
    // 就是「振幅已接通」的证据；无样本时继续如实显示。
    final bool live = _samples.isNotEmpty;
    return Row(
      children: <Widget>[
        Expanded(
          child: SizedBox(
            height: 20,
            child: CustomPaint(
              painter: _WaveformPainter(
                color: live ? widget.color : widget.dim,
                samples: _samples,
              ),
            ),
          ),
        ),
        const SizedBox(width: DshSpace.x8),
        Text(
          live
              ? _formattedTime
              : '$_formattedTime · ${context.t('home.ampPending', zh: '振幅未接入')}',
          style: DshType.mono11.copyWith(color: widget.dim),
        ),
      ],
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.color, required this.samples});

  final Color color;

  /// 真实声级样本（0.0 ~ 1.0），按时间从左到右；为空时只画固定基线。
  final List<double> samples;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    if (samples.isEmpty) {
      // 真实麦克风声级尚未接入：只画一条固定的基线，界面上同时标注
      // 「振幅未接入」，绝不用 Random + sin 生成随机波形冒充录音数据。
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }
    // 每根竖条的高度就是该时刻的真实声级；条数不足 24 时靠右对齐，
    // 使最新样本始终贴着计时文本。
    const double gap = 3.0;
    final double barWidth = 2.0;
    final double step = barWidth + gap;
    final double totalWidth = samples.length * step - gap;
    double x = size.width - totalWidth;
    final double midY = size.height / 2;
    for (final double sample in samples) {
      final double half =
          (sample.clamp(0.0, 1.0) * midY).clamp(1.0, midY).toDouble();
      canvas.drawLine(
        Offset(x + barWidth / 2, midY - half),
        Offset(x + barWidth / 2, midY + half),
        paint,
      );
      x += step;
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.samples != samples;
}

/// 附件预览：60dp 缩略图 / 文件块，右上角减号。
class _AttachmentPreviewRow extends StatelessWidget {
  const _AttachmentPreviewRow({
    required this.attachments,
    required this.onRemove,
  });

  final List<PickedAttachment> attachments;
  final void Function(int index) onRemove;

  bool _isImage(PickedAttachment a) {
    final String mime = a.mimeType ?? '';
    return mime.startsWith('image/') ||
        a.name.endsWith('.jpg') ||
        a.name.endsWith('.jpeg') ||
        a.name.endsWith('.png') ||
        a.name.endsWith('.heic');
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return SizedBox(
      height: 76,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: DshSpace.x10,
          vertical: DshSpace.x4,
        ),
        itemCount: attachments.length,
        itemBuilder: (BuildContext context, int index) {
          final PickedAttachment a = attachments[index];
          return Padding(
            padding: const EdgeInsets.only(right: DshSpace.x8),
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Semantics(
                  label: '附件 ${a.name}',
                  child: Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: c.selector,
                      borderRadius: BorderRadius.circular(DshR.md),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: _isImage(a)
                        ? Image.file(File(a.path), fit: BoxFit.cover)
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              Icon(
                                Icons.attach_file_rounded,
                                size: 18,
                                color: c.labelSecondary,
                              ),
                              const SizedBox(height: 2),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: Text(
                                  a.name,
                                  style: DshType.xxxs11.copyWith(
                                    color: c.labelTertiary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                Positioned(
                  top: -2,
                  right: -2,
                  child: Semantics(
                    button: true,
                    label: '移除附件 ${a.name}',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onRemove(index),
                      child: Container(
                        // 放大到 22dp，兼顾可见性与手指命中。
                        width: 22,
                        height: 22,
                        decoration: const BoxDecoration(
                          color: Color(0x99000000),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
