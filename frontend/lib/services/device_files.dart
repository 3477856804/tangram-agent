import 'dart:io';

/// 设备文件访问授权状态（平台无关）。
/// Android 的「所有文件访问」、iOS 的文件 App 授权、桌面直接可用，统一映射到这里。
enum DeviceFileAccess { unknown, granted, denied, needsSystemSettings }

/// 一条可访问根目录。授权前通常只有 App 私有目录；授权后扩展到设备共享存储。
class DeviceRoot {
  const DeviceRoot(this.path, this.label, {this.writable = true});

  final String path;
  final String label;
  final bool writable;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'label': label,
        'writable': writable,
      };

  @override
  String toString() => 'DeviceRoot($label, $path, writable=$writable)';
}

/// 权限网关：平台差异的唯一注入点。
///
/// 核心文件能力（本文件）不 import 任何 Android/iOS 原生包，因此可在全部
/// Flutter 平台编译；各平台只需提供本接口的实现：
///   - Android：MethodChannel 检查/申请 MANAGE_EXTERNAL_STORAGE + 共享存储根
///   - iOS：文件 App / 文档选择器授权目录
///   - 桌面（Linux/Windows/macOS）：直接 granted，传用户目录为根
abstract class DeviceFileGateway {
  Future<DeviceFileAccess> check();
  Future<DeviceFileAccess> request();
  List<DeviceRoot> roots();
}

/// 无需系统授权模型的平台（桌面 / 已获私有目录）直接放行。
class LocalDeviceFileGateway implements DeviceFileGateway {
  LocalDeviceFileGateway(this._roots,
      {DeviceFileAccess state = DeviceFileAccess.granted})
      : _state = state;

  final List<DeviceRoot> _roots;
  DeviceFileAccess _state;

  @override
  Future<DeviceFileAccess> check() async => _state;

  @override
  Future<DeviceFileAccess> request() async => _state;

  @override
  List<DeviceRoot> roots() => List<DeviceRoot>.unmodifiable(_roots);
}

/// 目录/文件条目。
class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    required this.modified,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final String modified;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
        'is_directory': isDirectory,
        'size': size,
        'modified': modified,
      };
}

/// 一次文件操作的结果。未授权时 needsPermission=true 且绝不触碰磁盘。
class FileOpResult {
  const FileOpResult._(
      this.ok, this.op, this.data, this.error, this.needsPermission);

  final bool ok;
  final String op;
  final dynamic data;
  final String error;
  final bool needsPermission;

  factory FileOpResult.ok(String op, dynamic data) =>
      FileOpResult._(true, op, data, '', false);
  factory FileOpResult.fail(String op, String error) =>
      FileOpResult._(false, op, null, error, false);
  factory FileOpResult.permissionNeeded(String op) => FileOpResult._(
        false,
        op,
        null,
        '需要用户授权设备文件访问后才能执行 $op',
        true,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'op': op,
        'data': data,
        'error': error,
        'needs_permission': needsPermission,
      };
}

class DeviceFileException implements Exception {
  DeviceFileException(this.message);
  final String message;
  @override
  String toString() => 'DeviceFileException: $message';
}

/// 跨平台真实文件服务。
///
/// 安全约定（与 README 四道沙箱门一致）：
///   1. 每次操作先过授权门控，未授权返回 needsPermission，不落盘。
///   2. 所有路径必须落在已授权的 roots 内；字面 ..、绝对路径越界、
///      符号链接逃逸一律拒绝。
///   3. 删除不物理 unlink，统一移入隔离区（quarantine）。
///   4. 读取有字节上限，防止把超大文件读进内存。
class DeviceFileService {
  DeviceFileService({
    required DeviceFileGateway gateway,
    int maxReadBytes = 4 * 1024 * 1024,
    int maxListEntries = 2000,
    int maxSearchResults = 500,
  })  : _gateway = gateway,
        _maxReadBytes = maxReadBytes,
        _maxListEntries = maxListEntries,
        _maxSearchResults = maxSearchResults;

  final DeviceFileGateway _gateway;
  final int _maxReadBytes;
  final int _maxListEntries;
  final int _maxSearchResults;

  DeviceFileGateway get gateway => _gateway;
  List<DeviceRoot> get roots => _gateway.roots();

  Future<DeviceFileAccess> accessState() => _gateway.check();
  Future<DeviceFileAccess> requestAccess() => _gateway.request();

  /// 把路径规范化为可比较的绝对形式（折叠 . 与 ..，兼容 Windows 盘符）。
  /// 仅用于安全检查；真正落盘用调用方传入的原路径，由 dart:io 自行解析。
  static String normalize(String path) {
    final raw = path.replaceAll('\\', '/');
    final drive = RegExp(r'^[A-Za-z]:').firstMatch(raw)?.group(0) ?? '';
    final body = drive.isEmpty ? raw : raw.substring(drive.length);
    final segs = <String>[];
    for (final s in body.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (segs.isNotEmpty) segs.removeLast();
        continue;
      }
      segs.add(s);
    }
    final joined = segs.join('/');
    if (drive.isNotEmpty) return '$drive/$joined';
    return '${raw.startsWith('/') ? '/' : ''}$joined';
  }

  static bool _hasTraversal(String raw) =>
      raw.replaceAll('\\', '/').split('/').contains('..');

  /// 取绝对真实路径（符号链接也解析），用于越界判定。
  ///
  /// 真实路径越权拦截：目标不存在时，逐级向上找到最近存在的祖先目录并解析
  /// 其真实路径后再拼回尾部，防止用「不存在的路径 + 符号链接祖先」逃逸出
  /// 授权根。与内置沙箱 sandbox.py 的 _is_within_roots 判定保持一致。
  String _absolute(String path) {
    final FileSystemEntityType type =
        FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      try {
        return normalize(File(path).resolveSymbolicLinksSync());
      } on Object {
        return normalize(File(path).absolute.path);
      }
    }

    String current = normalize(File(path).absolute.path);
    final List<String> tail = <String>[];
    while (true) {
      final FileSystemEntityType ancestor =
          FileSystemEntity.typeSync(current, followLinks: false);
      if (ancestor != FileSystemEntityType.notFound) {
        try {
          final String realRoot =
              normalize(File(current).resolveSymbolicLinksSync());
          if (tail.isEmpty) return realRoot;
          return normalize('$realRoot/${tail.reversed.join('/')}');
        } on Object {
          return normalize(File(path).absolute.path);
        }
      }
      final int idx = current.lastIndexOf('/');
      if (idx <= 0) return normalize(File(path).absolute.path);
      tail.add(current.substring(idx + 1));
      current = current.substring(0, idx);
    }
  }

  List<String> _rootPaths() =>
      _gateway.roots().map((DeviceRoot r) => normalize(r.path)).toList();

  /// 校验目标路径是否落在任一授权根内，返回规范化的真实绝对路径。
  String _guardPath(String path, {bool requireWritable = false}) {
    if (_hasTraversal(path)) {
      throw DeviceFileException('路径穿越被拒绝：$path');
    }
    final abs = _absolute(path);
    final candidates = requireWritable
        ? _gateway
            .roots()
            .where((DeviceRoot r) => r.writable)
            .map((DeviceRoot r) => normalize(r.path))
            .toList()
        : _rootPaths();
    for (final root in candidates) {
      if (abs == root || abs.startsWith('$root/')) {
        return abs;
      }
    }
    throw DeviceFileException('路径越权：$abs 不在授权根 $candidates 内');
  }

  Future<FileOpResult> _guard(String op) async {
    final state = await _gateway.check();
    if (state != DeviceFileAccess.granted) {
      return FileOpResult.permissionNeeded(op);
    }
    return FileOpResult.ok(op, null);
  }

  /// 列出目录内容（真实 dart:io）。
  Future<FileOpResult> list(String dirPath) async {
    final g = await _guard('list');
    if (g.needsPermission) return g;
    try {
      _guardPath(dirPath);
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        return FileOpResult.fail('list', '目录不存在：$dirPath');
      }
      final out = <FileEntry>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (out.length >= _maxListEntries) break;
        final stat = await entity.stat();
        out.add(FileEntry(
          name: entity.path.replaceAll('\\', '/').split('/').last,
          path: entity.path,
          isDirectory: stat.type == FileSystemEntityType.directory,
          size: stat.size,
          modified: stat.modified.toIso8601String(),
        ));
      }
      out.sort((FileEntry a, FileEntry b) => a.name.compareTo(b.name));
      return FileOpResult.ok(
        'list',
        out.map((FileEntry e) => e.toJson()).toList(),
      );
    } on DeviceFileException catch (e) {
      return FileOpResult.fail('list', e.message);
    } on Object catch (e) {
      return FileOpResult.fail('list', e.toString());
    }
  }

  /// 读取文本（有字节上限，真实 dart:io）。
  Future<FileOpResult> read(String filePath) async {
    final g = await _guard('read');
    if (g.needsPermission) return g;
    try {
      _guardPath(filePath);
      final file = File(filePath);
      if (!await file.exists()) {
        return FileOpResult.fail('read', '文件不存在：$filePath');
      }
      final length = await file.length();
      if (length > _maxReadBytes) {
        return FileOpResult.fail('read', '文件超过读取上限：$length > $_maxReadBytes');
      }
      final text = await file.readAsString();
      return FileOpResult.ok('read', <String, dynamic>{
        'path': filePath,
        'size': length,
        'text': text,
      });
    } on DeviceFileException catch (e) {
      return FileOpResult.fail('read', e.message);
    } on Object catch (e) {
      return FileOpResult.fail('read', e.toString());
    }
  }

  /// 写入文本（真实 dart:io；父目录自动创建）。
  Future<FileOpResult> write(String filePath, String content) async {
    final g = await _guard('write');
    if (g.needsPermission) return g;
    try {
      _guardPath(filePath, requireWritable: true);
      final file = File(filePath);
      final parent = file.parent;
      if (!await parent.exists()) {
        await parent.create(recursive: true);
      }
      await file.writeAsString(content);
      return FileOpResult.ok('write', <String, dynamic>{
        'path': filePath,
        'size': await file.length(),
      });
    } on DeviceFileException catch (e) {
      return FileOpResult.fail('write', e.message);
    } on Object catch (e) {
      return FileOpResult.fail('write', e.toString());
    }
  }

  Future<FileOpResult> mkdir(String dirPath) async {
    final g = await _guard('mkdir');
    if (g.needsPermission) return g;
    try {
      _guardPath(dirPath, requireWritable: true);
      final dir = await Directory(dirPath).create(recursive: true);
      return FileOpResult.ok('mkdir', <String, dynamic>{'path': dir.path});
    } on DeviceFileException catch (e) {
      return FileOpResult.fail('mkdir', e.message);
    } on Object catch (e) {
      return FileOpResult.fail('mkdir', e.toString());
    }
  }

  Future<FileOpResult> copy(String src, String dst) async {
    final g = await _guard('copy');
    if (g.needsPermission) return g;
    try {
      _guardPath(src);
      _guardPath(dst, requireWritable: true);
      final file = File(src);
      if (!await file.exists()) {
        return FileOpResult.fail('copy', '源文件不存在：$src');
      }
      await File(dst).parent.create(recursive: true);
      final copied = await file.copy(dst);
      return FileOpResult.ok('copy', <String, dynamic>{
        'from': src,
        'to': copied.path,
        'size': await copied.length(),
      });
    } on DeviceFileException catch (e) {
      return FileOpResult.fail('copy', e.message);
    } on Object catch (e) {
      return FileOpResult.fail('copy', e.toString());
    }
  }

  Future<FileOpResult> move(String src, String dst) async {
    final g = await _guard('move');
    if (g.needsPermission) return g;
    try {
      _guardPath(src, requireWritable: true);
      _guardPath(dst, requireWritable: true);
      final file = File(src);
      if (!await file.exists()) {
        return FileOpResult.fail('move', '源文件不存在：$src');
      }
      await File(dst).parent.create(recursive: true);
      final moved = await file.rename(dst);
      return FileOpResult.ok('move', <String, dynamic>{
        'from': src,
        'to': moved.path,
      });
    } on DeviceFileException catch (e) {
      return FileOpResult.fail('move', e.message);
    } on Object catch (e) {
      return FileOpResult.fail('move', e.toString());
    }
  }

  /// 删除：移入隔离区，绝不物理 unlink（与后端 sandbox.check_file_delete 一致）。
  Future<FileOpResult> delete(String path) async {
    final g = await _guard('delete');
    if (g.needsPermission) return g;
    try {
      _guardPath(path, requireWritable: true);
      final entity = File(path);
      final dir = Directory(path);
      final bool isDir = await dir.exists();
      if (!isDir && !await entity.exists()) {
        return FileOpResult.fail('delete', '目标不存在：$path');
      }
      final roots =
          _gateway.roots().where((DeviceRoot r) => r.writable).toList();
      if (roots.isEmpty) {
        return FileOpResult.fail('delete', '无可写根，无法建立隔离区');
      }
      final qdir = Directory('${roots.first.path}/.tangram_quarantine');
      if (!await qdir.exists()) {
        await qdir.create(recursive: true);
      }
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final name = path
          .replaceAll('\\', '/')
          .split('/')
          .where((String s) => s.isNotEmpty)
          .last;
      final target = '${qdir.path}/$stamp-$name';
      if (isDir) {
        await dir.rename(target);
      } else {
        await entity.rename(target);
      }
      return FileOpResult.ok('delete', <String, dynamic>{
        'from': path,
        'quarantine': target,
        'physical_delete': false,
      });
    } on DeviceFileException catch (e) {
      return FileOpResult.fail('delete', e.message);
    } on Object catch (e) {
      return FileOpResult.fail('delete', e.toString());
    }
  }

  /// 按文件名关键字递归搜索（真实 dart:io，有深度与结果上限）。
  Future<FileOpResult> search(String rootPath, String keyword) async {
    final g = await _guard('search');
    if (g.needsPermission) return g;
    try {
      _guardPath(rootPath);
      final dir = Directory(rootPath);
      if (!await dir.exists()) {
        return FileOpResult.fail('search', '目录不存在：$rootPath');
      }
      final out = <FileEntry>[];
      await for (final entity
          in dir.list(recursive: true, followLinks: false)) {
        if (out.length >= _maxSearchResults) break;
        final name = entity.path.replaceAll('\\', '/').split('/').last;
        if (!name.toLowerCase().contains(keyword.toLowerCase())) continue;
        final stat = await entity.stat();
        out.add(FileEntry(
          name: name,
          path: entity.path,
          isDirectory: stat.type == FileSystemEntityType.directory,
          size: stat.size,
          modified: stat.modified.toIso8601String(),
        ));
      }
      return FileOpResult.ok(
        'search',
        out.map((FileEntry e) => e.toJson()).toList(),
      );
    } on DeviceFileException catch (e) {
      return FileOpResult.fail('search', e.message);
    } on Object catch (e) {
      return FileOpResult.fail('search', e.toString());
    }
  }

  /// 列出目录下最大的 N 个文件（DSH 示例能力：「列出下载目录最大的 5 个文件」）。
  Future<FileOpResult> largestFiles(String rootPath, int n) async {
    final listed = await list(rootPath);
    if (!listed.ok) return listed;
    final entries = (listed.data as List)
        .map((dynamic e) => e as Map<String, dynamic>)
        .where((Map<String, dynamic> e) => e['is_directory'] != true)
        .toList();
    entries.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        (b['size'] as int).compareTo(a['size'] as int));
    return FileOpResult.ok(
      'largest_files',
      entries.take(n < 0 ? 0 : n).toList(),
    );
  }

  /// 统一 JSON-RPC 分发入口（供桥协议 device_file 域调用）。
  Future<FileOpResult> dispatch(
      String action, Map<String, dynamic> args) async {
    switch (action) {
      case 'status':
        return FileOpResult.ok('status', <String, dynamic>{
          'access': (await _gateway.check()).name,
          'roots': roots.map((DeviceRoot r) => r.toJson()).toList(),
        });
      case 'request_access':
        return FileOpResult.ok(
            'request_access', (await _gateway.request()).name);
      case 'list':
        return list((args['path'] ?? '').toString());
      case 'read':
        return read((args['path'] ?? '').toString());
      case 'write':
        return write((args['path'] ?? '').toString(),
            (args['content'] ?? '').toString());
      case 'mkdir':
        return mkdir((args['path'] ?? '').toString());
      case 'copy':
        return copy(
            (args['from'] ?? '').toString(), (args['to'] ?? '').toString());
      case 'move':
        return move(
            (args['from'] ?? '').toString(), (args['to'] ?? '').toString());
      case 'delete':
        return delete((args['path'] ?? '').toString());
      case 'search':
        return search((args['path'] ?? '').toString(),
            (args['keyword'] ?? '').toString());
      case 'largest_files':
        return largestFiles(
            (args['path'] ?? '').toString(), (args['n'] ?? 5) as int);
      default:
        return FileOpResult.fail('dispatch', '未知动作：$action');
    }
  }

  /// 供测试/演示：静态安全校验，不触碰磁盘。
  static bool isPathSafe(String path, List<String> authorizedRoots) {
    if (_hasTraversal(path)) return false;
    final abs = normalize(File(path).absolute.path);
    return authorizedRoots
        .map((String r) => normalize(r))
        .any((String r) => abs == r || abs.startsWith('$r/'));
  }
}
