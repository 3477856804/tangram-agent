// 0.0.41 守卫 / 快照 / WASM 契约测试（纯函数与序列化，不依赖平台通道）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/kernel_guard.dart';
import 'package:tangram/harness/plugin_tier.dart';
import 'package:tangram/harness/wasm_module.dart';

void main() {
  group('能力令牌', () {
    test('默认高权限接缝必须带令牌', () {
      final Map<String, List<String>> caps = defaultSeamCaps();
      expect(caps['core/sandbox'], contains('sandbox:exec'));
      expect(caps['core/im'], contains('channel:send'));
      expect(caps['core/mcp'], contains('net:fetch'));
    });

    test('root 调用方不受限（UI 直通）', () {
      expect(kRootCaller, 'ui');
    });

    test('T3 未声明 caps 一律拒绝', () {
      expect(seamAllowed(PluginTier.thirdParty, const <String>[], 'core/im'), isFalse);
      expect(
          seamAllowed(PluginTier.thirdParty, const <String>['channel:send'], 'core/im'),
          isTrue);
    });
  });

  group('内核快照序列化', () {
    test('toJson/fromJson 往返一致', () {
      final KernelSnapshot s = KernelSnapshot(
        id: 'ksnap-1',
        label: '装插件前',
        at: '2026-11-25T01:00:00.000',
        nodes: <Map<String, dynamic>>[
          <String, dynamic>{'id': 'p1', 'parent': null, 'tier': 'T1'},
        ],
        seams: <Map<String, dynamic>>[
          <String, dynamic>{'name': 'core/model', 'active': 'auto'},
        ],
        services: <String>['creator.demo'],
        mode: 'standard',
        seq: 42,
      );
      final KernelSnapshot back =
          KernelSnapshot.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.id, 'ksnap-1');
      expect(back.nodeIds, <String>{'p1'});
      expect(back.services, <String>['creator.demo']);
      expect(back.seq, 42);
    });

    test('坏数据不炸：缺字段给空', () {
      final KernelSnapshot s = KernelSnapshot.fromJson(<String, dynamic>{});
      expect(s.nodes, isEmpty);
      expect(s.nodeIds, isEmpty);
      expect(s.seq, 0);
    });
  });

  group('WASM 契约', () {
    test('帧编解码往返', () {
      final Uint8List frame = WasmModule.encodeFrame(<String, dynamic>{'a': 1});
      expect(frame.length, greaterThan(4));
      expect(WasmModule.decodeFrame(frame), <String, dynamic>{'a': 1});
    });

    test('ABI 不匹配即类型化拒绝', () {
      expect(() => WasmModule.load(<String, dynamic>{'abi': 'wasm/2', 'caps': <String>['fs:read']}),
          throwsA(isA<WasmContractError>()));
    });

    test('T3 模块无 caps 即拒绝', () {
      expect(() => WasmModule.load(<String, dynamic>{'abi': 'wasm/1', 'module': 'x.wasm'}),
          throwsA(isA<WasmContractError>()));
    });

    test('合法清单因无运行时抛 WasmUnavailable', () {
      expect(
        () => WasmModule.load(<String, dynamic>{
          'abi': 'wasm/1',
          'module': 'x.wasm',
          'caps': <String>['fs:read'],
          'limits': <String, dynamic>{'memoryPages': 32},
        }),
        throwsA(isA<WasmUnavailable>()),
      );
    });
  });
}
