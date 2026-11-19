/// 端侧 GGUF 真推理服务（llama.cpp / llamadart）。
///
/// 把用户在「模型」页下载完成的 .gguf 权重真实加载进 llama.cpp 引擎，
/// 生成回复；不伪造任何 token。所有错误如实上抛，由调用方决定降级。
///
/// 参考：`flutter_agent_harness` 的 provider 契约（load → infer → dispose），
/// 实现：`llamadart 0.19.0`（Dart FFI + llama.cpp native assets）。
///
/// 推理加速（DeepInfer 思路，见 `deep_infer.dart`）：
///  * system 段逐字稳定 → 引擎的 prompt cache 有命中机会，减少重复预填充；
///  * 生成长度按 `context - prompt - 64` 预算，避免超出上下文被硬截断；
///  * 线程数按 CPU 核数设定（留一核给 UI），不再固定 4 线程。
/// 这里不做「假装已接受 N 个起草 token」的统计：Dart 端拿不到逐 token
/// 核对结果，投机解码的真实参数在 Python 后端（llama_cpp 起草模型）里生效。

import 'dart:io';

import 'package:llamadart/llamadart.dart';

import 'deep_infer.dart';
import 'gguf_probe.dart';
import 'prompt_kit.dart';

/// 一次 GGUF 加载档位：从快到稳逐级降级，兼顾速度与移动端内存。
class _LoadProfile {
  const _LoadProfile({
    required this.gpuLayers,
    required this.batchSize,
    required this.contextSize,
    required this.threads,
    required this.timeout,
  });
  final int gpuLayers;
  final int batchSize;
  final int contextSize;
  final int threads;
  final int timeout;
}

/// 一次端侧推理的结果。
class LocalInferenceResult {
  const LocalInferenceResult({
    required this.ok,
    this.text = '',
    this.error = '',
    this.modelPath = '',
    this.metrics = const <String, dynamic>{},
  });
  final bool ok;
  final String text;
  final String error;
  final String modelPath;

  /// 本次推理的真实耗时/Token 记账（来自 [DeepInferPlanner.record]）。
  final Map<String, dynamic> metrics;
}

/// 单例端侧推理引擎：复用已加载的模型，避免每次消息都重新加载权重。
class LocalInference {
  LocalInference._();

  static final LocalInference instance = LocalInference._();

  /// 端侧推理规划器（稳定前缀 / 预算 / 线程 / 起草长度）。
  final DeepInferPlanner planner = DeepInferPlanner(contextSize: 2048);

  LlamaEngine? _engine;
  String? _loadedPath;
  bool _loading = false;
  String? _lastError;

  bool get isLoaded => _engine != null && _loadedPath != null;
  String? get loadedPath => _loadedPath;
  String? get lastError => _lastError;

  /// 累计推理指标（真实生成次数、token 数、平均延迟、前缀命中率）。
  Map<String, dynamic> get metrics => planner.metrics();

  /// 加载（或复用）真实 GGUF 权重。文件不存在 / 加载失败如实返回原因。
  ///
  /// 稳定性策略（针对移动端真实加载失败的根因）：
  ///  1. 加载前先做 GGUF 魔数校验：下载中断/HTML 错误页会在文件头留下非 GGUF
  ///     内容，此时直接给出「文件损坏」结论，不让 llama.cpp 吐一堆 diagnostics。
  ///  2. 分级降级加载：GPU(大 batch) → CPU(中 batch) → CPU(小 batch + 小上下文)。
  ///     5GB 级模型在低内存手机上用 batchSize=512 会因计算缓冲不足而 OOM；
  ///     逐级收紧内存占用，尽可能把大模型真正加载起来。
  ///  3. 失败信息去重、去噪：过滤底层 diagnostics，输出可读的一句话原因。
  Future<String?> load(String modelPath) async {
    if (_loadedPath == modelPath && _engine != null) return null;
    if (_loading) return '模型正在加载中，请稍候';
    final f = File(modelPath);
    if (!f.existsSync()) {
      return '权重文件不存在：$modelPath';
    }
    final size = await f.length();
    if (size < 1024 * 1024) {
      return '权重文件不完整（${size}B），请重新下载';
    }
    // 1) GGUF 魔数校验：'GGUF' = 0x47 0x47 0x55 0x46。
    final String? magicError = await _checkGgufMagic(f);
    if (magicError != null) return magicError;

    _loading = true;
    _lastError = null;
    try {
      await dispose();
      final int threads = planner.threads;
      final int ctx = planner.contextSize;
      final source = LlamaModel(ModelSource.path(modelPath));
      // 2) 三级加载档位：从快到稳。
      final List<_LoadProfile> profiles = <_LoadProfile>[
        _LoadProfile(gpuLayers: 99, batchSize: 256, contextSize: ctx,
            threads: threads, timeout: 180),
        _LoadProfile(gpuLayers: 0, batchSize: 128, contextSize: ctx,
            threads: threads, timeout: 180),
        _LoadProfile(gpuLayers: 0, batchSize: 64,
            contextSize: ctx < 1024 ? ctx : 1024,
            threads: threads < 2 ? threads : 2, timeout: 180),
      ];
      Object? lastFailure;
      for (final _LoadProfile p in profiles) {
        try {
          final LlamaEngine engine = await LlamaEngine.load(
            source,
            params: ModelParams(
              contextSize: p.contextSize,
              numberOfThreads: p.threads,
              numberOfThreadsBatch: p.threads,
              batchSize: p.batchSize,
              gpuLayers: p.gpuLayers,
            ),
          ).timeout(Duration(seconds: p.timeout));
          _engine = engine;
          _loadedPath = modelPath;
          return null;
        } on Object catch (e) {
          lastFailure = e;
        }
      }
      // 3) 所有档位都失败：输出精简、可读、无重复的原因。
      _lastError = lastFailure?.toString() ?? '未知错误';
      return _friendlyLoadError(lastFailure, size);
    } on Object catch (e) {
      _lastError = e.toString();
      _engine = null;
      _loadedPath = null;
      return _friendlyLoadError(e, size);
    } finally {
      _loading = false;
    }
  }

  /// 读取文件头 4 字节校验 GGUF 魔数。返回 null 表示合法；否则返回可读错误。
  Future<String?> _checkGgufMagic(File f) => checkGgufMagicFile(f);

  /// 把 llamadart 的底层异常转成一句话可读原因：去掉 diagnostics 噪声、
  /// 提取根因关键字，避免把整段 `{moduleDir=null,...}` 抛给用户。
  String _friendlyLoadError(Object? e, int size) {
    _engine = null;
    _loadedPath = null;
    final raw = e?.toString() ?? '未知错误';
    final mb = (size / (1024 * 1024)).toStringAsFixed(0);
    final lower = raw.toLowerCase();
    // 从 diagnostics / 异常文本里提取真正的根因信号。
    String cause;
    if (lower.contains('out of memory') ||
        lower.contains('bad_alloc') ||
        lower.contains('memory') && lower.contains('alloc')) {
      cause = '内存不足，模型过大或 batch 过高';
    } else if (lower.contains('invalid magic') ||
        lower.contains('unknown model') ||
        lower.contains('unsupported') ||
        lower.contains('invalid model')) {
      cause = '模型格式不受当前引擎支持';
    } else if (lower.contains('failed to open') ||
        lower.contains('no such file') ||
        lower.contains('cannot open')) {
      cause = '无法读取权重文件';
    } else if (lower.contains('diagnostics') &&
        lower.contains('registeredbackends=[cpu]')) {
      // GPU 后端未就绪 + 大 batch，本机实测常见于 5GB 模型加载失败。
      cause = 'GPU 后端不可用且模型较大，CPU 加载内存不足';
    } else {
      cause = '底层加载失败';
    }
    // 去掉 diagnostics 大括号内容，只留 llama.cpp 真正的一行错误，避免噪声。
    final diagStart = raw.indexOf('(diagnostics=');
    final brief = (diagStart > 0 ? raw.substring(0, diagStart) : raw).trim();
    final gb = (size / (1024 * 1024 * 1024)).toStringAsFixed(2);
    return '加载 GGUF 失败（${gb}GB / ${mb}MB）：$cause。$brief'
        '。已自动尝试降低 batch 与上下文仍失败，请换用更小的量化档位，'
        '或在训练设置里配置 OpenAI 兼容 API';
  }

  /// 真实推理：把 text 作为用户消息送进模型，返回生成的完整回复。
  Future<LocalInferenceResult> infer(
    String text, {
    String system = PromptKit.defaultSystem,
    int maxTokens = 512,
  }) async {
    final engine = _engine;
    if (engine == null) {
      return const LocalInferenceResult(ok: false, error: '端侧模型尚未加载');
    }
    final GenerationPlan plan =
        planner.plan(system: system, user: text, maxTokens: maxTokens);
    final Stopwatch sw = Stopwatch()..start();
    try {
      final messages = <LlamaChatMessage>[
        LlamaChatMessage.fromText(
            role: LlamaChatRole.system, text: plan.stableSystem),
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: text),
      ];
      final completion = await engine.complete(
        messages,
        params: GenerationParams(maxTokens: plan.maxTokens),
      );
      sw.stop();
      final reply = completion.text.trim();
      if (reply.isEmpty) {
        planner.record(
          promptTokens: plan.promptTokens,
          completionTokens: 0,
          latency: sw.elapsed,
        );
        return LocalInferenceResult(
          ok: false,
          error: '模型未生成任何内容（权重可能不兼容或上下文不足）',
          modelPath: _loadedPath ?? '',
          metrics: planner.metrics(),
        );
      }
      planner.record(
        promptTokens: plan.promptTokens,
        completionTokens: DeepInferPlanner.estimateTokens(reply),
        latency: sw.elapsed,
      );
      return LocalInferenceResult(
        ok: true,
        text: reply,
        modelPath: _loadedPath ?? '',
        metrics: <String, dynamic>{
          'plan': plan.toJson(),
          'elapsed_ms': sw.elapsedMilliseconds,
        },
      );
    } on Object catch (e) {
      sw.stop();
      _lastError = e.toString();
      return LocalInferenceResult(
        ok: false,
        error: '端侧推理失败：$e',
        modelPath: _loadedPath ?? '',
      );
    }
  }

  /// 加载并推理一步到位（供 _chat / IM 网桥直接调用）。
  Future<LocalInferenceResult> generate(
    String modelPath,
    String text, {
    String system = PromptKit.defaultSystem,
  }) async {
    final err = await load(modelPath);
    if (err != null) {
      return LocalInferenceResult(ok: false, error: err, modelPath: modelPath);
    }
    return infer(text, system: system);
  }

  Future<void> dispose() async {
    final e = _engine;
    _engine = null;
    _loadedPath = null;
    if (e != null) {
      try {
        await e.dispose();
      } on Object {
        // 释放失败无需上报。
      }
    }
  }
}