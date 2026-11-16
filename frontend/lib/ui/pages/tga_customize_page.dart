import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/tga_design.dart';
import '../../harness/store.dart';
import '../../harness/ui_customization.dart';

/// 全栈 UI 自定义页：主题 / 布局配置 + 实时预览 + 导入导出。
///
/// 本页只产生配置数据（持久化到 ui_customization.json），不直接改
/// MaterialApp，也不覆盖现有 Tga 色板；集成方读取 `apply(scope)` 自行消费。
class TgaCustomizePage extends StatefulWidget {
  const TgaCustomizePage({super.key, this.customization});

  /// 允许集成方注入已加载的仓库；为空时页面自行从 [HarnessStore] 加载。
  final UiCustomizationStore? customization;

  @override
  State<TgaCustomizePage> createState() => _TgaCustomizePageState();
}

class _TgaCustomizePageState extends State<TgaCustomizePage> {
  UiCustomizationStore? _store;
  bool _loading = true;
  String _loadError = '';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _store?.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _bootstrap() async {
    if (widget.customization != null) {
      _store = widget.customization;
      _store!.addListener(_onStoreChanged);
      setState(() {
        _loading = false;
        _loadError = _store!.loadError;
      });
      return;
    }
    try {
      final HarnessStore harness = await HarnessStore.instance();
      final UiCustomizationStore store =
          await UiCustomizationStore.load(harness);
      if (!mounted) return;
      store.addListener(_onStoreChanged);
      setState(() {
        _store = store;
        _loading = false;
        _loadError = store.loadError;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '加载 UI 配置失败：$e';
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _save() async {
    final UiCustomizationStore? store = _store;
    if (store == null || _saving) return;
    setState(() => _saving = true);
    try {
      final bool ok = await store.save();
      if (!mounted) return;
      _snack(ok ? '已保存 ui_customization.json（${store.scope.label}）' : '保存失败：${store.lastError}');
    } on Object catch (e) {
      if (mounted) _snack('写盘失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _export() async {
    final UiCustomizationStore? store = _store;
    if (store == null) return;
    final String json = store.exportJson();
    final TextEditingController ctrl = TextEditingController(text: json);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return AlertDialog(
          backgroundColor: Tga.card,
          title: const Text('导出 UI 配置'),
          content: SizedBox(
            width: 540,
            height: 360,
            child: TextField(
              controller: ctrl,
              readOnly: true,
              maxLines: null,
              expands: true,
              style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  color: Tga.text,
                  height: 1.5),
              decoration: InputDecoration(
                filled: true,
                fillColor: Tga.bgSoft,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: json));
                Navigator.pop(ctx);
                _snack('已复制 UI 配置 JSON');
              },
              child: const Text('复制'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        );
      },
    );
    ctrl.dispose();
  }

  Future<void> _import() async {
    final UiCustomizationStore? store = _store;
    if (store == null) return;
    final TextEditingController ctrl = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return AlertDialog(
          backgroundColor: Tga.card,
          title: const Text('导入 UI 配置'),
          content: SizedBox(
            width: 540,
            height: 360,
            child: TextField(
              controller: ctrl,
              maxLines: null,
              expands: true,
              style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  color: Tga.text,
                  height: 1.5),
              decoration: InputDecoration(
                hintText: '粘贴 ui_customization.json 内容…',
                hintStyle: TextStyle(fontSize: 13, color: Tga.textDim),
                filled: true,
                fillColor: Tga.bgSoft,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('导入'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (text == null || !mounted) return;
    final Map<String, dynamic> result = await store.importJson(text);
    if (!mounted) return;
    _snack(result['ok'] == true
        ? '已导入并落盘（${result['scope']}）'
        : '导入失败：${result['error']}');
  }

  // ---------------------------------------------------------------- 构建

  Color _accentColor(UiAccentPreset preset) => switch (preset) {
        UiAccentPreset.blue => const Color(0xFF4A90D9),
        UiAccentPreset.cyan => const Color(0xFF2FB3AE),
        UiAccentPreset.purple => const Color(0xFF9068E8),
        UiAccentPreset.gold => const Color(0xFFE8A83A),
        UiAccentPreset.green => const Color(0xFF2FAE74),
      };

  Widget _previewCard(UiCustomizationConfig config) {
    final bool dark = config.surfacePreset == UiSurfacePreset.midnight ||
        (config.surfacePreset == UiSurfacePreset.auto &&
            Theme.of(context).brightness == Brightness.dark);
    final Color bg =
        dark ? const Color(0xFF141618) : const Color(0xFFF7F9F7);
    final Color card = dark ? const Color(0xFF212B36) : Colors.white;
    final Color text = dark ? const Color(0xFFE2E8F0) : const Color(0xFF111111);
    final Color sub = dark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final Color accent = _accentColor(config.accentPreset);
    final double gap = config.density == UiDensity.compact
        ? 6
        : config.density == UiDensity.spacious
            ? 14
            : 10;
    final double fs = config.fontScale;
    final List<String> labels = config.visibleNavKeys
        .map((String k) => UiCustomizationConfig.navLabels[k] ?? k)
        .take(5)
        .toList();
    final Widget composer = Container(
      width: config.composerFloating ? 220 : double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: gap),
      decoration: BoxDecoration(
        color: card,
        borderRadius: BorderRadius.circular(config.radius.clamp(4, 24).toDouble()),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.add_circle_outline_rounded, size: 16 * fs, color: accent),
          SizedBox(width: gap),
          Expanded(
            child: Text('向檀阁瑞木发消息…',
                style: TextStyle(fontSize: 12 * fs, color: sub)),
          ),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            child: Icon(Icons.arrow_upward_rounded,
                size: 12 * fs, color: Colors.white),
          ),
        ],
      ),
    );
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(16 * fs.clamp(0.85, 1.2).toDouble()),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(config.radius),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 26 * fs,
                height: 26 * fs,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(config.radius / 2),
                ),
                child: Icon(Icons.auto_awesome_rounded,
                    size: 15 * fs, color: accent),
              ),
              SizedBox(width: gap),
              Text('实时预览 · 檀阁瑞木',
                  style: TextStyle(
                      fontSize: 15 * fs,
                      fontWeight: FontWeight.w700,
                      color: text)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                    config.sidebarGrouping ? '分组导航' : '平铺导航',
                    style: TextStyle(
                        fontSize: 10 * fs,
                        fontWeight: FontWeight.w600,
                        color: accent)),
              ),
            ],
          ),
          SizedBox(height: gap),
          Text('可见导航 ${config.visibleNavKeys.length} 项',
              style: TextStyle(fontSize: 11.5 * fs, color: sub)),
          SizedBox(height: gap * 0.6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String label in labels)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: card,
                    borderRadius: BorderRadius.circular(config.radius / 2),
                    border: Border.all(color: accent.withValues(alpha: 0.25)),
                  ),
                  child: Text(label,
                      style: TextStyle(fontSize: 10.5 * fs, color: text)),
                ),
            ],
          ),
          SizedBox(height: gap * 1.2),
          if (config.composerFloating)
            Align(alignment: Alignment.centerRight, child: composer)
          else
            composer,
        ],
      ),
    );
  }

  Widget _accentPicker(UiCustomizationConfig config) {
    return Wrap(
      spacing: 12,
      runSpacing: 10,
      children: <Widget>[
        for (final UiAccentPreset preset in UiAccentPreset.values)
          GestureDetector(
            onTap: () => _store?.setAccent(preset),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: config.accentPreset == preset
                    ? _accentColor(preset).withValues(alpha: 0.12)
                    : Tga.card,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: config.accentPreset == preset
                      ? _accentColor(preset)
                      : Tga.border,
                  width: config.accentPreset == preset ? 1.6 : 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: _accentColor(preset),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Text(preset.label,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: config.accentPreset == preset
                              ? _accentColor(preset)
                              : Tga.textSub)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _navKeyWrap(UiCustomizationConfig config) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final String key in UiCustomizationConfig.knownNavKeys)
          GestureDetector(
            onTap: () => _store?.toggleNavKey(key),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: config.visibleNavKeys.contains(key)
                    ? Tga.primary.withValues(alpha: 0.12)
                    : Tga.bgSoft,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: config.visibleNavKeys.contains(key)
                      ? Tga.primary
                      : Tga.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    config.visibleNavKeys.contains(key)
                        ? Icons.check_circle_outline_rounded
                        : Icons.circle_outlined,
                    size: 13,
                    color: config.visibleNavKeys.contains(key)
                        ? Tga.primary
                        : Tga.textDim,
                  ),
                  const SizedBox(width: 5),
                  Text(UiCustomizationConfig.navLabels[key] ?? key,
                      style: TextStyle(
                          fontSize: 12,
                          color: config.visibleNavKeys.contains(key)
                              ? Tga.primary
                              : Tga.textSub)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _slider({
    required String label,
    required String valueLabel,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(label, style: Tga.body),
            const Spacer(),
            TgaTag(valueLabel, color: Tga.primary),
          ],
        ),
        Slider(
          value: value.clamp(min, max).toDouble(),
          min: min,
          max: max,
          divisions: divisions,
          label: valueLabel,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _switchRow(String title, String subtitle, bool value, ValueChanged<bool> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: Tga.body),
                Text(subtitle, style: Tga.caption),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final UiCustomizationStore? store = _store;
    if (_loading || store == null) {
      return TgaPage(
        title: '界面自定义',
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    final UiCustomizationConfig config = store.config;
    return TgaPage(
      title: '界面自定义',
      actions: <Widget>[
        IconButton(
          tooltip: '保存配置',
          onPressed: _saving ? null : _save,
          icon: Icon(Icons.save_outlined, color: Tga.textSub),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
        children: <Widget>[
          if (_loadError.isNotEmpty)
            TgaCard(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, size: 16, color: Tga.red),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_loadError, style: Tga.sub)),
                ],
              ),
            ),
          TgaGroupTitle(
            '作用域',
            trailing: Text('project 未保存时回退 global',
                style: Tga.caption),
          ),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TgaSegmented<UiScope>(
                  items: UiScope.values,
                  value: store.scope,
                  labelOf: (UiScope s) => s.label,
                  onChanged: store.setScope,
                ),
                const SizedBox(height: 8),
                Text(
                  store.scope == UiScope.project
                      ? '当前编辑项目级覆盖；保存后 apply(project) 返回它。'
                      : '当前编辑全局配置；apply(global) 始终返回它。',
                  style: Tga.caption,
                ),
              ],
            ),
          ),
          TgaGroupTitle(
            '实时预览',
            trailing: TgaTag('主题包 v${config.themePackVersion}',
                color: Tga.textSub),
          ),
          TgaCard(child: _previewCard(config)),
          TgaGroupTitle('主色预设'),
          TgaCard(child: _accentPicker(config)),
          TgaGroupTitle('表面预设'),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TgaSegmented<UiSurfacePreset>(
                  items: UiSurfacePreset.values,
                  value: config.surfacePreset,
                  labelOf: (UiSurfacePreset s) => s.label,
                  onChanged: store.setSurface,
                ),
                if (config.surfacePreset == UiSurfacePreset.auto) ...<Widget>[
                  const SizedBox(height: 8),
                  Text('自动：跟随系统明暗，仅作配置，不直接改 MaterialApp。',
                      style: Tga.caption),
                ],
              ],
            ),
          ),
          TgaGroupTitle('排版与圆角'),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _slider(
                  label: '字体缩放',
                  valueLabel: '${(config.fontScale * 100).round()}%',
                  value: config.fontScale,
                  min: UiCustomizationConfig.minFontScale,
                  max: UiCustomizationConfig.maxFontScale,
                  divisions: 11,
                  onChanged: store.setFontScale,
                ),
                const SizedBox(height: 4),
                _slider(
                  label: '圆角',
                  valueLabel: config.radius.toStringAsFixed(0),
                  value: config.radius,
                  min: UiCustomizationConfig.minRadius,
                  max: UiCustomizationConfig.maxRadius,
                  divisions: 20,
                  onChanged: store.setRadius,
                ),
                const SizedBox(height: 8),
                Text('信息密度', style: Tga.body),
                const SizedBox(height: 8),
                TgaSegmented<UiDensity>(
                  items: UiDensity.values,
                  value: config.density,
                  labelOf: (UiDensity d) => d.label,
                  onChanged: store.setDensity,
                ),
              ],
            ),
          ),
          TgaGroupTitle('布局'),
          TgaCard(
            child: Column(
              children: <Widget>[
                _switchRow(
                  '侧栏分组',
                  '按类别分组展示导航项（配置项，由侧栏消费）',
                  config.sidebarGrouping,
                  store.setSidebarGrouping,
                ),
                Divider(height: 14, color: Tga.divider),
                _switchRow(
                  '悬浮输入框',
                  '输入框浮动在内容右下角，而不是贴底',
                  config.composerFloating,
                  store.setComposerFloating,
                ),
              ],
            ),
          ),
          TgaGroupTitle(
            '可见导航项',
            trailing: Text('${config.visibleNavKeys.length} / '
                '${UiCustomizationConfig.knownNavKeys.length}',
                style: Tga.caption),
          ),
          TgaCard(child: _navKeyWrap(config)),
          if (store.lastError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Row(
                children: <Widget>[
                  Icon(Icons.error_outline_rounded, size: 14, color: Tga.red),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(store.lastError,
                          style: TextStyle(fontSize: 12, color: Tga.red))),
                ],
              ),
            ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              TgaButton(
                  label: _saving ? '保存中…' : '保存',
                  onTap: _saving ? () {} : _save),
              const SizedBox(width: 10),
              TgaButton(
                  label: '导出 JSON',
                  filled: false,
                  color: Tga.textSub,
                  onTap: _export),
              const SizedBox(width: 10),
              TgaButton(
                  label: '导入 JSON',
                  filled: false,
                  color: Tga.textSub,
                  onTap: _import),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '保存路径：${store.store.file(UiCustomizationStore.fileName).path}',
            style: Tga.caption,
          ),
        ],
      ),
    );
  }
}
