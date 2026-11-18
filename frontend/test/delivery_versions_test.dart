/// 交付物版本化底座测试：真实文件、SHA-256、状态机与目录穿越防护。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/delivery_versions.dart';
import 'package:tangram/harness/store.dart';

void main() {
  late Directory tmp;
  late DeliveryVersions versions;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_delivery_versions_');
    HarnessStore.overrideForTest(tmp);
    final HarnessStore store = await HarnessStore.instance();
    versions = DeliveryVersions(store);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('保存两版：真实文件、SHA-256 与升序列表', () async {
    final DeliverableVersion v1 =
        await versions.saveDraft('周报', utf8.encode('第一版'), note: '初稿');
    final DeliverableVersion v2 =
        await versions.saveDraft('周报', utf8.encode('第二版'), note: '修订');

    expect(v1.version, 1);
    expect(v2.version, 2);
    expect(v1.sha256, sha256.convert(utf8.encode('第一版')).toString());
    expect(v2.sha256, sha256.convert(utf8.encode('第二版')).toString());
    expect(v1.filePath, 'work/deliverables/周报/v1.txt');
    expect(v2.filePath, 'work/deliverables/周报/v2.txt');

    final File f1 = File('${tmp.path}/${v1.filePath}');
    final File f2 = File('${tmp.path}/${v2.filePath}');
    expect(await f1.exists(), isTrue);
    expect(await f2.exists(), isTrue);
    expect(await f1.readAsString(), '第一版');
    expect(await f2.readAsString(), '第二版');

    final File indexFile =
        File('${tmp.path}/work/deliverables/周报/index.json');
    expect(await indexFile.exists(), isTrue);
    final Map<String, dynamic> index =
        jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
    expect((index['versions'] as List<dynamic>).length, 2);

    final List<DeliverableVersion> listed = await versions.list('周报');
    expect(listed.map((DeliverableVersion v) => v.version).toList(), <int>[1, 2]);
    expect(
      listed.every((DeliverableVersion v) => v.status == VersionStatus.draft),
      isTrue,
    );
    expect(await versions.readText('周报', 1), '第一版');
    expect(await versions.readText('周报', 2), '第二版');
    expect(await versions.list('不存在'), isEmpty);
  });

  test('draft 不能直接 final；submit 后才能 final', () async {
    final DeliverableVersion draft =
        await versions.saveDraft('方案', utf8.encode('内容'));

    await expectLater(
      versions.finalize('方案', draft.version),
      throwsStateError,
    );
    // 非法跳转不落盘，状态仍是 draft。
    expect((await versions.list('方案')).single.status, VersionStatus.draft);

    final DeliverableVersion reviewed =
        await versions.submit('方案', draft.version);
    expect(reviewed.status, VersionStatus.review);

    final DeliverableVersion finalized =
        await versions.finalize('方案', draft.version);
    expect(finalized.status, VersionStatus.final_);

    final List<DeliverableVersion> persisted = await versions.list('方案');
    expect(persisted.single.status, VersionStatus.final_);

    // final 之后再次 submit 也是非法转换。
    await expectLater(
      versions.submit('方案', draft.version),
      throwsStateError,
    );
  });

  test('revise 生成新 draft 且 parentVersion 指向来源版本', () async {
    final DeliverableVersion v1 =
        await versions.saveDraft('文档', utf8.encode('v1'));
    final DeliverableVersion v2 = await versions.revise(
      '文档',
      v1.version,
      utf8.encode('v2'),
      note: '基于 v1 修订',
    );

    expect(v2.version, 2);
    expect(v2.status, VersionStatus.draft);
    expect(v2.parentVersion, 1);
    expect(v2.sha256, sha256.convert(utf8.encode('v2')).toString());
    expect(await versions.readText('文档', 2), 'v2');

    final List<DeliverableVersion> listed = await versions.list('文档');
    expect(
      listed.map((DeliverableVersion v) => v.parentVersion).toList(),
      <int?>[null, 1],
    );

    await expectLater(
      versions.revise('文档', 99, utf8.encode('x')),
      throwsStateError,
    );
  });

  test('readText 读取不存在版本抛 StateError', () async {
    await versions.saveDraft('稿', utf8.encode('a'));

    await expectLater(versions.readText('稿', 99), throwsStateError);
    await expectLater(versions.readText('不存在', 1), throwsStateError);
  });

  test('名称含 ../ 被安全化且不会写出临时根目录', () async {
    final DeliverableVersion v =
        await versions.saveDraft('../evil', utf8.encode('x'));
    final String slug = DeliveryVersions.slug('../evil');

    expect(slug.contains('/'), isFalse);
    expect(slug.contains('\\'), isFalse);
    expect(slug.contains('..'), isFalse);
    expect(v.filePath.contains('..'), isFalse);
    expect(v.filePath, 'work/deliverables/$slug/v1.txt');

    final File written = File('${tmp.path}/${v.filePath}');
    expect(await written.exists(), isTrue);
    expect(await written.readAsString(), 'x');

    final String rootPrefix = '${tmp.absolute.path}${Platform.pathSeparator}';
    expect(written.absolute.path.startsWith(rootPrefix), isTrue);
    expect(
      await Directory('${tmp.path}/work/deliverables/$slug').exists(),
      isTrue,
    );
    expect(await versions.list('../evil'), hasLength(1));
  });
}
