import 'package:flutter/material.dart';

import '../../design/dsh_tokens.dart';
import '../../services/presence_store.dart';

/// 在场状态入口：顶栏模式按钮的图标随模式变化。
IconData presenceModeIcon(PresenceMode mode) {
  switch (mode) {
    case PresenceMode.focus:
      return Icons.center_focus_strong_rounded;
    case PresenceMode.chat:
      return Icons.chat_bubble_outline_rounded;
    case PresenceMode.quiet:
      return Icons.bedtime_outlined;
  }
}

/// 打开「在场」底部弹窗：模式、情绪 / 能量、打断任务恢复、最近交互与遗忘。
///
/// 弹窗直接持有 [PresenceStore]，所有操作真实写回并落盘；
/// 通过 ListenableBuilder 订阅 store 刷新，不依赖 Provider 是否已注入。
Future<void> showPresenceSheet(BuildContext context, PresenceStore store) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: DshPalette.of(context).bgLayer1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(DshR.panel)),
    ),
    builder: (BuildContext ctx) => _PresenceSheetBody(store: store),
  );
}

class _PresenceSheetBody extends StatelessWidget {
  const _PresenceSheetBody({required this.store});

  final PresenceStore store;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext ctx, Widget? _) {
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.86,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                DshSpace.x20,
                DshSpace.x12,
                DshSpace.x20,
                DshSpace.x24,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _header(ctx, c),
                  const SizedBox(height: DshSpace.x16),
                  _sectionLabel('场景模式', c),
                  const SizedBox(height: DshSpace.x8),
                  _modeChips(c),
                  const SizedBox(height: DshSpace.x8),
                  Text(
                    '${store.mode.strategy}；主动打扰：${_proactiveLabel()}',
                    style: DshType.xs13.copyWith(color: c.labelSecondary),
                  ),
                  const SizedBox(height: DshSpace.x20),
                  _sectionLabel('情绪与能量', c),
                  const SizedBox(height: DshSpace.x8),
                  _moodChips(c),
                  const SizedBox(height: DshSpace.x10),
                  _EnergyControl(store: store, palette: c),
                  const SizedBox(height: DshSpace.x4),
                  Text(
                    '情绪判断来自最近消息的关键词、标点与长度，只是交互风格提示，不是心理诊断。',
                    style: DshType.xxs12.copyWith(color: c.labelCaption),
                  ),
                  const SizedBox(height: DshSpace.x20),
                  _sectionLabel('被打断的任务', c),
                  const SizedBox(height: DshSpace.x8),
                  _interruptedCard(c),
                  const SizedBox(height: DshSpace.x20),
                  _sectionLabel('最近交互（最多 5 条）', c),
                  const SizedBox(height: DshSpace.x8),
                  _recentList(c),
                  const SizedBox(height: DshSpace.x20),
                  _sectionLabel('合理遗忘', c),
                  const SizedBox(height: DshSpace.x8),
                  _forgetRow(c),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, DshPalette c) {
    return Row(
      children: <Widget>[
        Icon(presenceModeIcon(store.mode), size: 20, color: c.labelPrimary),
        const SizedBox(width: DshSpace.x8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('在场状态', style: DshType.l20.copyWith(color: c.labelPrimary)),
              Text(
                '场景感知 · 情绪连贯 · 保存在本机',
                style: DshType.xxs12.copyWith(color: c.labelCaption),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: Icon(Icons.close_rounded, color: c.labelSecondary),
          tooltip: '关闭',
        ),
      ],
    );
  }

  Widget _sectionLabel(String text, DshPalette c) {
    return Text(
      text,
      style: DshType.xs13m.copyWith(color: c.labelSecondary),
    );
  }

  Widget _modeChips(DshPalette c) {
    return Wrap(
      spacing: DshSpace.x8,
      runSpacing: DshSpace.x8,
      children: <Widget>[
        for (final PresenceMode m in PresenceMode.values)
          ChoiceChip(
            avatar: Icon(
              presenceModeIcon(m),
              size: 16,
              color: store.mode == m ? c.labelOnPrimary : c.labelSecondary,
            ),
            label: Text(m.label),
            selected: store.mode == m,
            showCheckmark: false,
            selectedColor: c.brandPrimary,
            backgroundColor: c.bgLayer2,
            labelStyle: DshType.xs13m.copyWith(
              color: store.mode == m ? c.labelOnPrimary : c.labelPrimary,
            ),
            side: BorderSide(color: c.borderL4, width: dshHairline),
            onSelected: (bool _) => store.setMode(m),
          ),
      ],
    );
  }

  Widget _moodChips(DshPalette c) {
    return Wrap(
      spacing: DshSpace.x8,
      runSpacing: DshSpace.x8,
      children: <Widget>[
        for (final Mood m in Mood.values)
          ChoiceChip(
            label: Text(m.label),
            selected: store.mood == m,
            showCheckmark: false,
            selectedColor: c.business,
            backgroundColor: c.bgLayer2,
            labelStyle: DshType.xs13m.copyWith(
              color: store.mood == m ? c.labelOnPrimary : c.labelPrimary,
            ),
            side: BorderSide(color: c.borderL4, width: dshHairline),
            onSelected: (bool _) => store.setMood(m),
          ),
      ],
    );
  }

  Widget _interruptedCard(DshPalette c) {
    final String? task = store.interruptedTask;
    if (task == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(DshSpace.x12),
        decoration: dshFlat(c, radius: DshR.md, fill: c.bgLayer2),
        child: Text(
          '没有被打断的任务。',
          style: DshType.xs13.copyWith(color: c.labelTertiary),
        ),
      );
    }
    final DateTime? paused = store.pausedAt;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(DshSpace.x12),
      decoration: dshFlat(c, radius: DshR.md, fill: c.bgLayer2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(task, style: DshType.s14.copyWith(color: c.labelPrimary)),
          if (paused != null) ...<Widget>[
            const SizedBox(height: DshSpace.x4),
            Text(
              '暂停于 ${_formatTime(paused)}',
              style: DshType.xxs12.copyWith(color: c.labelCaption),
            ),
          ],
          const SizedBox(height: DshSpace.x8),
          Row(
            children: <Widget>[
              FilledButton.icon(
                onPressed: store.resumeTask,
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('恢复任务'),
              ),
              const SizedBox(width: DshSpace.x8),
              TextButton(
                onPressed: store.clearInterrupted,
                child: const Text('清除'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recentList(DshPalette c) {
    final List<RecentInteraction> items =
        store.recentInteractions.reversed.take(5).toList(growable: false);
    if (items.isEmpty) {
      return Text(
        '还没有记录：发一条消息后，这里会显示真实摘要。',
        style: DshType.xs13.copyWith(color: c.labelTertiary),
      );
    }
    return Column(
      children: <Widget>[
        for (final RecentInteraction r in items) ...<Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: DshSpace.x6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: DshSpace.x6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: c.bgLayer3,
                    borderRadius: DshR.brXs,
                  ),
                  child: Text(
                    Mood.parse(r.tone).label,
                    style: DshType.xxxs11.copyWith(color: c.labelSecondary),
                  ),
                ),
                const SizedBox(width: DshSpace.x8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        r.text,
                        style: DshType.xs13.copyWith(color: c.labelPrimary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _formatTime(r.ts),
                        style: DshType.xxxs11.copyWith(color: c.labelCaption),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => store.isPinned(r.text)
                      ? store.unpin(r.text)
                      : store.pin(r.text),
                  visualDensity: VisualDensity.compact,
                  tooltip: store.isPinned(r.text) ? '取消保留' : '保留（遗忘时跳过）',
                  icon: Icon(
                    store.isPinned(r.text)
                        ? Icons.push_pin
                        : Icons.push_pin_outlined,
                    size: 16,
                    color: store.isPinned(r.text)
                        ? c.brandPrimary
                        : c.labelCaption,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: dshHairline, color: c.borderL2),
        ],
      ],
    );
  }

  Widget _forgetRow(DshPalette c) {
    final DateTime? cutoff = store.forgetBefore;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: DshSpace.x8,
          runSpacing: DshSpace.x8,
          children: <Widget>[
            OutlinedButton(
              onPressed: () => store.forgetOlderThan(7),
              child: const Text('遗忘 7 天前'),
            ),
            OutlinedButton(
              onPressed: () => store.forgetOlderThan(30),
              child: const Text('遗忘 30 天前'),
            ),
          ],
        ),
        const SizedBox(height: DshSpace.x6),
        Text(
          cutoff == null
              ? '已保留 ${store.pinned.length} 条固定记录；固定内容不会被遗忘。'
              : '上次遗忘界线：${_formatTime(cutoff)}；已保留 ${store.pinned.length} 条固定记录。',
          style: DshType.xxs12.copyWith(color: c.labelCaption),
        ),
      ],
    );
  }

  String _proactiveLabel() {
    if (store.mode == PresenceMode.quiet) return '关闭';
    if (store.mode == PresenceMode.focus) {
      return store.shouldProactivelySpeak ? '仅高优先级' : '暂不主动';
    }
    return '允许';
  }

  static String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 能量滑杆：拖动时只更新本地值，松手才真实写回 store，避免每帧落盘。
class _EnergyControl extends StatefulWidget {
  const _EnergyControl({required this.store, required this.palette});

  final PresenceStore store;
  final DshPalette palette;

  @override
  State<_EnergyControl> createState() => _EnergyControlState();
}

class _EnergyControlState extends State<_EnergyControl> {
  double _value = 0.6;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _value = widget.store.energy;
  }

  @override
  void didUpdateWidget(covariant _EnergyControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging) _value = widget.store.energy;
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = widget.palette;
    return Row(
      children: <Widget>[
        Text('能量', style: DshType.xs13.copyWith(color: c.labelSecondary)),
        Expanded(
          child: Slider(
            value: _value.clamp(0, 1).toDouble(),
            divisions: 20,
            label: '${(_value * 100).round()}%',
            onChangeStart: (double v) {
              _dragging = true;
              setState(() => _value = v);
            },
            onChanged: (double v) => setState(() => _value = v),
            onChangeEnd: (double v) {
              _dragging = false;
              widget.store.setEnergy(v);
            },
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            '${(_value * 100).round()}%',
            textAlign: TextAlign.end,
            style: DshType.xs13m.copyWith(color: c.labelPrimary),
          ),
        ),
      ],
    );
  }
}
