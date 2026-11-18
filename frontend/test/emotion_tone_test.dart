/// 情绪感知与连贯的真实行为测试。
///
/// 覆盖词库极性、否定翻转、空文本不编造、EMA 平滑方向、decay 回归、
/// 真实落盘重载、summaryBlock 约束，以及 PresenceStore 的接入点。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/emotion_tone.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/services/presence_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore harness;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_emotion_test_');
    HarnessStore.overrideForTest(tmp);
    harness = await HarnessStore.instance();
  });

  tearDown(() async {
    // EmotionContinuity 的落盘是 unawaited 的，tearDown 可能抢在写入
    // 完成前删除临时目录，导致「Directory not empty」。这里短重试，
    // 只清测试目录，不影响被测逻辑。
    for (var i = 0; i < 5; i++) {
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
  });

  group('词库极性', () {
    test('六类关键词分别给出正确符号与标签', () {
      final EmotionReading joy = EmotionLexicon.analyze('今天太开心了，谢谢');
      expect(joy.label, EmotionLabel.joy);
      expect(joy.valence, greaterThan(0));
      expect(joy.confidence, greaterThan(0));

      final EmotionReading calm = EmotionLexicon.analyze('现在很平静，放松一下');
      expect(calm.label, EmotionLabel.calm);
      expect(calm.valence, greaterThan(0));

      final EmotionReading sad = EmotionLexicon.analyze('有点难过，想哭');
      expect(sad.label, EmotionLabel.sad);
      expect(sad.valence, lessThan(0));

      final EmotionReading angry = EmotionLexicon.analyze('烦死了，真的受不了');
      expect(angry.label, EmotionLabel.angry);
      expect(angry.valence, lessThan(0));

      final EmotionReading anxious = EmotionLexicon.analyze('我很焦虑，担心明天');
      expect(anxious.label, EmotionLabel.anxious);
      expect(anxious.valence, lessThan(0));

      final EmotionReading tired = EmotionLexicon.analyze('好累，想睡');
      expect(tired.label, EmotionLabel.tired);
      expect(tired.valence, lessThan(0));
    });

    test('英文关键词同样可识别', () {
      final EmotionReading r = EmotionLexicon.analyze('I am so happy, thanks');
      expect(r.label, EmotionLabel.joy);
      expect(r.valence, greaterThan(0));

      final EmotionReading negative = EmotionLexicon.analyze('I feel so lonely');
      expect(negative.label, EmotionLabel.sad);
      expect(negative.valence, lessThan(0));
    });

    test('感叹号抬高能量但不改变极性', () {
      final EmotionReading plain = EmotionLexicon.analyze('开心');
      final EmotionReading loud = EmotionLexicon.analyze('开心！！！');
      expect(loud.label, EmotionLabel.joy);
      expect(loud.arousal, greaterThan(plain.arousal));
      expect(loud.arousal, lessThanOrEqualTo(1));
    });
  });

  group('否定词翻转', () {
    test('中文否定词把正向极性翻负', () {
      final EmotionReading r = EmotionLexicon.analyze('我不开心');
      expect(r.label, EmotionLabel.sad);
      expect(r.valence, lessThan(0));
      expect(r.hits, contains('不·开心'));
    });

    test('中文否定词把负向极性翻正', () {
      final EmotionReading r = EmotionLexicon.analyze('别担心');
      expect(r.label, EmotionLabel.calm);
      expect(r.valence, greaterThan(0));
    });

    test('英文 never 翻转邻近词', () {
      final EmotionReading r = EmotionLexicon.analyze('never happy');
      expect(r.valence, lessThan(0));
    });

    test('特别 / 不错 不是否定词', () {
      final EmotionReading special = EmotionLexicon.analyze('特别开心');
      expect(special.label, EmotionLabel.joy);
      expect(special.valence, greaterThan(0));

      final EmotionReading notBad = EmotionLexicon.analyze('不错，挺开心的');
      expect(notBad.label, EmotionLabel.joy);
      expect(notBad.valence, greaterThan(0));
    });
  });

  group('空文本不编造', () {
    test('空串与纯空白返回 neutral 且 confidence 0', () {
      for (final String text in <String>['', '   ', '\n\t']) {
        final EmotionReading r = EmotionLexicon.analyze(text);
        expect(r.label, EmotionLabel.neutral);
        expect(r.confidence, 0);
        expect(r.hits, isEmpty);
      }
    });

    test('无命中文本返回 neutral 且没有 hits', () {
      final EmotionReading r = EmotionLexicon.analyze('明天下午三点开会');
      expect(r.label, EmotionLabel.neutral);
      expect(r.confidence, 0);
      expect(r.hits, isEmpty);
      expect(r.valence, 0);
    });
  });

  group('EMA 平滑', () {
    test('新 0.35 / 旧 0.65，标签取置信度更高者', () {
      final EmotionContinuity c = EmotionContinuity(store: harness);
      final EmotionReading first = c.update(const EmotionReading(
        label: EmotionLabel.joy,
        valence: 1,
        arousal: 1,
        confidence: 0.8,
        hits: <String>['开心'],
      ));
      expect(first.valence, closeTo(0.35, 1e-9));
      expect(first.arousal, closeTo(0.35 + 0.65 * 0.3, 1e-9));
      expect(first.label, EmotionLabel.joy);

      final EmotionReading second = c.update(const EmotionReading(
        label: EmotionLabel.angry,
        valence: -1,
        arousal: 0.9,
        confidence: 0.9,
        hits: <String>['生气'],
      ));
      expect(second.valence, closeTo(-0.35 + 0.65 * 0.35, 1e-9));
      expect(second.valence, lessThan(first.valence));
      expect(second.label, EmotionLabel.angry);

      // 置信度更低的新标签不覆盖已有标签。
      final EmotionReading third = c.update(const EmotionReading(
        label: EmotionLabel.tired,
        valence: 0.5,
        arousal: 0.2,
        confidence: 0.1,
      ));
      expect(third.label, EmotionLabel.angry);
    });

    test('confidence 为 0 的读数被忽略，保持连贯', () {
      final EmotionContinuity c = EmotionContinuity(store: harness);
      final EmotionReading before = c.update(const EmotionReading(
        label: EmotionLabel.sad,
        valence: -0.8,
        arousal: 0.5,
        confidence: 0.7,
      ));
      final EmotionReading after = c.update(EmotionReading.neutral);
      expect(after, same(before));
      expect(c.current.valence, before.valence);
      expect(c.history, hasLength(1));
    });

    test('历史最多保留 20 条', () {
      final EmotionContinuity c = EmotionContinuity(store: harness);
      for (var i = 0; i < 30; i++) {
        c.update(EmotionReading(
          label: EmotionLabel.joy,
          valence: 0.5,
          arousal: 0.5,
          confidence: 0.5,
          hits: <String>['开心$i'],
        ));
      }
      expect(c.history, hasLength(EmotionContinuity.maxHistory));
      expect(c.history.last.hits, contains('开心29'));
    });
  });

  group('decay 回归', () {
    test('每次向中性衰减 10%，最终回到 neutral', () {
      final EmotionContinuity c = EmotionContinuity(store: harness);
      c.update(const EmotionReading(
        label: EmotionLabel.joy,
        valence: 0.8,
        arousal: 0.9,
        confidence: 0.8,
      ));
      final EmotionReading before = c.current;
      final EmotionReading first = c.decay();
      expect(first.valence, closeTo(before.valence * 0.9, 1e-9));
      expect(
        first.arousal,
        closeTo(before.arousal + (0.3 - before.arousal) * 0.1, 1e-9),
      );
      expect(first.arousal, lessThan(before.arousal));
      expect(first.label, EmotionLabel.joy);

      for (var i = 0; i < 40; i++) {
        c.decay();
      }
      expect(c.current.label, EmotionLabel.neutral);
      expect(c.current.valence.abs(), lessThan(0.08));
    });
  });

  group('落盘与容错', () {
    test('真实写入 presence/emotion_state.json 并可重载', () async {
      final EmotionContinuity c = EmotionContinuity(store: harness);
      c.update(const EmotionReading(
        label: EmotionLabel.anxious,
        valence: -0.6,
        arousal: 0.7,
        confidence: 0.55,
        hits: <String>['焦虑'],
      ));
      await c.flush();

      final File file = File('${tmp.path}/presence/emotion_state.json');
      expect(await file.exists(), isTrue);

      final EmotionContinuity restored = await EmotionContinuity.load(harness);
      expect(restored.current.label, EmotionLabel.anxious);
      expect(restored.current.valence, closeTo(-0.6 * 0.35, 1e-9));
      expect(restored.history, hasLength(1));
      expect(restored.history.single.hits, contains('焦虑'));
    });

    test('文件损坏时回退中性，不抛异常', () async {
      final File file = File('${tmp.path}/presence/emotion_state.json');
      await file.parent.create(recursive: true);
      await file.writeAsString('{not valid json');

      final EmotionContinuity restored = await EmotionContinuity.load(harness);
      expect(restored.current.label, EmotionLabel.neutral);
      expect(restored.current.confidence, 0);
      expect(restored.history, isEmpty);
    });
  });

  group('summaryBlock 约束', () {
    test('包含当前情绪、能量约束、避免过度共情与诊断免责', () {
      final EmotionContinuity c = EmotionContinuity(store: harness);
      c.update(const EmotionReading(
        label: EmotionLabel.tired,
        valence: -0.7,
        arousal: 0.2,
        confidence: 0.6,
      ));
      final String block = c.summaryBlock();
      expect(block, contains('疲惫'));
      expect(block, contains('能量'));
      expect(block, contains('能量偏低'));
      expect(block, contains('避免过度共情'));
      expect(block, contains('不是心理诊断'));
    });

    test('高能量时给出可展开的约束', () {
      final EmotionContinuity c = EmotionContinuity(
        initial: const EmotionReading(
          label: EmotionLabel.joy,
          valence: 0.8,
          arousal: 0.8,
          confidence: 0.7,
        ),
      );
      expect(c.summaryBlock(), contains('可适度展开'));
    });
  });

  group('PresenceStore 接入', () {
    test('recordUserMessage 更新情绪并真实落盘', () async {
      final PresenceStore presence = await PresenceStore.load(harness);
      presence.recordUserMessage('烦死了，又报错');
      await presence.flush();

      expect(presence.emotion.current.label, EmotionLabel.angry);
      expect(presence.emotion.history, isNotEmpty);
      expect(presence.emotion.summaryBlock(), contains('不是心理诊断'));

      final EmotionContinuity restored = await EmotionContinuity.load(harness);
      expect(restored.current.label, EmotionLabel.angry);
    });

    test('中性消息不改变已有连续情绪', () async {
      final PresenceStore presence = await PresenceStore.load(harness);
      presence.recordUserMessage('今天太开心了');
      final double driven = presence.emotion.current.valence;
      presence.recordUserMessage('嗯');
      expect(presence.emotion.current.valence, driven);
    });
  });
}
