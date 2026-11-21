import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// Team Computer：共享工作区 + 每个智能体独立浏览器 profile。
///
/// 页面上的每个动作都走 `computer` 控制域并真实落盘：
///   * 浏览器为真实 HTTP 请求（Cookie / 历史持久化），不执行 JavaScript；
///   * 文件读写限制在电脑 home 内，支持共享目录与智能体目录；
///   * 检查点是真实目录副本 + SHA256 清单，恢复前自动备份；
///   * 活动日志按电脑展示，不伪造成功状态。
class TgaComputerPage extends StatefulWidget {
  const TgaComputerPage({super.key});

  @override
  State<TgaComputerPage> createState() => _TgaComputerPageState();
}

class _TgaComputerPageState extends State<TgaComputerPage> {
  List<Map<String, dynamic>> _computers = <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('computer', <String, dynamic>{
      'action': action,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await _call('list');
      if (!mounted) return;
      setState(() {
        _computers = (r['computers'] is List ? r['computers'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  Future<void> _create() async {
    final TextEditingController name = TextEditingController();
    bool private = false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('新建电脑', style: Tga.h2),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: name,
                autofocus: true,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '电脑名称'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeTrackColor: Tga.primary,
                value: private,
                title: Text('独立电脑', style: Tga.body),
                subtitle: Text('默认共享 Team Computer；独立电脑不共享文件与登录态', style: Tga.caption),
                onChanged: (bool v) => setLocal(() => private = v),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    final String n = name.text.trim();
    name.dispose();
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('create', <String, dynamic>{
      'name': n,
      'kind': private ? 'private' : 'team',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '创建失败'}');
      return;
    }
    await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 3),
      ));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '团队电脑',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _create,
          tooltip: '新建电脑',
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Tga.primary,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Text(
                    '每台电脑有真实共享工作区与每个智能体独立的浏览器 profile。\n'
                    '浏览器为 HTTP 模式：真实请求、Cookie 与历史持久化，但不执行 JavaScript。',
                    style: Tga.sub,
                  ),
                ),
                TgaGroupTitle('电脑（${_computers.length}）'),
                if (_computers.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有电脑\n点右上角 + 新建',
                      icon: Icons.desktop_windows_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> c in _computers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (BuildContext _) => _ComputerDetailPage(
                                computer: c,
                              ),
                            ),
                          );
                          await _load();
                        },
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: Tga.iconBlueBg,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                Icons.desktop_windows_rounded,
                                size: 19,
                                color: Tga.iconBlue,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('${c['name']}', style: Tga.h2),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${c['kind'] == 'private' ? '独立' : '共享'} · '
                                    '${c['bot_count']} 个智能体 · ${c['file_count']} 个文件 · '
                                    '${_bytes(c['bytes'])}',
                                    style: Tga.caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right_rounded, color: Tga.textDim),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}

String _bytes(dynamic value) {
  final int n = value is num ? value.toInt() : 0;
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _ComputerDetailPage extends StatefulWidget {
  const _ComputerDetailPage({required this.computer});

  final Map<String, dynamic> computer;

  @override
  State<_ComputerDetailPage> createState() => _ComputerDetailPageState();
}

class _ComputerDetailPageState extends State<_ComputerDetailPage> {
  late Map<String, dynamic> _computer;
  late final TextEditingController _url;
  List<Map<String, dynamic>> _bots = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _files = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _activity = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _checkpoints = <Map<String, dynamic>>[];
  String _selectedBot = '';
  String _section = 'browser';
  bool _scopeAll = true;
  bool _loading = true;
  Map<String, dynamic>? _browser;

  @override
  void initState() {
    super.initState();
    _computer = widget.computer;
    _url = TextEditingController();
    _loadAll();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  String get _id => '${_computer['id']}';

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('computer', <String, dynamic>{
      'action': action,
      'computer_id': _id,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _loadAll() async {
    final Map<String, dynamic> bots = await _call('bots');
    if (!mounted) return;
    final List<Map<String, dynamic>> list =
        (bots['bots'] is List ? bots['bots'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
    String selected = _selectedBot;
    if (selected.isEmpty || !list.any((Map<String, dynamic> b) => '${b['id']}' == selected)) {
      selected = list.isEmpty ? '' : '${list.first['id']}';
    }
    setState(() {
      _bots = list;
      _selectedBot = selected;
      _computer = bots['computer'] is Map
          ? Map<String, dynamic>.from(bots['computer'] as Map)
          : _computer;
    });
    await Future.wait(<Future<void>>[
      _loadFiles(),
      _loadActivity(),
      _loadCheckpoints(),
    ]);
    if (selected.isNotEmpty) await _loadState();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadFiles() async {
    final Map<String, dynamic> r = await _call('files', <String, dynamic>{
      'bot_id': _scopeAll ? '' : _selectedBot,
    });
    if (!mounted) return;
    setState(() {
      _files = (r['files'] is List ? r['files'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
    });
  }

  Future<void> _loadActivity() async {
    final Map<String, dynamic> r = await _call('activity', <String, dynamic>{
      'limit': 80,
    });
    if (!mounted) return;
    setState(() {
      _activity = (r['activity'] is List ? r['activity'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
    });
  }

  Future<void> _loadCheckpoints() async {
    final Map<String, dynamic> r = await _call('checkpoints');
    if (!mounted) return;
    setState(() {
      _checkpoints =
          (r['checkpoints'] is List ? r['checkpoints'] as List : <dynamic>[])
              .whereType<Map>()
              .map((Map e) => Map<String, dynamic>.from(e))
              .toList();
    });
  }

  Future<void> _loadState() async {
    if (_selectedBot.isEmpty) return;
    final Map<String, dynamic> r = await _call('state', <String, dynamic>{
      'bot_id': _selectedBot,
    });
    if (!mounted) return;
    setState(() => _browser = r);
    final String url = (r['url'] ?? '').toString();
    if (url.isNotEmpty) _url.text = url;
  }

  Future<void> _selectBot(String id) async {
    setState(() => _selectedBot = id);
    await _loadState();
    await _loadActivity();
  }

  Future<void> _addBot() async {
    final TextEditingController name = TextEditingController();
    bool private = false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('添加智能体', style: Tga.h2),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: name,
                autofocus: true,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '智能体名称'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeTrackColor: Tga.primary,
                value: private,
                title: Text('使用独立电脑', style: Tga.body),
                subtitle: Text('开启后文件与登录态不与其他智能体共享', style: Tga.caption),
                onChanged: (bool v) => setLocal(() => private = v),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    final String n = name.text.trim();
    name.dispose();
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('add_bot', <String, dynamic>{
      'name': n,
      'private': private,
      'computer_id': _id,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '添加失败'}');
      return;
    }
    await _loadAll();
    _toast('${r['note'] ?? '已添加'}');
  }

  Future<void> _removeBot() async {
    if (_selectedBot.isEmpty) return;
    final String name = _bots
        .where((Map<String, dynamic> b) => '${b['id']}' == _selectedBot)
        .map((Map<String, dynamic> b) => '${b['name']}')
        .firstWhere((String _) => true, orElse: () => _selectedBot);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('删除智能体「$name」？', style: Tga.h2),
        content: Text('会删除它的工作区目录与浏览器 profile（Cookie / 历史）。', style: Tga.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Tga.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('remove_bot', <String, dynamic>{
      'bot_id': _selectedBot,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '删除失败'}');
      return;
    }
    setState(() {
      _selectedBot = '';
      _browser = null;
    });
    await _loadAll();
  }

  Future<void> _navigate() async {
    final String url = _url.text.trim();
    if (_selectedBot.isEmpty) {
      _toast('请先添加一个智能体');
      return;
    }
    if (url.isEmpty) return;
    final Map<String, dynamic> r = await _call('navigate', <String, dynamic>{
      'bot_id': _selectedBot,
      'url': url,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '打开失败'}');
      return;
    }
    setState(() => _browser = r);
    final String finalUrl = '${r['url'] ?? ''}';
    if (finalUrl.isNotEmpty) _url.text = finalUrl;
    await _loadActivity();
  }

  Future<void> _act(String action, {String ref = '', String value = ''}) async {
    if (_selectedBot.isEmpty) return;
    final Map<String, dynamic> r = await _call('act', <String, dynamic>{
      'bot_id': _selectedBot,
      'action': action,
      'ref': ref,
      'value': value,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '操作失败'}');
      return;
    }
    if (r['snapshot'] != null || action == 'fill') {
      final Map<String, dynamic> state =
          await _call('state', <String, dynamic>{'bot_id': _selectedBot});
      if (mounted && state['ok'] == true) setState(() => _browser = state);
    }
    await _loadActivity();
  }

  Future<void> _submitForm(Map<String, dynamic> form) async {
    final List<Map<String, dynamic>> fields =
        (form['fields'] is List ? form['fields'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
    final Map<String, TextEditingController> controllers =
        <String, TextEditingController>{};
    for (final Map<String, dynamic> f in fields) {
      controllers['${f['ref']}'] =
          TextEditingController(text: '${f['value'] ?? ''}');
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('填写表单 ${form['ref']}', style: Tga.h2),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (final Map<String, dynamic> f in fields)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: controllers['${f['ref']}'],
                      obscureText: '${f['type']}' == 'password',
                      style: TextStyle(color: Tga.text),
                      decoration: InputDecoration(
                        labelText:
                            '${f['label'] ?? f['name'] ?? f['ref']}（${f['type']}）',
                      ),
                    ),
                  ),
                Text('提交会发起真实 HTTP 请求；密码不会写入活动日志。', style: Tga.caption),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    final Map<String, String> values = <String, String>{};
    controllers.forEach((String ref, TextEditingController c) {
      values[ref] = c.text;
      c.dispose();
    });
    if (ok != true || !mounted) return;
    final Map<String, dynamic> r = await _call('act', <String, dynamic>{
      'bot_id': _selectedBot,
      'action': 'submit',
      'ref': '${form['ref']}',
      'values': values,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '提交失败'}');
      return;
    }
    await _loadState();
    await _loadActivity();
  }

  Future<void> _clearBrowser() async {
    if (_selectedBot.isEmpty) return;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('清除浏览器数据？', style: Tga.h2),
        content: Text('会删除该智能体的 Cookie 与历史记录，不影响工作区文件。', style: Tga.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('clear_browser', <String, dynamic>{
      'bot_id': _selectedBot,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '清除失败'}');
      return;
    }
    setState(() => _browser = null);
    _url.clear();
    await _loadActivity();
  }

  Future<void> _newFile() async {
    final TextEditingController path = TextEditingController(text: 'notes.md');
    final TextEditingController text = TextEditingController();
    bool shared = false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('新建 / 覆盖文件', style: Tga.h2),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: path,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '相对路径，如 docs/plan.md'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: text,
                  minLines: 5,
                  maxLines: 10,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(hintText: '文件内容（UTF-8 文本）'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: Tga.primary,
                  value: shared,
                  title: Text('写入共享目录 shared/', style: Tga.body),
                  subtitle: Text('关闭则写入当前智能体目录 bots/<id>/', style: Tga.caption),
                  onChanged: (bool v) => setLocal(() => shared = v),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub)),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final String p = path.text.trim();
    final String t = text.text;
    path.dispose();
    text.dispose();
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('write', <String, dynamic>{
      'bot_id': shared || _selectedBot.isEmpty ? '' : _selectedBot,
      'path': shared ? 'shared/$p' : p,
      'text': t,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '写入失败'}');
      return;
    }
    await _loadFiles();
    await _loadActivity();
  }

  Future<void> _openFile(Map<String, dynamic> f) async {
    final Map<String, dynamic> r = await _call('read', <String, dynamic>{
      'path': '${f['path']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '读取失败'}');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('${f['path']}', style: Tga.h2),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText('${r['text']}', style: Tga.body),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('关闭', style: TextStyle(color: Tga.textSub)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteFile(Map<String, dynamic> f) async {
    final Map<String, dynamic> r = await _call('delete_file', <String, dynamic>{
      'path': '${f['path']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '删除失败'}');
      return;
    }
    await _loadFiles();
    await _loadActivity();
  }

  Future<void> _checkpoint() async {
    final TextEditingController note = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('创建检查点', style: Tga.h2),
        content: TextField(
          controller: note,
          autofocus: true,
          style: TextStyle(color: Tga.text),
          decoration: const InputDecoration(hintText: '备注（可选）'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    final String n = note.text.trim();
    note.dispose();
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('checkpoint', <String, dynamic>{
      'note': n,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '创建失败'}');
      return;
    }
    final Map<dynamic, dynamic>? cp =
        r['checkpoint'] is Map ? r['checkpoint'] as Map : null;
    _toast(cp == null
        ? '已创建检查点'
        : '已创建 ${cp['rev']}（${cp['entries']} 个文件）');
    await _loadCheckpoints();
    await _loadActivity();
  }

  Future<void> _restore(Map<String, dynamic> cp) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('恢复 ${cp['rev']}？', style: Tga.h2),
        content: Text('当前工作区会先自动备份，再恢复到该检查点。', style: Tga.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('restore', <String, dynamic>{
      'rev': '${cp['rev']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '恢复失败'}');
      return;
    }
    _toast('${r['note'] ?? '已恢复'}');
    await _loadAll();
  }

  Future<void> _deleteCheckpoint(Map<String, dynamic> cp) async {
    final Map<String, dynamic> r =
        await _call('delete_checkpoint', <String, dynamic>{'rev': '${cp['rev']}'});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '删除失败'}');
      return;
    }
    await _loadCheckpoints();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 3),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? snap = _browser?['snapshot'] is Map
        ? Map<String, dynamic>.from(_browser!['snapshot'] as Map)
        : null;
    return TgaPage(
      title: '${_computer['name']}',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _loadAll,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _selectedBot.isEmpty ? null : _removeBot,
          tooltip: '删除当前智能体',
          icon: Icon(Icons.person_remove_outlined, color: Tga.red),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Tga.primary,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.desktop_windows_outlined, size: 18, color: Tga.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${_computer['kind'] == 'private' ? '独立电脑' : '共享 Team Computer'}'
                          ' · ${_bots.length} 个智能体 · '
                          '检查点 ${_computer['last_checkpoint_rev'] ?? '无'}',
                          style: Tga.sub,
                        ),
                      ),
                    ],
                  ),
                ),
                TgaGroupTitle(
                  '智能体',
                  trailing: TextButton(
                    onPressed: _addBot,
                    child: Text('+ 添加', style: TextStyle(color: Tga.primary, fontSize: 12)),
                  ),
                ),
                if (_bots.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有智能体\n添加后即可使用浏览器与工作区',
                      icon: Icons.smart_toy_outlined,
                    ),
                  )
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        for (final Map<String, dynamic> b in _bots)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _chip(
                              '${b['name']}',
                              selected: '${b['id']}' == _selectedBot,
                              onTap: () => _selectBot('${b['id']}'),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                _sectionChips(),
                const SizedBox(height: 12),
                if (_section == 'browser') _buildBrowser(snap),
                if (_section == 'files') _buildFiles(),
                if (_section == 'checkpoints') _buildCheckpoints(),
                if (_section == 'activity') _buildActivity(),
              ],
            ),
    );
  }

  Widget _chip(String label, {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Tga.primary : Tga.bgSoft,
          borderRadius: BorderRadius.circular(Tga.rChip),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected ? Tga.onPrimary : Tga.text,
          ),
        ),
      ),
    );
  }

  Widget _sectionChips() {
    const List<(String, String)> sections = <(String, String)>[
      ('browser', '浏览器'),
      ('files', '工作区'),
      ('checkpoints', '检查点'),
      ('activity', '活动'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final (String key, String label) in sections)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _chip(
                label,
                selected: _section == key,
                onTap: () => setState(() => _section = key),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBrowser(Map<String, dynamic>? snap) {
    final String display = '${_browser?['display'] ?? ''}';
    final List<dynamic> links =
        snap != null && snap['links'] is List ? snap['links'] as List : <dynamic>[];
    final List<dynamic> forms =
        snap != null && snap['forms'] is List ? snap['forms'] as List : <dynamic>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TgaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextField(
                controller: _url,
                style: TextStyle(color: Tga.text),
                decoration: InputDecoration(
                  hintText: 'https://example.com',
                  suffixIcon: IconButton(
                    onPressed: _navigate,
                    icon: Icon(Icons.arrow_forward_rounded, color: Tga.primary),
                  ),
                ),
                onSubmitted: (String _) => _navigate(),
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  IconButton(
                    onPressed: (_browser?['can_back'] == true)
                        ? () => _act('back')
                        : null,
                    icon: Icon(Icons.chevron_left_rounded, color: Tga.textSub),
                    tooltip: '后退',
                  ),
                  IconButton(
                    onPressed: (_browser?['can_forward'] == true)
                        ? () => _act('forward')
                        : null,
                    icon: Icon(Icons.chevron_right_rounded, color: Tga.textSub),
                    tooltip: '前进',
                  ),
                  IconButton(
                    onPressed: _browser == null ? null : () => _act('reload'),
                    icon: Icon(Icons.refresh_rounded, color: Tga.textSub),
                    tooltip: '刷新',
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _selectedBot.isEmpty ? null : _clearBrowser,
                    child: Text('清除登录态', style: TextStyle(color: Tga.red, fontSize: 12)),
                  ),
                ],
              ),
              Text(
                _selectedBot.isEmpty
                    ? '先添加一个智能体。'
                    : 'HTTP 模式：真实请求与 Cookie，不执行 JavaScript；单页上限 4MB。',
                style: Tga.caption,
              ),
            ],
          ),
        ),
        if (display.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TgaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${snap?['title'] ?? ''}',
                    style: Tga.h2,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_browser?['url'] ?? ''} · HTTP ${_browser?['status'] ?? ''}',
                    style: Tga.caption,
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    '${snap?['text'] ?? ''}',
                    style: Tga.body,
                    maxLines: 14,
                  ),
                ],
              ),
            ),
          ),
        if (links.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TgaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('链接', style: Tga.h2),
                  const SizedBox(height: 4),
                  for (final dynamic raw in links)
                    if (raw is Map)
                      InkWell(
                        onTap: () => _act('click', ref: '${raw['ref']}'),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '[${raw['ref']}] ${raw['text']}',
                            style: TextStyle(color: Tga.primary, fontSize: 13),
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ),
        if (forms.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: TgaCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('表单', style: Tga.h2),
                  const SizedBox(height: 4),
                  for (final dynamic raw in forms)
                    if (raw is Map)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                '[${raw['ref']}] ${raw['method']} ${raw['action']}',
                                style: Tga.body,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  _submitForm(Map<String, dynamic>.from(raw)),
                              child: Text('填写并提交',
                                  style: TextStyle(color: Tga.primary, fontSize: 12)),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ),
        if (display.isEmpty && _selectedBot.isNotEmpty)
          TgaCard(
            child: TgaEmpty(
              '还没有打开网页\n在上面输入地址后回车',
              icon: Icons.public_rounded,
            ),
          ),
      ],
    );
  }

  Widget _buildFiles() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            _chip(
              '全部工作区',
              selected: _scopeAll,
              onTap: () async {
                setState(() => _scopeAll = true);
                await _loadFiles();
              },
            ),
            const SizedBox(width: 8),
            _chip(
              '当前智能体',
              selected: !_scopeAll,
              onTap: () async {
                setState(() => _scopeAll = false);
                await _loadFiles();
              },
            ),
            const Spacer(),
            TextButton(
              onPressed: _newFile,
              child: Text('+ 新建文件',
                  style: TextStyle(color: Tga.primary, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (_files.isEmpty)
          TgaCard(child: TgaEmpty('工作区里还没有文件', icon: Icons.folder_open_outlined))
        else
          for (final Map<String, dynamic> f in _files)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TgaCard(
                onTap: () => _openFile(f),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.insert_drive_file_outlined, size: 17, color: Tga.textSub),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${f['path']}', style: Tga.body)),
                    Text('${f['size']} B', style: Tga.caption),
                    IconButton(
                      icon: Icon(Icons.delete_outline_rounded, size: 17, color: Tga.red),
                      onPressed: () => _deleteFile(f),
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 8),
        Text('shared/ 为共享目录；bots/<id>/ 为各智能体目录。路径越界会被拒绝。',
            style: Tga.caption),
      ],
    );
  }

  Widget _buildCheckpoints() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TgaCard(
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '检查点包含工作区文件与浏览器登录态（SHA256 清单）。'
                  '恢复前会自动备份当前工作区。',
                  style: Tga.sub,
                ),
              ),
              TextButton(
                onPressed: _checkpoint,
                child: Text('创建', style: TextStyle(color: Tga.primary, fontSize: 12)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (_checkpoints.isEmpty)
          TgaCard(child: TgaEmpty('还没有检查点', icon: Icons.restore_rounded))
        else
          for (final Map<String, dynamic> cp in _checkpoints)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TgaCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.history_rounded, size: 17, color: Tga.textSub),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('${cp['rev']}', style: Tga.body),
                          Text(
                            '${cp['entries']} 个文件 · ${_bytes(cp['total_bytes'])}'
                            '${'${cp['note'] ?? ''}'.isEmpty ? '' : ' · ${cp['note']}'}',
                            style: Tga.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => _restore(cp),
                      child: Text('恢复',
                          style: TextStyle(color: Tga.primary, fontSize: 12)),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline_rounded, size: 17, color: Tga.red),
                      onPressed: () => _deleteCheckpoint(cp),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  Widget _buildActivity() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text('最近 ${_activity.length} 条真实动作', style: Tga.sub),
            const Spacer(),
            TextButton(
              onPressed: _loadActivity,
              child: Text('刷新', style: TextStyle(color: Tga.primary, fontSize: 12)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_activity.isEmpty)
          TgaCard(child: TgaEmpty('还没有动作记录', icon: Icons.history_toggle_off_rounded))
        else
          for (final Map<String, dynamic> a in _activity)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: <Widget>[
                  Icon(
                    a['ok'] == true
                        ? Icons.check_circle_outline_rounded
                        : Icons.error_outline_rounded,
                    size: 14,
                    color: a['ok'] == true ? Tga.green : Tga.red,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${a['action']}'
                      '${'${a['target'] ?? ''}'.isEmpty ? '' : ' · ${a['target']}'}'
                      '${'${a['detail'] ?? ''}'.isEmpty ? '' : ' · ${a['detail']}'}',
                      style: Tga.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${a['ts'] ?? ''}'.replaceFirst('T', ' ').split('.').first,
                    style: Tga.caption,
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
