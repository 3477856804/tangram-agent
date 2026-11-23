/// 沙箱抽象（SandboxProvider）—— 把「内置沙箱」收到统一 provider 接口。
///
/// 设计来源：Rakazo 的沙箱抽象机制（clean-room：只参考设计思路，
/// 本文件为自行实现，未复制任何第三方源码）。
///
/// 一个 provider 覆盖四组能力：生命周期（start/stop/status）、执行
/// （exec，带超时与输出上限）、文件（read/write/list）、屏幕/会话状态
/// 查询（sessionState）。具体后端（proot 用户态 / 本机宿主 shell /
/// 以后接的远端 SSH）只实现这个接口，上层调用方不再关心是哪套沙箱。
///
/// 本文件刻意只依赖 dart:async / dart:convert / dart:io，不引
/// `proot_sandbox.dart`（后者经 `store.dart` → `path_provider` →
/// Flutter `dart:ui`，纯 Dart VM 里加载不起来）。proot 适配器在
/// `sandbox_proot_provider.dart`；本文件只含接口、注册表与本机后端，
/// 因此 Dart VM 断言脚本可以直接 import 本文件验证核心语义。
///
/// 接管门禁：每个 provider 可挂一个 [SandboxTakeover]；接管生效期间
/// [exec] 直接拒绝并返回 `takeover-active` 状态，不执行命令。
/// 文件读写不受接管影响（人接管时仍需看/改文件）；自动 exec 才被拦。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sandbox_takeover.dart';

/// 沙箱后端种类。
enum SandboxProviderKind {
  /// Android 本地 Linux 用户态（proot + Ubuntu/Alpine rootfs）。
  proot,

  /// 本机宿主 shell（桌面 bash / 安卓 toybox 回落），无用户态隔离。
  local,
}

/// 一次沙箱执行的结果。`status` 取值：
/// `ok` / `error` / `timeout` / `takeover-active` / `not-installed`。
class SandboxExecResult {
  const SandboxExecResult({
    required this.ok,
    required this.kind,
    this.stdout = '',
    this.stderr = '',
    this.exitCode = -1,
    this.timedOut = false,
    this.truncated = false,
    this.status = 'ok',
    this.error = '',
    this.cwd = '.',
  });

  /// 接管期间拒绝自动执行的结果（不执行命令）。
  factory SandboxExecResult.takeoverRefused({
    required SandboxProviderKind kind,
    required String detail,
  }) =>
      SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'takeover-active',
        error: '沙箱正被人工接管，自动执行已暂停：$detail',
      );

  /// 后端未安装/未就绪的结果（不执行命令）。
  factory SandboxExecResult.notInstalled({
    required SandboxProviderKind kind,
    required String detail,
  }) =>
      SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'not-installed',
        error: detail,
      );

  final bool ok;
  final SandboxProviderKind kind;
  final String stdout;
  final String stderr;
  final int exitCode;
  final bool timedOut;

  /// 输出是否因超过上限被截断。
  final bool truncated;
  final String status;
  final String error;
  final String cwd;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'kind': kind.name,
        'status': status,
        'stdout': stdout,
        'stderr': stderr,
        'exit_code': exitCode,
        'timed_out': timedOut,
        'truncated': truncated,
        if (error.isNotEmpty) 'error': error,
        'cwd': cwd,
      };
}

/// listDir 返回的一条文件记录。
class SandboxFileEntry {
  const SandboxFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
        'is_directory': isDirectory,
        'size': size,
      };
}

/// 沙箱后端统一接口。
abstract class SandboxProvider {
  SandboxProviderKind get kind;

  /// 展示名（如 '内置沙箱（proot + Ubuntu 24.04 base）'）。
  String get name;

  /// 人工接管管理器（可为空 = 不设接管门禁；注册表会统一注入）。
  SandboxTakeover? takeover;

  /// 生命周期：确保后端就绪。proot 未安装时返回 ok:false（不自动下载，
  /// 安装由 UI 侧 `proot.install()` 触发）；本机后端恒为就绪。
  Future<Map<String, dynamic>> start();

  /// 生命周期：停止后端。无常驻进程的后端返回 ok:true + 说明即可。
  Future<Map<String, dynamic>> stop();

  /// 状态快照（给 UI / 状态查询用）。
  Future<Map<String, dynamic>> status();

  /// 执行命令。超时强杀、输出超上限截断（`truncated=true`）；接管期间
  /// 拒绝并返回 `takeover-active`，不执行。
  Future<SandboxExecResult> exec(
    String command, {
    String cwd = '.',
    Duration timeout = const Duration(seconds: 60),
    int maxOutputChars = 65536,
  });

  /// 读沙箱内文件。成功返回 {ok:true, content, size}；
  /// 不存在/越界返回 {ok:false, error}。
  Future<Map<String, dynamic>> readFile(
    String guestPath, {
    int maxBytes = 1024 * 1024,
  });

  /// 写沙箱内文件（父目录不存在时自动创建）。返回 {ok, path, size} 或
  /// {ok:false, error}。
  Future<Map<String, dynamic>> writeFile(String guestPath, String content);

  /// 列沙箱内目录。返回 {ok:true, entries:[...]} 或 {ok:false, error}。
  Future<Map<String, dynamic>> listDir(String guestPath);

  /// 屏幕/会话状态查询。proot 用户态无独立图形屏幕，返回终端执行状态
  /// 与安装状态；以后接 Team Computer 式远端桌面时由该后端返回真实
  /// display / 会话信息（接口已预留，不用再改调用方）。
  Future<Map<String, dynamic>> sessionState();

  /// 快速自检（注册表切换前调用）：只做轻量存在性检查，不启动、不下载。
  Future<Map<String, dynamic>> selfCheck();

  /// 接管门禁：接管生效时返回拒绝结果，否则返回 null（放行）。
  SandboxExecResult? takeoverRefusal() {
    final SandboxTakeover? t = takeover;
    if (t == null) return null;
    final SandboxTakeoverLease? lease = t.activeLease;
    if (lease == null) return null;
    return SandboxExecResult.takeoverRefused(
      kind: kind,
      detail: '持有人 ${lease.holder}，原因 ${lease.reason}，'
          '租约 ${lease.id}，剩余 ${lease.remainingSecondsAt(DateTime.now())}s',
    );
  }

  /// 输出上限：超长输出截断并加尾注，调用方凭 `truncated` 判断。
  /// 纯函数，供适配器与检查脚本共用。
  static String capOutput(String text, int maxChars) {
    if (maxChars <= 0) return '';
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n…[输出已截断，共 ${text.length} 字符，上限 $maxChars]';
  }

  /// 沙箱内 guest 路径 → 宿主真实路径（纯函数，供适配器与检查脚本共用）。
  ///
  /// * `/workspace/...` → 工作区目录（App 沙箱 / agent_ws）；
  /// * 其他绝对路径 `/a/b` → rootfs 下的 `/a/b`；
  /// * 相对路径 `a/b` → rootfs 下的 `/root/a/b`。
  /// 含 `..` 穿越的路径返回 null（调用方按越界拒绝）。
  static String? resolveGuestPath({
    required String rootfsPath,
    required String workspacePath,
    required String guestPath,
  }) {
    final String g = guestPath.trim();
    if (g.isEmpty) return null;
    final List<String> segs = <String>[];
    for (final String s in g.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') return null;
      segs.add(s);
    }
    if (segs.isEmpty) return null;
    final String root = rootfsPath.replaceAll(RegExp(r'/+$'), '');
    final String ws = workspacePath.replaceAll(RegExp(r'/+$'), '');
    if (segs.first == 'workspace') {
      if (segs.length == 1) return ws;
      return '$ws/${segs.sublist(1).join('/')}';
    }
    if (g.startsWith('/')) {
      return '$root/${segs.join('/')}';
    }
    return '$root/root/${segs.join('/')}';
  }

  /// 工作区内宿主路径解析（本机后端用）：相对路径落在工作区内，
  /// 绝对路径必须已在工作区内，`..` 穿越返回 null。
  static String? resolveWorkspacePath({
    required String workspacePath,
    required String path,
  }) {
    final String p = path.trim();
    if (p.isEmpty) return null;
    final String ws = workspacePath.replaceAll(RegExp(r'/+$'), '');
    String joined;
    if (p.startsWith('/')) {
      joined = p;
    } else {
      joined = '$ws/$p';
    }
    final List<String> segs = <String>[];
    for (final String s in joined.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (segs.isEmpty) return null;
        segs.removeLast();
        continue;
      }
      segs.add(s);
    }
    final String resolved = '/${segs.join('/')}';
    if (resolved != ws && !resolved.startsWith('$ws/')) return null;
    return resolved;
  }
}

/// 本机宿主 shell 后端：桌面 bash / 安卓 toybox 回落。
/// 无用户态隔离（与 proot 不同），只在 proot 不可用时作执行回落；
/// 命令经 `/bin/sh -c` 真实执行，超时强杀、输出上限截断。
class LocalSandboxProvider extends SandboxProvider {
  LocalSandboxProvider(this.workspace, {SandboxTakeover? takeover}) {
    this.takeover = takeover;
  }

  /// 宿主工作区目录（所有相对路径与文件操作都限定在此目录内）。
  final Directory workspace;

  @override
  SandboxProviderKind get kind => SandboxProviderKind.local;

  @override
  String get name => '本机沙箱（宿主 shell）';

  @override
  Future<Map<String, dynamic>> start() async {
    try {
      if (!await workspace.exists()) {
        await workspace.create(recursive: true);
      }
      return <String, dynamic>{
        'ok': true,
        'kind': kind.name,
        'workspace': workspace.path,
      };
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'kind': kind.name,
        'error': '工作区不可用：$e',
      };
    }
  }

  @override
  Future<Map<String, dynamic>> stop() async => <String, dynamic>{
        'ok': true,
        'kind': kind.name,
        'note': '本机 shell 无常驻进程，无需停止。',
      };

  @override
  Future<Map<String, dynamic>> status() async {
    final Map<String, dynamic> check = await selfCheck();
    return <String, dynamic>{
      'ok': true,
      'kind': kind.name,
      'running': check['ok'] == true,
      'workspace': workspace.path,
      'shell': '/bin/sh',
      if (check['ok'] != true) 'error': check['error'],
    };
  }

  @override
  Future<SandboxExecResult> exec(
    String command, {
    String cwd = '.',
    Duration timeout = const Duration(seconds: 60),
    int maxOutputChars = 65536,
  }) async {
    final SandboxExecResult? refused = takeoverRefusal();
    if (refused != null) return refused;
    if (Platform.isWindows) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: '本机沙箱 exec 仅支持 POSIX shell，Windows 请用远端沙箱。',
        cwd: cwd,
      );
    }
    // exec 前确保工作区存在（start 的同款幂等创建；未 start 就 exec
    // 也不应报「目录不存在」，否则切换自检通过后首次执行仍会失败）。
    try {
      if (!await workspace.exists()) {
        await workspace.create(recursive: true);
      }
    } on Object catch (e) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: '工作区不可用：$e',
        cwd: cwd,
      );
    }
    final String? dir = SandboxProvider.resolveWorkspacePath(
      workspacePath: workspace.path,
      path: cwd,
    );
    if (dir == null) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: '工作目录越出沙箱工作区：$cwd',
        cwd: cwd,
      );
    }
    Process proc;
    try {
      proc = await Process.start(
        '/bin/sh',
        <String>['-c', command],
        workingDirectory: dir,
        runInShell: false,
      );
    } on Object catch (e) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: '宿主 shell 无法启动：$e',
        cwd: cwd,
      );
    }
    final Future<String> outF =
        proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final Future<String> errF =
        proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    bool timedOut = false;
    int exitCode;
    try {
      exitCode = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
      exitCode = 124;
    }
    final String stdoutAll =
        await outF.timeout(const Duration(seconds: 3), onTimeout: () => '');
    final String stderrAll =
        await errF.timeout(const Duration(seconds: 3), onTimeout: () => '');
    final String out = SandboxProvider.capOutput(stdoutAll, maxOutputChars);
    final String err = SandboxProvider.capOutput(stderrAll, maxOutputChars);
    final bool truncated =
        stdoutAll.length > maxOutputChars || stderrAll.length > maxOutputChars;
    return SandboxExecResult(
      ok: !timedOut && exitCode == 0,
      kind: kind,
      stdout: out,
      stderr: err,
      exitCode: exitCode,
      timedOut: timedOut,
      truncated: truncated,
      status: timedOut ? 'timeout' : (exitCode == 0 ? 'ok' : 'error'),
      error: timedOut
          ? '命令超时 ${timeout.inSeconds}s 已强杀'
          : (exitCode == 0 ? '' : 'exit $exitCode'),
      cwd: cwd,
    );
  }

  @override
  Future<Map<String, dynamic>> readFile(
    String guestPath, {
    int maxBytes = 1024 * 1024,
  }) async {
    final String? path = SandboxProvider.resolveWorkspacePath(
      workspacePath: workspace.path,
      path: guestPath,
    );
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越出沙箱工作区：$guestPath',
      };
    }
    final File f = File(path);
    try {
      if (!await f.exists()) {
        return <String, dynamic>{'ok': false, 'error': '文件不存在：$guestPath'};
      }
      final int size = await f.length();
      if (size > maxBytes) {
        return <String, dynamic>{
          'ok': false,
          'error': '文件过大（$size 字节，上限 $maxBytes）：$guestPath',
        };
      }
      return <String, dynamic>{
        'ok': true,
        'path': guestPath,
        'size': size,
        'content': await f.readAsString(),
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '读取失败：$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> writeFile(
    String guestPath,
    String content,
  ) async {
    final String? path = SandboxProvider.resolveWorkspacePath(
      workspacePath: workspace.path,
      path: guestPath,
    );
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越出沙箱工作区：$guestPath',
      };
    }
    try {
      final File f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString(content, flush: true);
      return <String, dynamic>{
        'ok': true,
        'path': guestPath,
        'size': content.length,
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '写入失败：$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> listDir(String guestPath) async {
    final String? path = SandboxProvider.resolveWorkspacePath(
      workspacePath: workspace.path,
      path: guestPath,
    );
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越出沙箱工作区：$guestPath',
      };
    }
    final Directory d = Directory(path);
    try {
      if (!await d.exists()) {
        return <String, dynamic>{'ok': false, 'error': '目录不存在：$guestPath'};
      }
      final List<SandboxFileEntry> entries = <SandboxFileEntry>[];
      await for (final FileSystemEntity e in d.list(followLinks: false)) {
        final String name = e.path.split('/').last;
        int size = 0;
        if (e is File) {
          try {
            size = await e.length();
          } on Object {
            size = 0;
          }
        }
        entries.add(SandboxFileEntry(
          name: name,
          path: '$guestPath/$name',
          isDirectory: e is Directory,
          size: size,
        ));
      }
      entries.sort((SandboxFileEntry a, SandboxFileEntry b) =>
          a.name.compareTo(b.name));
      return <String, dynamic>{
        'ok': true,
        'path': guestPath,
        'entries': entries.map((SandboxFileEntry e) => e.toJson()).toList(),
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '列目录失败：$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> sessionState() async => <String, dynamic>{
        'kind': kind.name,
        'running': true,
        'workspace': workspace.path,
        'note': '本机沙箱无独立屏幕会话；会话状态即宿主终端状态。',
      };

  @override
  Future<Map<String, dynamic>> selfCheck() async {
    if (Platform.isWindows) {
      return <String, dynamic>{
        'ok': false,
        'kind': kind.name,
        'error': '本机沙箱 exec 仅支持 POSIX shell。',
      };
    }
    final bool shellOk = await File('/bin/sh').exists();
    // 工作区尚未创建也算通过：start()/exec() 会幂等创建；只有父目录
    // 也不存在（无法创建）时才算自检失败。
    bool wsOk = await workspace.exists();
    if (!wsOk) {
      try {
        wsOk = await workspace.parent.exists();
      } on Object {
        wsOk = false;
      }
    }
    return <String, dynamic>{
      'ok': shellOk && wsOk,
      'kind': kind.name,
      'shell': shellOk,
      'workspace': wsOk,
      if (!shellOk) 'error': '宿主 /bin/sh 不存在',
      if (shellOk && !wsOk) 'error': '工作区不存在且无法创建：${workspace.path}',
    };
  }
}

/// 沙箱 provider 注册表：注册 / 切换 / 执行入口。
///
/// 切换先自检（[SandboxProvider.selfCheck]），自检失败时回落默认后端
/// 并记录原因（[lastSwitchError] / [lastFallbackReason]），绝不把调用方
/// 丢在一个不可用的后端上。注册表持有唯一的 [SandboxTakeover]，注册时
/// 注入每个 provider，接管门禁因此在所有后端上一致生效。
class SandboxProviderRegistry {
  SandboxProviderRegistry({
    required this.takeover,
    this.defaultKind = SandboxProviderKind.proot,
  });

  final SandboxTakeover takeover;
  final SandboxProviderKind defaultKind;

  final Map<SandboxProviderKind, SandboxProvider Function()> _factories =
      <SandboxProviderKind, SandboxProvider Function()>{};
  SandboxProvider? _current;
  SandboxProviderKind? _currentKind;

  /// 最近一次切换失败的原因（成功切换后清掉）。
  String? lastSwitchError;

  /// 最近一次回落默认后端的原因（成功切换到非默认后端后清掉）。
  String? lastFallbackReason;

  void register(
    SandboxProviderKind kind,
    SandboxProvider Function() factory,
  ) {
    _factories[kind] = factory;
  }

  List<String> get availableKinds =>
      _factories.keys.map((SandboxProviderKind k) => k.name).toList();

  SandboxProvider get current {
    final SandboxProvider? c = _current;
    if (c != null) return c;
    return _build(defaultKind);
  }

  SandboxProviderKind get currentKind => _currentKind ?? defaultKind;

  SandboxProvider _build(SandboxProviderKind kind) {
    final SandboxProvider Function()? factory = _factories[kind];
    if (factory == null) {
      throw StateError('未注册的沙箱后端：${kind.name}');
    }
    final SandboxProvider p = factory();
    p.takeover = takeover;
    _current = p;
    _currentKind = kind;
    return p;
  }

  /// 切换后端：先对候选后端自检；自检失败则回落默认后端（同样先自检），
  /// 回落也失败时返回 ok:false，当前后端保持不变。
  Future<Map<String, dynamic>> switchTo(SandboxProviderKind kind) async {
    final SandboxProvider Function()? factory = _factories[kind];
    if (factory == null) {
      lastSwitchError = '未注册的沙箱后端：${kind.name}';
      return <String, dynamic>{
        'ok': false,
        'error': lastSwitchError,
      };
    }
    final SandboxProvider candidate = factory();
    candidate.takeover = takeover;
    final Map<String, dynamic> check = await candidate.selfCheck();
    if (check['ok'] == true) {
      _current = candidate;
      _currentKind = kind;
      lastSwitchError = null;
      lastFallbackReason = null;
      return <String, dynamic>{'ok': true, 'kind': kind.name};
    }
    final String reason =
        (check['error'] ?? '自检失败').toString();
    lastSwitchError = '${kind.name} 自检失败：$reason';
    if (kind == defaultKind) {
      return <String, dynamic>{
        'ok': false,
        'error': lastSwitchError,
        'kind': kind.name,
      };
    }
    final SandboxProvider Function()? fbFactory = _factories[defaultKind];
    if (fbFactory == null) {
      return <String, dynamic>{
        'ok': false,
        'error': lastSwitchError,
        'kind': kind.name,
      };
    }
    final SandboxProvider fb = fbFactory();
    fb.takeover = takeover;
    final Map<String, dynamic> fbCheck = await fb.selfCheck();
    if (fbCheck['ok'] != true) {
      return <String, dynamic>{
        'ok': false,
        'error': lastSwitchError,
        'fallback_error': (fbCheck['error'] ?? '自检失败').toString(),
        'kind': kind.name,
      };
    }
    _current = fb;
    _currentKind = defaultKind;
    lastFallbackReason = lastSwitchError;
    return <String, dynamic>{
      'ok': true,
      'kind': defaultKind.name,
      'fallback': true,
      'reason': lastFallbackReason,
    };
  }

  /// 执行入口：委托当前后端（接管门禁在后端 exec 内生效）。
  Future<SandboxExecResult> exec(
    String command, {
    String cwd = '.',
    Duration timeout = const Duration(seconds: 60),
    int maxOutputChars = 65536,
  }) =>
      current.exec(
        command,
        cwd: cwd,
        timeout: timeout,
        maxOutputChars: maxOutputChars,
      );

  /// 注册表 + 当前后端的状态快照。
  Future<Map<String, dynamic>> status() async {
    final Map<String, dynamic> currentStatus = await current.status();
    return <String, dynamic>{
      'ok': true,
      'current_kind': currentKind.name,
      'available_kinds': availableKinds,
      'takeover_active': takeover.isActive,
      if (lastSwitchError != null) 'last_switch_error': lastSwitchError,
      if (lastFallbackReason != null)
        'last_fallback_reason': lastFallbackReason,
      'current': currentStatus,
    };
  }
}
