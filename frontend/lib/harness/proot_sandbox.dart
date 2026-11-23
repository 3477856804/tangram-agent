/// Android 本地 Linux 用户态（proot）——「内置沙箱」终端的 Linux 扩展包。
/// 新装默认 Ubuntu 24.04 base（与 Termux 同级的普通用户态，仍走 proot，
/// 不是独立内核）；已装 Alpine 3.20 的老环境按 READY.json 里的 profile
/// 继续以 Alpine 运行，不受影响。
///
/// 安卓本身只有 toybox（/system/bin/sh），没有 apt/pkg。本模块用真实链路
/// 补上用户态 Linux：
///   1. 用 http.Client().send 流式真实下载（逐 chunk 累计接收字节并回调
///      上报实时进度，total 取响应 Content-Length，未知传 -1）：
///      - proot 静态 tracer（UserLAnd 官方 arm64 二进制，内嵌 loader，
///        DT_NEEDED 仅 libtalloc.so.2 + bionic libc/libdl）；
///      - libtalloc.so.2（配套动态库）；
///      - Ubuntu base 24.04.5 arm64（默认，29936675 B）或 Alpine
///        minirootfs 3.20.3 aarch64（老环境兼容，3947906 B）；两者都是
///        gzip tar，用 dart:io GZipCodec + 本文件内 tar 解析器解包。
///   2. 解包 rootfs 到 App 私有目录（文件/目录/符号链接/硬链接，
///      拒绝路径穿越），用系统 toybox chmod 恢复可执行位。
///   3. 命令执行：`proot -0 -l -r <rootfs> -b /dev -b /proc -b /sys
///      /bin/sh -c <script>` —— apt/apk/python/pip 等包命令在用户态里真跑。
///
/// 前提：Android 10+ 对 targetSdk≥29 的应用禁止 exec 私有目录里的文件
/// （SELinux app_data_file noexec）。本 APK 以 targetSdk=28 构建（自有
/// OTA 分发，不上 Google Play），使 exec 合法；若个别 ROM 仍拒绝执行，
/// 首次 exec 失败会把真实原因（EACCES/EPERM）如实回显并引导改用
/// 「远端沙箱（SSH）」，绝不模拟成功。
///
/// URL 均为实测存在（GET 校验字节数与 gzip 完整性）：
///   proot      231416 B  sha256 6bb2cb176d4a617fc0c4cd1a948075bc5ff1ddaf9ece306df0f2f0b52dbc8547
///   libtalloc   75648 B  sha256 81500585cc2dacbe1bdb687e0dd26e9c89cedbbcf0e609c5b905cc4705fabdd6
///   ubuntu   29936675 B  https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz
///   alpine    3947906 B  sha256 041fa34a81788242df9e78fa69b97ab45b8ec47ddbf88864755610414a7bf3de


import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:tangram/harness/downloader.dart';
import 'package:tangram/harness/store.dart';

class ProotSandbox {
  ProotSandbox(this.store, this.downloads);

  static const String kProotUrl =
      'https://raw.githubusercontent.com/CypherpunkArmory/UserLAnd-Assets-Support/master/assets/arm64/proot';
  static const String kTallocUrl =
      'https://raw.githubusercontent.com/CypherpunkArmory/UserLAnd-Assets-Support/master/assets/arm64/libtalloc.so.2';

  /// 新装默认 rootfs：Ubuntu 24.04 base arm64（gzip tar，约 30 MB）。
  static const String kUbuntuRootfsUrl =
      'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-arm64.tar.gz';

  /// 老环境兼容：Alpine minirootfs 3.20.3 aarch64。
  static const String kRootfsUrl =
      'https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-minirootfs-3.20.3-aarch64.tar.gz';

  static const int kProotBytes = 231416;
  static const int kTallocBytes = 75648;
  static const int kUbuntuRootfsBytes = 29936675;
  static const int kRootfsBytes = 3947906;

  /// 下载完整性真源：proot 是要被 exec 的二进制，仅比字节长度无法发现
  /// 内容被替换（长度相同的恶意 ELF）。这些值来自官方源实测（2026-11-19）：
  /// proot/talloc 与 UserLAnd 官方资产一致，ubuntu 取自官方 SHA256SUMS，
  /// alpine 取自 Alpine 官方发布。下载后逐字节算 SHA256 比对，不符即拒用。
  static const String kProotSha256 =
      '6bb2cb176d4a617fc0c4cd1a948075bc5ff1ddaf9ece306df0f2f0b52dbc8547';
  static const String kTallocSha256 =
      '81500585cc2dacbe1bdb687e0dd26e9c89cedbbcf0e609c5b905cc4705fabdd6';
  static const String kUbuntuRootfsSha256 =
      'a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2';
  static const String kRootfsSha256 =
      '041fa34a81788242df9e78fa69b97ab45b8ec47ddbf88864755610414a7bf3de';

  static String sha256ForUrl(String url) {
    if (url == kProotUrl) return kProotSha256;
    if (url == kTallocUrl) return kTallocSha256;
    if (url == kUbuntuRootfsUrl) return kUbuntuRootfsSha256;
    if (url == kRootfsUrl) return kRootfsSha256;
    return '';
  }

  /// 新装默认 profile；已装环境的 READY.json 没写 profile 时按 alpine 解释。
  static const String kDefaultProfile = 'ubuntu';

  static const String kUbuntuDistroName = 'ubuntu-base-24.04.5-base-arm64';
  static const String kAlpineDistroName = 'alpine-minirootfs-3.20.3-aarch64';

  static String normalizeProfile(String? raw) {
    final String p = (raw ?? '').trim().toLowerCase();
    return (p == 'alpine' || p == 'ubuntu') ? p : kDefaultProfile;
  }

  static String rootfsUrlFor(String profile) =>
      profile == 'alpine' ? kRootfsUrl : kUbuntuRootfsUrl;

  static int rootfsBytesFor(String profile) =>
      profile == 'alpine' ? kRootfsBytes : kUbuntuRootfsBytes;

  static String rootfsDistroFor(String profile) =>
      profile == 'alpine' ? kAlpineDistroName : kUbuntuDistroName;

  static String distroLabelFor(String profile) =>
      profile == 'alpine' ? 'Alpine 3.20' : 'Ubuntu 24.04 base';

  /// 解包用的临时压缩包名（按 profile 区分，避免旧 Alpine 包残留误用）。
  static String rootfsArchiveFor(String profile) => profile == 'alpine'
      ? 'tga-debian-alpine-rootfs.tar.gz'
      : 'tga-ubuntu-24.04-base-arm64-rootfs.tar.gz';

  final HarnessStore store;
  final DownloadManager downloads;

  Directory get extDir => Directory('${store.root.path}/debian_ext');
  Directory get rootfsDir => Directory('${extDir.path}/rootfs');
  File get prootBin => File('${extDir.path}/proot');
  File get tallocLib => File('${extDir.path}/libtalloc.so.2');
  File get readyFile => File('${extDir.path}/READY.json');

  /// 安装中的目标 profile（READY 落盘前也能给出正确口径；null = 不在安装）。
  String? _installProfile;

  Map<String, dynamic> _readyJson() {
    try {
      if (!readyFile.existsSync()) return const <String, dynamic>{};
      final Object? v = jsonDecode(readyFile.readAsStringSync());
      return v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
    } on Object {
      return const <String, dynamic>{};
    }
  }

  /// 当前生效 profile：
  /// * 安装中 → 本次安装的目标 profile；
  /// * 已装 → READY.json 的 profile / distro / rootfs；老版本没有 profile
  ///   字段（当时只有 Alpine）一律按 alpine 解释；
  /// * 未装 → 新装默认 ubuntu。
  String get profile {
    if (_installProfile != null) return _installProfile!;
    if (!readyFile.existsSync()) return kDefaultProfile;
    final Map<String, dynamic> m = _readyJson();
    final String p = (m['profile'] ?? '').toString().toLowerCase();
    if (p == 'alpine' || p == 'ubuntu') return p;
    final String d = '${m['distro'] ?? ''} ${m['rootfs'] ?? ''}'.toLowerCase();
    return d.contains('ubuntu') ? 'ubuntu' : 'alpine';
  }

  /// 供 UI / env_report 展示的发行版口径。
  String get distroLabel => distroLabelFor(profile);

  /// 是否真正可用：READY 标记 + proot 二进制完整（>100KB）+ rootfs 里
  /// 已有可执行的 /bin/sh，且该 profile 的关键文件存在：
  /// * Alpine：/bin/busybox（/bin/sh 是指向绝对路径 /bin/busybox 的
  ///   符号链接，宿主解析时目标不存在，只能用 _present 判断链接本身）；
  /// * Ubuntu：/bin/bash 或 /usr/bin/apt-get。
  bool get installed =>
      readyFile.existsSync() &&
      prootBin.existsSync() &&
      prootBin.lengthSync() > 100000 &&
      _present('${rootfsDir.path}/bin/sh') &&
      (profile == 'alpine'
          ? File('${rootfsDir.path}/bin/busybox').existsSync()
          : (File('${rootfsDir.path}/bin/bash').existsSync() ||
              File('${rootfsDir.path}/usr/bin/apt-get').existsSync()));

  static bool _present(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  // ---- 安装状态机（流式真实字节进度，失败如实记录）----

  String _step = 'idle'; // idle | downloading | extracting | ready | failed
  String? _error;
  bool _installing = false;

  // 流式下载的真实进度（全部来自收到的字节，不编造）。
  int _received = 0; // 三个文件累计已接收字节
  int _total = 0; // 累计总字节；-1 = 当前有文件 Content-Length 未知
  int _doneBytes = 0; // 已完成文件累计字节
  double _speed = 0; // 最近窗口的平均字节速率（bytes/s）
  String _lastPhase = 'download'; // download | extract
  int _lastReceived = 0;
  int _lastTotal = 0;
  double _lastSpeed = 0;
  DateTime _winAt = DateTime.now();
  int _winBytes = 0;
  DateTime _emitAt = DateTime.now();
  void Function(String phase, int received, int total, double bytesPerSec)?
      _onProgress;

  Map<String, dynamic> status() {
    final String p = profile;
    final int rootfsBytes = rootfsBytesFor(p);
    final int total =
        _total > 0 ? _total : kProotBytes + kTallocBytes + rootfsBytes;
    final String pkg = p == 'alpine' ? 'apk/python/pip' : 'apt/dpkg/python/pip';
    return <String, dynamic>{
      'ok': true,
      'installed': installed,
      'step': installed && _step == 'idle' ? 'ready' : _step,
      'installing': _installing,
      'profile': p,
      'distro': distroLabelFor(p),
      'rootfs_name': rootfsDistroFor(p),
      'downloaded': _received,
      'total': total,
      'rootfs_bytes': rootfsBytes,
      'percent': total > 0 ? (_received * 100 / total).clamp(0, 100).toDouble() : 0.0,
      'speed': _speed,
      if (_error != null) 'error': _error,
      'rootfs': installed ? rootfsDir.path : '',
      'proot': prootBin.existsSync() ? prootBin.path : '',
      'note': '${distroLabelFor(p)} + proot（UserLAnd arm64 官方二进制），'
          '共约 ${(total / 1000000).toStringAsFixed(0)} MB；'
          '流式下载按真实接收字节上报进度，'
          '$pkg 在用户态真实执行。',
    };
  }

  /// 最近一次进度快照（proot_progress 事件载荷）；未在安装中返回 null。
  /// 由 debian_status 分发时同步补发，保证 hot-path 事件必达 UI。
  Map<String, dynamic>? progressSnapshot() {
    if (!_installing) return null;
    return <String, dynamic>{
      'phase': _lastPhase,
      'received': _lastReceived,
      'total': _lastTotal,
      'speed': _lastSpeed,
    };
  }

  /// 启动真实安装：三个文件依次流式下载（http.Client().send 收
  /// ByteStream，逐 chunk 累计 received 并经 onProgress 上报
  /// phase/received/total/bytesPerSec，total 未知传 -1）；
  /// 完成后解包 rootfs（phase='extract'）、恢复权限、写 resolv.conf
  /// 并落 READY 标记。方法本身立即返回，不阻塞 control 请求。
  Future<Map<String, dynamic>> install({
    String profile = kDefaultProfile,
    void Function(String phase, int received, int total, double bytesPerSec)?
        onProgress,
  }) async {
    final String target = normalizeProfile(profile);
    if (installed) {
      return <String, dynamic>{
        'ok': true,
        'profile': this.profile,
        'note': '${distroLabel} 用户态已就绪。',
      };
    }
    if (_installing) {
      return <String, dynamic>{'ok': true, 'note': '安装已在进行中。'};
    }
    _installing = true;
    _installProfile = target;
    _error = null;
    _step = 'downloading';
    _onProgress = onProgress;
    _received = 0;
    _doneBytes = 0;
    _total = kProotBytes + kTallocBytes + rootfsBytesFor(target);
    _speed = 0;
    _lastPhase = 'download';
    _lastReceived = 0;
    _lastTotal = _total;
    _lastSpeed = 0;
    _winAt = DateTime.now();
    _winBytes = 0;
    _emitAt = DateTime.now();
    unawaited(_runInstall(target));
    return <String, dynamic>{
      'ok': true,
      'profile': target,
      'note': '真实流式下载中：${distroLabelFor(target)}，'
          '进度按接收字节实时上报（约 ${(_total / 1000000).toStringAsFixed(0)} MB）。',
    };
  }

  Future<void> _runInstall(String profile) async {
    final http.Client client = http.Client();
    try {
      if (!extDir.existsSync()) extDir.createSync(recursive: true);
      final int rootfsBytes = rootfsBytesFor(profile);
      final File rootfsTmp =
          File('${extDir.path}/${rootfsArchiveFor(profile)}');
      await _downloadStream(
          client, kProotUrl, prootBin, kTallocBytes + rootfsBytes,
          expectedSha256: kProotSha256);
      await _downloadStream(client, kTallocUrl, tallocLib, rootfsBytes,
          expectedSha256: kTallocSha256);
      await _downloadStream(client, rootfsUrlFor(profile), rootfsTmp, 0,
          expectedSha256: sha256ForUrl(rootfsUrlFor(profile)));

      _step = 'extracting';
      _report('extract', _received, _total, 0);

      final bytes = await rootfsTmp.readAsBytes();
      final int rootfsActual = bytes.length;
      final Uint8List tar =
          Uint8List.fromList(GZipCodec().decode(bytes));
      _extractTar(tar, rootfsDir);
      await rootfsTmp.delete();

      // 目录里已备好 proot 需要的最小骨架。
      for (final d in <String>['tmp', 'root', 'proc', 'sys', 'dev']) {
        final dir2 = Directory('${rootfsDir.path}/$d');
        if (!dir2.existsSync()) dir2.createSync(recursive: true);
      }
      // proot 的临时目录必须真实存在（PROOT_TMP_DIR 指向它），否则首次
      // 启动会在 relink 阶段失败——这是「装了却跑不起来」的常见原因。
      final Directory prootTmp = Directory('${extDir.path}/proot_tmp');
      if (!prootTmp.existsSync()) prootTmp.createSync(recursive: true);
      // 把 App 沙箱目录挂进用户态，Agent 在工作区写的文件在 Linux 里
      // 走 /workspace 就能直接看到（同一份磁盘，不是复制）。
      final Directory appSandbox = store.sub('sandbox');
      if (!appSandbox.existsSync()) appSandbox.createSync(recursive: true);
      // ubuntu-base / Alpine minirootfs 都不带可用 DNS 配置；写真实公共 DNS。
      // ubuntu-base 里 /etc/resolv.conf 可能是指向 /run 的符号链接，先删掉
      // 链接本身再写普通文件，避免写入悬空目标导致安装失败。
      final File resolv = File('${rootfsDir.path}/etc/resolv.conf');
      if (FileSystemEntity.typeSync(resolv.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await resolv.delete();
      }
      await resolv.writeAsString('nameserver 8.8.8.8\nnameserver 1.1.1.1\n');

      // 兼容层按 profile 写入：
      // * Ubuntu：apt/dpkg 原生可用，只补一个 pkg → apt-get 的封装；
      // * Alpine：pkg / apt 两个 Termux 风格命令真实映射到 apk。
      // 脚本失败不影响系统包管理器本体。
      await _writeCompatShims(profile);
      await _ensureAptSources();
      await _ensureAptConf();

      // 恢复可执行位：tar 头里的 mode 无法用 dart:io 直接落位，
      // 统一交给系统 toybox chmod（系统二进制，任何 targetSdk 都可执行）。
      final chmod = await _chmodAll();
      if (chmod != null) {
        throw StateError('chmod 失败：$chmod');
      }

      // JS 运行时预装：QQ 沙箱直连走腾讯官方 dsh-qqbot（npx dsh），
      // 依赖 node/npm。Alpine 在初始化阶段用 apk 真实预装；Ubuntu 首次
      // apt-get update/install 可能耗时数分钟，故安装阶段不预装，由
      // ensureJs() 在扫码前按需真实补装，避免拖垮整体安装。
      final Map<String, dynamic> js = await provisionJs(profile: profile);

      await readyFile.writeAsString(jsonEncode(<String, dynamic>{
        'installed_at': DateTime.now().toIso8601String(),
        'profile': profile,
        'distro': distroLabelFor(profile),
        'rootfs': rootfsDistroFor(profile),
        'proot_bytes': prootBin.lengthSync(),
        'talloc_bytes': tallocLib.lengthSync(),
        'rootfs_bytes': rootfsActual,
        'js': js,
      }), flush: true);
      _step = 'ready';
    } on Object catch (e) {
      _step = 'failed';
      _error = '$e';
    } finally {
      client.close();
      _installing = false;
      _installProfile = null;
    }
  }

  /// 单文件流式下载：resp.contentLength 为该文件 total（未知传 -1）；
  /// 逐 chunk 累计 _received，按 ~250ms 节流上报 download 进度。
  /// [remainingKnown] 为后续文件已核实的字节常量之和，用于推算全局 total。
  Future<void> _downloadStream(
    http.Client client,
    String url,
    File target,
    int remainingKnown, {
    String expectedSha256 = '',
  }) async {
    final request = http.Request('GET', Uri.parse(url))
      ..followRedirects = true;
    final http.StreamedResponse resp;
    try {
      resp = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
    } on Object catch (e) {
      throw StateError('下载 ${Uri.parse(url).pathSegments.last} '
          '连接失败：$e');
    }
    if (resp.statusCode != 200) {
      await resp.stream.drain<void>();
      throw StateError('下载 ${Uri.parse(url).pathSegments.last} '
          '失败：HTTP ${resp.statusCode}');
    }
    final int? respLen = resp.contentLength;
    final int fileTotal = (respLen != null && respLen > 0) ? respLen : -1;
    if (target.existsSync()) target.deleteSync();
    final IOSink sink = target.openWrite();
    final int base = _received;
    try {
      // 30s 无字节即判停滞，如实失败（不谎报进度）。
      await for (final List<int> chunk in
          resp.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        _received += chunk.length;
        _tickDownloadProgress(fileTotal, remainingKnown);
      }
    } finally {
      await sink.close();
    }
    final int written = target.lengthSync();
    _received = base + written; // 以真实落盘字节为准
    _doneBytes += written;
    if (fileTotal > 0 && written != fileTotal) {
      throw StateError('${target.path} 不完整：$written / $fileTotal 字节');
    }
    // 完整性校验：proot/rootfs 是要执行或解包落盘的二进制，长度一致但内容
    // 被替换（恶意 ELF / 损坏镜像）只能靠摘要发现。不符则删除并如实失败，
    // 绝不把未校验的文件交给 exec 或 tar 解包。
    if (expectedSha256.isNotEmpty) {
      // 对已落盘文件做流式 SHA256（不全量载入内存），与官方摘要比对。
      final String actual =
          (await crypto.sha256.bind(target.openRead()).first).toString();
      if (actual != expectedSha256.toLowerCase()) {
        try {
          target.deleteSync();
        } on Object {
          // 删不掉也如实报错，绝不继续使用未通过校验的文件。
        }
        _doneBytes -= written;
        _received = base;
        throw StateError('${target.path} SHA256 校验失败：期望 $expectedSha256，'
            '实际 $actual（下载内容可能被替换/损坏），已删除拒绝使用');
      }
    }
    _report('download', _received,
        fileTotal > 0 ? _doneBytes + remainingKnown : -1, _speed);
  }

  void _tickDownloadProgress(int fileTotal, int remainingKnown) {
    final DateTime now = DateTime.now();
    if (now.difference(_emitAt).inMilliseconds < 250) return;
    final double dt = now.difference(_winAt).inMicroseconds / 1e6;
    if (dt > 0.05) {
      _speed = (_received - _winBytes) / dt;
      _winAt = now;
      _winBytes = _received;
    }
    _emitAt = now;
    _report('download', _received,
        fileTotal > 0 ? _doneBytes + fileTotal + remainingKnown : -1, _speed);
  }

  void _report(String phase, int received, int total, double speed) {
    _lastPhase = phase;
    _lastReceived = received;
    _lastTotal = total;
    _lastSpeed = speed;
    if (total > 0) _total = total;
    _onProgress?.call(phase, received, total, speed);
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

  bool _shimsReady = false;

  /// Ubuntu 的 pkg 兼容层：只映射到 apt-get，绝不覆盖原生 apt/dpkg。
  /// `install` 前先 `apt-get update`：ubuntu-base 镜像首次安装时包索引为空，
  /// 直接 install 会报 `Unable to locate package`（真实用户反馈）。
  /// 版本标记用于识别并升级老环境的旧脚本（旧脚本里也有 `apt-get update`
  /// 这一行，不能只按该字符串判断）。
  static const String _ubuntuPkgBody = '''#!/bin/sh
# TGA_SHIM_VERSION=2
# TGA: Ubuntu 环境，pkg 兼容层映射到 apt-get；原生 apt/dpkg 未被覆盖。
export DEBIAN_FRONTEND=noninteractive
cmd="\$1"; [ \$# -gt 0 ] && shift
args=""
for a in "\$@"; do
  [ "\$a" = "-y" ] || [ "\$a" = "--yes" ] || args="\$args \$a"
done
# Termux 习惯：pkg install python 在 Ubuntu 上没有 python 包，映射到 python3。
mapped=""
for a in \$args; do
  [ "\$a" = "python" ] && a="python3"
  mapped="\$mapped \$a"
done
case "\$cmd" in
  install|add)
    apt-get update || exit \$?
    exec apt-get install -y \$mapped ;;
  uninstall|remove|purge) exec apt-get remove -y \$args ;;
  update) exec apt-get update ;;
  upgrade) apt-get update || exit \$?; exec apt-get upgrade -y ;;
  search) exec apt-cache search \$args ;;
  list-installed) exec dpkg -l ;;
  *) exec apt-get "\$cmd" \$args ;;
esac
''';

  /// 写入兼容脚本，按 profile 区分：
  /// * Ubuntu：原生 apt/dpkg 保留，只写 pkg → apt-get（Termux 习惯）；
  /// * Alpine：保持原有 pkg / apt → apk 映射，老环境完全不变。
  Future<void> _writeCompatShims(String profile) async {
    final String p = normalizeProfile(profile);
    final Directory bin = Directory('${rootfsDir.path}/usr/local/bin');
    if (!bin.existsSync()) bin.createSync(recursive: true);
    const String aptBody = '''#!/bin/sh
# TGA: Alpine 环境，apt 兼容层映射到 apk。
cmd="\$1"; [ \$# -gt 0 ] && shift
args=""
for a in "\$@"; do
  [ "\$a" = "-y" ] || [ "\$a" = "--yes" ] || args="\$args \$a"
done
case "\$cmd" in
  install) exec apk add \$args ;;
  remove|purge) exec apk del \$args ;;
  update) exec apk update ;;
  upgrade) exec apk upgrade ;;
  search) exec apk search \$args ;;
  *) echo "TGA: 这是 Alpine 环境，apt 已映射到 apk；支持 install/remove/update/upgrade/search。" >&2; exit 2 ;;
esac
''';
    const String pkgBody = '''#!/bin/sh
# TGA: Termux 风格 pkg 兼容层，映射到 apk。
cmd="\$1"; [ \$# -gt 0 ] && shift
args=""
for a in "\$@"; do
  [ "\$a" = "-y" ] || [ "\$a" = "--yes" ] || args="\$args \$a"
done
case "\$cmd" in
  install|add) exec apk add \$args ;;
  uninstall|remove) exec apk del \$args ;;
  update) exec apk update ;;
  upgrade) exec apk upgrade ;;
  search) exec apk search \$args ;;
  list-installed) exec apk info ;;
  *) exec apk "\$cmd" \$args ;;
esac
''';
    try {
      final List<String> written = <String>[];
      if (p == 'alpine') {
        await File('${bin.path}/apt').writeAsString(aptBody, flush: true);
        await File('${bin.path}/pkg').writeAsString(pkgBody, flush: true);
        written.addAll(<String>['${bin.path}/apt', '${bin.path}/pkg']);
      } else {
        // Ubuntu：不写 /usr/local/bin/apt，保证原生 apt 行为不被拦截。
        await File('${bin.path}/pkg')
            .writeAsString(_ubuntuPkgBody, flush: true);
        written.add('${bin.path}/pkg');
      }
      final String chmod = Platform.isAndroid ? '/system/bin/chmod' : 'chmod';
      await Process.run(chmod, <String>['755', ...written]);
      _shimsReady = true;
    } on Object {
      // 只读 rootfs 等异常不阻断；用户仍可直接用系统包管理器。
    }
  }

  /// 保证 Ubuntu 里有可用的 apt 源。ubuntu-base 自带 ports.ubuntu.com，
  /// 但个别安装/迁移会把 sources 丢空；此时 `apt-get update` 不报错却
  /// 拿不到任何索引，install 就会报 `Unable to locate package`。
  Future<void> _ensureAptSources() async {
    if (profile != 'ubuntu') return;
    final Directory etcApt = Directory('${rootfsDir.path}/etc/apt');
    try {
      if (!etcApt.existsSync()) etcApt.createSync(recursive: true);
      bool hasSources = false;
      bool hasNonComment(File f) {
        try {
          final String text = f.readAsStringSync();
          return text.split('\n').any((String line) {
            final String t = line.trim();
            return t.isNotEmpty && !t.startsWith('#');
          });
        } on Object {
          return false;
        }
      }

      final File legacy = File('${etcApt.path}/sources.list');
      if (legacy.existsSync()) hasSources = hasNonComment(legacy);
      final Directory dropIn = Directory('${etcApt.path}/sources.list.d');
      if (!hasSources && dropIn.existsSync()) {
        for (final FileSystemEntity e in dropIn.listSync()) {
          if (e is! File) continue;
          if (!e.path.endsWith('.list') && !e.path.endsWith('.sources')) {
            continue;
          }
          if (hasNonComment(e)) {
            hasSources = true;
            break;
          }
        }
      }
      if (hasSources) return;
      if (FileSystemEntity.typeSync(legacy.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        legacy.deleteSync();
      }
      legacy.writeAsStringSync('''deb http://ports.ubuntu.com/ubuntu-ports noble main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main universe restricted multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-security main universe restricted multiverse
''', flush: true);
    } on Object {
      // 源修复失败不阻断命令；apt 会打印真实错误。
    }
  }

  /// proot 的 fake root 不支持 setresuid / getgroups，apt 默认会降权到
  /// `_apt` 用户，导致 update 直接失败：
  ///   E: getgroups ... Function not implemented
  ///   E: Failed to set new user ids - setresuid (1: Operation not permitted)
  /// 写入 apt 配置强制以 root 运行下载方法，是 proot 下的标准做法。
  Future<void> _ensureAptConf() async {
    if (profile != 'ubuntu') return;
    final Directory dir = Directory('${rootfsDir.path}/etc/apt/apt.conf.d');
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File f = File('${dir.path}/99tga-proot');
      const String body = '''// TGA: proot 无法 setresuid/getgroups，apt 必须以 root 运行下载方法。
APT::Sandbox::User "root";
''';
      if (!f.existsSync() ||
          !f.readAsStringSync().contains('APT::Sandbox::User')) {
        f.writeAsStringSync(body, flush: true);
      }
    } on Object {
      // 配置写不进去时 apt 会打印真实错误，不静默伪造成功。
    }
  }

  /// 已装用户的兼容层补齐：Ubuntu 只要求 pkg；Alpine 要求 pkg + apt。
  Future<void> _ensureCompatShims() async {
    if (_shimsReady) return;
    if (!installed) return;
    final String p = profile;
    final Directory bin = Directory('${rootfsDir.path}/usr/local/bin');
    final List<String> needed = p == 'alpine'
        ? <String>['pkg', 'apt']
        : <String>['pkg'];
    if (needed.every((String n) => File('${bin.path}/$n').existsSync())) {
      // 老版本的 Ubuntu pkg 兼容层不会先 apt-get update，导致包索引为空时
      // 安装必然失败；发现旧脚本就原地升级为当前版本。
      if (p == 'ubuntu') {
        try {
          final String body = await File('${bin.path}/pkg').readAsString();
          // 旧脚本里同样有 `apt-get update` 字符串（update 分支），
          // 必须按版本标记判断，否则永远不会升级。
          if (!body.contains('TGA_SHIM_VERSION=2')) {
            await _writeCompatShims(p);
            return;
          }
        } on Object {
          // 读取失败时按缺失处理，下面会重写。
          await _writeCompatShims(p);
          return;
        }
      }
      _shimsReady = true;
      return;
    }
    await _writeCompatShims(p);
  }

  /// Android/Termux 式用户态绑定：读取已授权、可写、未禁用的 link 映射，
  /// 用 proot `-b host:/mnt/tga/<id>` 挂进 Linux。无需 root，也不复制文件。
  /// 只读映射不在此绑定（proot -b 不能可靠降为只读），继续走 copy。
  Future<List<String>> _workspaceBindArgs() async {
    try {
      final List<dynamic> raw = await store.readList('workspace_mappings.json');
      final List<String> args = <String>[];
      for (final dynamic item in raw) {
        if (item is! Map) continue;
        final Map<String, dynamic> m = Map<String, dynamic>.from(item);
        if (m['enabled'] == false) continue;
        if ((m['bind_mode'] ?? '') != 'link') continue;
        if ((m['access'] ?? 'rw') == 'ro') continue;
        final String host = (m['link_target'] ?? '').toString();
        final String id = (m['id'] ?? '').toString();
        if (host.isEmpty || id.isEmpty) continue;
        final String p = host.replaceAll('\\', '/').toLowerCase();
        const List<String> deny = <String>[
          '/etc', '/proc', '/sys', '/dev', '/boot', '/root',
          '.ssh', '.gnupg', '.aws', '.config/gcloud',
          'id_rsa', 'id_ed25519', 'credentials', 'secrets', '.env',
        ];
        if (deny.any(p.contains)) continue;
        if (!Directory(host).existsSync()) continue;
        final String guest = '/mnt/tga/$id';
        Directory('${rootfsDir.path}$guest').createSync(recursive: true);
        args.addAll(<String>['-b', '$host:$guest']);
      }
      return args;
    } on Object {
      // 映射文件缺失/损坏不影响终端本身。
      return const <String>[];
    }
  }

  // ---- 真实执行：proot 里跑 /bin/sh ----

  /// 已安装则用 proot 用户态真实执行；未安装返回 null（调用方回退
  /// toybox 真实 shell）。exec 被 ROM 拒绝时如实报错并给出原因与出路。
  Future<Map<String, dynamic>?> run(
    String raw,
    String cwd, {
    bool requireInstalled = true,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (requireInstalled && !installed) return null;
    if (installed) {
      await _ensureAptSources();
      await _ensureAptConf();
      await _ensureCompatShims();
    }
    final String guestCwd = cwd == '.'
        ? '/root'
        : (cwd.startsWith('/') ? cwd : '/root/$cwd');
    final String marker =
        '__TGA_END_${DateTime.now().microsecondsSinceEpoch}__';
    final String script =
        'cd ${_shellQuote(guestCwd)} 2>/dev/null; $raw; __rc=\$?; '
        'printf "\\n$marker%s$marker\$__rc\\n" "\$(pwd -P 2>/dev/null)"; '
        'exit \$__rc';

    final Directory prootTmp = Directory('${extDir.path}/proot_tmp');
    if (!prootTmp.existsSync()) prootTmp.createSync(recursive: true);
    final Directory appSandbox = store.sub('sandbox');
    if (!appSandbox.existsSync()) appSandbox.createSync(recursive: true);
    final List<String> bindArgs = await _workspaceBindArgs();

    Process proc;
    try {
      proc = await Process.start(
        prootBin.path,
        <String>[
          '-0',
          '-l',
          '-r',
          rootfsDir.path,
          // 显式指定 guest 内初始工作目录。否则 proot 会把宿主的
          // workingDirectory（App 私有目录）当成 guest 路径去 chdir，
          // 打印 "can't chdir(...)" 并退回 "/"，随后 apt 里的 getcwd()
          // 直接失败（真实用户反馈）。
          '-w',
          '/root',
          '-b',
          '/dev',
          '-b',
          '/proc',
          '-b',
          '/sys',
          // 工作区与 App 沙箱共用同一份磁盘：Linux 里 /workspace 就是它。
          '-b',
          '${appSandbox.path}:/workspace',
          ...bindArgs,
          '/bin/sh',
          '-c',
          script,
        ],
        workingDirectory: rootfsDir.path,
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
        'error': 'Linux 用户态无法启动（${e.errorCode} ${e.message}）。'
            'Android 10+ 若 ROM 强制禁止执行应用私有目录文件'
            '（SELinux app_data_file noexec），proot 无法运行；'
            '请改用「远端沙箱（SSH）」在真实 Linux 上跑 apt。',
        'cwd': cwd,
        'cube': 'shell',
        'debian': true,
      };
    }

    // 宽松解码：Linux 命令可能输出非 UTF-8 字节，严格解码会抛 FormatException。
    final Future<String> outF =
        proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final Future<String> errF =
        proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    int exitCode = 124;
    try {
      exitCode = await proc.exitCode.timeout(timeout);
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

  // ---- JS 运行时（nodejs/npm）：QQ 沙箱直连 dsh-qqbot 的真实前置依赖 ----

  /// 安装阶段的 JS 运行时准备，按 profile 区分：
  /// * Alpine：真实执行 `apk add --no-cache nodejs npm`；
  /// * Ubuntu：不在安装阶段预装（apt-get update + install 可能数分钟，
  ///   且网络失败会拖垮整个安装），如实返回未预装，由 ensureJs() 在
  ///   QQ 扫码前按需真实补装。
  /// 安装阶段调用时 READY 未落盘，故 requireInstalled=false；
  /// 失败如实返回 ok:false，绝不伪造成功。
  Future<Map<String, dynamic>> provisionJs({String? profile}) async {
    final String p = normalizeProfile(profile ?? this.profile);
    if (p == 'ubuntu') {
      return <String, dynamic>{
        'ok': false,
        'skipped': true,
        'reason': 'debian: node 未预装，首次使用前按需安装',
      };
    }
    // apk 需要 DNS/源可达，安装阶段 resolv.conf 已写好；给足超时。
    final Map<String, dynamic>? r = await run(
      'if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then '
      'echo "already: \$(node --version) / \$(npm --version)"; exit 0; fi; '
      'apk add --no-cache nodejs npm 2>&1; '
      'if command -v node >/dev/null 2>&1; then echo "js-ready: \$(node --version)"; '
      'else echo "js-missing"; exit 1; fi',
      '.',
      requireInstalled: false,
      timeout: const Duration(seconds: 300),
    );
    return _jsResult(r);
  }

  /// Ubuntu 按需补装：`apt-get update && DEBIAN_FRONTEND=noninteractive
  /// apt-get install -y nodejs npm`，真实执行、真实回传。
  Future<Map<String, dynamic>> _aptProvisionJs() async {
    final Map<String, dynamic>? r = await run(
      'if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then '
      'echo "already: \$(node --version) / \$(npm --version)"; exit 0; fi; '
      'export DEBIAN_FRONTEND=noninteractive; '
      'apt-get update 2>&1 && apt-get install -y nodejs npm 2>&1; '
      'if command -v node >/dev/null 2>&1; then echo "js-ready: \$(node --version)"; '
      'else echo "js-missing"; exit 1; fi',
      '.',
      requireInstalled: false,
      timeout: const Duration(minutes: 10),
    );
    return _jsResult(r);
  }

  Map<String, dynamic> _jsResult(Map<String, dynamic>? r) {
    if (r == null) {
      return <String, dynamic>{
        'ok': false,
        'error': 'proot 用户态无法启动，JS 运行时未安装',
      };
    }
    final String out = (r['stdout'] ?? '').toString();
    final bool ok = r['ok'] == true &&
        out.contains('js-ready:') &&
        !out.contains('js-missing');
    return <String, dynamic>{
      'ok': ok,
      'detail': out.trim(),
      if (!ok) 'error': out.trim().isEmpty ? (r['error'] ?? '未知错误') : out.trim(),
    };
  }

  /// 幂等确保 node/npm 可用：查询 READY.json 的安装结果，缺失则补装。
  /// Ubuntu 在安装阶段不预装 node，这里按需执行真实 apt-get 安装。
  /// 供 QQ 扫码 start() 在启动 dsh 前调用；返回真实状态。
  Future<Map<String, dynamic>> ensureJs() async {
    if (!installed) {
      return <String, dynamic>{
        'ok': false,
        'error': 'Linux 沙箱尚未就绪，无法准备 JS 运行时',
      };
    }
    // 先真实探测一次，避免重复安装。
    final Map<String, dynamic>? probe = await run('command -v node && node --version', '.');
    if (probe != null && probe['ok'] == true &&
        (probe['stdout'] ?? '').toString().trim().isNotEmpty) {
      return <String, dynamic>{
        'ok': true,
        'node': (probe['stdout'] ?? '').toString().trim(),
        'note': 'JS 运行时已在沙箱中就绪',
      };
    }
    final Map<String, dynamic> r =
        profile == 'ubuntu' ? await _aptProvisionJs() : await provisionJs();
    if (r['ok'] == true) {
      return <String, dynamic>{
        'ok': true,
        'note': 'JS 运行时已补装完成',
        'node': r['detail'],
      };
    }
    return <String, dynamic>{
      'ok': false,
      'error': 'JS 运行时安装失败：${r['error'] ?? '未知错误'}。'
          '本应用不会伪造二维码或假装已连接。',
    };
  }

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
