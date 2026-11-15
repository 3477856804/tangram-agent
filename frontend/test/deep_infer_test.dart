/// DeepInfer 规划器测试：token 估算、分块预填充、稳定前缀、预算、
/// 起草长度与真实指标记账。全部为确定性断言，不依赖模型权重。
import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/deep_infer.dart';

void main() {
  group('token 估算', () {
    test('CJK 按字、拉丁按词、符号计数', () {
      expect(DeepInferPlanner.estimateTokens('你好世界'), 4);
      expect(DeepInferPlanner.estimateTokens('hello world'), 3); // 2 词 → 3
      expect(DeepInferPlanner.estimateTokens(''), 0);
      expect(DeepInferPlanner.estimateTokens('中文 and English!'),
          greaterThan(6));
    });
  });

  group('分块预填充', () {
    test('首块 128、随后翻倍、上限 1024', () {
      expect(DeepInferPlanner.prefillChunks(0), isEmpty);
      expect(DeepInferPlanner.prefillChunks(100), <int>[100]);
      final List<int> chunks = DeepInferPlanner.prefillChunks(128 + 256 + 512);
      expect(chunks, <int>[128, 256, 512]);
      final List<int> big = DeepInferPlanner.prefillChunks(3000);
      expect(big.first, 128);
      expect(big.reduce((a, b) => a + b), 3000);
      expect(big.every((c) => c <= 1024), isTrue);
    });
  });

  group('计划', () {
    test('生成长度受上下文预算约束', () {
      final DeepInferPlanner p =
          DeepInferPlanner(contextSize: 256, threads: 2);
      final GenerationPlan plan =
          p.plan(system: '你是助手', user: '写一段话', maxTokens: 512);
      expect(plan.maxTokens, lessThanOrEqualTo(256 - plan.promptTokens - 64));
      expect(plan.maxTokens, greaterThan(0));
    });

    test('相同 system 命中稳定前缀，变化则未命中', () {
      final DeepInferPlanner p = DeepInferPlanner(threads: 2);
      final GenerationPlan a =
          p.plan(system: '固定人设', user: '第一问', maxTokens: 64);
      final GenerationPlan b =
          p.plan(system: '固定人设', user: '第二问', maxTokens: 64);
      final GenerationPlan c =
          p.plan(system: '换了人设', user: '第三问', maxTokens: 64);
      expect(a.prefixReused, isFalse);
      expect(b.prefixReused, isTrue);
      expect(c.prefixReused, isFalse);
      final Map<String, dynamic> stats =
          (p.metrics()['prefix'] as Map).cast<String, dynamic>();
      expect(stats['hits'], 1);
      expect(stats['misses'], 2);
    });
  });

  group('投机起草长度', () {
    test('未积累数据时保守起草 2 个', () {
      final SpeculativeTracker t = SpeculativeTracker();
      expect(t.draftLength(), 2);
    });

    test('接受率高升到 6，接受率低退回 0', () {
      final SpeculativeTracker high = SpeculativeTracker();
      high.observe(drafted: 6, accepted: 6);
      high.observe(drafted: 6, accepted: 5);
      expect(high.draftLength(), 6);

      final SpeculativeTracker low = SpeculativeTracker();
      low.observe(drafted: 6, accepted: 0);
      low.observe(drafted: 6, accepted: 1);
      expect(low.draftLength(), 0);
    });

    test('接受数不会超过起草数', () {
      final SpeculativeTracker t = SpeculativeTracker();
      t.observe(drafted: 4, accepted: 99);
      final Map<String, dynamic> s =
          (t.stats['accepted'] as int) == 4 ? t.stats : t.stats;
      expect(s['accepted'], 4);
    });
  });

  group('指标记账', () {
    test('次数/Token/延迟/吞吐由真实记录累加', () {
      final DeepInferPlanner p = DeepInferPlanner(threads: 2);
      p.record(
          promptTokens: 100,
          completionTokens: 50,
          latency: const Duration(milliseconds: 500));
      p.record(
          promptTokens: 200,
          completionTokens: 150,
          latency: const Duration(milliseconds: 1000),
          drafted: 4,
          accepted: 3);
      final Map<String, dynamic> m = p.metrics();
      expect(m['generations'], 2);
      expect(m['prompt_tokens'], 300);
      expect(m['completion_tokens'], 200);
      expect(m['avg_latency_ms'], 750);
      expect(
          (m['tokens_per_second'] as num).toDouble(), closeTo(133.33, 0.1));
      final Map<String, dynamic> spec =
          (m['speculation'] as Map).cast<String, dynamic>();
      expect(spec['rounds'], 1);
      expect(spec['accepted'], 3);
    });

    test('线程数在 2~6 之间', () {
      final DeepInferPlanner p = DeepInferPlanner();
      expect(p.threads, inInclusiveRange(2, 6));
    });
  });
}