/// 万物皆插件内核深化能力测试：原子热替换 + 依赖健康检查。
/// 与 plugin_kernel_test.dart 同规范：真实落盘语义（内存持久化真实实现），
/// 逐项断言，绝不使用 mock 冒充结果。

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/plugin_kernel.dart';

class _BaseProvider extends Plugin {
  final String marker;
  final String ver;
  final bool fail;
  _BaseProvider(this.marker, this.ver, {this.fail = false});

  @override
  String get id => 'hot.swap';
  @override
  String get name => 'HotSwap';
  @override
  String get version => ver;
  @override
  String get description => '热替换测试插件';
  @override
  List<String> get providesSeams => const <String>['hot/swap'];

  @override
  Future<void> apply(PluginContext ctx) async {
    if (fail) throw StateError('故意挂载失败');
    ctx.provideService('hot/service', marker);
    final CapabilitySeam s = ctx.seam('hot/swap', '热替换接缝');
    ctx.provideSeamProvider('hot/swap', 'p', marker,
        (String method, Map<String, dynamic> args) async {
      return <String, dynamic>{'ok': true, 'value': marker};
    });
    s.consumers.add('hot-consumer');
  }
}

class _NeedsService extends Plugin {
  @override
  String get id => 'needs.service';
  @override
  String get name => 'Needs';
  @override
  String get version => '1.0.0';
  @override
  String get description => '依赖 hot/service';
  @override
  List<String> get requires => const <String>['hot/service'];
  @override
  Future<void> apply(PluginContext ctx) async {
    ctx.require<String>('hot/service');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PluginKernel freshKernel() => PluginKernel(
        persistence: MemoryKernelPersistence(),
      );

  Future<void> boot(PluginKernel k) async {
    // 注册初始 provider（v1）到目录，再启动内核。
    k.registerPlugin(_BaseProvider('v1', '1.0.0'));
    await k.boot(
      builtinPlugins: <Plugin>[],
      defaultProfile: RuntimeProfile(
        't',
        't',
        RunMode.standard,
        <Bundle>[],
        <String, dynamic>{},
      ),
    );
  }

  group('PluginKernel 热替换 / 依赖健康检查', () {
    test('hotSwap 成功后 provider 返回值来自新插件', () async {
      final PluginKernel k = freshKernel();
      await boot(k);
      expect((await k.mount('hot.swap'))['ok'], true);
      final Map<String, dynamic> before =
          await k.invoke('hot/swap', 'x', <String, dynamic>{});
      expect((before['result'] as Map)['value'], 'v1');

      final Map<String, dynamic> r =
          await k.hotSwap('hot.swap', _BaseProvider('v2', '2.0.0'));
      expect(r['ok'], true);
      expect(r['to_version'], '2.0.0');
      final Map<String, dynamic> inv =
          await k.invoke('hot/swap', 'x', <String, dynamic>{});
      expect((inv['result'] as Map)['value'], 'v2');
    });

    test('hotSwap 失败自动回滚到旧插件，槽位仍可用', () async {
      final PluginKernel k = freshKernel();
      await boot(k);
      expect((await k.mount('hot.swap'))['ok'], true);

      final Map<String, dynamic> r = await k.hotSwap(
        'hot.swap',
        _BaseProvider('bad', '9.9.9', fail: true),
      );
      expect(r['ok'], false);
      expect(r['rollback_ok'], true);
      // 旧插件已挂回：仍能返回 v1，且槽位存在。
      final Map<String, dynamic> inv =
          await k.invoke('hot/swap', 'x', <String, dynamic>{});
      expect((inv['result'] as Map)['value'], 'v1');
      expect(k.mountedCount, 1);
    });

    test('hotSwap 拒绝 id 不一致的替换（换实现不换槽位）', () async {
      final PluginKernel k = freshKernel();
      await boot(k);
      expect((await k.mount('hot.swap'))['ok'], true);
      final Map<String, dynamic> r =
          await k.hotSwap('hot.swap', _NeedsService());
      expect(r['ok'], false);
      expect(r['error'].toString(), contains('必须等于目标槽位'));
    });

    test('verifyDependencies 检出「仍挂载但依赖缺失」', () async {
      final PluginKernel k = freshKernel();
      await boot(k);
      expect((await k.mount('hot.swap'))['ok'], true);
      k.registerPlugin(_NeedsService());
      expect((await k.mount('needs.service'))['ok'], true);

      Map<String, dynamic> ok = k.verifyDependencies();
      expect(ok['ok'], true);
      expect((ok['broken'] as List).isEmpty, true);

      // 卸载依赖提供者后，依赖方的服务消失 → 如实报告不一致。
      await k.unmount('hot.swap');
      Map<String, dynamic> bad = k.verifyDependencies();
      expect(bad['ok'], false);
      final List<dynamic> broken = bad['broken'] as List<dynamic>;
      expect(
        broken.any((dynamic e) =>
            (e as Map)['plugin'] == 'needs.service' &&
            (e)['missing_service'] == 'hot/service'),
        isTrue,
      );
    });
  });
}
