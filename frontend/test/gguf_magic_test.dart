/// GGUF 文件头魔数校验测试 + 错误文案去噪验证。
///
/// 只校验字节魔数与文件读取，不加载 llamadart native，
/// 因此可在任意宿主（含 x64 CI）直接运行。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/gguf_probe.dart';

void main() {
  group('isGgufMagic', () {
    test('合法 GGUF 头返回 true', () {
      expect(isGgufMagic(<int>[0x47, 0x47, 0x55, 0x46]), isTrue);
      // 带后续字节的真实文件头也应命中。
      expect(isGgufMagic(<int>[0x47, 0x47, 0x55, 0x46, 0x00, 0x00]), isTrue);
    });

    test('非法/截断/HTML 错误页返回 false', () {
      expect(isGgufMagic(<int>[0x47, 0x47, 0x55]), isFalse); // 截断
      expect(isGgufMagic(<int>[]), isFalse);
      expect(isGgufMagic('<ht'.codeUnits), isFalse); // HTML 错误页
      expect(isGgufMagic(<int>[0x50, 0x4b, 0x03, 0x04]), isFalse); // ZIP
    });
  });

  group('checkGgufMagicFile', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangram_gguf_magic_test_');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('合法 GGUF 文件返回 null', () async {
      final f = File('${tmp.path}/ok.gguf');
      await f.writeAsBytes(<int>[0x47, 0x47, 0x55, 0x46, 0, 1, 2, 3]);
      expect(await checkGgufMagicFile(f), isNull);
    });

    test('损坏文件给出可读错误，不抛异常', () async {
      final f = File('${tmp.path}/bad.gguf');
      await f.writeAsBytes('<html>404</html>'.codeUnits);
      final err = await checkGgufMagicFile(f);
      expect(err, isNotNull);
      expect(err, contains('不是合法 GGUF'));
      expect(err, contains('重新下载'));
    });

    test('空文件给出可读错误', () async {
      final f = File('${tmp.path}/empty.gguf');
      await f.writeAsBytes(<int>[]);
      expect(await checkGgufMagicFile(f), isNotNull);
    });
  });
}
