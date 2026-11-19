/// 内置推理加速与稳定性调度（DeepInfer 思路的端侧落地）。
///
/// 参考 DeepSeek 系推理工程里被验证过的三件事，只保留能在端侧真实生效、
/// 且不假装「用了某个加速就算加速」的部分：
///
///  1. **稳定前缀**：system 段逐字稳定、只在末尾追加用户内容。llama.cpp /
///     llama-cpp-python 的 prompt cache 以「相同前缀」为命中条件，前缀一旦
///     抖动（时间戳、随机 id、人设顺序变化）就等于每次全量重算。
///  2. **预算化的生成长度**：把 `context - prompt` 作为 maxTokens 上限，
///     避免超出上下文后静默截断、输出半句话。
///  3. **投机解码参数**：按历史接受率决定起草长度（0/2/4/6），
///     起草模型由真正支持它的后端（Python 侧 llama_cpp 的
///     LlamaPromptLookupDecoding）执行；本类只负责给出可信的调度参数与
///     统计，不对未接入的后端虚报「已加速」。
///
/// 所有统计都来自真实调用：`record()` 只在一次生成结束后被调用。
library;

import 'dart:io' show Platform;
import 'dart:math' as math;

/// 单次生成计划：全部字段都能直接喂给推理后端。
class GenerationPlan {
  const GenerationPlan({
    required this.stableSystem,
    required this.maxTokens,
    required this.promptTokens,
    required this.prefillChunks,
    required this.draftTokens,
    required this.threads,
    required this.prefixReused,
  });

  /// 逐字稳定的 system 段（与上次完全一致时 prefixReused=true）。
  final String stableSystem;

  /// 受上下文预算约束后的生成长度。
  final int maxTokens;

  /// 估算的 prompt token 数（CJK 按字、拉丁按词折算）。
  final int promptTokens;

  /// 分块预填充的每块 token 数（首块小、后续 2 倍递增，降低首字延迟）。
  final List<int> prefillChunks;

  /// 建议投机起草长度（0 = 不做投机，直接用主模型）。
  final int draftTokens;

  /// 建议线程数（不超过 CPU 核数，避免线程争抢）。
  final int threads;

  /// 本次 system 前缀是否与上一次完全一致（命中引擎 KV 缓存的前提）。
  final bool prefixReused;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'max_tokens': maxTokens,
        'prompt_tokens': promptTokens,
        'prefill_chunks': prefillChunks,
        'draft_tokens': draftTokens,
        'threads': threads,
        'prefix_reused': prefixReused,
      };
}

/// 前缀稳定性追踪：只记「最近一次 system 文本」，用来判断能否命中缓存。
class PrefixTracker {
  String _last = '';
  int _hits = 0;
  int _misses = 0;

  /// 返回本次是否为稳定前缀（同时把当前 system 记为最新）。
  bool observe(String system) {
    final bool hit = system.isNotEmpty && system == _last;
    if (hit) {
      _hits++;
    } else {
      _misses++;
    }
    _last = system;
    return hit;
  }

  void reset() {
    _last = '';
  }

  Map<String, dynamic> get stats => <String, dynamic>{
        'hits': _hits,
        'misses': _misses,
        'hit_rate': (_hits + _misses) == 0
            ? 0.0
            : _hits / (_hits + _misses),
      };
}

/// 投机解码接受率追踪：决定下一轮起草多少个 token。
class SpeculativeTracker {
  double _ema = 0;
  int _drafted = 0;
  int _accepted = 0;
  int _rounds = 0;

  /// 记录了真实核对结果才更新 EMA（drafted<=0 视为未启用，不计入）。
  void observe({required int drafted, required int accepted}) {
    if (drafted <= 0) return;
    _rounds++;
    _drafted += drafted;
    _accepted += accepted.clamp(0, drafted);
    final double ratio = accepted.clamp(0, drafted) / drafted;
    _ema = _rounds == 1 ? ratio : (_ema * 0.7 + ratio * 0.3);
  }

  /// 起草长度：接受率高就多起草，接受率低就退回主模型（0）。
  int draftLength({int cap = 6}) {
    if (_rounds < 2) return math.min(2, cap);
    if (_ema >= 0.75) return math.min(cap, 6);
    if (_ema >= 0.5) return math.min(cap, 4);
    if (_ema >= 0.3) return math.min(cap, 2);
    return 0;
  }

  Map<String, dynamic> get stats => <String, dynamic>{
        'rounds': _rounds,
        'drafted': _drafted,
        'accepted': _accepted,
        'acceptance_ema': _ema,
      };
}

/// 规划器：把上述策略组合成一份可直接执行、可测试的生成计划。
class DeepInferPlanner {
  DeepInferPlanner({
    this.contextSize = 2048,
    int? threads,
    this.maxDraftTokens = 6,
  }) : threads = threads ?? defaultThreads();

  final int contextSize;
  final int threads;
  final int maxDraftTokens;

  final PrefixTracker prefixes = PrefixTracker();
  final SpeculativeTracker speculation = SpeculativeTracker();

  int _generations = 0;
  int _totalPromptTokens = 0;
  int _totalCompletionTokens = 0;
  int _totalLatencyMs = 0;

  /// 端侧线程数：尽量吃满大核，但留一个核给 UI/网络，上限 8。
  static int defaultThreads() {
    final int cores = _cores();
    return math.max(2, math.min(8, cores <= 2 ? cores : cores - 1));
  }

  static int _cores() {
    try {
      final int n = Platform.numberOfProcessors;
      if (n > 0) return n;
    } on Object {
      // 读不到就按 4 核保守估计。
    }
    return 4;
  }

  /// 估算 token 数：CJK 每字 1 个，拉丁单词约 1.3 个，其余符号 1 个。
  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    int cjk = 0;
    int latinWords = 0;
    int symbols = 0;
    bool inWord = false;
    for (final int r in text.runes) {
      final bool isCjk = (r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3040 && r <= 0x30FF) ||
          (r >= 0x3400 && r <= 0x4DBF);
      final bool isLatin = (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
      if (isCjk) {
        cjk++;
        inWord = false;
      } else if (isLatin) {
        if (!inWord) latinWords++;
        inWord = true;
      } else {
        if (r != 0x20 && r != 0x0A && r != 0x09) symbols++;
        inWord = false;
      }
    }
    final int base = cjk + (latinWords * 1.3).ceil() + symbols;
    // 中英混排多一次脚本切换切分，预算按此保守计（与 Python 端同口径）。
    return (cjk > 0 && latinWords > 0) ? base + 1 : base;
  }

  /// 分块预填充：首块 128，之后翻倍，直到覆盖 prompt（上限 1024/块）。
  /// 首块小 → 首字延迟低；后续块大 → 吞吐高。
  static List<int> prefillChunks(int promptTokens) {
    if (promptTokens <= 0) return const <int>[];
    final List<int> out = <int>[];
    int left = promptTokens;
    int size = 128;
    while (left > 0) {
      final int take = left < size ? left : size;
      out.add(take);
      left -= take;
      size = math.min(1024, size * 2);
    }
    return out;
  }

  /// 生成计划。`maxTokens` 会被 `context - prompt - 64` 约束，预留 64 token
  /// 给对话模板/结束符，避免生成阶段被硬截断。
  GenerationPlan plan({
    required String system,
    required String user,
    int maxTokens = 512,
  }) {
    final int promptTokens = estimateTokens(system) + estimateTokens(user) + 16;
    final int budget = math.max(16, contextSize - promptTokens - 64);
    final int limit = math.min(maxTokens, budget);
    final bool reused = prefixes.observe(system);
    return GenerationPlan(
      stableSystem: system,
      maxTokens: limit,
      promptTokens: promptTokens,
      prefillChunks: prefillChunks(promptTokens),
      draftTokens: speculation.draftLength(cap: maxDraftTokens),
      threads: threads,
      prefixReused: reused,
    );
  }

  /// 一次生成结束后的真实记账。
  void record({
    required int promptTokens,
    required int completionTokens,
    required Duration latency,
    int drafted = 0,
    int accepted = 0,
  }) {
    _generations++;
    _totalPromptTokens += promptTokens;
    _totalCompletionTokens += completionTokens;
    _totalLatencyMs += latency.inMilliseconds;
    speculation.observe(drafted: drafted, accepted: accepted);
  }

  Map<String, dynamic> metrics() => <String, dynamic>{
        'generations': _generations,
        'prompt_tokens': _totalPromptTokens,
        'completion_tokens': _totalCompletionTokens,
        'avg_latency_ms': _generations == 0
            ? 0
            : (_totalLatencyMs / _generations).round(),
        'tokens_per_second': _totalLatencyMs == 0
            ? 0.0
            : _totalCompletionTokens * 1000 / _totalLatencyMs,
        'prefix': prefixes.stats,
        'speculation': speculation.stats,
        'threads': threads,
        'context_size': contextSize,
      };
}