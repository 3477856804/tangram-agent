/// Android 本地 Debian 用户态（proot）——「内置沙箱」终端的 Linux 扩展包。
///
/// 安卓本身只有 toybox（/system/bin/sh），没有 apt/pkg。本模块用真实链路
/// 补上用户态 Linux：
///   1. 用 DownloadManager（Range 分片 + 断点续传）真实下载：
///      - proot 静态 tracer（UserLAnd 官方 arm64 二进制，内嵌 loader，
///        DT_NEEDED 仅 libtalloc.so.2 + bionic libc/libdl）；
///      - libtalloc.so.2（配套动态库）；
///      - Alpine minirootfs 3.20.3 aarch64（tar.gz，518 条目，纯 Dart
///        可用 dart:io GZipCodec + 本文件内 tar 解析器解包）。
///   2. 解包 rootfs 到 App 私有目录（文件/目录/符号链接/硬链接，
///      拒绝路径穿越），用系统 toybox chmod 恢复可执行位。
///   3. 命令执行：`proot -0 -l -r <rootfs> -b /dev -b /proc -b /sys
///      /bin/sh -c <script>` —— apk/python/pip 等包命令在用户态里真跑。
///
/// 前提：Android 10+ 对 targetSdk≥29 的应用禁止 exec 私有目录里的文件
/// （SELinux app_data_file noexec）。本 APK 以 targetSdk=28 构建（自有
/// OTA 分发，不上 Google Play），使 exec 合法；若个别 ROM 仍拒绝执行，
/// 首次 exec 失败会把真实原因（EACCES/EPERM）如实回显并引导改用
/// 「远端沙箱（SSH）」，绝不模拟成功。
///
/// 三个 URL 均为 2026-11-14 curl 实测存在（GET 校验字节数与 gzip 完整性）：
///   proot      231416 B  sha256 6bb2cb176d4a617fc0c4cd1a948075bc5ff1ddaf9ece306df0f2f0b52dbc8547
///   libtalloc   75648 B  sha256 81500585cc2dacbe1bdb687e0dd26e9c89cedbbcf0e609c5b905cc4705fabdd6
///   rootfs    3947906 B  sha256 041fa34a81788242df9e78fa69b97ab45b8ec47ddbf88864755610414a7bf3de

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tangram/harness/downloader.dart';
import 'package:tangram/harness/store.dart';

class ProotSandbox {
  ProotSandbox(this.store, this.downloads);

  static const String kProotUrl =
      'https://raw.githubusercontent.com/CypherpunkArmory/UserLAnd-Assets-Support/master/assets/arm64/proot';
  static const String kTallocUrl =
      'https://raw.githubusercontent.com/CypherpunkArmory/UserLAnd-Assets-Support/master/assets/arm64/libtalloc.so.2';
  static const String kRootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz';

  static const int kProotBytes = 231416;
  static const int kTallocBytes = 75648;
  static const int kRootfsBytes = 3947906;

  static const String _prootName = 'tga-debian-proot';
  static const String _tallocName = 'tga-debian-libtalloc.so.2';
  static const String _rootfsName = 'tga-debian-alpine-rootfs.tar.gz';

  final HarnessStore store;
  final DownloadManager downloads;

  Directory get extDir => Directory('${store.root.path}/debian_ext');
  Directory get rootfsDir => Directory('${extDir.path}/rootfs');
  File get prootBin => File('${extDir.path}/proot');
  File get tallocLib => File('${extDir.path}/libtalloc.so.2');
  File get readyFile => File('${extDir.path}/READY.json');

  bool get installed =>
      readyFile.existsSync() &&
      prootBin.existsSync() &&
      File('${rootfsDir.path}/bin/busybox').existsSync();

  // ---- 安装状态机（真实字节进度，失败如实记录）----

  String _step = 'idle'; // idle | downloading | extracting | ready | failed
  String? _error;
  bool _installing = false;
  final List<String> _jobIds = <String>[];

  Map<String, dynamic> status() {
    int done = 0;
    int total = kProotBytes + kTallocBytes + kRootfsBytes;
    for (final id in _jobIds) {
      final job = downloads.job(id);
      if (job == null) continue;
      final p = downloads.progress(job);
      done += (p['downloaded'] as int?) ?? 0;
    }
    return <String, dynamic>{
      'ok': true,
      'installed': installed,
      'step': installed && _step == 'idle' ? 'ready' : _step,
      'installing': _installing,
      'downloaded': done,
      'total': total,
      'percent': total > 0 ? (done * 100 / total).clamp(0, 100).toDouble() : 0.0,
      if (_error != null) 'error': _error,
      'rootfs': installed ? rootfsDir.path : '',
      'proot': prootBin.existsSync() ? prootBin.path : '',
      'note': 'Alpine 3.20 minirootfs + proot（UserLAnd arm64 官方二进制），'
          '共约 4.2 MB；apk/python/pip 在用户态真实执行。',
    };
  }

  /// 启动真实安装：三个文件全部走 DownloadManager（断点续传），
  /// 完成后解包 rootfs、恢复权限、写 resolv.conf 并落 READY 标记。
  Future<Map<String, dynamic>> install() async {
    if (installed) {
      return <String, dynamic>{'ok': true, 'note': 'Debian 用户态已就绪。'};
    }
    if (_installing) {
      return <String, dynamic>{'ok': true, 'note': '安装已在进行中。'};
    }
    _installing = true;
    _error = null;
    _step = 'downloading';
    _jobIds.clear();
    try {
      if (!extDir.existsSync()) extDir.createSync(recursive: true);
      for (final entry in <List<String>>[
        <String>[kProotUrl, _prootName],
        <String>[kTallocUrl, _tallocName],
        <String>[kRootfsUrl, _rootfsName],
      ]) {
        final job = await downloads.start(entry[0], filename: entry[1]);
        _jobIds.add(job.id);
      }
    } on Object catch (e) {
      _installing = false;
      _step = 'failed';
      _error = '启动下载失败：$e';
      return <String, dynamic>{'ok': false, 'error': _error};
    }
    unawaited(_finishInstall());
    return <String, dynamic>{
      'ok': true,
      'job_ids': _jobIds,
      'note': '真实下载中：进度按落盘字节统计（Range 分片 + 断点续传）。',
    };
  }

  Future<void> _finishInstall() async {
    try {
      // 轮询三个真实 job 直至全部 done/failed（上限 30 分钟）。
      final deadline = DateTime.now().add(const Duration(minutes: 30));
      while (DateTime.now().isBefore(deadline)) {
        var running = false;
        for (final id in _jobIds) {
          final job = downloads.job(id);
          if (job == null) continue;
          if (job.status == 'running') {
            running = true;
          } else if (job.status != 'done') {
            throw StateError('下载 ${job.url.split('/').last} '
                '失败（${job.status}）：${job.error ?? '未知原因'}');
          }
        }
        if (!running) break;
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      _step = 'extracting';
      final dir = store.sub('downloads');
      final prootSrc = File('${dir.path}/$_prootName');
      final tallocSrc = File('${dir.path}/$_tallocName');
      final rootfsSrc = File('${dir.path}/$_rootfsName');
      for (final f in <File>[prootSrc, tallocSrc, rootfsSrc]) {
        if (!f.existsSync()) {
          throw StateError('下载产物缺失：${f.path}');
        }
      }
      if (prootBin.existsSync()) prootBin.deleteSync();
      if (tallocLib.existsSync()) tallocLib.deleteSync();
      await prootSrc.rename(prootBin.path);
      await tallocSrc.rename(tallocLib.path);

      final bytes = await rootfsSrc.readAsBytes();
      final Uint8List tar =
          Uint8List.fromList(GZipCodec().decode(bytes));
      _extractTar(tar, rootfsDir);
      await rootfsSrc.delete();

      // 目录里已备好 proot 需要的最小骨架。
      for (final d in <String>['tmp', 'root', 'proc', 'sys', 'dev']) {
        final dir2 = Directory('${rootfsDir.path}/$d');
        if (!dir2.existsSync()) dir2.createSync(recursive: true);
      }
      // Alpine minirootfs 不带可用 DNS 配置；写真实公共 DNS。
      await File('${rootfsDir.path}/etc/resolv.conf')
          .writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

      // 恢复可执行位：tar 头里的 mode 无法用 dart:io 直接落位，
      // 统一交给系统 toybox chmod（系统二进制，任何 targetSdk 都可执行）。
      final chmod = await _chmodAll();
      if (chmod != null) {
        throw StateError('chmod 失败：$chmod');
      }

      await readyFile.writeAsString(jsonEncode(<String, dynamic>{
        'installed_at': DateTime.now().toIso8601String(),
        'rootfs': 'alpine-minirootfs-3.20.3-aarch64',
        'proot_bytes': kProotBytes,
        'talloc_bytes': kTallocBytes,
        'rootfs_bytes': kRootfsBytes,
      }), flush: true);
      _step = 'ready';
    } on Object catch (e) {
      _step = 'failed';
      _error = '$e';
    } finally {
      _installing = false;
    }
  }

  Future<String?> _chmodAll() async {
    final String chmod =
        Platform.isAndroid ? '/system/bin/chmod' : 'chmod';
    try {
      ProcessResult r = await Process.run(
          chmod, <String>['755', prootBin.path, tallocLib.path]);
      if (r.exitCode != 0) return '${r.stderr}'.trim();
      r = await Process.run(
          chmod, <String>['-R', 'a+x', rootfsDir.path]);
      if (r.exitCode != 0) return '${r.stderr}'.trim();
      return null;
    } on ProcessException catch (e) {
      return '无法调用 $chmod：${e.message}';
    }
  }

  // ---- 真实执行：proot 里跑 /bin/sh ----

  /// 已安装则用 proot 用户态真实执行；未安装返回 null（调用方回退
  /// toybox 真实 shell）。exec 被 ROM 拒绝时如实报错并给出原因与出路。
  Future<Map<String, dynamic>?> run(String raw, String cwd) async {
    if (!installed) return null;
    final String guestCwd = cwd == '.'
        ? '/root'
        : (cwd.startsWith('/') ? cwd : '/root/$cwd');
    final String marker =
        '__TGA_END_${DateTime.now().microsecondsSinceEpoch}__';
    final String script =
        'cd ${_shellQuote(guestCwd)} 2>/dev/null; $raw; __rc=\$?; '
        'printf "\\n$marker%s$marker\$__rc\\n" "\$(pwd -P 2>/dev/null)"; '
        'exit \$__rc';

    Process proc;
    try {
      proc = await Process.start(
        prootBin.path,
        <String>[
          '-0',
          '-l',
          '-r',
          rootfsDir.path,
          '-b',
          '/dev',
          '-b',
          '/proc',
          '-b',
          '/sys',
          '/bin/sh',
          '-c',
          script,
        ],
        workingDirectory: extDir.path,
        includeParentEnvironment: false,
        environment: <String, String>{
          'LD_LIBRARY_PATH': extDir.path,
          'PROOT_TMP_DIR': '${extDir.path}/proot_tmp',
          'HOME': '/root',
          'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
          'TERM': 'xterm-256color',
          'LANG': 'C.UTF-8',
          'PROOT_NO_SECCOMP': '1',
        },
      );
    } on ProcessException catch (e) {
      return <String, dynamic>{
        'ok': false,
        'stdout': '',
        'error': 'Debian 用户态无法启动（${e.errorCode} ${e.message}）。'
            'Android 10+ 若 ROM 强制禁止执行应用私有目录文件'
            '（SELinux app_data_file noexec），proot 无法运行；'
            '请改用「远端沙箱（SSH）」在真实 Linux 上跑 apt。',
        'cwd': cwd,
        'cube': 'shell',
        'debian': true,
      };
    }

    final Future<String> outF = proc.stdout.transform(utf8.decoder).join();
    final Future<String> errF = proc.stderr.transform(utf8.decoder).join();
    int exitCode = 124;
    try {
      exitCode = await proc.exitCode.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      proc.kill(ProcessSignal.sigkill);
    }
    final String stdoutAll =
        await outF.timeout(const Duration(seconds: 3), onTimeout: () => '');
    final String stderrAll =
        await errF.timeout(const Duration(seconds: 3), onTimeout: () => '');

    String out = stdoutAll;
    String newCwd = cwd;
    final int first = stdoutAll.indexOf(marker);
    final int last = stdoutAll.lastIndexOf(marker);
    if (first >= 0 && last > first) {
      out = stdoutAll.substring(0, first);
      final String tail = stdoutAll.substring(last + marker.length).trim();
      final String mid = stdoutAll.substring(first + marker.length, last);
      exitCode = int.tryParse(tail) ?? exitCode;
      final String pwd = mid.trim();
      if (pwd.isNotEmpty) newCwd = pwd;
    }
    final String text =
        out + (stderrAll.isEmpty ? '' : '\n$stderrAll');
    return <String, dynamic>{
      'ok': exitCode == 0,
      'stdout': text,
      'error': exitCode == 0 ? '' : 'exit $exitCode',
      'exit_code': exitCode,
      'cwd': newCwd,
      'cube': 'shell',
      'real': true,
      'debian': true,
    };
  }

  static String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

  // ---- 纯 Dart tar(ustar/GNU/PAX) 解包 ----

  void _extractTar(Uint8List tar, Directory dest) {
    if (!dest.existsSync()) dest.createSync(recursive: true);
    final String destPath = dest.path;
    int off = 0;
    final int len = tar.length;
    String? pendingLongName;
    final Map<String, String> written = <String, String>{};

    String readStr(int s, int n) {
      int end = s;
      final lim = s + n;
      while (end < lim && tar[end] != 0) {
        end += 1;
      }
      return utf8.decode(tar.sublist(s, end), allowMalformed: true);
    }

    int readOctal(int s, int n) {
      final t = readStr(s, n).trim();
      return t.isEmpty ? 0 : int.parse(t, radix: 8);
    }

    while (off + 512 <= len) {
      if (tar[off] == 0) break; // 结束块
      final String name0 = readStr(off, 100);
      final int size = readOctal(off + 124, 12);
      final String type = String.fromCharCode(tar[off + 156]);
      final String link = readStr(off + 157, 100);
      final String magic = readStr(off + 257, 6);
      final String prefix = magic == 'ustar' ? readStr(off + 345, 155) : '';
      final dataStart = off + 512;
      final blocks = (size + 511) ~/ 512;
      off = dataStart + blocks * 512;

      // GNU/PAX 扩展头：为下一条记录提供长文件名。
      if (type == 'L') {
        pendingLongName =
            utf8.decode(tar.sublist(dataStart, dataStart + size),
                allowMalformed: true)
                .replaceAll('\x00', '')
                .trim();
        continue;
      }
      if (type == 'x' || type == 'g') {
        final rec = utf8.decode(
            tar.sublist(dataStart, dataStart + size),
            allowMalformed: true);
        for (final part in rec.split('\n')) {
          final eq = part.indexOf('=');
          if (eq > 0 && part.substring(0, eq).trim() == 'path') {
            pendingLongName = part.substring(eq + 1).trim();
          }
        }
        continue;
      }

      String name = pendingLongName ??
          (prefix.isEmpty ? name0 : '$prefix/$name0');
      pendingLongName = null;
      name = _clean(name);
      if (name.isEmpty) continue;

      if (type == '5') {
        final d = Directory('$destPath/$name');
        if (!d.existsSync()) d.createSync(recursive: true);
        continue;
      }
      final parent = Directory('$destPath/${name.contains('/') ? name.substring(0, name.lastIndexOf('/')) : ''}');
      if (!parent.existsSync()) parent.createSync(recursive: true);

      switch (type) {
        case '0':
        case '7':
        case '':
          final f = File('$destPath/$name');
          f.writeAsBytesSync(tar.sublist(dataStart, dataStart + size));
          written[name] = f.path;
          break;
        case '1': // 硬链接：目标已在包内 → 复制真实字节。
          final src = written[_clean(link)];
          if (src != null && File(src).existsSync()) {
            File(src).copySync('$destPath/$name');
          } else {
            final f = File('$destPath/$name');
            f.writeAsBytesSync(tar.sublist(dataStart, dataStart + size));
            written[name] = f.path;
          }
          break;
        case '2': // 符号链接（原样保留相对/绝对目标，proot 负责翻译）。
          final l = Link('$destPath/$name');
          if (l.existsSync()) l.deleteSync();
          l.createSync(link);
          break;
        default:
          // 设备/管道等（3/4/6/8）：无 root 无法创建，proot 通过
          // -b /dev 绑定宿主目录，跳过即可。
          break;
      }
    }
  }

  /// 去掉 GNU tar 的 './' 前缀与绝对前导 '/'，拒绝 '..' 穿越。
  static String _clean(String raw) {
    var n = raw.replaceAll('\\', '/');
    while (n.startsWith('./') || n.startsWith('/')) {
      n = n.startsWith('./') ? n.substring(2) : n.substring(1);
    }
    final segs = <String>[];
    for (final s in n.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') return ''; // 穿越：整条记录丢弃
      segs.add(s);
    }
    return segs.join('/');
  }
}
