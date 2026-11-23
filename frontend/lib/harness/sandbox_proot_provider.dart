/// proot 沙箱适配器：把现有 [ProotSandbox] 包成 [SandboxProvider]。
///
/// 不改 proot 内部行为（下载 / 解包 / 执行链路原样），只包一层：
/// 统一接口、超时与输出上限、接管门禁、guest 路径映射。
///
/// 单独成文件的原因：`proot_sandbox.dart` 经 `store.dart` →
/// `path_provider` → Flutter `dart:ui`，纯 Dart VM 里加载不起来；
/// 接口与注册表留在 `sandbox_provider.dart`（纯 Dart），VM 断言脚本
/// 才能直接验证核心语义；本适配器由 `flutter analyze` 与 flutter_test
/// 覆盖（本机跑不了 flutter test：llamadart .so 是 arm64、宿主 x64）。
import 'dart:io';

import 'proot_sandbox.dart';
import 'sandbox_provider.dart';
import 'sandbox_takeover.dart';

/// proot 用户态后端：Android 本地 Linux（proot + Ubuntu/Alpine rootfs）。
class ProotSandboxProvider extends SandboxProvider {
  ProotSandboxProvider(this.proot, {SandboxTakeover? takeover}) {
    this.takeover = takeover;
  }

  final ProotSandbox proot;

  @override
  SandboxProviderKind get kind => SandboxProviderKind.proot;

  @override
  String get name => '内置沙箱（proot + ${proot.distroLabel}）';

  @override
  Future<Map<String, dynamic>> start() async {
    if (proot.installed) {
      return <String, dynamic>{
        'ok': true,
        'kind': kind.name,
        'profile': proot.profile,
        'distro': proot.distroLabel,
      };
    }
    return <String, dynamic>{
      'ok': false,
      'kind': kind.name,
      'status': 'not-installed',
      'error': 'Linux 用户态未安装：请先在「沙箱」页安装 '
          '${proot.distroLabel}（真实下载 proot + rootfs）。',
    };
  }

  @override
  Future<Map<String, dynamic>> stop() async => <String, dynamic>{
        'ok': true,
        'kind': kind.name,
        'note': 'proot 用户态无常驻进程；stop 仅作状态复位。',
      };

  @override
  Future<Map<String, dynamic>> status() async {
    final Map<String, dynamic> st = proot.status();
    return <String, dynamic>{
      ...st,
      'kind': kind.name,
      'takeover_active': takeover?.isActive ?? false,
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
    if (!proot.installed) {
      return SandboxExecResult.notInstalled(
        kind: kind,
        detail: 'Linux 用户态未安装，无法执行：请先在「沙箱」页安装 '
            '${proot.distroLabel}。',
      );
    }
    final Map<String, dynamic>? r = await proot.run(
      command,
      cwd,
      timeout: timeout,
    );
    if (r == null) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: 'Linux 环境启动失败（proot 可执行文件不可用）。',
        cwd: cwd,
      );
    }
    final String stdoutAll = (r['stdout'] ?? '').toString();
    final String stderrAll = (r['stderr'] ?? '').toString();
    final bool truncated = stdoutAll.length > maxOutputChars ||
        stderrAll.length > maxOutputChars;
    final int exitCode = r['exit_code'] is num
        ? (r['exit_code'] as num).toInt()
        : (r['ok'] == true ? 0 : 1);
    return SandboxExecResult(
      ok: r['ok'] == true,
      kind: kind,
      stdout: SandboxProvider.capOutput(stdoutAll, maxOutputChars),
      stderr: SandboxProvider.capOutput(stderrAll, maxOutputChars),
      exitCode: exitCode,
      truncated: truncated,
      status: r['ok'] == true ? 'ok' : 'error',
      error: (r['error'] ?? '').toString(),
      cwd: (r['cwd'] ?? cwd).toString(),
    );
  }

  /// guest 路径 → 宿主真实路径：`/workspace/...` 走 App 沙箱工作区，
  /// 其余走 rootfs；含 `..` 穿越返回 null。
  String? _hostPath(String guestPath) =>
      SandboxProvider.resolveGuestPath(
        rootfsPath: proot.rootfsDir.path,
        workspacePath: proot.store.sub('sandbox').path,
        guestPath: guestPath,
      );

  @override
  Future<Map<String, dynamic>> readFile(
    String guestPath, {
    int maxBytes = 1024 * 1024,
  }) async {
    final String? path = _hostPath(guestPath);
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越界或非法：$guestPath',
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
    final String? path = _hostPath(guestPath);
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越界或非法：$guestPath',
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
    final String? path = _hostPath(guestPath);
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越界或非法：$guestPath',
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
  Future<Map<String, dynamic>> sessionState() async {
    final Map<String, dynamic> st = proot.status();
    return <String, dynamic>{
      'kind': kind.name,
      'running': st['installing'] == true,
      'installed': proot.installed,
      'profile': proot.profile,
      'distro': proot.distroLabel,
      'step': st['step'],
      'note': 'proot 用户态无独立图形屏幕；会话状态即终端执行状态。',
    };
  }

  @override
  Future<Map<String, dynamic>> selfCheck() async {
    final bool binOk = proot.prootBin.existsSync() &&
        proot.prootBin.lengthSync() > 100000;
    final bool shOk = File('${proot.rootfsDir.path}/bin/sh').existsSync() ||
        Link('${proot.rootfsDir.path}/bin/sh').existsSync();
    final bool ok = proot.installed && binOk && shOk;
    return <String, dynamic>{
      'ok': ok,
      'kind': kind.name,
      'installed': proot.installed,
      'proot_binary': binOk,
      'rootfs_sh': shOk,
      if (!ok)
        'error': proot.installed
            ? 'proot 二进制或 rootfs /bin/sh 缺失'
            : 'Linux 用户态未安装',
    };
  }
}
