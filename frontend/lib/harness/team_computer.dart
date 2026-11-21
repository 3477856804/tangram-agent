/// Team Computer：真实的本机共享工作区 + 每个智能体独立的浏览器 profile。
///
/// 对照 Rakazo 的 Team Computer 语义，在移动端可真实落地的最小集：
///   * 一台电脑有共享工作区 `shared/` 与每个智能体的 `bots/<id>/`；
///   * 每个智能体拥有独立浏览器 Cookie / 历史（持久化，互不干扰）；
///   * 文件读写全部限制在电脑 home 内，拒绝 `..` 越界；
///   * 检查点 = 真实目录副本 + SHA256 清单；恢复前自动备份当前工作区；
///   * 每个动作追加到 `computer/activity.jsonl`，页面可按电脑查看。
///
/// 真实性边界：
///   * 不提供虚拟机 / 图形桌面 / 真实 Chromium；浏览器是 HTTP 模式，
///     不执行 JavaScript（快照里明确标注 `js=false`）；
///   * 不做跨设备同步，也不谎称已连接云端沙箱；
///   * 系统包安装、Docker 生命周期等能力不在本机实现范围内。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'browser_session.dart';

class TeamComputerService {
  TeamComputerService(Directory root)
      : _base = Directory('${root.path}/computer');

  final Directory _base;
  final Map<String, BrowserSession> _sessions = <String, BrowserSession>{};

  Future<void>? _initFuture;
  List<Map<String, dynamic>>? _computers;
  List<Map<String, dynamic>>? _bots;

  static const int maxFileBytes = 2 * 1024 * 1024;
  static const int maxCheckpointBytes = 300 * 1024 * 1024;
  static const int maxCheckpointEntries = 8000;
  static const int maxActivityRead = 200;

  Future<void> _ensureInit() {
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    await _base.create(recursive: true);
    await Directory('${_base.path}/homes').create(recursive: true);
    await Directory('${_base.path}/checkpoints').create(recursive: true);
    _computers = await _readList('computers.json', 'computers');
    _bots = await _readList('bots.json', 'bots');
  }

  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> p,
  ) async {
    await _ensureInit();
    switch (action) {
      case 'list':
        return _list();
      case 'create':
        return _create(p);
      case 'rename':
        return _rename(p);
      case 'delete':
        return _delete(p);
      case 'bots':
        return _botsOf(p);
      case 'add_bot':
        return _addBot(p);
      case 'remove_bot':
        return _removeBot(p);
      case 'files':
        return _files(p);
      case 'read':
        return _read(p);
      case 'write':
        return _write(p);
      case 'delete_file':
        return _deleteFile(p);
      case 'checkpoint':
        return _checkpoint(p);
      case 'checkpoints':
        return _checkpointList(p);
      case 'restore':
        return _restore(p);
      case 'delete_checkpoint':
        return _deleteCheckpoint(p);
      case 'activity':
        return _activity(p);
      case 'navigate':
        return _navigate(p);
      case 'snapshot':
      case 'state':
        return _snapshot(p);
      case 'act':
        return _act(p);
      case 'clear_browser':
        return _clearBrowser(p);
      case 'close':
        return _close(p);
      default:
        return <String, dynamic>{'ok': false, 'error': '未知电脑动作：$action'};
    }
  }

  // ---- 基础存取 ----

  Future<List<Map<String, dynamic>>> _readList(String name, String key) async {
    final File f = File('${_base.path}/$name');
    if (!await f.exists()) return <Map<String, dynamic>>[];
    try {
      final dynamic decoded = jsonDecode(await f.readAsString());
      if (decoded is Map && decoded[key] is List) {
        return (decoded[key] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } on Object {
      // 损坏记录不冒充数据，按空态处理。
    }
    return <Map<String, dynamic>>[];
  }

  Future<void> _writeList(
    String name,
    String key,
    List<Map<String, dynamic>> items,
  ) async {
    final File f = File('${_base.path}/$name');
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, dynamic>{key: items}),
      flush: true,
    );
    await tmp.rename(f.path);
  }

  Future<void> _saveComputers() =>
      _writeList('computers.json', 'computers', _computers!);

  Future<void> _saveBots() => _writeList('bots.json', 'bots', _bots!);

  String _stamp() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}-'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  String _newId(String prefix) => '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  Map<String, dynamic>? _computerById(String id) {
    for (final Map<String, dynamic> c in _computers!) {
      if ('${c['id']}' == id) return c;
    }
    return null;
  }

  Map<String, dynamic>? _botById(String id) {
    for (final Map<String, dynamic> b in _bots!) {
      if ('${b['id']}' == id) return b;
    }
    return null;
  }

  Directory _home(Map<String, dynamic> computer) =>
      Directory('${_base.path}/homes/${computer['id']}');

  Directory _profileDir(Map<String, dynamic> computer, String botId) =>
      Directory('${_home(computer).path}/.browser-profiles/$botId');

  Future<Map<String, dynamic>> _defaultComputer() async {
    if (_computers!.isNotEmpty) return _computers!.first;
    final Map<String, dynamic> computer = await _createComputer(name: '团队电脑');
    // 首台电脑带一个默认智能体，打开页面即可直接使用浏览器与工作区。
    await _addBotRecord(
      computer: computer,
      name: '助手',
      privateComputer: false,
    );
    return computer;
  }

  Future<Map<String, dynamic>> _createComputer({
    required String name,
    String spaceId = '',
    String kind = 'team',
  }) async {
    final String id = _newId('pc');
    final Map<String, dynamic> record = <String, dynamic>{
      'id': id,
      'name': name,
      'space_id': spaceId,
      'kind': kind,
      'created_at': DateTime.now().toIso8601String(),
      'last_used_at': '',
      'last_checkpoint_rev': '',
      'last_checkpoint_at': '',
    };
    final Directory home = _home(record);
    await Directory('${home.path}/shared').create(recursive: true);
    await Directory('${home.path}/bots').create(recursive: true);
    await Directory('${home.path}/.browser-profiles').create(recursive: true);
    _computers!.add(record);
    await _saveComputers();
    return record;
  }

  Future<Map<String, dynamic>> _addBotRecord({
    required Map<String, dynamic> computer,
    required String name,
    required bool privateComputer,
  }) async {
    final String botId = _newId('bot');
    final Map<String, dynamic> bot = <String, dynamic>{
      'id': botId,
      'computer_id': '${computer['id']}',
      'name': name,
      'private': privateComputer,
      'created_at': DateTime.now().toIso8601String(),
      'last_used_at': '',
    };
    await Directory('${_home(computer).path}/bots/$botId').create(recursive: true);
    await _profileDir(computer, botId).create(recursive: true);
    _bots!.add(bot);
    await _saveBots();
    return bot;
  }

  // ---- 电脑与智能体 ----

  Future<Map<String, dynamic>> _list() async {
    await _defaultComputer();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> c in _computers!) {
      final Map<String, dynamic> stats = await _stats(_home(c));
      final int botCount = _bots!
          .where((Map<String, dynamic> b) => '${b['computer_id']}' == '${c['id']}')
          .length;
      out.add(<String, dynamic>{
        ...c,
        'bot_count': botCount,
        'file_count': stats['files'],
        'bytes': stats['bytes'],
      });
    }
    return <String, dynamic>{
      'ok': true,
      'computers': out,
      'storage': _base.path,
      'js': false,
      'sync': false,
      'note': '本机 Team Computer：共享工作区 + 独立浏览器 profile；'
          '浏览器为 HTTP 模式，不执行 JavaScript。',
    };
  }

  Future<Map<String, dynamic>> _stats(Directory home) async {
    int files = 0;
    int bytes = 0;
    if (!await home.exists()) {
      return <String, dynamic>{'files': 0, 'bytes': 0};
    }
    try {
      await for (final FileSystemEntity e
          in home.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (e.path.contains('/.browser-profiles/')) continue;
        files++;
        bytes += await e.length();
        if (files >= maxCheckpointEntries) break;
      }
    } on Object {
      // 统计失败不影响列表，返回已统计部分。
    }
    return <String, dynamic>{'files': files, 'bytes': bytes};
  }

  Future<Map<String, dynamic>> _create(Map<String, dynamic> p) async {
    final String name = (p['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '电脑名称不能为空'};
    }
    if (_computers!.any((Map<String, dynamic> c) => c['name'] == name)) {
      return <String, dynamic>{'ok': false, 'error': '同名电脑已存在'};
    }
    final String kind = '${p['kind']}' == 'private' ? 'private' : 'team';
    final Map<String, dynamic> computer = await _createComputer(
      name: name,
      spaceId: (p['space_id'] ?? '').toString(),
      kind: kind,
    );
    return <String, dynamic>{'ok': true, 'computer': computer};
  }

  Future<Map<String, dynamic>> _rename(Map<String, dynamic> p) async {
    final Map<String, dynamic>? computer =
        _computerById((p['id'] ?? '').toString());
    if (computer == null) {
      return <String, dynamic>{'ok': false, 'error': '电脑不存在'};
    }
    final String name = (p['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '名称不能为空'};
    }
    computer['name'] = name;
    if (p.containsKey('space_id')) {
      computer['space_id'] = (p['space_id'] ?? '').toString();
    }
    await _saveComputers();
    return <String, dynamic>{'ok': true, 'computer': computer};
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final Map<String, dynamic>? computer =
        _computerById((p['id'] ?? '').toString());
    if (computer == null) {
      return <String, dynamic>{'ok': false, 'error': '电脑不存在'};
    }
    final Directory home = _home(computer);
    if (await home.exists()) await home.delete(recursive: true);
    final Directory checkpoints =
        Directory('${_base.path}/checkpoints/${computer['id']}');
    if (await checkpoints.exists()) await checkpoints.delete(recursive: true);
    for (final Map<String, dynamic> b in _bots!) {
      if ('${b['computer_id']}' != '${computer['id']}') continue;
      _sessions.remove('${b['id']}')?.close();
    }
    _bots!.removeWhere(
      (Map<String, dynamic> b) => '${b['computer_id']}' == '${computer['id']}',
    );
    _computers!.remove(computer);
    await _saveComputers();
    await _saveBots();
    await _log(
      '${computer['id']}',
      '',
      'delete_computer',
      target: '${computer['name']}',
      detail: '删除电脑、工作区与检查点',
    );
    return <String, dynamic>{'ok': true, 'deleted': computer['id']};
  }

  Future<Map<String, dynamic>> _botsOf(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final List<Map<String, dynamic>> bots = _bots!
        .where((Map<String, dynamic> b) =>
            '${b['computer_id']}' == '${computer['id']}')
        .map((Map<String, dynamic> b) => <String, dynamic>{
              ...b,
              'file_count': _botFileCount(computer, '${b['id']}'),
            })
        .toList();
    return <String, dynamic>{
      'ok': true,
      'computer': computer,
      'bots': bots,
      'js': false,
    };
  }

  int _botFileCount(Map<String, dynamic> computer, String botId) {
    final Directory dir = Directory('${_home(computer).path}/bots/$botId');
    if (!dir.existsSync()) return 0;
    int count = 0;
    try {
      for (final FileSystemEntity e
          in dir.listSync(recursive: true, followLinks: false)) {
        if (e is File) count++;
        if (count >= maxCheckpointEntries) break;
      }
    } on Object {
      // 忽略统计异常。
    }
    return count;
  }

  Future<Map<String, dynamic>> _addBot(Map<String, dynamic> p) async {
    final String name = (p['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '智能体名称不能为空'};
    }
    final bool privateComputer = p['private'] == true;
    Map<String, dynamic>? computer =
        _computerById((p['computer_id'] ?? '').toString());
    computer ??= await _defaultComputer();
    if (!privateComputer &&
        _bots!.any((Map<String, dynamic> b) =>
            '${b['computer_id']}' == '${computer!['id']}' &&
            b['name'] == name)) {
      return <String, dynamic>{'ok': false, 'error': '该电脑上已有同名智能体'};
    }
    Map<String, dynamic> target = computer;
    if (privateComputer) {
      target = await _createComputer(
        name: '$name 的电脑',
        kind: 'private',
      );
    }
    final Map<String, dynamic> bot = await _addBotRecord(
      computer: target,
      name: name,
      privateComputer: privateComputer,
    );
    await _log(
      '${target['id']}',
      '${bot['id']}',
      'add_bot',
      target: name,
      detail: privateComputer ? '独立电脑' : '共享 Team Computer',
    );
    return <String, dynamic>{
      'ok': true,
      'bot': bot,
      'computer': target,
      'note': privateComputer
          ? '已创建独立电脑：文件与登录态不与其它智能体共享。'
          : '已加入共享 Team Computer：可访问 shared/ 与自己的 bots/<id>/。',
    };
  }

  Future<Map<String, dynamic>> _removeBot(Map<String, dynamic> p) async {
    final Map<String, dynamic>? bot = _botById((p['bot_id'] ?? '').toString());
    if (bot == null) {
      return <String, dynamic>{'ok': false, 'error': '智能体不存在'};
    }
    final Map<String, dynamic>? computer =
        _computerById('${bot['computer_id']}');
    if (computer == null) {
      return <String, dynamic>{'ok': false, 'error': '所在电脑不存在'};
    }
    final Directory dir =
        Directory('${_home(computer).path}/bots/${bot['id']}');
    if (await dir.exists()) await dir.delete(recursive: true);
    final Directory profile = _profileDir(computer, '${bot['id']}');
    if (await profile.exists()) await profile.delete(recursive: true);
    final BrowserSession? session = _sessions.remove('${bot['id']}');
    session?.close();
    _bots!.remove(bot);
    await _saveBots();
    await _log(
      '${computer['id']}',
      '${bot['id']}',
      'remove_bot',
      target: '${bot['name']}',
      detail: '删除工作区与浏览器 profile',
    );
    return <String, dynamic>{'ok': true, 'removed': bot['id']};
  }

  // ---- 文件 ----

  Directory? _scopeDir(
    Map<String, dynamic> computer,
    String botId,
  ) {
    final Directory home = _home(computer);
    if (botId.isEmpty) return home;
    final Map<String, dynamic>? bot = _botById(botId);
    if (bot == null || '${bot['computer_id']}' != '${computer['id']}') {
      return null;
    }
    return Directory('${home.path}/bots/$botId');
  }

  String? _safePath(Directory root, String relative, {bool guardProfile = true}) {
    final String cleaned = relative.replaceAll('\\', '/').trim();
    if (cleaned.startsWith('/') || cleaned.contains('..')) return null;
    if (guardProfile && cleaned.split('/').contains('.browser-profiles')) {
      return null;
    }
    final String base = root.absolute.path;
    final String full = cleaned.isEmpty ? base : '$base/$cleaned';
    if (full != base && !full.startsWith('$base/')) return null;
    return full;
  }

  Future<Map<String, dynamic>> _files(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final String botId = (p['bot_id'] ?? '').toString().trim();
    final Directory? scope = _scopeDir(computer, botId);
    if (scope == null) {
      return <String, dynamic>{'ok': false, 'error': '智能体不属于该电脑'};
    }
    final String? path = _safePath(
      scope,
      (p['path'] ?? '').toString(),
      guardProfile: false,
    );
    if (path == null) {
      return <String, dynamic>{'ok': false, 'error': '路径越界，已拒绝'};
    }
    final Directory dir = Directory(path);
    if (!await dir.exists()) {
      return <String, dynamic>{'ok': true, 'files': <dynamic>[], 'dirs': <dynamic>[]};
    }
    final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
    final List<String> dirs = <String>[];
    final String homePath = _home(computer).absolute.path;
    try {
      await for (final FileSystemEntity e
          in dir.list(recursive: true, followLinks: false)) {
        if (e.path.contains('/.browser-profiles')) continue;
        final String rel = e.path.substring(homePath.length + 1);
        if (e is Directory) {
          if (dirs.length < 100) dirs.add(rel);
          continue;
        }
        if (e is! File) continue;
        final FileStat st = await e.stat();
        files.add(<String, dynamic>{
          'path': rel,
          'size': st.size,
          'modified': st.modified.toIso8601String(),
        });
        if (files.length >= 500) break;
      }
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '读取目录失败：$e'};
    }
    files.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        '${a['path']}'.compareTo('${b['path']}'));
    return <String, dynamic>{
      'ok': true,
      'files': files,
      'dirs': dirs,
      'computer': computer['id'],
      'bot_id': botId,
    };
  }

  Future<Map<String, dynamic>> _read(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final String botId = (p['bot_id'] ?? '').toString().trim();
    final Directory? scope = _scopeDir(computer, botId);
    if (scope == null) {
      return <String, dynamic>{'ok': false, 'error': '智能体不属于该电脑'};
    }
    final String? path = _safePath(scope, (p['path'] ?? '').toString());
    if (path == null) {
      return <String, dynamic>{'ok': false, 'error': '路径越界或受保护，已拒绝'};
    }
    final File f = File(path);
    if (!await f.exists()) {
      return <String, dynamic>{'ok': false, 'error': '文件不存在'};
    }
    final int size = await f.length();
    if (size > maxFileBytes) {
      return <String, dynamic>{
        'ok': false,
        'error': '文件超过 ${maxFileBytes ~/ (1024 * 1024)}MB，请用沙箱工具处理',
      };
    }
    String text;
    try {
      text = utf8.decode(await f.readAsBytes());
    } on Object {
      return <String, dynamic>{'ok': false, 'error': '不是 UTF-8 文本，拒绝预览'};
    }
    return <String, dynamic>{'ok': true, 'text': text, 'size': size};
  }

  Future<Map<String, dynamic>> _write(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final String botId = (p['bot_id'] ?? '').toString().trim();
    final Directory? scope = _scopeDir(computer, botId);
    if (scope == null) {
      return <String, dynamic>{'ok': false, 'error': '智能体不属于该电脑'};
    }
    final String? path = _safePath(scope, (p['path'] ?? '').toString());
    if (path == null) {
      return <String, dynamic>{'ok': false, 'error': '路径越界或受保护，已拒绝'};
    }
    final String text = (p['text'] ?? p['content'] ?? '').toString();
    if (utf8.encode(text).length > maxFileBytes) {
      return <String, dynamic>{'ok': false, 'error': '文本超过 2MB'};
    }
    final File f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(text, flush: true);
    final String rel = f.path.substring(_home(computer).absolute.path.length + 1);
    await _log(
      '${computer['id']}',
      botId,
      'write_file',
      target: rel,
      detail: '${utf8.encode(text).length} 字节',
    );
    computer['last_used_at'] = DateTime.now().toIso8601String();
    await _saveComputers();
    return <String, dynamic>{'ok': true, 'path': rel};
  }

  Future<Map<String, dynamic>> _deleteFile(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final String botId = (p['bot_id'] ?? '').toString().trim();
    final Directory? scope = _scopeDir(computer, botId);
    if (scope == null) {
      return <String, dynamic>{'ok': false, 'error': '智能体不属于该电脑'};
    }
    final String? path = _safePath(scope, (p['path'] ?? '').toString());
    if (path == null) {
      return <String, dynamic>{'ok': false, 'error': '路径越界或受保护，已拒绝'};
    }
    final File f = File(path);
    if (!await f.exists()) {
      return <String, dynamic>{'ok': false, 'error': '文件不存在'};
    }
    await f.delete();
    final String rel = f.path.substring(_home(computer).absolute.path.length + 1);
    await _log(
      '${computer['id']}',
      botId,
      'delete_file',
      target: rel,
      detail: '删除文件',
    );
    return <String, dynamic>{'ok': true, 'deleted': rel};
  }

  // ---- 检查点 ----

  Directory _checkpointRoot(Map<String, dynamic> computer) =>
      Directory('${_base.path}/checkpoints/${computer['id']}');

  Future<Map<String, dynamic>> _checkpoint(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final String note = (p['note'] ?? '').toString().trim();
    final String rev = 'rev-${_stamp()}';
    final Directory target =
        Directory('${_checkpointRoot(computer).path}/$rev');
    if (await target.exists()) {
      return <String, dynamic>{'ok': false, 'error': '检查点已存在：$rev'};
    }
    final Directory workspace = Directory('${target.path}/workspace');
    await workspace.create(recursive: true);

    int total = 0;
    int count = 0;
    final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
    final List<String> skipped = <String>[];
    final Directory home = _home(computer);
    if (await home.exists()) {
      await for (final FileSystemEntity e
          in home.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        if (e.path.contains('/.browser-profiles/') &&
            (e.path.endsWith('.lock') || e.path.endsWith('-journal'))) {
          continue;
        }
        final int size = await e.length();
        if (total + size > maxCheckpointBytes) {
          skipped.add('超过 ${maxCheckpointBytes ~/ (1024 * 1024)}MB 上限');
          break;
        }
        if (count >= maxCheckpointEntries) {
          skipped.add('超过 $maxCheckpointEntries 个文件上限');
          break;
        }
        final String rel = e.path.substring(home.absolute.path.length + 1);
        final List<int> bytes = await e.readAsBytes();
        final File dest = File('${workspace.path}/$rel');
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(bytes, flush: true);
        files.add(<String, dynamic>{
          'path': rel,
          'size': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
        });
        total += bytes.length;
        count++;
      }
    }

    final Map<String, dynamic> manifest = <String, dynamic>{
      'rev': rev,
      'computer_id': computer['id'],
      'note': note,
      'created_at': DateTime.now().toIso8601String(),
      'total_bytes': total,
      'entries': files.length,
      'files': files,
      'skipped': skipped,
    };
    final File mf = File('${target.path}/manifest.json');
    await mf.writeAsString(jsonEncode(manifest), flush: true);

    computer['last_checkpoint_rev'] = rev;
    computer['last_checkpoint_at'] = manifest['created_at'];
    await _saveComputers();
    await _log(
      '${computer['id']}',
      '',
      'checkpoint',
      target: rev,
      detail: '${files.length} 个文件，$total 字节',
    );
    return <String, dynamic>{
      'ok': true,
      'checkpoint': <String, dynamic>{
        'rev': rev,
        'note': note,
        'created_at': manifest['created_at'],
        'total_bytes': total,
        'entries': files.length,
        'skipped': skipped,
      },
    };
  }

  Future<Map<String, dynamic>> _checkpointList(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final Directory root = _checkpointRoot(computer);
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    if (await root.exists()) {
      await for (final FileSystemEntity e in root.list(followLinks: false)) {
        if (e is! Directory) continue;
        final File mf = File('${e.path}/manifest.json');
        if (!await mf.exists()) continue;
        try {
          final dynamic decoded = jsonDecode(await mf.readAsString());
          if (decoded is! Map) continue;
          out.add(<String, dynamic>{
            'rev': '${decoded['rev'] ?? e.path.split('/').last}',
            'note': '${decoded['note'] ?? ''}',
            'created_at': '${decoded['created_at'] ?? ''}',
            'total_bytes': decoded['total_bytes'] ?? 0,
            'entries': decoded['entries'] ?? 0,
            'skipped': decoded['skipped'] ?? <dynamic>[],
          });
        } on Object {
          // 损坏的清单不展示，避免伪造检查点。
        }
      }
    }
    out.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        '${b['rev']}'.compareTo('${a['rev']}'));
    return <String, dynamic>{
      'ok': true,
      'checkpoints': out,
      'last_rev': computer['last_checkpoint_rev'],
    };
  }

  Future<Map<String, dynamic>> _restore(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final String rev = (p['rev'] ?? '').toString().trim();
    if (rev.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '缺少检查点 rev'};
    }
    final Directory source =
        Directory('${_checkpointRoot(computer).path}/$rev/workspace');
    if (!await source.exists()) {
      return <String, dynamic>{'ok': false, 'error': '检查点不存在：$rev'};
    }
    final Directory home = _home(computer);
    // 恢复前把当前工作区真实备份，避免不可逆丢失。
    if (await home.exists()) {
      final Directory backup = Directory(
        '${_checkpointRoot(computer).path}/pre-restore-${_stamp()}/workspace',
      );
      await backup.parent.create(recursive: true);
      await _copyDir(home, backup);
      await home.delete(recursive: true);
    }
    await home.create(recursive: true);
    await _copyDir(source, home);
    await Directory('${home.path}/shared').create(recursive: true);
    await Directory('${home.path}/bots').create(recursive: true);
    await Directory('${home.path}/.browser-profiles').create(recursive: true);
    for (final Map<String, dynamic> b in _bots!) {
      if ('${b['computer_id']}' != '${computer['id']}') continue;
      final String botId = '${b['id']}';
      await Directory('${home.path}/bots/$botId').create(recursive: true);
      await _profileDir(computer, botId).create(recursive: true);
      final BrowserSession? session = _sessions.remove(botId);
      session?.close();
    }
    computer['last_used_at'] = DateTime.now().toIso8601String();
    await _saveComputers();
    await _log(
      '${computer['id']}',
      '',
      'restore',
      target: rev,
      detail: '恢复工作区（当前内容已自动备份）',
    );
    return <String, dynamic>{
      'ok': true,
      'restored': rev,
      'note': '已恢复检查点；恢复前的工作区已备份在 checkpoints 目录。',
    };
  }

  Future<Map<String, dynamic>> _deleteCheckpoint(Map<String, dynamic> p) async {
    final Map<String, dynamic> computer =
        _computerById((p['computer_id'] ?? '').toString()) ??
            await _defaultComputer();
    final String rev = (p['rev'] ?? '').toString().trim();
    if (rev.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '缺少检查点 rev'};
    }
    final Directory dir = Directory('${_checkpointRoot(computer).path}/$rev');
    if (!await dir.exists()) {
      return <String, dynamic>{'ok': false, 'error': '检查点不存在：$rev'};
    }
    await dir.delete(recursive: true);
    if ('${computer['last_checkpoint_rev']}' == rev) {
      computer['last_checkpoint_rev'] = '';
      computer['last_checkpoint_at'] = '';
      await _saveComputers();
    }
    return <String, dynamic>{'ok': true, 'deleted': rev};
  }

  Future<void> _copyDir(Directory src, Directory dst) async {
    await dst.create(recursive: true);
    await for (final FileSystemEntity e
        in src.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final String rel = e.path.substring(src.absolute.path.length + 1);
      final File dest = File('${dst.path}/$rel');
      await dest.parent.create(recursive: true);
      await e.copy(dest.path);
    }
  }

  // ---- 活动日志 ----

  File get _activityFile => File('${_base.path}/activity.jsonl');

  Future<void> _log(
    String computerId,
    String botId,
    String action, {
    String target = '',
    bool ok = true,
    String detail = '',
  }) async {
    final Map<String, dynamic> entry = <String, dynamic>{
      'computer_id': computerId,
      'bot_id': botId,
      'action': action,
      'target': target,
      'ok': ok,
      'detail': detail,
      'ts': DateTime.now().toIso8601String(),
    };
    try {
      await _activityFile.writeAsString(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
      if (await _activityFile.length() > 1024 * 1024) {
        await _trimActivity();
      }
    } on Object {
      // 日志写入失败不影响主流程。
    }
  }

  Future<void> _trimActivity() async {
    final List<String> lines = await _activityFile.readAsLines();
    final List<String> keep = lines.length > 1000
        ? lines.sublist(lines.length - 1000)
        : lines;
    await _activityFile.writeAsString('${keep.join('\n')}\n', flush: true);
  }

  Future<Map<String, dynamic>> _activity(Map<String, dynamic> p) async {
    final String computerId = (p['computer_id'] ?? '').toString();
    final int limit = (p['limit'] is num)
        ? (p['limit'] as num).toInt().clamp(1, maxActivityRead)
        : 100;
    if (!await _activityFile.exists()) {
      return <String, dynamic>{'ok': true, 'activity': <dynamic>[]};
    }
    final List<String> lines = await _activityFile.readAsLines();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final String line in lines.reversed) {
      if (line.trim().isEmpty) continue;
      try {
        final dynamic decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        if (computerId.isNotEmpty &&
            '${decoded['computer_id']}' != computerId) {
          continue;
        }
        out.add(Map<String, dynamic>.from(decoded));
        if (out.length >= limit) break;
      } on Object {
        // 跳过损坏行。
      }
    }
    return <String, dynamic>{'ok': true, 'activity': out};
  }

  // ---- 浏览器 ----

  Future<Map<String, dynamic>> _sessionFor(String botId) async {
    final Map<String, dynamic>? bot = _botById(botId);
    if (bot == null) {
      return <String, dynamic>{'ok': false, 'error': '智能体不存在：$botId'};
    }
    final Map<String, dynamic>? computer =
        _computerById('${bot['computer_id']}');
    if (computer == null) {
      return <String, dynamic>{'ok': false, 'error': '智能体所在电脑不存在'};
    }
    BrowserSession? session = _sessions[botId];
    if (session == null) {
      final Directory dir = _profileDir(computer, botId);
      await dir.create(recursive: true);
      session = BrowserSession(profileDir: dir);
      _sessions[botId] = session;
    }
    bot['last_used_at'] = DateTime.now().toIso8601String();
    computer['last_used_at'] = bot['last_used_at'];
    await _saveBots();
    await _saveComputers();
    return <String, dynamic>{
      'ok': true,
      'session': session,
      'bot': bot,
      'computer': computer,
    };
  }

  String _safeUrl(String raw) {
    final Uri? uri = Uri.tryParse(raw);
    if (uri == null) return raw;
    if (uri.host.isEmpty) return raw;
    final String path = uri.path.length > 120 ? '${uri.path.substring(0, 120)}…' : uri.path;
    return '${uri.scheme}://${uri.host}$path';
  }

  Future<Map<String, dynamic>> _navigate(Map<String, dynamic> p) async {
    final Map<String, dynamic> handle =
        await _sessionFor((p['bot_id'] ?? '').toString());
    if (handle['ok'] != true) return handle;
    final BrowserSession session = handle['session'] as BrowserSession;
    final Map<String, dynamic> result =
        await session.navigate((p['url'] ?? '').toString());
    await _log(
      '${(handle['computer'] as Map)['id']}',
      '${(handle['bot'] as Map)['id']}',
      'browser_navigate',
      target: _safeUrl('${p['url']}'),
      ok: result['ok'] == true,
      detail: result['ok'] == true
          ? 'HTTP ${result['status']}'
          : '${result['error'] ?? '失败'}',
    );
    return result;
  }

  Future<Map<String, dynamic>> _snapshot(Map<String, dynamic> p) async {
    final Map<String, dynamic> handle =
        await _sessionFor((p['bot_id'] ?? '').toString());
    if (handle['ok'] != true) return handle;
    final BrowserSession session = handle['session'] as BrowserSession;
    await session.load();
    return session.state();
  }

  Future<Map<String, dynamic>> _act(Map<String, dynamic> p) async {
    final Map<String, dynamic> handle =
        await _sessionFor((p['bot_id'] ?? '').toString());
    if (handle['ok'] != true) return handle;
    final BrowserSession session = handle['session'] as BrowserSession;
    final Map<String, String> values = <String, String>{};
    final dynamic rawValues = p['values'];
    if (rawValues is Map) {
      rawValues.forEach((dynamic k, dynamic v) {
        values['$k'] = '$v';
      });
    }
    final String action = (p['action'] ?? '').toString();
    final Map<String, dynamic> result = await session.act(
      action: action,
      ref: (p['ref'] ?? '').toString(),
      value: (p['value'] ?? '').toString(),
      values: values,
    );
    await _log(
      '${(handle['computer'] as Map)['id']}',
      '${(handle['bot'] as Map)['id']}',
      'browser_$action',
      target: (p['ref'] ?? '').toString(),
      ok: result['ok'] == true,
      detail: result['ok'] == true
          ? 'HTTP ${result['status'] ?? ''}'
          : '${result['error'] ?? '失败'}',
    );
    return result;
  }

  Future<Map<String, dynamic>> _clearBrowser(Map<String, dynamic> p) async {
    final String botId = (p['bot_id'] ?? '').toString();
    final Map<String, dynamic>? bot = _botById(botId);
    if (bot == null) {
      return <String, dynamic>{'ok': false, 'error': '智能体不存在'};
    }
    final Map<String, dynamic> handle = await _sessionFor(botId);
    if (handle['ok'] != true) return handle;
    final BrowserSession session = handle['session'] as BrowserSession;
    await session.load();
    await session.clearProfile();
    return <String, dynamic>{
      'ok': true,
      'cleared': botId,
      'note': '已删除该智能体的 Cookie 与浏览历史。',
    };
  }

  Future<Map<String, dynamic>> _close(Map<String, dynamic> p) async {
    final String botId = (p['bot_id'] ?? '').toString();
    final BrowserSession? session = _sessions.remove(botId);
    session?.close();
    return <String, dynamic>{'ok': true, 'closed': botId};
  }

  /// 进程退出时释放所有 HTTP 连接。
  void dispose() {
    for (final BrowserSession s in _sessions.values) {
      s.close();
    }
    _sessions.clear();
  }
}
