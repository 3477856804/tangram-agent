/// 模型下载 SHA-256 完整性校验测试。
///
/// 只用临时文件验证真实摘要计算与入参校验；不构造网络下载。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/downloader.dart';
import 'package:tangram/harness/store.dart';

void main() {
  test('sha256OfFile 与已知内容摘要一致', () async {
    final tmp = await Directory.systemTemp.createTemp('tangram_sha256_test_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final file = File('${tmp.path}/abc.bin');
    await file.writeAsBytes(<int>[97, 98, 99]);

    expect(
      await sha256OfFile(file),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('isValidSha256 只接受 64 位小写 hex', () {
    expect(
      isValidSha256(
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'),
      isTrue,
    );
    expect(isValidSha256(''), isFalse);
    expect(isValidSha256('abc'), isFalse);
    expect(isValidSha256('g' * 64), isFalse);
    expect(isValidSha256('a' * 63), isFalse);
    expect(isValidSha256('A' * 64), isFalse);
  });

  test('非法 expected_sha256 直接返回失败且不发起下载', () async {
    final tmp = await Directory.systemTemp.createTemp('tangram_sha256_test_');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    HarnessStore.overrideForTest(tmp);
    final store = await HarnessStore.instance();
    final manager = DownloadManager(store);

    final job = await manager.start(
      'http://127.0.0.1:1/model.gguf',
      expectedSha256: 'not-a-sha256',
    );

    expect(job.status, 'failed');
    expect(job.error, 'expected_sha256 不是合法 SHA-256');
    expect(job.expectedSha256, isNull);
    expect(job.actualSha256, isNull);
  });
}
