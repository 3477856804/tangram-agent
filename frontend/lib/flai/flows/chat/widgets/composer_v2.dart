import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../design/dsh_tokens.dart';
import '../../../../design/dsh_widgets.dart';
import '../../../../services/model_registry.dart';
import '../../../../services/persona_store.dart';
import '../../../../ui/i18n/tga_strings.dart';
import '../chat_experience_config.dart';
import 'attachment_menu.dart';
import 'attachment_picker.dart';
import 'model_selector_sheet.dart';

/// 发送回调：文本 + 「深度思考 / 智能搜索」两个胶囊的真实开关状态。
/// 标志沿 onSend → HomeController.sendMessage → ChatRequest →
/// TangramAiProvider._payload 一路透传进后端 chat payload。
typedef FlaiSendHandler = void Function(
  String text,
  bool thinking,
  bool search,
);

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
  });

  @override
  State<FlaiComposerV2> createState() => _FlaiComposerV2State();
}

class _FlaiComposerV2State extends State<FlaiComposerV2> {
  final TextEditingController _textController = TextEditingController();
  final List<PickedAttachment> _pendingAttachments = <PickedAttachment>[];
  bool _hasText = false;

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
      if (has != _hasText) {
        setState(() => _hasText = has);
      }
    });
  }

  @override
  void didUpdateWidget(FlaiComposerV2 oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.voiceTranscript != null &&
        widget.voiceTranscript != oldWidget.voiceTranscript &&
        widget.voiceTranscript!.isNotEmpty) {
      _textController.text = widget.voiceTranscript!;
      setState(() => _hasText = true);
    }
  }

  @override
  void dispose() {
    _textController.dispose();
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
      final String size =
          a.sizeBytes == null ? '大小未知' : _humanSize(a.sizeBytes!);
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
    '.txt', '.md', '.json', '.yaml', '.yml', '.csv', '.log',
    '.dart', '.py', '.js', '.ts', '.xml', '.html', '.css',
    '.sh', '.toml', '.ini', '.conf',
  };

  String? _readTextAttachment(PickedAttachment a) {
    final String lower = a.name.toLowerCase();
    final bool isText = a.mimeType?.startsWith('text/') == true ||
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
    );
  }

  /// 把真实注册表转换成选择器选项：带（本地）/（云端）标记、分组、来源副标题。
  /// 分组标题走 i18n 词典，随语言即时切换。
  List<ModelOption> _optionsOf(BuildContext context, ModelRegistry r) =>
      r.entries.map((ModelEntry e) {
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
      }).toList(growable: false);

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

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final bool canSend = _hasText || _pendingAttachments.isNotEmpty;

    // 监听模型注册表与选择变化，模型入口即时刷新（新增/下载后立即生效）。
    context.watch<PersonaStore>();
    context.watch<ModelRegistry>();
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
        child: Container(
          decoration: BoxDecoration(
            color: c.inputMajor,
            borderRadius: BorderRadius.circular(DshComposerSpec.radius),
            border: Border.all(
              color: c.borderL1,
              width: DshComposerSpec.borderWidth,
            ),
            boxShadow: dshSoftShadow(
              blur: DshComposerSpec.shadowBlur,
              lift: DshComposerSpec.shadowLift,
              alpha: DshComposerSpec.shadowAlpha,
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
              if (widget.isRecording || widget.isTranscribing)
                _buildRecordingRow(c)
              else ...<Widget>[
                _buildEditorRow(c, canSend),
                const SizedBox(height: DshSpace.x10),
                _buildFeatureRow(c),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 编辑器行：浅灰圆角输入框 + 发送键。
  Widget _buildEditorRow(DshPalette c, bool canSend) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: ConstrainedBox(
            constraints:
                const BoxConstraints(minHeight: DshComposerSpec.editorMinHeight),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: DshSpace.x12,
                vertical: DshSpace.x8,
              ),
              decoration: BoxDecoration(
                color: c.bgModule,
                borderRadius: BorderRadius.circular(DshR.md),
              ),
              child: TextField(
                controller: _textController,
                maxLines: 8,
                minLines: 1,
                onSubmitted: (_) => _handleSend(),
                textInputAction: TextInputAction.send,
                cursorColor: c.business,
                cursorWidth: 1.5,
                style: DshType.s14.copyWith(color: c.labelPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: widget.isRecording
                      ? context.t('home.listening', zh: '正在听…')
                      : context.t('home.inputHint',
                          zh: widget.config.resolvedPlaceholder),
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
        if (widget.config.enableVoice && !_hasText) ...<Widget>[
          const SizedBox(width: DshSpace.x6),
          DshIconButton(
            icon: Icons.mic_none_rounded,
            iconSize: 18,
            size: 28,
            tint: c.labelSecondary,
            onTap: _handleMicTap,
            tooltip: context.t('home.voiceInput', zh: '语音输入'),
          ),
        ],
        const SizedBox(width: DshSpace.x8),
        DshSendButton(
          enabled: canSend,
          onSend: _handleSend,
          size: 40,
        ),
      ],
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
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? c.businessTertiary : c.inputMajor,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active
                  ? c.business.withValues(alpha: 0.30)
                  : c.borderL3,
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon,
                  size: 13,
                  color: active ? c.business : c.labelSecondary),
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
      );
    }

    return Row(
      children: <Widget>[
        // “[+]” 添加附件
        Tooltip(
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
    final ModelEntry selected = context.watch<ModelRegistry>().selected;
    return Semantics(
      button: true,
      label: context.t('home.switchModelSemantics',
          zh: '切换模型，快捷键 Ctrl 或 Command 加 M'),
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
                Icon(Icons.expand_more_rounded,
                    size: 16, color: c.labelTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecordingRow(DshPalette c) {
    return Padding(
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
                : _InlineWaveform(color: c.labelPrimary, dim: c.labelCaption),
          ),
          const SizedBox(width: DshSpace.x8),
          DshIconButton(
            icon: Icons.stop_rounded,
            size: 28,
            iconSize: 16,
            tint: c.labelPrimary,
            background: c.selector,
            onTap: () => widget.onVoiceStop?.call(),
            tooltip: context.t('home.stopRecording', zh: '停止录音'),
          ),
          const SizedBox(width: DshSpace.x4),
          DshSendButton(enabled: _hasText, onSend: _handleSend),
        ],
      ),
    );
  }
}

/// 录音时的波形：24 根随相位起伏的竖条 + 计时（沿用 dsh 的克制风格）。
class _InlineWaveform extends StatefulWidget {
  const _InlineWaveform({required this.color, required this.dim});

  final Color color;
  final Color dim;

  @override
  State<_InlineWaveform> createState() => _InlineWaveformState();
}

class _InlineWaveformState extends State<_InlineWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Timer _timerTick;
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _timerTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    _timerTick.cancel();
    super.dispose();
  }

  String get _formattedTime {
    final String m = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final String s = (_elapsedSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: SizedBox(
            height: 20,
            child: AnimatedBuilder(
              animation: _animController,
              builder: (BuildContext context, Widget? _) {
                return CustomPaint(
                  painter: _WaveformPainter(color: widget.dim),
                );
              },
            ),
          ),
        ),
        const SizedBox(width: DshSpace.x8),
        Text(
          '$_formattedTime · ${context.t('home.ampPending', zh: '振幅未接入')}',
          style: DshType.mono11.copyWith(color: widget.dim),
        ),
      ],
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // 真实麦克风 PCM 振幅尚未接入。这里不再用 Random + sin 生成随机波形
    // 冒充录音数据，只画一条固定的基线，界面上同时标注「振幅未接入」。
    final Paint base = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(0, size.height / 2),
      Offset(size.width, size.height / 2),
      base,
    );
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) => false;
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
      height: 72,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: DshSpace.x10,
          vertical: DshSpace.x2,
        ),
        itemCount: attachments.length,
        itemBuilder: (BuildContext context, int index) {
          final PickedAttachment a = attachments[index];
          return Padding(
            padding: const EdgeInsets.only(right: DshSpace.x8),
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Container(
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
                Positioned(
                  top: -4,
                  right: -4,
                  child: GestureDetector(
                    onTap: () => onRemove(index),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: const Color(0x99000000),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 11,
                        color: Colors.white,
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
