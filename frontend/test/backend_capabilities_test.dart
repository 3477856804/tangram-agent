/// 内嵌后端新增能力测试：3D 建模动作、统一环境自检、主动发送拒绝语义。
///
/// 全部走真实 `EmbeddedBackend.dispatch`，落盘到临时目录；断言的是真实
/// 返回结构与真实文件，不用 mock 响应。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;
  late EmbeddedBackend backend;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_caps_test_');
    for (final String sub in <String>[
      'models', 'cards', 'plugins', 'work', 'downloads', 'sandbox'
    ]) {
      await Directory('${tmp.path}/$sub').create(recursive: true);
    }
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
    backend = EmbeddedBackend.forTest(store);
  });

  tearDown(() async {
    await backend.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> call(
    String topic, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final reply = await backend.dispatch(topic, payload);
    return reply.payload;
  }

  group('3D 建模', () {
    test('生成立方体：统计为真实几何值', () async {
      final Map<String, dynamic> r = await call(
          'code_task', <String, dynamic>{
        'action': 'model3d_primitive',
        'kind': 'cube',
      });
      expect(r['ok'], isTrue);
      final Map<String, dynamic> stats =
          (r['stats'] as Map).cast<String, dynamic>();
      expect(stats['vertices'], 8);
      expect(stats['triangles'], 12);
      expect(stats['watertight'], isTrue);
      expect((stats['volume'] as num).toDouble(), closeTo(1, 1e-6));
      final Map<String, dynamic> mesh =
          (r['mesh'] as Map).cast<String, dynamic>();
      expect((mesh['vertices'] as List).length, 24);
      expect((mesh['faces'] as List).length, 36);
    });

    test('低模鹿可生成且面数充足', () async {
      final Map<String, dynamic> r = await call(
          'code_task', <String, dynamic>{
        'action': 'model3d_primitive',
        'kind': 'deer',
      });
      expect(r['ok'], isTrue);
      final Map<String, dynamic> stats =
          (r['stats'] as Map).cast<String, dynamic>();
      expect(stats['triangles'] as int, greaterThan(50));
    });

    test('导出 OBJ 真实写盘，再导入能读回', () async {
      await call('code_task', <String, dynamic>{
        'action': 'model3d_primitive',
        'kind': 'cube',
      });
      final Map<String, dynamic> exp = await call(
          'code_task', <String, dynamic>{
        'action': 'model3d_export',
        'format': 'obj',
        'name': 'unit-cube',
      });
      expect(exp['ok'], isTrue);
      final File f = File(exp['path'] as String);
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(100));
      expect(f.readAsStringSync().startsWith('# TGA 3D Studio'), isTrue);

      final Map<String, dynamic> imp = await call(
          'code_task', <String, dynamic>{
        'action': 'model3d_import',
        'path': exp['path'],
      });
      expect(imp['ok'], isTrue, reason: '导入返回：$imp');
      final Map<String, dynamic> stats =
          (imp['stats'] as Map).cast<String, dynamic>();
      expect(stats['vertices'], 8);
      expect(stats['triangles'], 12);
    });

    test('导出 STL 字节数为 84 + 50×面数', () async {
      await call('code_task', <String, dynamic>{
        'action': 'model3d_primitive',
        'kind': 'cube',
      });
      final Map<String, dynamic> exp = await call(
          'code_task', <String, dynamic>{
        'action': 'model3d_export',
        'format': 'stl',
        'name': 'unit-cube',
      });
      expect(exp['ok'], isTrue);
      expect(exp['bytes'], 84 + 12 * 50);
    });

    test('不存在的模型路径如实失败', () async {
      final Map<String, dynamic> r = await call(
          'code_task', <String, dynamic>{
        'action': 'model3d_import',
        'path': 'models3d/not-there.obj',
      });
      expect(r['ok'], isFalse);
      expect((r['error'] as String).contains('不存在'), isTrue);
    });

    test('未知图元如实拒绝', () async {
      final Map<String, dynamic> r = await call(
          'code_task', <String, dynamic>{
        'action': 'model3d_primitive',
        'kind': 'dragon',
      });
      expect(r['ok'], isFalse);
      expect((r['error'] as String).contains('dragon'), isTrue);
    });
  });

  group('统一环境自检', () {
    test('返回唯一环境口径与真实探测字段', () async {
      final Map<String, dynamic> r =
          await call('code_task', <String, dynamic>{'action': 'env_report'});
      expect(r['single_environment'], isTrue);
      expect(r['platform'], Platform.operatingSystem);
      expect(r.containsKey('environment'), isTrue);
      // 桌面端返回系统 shell 的真实探测结果（Windows 下为 ver 输出）。
      expect(r.containsKey('kernel'), isTrue);
    });
  });

  group('主动发送', () {
    test('目标簿初始为空且结构合法', () async {
      final Map<String, dynamic> r = await call(
          'im_event', <String, dynamic>{'action': 'send_targets'});
      expect(r['ok'], isTrue);
      expect(r['targets'], isA<Map>());
    });

    test('空内容被拒绝', () async {
      final Map<String, dynamic> r = await call(
          'im_event', <String, dynamic>{
        'action': 'send',
        'connector': 'wechat',
        'to': 'someone',
        'text': '   ',
      });
      expect(r['ok'], isFalse);
      expect((r['error'] as String).contains('内容为空'), isTrue);
    });

    test('未登录的微信如实失败，不伪造成功', () async {
      final Map<String, dynamic> r = await call(
          'im_event', <String, dynamic>{
        'action': 'send',
        'connector': 'wechat',
        'to': 'someone',
        'text': '你好',
      });
      expect(r['ok'], isFalse);
      expect((r['error'] as String).isNotEmpty, isTrue);
    });

    test('未知渠道直接报错', () async {
      final Map<String, dynamic> r = await call(
          'im_event', <String, dynamic>{
        'action': 'send',
        'connector': 'telegram',
        'to': 'x',
        'text': 'hi',
      });
      expect(r['ok'], isFalse);
      expect((r['error'] as String).contains('未知渠道'), isTrue);
    });
  });
}