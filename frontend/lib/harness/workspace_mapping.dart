/// 工作区域目录映射（宿主目录 ↔ 内置沙箱）。
///
/// 真实行为：用户授权一个宿主目录后，按 `bind_mode` 选择两种映射方式：
/// - `copy`（默认，兼容旧数据）：真实复制到沙箱 `sandbox/mounts/<id>/`，
///   支持 host→sandbox 同步、sandbox→host 回写（只读映射禁止回写）、预览与移除。
/// - `link`：桌面端在 `sandbox/mounts/<id>` 创建目录链接；Android 由
///   `ProotSandbox` 在 proot 启动时用 `-b host:/mnt/tga/<id>` 做用户态绑定
///   （Termux 同类方案，无需 root），写入即时落到宿主目录。
///
/// iOS 不支持目录链接与 proot 绑定，如实返回 `bind_supported: false`，
/// 由用户显式改用 `copy`。敏感目录默认拒绝；所有复制都限制文件数与总
/// 字节，拒绝符号链接穿越；失败如实返回错误，不删除源文件，也不伪造成功。

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

  /// 桌面平台支持目录链接映射；Android/iOS 不支持。
  /// 桌面端用目录链接；Android 用 proot 用户态 `-b` 绑定（无需 root，
  /// 与 Termux 的 proot 方案同类），所以两端都算支持真实映射。
  static bool get bindSupported =>
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isAndroid;

  /// 映射方式：'copy'（真实复制，默认）或 'link'（目录链接）。
  /// 旧记录没有 bind_mode，按原 mode 归一化为 copy。
  static String _bindModeOf(Map<String, dynamic> m) {
    final String kind = (m['bind_mode'] ?? '').toString();
    if (kind == 'link' || kind == 'copy') return kind;
    return m['mode'] == 'link' ? 'link' : 'copy';
  }

  /// 读写权限：'ro' 只读 / 'rw' 读写。旧记录用 mode 字段表达。
  static bool _isReadOnly(Map<String, dynamic> m) {
    final String access = (m['access'] ?? '').toString();
    if (access == 'ro' || access == 'rw') return access == 'ro';
    return m['mode'] == 'ro';
  }

  Future<List<Map<String, dynamic>>> _all() async {
    final List<dynamic> raw = await store.readList(_file);
    final List<Map<String, dynamic>> list = raw
        .whereType<Map>()
        .map<Map<String, dynamic>>((Map e) => Map<String, dynamic>.from(e))
        .toList();
    for (final Map<String, dynamic> m in list) {
      // 旧数据没有 bind_mode/access/link_target，读取时补齐，不丢兼容性。
      m['bind_mode'] = _bindModeOf(m);
      m['access'] = _isReadOnly(m) ? 'ro' : 'rw';
      m['link_target'] = (m['link_target'] ?? '').toString();
    }
    return list;
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
          'bind_supported': bindSupported,
          'note': bindSupported
              ? '桌面端用目录链接，Android 用 proot 用户态 -b 绑定（无需 root）；'
                  '也可选 mode=copy 复制同步；敏感目录默认拒绝。'
              : '当前平台不支持目录链接映射，移动端为文件同步复制（mode=copy）；'
                  '敏感目录默认拒绝。',
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
      case 'open':
      case 'resolve':
        return await _resolve(p);
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
    final String requested = (p['mode'] ?? '').toString();
    final bool wantsLink = requested == 'link';
    if (wantsLink && !bindSupported) {
      // 移动端不创建任何假链接，明确要求用户选择 copy。
      return <String, dynamic>{
        'ok': false,
        'error': '当前平台不支持目录链接映射，请使用 mode=copy',
        'bind_supported': false,
      };
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
    final String access = _requestedAccess(p, requested);
    final String bindMode = wantsLink ? 'link' : 'copy';
    final String id = 'map-${DateTime.now().microsecondsSinceEpoch}';
    final Map<String, dynamic> mapping = <String, dynamic>{
      'id': id,
      'name': (p['name'] ?? dir.uri.pathSegments.last).toString(),
      'host_path': resolved,
      'sandbox_rel': 'sandbox/mounts/$id',
      // link 记录用 mode=link 标识链接映射；copy 记录保留既有 rw/ro 以兼容
      // 旧数据与页面，映射方式统一由 bind_mode 表达。
      'mode': bindMode == 'link' ? 'link' : access,
      'access': access,
      'bind_mode': bindMode,
      'link_target': bindMode == 'link' ? resolved : '',
      'enabled': p['enabled'] != false,
      'created_at': DateTime.now().toIso8601String(),
      'last_sync_at': '',
      'file_count': 0,
      'bytes': 0,
    };
    final String sandboxPath = '${store.root.path}/${mapping['sandbox_rel']}';
    if (bindMode == 'link') {
      await Directory('${store.root.path}/sandbox/mounts')
          .create(recursive: true);
      if (Platform.isAndroid) {
        // Android 不用系统 mount：由 ProotSandbox 在每次 proot 启动时用
        // `-b <host>:/mnt/tga/<id>` 做用户态绑定（Termux 同类做法）。
        await Directory(sandboxPath).create(recursive: true);
        mapping['proot_bind'] = true;
      } else {
        try {
          // 桌面端目录链接：沙箱内路径直接指向宿主目录，写入即时落到宿主。
          await Link(sandboxPath).create(resolved);
        } on Object catch (e) {
          // 创建失败不落记录、不静默回退到 copy，由用户显式选择 mode=copy。
          return <String, dynamic>{
            'ok': false,
            'error': '创建目录链接失败：$e',
            'bind_supported': true,
            'mode': 'link',
          };
        }
      }
    } else {
      await Directory(sandboxPath).create(recursive: true);
    }
    await _save(<Map<String, dynamic>>[...all, mapping]);
    await _audit(mapping, 'add',
        bindMode == 'link' ? '创建目录链接映射' : '创建复制映射');
    return <String, dynamic>{
      'ok': true,
      'mapping': mapping,
      'bind_supported': bindSupported,
    };
  }

  /// 解析请求的读写权限。mode=link/copy 时用 access/read_only 指定。
  String _requestedAccess(Map<String, dynamic> p, String requested) {
    if (requested == 'ro') return 'ro';
    if (p['access'] == 'ro' ||
        p['read_only'] == true ||
        p['readonly'] == true) {
      return 'ro';
    }
    return 'rw';
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
      final String sandboxPath =
          '${store.root.path}/${target['sandbox_rel']}';
      if (_bindModeOf(target) == 'link') {
        // 链接映射只删除链接本身，绝不递归删除宿主真实目录。
        final Link link = Link(sandboxPath);
        if (await link.exists()) await link.delete();
      } else {
        final Directory dir = Directory(sandboxPath);
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    }
    await _audit(target, 'remove', '移除映射');
    return <String, dynamic>{
      'ok': true,
      'removed': id,
      'mode': _bindModeOf(target),
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
    if (_bindModeOf(m) == 'link') {
      final String linkPath = '${store.root.path}/${m['sandbox_rel']}';
      if (!await Link(linkPath).exists()) {
        return <String, dynamic>{
          'ok': false,
          'error': '目录链接已失效：$linkPath',
          'mode': 'link',
        };
      }
      // 链接映射实时指向宿主目录，没有复制环节。
      return <String, dynamic>{
        'ok': true,
        'files': 0,
        'bytes': 0,
        'errors': <String>[],
        'sandbox_path': linkPath,
        'mode': 'link',
        'link_target': m['link_target'] ?? m['host_path'],
        'note': '链接映射实时指向宿主目录，无需复制',
      };
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
    if (_isReadOnly(m)) {
      return <String, dynamic>{'ok': false, 'error': '只读映射禁止回写宿主目录'};
    }
    final bool isLink = _bindModeOf(m) == 'link';
    final Directory src =
        Directory('${store.root.path}/${m['sandbox_rel']}');
    if (!await src.exists()) {
      return <String, dynamic>{'ok': false, 'error': '沙箱映射目录不存在'};
    }
    final Directory dst = Directory(m['host_path'].toString());
    if (!await dst.exists()) {
      return <String, dynamic>{'ok': false, 'error': '宿主目录已不存在'};
    }
    if (isLink) {
      // 链接映射的写入直接落在宿主目录，这里只做写守卫，不做复制。
      final Map<String, dynamic>? denied =
          await _guardDenied('write', dst.path);
      if (denied != null) return <String, dynamic>{...denied, 'mode': 'link'};
      m['last_sync_at'] = DateTime.now().toIso8601String();
      await _update(m);
      await _audit(m, 'sync_to_host', '链接映射直接写入宿主目录');
      return <String, dynamic>{
        'ok': true,
        'files': 0,
        'bytes': 0,
        'errors': <String>[],
        'host_path': dst.path,
        'mode': 'link',
        'link_target': m['link_target'] ?? m['host_path'],
        'note': '链接映射直接写入宿主目录，无需回写',
      };
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
    final bool isLink = _bindModeOf(m) == 'link';
    final Directory dir =
        Directory('${store.root.path}/${m['sandbox_rel']}');
    // 链接映射读的是宿主真实目录，守卫也按宿主路径校验。
    final String guardPath =
        isLink ? m['host_path'].toString() : dir.path;
    final Map<String, dynamic>? denied = await _guardDenied('read', guardPath);
    if (denied != null) return denied;
    if (isLink && !await Link(dir.path).exists()) {
      return <String, dynamic>{
        'ok': false,
        'error': '目录链接已失效：${dir.path}',
        'mode': 'link',
      };
    }
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
      'mode': _bindModeOf(m),
      'truncated': entries.length >= 200,
    };
  }

  /// open / resolve：返回真实可访问路径。
  /// - link：沙箱链接路径 + 宿主真实路径（内容一致）；
  /// - copy：沙箱内复制目录路径。
  /// 两者都带 mode 与 bind_supported；write=true 时先过 guard('write', host)。
  Future<Map<String, dynamic>> _resolve(Map<String, dynamic> p) async {
    final Map<String, dynamic>? m = await _find(p);
    if (m == null) return <String, dynamic>{'ok': false, 'error': '映射不存在'};
    final String bindMode = _bindModeOf(m);
    final bool readonly = _isReadOnly(m);
    final String hostPath = m['host_path'].toString();
    final Map<String, dynamic> base = <String, dynamic>{
      'id': m['id'],
      'mode': bindMode,
      'bind_mode': bindMode,
      'bind_supported': bindSupported,
      'link_target': (m['link_target'] ?? '').toString(),
      'readonly': readonly,
    };
    if (p['write'] == true) {
      if (readonly) {
        return <String, dynamic>{
          ...base,
          'ok': false,
          'error': '只读映射禁止写入',
        };
      }
      final Map<String, dynamic>? denied =
          await _guardDenied('write', hostPath);
      if (denied != null) return <String, dynamic>{...base, ...denied};
    }
    if (bindMode == 'link') {
      if (!await Directory(hostPath).exists()) {
        return <String, dynamic>{
          ...base,
          'ok': false,
          'error': '宿主目录已不存在：$hostPath',
        };
      }
      if (Platform.isAndroid) {
        // Android 由 proot 绑定到 /mnt/tga/<id>，不是系统目录链接。
        final String guestPath = '/mnt/tga/${m['id']}';
        return <String, dynamic>{
          ...base,
          'ok': true,
          'path': guestPath,
          'proot_path': guestPath,
          'host_path': hostPath,
          'real_path': hostPath,
        };
      }
      final String linkPath = '${store.root.path}/${m['sandbox_rel']}';
      if (!await Link(linkPath).exists()) {
        return <String, dynamic>{
          ...base,
          'ok': false,
          'error': '目录链接已失效：$linkPath -> $hostPath',
        };
      }
      return <String, dynamic>{
        ...base,
        'ok': true,
        'path': linkPath,
        'link_path': linkPath,
        'host_path': hostPath,
        'real_path': hostPath,
      };
    }
    final String sandboxPath = '${store.root.path}/${m['sandbox_rel']}';
    return <String, dynamic>{
      ...base,
      'ok': true,
      'path': sandboxPath,
      'sandbox_path': sandboxPath,
      'host_path': hostPath,
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
