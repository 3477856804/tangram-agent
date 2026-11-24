// 插件分级与能力令牌（T0–T3）测试。
// 对应 0.0.41 融合：caps 为空＝不限制；T3 未声明即拒绝；地址非法即抛。

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/plugin_tier.dart';

void main() {
  test('tier 解析：线上写法 / 枚举名 / 未知兜底 official', () {
    expect(PluginTier.parse('T3'), PluginTier.thirdParty);
    expect(PluginTier.parse('system'), PluginTier.system);
    expect(PluginTier.parse('third_party'), PluginTier.thirdParty);
    expect(PluginTier.parse(null), PluginTier.official);
    expect(PluginTier.parse('T9'), PluginTier.official);
  });

  test('seamAllowed：空 caps 只拒 T3', () {
    const List<String> none = <String>[];
    expect(seamAllowed(PluginTier.system, none, 'net'), isTrue);
    expect(seamAllowed(PluginTier.official, none, 'net'), isTrue);
    expect(seamAllowed(PluginTier.user, none, 'net'), isTrue);
    expect(seamAllowed(PluginTier.thirdParty, none, 'net'), isFalse);
    expect(seamAllowed(PluginTier.thirdParty, const <String>['net'], 'net'), isTrue);
    expect(seamAllowed(PluginTier.thirdParty, const <String>['fs'], 'net'), isFalse);
  });

  test('parsePluginAddress：合法与非法', () {
    final ({String scheme, String path}) a = parsePluginAddress('pkg.mod:attr');
    expect(a.scheme, 'pkg.mod');
    expect(a.path, 'attr');
    expect(() => parsePluginAddress('nope'), throwsFormatException);
    expect(() => parsePluginAddress(':x'), throwsFormatException);
    expect(() => parsePluginAddress('pkg:'), throwsFormatException);
    expect(() => parsePluginAddress('  '), throwsFormatException);
  });

  test('CapabilityDenied 消息可定位', () {
    final CapabilityDenied e =
        CapabilityDenied('p1', 'net:fetch', 'caps 未声明该接缝（tier=T3）');
    expect(e.toString(), contains('p1'));
    expect(e.toString(), contains('net:fetch'));
  });
}
