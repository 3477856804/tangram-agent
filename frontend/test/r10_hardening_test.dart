import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/ui_customization.dart';

void main() {
  late Directory tmp;
  late HarnessStore store;
  late EmbeddedBackend backend;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_r10_');
    for (final String sub in <String>[
      'models',
      'cards',
      'plugins',
      'work',
      'downloads',
      'sandbox',
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
    final dynamic raw = reply.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': 'payload 不是 Map'};
  }

  group('用户策略优先级', () {
    test('新增 deny 规则优先于内置 allow，delete 不再落到 fallback ask', () async {
      final Map<String, dynamic> saved = await call(
        'security_approval',
        <String, dynamic>{
          'action': 'policy_set',
          'rule': <String, dynamic>{
            'id': 'user-deny-delete',
            'tool': r'^workspace\.delete$',
            'decision': 'deny',
            'note': '测试：删除一律拒绝',
          },
        },
      );
      expect(saved['ok'], true);

      final Map<String, dynamic> evaluated = await call(
        'security_approval',
        <String, dynamic>{
          'action': 'policy_evaluate',
          'tool': 'workspace.delete',
          'path': '/tmp/a.txt',
        },
      );
      expect(evaluated['decision'], 'deny');
    });

    test('用户规则不能绕过内置私钥拒绝', () async {
      await call('security_approval', <String, dynamic>{
        'action': 'policy_set',
        'rule': <String, dynamic>{
          'id': 'user-allow-workspace',
          'tool': r'^workspace\.read$',
          'decision': 'allow',
          'note': '测试：普通读取放行',
        },
      });
      final Map<String, dynamic> evaluated = await call(
        'security_approval',
        <String, dynamic>{
          'action': 'policy_evaluate',
          'tool': 'workspace.read',
          'path': '/root/.ssh/id_rsa',
        },
      );
      expect(evaluated['decision'], 'deny');
    });
  });

  group('审批一次性放行', () {
    test('ask 拦截 → 批准 → 重试真实执行 → 凭据只消费一次', () async {
      final Map<String, dynamic> rule = await call(
        'security_approval',
        <String, dynamic>{
          'action': 'policy_set',
          'rule': <String, dynamic>{
            'id': 'user-ask-gate',
            'tool': r'^shell$',
            'args': 'gate-test',
            'decision': 'ask',
            'note': '测试：命中 gate-test 需审批',
          },
        },
      );
      expect(rule['ok'], true);

      final Map<String, dynamic> blocked = await call(
        'code_task',
        <String, dynamic>{'action': 'shell', 'command': 'echo gate-test'},
      );
      expect(blocked['ok'], false);
      expect(blocked['error'].toString(), contains('审批'));

      final Map<String, dynamic> listed = await call(
        'security_approval',
        <String, dynamic>{'action': 'list'},
      );
      final List<dynamic> approvals =
          (listed['approvals'] as List<dynamic>?) ?? const <dynamic>[];
      final Map<String, dynamic> pending = approvals
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .firstWhere((Map<String, dynamic> e) =>
              e['status'] == 'pending' &&
              e['grant_key'] == 'shell|echo gate-test');
      final Map<String, dynamic> approved = await call(
        'security_approval',
        <String, dynamic>{'action': 'approve', 'id': pending['id']},
      );
      expect(approved['ok'], true);

      final Map<String, dynamic> ran = await call(
        'code_task',
        <String, dynamic>{'action': 'shell', 'command': 'echo gate-test'},
      );
      expect(ran['ok'], true);
      expect(ran.toString(), contains('gate-test'));

      final Map<String, dynamic> blockedAgain = await call(
        'code_task',
        <String, dynamic>{'action': 'shell', 'command': 'echo gate-test'},
      );
      expect(blockedAgain['ok'], false,
          reason: '一次性凭据消费后必须重新审批');
    });
  });

  group('旧版界面配置迁移', () {
    test('version<2 时自动补回安全中心与性能诊断入口', () async {
      final File file = File('${tmp.path}/ui_customization.json');
      await file.writeAsString(jsonEncode(<String, dynamic>{
        'version': 1,
        'active_scope': 'global',
        'global': <String, dynamic>{
          'accentPreset': 'blue',
          'surfacePreset': 'auto',
          'fontScale': 1,
          'density': 'comfortable',
          'radius': 16,
          'sidebarGrouping': true,
          'visibleNavKeys': <String>['sidebar.workspace', 'sidebar.compute'],
          'composerFloating': false,
          'scope': 'global',
          'themePackVersion': 1,
        },
      }));

      final UiCustomizationStore loaded = await UiCustomizationStore.load(store);
      final List<String> keys =
          loaded.apply(UiScope.global).visibleNavKeys;
      expect(keys, contains('sidebar.security'));
      expect(keys, contains('sidebar.performance'));
      expect(keys, contains('sidebar.workspace'));
    });
  });
}
