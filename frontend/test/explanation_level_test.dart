/// 分层解释 / 因材施教的真实行为测试。
///
/// 覆盖：关键词识别与优先级、显式偏好优先、每级提示词的关键约束，
/// 以及偏好在 HarnessStore 临时目录中的真实落盘 / 重载往返与损坏回退。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/explanation_level.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudienceDetector.detect 关键词识别', () {
    test('代码类关键词 → developer', () {
      for (final String text in <String>[
        '这段代码为什么报错',
        '怎么编译这个项目',
        'API 返回 401 怎么处理',
        'Dart 的异步怎么写',
        'Python 脚本跑不起来',
      ]) {
        expect(AudienceDetector.detect(text), AudienceLevel.developer,
            reason: text);
      }
    });

    test('交易类关键词 → trader', () {
      for (final String text in <String>['帮我回测一下', '仓位怎么分', '止损设多少', '这个策略靠谱吗']) {
        expect(AudienceDetector.detect(text), AudienceLevel.trader,
            reason: text);
      }
    });

    test('创作类关键词 → creator', () {
      for (final String text in <String>['这个剪辑节奏怎么调', '帮我写分镜', '文案怎么写', '账号怎么涨粉']) {
        expect(AudienceDetector.detect(text), AudienceLevel.creator,
            reason: text);
      }
    });

    test('新手类关键词 → novice', () {
      for (final String text in <String>['这个怎么用', '我是新手', '入门该学什么', '机器学习是什么']) {
        expect(AudienceDetector.detect(text), AudienceLevel.novice,
            reason: text);
      }
    });

    test('无信号 → auto；多类信号按 开发者 优先', () {
      expect(AudienceDetector.detect('今天天气不错'), AudienceLevel.auto);
      expect(AudienceDetector.detect(''), AudienceLevel.auto);
      expect(AudienceDetector.detect('新手怎么用代码写策略'),
          AudienceLevel.developer);
    });

    test('preferred 非 auto 时直接采纳用户选择', () {
      expect(
        AudienceDetector.detect('这段代码怎么编译',
            preferred: AudienceLevel.trader),
        AudienceLevel.trader,
      );
      expect(
        AudienceDetector.detect('今天天气不错',
            preferred: AudienceLevel.creator),
        AudienceLevel.creator,
      );
      expect(
        AudienceDetector.detect('这段代码怎么编译',
            preferred: AudienceLevel.auto),
        AudienceLevel.developer,
      );
    });
  });

  group('ExplanationStyle.hint 每级提示词', () {
    test('每级非空且包含关键约束', () {
      for (final AudienceLevel level in AudienceLevel.values) {
        final String hint = ExplanationStyle.hint(level);
        expect(hint.trim().isNotEmpty, true, reason: level.name);
        expect(hint.contains('不编造') || hint.contains('禁止编造'), true,
            reason: level.name);
      }
      final String novice = ExplanationStyle.hint(AudienceLevel.novice);
      expect(novice.contains('类比'), true);
      expect(novice.contains('步骤'), true);

      final String developer = ExplanationStyle.hint(AudienceLevel.developer);
      expect(developer.contains('参数'), true);
      expect(developer.contains('文件路径'), true);
      expect(developer.contains('源码'), true);

      final String trader = ExplanationStyle.hint(AudienceLevel.trader);
      expect(trader.contains('回撤'), true);
      expect(trader.contains('风险'), true);
      expect(trader.contains('合规'), true);

      final String creator = ExplanationStyle.hint(AudienceLevel.creator);
      expect(creator.contains('分镜'), true);
      expect(creator.contains('节奏'), true);
      expect(creator.contains('素材清单'), true);

      final String auto = ExplanationStyle.hint(AudienceLevel.auto);
      expect(auto.contains('判断'), true);
    });
  });

  group('ExplanationLevelPref 真实落盘', () {
    late Directory tmp;
    late HarnessStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangram_explanation_test_');
      HarnessStore.overrideForTest(tmp);
      store = await HarnessStore.instance();
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('保存后重载一致', () async {
      expect(await ExplanationLevelPref.save(store, AudienceLevel.developer),
          true);
      expect(store.file('prefs/explanation_level.json').existsSync(), true);
      expect(await ExplanationLevelPref.load(store), AudienceLevel.developer);

      expect(await ExplanationLevelPref.save(store, AudienceLevel.creator),
          true);
      expect(await ExplanationLevelPref.load(store), AudienceLevel.creator);
    });

    test('文件缺失回退 auto', () async {
      expect(await ExplanationLevelPref.load(store), AudienceLevel.auto);
    });

    test('文件损坏或取值未知回退 auto', () async {
      final File f = store.file('prefs/explanation_level.json');
      await f.parent.create(recursive: true);
      await f.writeAsString('{not json');
      expect(await ExplanationLevelPref.load(store), AudienceLevel.auto);

      await store.writeJson(
          'prefs/explanation_level.json', <String, dynamic>{'level': 'alien'});
      expect(await ExplanationLevelPref.load(store), AudienceLevel.auto);
    });
  });
}
