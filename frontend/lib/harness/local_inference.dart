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
import 'prompt_kit.dart';

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
    _loading = true;
    _lastError = null;
    try {
      await dispose();
      final engine = await LlamaEngine.load(
        LlamaModel(ModelSource.path(modelPath)),
        params: ModelParams(
          contextSize: planner.contextSize,
          numberOfThreads: planner.threads,
          gpuLayers: 0,
        ),
      );
      _engine = engine;
      _loadedPath = modelPath;
      return null;
    } on Object catch (e) {
      _lastError = e.toString();
      _engine = null;
      _loadedPath = null;
      return '加载 GGUF 失败：$e';
    } finally {
      _loading = false;
    }
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