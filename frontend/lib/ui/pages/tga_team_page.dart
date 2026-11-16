import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 团队协作沙箱（本机）。
///
/// 真实目录 + 角色权限 + 审计日志：viewer 只读、runner 只读、editor 可写、
/// owner 可管理成员与删除。所有操作真实落盘，页面明确标注未实现跨设备实时同步。
class TgaTeamPage extends StatefulWidget {
  const TgaTeamPage({super.key});

  @override
  State<TgaTeamPage> createState() => _TgaTeamPageState();
}

class _TgaTeamPageState extends State<TgaTeamPage> {
  List<Map<String, dynamic>> _spaces = <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('team_space', <String, dynamic>{
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
        _spaces = (r['spaces'] is List ? r['spaces'] as List : <dynamic>[])
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
    final TextEditingController desc = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('新建团队空间', style: Tga.h2),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: name,
              autofocus: true,
              style: TextStyle(color: Tga.text),
              decoration: const InputDecoration(hintText: '空间名称'),
            ),
            TextField(
              controller: desc,
              style: TextStyle(color: Tga.text),
              decoration: const InputDecoration(hintText: '用途说明（可选）'),
            ),
            const SizedBox(height: 8),
            Text('你是 owner，可在空间内添加成员并分配角色。', style: Tga.caption),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('创建')),
        ],
      ),
    );
    final String n = name.text.trim();
    final String d = desc.text.trim();
    name.dispose();
    desc.dispose();
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('create', <String, dynamic>{
      'name': n,
      'description': d,
      'actor': '我',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '创建失败').toString());
      return;
    }
    await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '团队协作',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _create,
          tooltip: '新建团队空间',
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
                  child: CircularProgressIndicator(strokeWidth: 2, color: Tga.primary)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Text(
                    '本机协作空间：成员角色与文件权限真实生效，所有操作写入审计日志。\n'
                    '跨设备实时同步尚未配置；迁移可配合「快照备份」。',
                    style: Tga.sub,
                  ),
                ),
                TgaGroupTitle('团队空间（${_spaces.length}）'),
                if (_spaces.isEmpty)
                  TgaCard(
                    child: TgaEmpty('还没有团队空间\n点右上角 + 新建',
                        icon: Icons.groups_outlined),
                  )
                else
                  for (final Map<String, dynamic> s in _spaces)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (BuildContext _) => _TeamSpaceDetailPage(
                              space: s,
                              onChanged: _load,
                            ),
                          ),
                        ),
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: Tga.iconCyanBg,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(Icons.groups_rounded,
                                  size: 19, color: Tga.iconCyan),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(s['name'].toString(), style: Tga.h2),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${(s['members'] is List) ? (s['members'] as List).length : 0} 名成员'
                                    '${(s['description'] ?? '').toString().isEmpty ? '' : ' · ${s['description']}'}',
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

class _TeamSpaceDetailPage extends StatefulWidget {
  const _TeamSpaceDetailPage({required this.space, required this.onChanged});

  final Map<String, dynamic> space;
  final VoidCallback onChanged;

  @override
  State<_TeamSpaceDetailPage> createState() => _TeamSpaceDetailPageState();
}

class _TeamSpaceDetailPageState extends State<_TeamSpaceDetailPage> {
  late Map<String, dynamic> _space;
  List<Map<String, dynamic>> _members = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _files = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _audit = <Map<String, dynamic>>[];
  String _actor = '我';

  @override
  void initState() {
    super.initState();
    _space = widget.space;
    _load();
  }

  String get _id => _space['id'].toString();

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('team_space', <String, dynamic>{
      'action': action,
      'id': _id,
      'actor': _actor,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    final Map<String, dynamic> m = await _call('members', <String, dynamic>{'op': 'list'});
    final Map<String, dynamic> f = await _call('files');
    final Map<String, dynamic> a = await _call('audit');
    if (!mounted) return;
    setState(() {
      _members = (m['members'] is List ? m['members'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
      if (_members.isNotEmpty &&
          !_members.any((Map<String, dynamic> x) => x['name'] == _actor)) {
        _actor = _members.first['name'].toString();
      }
      _files = (f['files'] is List ? f['files'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
      _audit = (a['audit'] is List ? a['audit'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
    });
  }

  Future<void> _addMember() async {
    final TextEditingController name = TextEditingController();
    String role = 'viewer';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setLocal) => AlertDialog(
          backgroundColor: Tga.card,
          title: Text('添加成员', style: Tga.h2),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: name,
                autofocus: true,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '成员名称'),
              ),
              DropdownButtonFormField<String>(
                value: role,
                dropdownColor: Tga.card,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(labelText: '角色'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: 'viewer', child: Text('viewer · 只读')),
                  DropdownMenuItem<String>(value: 'runner', child: Text('runner · 只读')),
                  DropdownMenuItem<String>(value: 'editor', child: Text('editor · 读写')),
                  DropdownMenuItem<String>(value: 'owner', child: Text('owner · 管理')),
                ],
                onChanged: (String? v) => setLocal(() => role = v ?? 'viewer'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text('取消', style: TextStyle(color: Tga.textSub))),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true), child: const Text('添加')),
          ],
        ),
      ),
    );
    final String n = name.text.trim();
    name.dispose();
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('members', <String, dynamic>{
      'op': 'add', 'name': n, 'role': role,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '添加失败').toString());
      return;
    }
    await _load();
    widget.onChanged();
  }

  Future<void> _removeMember(String name) async {
    final Map<String, dynamic> r = await _call('members', <String, dynamic>{
      'op': 'remove', 'name': name,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '移除失败').toString());
      return;
    }
    if (_actor == name) _actor = '我';
    await _load();
    widget.onChanged();
  }

  Future<void> _setRole(String name, String role) async {
    final Map<String, dynamic> r = await _call('set_role', <String, dynamic>{
      'name': name, 'role': role,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '调整失败').toString());
      return;
    }
    await _load();
  }

  Future<void> _newFile() async {
    final TextEditingController path = TextEditingController(text: 'notes.md');
    final TextEditingController text = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('新建 / 覆盖文件', style: Tga.h2),
        content: Column(
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
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('保存')),
        ],
      ),
    );
    final String p = path.text.trim();
    final String t = text.text;
    path.dispose();
    text.dispose();
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('write', <String, dynamic>{
      'path': p, 'text': t,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '写入失败').toString());
      return;
    }
    await _load();
  }

  Future<void> _openFile(Map<String, dynamic> f) async {
    final Map<String, dynamic> r =
        await _call('read', <String, dynamic>{'path': f['path']});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '读取失败').toString());
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text(f['path'].toString(), style: Tga.h2),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(r['text'].toString(), style: Tga.body),
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('关闭', style: TextStyle(color: Tga.textSub))),
        ],
      ),
    );
  }

  Future<void> _deleteFile(Map<String, dynamic> f) async {
    final Map<String, dynamic> r =
        await _call('delete_file', <String, dynamic>{'path': f['path']});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '删除失败').toString());
      return;
    }
    await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final String myRole = _members
        .where((Map<String, dynamic> m) => m['name'] == _actor)
        .map((Map<String, dynamic> m) => (m['role'] ?? 'viewer').toString())
        .firstWhere((String _) => true, orElse: () => 'none');
    return TgaPage(
      title: _space['name'].toString(),
      actions: <Widget>[
        IconButton(
          onPressed: _load,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          TgaCard(
            child: Row(
              children: <Widget>[
                Icon(Icons.badge_outlined, size: 18, color: Tga.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _actor,
                      dropdownColor: Tga.card,
                      style: Tga.body,
                      items: _members
                          .map((Map<String, dynamic> m) => DropdownMenuItem<String>(
                                value: m['name'].toString(),
                                child: Text(
                                    '${m['name']} · ${m['role']}', style: Tga.body),
                              ))
                          .toList(),
                      onChanged: (String? v) async {
                        if (v == null) return;
                        setState(() => _actor = v);
                        await _load();
                      },
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Tga.bgSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('当前：$myRole', style: Tga.caption),
                ),
              ],
            ),
          ),
          TgaGroupTitle('成员', trailing: TextButton(
            onPressed: _addMember,
            child: Text('+ 添加', style: TextStyle(color: Tga.primary, fontSize: 12)),
          )),
          for (final Map<String, dynamic> m in _members)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TgaCard(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.person_outline_rounded, size: 17, color: Tga.textSub),
                    const SizedBox(width: 8),
                    Expanded(child: Text(m['name'].toString(), style: Tga.body)),
                    DropdownButton<String>(
                      value: (m['role'] ?? 'viewer').toString(),
                      underline: const SizedBox.shrink(),
                      dropdownColor: Tga.card,
                      style: Tga.sub,
                      items: const <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(value: 'owner', child: Text('owner')),
                        DropdownMenuItem<String>(value: 'editor', child: Text('editor')),
                        DropdownMenuItem<String>(value: 'runner', child: Text('runner')),
                        DropdownMenuItem<String>(value: 'viewer', child: Text('viewer')),
                      ],
                      onChanged: (String? v) {
                        if (v != null) _setRole(m['name'].toString(), v);
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.person_remove_outlined,
                          size: 17, color: Tga.red),
                      onPressed: m['name'] == _actor
                          ? null
                          : () => _removeMember(m['name'].toString()),
                    ),
                  ],
                ),
              ),
            ),
          TgaGroupTitle('共享文件', trailing: TextButton(
            onPressed: _newFile,
            child: Text('+ 新建', style: TextStyle(color: Tga.primary, fontSize: 12)),
          )),
          if (_files.isEmpty)
            TgaCard(child: TgaEmpty('空间里还没有文件', icon: Icons.folder_open_outlined))
          else
            for (final Map<String, dynamic> f in _files)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TgaCard(
                  onTap: () => _openFile(f),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.insert_drive_file_outlined,
                          size: 17, color: Tga.textSub),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(f['path'].toString(), style: Tga.body),
                      ),
                      Text('${f['size']} B', style: Tga.caption),
                      IconButton(
                        icon: Icon(Icons.delete_outline_rounded,
                            size: 17, color: Tga.red),
                        onPressed: () => _deleteFile(f),
                      ),
                    ],
                  ),
                ),
              ),
          TgaGroupTitle('审计日志（最近 ${_audit.length} 条）'),
          if (_audit.isEmpty)
            TgaCard(child: TgaEmpty('还没有操作记录', icon: Icons.history_rounded))
          else
            for (final Map<String, dynamic> a in _audit)
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
                        '${a['actor']} · ${a['action']} · ${a['target']}'
                        '${a['detail'].toString().isEmpty ? '' : ' · ${a['detail']}'}',
                        style: Tga.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      (a['ts'] ?? '').toString().replaceFirst('T', ' ').split('.').first,
                      style: Tga.caption,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
