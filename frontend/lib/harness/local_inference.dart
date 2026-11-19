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
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

import 'deep_infer.dart';
import 'gguf_probe.dart';
import 'prompt_kit.dart';
import 'store.dart';

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

/// run_config.json 中与加载相关的配置子集（null = 未配置）。
class _RunConfig {
  const _RunConfig({
    this.contextSize,
    this.threads,
    this.gpuLayers,
    this.flashAttention,
    this.kvCacheType,
  });

  final int? contextSize;
  final int? threads;
  final int? gpuLayers;
  final FlashAttention? flashAttention;
  final KvCacheType? kvCacheType;
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
  /// 加载时按 run_config.json 重建，保证生成长度预算与真实上下文一致。
  DeepInferPlanner planner = DeepInferPlanner(contextSize: 2048);

  LlamaEngine? _engine;
  String? _loadedPath;
  String? _projectorPath;
  bool _loading = false;
  String? _lastError;

  bool get isLoaded => _engine != null && _loadedPath != null;
  String? get loadedPath => _loadedPath;
  String? get lastError => _lastError;

  /// 当前模型是否已挂载 mmproj 多模态投影器（视觉/音频输入）。
  bool get hasProjector => _projectorPath != null;

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
      // 读取「运行」页保存的参数；缺失字段沿用既有默认值。
      final _RunConfig cfg = await _readRunConfig();
      final int threads = math.min(
        math.max(2, cfg.threads ?? planner.threads),
        math.max(2, Platform.numberOfProcessors),
      );
      final int ctx = math.max(512, cfg.contextSize ?? planner.contextSize);
      if (threads != planner.threads || ctx != planner.contextSize) {
        planner = DeepInferPlanner(contextSize: ctx, threads: threads);
      }
      final int gpuLayers = (cfg.gpuLayers ?? 99)
          .clamp(0, ModelParams.maxGpuLayers)
          .toInt();
      final KvCacheType kv = cfg.kvCacheType ?? KvCacheType.f16;
      FlashAttention flash = cfg.flashAttention ?? FlashAttention.auto;
      if (kv != KvCacheType.f16 && flash != FlashAttention.enabled) {
        // llama.cpp 拒绝非 F16 KV 搭配关闭的 Flash Attention。
        flash = FlashAttention.enabled;
      }
      final source = LlamaModel(ModelSource.path(modelPath));
      // 2) 三级加载档位：从快到稳。
      final List<_LoadProfile> profiles = <_LoadProfile>[
        _LoadProfile(
          gpuLayers: gpuLayers,
          batchSize: 256,
          contextSize: ctx,
          threads: threads,
          timeout: 180,
        ),
        _LoadProfile(
          gpuLayers: 0,
          batchSize: 128,
          contextSize: ctx,
          threads: threads,
          timeout: 180,
        ),
        _LoadProfile(
          gpuLayers: 0,
          batchSize: 64,
          contextSize: ctx < 1024 ? ctx : 1024,
          threads: threads < 2 ? threads : 2,
          timeout: 180,
        ),
        // 6GB 级权重在 12–16GB 手机上最后再试一次极小计算缓冲，
        // 避免 CPU 后端因 batch/上下文缓冲直接 OOM。
        _LoadProfile(
          gpuLayers: 0,
          batchSize: 32,
          contextSize: ctx < 512 ? ctx : 512,
          threads: threads < 2 ? threads : 2,
          timeout: 180,
        ),
        // 最后兜底：极小上下文 + 单线程，把计算缓冲压到最低，
        // 让尽可能大的权重也能在手机上真正加载并推理。
        _LoadProfile(
          gpuLayers: 0,
          batchSize: 8,
          contextSize: ctx < 128 ? ctx : 128,
          threads: 1,
          timeout: 180,
        ),
      ];
      Object? lastFailure;
      Future<bool> tryProfile(
        _LoadProfile p,
        FlashAttention fa,
        KvCacheType cache,
      ) async {
        try {
          final LlamaEngine engine = await LlamaEngine.load(
            source,
            params: ModelParams(
              contextSize: p.contextSize,
              numberOfThreads: p.threads,
              numberOfThreadsBatch: p.threads,
              batchSize: p.batchSize,
              gpuLayers: p.gpuLayers,
              flashAttention: fa,
              cacheTypeK: cache,
              cacheTypeV: cache,
              useMmap: true,
              // 第一档显式要 Vulkan；模块缺失时 llamadart 会回落 CPU，
              // 后面的纯 CPU 档位继续兜底。
              preferredBackend: p.gpuLayers > 0
                  ? GpuBackend.vulkan
                  : GpuBackend.auto,
            ),
          ).timeout(Duration(seconds: p.timeout));
          _engine = engine;
          _loadedPath = modelPath;
          await _attachProjector(engine, modelPath);
          return true;
        } on Object catch (e) {
          lastFailure = e;
          return false;
        }
      }

      for (final _LoadProfile p in profiles) {
        if (await tryProfile(p, flash, kv)) return null;
      }
      // 某些 CPU/旧驱动不支持 Flash Attention 或量化 KV；最后一轮退回
      // F16 KV + 关闭 Flash Attention，避免参数组合把可加载的权重挡在门外。
      if (flash != FlashAttention.disabled || kv != KvCacheType.f16) {
        for (final _LoadProfile p in profiles.where(
          (_LoadProfile p) => p.gpuLayers == 0,
        )) {
          if (await tryProfile(p, FlashAttention.disabled, KvCacheType.f16)) {
            return null;
          }
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

  /// 读取「运行」页写入的 run_config.json（缺失/损坏时返回空配置）。
  Future<_RunConfig> _readRunConfig() async {
    try {
      final HarnessStore store = await HarnessStore.instance();
      final Map<String, dynamic> cfg = await store.readJson('run_config.json');
      final dynamic ctx = cfg['context_size'];
      final dynamic threads = cfg['threads'];
      final dynamic gpu = cfg['gpu_layers'];
      final dynamic flash = cfg['flash_attn'];
      final String kvRaw = (cfg['kv_cache'] ?? '').toString();
      final KvCacheType? kv = switch (kvRaw) {
        'q8_0' => KvCacheType.q8_0,
        'q4_0' => KvCacheType.q4_0,
        'f16' => KvCacheType.f16,
        _ => null,
      };
      return _RunConfig(
        contextSize: ctx is num ? ctx.toInt() : null,
        threads: threads is num ? threads.toInt() : null,
        gpuLayers: gpu is num ? gpu.toInt() : null,
        flashAttention: flash is bool
            ? (flash ? FlashAttention.enabled : FlashAttention.disabled)
            : null,
        kvCacheType: kv,
      );
    } on Object {
      return const _RunConfig();
    }
  }

  /// 同一目录下的 mmproj*.gguf 自动挂载为多模态投影器。
  /// 没有投影器时保持纯文本，不影响正常对话。
  Future<void> _attachProjector(LlamaEngine engine, String modelPath) async {
    _projectorPath = null;
    try {
      final Directory dir = File(modelPath).parent;
      final List<File> candidates = dir.listSync().whereType<File>().where((
        File f,
      ) {
        final String n = f.path.toLowerCase();
        return n.endsWith('.gguf') && n.contains('mmproj');
      }).toList()..sort((File a, File b) => a.path.compareTo(b.path));
      if (candidates.isEmpty) return;
      await engine
          .loadMultimodalProjector(candidates.first.path)
          .timeout(const Duration(seconds: 180));
      _projectorPath = candidates.first.path;
    } on Object {
      // 投影器不兼容时退回文本推理，由调用方按 hasProjector 判断能否收图。
      _projectorPath = null;
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
        lower.contains('invalid model') ||
        lower.contains('unknown architecture')) {
      cause = '该权重的架构无法被当前文本引擎解析';
    } else if (lower.contains('failed to open') ||
        lower.contains('no such file') ||
        lower.contains('cannot open')) {
      cause = '无法读取权重文件';
    } else if (lower.contains('registeredbackends=[cpu]')) {
      // 只是说明 GPU 后端没启用，并不等于内存不足；真正原因通常是
      // 权重架构不受支持或计算缓冲分配失败。
      cause = 'GPU 后端未启用，已回落 CPU 仍加载失败';
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
    List<String> imagePaths = const <String>[],
  }) async {
    final engine = _engine;
    if (engine == null) {
      return const LocalInferenceResult(ok: false, error: '端侧模型尚未加载');
    }
    if (imagePaths.isNotEmpty && !hasProjector) {
      return const LocalInferenceResult(
        ok: false,
        error:
            '当前模型没有 mmproj 多模态投影器，无法读取图片。'
            '请把同仓库的 mmproj*.gguf 一起下载到模型目录后重新运行。',
      );
    }
    final GenerationPlan plan = planner.plan(
      system: system,
      user: text,
      maxTokens: maxTokens,
    );
    final Stopwatch sw = Stopwatch()..start();
    try {
      final messages = <LlamaChatMessage>[
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: plan.stableSystem,
        ),
        if (imagePaths.isEmpty)
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: text)
        else
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: <LlamaContentPart>[
              LlamaTextContent(text),
              for (final String path in imagePaths)
                LlamaImageContent(path: path),
            ],
          ),
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
    List<String> imagePaths = const <String>[],
  }) async {
    final err = await load(modelPath);
    if (err != null) {
      return LocalInferenceResult(ok: false, error: err, modelPath: modelPath);
    }
    return infer(text, system: system, imagePaths: imagePaths);
  }

  Future<void> dispose() async {
    final e = _engine;
    _engine = null;
    _loadedPath = null;
    _projectorPath = null;
    if (e != null) {
      try {
        await e.dispose();
      } on Object {
        // 释放失败无需上报。
      }
    }
  }
}
