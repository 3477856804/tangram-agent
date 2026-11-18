import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/downloader.dart';
import 'package:tangram/harness/proot_sandbox.dart';
import 'package:tangram/harness/store.dart';

/// 回归：Alpine rootfs 的 /bin/sh 是绝对路径符号链接，宿主解析会指向
/// 不存在的 /bin/busybox；安装完成判断不能因此永远返回「未安装」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;
  late ProotSandbox sandbox;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_proot_test_');
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
    sandbox = ProotSandbox(store, DownloadManager(store));
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> installLayout({bool ready = true}) async {
    final Directory rootfs = Directory('${tmp.path}/debian_ext/rootfs');
    await Directory('${rootfs.path}/bin').create(recursive: true);
    await File('${rootfs.path}/bin/busybox').writeAsBytes(<int>[1, 2, 3]);
    final Link sh = Link('${rootfs.path}/bin/sh');
    if (await sh.exists()) await sh.delete();
    await sh.create('/bin/busybox');
    await File('${tmp.path}/debian_ext/proot')
        .writeAsBytes(List<int>.filled(200 * 1024, 0));
    if (ready) {
      await File('${tmp.path}/debian_ext/READY.json')
          .writeAsString('{"installed_at":"x"}');
    }
  }

  test('绝对符号链接 /bin/sh 不会被误判为未安装', () async {
    await installLayout();
    expect(Link('${tmp.path}/debian_ext/rootfs/bin/sh').existsSync(), isTrue);
    expect(File('${tmp.path}/debian_ext/rootfs/bin/sh').existsSync(), isFalse,
        reason: '宿主解析绝对链接目标 /bin/busybox 应不存在');
    expect(sandbox.installed, isTrue);
  });

  test('缺少 READY 或 busybox 时如实为未安装', () async {
    await installLayout(ready: false);
    expect(sandbox.installed, isFalse);

    await File('${tmp.path}/debian_ext/READY.json')
        .writeAsString('{"installed_at":"x"}');
    await File('${tmp.path}/debian_ext/rootfs/bin/busybox').delete();
    expect(sandbox.installed, isFalse);
  });
}
