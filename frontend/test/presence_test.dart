/// 场景感知 / 情绪连贯 / 打断恢复 / 合理遗忘的真实行为测试。
///
/// 只验证 PresenceStore 的落盘与纯逻辑，不发起任何网络请求；
/// 所有数据真实写入 HarnessStore 的临时目录，再重新 load 校验恢复。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/services/presence_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore harness;
  late PresenceStore presence;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_presence_test_');
    HarnessStore.overrideForTest(tmp);
    harness = await HarnessStore.instance();
    presence = await PresenceStore.load(harness);
  });

  tearDown(() async {
    await presence.flush();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('模式 / 情绪持久化与恢复', () {
    test('字段真实落盘，重新 load 后一致', () async {
      presence.setMode(PresenceMode.focus);
      presence.setMood(Mood.cheerful);
      presence.setEnergy(0.42);
      presence.interruptTask('重构 presence 提示词');
      await presence.flush();

      final PresenceStore restored = await PresenceStore.load(harness);
      expect(restored.loaded, isTrue);
      expect(restored.mode, PresenceMode.focus);
      expect(restored.mood, Mood.cheerful);
      expect(restored.energy, closeTo(0.42, 0.001));
      expect(restored.interruptedTask, '重构 presence 提示词');
      expect(restored.pausedAt, isNotNull);
      expect(restored.updatedAt.isAfter(DateTime(2000)), isTrue);
    });

    test('能量被钳制在 0-1', () {
      presence.setEnergy(-3);
      expect(presence.energy, 0);
      presence.setEnergy(9);
      expect(presence.energy, 1);
    });
  });

  group('主动打扰策略', () {
    test('quiet 永不主动', () {
      presence.setMode(PresenceMode.quiet);
      expect(presence.shouldProactivelySpeak, isFalse);
      presence.interruptTask('整理周报');
      expect(presence.shouldProactivelySpeak, isFalse);
    });

    test('focus 仅高优先级，chat 允许', () {
      presence.setMode(PresenceMode.focus);
      expect(presence.shouldProactivelySpeak, isFalse);

      presence.setMood(Mood.frustrated);
      expect(presence.shouldProactivelySpeak, isTrue);

      presence.setMood(Mood.neutral);
      presence.interruptTask('修登录');
      expect(presence.shouldProactivelySpeak, isTrue);

      presence.resumeTask();
      presence.setMode(PresenceMode.chat);
      expect(presence.shouldProactivelySpeak, isTrue);
    });
  });

  group('打断与恢复', () {
    test('中断任务可生成提示并真实恢复', () async {
      presence.interruptTask('部署 0.0.12');
      expect(presence.resumeHint, contains('部署 0.0.12'));
      expect(presence.pausedAt, isNotNull);

      presence.resumeTask();
      expect(presence.interruptedTask, isNull);
      expect(presence.pausedAt, isNull);
      expect(presence.resumeHint, isNull);
      await presence.flush();

      final PresenceStore restored = await PresenceStore.load(harness);
      expect(restored.interruptedTask, isNull);
      expect(restored.resumeHint, isNull);
    });
  });

  group('recordUserMessage 语气判定', () {
    test('关键词启发式区分四种语气', () {
      presence.recordUserMessage('烦死了，又报错，真搞不定');
      expect(presence.lastUserTone, Mood.frustrated.name);
      expect(presence.mood, Mood.frustrated);

      presence.recordUserMessage('哈哈，终于好了，谢谢');
      expect(presence.lastUserTone, Mood.cheerful.name);
      expect(presence.mood, Mood.cheerful);

      presence.recordUserMessage('好累，想睡');
      expect(presence.lastUserTone, Mood.tired.name);
      expect(presence.mood, Mood.tired);

      presence.recordUserMessage('帮我修复登录代码并测试');
      expect(presence.lastUserTone, Mood.focused.name);
      expect(presence.mood, Mood.focused);
    });

    test('中性短消息不改变情绪，保持连贯', () {
      presence.setMood(Mood.cheerful);
      presence.recordUserMessage('嗯');
      expect(presence.lastUserTone, Mood.neutral.name);
      expect(presence.mood, Mood.cheerful);
    });

    test('最近交互上限 60，按最旧淘汰并落盘', () async {
      for (int i = 0; i < 70; i++) {
        presence.recordUserMessage('第 $i 条：帮我检查代码');
      }
      expect(presence.recentInteractions.length, 60);
      expect(presence.recentInteractions.first.text, contains('第 10 条'));
      expect(presence.recentInteractions.last.text, contains('第 69 条'));

      await presence.flush();
      final PresenceStore restored = await PresenceStore.load(harness);
      expect(restored.recentInteractions.length, 60);
      expect(restored.recentInteractions.first.text, contains('第 10 条'));
    });
  });

  group('合理遗忘', () {
    test('forgetOlderThan 真删除过期记录，固定内容保留', () async {
      final DateTime now = DateTime.now();
      presence.recentInteractions.addAll(<RecentInteraction>[
        RecentInteraction(
          text: '十天前的旧消息',
          tone: Mood.neutral.name,
          ts: now.subtract(const Duration(days: 10)),
        ),
        RecentInteraction(
          text: '要保留的旧消息',
          tone: Mood.neutral.name,
          ts: now.subtract(const Duration(days: 10)),
        ),
        RecentInteraction(
          text: '昨天的消息',
          tone: Mood.focused.name,
          ts: now.subtract(const Duration(days: 1)),
        ),
      ]);
      presence.pin('要保留的旧消息');
      presence.forgetOlderThan(7);

      expect(presence.forgetBefore, isNotNull);
      final List<String> texts = presence.recentInteractions
          .map((RecentInteraction r) => r.text)
          .toList();
      expect(texts, isNot(contains('十天前的旧消息')));
      expect(texts, contains('要保留的旧消息'));
      expect(texts, contains('昨天的消息'));

      await presence.flush();
      final PresenceStore restored = await PresenceStore.load(harness);
      final List<String> restoredTexts = restored.recentInteractions
          .map((RecentInteraction r) => r.text)
          .toList();
      expect(restoredTexts, isNot(contains('十天前的旧消息')));
      expect(restoredTexts, contains('要保留的旧消息'));
    });
  });

  group('summaryBlock 注入约束', () {
    test('包含模式、情绪、能量、中断任务与否与诊断免责', () {
      presence.setMode(PresenceMode.quiet);
      presence.setMood(Mood.tired);
      presence.setEnergy(0.2);
      presence.interruptTask('整理周报');

      final String block = presence.summaryBlock();
      expect(block, startsWith('【在场状态】'));
      expect(block, contains('当前模式：安静'));
      expect(block, contains('疲惫'));
      expect(block, contains('20%'));
      expect(block, contains('整理周报'));
      expect(block, contains('禁止主动打扰'));
      expect(block, contains('不是心理诊断'));
    });

    test('专注 / 闲聊分别给出少寒暄与承接情绪策略', () {
      presence.setMode(PresenceMode.focus);
      expect(presence.summaryBlock(), contains('少寒暄'));

      presence.setMode(PresenceMode.chat);
      expect(presence.summaryBlock(), contains('承接情绪'));
    });
  });
}
