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

  test('link 映射：open/resolve 返回链接与宿主路径且内容一致', () async {
    await File('${hostDir.path}/a.txt').writeAsString('hello-link');
    final Map<String, dynamic> added = await service.handle(
        'add', <String, dynamic>{'host_path': hostDir.path, 'mode': 'link'});
    expect(added['ok'], true, reason: added['error']?.toString());
    expect(added['bind_supported'], true);
    final Map mapping = added['mapping'] as Map;
    expect(mapping['mode'], 'link');
    expect(mapping['bind_mode'], 'link');
    expect(mapping['link_target'], Directory(hostDir.path).absolute.path);

    final Map<String, dynamic> opened =
        await service.handle('open', <String, dynamic>{'id': mapping['id']});
    expect(opened['ok'], true, reason: opened['error']?.toString());
    expect(opened['mode'], 'link');
    expect(opened['bind_supported'], true);
    final String linkPath = opened['link_path'].toString();
    final String hostPath = opened['host_path'].toString();
    expect(hostPath, Directory(hostDir.path).absolute.path);
    expect(await File('$linkPath/a.txt').readAsString(), 'hello-link');
    expect(await File('$hostPath/a.txt').readAsString(), 'hello-link');

    // 通过沙箱链接写入，内容即时落到宿主真实目录。
    await File('$linkPath/a.txt').writeAsString('via-link');
    expect(await File('${hostDir.path}/a.txt').readAsString(), 'via-link');

    final Map<String, dynamic> resolved =
        await service.handle('resolve', <String, dynamic>{'id': mapping['id']});
    expect(resolved['ok'], true);
    expect(resolved['mode'], 'link');
    expect(resolved['link_target'], hostPath);
  }, skip: _symlinkSupported ? false : '测试环境不支持符号链接，跳过 link 用例');

  test('只读 link 映射禁止写入，写前过 guard(write, host)', () async {
    final List<String> guardedCalls = <String>[];
    final WorkspaceMappingService guarded = WorkspaceMappingService(
      store,
      guard: (String tool, String path) async {
        guardedCalls.add('$tool:$path');
        return tool != 'write';
      },
    );
    final Map<String, dynamic> added = await guarded.handle('add',
        <String, dynamic>{
          'host_path': hostDir.path,
          'mode': 'link',
          'access': 'ro',
        });
    expect(added['ok'], true, reason: added['error']?.toString());
    final Map mapping = added['mapping'] as Map;

    final Map<String, dynamic> writeOpen = await guarded.handle(
        'open', <String, dynamic>{'id': mapping['id'], 'write': true});
    expect(writeOpen['ok'], false);
    expect(writeOpen['error'].toString(), contains('只读'));

    final Map<String, dynamic> back = await guarded.handle(
        'sync_to_host', <String, dynamic>{'id': mapping['id']});
    expect(back['ok'], false);
    expect(back['error'].toString(), contains('只读'));

    // 读写的 link：写入前确实调用 guard('write', 宿主路径)，拒绝时不返回可写路径。
    final Directory rwDir = Directory('${hostDir.path}/rw');
    await rwDir.create();
    final Map<String, dynamic> addedRw = await guarded.handle('add',
        <String, dynamic>{'host_path': rwDir.path, 'mode': 'link'});
    expect(addedRw['ok'], true, reason: addedRw['error']?.toString());
    final Map mappingRw = addedRw['mapping'] as Map;
    guardedCalls.clear();
    final Map<String, dynamic> denied = await guarded.handle(
        'open', <String, dynamic>{'id': mappingRw['id'], 'write': true});
    expect(denied['ok'], false);
    expect(denied['denied'], true);
    expect(
        guardedCalls.contains(
            'write:${Directory(rwDir.path).absolute.path}'),
        true);
  }, skip: _symlinkSupported ? false : '测试环境不支持符号链接，跳过 link 用例');

  test('link 模式仍拒绝敏感目录', () async {
    final Directory ssh = Directory('${hostDir.path}/.ssh');
    await ssh.create();
    final Map<String, dynamic> denied = await service.handle(
        'add', <String, dynamic>{'host_path': ssh.path, 'mode': 'link'});
    expect(denied['ok'], false);
    expect(denied['error'].toString(), contains('敏感'));

    final Map<String, dynamic> list =
        await service.handle('list', <String, dynamic>{});
    expect(list['mappings'] as List, isEmpty);
  }, skip: _symlinkSupported ? false : '测试环境不支持符号链接，跳过 link 用例');

  test('mode=copy 行为不变：真实复制而非链接', () async {
    await File('${hostDir.path}/a.txt').writeAsString('copy');
    final Map<String, dynamic> added = await service.handle(
        'add', <String, dynamic>{'host_path': hostDir.path, 'mode': 'copy'});
    expect(added['ok'], true, reason: added['error']?.toString());
    final Map mapping = added['mapping'] as Map;
    expect(mapping['mode'], 'rw');
    expect(mapping['bind_mode'], 'copy');
    expect(mapping['link_target'], '');

    final Map<String, dynamic> sync = await service.handle(
        'sync_to_sandbox', <String, dynamic>{'id': mapping['id']});
    expect(sync['ok'], true);
    expect(sync['files'], 1);
    final String sandboxPath = sync['sandbox_path'].toString();
    expect(await File('$sandboxPath/a.txt').readAsString(), 'copy');
    expect(await Link(sandboxPath).exists(), false);

    final Map<String, dynamic> opened =
        await service.handle('open', <String, dynamic>{'id': mapping['id']});
    expect(opened['ok'], true);
    expect(opened['mode'], 'copy');
    expect(opened['sandbox_path'], sandboxPath);
    expect(opened['bind_supported'], WorkspaceMappingService.bindSupported);
  });
}

/// 探测当前测试环境是否支持创建符号链接（Windows 需开发者模式/权限）。
bool _probeSymlink() {
  final Directory probe =
      Directory.systemTemp.createTempSync('tga_link_probe_');
  try {
    final Link link = Link('${probe.path}/target_link');
    link.createSync(probe.path);
    link.deleteSync();
    return true;
  } on Object {
    return false;
  } finally {
    if (probe.existsSync()) probe.deleteSync(recursive: true);
  }
}

/// 链接用例的 skip 条件：环境不支持 symlink 时跳过并说明原因。
final bool _symlinkSupported = _probeSymlink();
