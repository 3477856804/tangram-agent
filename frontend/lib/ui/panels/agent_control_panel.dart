/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/services/persona_store.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';
import 'package:tangram/ui/panels/autonomy_panel.dart';

/// 人格设置页：人格设定 / 对话参数 / 它的日记 / 主动 四个子分区。
/// 离线状态只在此页渲染一份统一组件，子分区不重复渲染状态块。
class AgentControlPanel extends StatefulWidget {
  const AgentControlPanel({super.key});

  @override
  State<AgentControlPanel> createState() => _AgentControlPanelState();
}

class _AgentControlPanelState extends State<AgentControlPanel>
    with AsyncPanelMixin {
  List<Map<String, dynamic>> _days = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _loadDiary();
  }

  Future<void> _loadDiary() => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env =
            await backend.sendControl('memory_event', {'action': 'diary'});
        final payload = env.payload;
        _days = <Map<String, dynamic>>[];
        if (payload is Map && payload['days'] is List) {
          for (final dynamic d in payload['days'] as List) {
            if (d is Map) {
              _days.add(
                d.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
              );
            }
          }
        }
      });

  Future<void> _deleteDay(String day) async {
    try {
      final backend = context.read<BackendClient>();
      await backend.sendControl('memory_event', {
        'action': 'delete_day',
        'day': day,
      });
    } on Object catch (e) {
      setError(e.toString());
      return;
    }
    await _loadDiary();
  }

  @override
  Widget build(BuildContext context) {
    return PanelPage(
      children: <Widget>[
        const SectionTitle(
          title: '人格设置',
          icon: Icons.psychology_outlined,
          accent: TangramColors.gold,
        ),
        buildStatusBlock(),
        const SizedBox(height: TangramSpacing.md),
        const _PersonaPromptSection(),
        const SizedBox(height: TangramSpacing.xl),
        const _ChatParamsSection(),
        const SizedBox(height: TangramSpacing.xl),
        _DiarySection(days: _days, onDelete: _deleteDay),
        const SizedBox(height: TangramSpacing.xl),
        const ProactiveSection(),
      ],
    );
  }
}

/// 人格设定：自定义系统提示词编辑区。
class _PersonaPromptSection extends StatefulWidget {
  const _PersonaPromptSection();

  @override
  State<_PersonaPromptSection> createState() => _PersonaPromptSectionState();
}

class _PersonaPromptSectionState extends State<_PersonaPromptSection> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: context.read<PersonaStore>().systemPrompt,
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PersonaStore persona = context.watch<PersonaStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionTitle(
          title: '人格设定',
          icon: Icons.edit_note_outlined,
        ),
        GlassCard(
          padding: const EdgeInsets.all(TangramSpacing.md),
          child: TextField(
            controller: _ctrl,
            minLines: 5,
            maxLines: 10,
            onChanged: persona.setSystemPrompt,
            decoration: const InputDecoration(
              hintText: '描述它的性格与说话方式，自动保存。',
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }
}

/// 对话参数：temperature / top_p / max_tokens，滑块 + 数字输入。
class _ChatParamsSection extends StatelessWidget {
  const _ChatParamsSection();

  @override
  Widget build(BuildContext context) {
    final PersonaStore persona = context.watch<PersonaStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionTitle(
          title: '对话参数',
          icon: Icons.tune_outlined,
          accent: TangramColors.jade,
        ),
        _ParamSlider(
          label: 'temperature',
          value: persona.temperature,
          min: 0,
          max: 2,
          divisions: 20,
          onChanged: persona.setTemperature,
        ),
        const SizedBox(height: TangramSpacing.sm),
        _ParamSlider(
          label: 'top_p',
          value: persona.topP,
          min: 0,
          max: 1,
          divisions: 20,
          onChanged: persona.setTopP,
        ),
        const SizedBox(height: TangramSpacing.sm),
        _ParamSlider(
          label: 'max_tokens',
          value: persona.maxTokens.toDouble(),
          min: 256,
          max: 8192,
          divisions: 31,
          integer: true,
          onChanged: (double v) => persona.setMaxTokens(v.round()),
        ),
      ],
    );
  }
}

class _ParamSlider extends StatefulWidget {
  const _ParamSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    this.integer = false,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final bool integer;

  @override
  State<_ParamSlider> createState() => _ParamSliderState();
}

class _ParamSliderState extends State<_ParamSlider> {
  late final TextEditingController _ctrl;

  String _format(double v) =>
      widget.integer ? v.round().toString() : v.toStringAsFixed(2);

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _format(widget.value));
  }

  @override
  void didUpdateWidget(_ParamSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String text = _format(widget.value);
    if (_ctrl.text != text) _ctrl.text = text;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final double? parsed = double.tryParse(raw.trim());
    if (parsed == null) {
      _ctrl.text = _format(widget.value);
      return;
    }
    widget.onChanged(parsed.clamp(widget.min, widget.max).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(TangramSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            widget.label,
            style: const TextStyle(
              color: TangramColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Slider(
                  value: widget.value.clamp(widget.min, widget.max).toDouble(),
                  min: widget.min,
                  max: widget.max,
                  divisions: widget.divisions,
                  onChanged: widget.onChanged,
                ),
              ),
              const SizedBox(width: TangramSpacing.sm),
              SizedBox(
                width: 84,
                child: TextField(
                  controller: _ctrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textAlign: TextAlign.center,
                  onSubmitted: _submit,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 它的日记：复用 Memory 记忆引擎，按天归档，仅查看 / 删除，不可编辑。
class _DiarySection extends StatelessWidget {
  const _DiarySection({required this.days, required this.onDelete});

  final List<Map<String, dynamic>> days;
  final void Function(String day) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SectionTitle(
          title: '它的日记',
          subtitle: '按天归档 · 只能看和删',
          icon: Icons.auto_stories_outlined,
          accent: TangramColors.jade,
          trailing: StatusPill(
            label: '${days.length} 天',
            color: TangramColors.jade,
            dense: true,
          ),
        ),
        if (days.isEmpty)
          const GlassCard(
            child: EmptyState(
              icon: Icons.auto_stories_outlined,
              title: '暂无日记',
              message: '沙箱未启动或暂无记录',
              compact: true,
            ),
          )
        else
          ...days.map(
            (Map<String, dynamic> d) {
              final String day = (d['day'] ?? '').toString();
              final List<dynamic> entries =
                  (d['entries'] is List) ? d['entries'] as List : <dynamic>[];
              return Padding(
                padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
                child: GlassCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: TangramSpacing.md,
                  ),
                  child: ExpansionTile(
                    title: Text(day),
                    subtitle: Text('${entries.length} 条记忆'),
                    trailing: IconButton(
                      tooltip: '删除这一天',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => onDelete(day),
                    ),
                    children: entries.map((dynamic e) {
                      final Map<String, dynamic> item = e is Map
                          ? e.map((dynamic k, dynamic v) =>
                              MapEntry(k.toString(), v))
                          : <String, dynamic>{};
                      return ListTile(
                        dense: true,
                        title: Text(
                          (item['text'] ?? '').toString(),
                          style: const TextStyle(fontSize: 12),
                        ),
                        subtitle: Text((item['role'] ?? '').toString()),
                      );
                    }).toList(),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
