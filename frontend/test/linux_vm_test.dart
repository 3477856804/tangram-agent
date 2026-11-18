import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/linux_vm.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;
  late LinuxVm vm;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_linux_vm_test_');
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
    vm = LinuxVm(store);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> writeAssets({
    int kernelBytes = LinuxVm.minKernelBytes,
    int initrdBytes = LinuxVm.minInitrdBytes,
    int rootfsBytes = LinuxVm.minRootfsBytes,
  }) async {
    await vm.dir.create(recursive: true);
    await vm.kernel.writeAsBytes(List<int>.filled(kernelBytes, 0));
    await vm.initrd.writeAsBytes(List<int>.filled(initrdBytes, 0));
    await vm.rootfs.writeAsBytes(List<int>.filled(rootfsBytes, 0));
  }

  test('资产不完整时如实返回 false，start 抛错', () async {
    expect(vm.assetsReady, isFalse);
    await expectLater(vm.start(), throwsStateError);
    final Map<String, dynamic> st = await vm.status();
    expect(st['assets_ready'], false);
    expect((st['note'] as String), isNotEmpty);
  });

  test('资产达到阈值后 ready，命令包含 kernel/initrd/rootfs 与真内核参数', () async {
    await writeAssets();
    expect(vm.assetsReady, isTrue);
    final List<String> args = vm.buildArgs(memoryMB: 512, cpus: 2);
    expect(args, containsAll(<String>['-M', 'virt', '-cpu', 'max']));
    expect(args, contains('-kernel'));
    expect(args, contains(vm.kernel.path));
    expect(args, contains('-initrd'));
    expect(args, contains(vm.initrd.path));
    expect(args.join(' '), contains(vm.rootfs.path));
    expect(args.join(' '), contains('console=ttyAMA0'));
    expect(args.join(' '), contains('if=virtio'));
  });

  test('qemuOverride 指向真实可执行文件时 status 标为就绪', () async {
    await writeAssets();
    final File fakeQemu = File('${tmp.path}/qemu-system-aarch64');
    await fakeQemu.writeAsString('#!/bin/sh\n');
    final LinuxVm q = LinuxVm(store, qemuOverride: fakeQemu.path);
    final Map<String, dynamic> st = await q.status();
    expect(st['qemu_ready'], isTrue);
    expect(st['assets_ready'], isTrue);
  });
}
