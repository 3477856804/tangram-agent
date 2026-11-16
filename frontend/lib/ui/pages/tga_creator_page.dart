import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/creator_runtime.dart';
import '../../harness/store.dart';

/// Creator 创造模式（声明式插件包）。
///
/// 左/上：本地 catalog 插件列表（真实 `plugins/creator/*.json`）。
/// 中：monospace manifest 编辑器。右：真实校验结果与运行结果。
/// 底部工具条：校验 / 保存 / 激活 / 停用 / 运行测试 / 删除 / 导出 / 导入。
///
/// 不做动态编译：manifest 只描述 prompt / http / shell 动作，运行由
/// [CreatorRuntime] 解释执行。需要 prompt 或 shell 时，集成方构造
/// `CreatorRuntime(HarnessStore.instance(), kernel: ..., chat: ..., shell: ...)`
/// 后注入本页；未注入时页面会如实提示"运行会失败"，不会假成功。
class TgaCreatorPage extends StatefulWidget {
  const TgaCreatorPage({super.key, this.runtime});

  final CreatorRuntime? runtime;

  @override
  State<TgaCreatorPage> createState() => _TgaCreatorPageState();
}

class _TgaCreatorPageState extends State<TgaCreatorPage> {
  CreatorRuntime? _runtime;
  bool _loading = true;
  bool _busy = false;
  String _loadError = '';

  List<Map<String, dynamic>> _plugins = <Map<String, dynamic>>[];
  String _selectedId = '';
  CreatorValidation? _validation;
  Map<String, dynamic>? _runResult;

  final TextEditingController _editor = TextEditingController();
  final TextEditingController _actionCtrl = TextEditingController();
  final TextEditingController _argsCtrl = TextEditingController(text: '{}');

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _editor.dispose();
    _actionCtrl.dispose();
    _argsCtrl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      if (widget.runtime != null) {
        _runtime = widget.runtime;
      } else {
        final BackendClient client = context.read<BackendClient>();
        final HarnessStore store = await HarnessStore.instance();
        _runtime = client.embeddedBackend != null
            ? await client.embeddedBackend!.createCreatorRuntime()
            : CreatorRuntime(store);
      }
      await _refresh();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _busy = false;
        _loadError = '初始化 Creator 运行时失败：$e';
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Map<String, dynamic>? _selectedPlugin() {
    for (final Map<String, dynamic> p in _plugins) {
      if (p['id'] == _selectedId) return p;
    }
    return null;
  }

  Future<void> _refresh({String? selectId}) async {
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null) return;
    setState(() => _busy = true);
    final List<Map<String, dynamic>> plugins = await runtime.list();
    if (!mounted) return;
    String selection = selectId ?? _selectedId;
    if (selection.isEmpty ||
        !plugins.any((Map<String, dynamic> p) => p['id'] == selection)) {
      selection =
          plugins.isEmpty ? '' : (plugins.first['id'] ?? '').toString();
    }
    final bool selectionChanged = selection != _selectedId;
    setState(() {
      _plugins = plugins;
      _selectedId = selection;
      _loading = false;
      _busy = false;
      _loadError = runtime.loadError;
    });
    if (selection.isNotEmpty && (selectionChanged || _editor.text.isEmpty)) {
      _loadIntoEditor(selection);
    }
  }

  void _loadIntoEditor(String id) {
    for (final Map<String, dynamic> p in _plugins) {
      if (p['id'] != id) continue;
      final Map<String, dynamic> manifest = <String, dynamic>{
        'id': p['id'],
        'name': p['name'],
        'version': p['version'],
        'description': p['description'],
        'permissions': p['permissions'],
        'dependencies': p['dependencies'],
        'actions': p['actions'],
      };
      _editor.text = const JsonEncoder.withIndent('  ').convert(manifest);
      final List<dynamic> actions =
          p['actions'] is List ? p['actions'] as List : <dynamic>[];
      _actionCtrl.text = actions.isEmpty
          ? ''
          : ((actions.first as Map)['id'] ?? '').toString();
      return;
    }
  }

  void _select(String id) {
    if (id == _selectedId && _editor.text.trim().isNotEmpty) return;
    setState(() {
      _selectedId = id;
      _validation = null;
      _runResult = null;
    });
    _loadIntoEditor(id);
  }

  void _validate() {
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null) return;
    setState(() => _validation = runtime.validate(_editor.text));
  }

  Future<void> _save() async {
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null || _busy) return;
    setState(() => _busy = true);
    final Map<String, dynamic> result = await runtime.save(_editor.text);
    if (!mounted) return;
    setState(() {
      _validation = runtime.validate(_editor.text);
      _busy = false;
    });
    if (result['ok'] == true) {
      final Object? reactivateError = result['reactivate_error'];
      _snack(reactivateError == null
          ? '已保存到 ${result['path']}'
          : '已保存，但旧版本重新激活失败：$reactivateError');
      await _refresh(selectId: (result['id'] ?? '').toString());
    } else {
      _snack('保存失败：${result['error']}');
    }
  }

  Future<void> _activate() async {
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null || _selectedId.isEmpty || _busy) return;
    setState(() => _busy = true);
    final Map<String, dynamic> result = await runtime.activate(_selectedId);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(result['ok'] == true
        ? '已激活「$_selectedId」，注册 ${(result['tools'] as List?)?.length ?? 0} 个动作'
        : '激活失败：${result['error']}');
    await _refresh();
  }

  Future<void> _deactivate() async {
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null || _selectedId.isEmpty || _busy) return;
    setState(() => _busy = true);
    final Map<String, dynamic> result = await runtime.deactivate(_selectedId);
    if (!mounted) return;
    setState(() => _busy = false);
    _snack(result['ok'] == true
        ? '已停用「$_selectedId」'
        : '停用失败：${result['error']}');
    await _refresh();
  }

  Future<void> _run() async {
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null || _busy) return;
    final String actionId = _actionCtrl.text.trim();
    if (actionId.isEmpty) {
      _snack('请先填写要运行的动作 id');
      return;
    }
    Map<String, dynamic> args = <String, dynamic>{};
    final String rawArgs = _argsCtrl.text.trim();
    if (rawArgs.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(rawArgs);
        if (decoded is! Map) {
          _snack('参数必须是 JSON 对象，如 {"name":"Ada"}');
          return;
        }
        args = decoded.map(
            (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v));
      } on Object catch (e) {
        _snack('参数 JSON 解析失败：$e');
        return;
      }
    }
    setState(() => _busy = true);
    final Map<String, dynamic> result = await runtime.run(
      actionId,
      args,
      _selectedId.isEmpty ? null : _selectedId,
    );
    if (!mounted) return;
    setState(() {
      _runResult = result;
      _busy = false;
    });
  }

  Future<void> _delete() async {
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null || _selectedId.isEmpty || _busy) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('删除插件「$_selectedId」？'),
        content: const Text('将真实删除 plugins/creator 下的 manifest 文件，操作不可恢复。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final Map<String, dynamic> result = await runtime.delete(_selectedId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result['ok'] == true) {
        _selectedId = '';
        _editor.clear();
        _validation = null;
        _runResult = null;
      }
    });
    _snack(result['ok'] == true
        ? '已删除「${result['id']}」'
        : '删除失败：${result['error']}');
    await _refresh();
  }

  Future<void> _export() async {
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null || _selectedId.isEmpty) {
      _snack('请先选择一个已保存的插件');
      return;
    }
    final Map<String, dynamic> result = await runtime.exportJson(_selectedId);
    if (!mounted) return;
    if (result['ok'] != true) {
      _snack('导出失败：${result['error']}');
      return;
    }
    final String json = (result['json'] ?? '').toString();
    final TextEditingController ctrl = TextEditingController(text: json);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return AlertDialog(
          backgroundColor: Tga.card,
          title: Text('导出「$_selectedId」'),
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
                _snack('已复制 manifest JSON 到剪贴板');
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
    final CreatorRuntime? runtime = _runtime;
    if (runtime == null) return;
    final TextEditingController ctrl = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return AlertDialog(
          backgroundColor: Tga.card,
          title: const Text('导入插件 manifest'),
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
                hintText: '粘贴 JSON manifest…',
                hintStyle: TextStyle(color: Tga.textDim, fontSize: 13),
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
    final Map<String, dynamic> result = await runtime.importJson(text);
    if (!mounted) return;
    if (result['ok'] == true) {
      _snack('已导入「${result['id']}」并落盘');
      _editor.text = text;
      await _refresh(selectId: (result['id'] ?? '').toString());
    } else {
      _snack('导入失败：${result['error']}');
    }
  }

  // ---------------------------------------------------------------- 构建

  Widget _pluginListPane() {
    return TgaCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Row(
              children: <Widget>[
                Text('本地 catalog', style: Tga.body),
                const Spacer(),
                TgaTag('${_plugins.length}', color: Tga.textSub),
              ],
            ),
          ),
          if (_plugins.isEmpty)
            const TgaEmpty('还没有 Creator 插件，先用「导入」或编辑 JSON 保存',
                icon: Icons.extension_outlined)
          else
            for (final Map<String, dynamic> p in _plugins)
              _pluginRow(p),
        ],
      ),
    );
  }

  Widget _pluginRow(Map<String, dynamic> p) {
    final String id = (p['id'] ?? '').toString();
    final bool selected = id == _selectedId;
    final bool active = p['active'] == true;
    final bool kernelRegistered = p['registered_to_kernel'] == true;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _select(id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          color: selected ? Tga.primary.withValues(alpha: 0.08) : null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                active
                    ? Icons.play_circle_outline_rounded
                    : Icons.extension_outlined,
                size: 19,
                color: active ? Tga.green : Tga.textDim,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text((p['name'] ?? id).toString(), style: Tga.body),
                    const SizedBox(height: 2),
                    Text(
                      '$id · v${p['version']} · ${(p['actions'] as List?)?.length ?? 0} 动作',
                      style: Tga.caption,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: <Widget>[
                        if (active)
                          TgaTag(
                            kernelRegistered ? '已激活 · 已注册内核' : '已激活',
                            color: Tga.green,
                          ),
                        if ((p['permissions'] as List?)?.isNotEmpty == true)
                          TgaTag(
                            (p['permissions'] as List)
                                .map((dynamic e) => e.toString())
                                .join('/'),
                            color: Tga.textSub,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editorPane() {
    final Map<String, dynamic>? current = _selectedPlugin();
    final bool active = current?['active'] == true;
    return TgaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(_selectedId.isEmpty ? '新建 / 导入插件' : _selectedId,
                        style: Tga.h2),
                    const SizedBox(height: 2),
                    Text('声明式 manifest（不动态编译 Dart）', style: Tga.caption),
                  ],
                ),
              ),
              if (active) TgaTag('运行中', color: Tga.green),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 360,
            child: Container(
              decoration: BoxDecoration(
                color: Tga.bgSoft,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Tga.border),
              ),
              child: TextField(
                controller: _editor,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                    color: Tga.text,
                    height: 1.5),
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.all(12),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              TgaButton(
                  label: '校验',
                  filled: false,
                  onTap: _busy ? () {} : _validate),
              TgaButton(
                  label: _busy ? '保存中…' : '保存',
                  onTap: _busy ? () {} : _save),
              TgaButton(
                  label: '激活',
                  color: Tga.green,
                  onTap: _busy ? () {} : _activate),
              TgaButton(
                  label: '停用',
                  filled: false,
                  color: Tga.orange,
                  onTap: _busy ? () {} : _deactivate),
              TgaButton(
                  label: '删除',
                  filled: false,
                  color: Tga.red,
                  onTap: _busy ? () {} : _delete),
              TgaButton(
                  label: '导出',
                  filled: false,
                  color: Tga.textSub,
                  onTap: _busy ? () {} : _export),
              TgaButton(
                  label: '导入',
                  filled: false,
                  color: Tga.textSub,
                  onTap: _busy ? () {} : _import),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              SizedBox(
                width: 150,
                child: _smallField(_actionCtrl, '动作 id'),
              ),
              const SizedBox(width: 8),
              Expanded(child: _smallField(_argsCtrl, '参数 JSON，如 {"name":"Ada"}')),
              const SizedBox(width: 8),
              TgaButton(
                  label: _busy ? '运行中…' : '运行测试',
                  color: Tga.purple,
                  onTap: _busy ? () {} : _run),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _runtime?.hasChat == true && _runtime?.hasShell == true
                ? '已注入 chat 与 shell 回调，prompt / shell 动作可真实执行。'
                : '未注入 chat 或 shell 回调：对应动作运行时会如实失败；'
                    'HTTP 动作受 host allowlist 限制（默认拒绝）。',
            style: Tga.caption,
          ),
        ],
      ),
    );
  }

  Widget _smallField(TextEditingController controller, String hint) {
    return TextField(
      controller: controller,
      style: TextStyle(fontSize: 12.5, color: Tga.text),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 12, color: Tga.textDim),
        filled: true,
        fillColor: Tga.bgSoft,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: Tga.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: Tga.border),
        ),
      ),
    );
  }

  Widget _resultPane() {
    final CreatorValidation? validation = _validation;
    final Map<String, dynamic>? runResult = _runResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TgaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('校验结果', style: Tga.h2),
              const SizedBox(height: 8),
              if (validation == null)
                Text('尚未校验。点击「校验」展示真实 errors / warnings。',
                    style: Tga.sub)
              else ...<Widget>[
                Row(
                  children: <Widget>[
                    TgaTag(validation.ok ? '通过' : '未通过',
                        color: validation.ok ? Tga.green : Tga.red),
                    const SizedBox(width: 8),
                    Text(
                        '${validation.errors.length} errors · '
                        '${validation.warnings.length} warnings',
                        style: Tga.caption),
                  ],
                ),
                if (validation.errors.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  for (final String e in validation.errors)
                    _issueRow(Icons.error_outline_rounded, Tga.red, e),
                ],
                if (validation.warnings.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  for (final String w in validation.warnings)
                    _issueRow(Icons.warning_amber_rounded, Tga.gold, w),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        TgaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text('运行结果', style: Tga.h2),
                  const Spacer(),
                  if (runResult != null)
                    TgaTag(runResult['ok'] == true ? '成功' : '失败',
                        color:
                            runResult['ok'] == true ? Tga.green : Tga.red),
                ],
              ),
              const SizedBox(height: 8),
              if (runResult == null)
                Text('运行测试后这里展示真实返回或错误，不放假成功。',
                    style: Tga.sub)
              else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Tga.bgSoft,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: SelectableText(
                    const JsonEncoder.withIndent('  ').convert(runResult),
                    style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: Tga.text,
                        height: 1.45),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _issueRow(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 12, color: color, height: 1.4))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      body = LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool wide = constraints.maxWidth >= 980;
          final List<Widget> panes = <Widget>[
            _pluginListPane(),
            _editorPane(),
            _resultPane(),
          ];
          if (wide) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(width: 250, child: panes[0]),
                  const SizedBox(width: 12),
                  Expanded(flex: 3, child: panes[1]),
                  const SizedBox(width: 12),
                  SizedBox(width: 310, child: panes[2]),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
            children: <Widget>[
              panes[0],
              const SizedBox(height: 12),
              panes[1],
              const SizedBox(height: 12),
              panes[2],
            ],
          );
        },
      );
    }
    return TgaPage(
      title: '创造模式',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新 catalog',
          onPressed: _busy || _loading ? null : () => _refresh(),
          icon: Icon(Icons.refresh_rounded, color: Tga.textSub),
        ),
      ],
      child: Column(
        children: <Widget>[
          if (_loadError.isNotEmpty)
            Container(
              width: double.infinity,
              color: Tga.red.withValues(alpha: 0.08),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, size: 15, color: Tga.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_loadError,
                        style: TextStyle(fontSize: 12, color: Tga.red)),
                  ),
                ],
              ),
            ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
