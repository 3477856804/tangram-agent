/// 目录映射真实行为：宿主 → 沙箱、回写、只读拒绝、敏感目录拒绝。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/workspace_mapping.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory harnessDir;
  late Directory hostDir;
  late HarnessStore store;
  late WorkspaceMappingService service;

  setUp(() async {
    harnessDir = await Directory.systemTemp.createTemp('tga_map_store_');
    hostDir = await Directory.systemTemp.createTemp('tga_map_host_');
    HarnessStore.overrideForTest(harnessDir);
    store = await HarnessStore.instance();
    service = WorkspaceMappingService(store);
  });

  tearDown(() async {
    for (final Directory d in <Directory>[harnessDir, hostDir]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  test('添加映射 → 同步到沙箱 → 修改后回写宿主', () async {
    await File('${hostDir.path}/a.txt').writeAsString('hello');
    await Directory('${hostDir.path}/sub').create();
    await File('${hostDir.path}/sub/b.md').writeAsString('# 文档');

    final Map<String, dynamic> added = await service.handle('add',
        <String, dynamic>{'host_path': hostDir.path, 'name': '项目目录'});
    expect(added['ok'], true);
    final Map mapping = added['mapping'] as Map;
    expect(mapping['mode'], 'rw');

    final Map<String, dynamic> sync = await service.handle(
        'sync_to_sandbox', <String, dynamic>{'id': mapping['id']});
    expect(sync['ok'], true);
    expect(sync['files'], 2);
    final String sandboxPath = sync['sandbox_path'].toString();
    expect(await File('$sandboxPath/a.txt').readAsString(), 'hello');
    expect(await File('$sandboxPath/sub/b.md').readAsString(), '# 文档');

    await File('$sandboxPath/a.txt').writeAsString('changed in sandbox');
    final Map<String, dynamic> back = await service.handle(
        'sync_to_host', <String, dynamic>{'id': mapping['id']});
    expect(back['ok'], true);
    expect(await File('${hostDir.path}/a.txt').readAsString(),
        'changed in sandbox');

    final Map<String, dynamic> preview = await service.handle(
        'preview', <String, dynamic>{'id': mapping['id']});
    final List entries = preview['entries'] as List;
    expect(entries.any((dynamic e) => (e as Map)['path'] == 'a.txt'), true);
  });

  test('只读映射禁止回写宿主', () async {
    await File('${hostDir.path}/a.txt').writeAsString('ro');
    final Map<String, dynamic> added = await service.handle('add',
        <String, dynamic>{'host_path': hostDir.path, 'mode': 'ro'});
    final Map mapping = added['mapping'] as Map;
    await service.handle(
        'sync_to_sandbox', <String, dynamic>{'id': mapping['id']});
    final Map<String, dynamic> back = await service.handle(
        'sync_to_host', <String, dynamic>{'id': mapping['id']});
    expect(back['ok'], false);
    expect(back['error'].toString(), contains('只读'));
  });

  test('敏感目录拒绝映射；不存在目录拒绝', () async {
    final Directory ssh = Directory('${hostDir.path}/.ssh');
    await ssh.create();
    final Map<String, dynamic> denied = await service.handle(
        'add', <String, dynamic>{'host_path': ssh.path});
    expect(denied['ok'], false);
    expect(denied['error'].toString(), contains('敏感'));

    final Map<String, dynamic> missing = await service.handle('add',
        <String, dynamic>{'host_path': '${hostDir.path}/not-exist'});
    expect(missing['ok'], false);
    expect(missing['error'].toString(), contains('不存在'));
  });

  test('移除映射默认保留沙箱文件，可显式删除', () async {
    await File('${hostDir.path}/a.txt').writeAsString('x');
    final Map<String, dynamic> added = await service.handle(
        'add', <String, dynamic>{'host_path': hostDir.path});
    final Map mapping = added['mapping'] as Map;
    final Map<String, dynamic> sync = await service.handle(
        'sync_to_sandbox', <String, dynamic>{'id': mapping['id']});
    final String sandboxPath = sync['sandbox_path'].toString();
    expect(await File('$sandboxPath/a.txt').exists(), true);

    await service.handle('remove', <String, dynamic>{'id': mapping['id']});
    expect(await File('$sandboxPath/a.txt').exists(), true);

    final Map<String, dynamic> added2 = await service.handle(
        'add', <String, dynamic>{'host_path': hostDir.path});
    final Map mapping2 = added2['mapping'] as Map;
    final Map<String, dynamic> sync2 = await service.handle(
        'sync_to_sandbox', <String, dynamic>{'id': mapping2['id']});
    final String path2 = sync2['sandbox_path'].toString();
    await service.handle('remove', <String, dynamic>{
      'id': mapping2['id'],
      'delete_files': true,
    });
    expect(await Directory(path2).exists(), false);
  });
}
