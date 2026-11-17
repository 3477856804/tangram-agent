/// 工作区域目录映射（宿主目录 ↔ 内置沙箱）。
///
/// 真实行为：用户授权一个宿主目录后，把它复制到沙箱 `sandbox/mounts/<id>/`，
/// 支持 host→sandbox 同步、sandbox→host 回写（只读映射禁止回写）、预览与移除。
/// 这是**文件同步映射**，不是内核 bind mount：在移动端受限环境里如实标注，
/// 不假装已挂载。敏感目录（.ssh/.gnupg/系统目录）默认拒绝。
///
/// 所有复制都限制文件数与总字节，拒绝符号链接穿越；失败如实返回错误，
/// 不删除源文件，也不伪造成功。

import 'dart:io';

import 'store.dart';

/// 守卫可抛出该异常，在拒绝结果里附带更具体的说明（如审批单号）。
class WorkspaceGuardDenied implements Exception {
  WorkspaceGuardDenied(this.message);

  final String message;

  @override
  String toString() => message;
}

class WorkspaceMappingService {
  WorkspaceMappingService(this.store, {this.guard});

  final HarnessStore store;

  /// 真实文件动作前的安全守卫：返回 false 时拒绝执行并返回 `denied`。
  /// 默认 null 表示不拦截（保持既有行为）。
  final Future<bool> Function(String tool, String path)? guard;

  static const String _file = 'workspace_mappings.json';
  static const int _maxFiles = 5000;
  static const int _maxBytes = 200 * 1024 * 1024;

  Future<List<Map<String, dynamic>>> _all() async {
    final List<dynamic> raw = await store.readList(_file);
    return raw
        .whereType<Map>()
        .map<Map<String, dynamic>>((Map e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> _save(List<Map<String, dynamic>> list) =>
      store.writeJson(_file, list);

  /// 执行文件动作前的守卫；返回 null 表示放行，否则返回拒绝结果。
  Future<Map<String, dynamic>?> _guardDenied(String tool, String path) async {
    final Future<bool> Function(String tool, String path)? g = guard;
    if (g == null) return null;
    final bool allowed;
    try {
      allowed = await g(tool, path);
    } on WorkspaceGuardDenied catch (e) {
      return <String, dynamic>{'ok': false, 'error': e.message, 'denied': true};
    }
    if (allowed) return null;
    return <String, dynamic>{
      'ok': false,
      'error': '操作被安全策略拒绝或待审批：$path',
      'denied': true,
    };
  }

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    switch (action) {
      case 'list':
        return <String, dynamic>{
          'ok': true,
          'mappings': await _all(),
          'mode': 'file-sync',
          'note': '移动端为文件同步映射，不是内核 bind mount；敏感目录默认拒绝。',
        };
      case 'add':
        return await _add(p);
      case 'remove':
        return await _remove(p);
      case 'sync_to_sandbox':
        return await _syncToSandbox(p);
      case 'sync_to_host':
        return await _syncToHost(p);
      case 'preview':
        return await _preview(p);
      default:
        return <String, dynamic>{'ok': false, 'error': '未知映射动作：$action'};
    }
  }

  bool _sensitive(String path) {
    final String p = path.replaceAll('\\', '/').toLowerCase();
    const List<String> deny = <String>[
      '/etc', '/proc', '/sys', '/dev', '/boot', '/root',
      '.ssh', '.gnupg', '.aws', '.config/gcloud',
      'id_rsa', 'id_ed25519', 'credentials', 'secrets', '.env',
    ];
    return deny.any(p.contains);
  }

  Future<Map<String, dynamic>> _add(Map<String, dynamic> p) async {
    final String hostPath = (p['host_path'] ?? '').toString().trim();
    if (hostPath.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '宿主目录为空'};
    }
    final Directory dir = Directory(hostPath);
    if (!await dir.exists()) {
      return <String, dynamic>{'ok': false, 'error': '目录不存在：$hostPath'};
    }
    final String resolved = dir.absolute.path;
    if (_sensitive(resolved)) {
      return <String, dynamic>{
        'ok': false,
        'error': '安全策略拒绝映射敏感目录：$resolved',
      };
    }
    final List<Map<String, dynamic>> all = await _all();
    if (all.any((Map<String, dynamic> m) => m['host_path'] == resolved)) {
      return <String, dynamic>{'ok': false, 'error': '该目录已映射'};
    }
    final Map<String, dynamic>? denied = await _guardDenied('mkdir', resolved);
    if (denied != null) return denied;
    final String id = 'map-${DateTime.now().microsecondsSinceEpoch}';
    final Map<String, dynamic> mapping = <String, dynamic>{
      'id': id,
      'name': (p['name'] ?? dir.uri.pathSegments.last).toString(),
      'host_path': resolved,
      'sandbox_rel': 'sandbox/mounts/$id',
      'mode': (p['mode'] ?? 'rw').toString() == 'ro' ? 'ro' : 'rw',
      'enabled': p['enabled'] != false,
      'created_at': DateTime.now().toIso8601String(),
      'last_sync_at': '',
      'file_count': 0,
      'bytes': 0,
    };
    await Directory('${store.root.path}/${mapping['sandbox_rel']}')
        .create(recursive: true);
    await _save(<Map<String, dynamic>>[...all, mapping]);
    await _audit(mapping, 'add', '创建映射');
    return <String, dynamic>{'ok': true, 'mapping': mapping};
  }

  Future<Map<String, dynamic>> _remove(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final List<Map<String, dynamic>> all = await _all();
    final int before = all.length;
    Map<String, dynamic>? target;
    for (final Map<String, dynamic> m in all) {
      if (m['id'] == id) target = m;
    }
    if (target == null) {
      return <String, dynamic>{'ok': false, 'error': '映射不存在'};
    }
    final Map<String, dynamic>? denied = await _guardDenied(
        'delete', target['host_path'].toString());
    if (denied != null) return denied;
    all.removeWhere((Map<String, dynamic> m) => m['id'] == id);
    if (all.length == before) {
      return <String, dynamic>{'ok': false, 'error': '映射不存在'};
    }
    await _save(all);
    if (p['delete_files'] == true) {
      final Directory dir =
          Directory('${store.root.path}/${target['sandbox_rel']}');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
    await _audit(target, 'remove', '移除映射');
    return <String, dynamic>{
      'ok': true,
      'removed': id,
      'files_deleted': p['delete_files'] == true,
    };
  }

  Future<Map<String, dynamic>> _syncToSandbox(Map<String, dynamic> p) async {
    final Map<String, dynamic>? m = await _find(p);
    if (m == null) return <String, dynamic>{'ok': false, 'error': '映射不存在'};
    final Directory src = Directory(m['host_path'].toString());
    if (!await src.exists()) {
      return <String, dynamic>{'ok': false, 'error': '宿主目录已不存在'};
    }
    final Map<String, dynamic>? denied = await _guardDenied('copy', src.path);
    if (denied != null) return denied;
    final Directory dst =
        Directory('${store.root.path}/${m['sandbox_rel']}');
    await dst.create(recursive: true);
    int files = 0;
    int bytes = 0;
    final List<String> errors = <String>[];
    await for (final FileSystemEntity e
        in src.list(recursive: true, followLinks: false)) {
      if (files >= _maxFiles || bytes > _maxBytes) {
        errors.add('超过同步上限（$_maxFiles 个文件 / 200MB），已截断');
        break;
      }
      if (e is Link) {
        errors.add('跳过符号链接：${e.path}');
        continue;
      }
      if (e is! File) continue;
      final String rel = e.path.substring(src.path.length + 1);
      if (_sensitive(rel)) {
        errors.add('跳过敏感文件：$rel');
        continue;
      }
      final int size = await e.length();
      if (bytes + size > _maxBytes) {
        errors.add('跳过超限文件：$rel');
        continue;
      }
      final File out = File('${dst.path}/$rel');
      await out.parent.create(recursive: true);
      await e.copy(out.path);
      files++;
      bytes += size;
    }
    m['last_sync_at'] = DateTime.now().toIso8601String();
    m['file_count'] = files;
    m['bytes'] = bytes;
    await _update(m);
    await _audit(m, 'sync_to_sandbox', '$files 个文件 / $bytes 字节');
    return <String, dynamic>{
      'ok': errors.isEmpty,
      'files': files,
      'bytes': bytes,
      'errors': errors,
      'sandbox_path': dst.path,
    };
  }

  Future<Map<String, dynamic>> _syncToHost(Map<String, dynamic> p) async {
    final Map<String, dynamic>? m = await _find(p);
    if (m == null) return <String, dynamic>{'ok': false, 'error': '映射不存在'};
    if (m['mode'] == 'ro') {
      return <String, dynamic>{'ok': false, 'error': '只读映射禁止回写宿主目录'};
    }
    final Directory src =
        Directory('${store.root.path}/${m['sandbox_rel']}');
    if (!await src.exists()) {
      return <String, dynamic>{'ok': false, 'error': '沙箱映射目录不存在'};
    }
    final Directory dst = Directory(m['host_path'].toString());
    if (!await dst.exists()) {
      return <String, dynamic>{'ok': false, 'error': '宿主目录已不存在'};
    }
    final Map<String, dynamic>? denied = await _guardDenied('write', dst.path);
    if (denied != null) return denied;
    int files = 0;
    int bytes = 0;
    final List<String> errors = <String>[];
    await for (final FileSystemEntity e
        in src.list(recursive: true, followLinks: false)) {
      if (e is Link) continue;
      if (e is! File) continue;
      final String rel = e.path.substring(src.path.length + 1);
      if (_sensitive(rel)) continue;
      if (files >= _maxFiles || bytes > _maxBytes) {
        errors.add('超过回写上限，已截断');
        break;
      }
      final int size = await e.length();
      if (bytes + size > _maxBytes) {
        errors.add('跳过超限文件：$rel');
        continue;
      }
      final File out = File('${dst.path}/$rel');
      await out.parent.create(recursive: true);
      await e.copy(out.path);
      files++;
      bytes += size;
    }
    m['last_sync_at'] = DateTime.now().toIso8601String();
    await _update(m);
    await _audit(m, 'sync_to_host', '$files 个文件 / $bytes 字节');
    return <String, dynamic>{
      'ok': errors.isEmpty,
      'files': files,
      'bytes': bytes,
      'errors': errors,
      'host_path': dst.path,
    };
  }

  Future<Map<String, dynamic>> _preview(Map<String, dynamic> p) async {
    final Map<String, dynamic>? m = await _find(p);
    if (m == null) return <String, dynamic>{'ok': false, 'error': '映射不存在'};
    final Directory dir =
        Directory('${store.root.path}/${m['sandbox_rel']}');
    final Map<String, dynamic>? denied = await _guardDenied('read', dir.path);
    if (denied != null) return denied;
    if (!await dir.exists()) {
      return <String, dynamic>{'ok': true, 'entries': <dynamic>[]};
    }
    final List<Map<String, dynamic>> entries = <Map<String, dynamic>>[];
    await for (final FileSystemEntity e
        in dir.list(recursive: true, followLinks: false)) {
      if (entries.length >= 200) break;
      final String rel = e.path.substring(dir.path.length + 1);
      if (e is File) {
        final FileStat st = await e.stat();
        entries.add(<String, dynamic>{
          'path': rel,
          'size': st.size,
          'is_dir': false,
        });
      } else if (e is Directory) {
        entries.add(<String, dynamic>{'path': '$rel/', 'is_dir': true});
      }
    }
    entries.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        a['path'].toString().compareTo(b['path'].toString()));
    return <String, dynamic>{
      'ok': true,
      'entries': entries,
      'mapping': m,
      'truncated': entries.length >= 200,
    };
  }

  Future<Map<String, dynamic>?> _find(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    for (final Map<String, dynamic> m in await _all()) {
      if (m['id'] == id) return m;
    }
    return null;
  }

  Future<void> _update(Map<String, dynamic> mapping) async {
    final List<Map<String, dynamic>> all = await _all();
    final int idx = all.indexWhere((Map<String, dynamic> m) => m['id'] == mapping['id']);
    if (idx < 0) return;
    all[idx] = Map<String, dynamic>.from(mapping);
    await _save(all);
  }

  Future<void> _audit(
      Map<String, dynamic> mapping, String action, String detail) async {
    // 映射审计写入独立记录集合；串行 await，避免与主写盘并发改名冲突。
    await store.insert('workspace_mapping_audit', <String, dynamic>{
      'mapping_id': mapping['id'],
      'action': action,
      'detail': detail,
      'ts': DateTime.now().toIso8601String(),
    });
  }

  /// 供页面展示 mapping 的真实沙箱路径。
  static String sandboxPathOf(Map<String, dynamic> mapping) =>
      mapping['sandbox_rel'].toString();
}
