/// 完整 Linux 虚拟机（真内核）管理器。
///
/// 与 proot 用户态不同：这里用 QEMU 全系统模拟运行 arm64 Linux 内核 +
/// Ubuntu 24.04 根盘，拥有独立内核、init 与 apt/dpkg。资产由
/// `scripts/build_linux_vm_assets.sh` 生成（Image / initrd.gz / root.sqfs）。
///
/// 平台差异（如实返回，不伪造可用）：
/// * Linux/macOS/Windows 桌面：使用系统 `qemu-system-aarch64`；
/// * Android：需要把 QEMU 可执行文件放到 `vm/qemu-system-aarch64` 或设置
///   `TGA_QEMU`；没有时 [status] 返回 `qemu_ready=false` 与安装说明。
/// * iOS：不允许启动子进程，状态明确为不支持。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'store.dart';

class LinuxVm {
  LinuxVm(this.store, {this.qemuOverride = ''});

  final HarnessStore store;

  /// 显式指定的 QEMU 路径（空 = 自动探测）。
  final String qemuOverride;

  static const String kernelName = 'Image';
  static const String initrdName = 'initrd.gz';
  static const String rootfsName = 'root.sqfs';
  static const String manifestName = 'manifest.json';

  /// 资产最低大小（字节），防止把半截下载当成可用镜像。
  static const int minKernelBytes = 8 * 1024 * 1024;
  static const int minInitrdBytes = 4 * 1024 * 1024;
  static const int minRootfsBytes = 16 * 1024 * 1024;

  Directory get dir => Directory('${store.root.path}/vm');
  File get kernel => File('${dir.path}/$kernelName');
  File get initrd => File('${dir.path}/$initrdName');
  File get rootfs => File('${dir.path}/$rootfsName');
  File get manifest => File('${dir.path}/$manifestName');

  bool get assetsReady =>
      kernel.existsSync() &&
      kernel.lengthSync() >= minKernelBytes &&
      initrd.existsSync() &&
      initrd.lengthSync() >= minInitrdBytes &&
      rootfs.existsSync() &&
      rootfs.lengthSync() >= minRootfsBytes;

  /// 解析 QEMU 可执行文件；找不到返回空串。
  Future<String> resolveQemu() async {
    final String override = qemuOverride.trim().isNotEmpty
        ? qemuOverride.trim()
        : (Platform.environment['TGA_QEMU'] ?? '').trim();
    if (override.isNotEmpty && File(override).existsSync()) return override;
    if (Platform.isAndroid) {
      final String bundled = '${dir.path}/qemu-system-aarch64';
      return File(bundled).existsSync() ? bundled : '';
    }
    if (Platform.isIOS) return '';
    for (final String name in <String>[
      'qemu-system-aarch64',
      '/usr/bin/qemu-system-aarch64',
      '/usr/local/bin/qemu-system-aarch64',
      '/opt/homebrew/bin/qemu-system-aarch64',
    ]) {
      try {
        final ProcessResult r = await Process.run(
          Platform.isWindows ? 'where' : 'which',
          <String>[name],
        ).timeout(const Duration(seconds: 3));
        final String p = '${r.stdout}'.trim().split('\n').first.trim();
        if (r.exitCode == 0 && p.isNotEmpty && File(p).existsSync()) return p;
      } on Object {
        // 继续尝试下一个路径。
      }
    }
    return '';
  }

  /// 真实状态：资产、QEMU、平台能力。缺什么就写什么，不谎报。
  Future<Map<String, dynamic>> status() async {
    final String qemu = await resolveQemu();
    String manifestText = '';
    if (manifest.existsSync()) {
      try {
        manifestText = await manifest.readAsString();
      } on Object {
        manifestText = '';
      }
    }
    return <String, dynamic>{
      'ok': true,
      'platform': Platform.operatingSystem,
      'mode': 'qemu-vm',
      'assets_ready': assetsReady,
      'qemu_ready': qemu.isNotEmpty,
      'qemu': qemu,
      'assets_dir': dir.path,
      'files': <String, dynamic>{
        kernelName: kernel.existsSync() ? kernel.lengthSync() : 0,
        initrdName: initrd.existsSync() ? initrd.lengthSync() : 0,
        rootfsName: rootfs.existsSync() ? rootfs.lengthSync() : 0,
      },
      'manifest': manifestText.isEmpty
          ? <String, dynamic>{}
          : (jsonDecode(manifestText) is Map
              ? jsonDecode(manifestText) as Map<String, dynamic>
              : <String, dynamic>{}),
      'note': qemu.isEmpty
          ? (Platform.isIOS
              ? 'iOS 不允许启动 QEMU 子进程；完整 Linux VM 仅桌面/Android 可用。'
              : '未找到 qemu-system-aarch64：请安装 QEMU，或把 Android 版 QEMU '
                  '放到 ${dir.path}/qemu-system-aarch64 / 设置 TGA_QEMU。')
          : (assetsReady
              ? '真内核 VM 资产与 QEMU 均已就绪。'
              : 'QEMU 已找到，但 VM 资产不完整：先运行 '
                  'scripts/build_linux_vm_assets.sh 并把产物放进 ${dir.path}。'),
    };
  }

  /// 生成与实测一致的命令参数：真内核实测可启动 Ubuntu 24.04 + apt。
  List<String> buildArgs({int memoryMB = 1024, int cpus = 2}) {
    final int mem = memoryMB < 256 ? 256 : memoryMB;
    final int cpu = cpus < 1 ? 1 : (cpus > 8 ? 8 : cpus);
    return <String>[
      '-M', 'virt',
      '-cpu', 'max',
      '-smp', '$cpu',
      '-m', '$mem',
      '-nographic',
      '-kernel', kernel.path,
      '-initrd', initrd.path,
      '-append', 'console=ttyAMA0',
      '-drive', 'file=${rootfs.path},if=virtio,format=raw',
    ];
  }

  /// 启动 VM。调用方需读取 [Process.stdout]/[stderr] 展示控制台。
  Future<Process> start({int memoryMB = 1024, int cpus = 2}) async {
    if (!assetsReady) {
      throw StateError('VM 资产不完整：请先构建并放入 ${dir.path}');
    }
    final String qemu = await resolveQemu();
    if (qemu.isEmpty) {
      throw StateError(Platform.isIOS
          ? 'iOS 不允许启动 QEMU 子进程'
          : '未找到 qemu-system-aarch64（可设置 TGA_QEMU）');
    }
    return Process.start(
      qemu,
      buildArgs(memoryMB: memoryMB, cpus: cpus),
      workingDirectory: dir.path,
    );
  }
}
