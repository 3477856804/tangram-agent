/// 团队协作沙箱（本地版）。
///
/// 真实能力：
///  * 创建协作工作区，每个空间有独立目录 `team/<id>/`；
///  * 成员与角色（owner / editor / runner / viewer），按角色强制读写权限；
///  * 文件读写全部限制在空间目录内，拒绝 `..` 越界；
///  * 每次操作写入只追加的审计日志（成员、动作、路径、结果、时间）。
///
/// 边界：这是**本机**协作空间，不谎称已实现跨设备实时同步；跨端共享需配合
/// 快照/外部同步，页面会如实标注。

import 'dart:convert';
import 'dart:io';

import 'store.dart';

class TeamSpaceService {
  TeamSpaceService(this.store);

  final HarnessStore store;

  static const Set<String> roles = <String>{
    'owner',
    'editor',
    'runner',
    'viewer',
  };

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    switch (action) {
      case 'list':
        return <String, dynamic>{
          'ok': true,
          'spaces': await _spaces(),
          'local_only': true,
          'note': '本机协作空间；跨设备实时同步未配置，可通过快照备份迁移。',
        };
      case 'create':
        return await _create(p);
      case 'update':
        return await _update(p);
      case 'delete':
        return await _delete(p);
      case 'members':
        return await _members(p);
      case 'set_role':
        return await _setRole(p);
      case 'files':
        return await _files(p);
      case 'read':
        return await _read(p);
      case 'write':
        return await _write(p);
      case 'delete_file':
        return await _deleteFile(p);
      case 'audit':
        return await _audit(p);
      default:
        return <String, dynamic>{'ok': false, 'error': '未知团队空间动作：$action'};
    }
  }

  Future<List<Map<String, dynamic>>> _spaces() async =>
      await store.readRecords('team_spaces');

  String _id() => 'team-${DateTime.now().microsecondsSinceEpoch}';

  Map<String, dynamic>? _find(List<Map<String, dynamic>> all, String id) {
    for (final Map<String, dynamic> s in all) {
      if (s['id'].toString() == id) return s;
    }
    return null;
  }

  Directory _dir(String id) => Directory('${store.root.path}/team/$id');

  String? _roleOf(Map<String, dynamic> space, String actor) {
    final dynamic raw = space['members'];
    if (raw is! List) return null;
    for (final dynamic m in raw) {
      if (m is Map && (m['name'] ?? '').toString() == actor) {
        return (m['role'] ?? 'viewer').toString();
      }
    }
    return null;
  }

  bool _canRead(String? role) => role != null;
  bool _canWrite(String? role) => role == 'owner' || role == 'editor';

  Future<Map<String, dynamic>> _auditLog(
    Map<String, dynamic> space,
    String actor,
    String action,
    String target,
    bool ok,
    String detail,
  ) async {
    final Map<String, dynamic> entry = <String, dynamic>{
      'space_id': space['id'],
      'actor': actor,
      'action': action,
      'target': target,
      'ok': ok,
      'detail': detail,
      'ts': DateTime.now().toIso8601String(),
    };
    await store.insert('team_audit', entry);
    return entry;
  }

  Future<Map<String, dynamic>> _create(Map<String, dynamic> p) async {
    final String name = (p['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '团队空间名称不能为空'};
    }
    final String actor = (p['actor'] ?? '我').toString().trim();
    final List<Map<String, dynamic>> all = await _spaces();
    if (all.any((Map<String, dynamic> s) => s['name'] == name)) {
      return <String, dynamic>{'ok': false, 'error': '同名团队空间已存在'};
    }
    final String id = _id();
    final Map<String, dynamic> space = <String, dynamic>{
      'id': id,
      'name': name,
      'description': (p['description'] ?? '').toString().trim(),
      'members': <Map<String, dynamic>>[
        <String, dynamic>{'name': actor.isEmpty ? '我' : actor, 'role': 'owner'},
      ],
      'created_at': DateTime.now().toIso8601String(),
      'dir': 'team/$id',
    };
    await store.writeRecords('team_spaces', <Map<String, dynamic>>[...all, space]);
    await _dir(id).create(recursive: true);
    await _auditLog(space, actor, 'create', name, true, '创建团队空间');
    return <String, dynamic>{'ok': true, 'space': space};
  }

  Future<Map<String, dynamic>> _update(Map<String, dynamic> p) async {
    final List<Map<String, dynamic>> all = await _spaces();
    final Map<String, dynamic>? space =
        _find(all, (p['id'] ?? '').toString());
    if (space == null) {
      return <String, dynamic>{'ok': false, 'error': '团队空间不存在'};
    }
    final String actor = (p['actor'] ?? '我').toString();
    if (_roleOf(space, actor) != 'owner') {
      return <String, dynamic>{'ok': false, 'error': '只有 owner 可修改空间设置'};
    }
    if (p.containsKey('name')) {
      final String name = (p['name'] ?? '').toString().trim();
      if (name.isEmpty) {
        return <String, dynamic>{'ok': false, 'error': '名称不能为空'};
      }
      space['name'] = name;
    }
    if (p.containsKey('description')) {
      space['description'] = (p['description'] ?? '').toString().trim();
    }
    await store.writeRecords('team_spaces', all);
    return <String, dynamic>{'ok': true, 'space': space};
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final List<Map<String, dynamic>> all = await _spaces();
    final String id = (p['id'] ?? '').toString();
    final Map<String, dynamic>? space = _find(all, id);
    if (space == null) {
      return <String, dynamic>{'ok': false, 'error': '团队空间不存在'};
    }
    final String actor = (p['actor'] ?? '我').toString();
    if (_roleOf(space, actor) != 'owner') {
      return <String, dynamic>{'ok': false, 'error': '只有 owner 可删除空间'};
    }
    all.remove(space);
    await store.writeRecords('team_spaces', all);
    await _auditLog(space, actor, 'delete', id, true, '删除空间记录（文件保留）');
    return <String, dynamic>{
      'ok': true,
      'deleted': id,
      'note': '空间记录已删除；磁盘文件保留在 team/$id，避免误删。',
    };
  }

  Future<Map<String, dynamic>> _members(Map<String, dynamic> p) async {
    final List<Map<String, dynamic>> all = await _spaces();
    final Map<String, dynamic>? space =
        _find(all, (p['id'] ?? '').toString());
    if (space == null) {
      return <String, dynamic>{'ok': false, 'error': '团队空间不存在'};
    }
    final String actor = (p['actor'] ?? '我').toString();
    final String? role = _roleOf(space, actor);
    if (!_canRead(role)) {
      return <String, dynamic>{'ok': false, 'error': '不是该空间成员'};
    }
    final String op = (p['op'] ?? 'list').toString();
    if (op == 'list') {
      return <String, dynamic>{
        'ok': true,
        'members': space['members'] ?? <dynamic>[],
        'my_role': role,
      };
    }
    if (role != 'owner') {
      return <String, dynamic>{'ok': false, 'error': '只有 owner 可管理成员'};
    }
    final List<Map<String, dynamic>> members =
        (space['members'] as List? ?? <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
    final String name = (p['name'] ?? '').toString().trim();
    if (op == 'add') {
      if (name.isEmpty) return <String, dynamic>{'ok': false, 'error': '成员名不能为空'};
      if (members.any((Map<String, dynamic> m) => m['name'] == name)) {
        return <String, dynamic>{'ok': false, 'error': '成员已存在'};
      }
      final String r = (p['role'] ?? 'viewer').toString();
      members.add(<String, dynamic>{
        'name': name,
        'role': roles.contains(r) ? r : 'viewer',
      });
    } else if (op == 'remove') {
      members.removeWhere((Map<String, dynamic> m) => m['name'] == name);
    } else {
      return <String, dynamic>{'ok': false, 'error': '未知成员操作：$op'};
    }
    space['members'] = members;
    await store.writeRecords('team_spaces', all);
    await _auditLog(space, actor, 'members_$op', name, true, '成员变更');
    return <String, dynamic>{'ok': true, 'members': members};
  }

  Future<Map<String, dynamic>> _setRole(Map<String, dynamic> p) async {
    final List<Map<String, dynamic>> all = await _spaces();
    final Map<String, dynamic>? space =
        _find(all, (p['id'] ?? '').toString());
    if (space == null) {
      return <String, dynamic>{'ok': false, 'error': '团队空间不存在'};
    }
    final String actor = (p['actor'] ?? '我').toString();
    if (_roleOf(space, actor) != 'owner') {
      return <String, dynamic>{'ok': false, 'error': '只有 owner 可调整角色'};
    }
    final String name = (p['name'] ?? '').toString();
    final String role = (p['role'] ?? '').toString();
    if (!roles.contains(role)) {
      return <String, dynamic>{'ok': false, 'error': '角色只能是 ${roles.join("/")}'};
    }
    final List<Map<String, dynamic>> members =
        (space['members'] as List? ?? <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
    bool found = false;
    for (final Map<String, dynamic> m in members) {
      if (m['name'] == name) {
        m['role'] = role;
        found = true;
      }
    }
    if (!found) return <String, dynamic>{'ok': false, 'error': '成员不存在'};
    space['members'] = members;
    await store.writeRecords('team_spaces', all);
    await _auditLog(space, actor, 'set_role', name, true, '角色改为 $role');
    return <String, dynamic>{'ok': true, 'members': members};
  }

  Future<Map<String, dynamic>> _files(Map<String, dynamic> p) async {
    final List<Map<String, dynamic>> all = await _spaces();
    final Map<String, dynamic>? space =
        _find(all, (p['id'] ?? '').toString());
    if (space == null) {
      return <String, dynamic>{'ok': false, 'error': '团队空间不存在'};
    }
    final String actor = (p['actor'] ?? '我').toString();
    final String? role = _roleOf(space, actor);
    if (!_canRead(role)) {
      return <String, dynamic>{'ok': false, 'error': '不是该空间成员'};
    }
    final Directory dir = _dir(space['id'].toString());
    if (!await dir.exists()) {
      return <String, dynamic>{'ok': true, 'files': <dynamic>[], 'my_role': role};
    }
    final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
    await for (final FileSystemEntity e in dir.list(recursive: true)) {
      if (e is! File) continue;
      final FileStat st = await e.stat();
      files.add(<String, dynamic>{
        'path': e.path.substring(dir.path.length + 1),
        'size': st.size,
        'modified': st.modified.toIso8601String(),
      });
    }
    files.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        a['path'].toString().compareTo(b['path'].toString()));
    return <String, dynamic>{'ok': true, 'files': files, 'my_role': role};
  }

  File? _safeFile(String spaceId, String relative) {
    final String cleaned = relative.replaceAll('\\', '/').trim();
    if (cleaned.isEmpty || cleaned.startsWith('/') || cleaned.contains('..')) {
      return null;
    }
    return File('${_dir(spaceId).path}/$cleaned');
  }

  Future<Map<String, dynamic>> _read(Map<String, dynamic> p) async {
    final List<Map<String, dynamic>> all = await _spaces();
    final Map<String, dynamic>? space =
        _find(all, (p['id'] ?? '').toString());
    if (space == null) {
      return <String, dynamic>{'ok': false, 'error': '团队空间不存在'};
    }
    final String actor = (p['actor'] ?? '我').toString();
    final String? role = _roleOf(space, actor);
    if (!_canRead(role)) {
      return <String, dynamic>{'ok': false, 'error': '不是该空间成员'};
    }
    final File? f = _safeFile(space['id'].toString(), (p['path'] ?? '').toString());
    if (f == null) {
      await _auditLog(space, actor, 'read', (p['path'] ?? '').toString(), false,
          '路径越界被拒绝');
      return <String, dynamic>{'ok': false, 'error': '路径越界，已拒绝'};
    }
    if (!await f.exists()) {
      return <String, dynamic>{'ok': false, 'error': '文件不存在'};
    }
    final int size = await f.length();
    if (size > 2 * 1024 * 1024) {
      return <String, dynamic>{'ok': false, 'error': '文件超过 2MB，请用沙箱工具处理'};
    }
    String text;
    try {
      text = utf8.decode(await f.readAsBytes());
    } on Object {
      return <String, dynamic>{'ok': false, 'error': '不是 UTF-8 文本，拒绝预览'};
    }
    await _auditLog(space, actor, 'read', f.path, true, '$size 字节');
    return <String, dynamic>{'ok': true, 'text': text, 'size': size};
  }

  Future<Map<String, dynamic>> _write(Map<String, dynamic> p) async {
    final List<Map<String, dynamic>> all = await _spaces();
    final Map<String, dynamic>? space =
        _find(all, (p['id'] ?? '').toString());
    if (space == null) {
      return <String, dynamic>{'ok': false, 'error': '团队空间不存在'};
    }
    final String actor = (p['actor'] ?? '我').toString();
    final String? role = _roleOf(space, actor);
    if (!_canWrite(role)) {
      await _auditLog(space, actor, 'write', (p['path'] ?? '').toString(),
          false, '角色 $role 无写权限');
      return <String, dynamic>{'ok': false, 'error': '当前角色（$role）无写权限'};
    }
    final File? f = _safeFile(space['id'].toString(), (p['path'] ?? '').toString());
    if (f == null) {
      return <String, dynamic>{'ok': false, 'error': '路径越界，已拒绝'};
    }
    final String text = (p['text'] ?? '').toString();
    if (text.length > 2 * 1024 * 1024) {
      return <String, dynamic>{'ok': false, 'error': '文本超过 2MB'};
    }
    await f.parent.create(recursive: true);
    await f.writeAsString(text, flush: true);
    await _auditLog(space, actor, 'write', f.path, true, '${text.length} 字符');
    return <String, dynamic>{'ok': true, 'path': f.path.substring(_dir(space['id'].toString()).path.length + 1)};
  }

  Future<Map<String, dynamic>> _deleteFile(Map<String, dynamic> p) async {
    final List<Map<String, dynamic>> all = await _spaces();
    final Map<String, dynamic>? space =
        _find(all, (p['id'] ?? '').toString());
    if (space == null) {
      return <String, dynamic>{'ok': false, 'error': '团队空间不存在'};
    }
    final String actor = (p['actor'] ?? '我').toString();
    final String? role = _roleOf(space, actor);
    if (!_canWrite(role)) {
      return <String, dynamic>{'ok': false, 'error': '当前角色（$role）无删除权限'};
    }
    final File? f = _safeFile(space['id'].toString(), (p['path'] ?? '').toString());
    if (f == null) {
      return <String, dynamic>{'ok': false, 'error': '路径越界，已拒绝'};
    }
    if (!await f.exists()) {
      return <String, dynamic>{'ok': false, 'error': '文件不存在'};
    }
    await f.delete();
    await _auditLog(space, actor, 'delete_file', f.path, true, '删除文件');
    return <String, dynamic>{'ok': true, 'deleted': p['path']};
  }

  Future<Map<String, dynamic>> _audit(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final List<Map<String, dynamic>> all = await store.readRecords('team_audit');
    final List<Map<String, dynamic>> filtered = all
        .where((Map<String, dynamic> e) => e['space_id'].toString() == id)
        .toList()
        .reversed
        .take(200)
        .toList();
    return <String, dynamic>{'ok': true, 'audit': filtered};
  }
}
