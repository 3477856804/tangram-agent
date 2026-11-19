/// 跨平台本地扩散推理（stable-diffusion.cpp C API）。
///
/// 同一套 Dart FFI 代码在 Android / iOS / macOS / Linux / Windows 上加载
/// 各平台编译出的 `stable-diffusion` 动态库；调用的是官方 2026-11 的
/// opaque options / tensor / result C API，支持 MiniMax-H3-Image 等
/// 文本生图与参考图编辑模型。
///
/// 库不存在时如实返回「未编译」，绝不伪造生成结果。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 一次生图请求。MiniMax-H3-Image 需要三个组件：
/// diffusion transformer、专用 VAE、Qwen3-VL 文本编码器。
class DiffusionRequest {
  const DiffusionRequest({
    required this.diffusionModelPath,
    required this.vaePath,
    required this.textEncoderPath,
    required this.prompt,
    this.negativePrompt = '',
    this.width = 1024,
    this.height = 1024,
    this.steps = 6,
    this.seed = 42,
    this.cfgScale = 1.0,
    this.sampler = 'euler',
    this.visionTowerPath = '',
    this.threads,
  });

  final String diffusionModelPath;
  final String vaePath;
  final String textEncoderPath;
  final String prompt;
  final String negativePrompt;
  final int width;
  final int height;
  final int steps;
  final int seed;
  final double cfgScale;
  final String sampler;
  final String visionTowerPath;
  final int? threads;
}

class DiffusionResult {
  const DiffusionResult({required this.ok, this.path = '', this.error = ''});

  final bool ok;
  final String path;
  final String error;
}

typedef _CreateOpt = Pointer<Void> Function();
typedef _CreateOptDart = Pointer<Void> Function();
typedef _SetString =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetStringDart =
    int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _SetInt = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int64);
typedef _SetIntDart = int Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _SetBool = Int32 Function(Pointer<Void>, Pointer<Utf8>, Bool);
typedef _SetBoolDart = int Function(Pointer<Void>, Pointer<Utf8>, bool);
typedef _SetDouble = Int32 Function(Pointer<Void>, Pointer<Utf8>, Double);
typedef _SetDoubleDart = int Function(Pointer<Void>, Pointer<Utf8>, double);
typedef _CtxCreate = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _CtxCreateDart = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _Generate =
    Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GenerateDart =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _Free = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _LastError = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();
typedef _ResultCount = Size Function(Pointer<Void>);
typedef _ResultCountDart = int Function(Pointer<Void>);
typedef _ResultImage = Pointer<Void> Function(Pointer<Void>, Size);
typedef _ResultImageDart = Pointer<Void> Function(Pointer<Void>, int);
typedef _TensorData = Pointer<Uint8> Function(Pointer<Void>);
typedef _TensorDataDart = Pointer<Uint8> Function(Pointer<Void>);
typedef _TensorDim = Int64 Function(Pointer<Void>, Size);
typedef _TensorDimDart = int Function(Pointer<Void>, int);
typedef _TensorBytes = Size Function(Pointer<Void>);
typedef _TensorBytesDart = int Function(Pointer<Void>);

class DiffusionEngine {
  DiffusionEngine._(this._lib);

  final DynamicLibrary _lib;

  static DiffusionEngine? _instance;
  static Object? _loadError;

  /// 当前平台是否已打包扩散原生库。
  static bool get isAvailable => open() != null;

  static String? get loadError => _loadError?.toString();

  static DiffusionEngine? open() {
    if (_instance != null) return _instance;
    if (_loadError != null) return null;
    try {
      final DynamicLibrary lib;
      if (Platform.isIOS || Platform.isMacOS) {
        // iOS 静态链接进主二进制；macOS 优先进程符号。
        lib = DynamicLibrary.process();
      } else if (Platform.isAndroid) {
        lib = DynamicLibrary.open('libstable-diffusion.so');
      } else if (Platform.isWindows) {
        lib = DynamicLibrary.open('stable-diffusion.dll');
      } else {
        lib = DynamicLibrary.open('libstable-diffusion.so');
      }
      // 探测入口符号：库存在但没导出 C API（例如错误架构/旧版本）时
      // 直接判为不可用，避免延迟到点「生成」才炸。
      lib.lookup('sd_ctx_opt_create');
      return _instance = DiffusionEngine._(lib);
    } on Object catch (e) {
      _loadError = e;
      return null;
    }
  }

  late final _CreateOptDart _ctxOptCreate = _lib
      .lookupFunction<_CreateOpt, _CreateOptDart>('sd_ctx_opt_create');
  late final _CreateOptDart _imgOptCreate = _lib
      .lookupFunction<_CreateOpt, _CreateOptDart>('sd_img_gen_opt_create');
  late final _SetStringDart _setString = _lib
      .lookupFunction<_SetString, _SetStringDart>('sd_opt_set_string');
  late final _SetIntDart _setInt = _lib.lookupFunction<_SetInt, _SetIntDart>(
    'sd_opt_set_int',
  );
  late final _SetBoolDart _setBool = _lib
      .lookupFunction<_SetBool, _SetBoolDart>('sd_opt_set_bool');
  late final _SetDoubleDart _setDouble = _lib
      .lookupFunction<_SetDouble, _SetDoubleDart>('sd_opt_set_float');
  late final _CtxCreateDart _ctxCreate = _lib
      .lookupFunction<_CtxCreate, _CtxCreateDart>('sd_ctx_create');
  late final _GenerateDart _generate = _lib
      .lookupFunction<_Generate, _GenerateDart>('sd_generate_image');
  late final _FreeDart _ctxFree = _lib.lookupFunction<_Free, _FreeDart>(
    'sd_ctx_free',
  );
  late final _FreeDart _optFree = _lib.lookupFunction<_Free, _FreeDart>(
    'sd_opt_free',
  );
  late final _FreeDart _resultFree = _lib.lookupFunction<_Free, _FreeDart>(
    'sd_result_free',
  );
  late final _LastErrorDart _lastError = _lib
      .lookupFunction<_LastError, _LastErrorDart>('sd_get_last_error');
  late final _ResultCountDart _imageCount = _lib
      .lookupFunction<_ResultCount, _ResultCountDart>(
        'sd_result_get_image_count',
      );
  late final _ResultImageDart _imageAt = _lib
      .lookupFunction<_ResultImage, _ResultImageDart>('sd_result_get_image');
  late final _TensorDataDart _tensorData = _lib
      .lookupFunction<_TensorData, _TensorDataDart>('sd_tensor_data');
  late final _TensorDimDart _tensorDim = _lib
      .lookupFunction<_TensorDim, _TensorDimDart>('sd_tensor_dim');
  late final _TensorBytesDart _tensorBytes = _lib
      .lookupFunction<_TensorBytes, _TensorBytesDart>('sd_tensor_byte_size');

  String _error() {
    try {
      final Pointer<Utf8> p = _lastError();
      if (p == nullptr) return '未知原生错误';
      return p.toDartString();
    } on Object {
      return '未知原生错误';
    }
  }

  Never _fail(String operation) {
    throw StateError('$operation 失败：${_error()}');
  }

  /// 生成一张图并写入应用图片目录；返回真实文件路径。
  Future<DiffusionResult> generate(DiffusionRequest req) async {
    if (!File(req.diffusionModelPath).existsSync()) {
      return const DiffusionResult(ok: false, error: '扩散模型文件不存在，请先完成下载');
    }
    if (!File(req.vaePath).existsSync()) {
      return const DiffusionResult(
        ok: false,
        error: '缺少 VAE 组件（MiniMax-H3-Image 必须单独下载）',
      );
    }
    if (!File(req.textEncoderPath).existsSync()) {
      return const DiffusionResult(
        ok: false,
        error: '缺少文本编码器（Qwen3-VL / P-H3 Image）',
      );
    }
    Pointer<Void>? ctxOpt;
    Pointer<Void>? imgOpt;
    Pointer<Void>? ctx;
    Pointer<Void>? resultPtr;
    try {
      ctxOpt = _ctxOptCreate();
      if (ctxOpt == nullptr) _fail('创建上下文参数');
      _putStr(ctxOpt, 'diffusion_model_path', req.diffusionModelPath);
      _putStr(ctxOpt, 'vae_path', req.vaePath);
      _putStr(ctxOpt, 'llm_path', req.textEncoderPath);
      if (req.visionTowerPath.isNotEmpty) {
        _putStr(ctxOpt, 'llm_vision_path', req.visionTowerPath);
      }
      _putInt(
        ctxOpt,
        'n_threads',
        req.threads ?? (Platform.numberOfProcessors - 1).clamp(1, 16),
      );
      _putBool(ctxOpt, 'enable_mmap', true);
      _putBool(ctxOpt, 'diffusion_flash_attn', true);
      _putBool(ctxOpt, 'vae_tiling.enabled', true);

      final Pointer<Pointer<Void>> outCtx = calloc<Pointer<Void>>();
      try {
        final int rc = _ctxCreate(ctxOpt, outCtx);
        if (rc != 0) _fail('加载模型');
        ctx = outCtx.value;
      } finally {
        calloc.free(outCtx);
      }
      _optFree(ctxOpt);
      ctxOpt = null;

      imgOpt = _imgOptCreate();
      if (imgOpt == nullptr) _fail('创建生图参数');
      _putStr(imgOpt, 'prompt', req.prompt);
      if (req.negativePrompt.isNotEmpty) {
        _putStr(imgOpt, 'negative_prompt', req.negativePrompt);
      }
      _putInt(imgOpt, 'width', req.width);
      _putInt(imgOpt, 'height', req.height);
      _putInt(imgOpt, 'seed', req.seed);
      _putInt(imgOpt, 'sample.steps', req.steps);
      _putStr(imgOpt, 'sample.method', req.sampler);
      _putDouble(imgOpt, 'sample.guidance.txt_cfg', req.cfgScale);
      // MiniMax-H3-Image 的 6 步 PDD sigma 由默认离散调度器在 steps=6 时生成；
      // 不传自定义 sample.sigmas（那是浮点数组，不是预设名）。

      final Pointer<Pointer<Void>> outResult = calloc<Pointer<Void>>();
      try {
        final int rc = _generate(ctx, imgOpt, outResult);
        if (rc != 0) _fail('生成图片');
        resultPtr = outResult.value;
      } finally {
        calloc.free(outResult);
      }

      final int count = _imageCount(resultPtr);
      if (count <= 0) {
        return const DiffusionResult(ok: false, error: '模型没有返回任何图片');
      }
      final Pointer<Void> tensor = _imageAt(resultPtr, 0);
      if (tensor == nullptr) {
        return const DiffusionResult(ok: false, error: '读取图片张量失败');
      }
      final int channels = _tensorDim(tensor, 0);
      final int w = _tensorDim(tensor, 1);
      final int h = _tensorDim(tensor, 2);
      final int bytes = _tensorBytes(tensor);
      if (channels < 3 || w <= 0 || h <= 0 || bytes < w * h * 3) {
        return const DiffusionResult(ok: false, error: '图片张量尺寸不合法');
      }
      final Uint8List raw = Uint8List.fromList(
        _tensorData(tensor).asTypedList(bytes),
      );
      final img.Image out = img.Image(width: w, height: h);
      for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
          final int i = (y * w + x) * channels;
          out.setPixelRgb(x, y, raw[i], raw[i + 1], raw[i + 2]);
        }
      }
      final Directory root = await getApplicationDocumentsDirectory();
      final Directory dir = Directory(p.join(root.path, 'generated'));
      if (!dir.existsSync()) await dir.create(recursive: true);
      final String path = p.join(
        dir.path,
        'tga-${DateTime.now().millisecondsSinceEpoch}.png',
      );
      await File(path).writeAsBytes(img.encodePng(out));
      return DiffusionResult(ok: true, path: path);
    } on Object catch (e) {
      return DiffusionResult(ok: false, error: e.toString());
    } finally {
      if (ctxOpt != null && ctxOpt != nullptr) _optFree(ctxOpt);
      if (imgOpt != null && imgOpt != nullptr) _optFree(imgOpt);
      if (resultPtr != null && resultPtr != nullptr) _resultFree(resultPtr);
      if (ctx != null && ctx != nullptr) _ctxFree(ctx);
    }
  }

  void _putStr(Pointer<Void> opt, String key, String value) {
    final Pointer<Utf8> k = key.toNativeUtf8();
    final Pointer<Utf8> v = value.toNativeUtf8();
    try {
      if (_setString(opt, k, v) != 0) _fail('设置 $key');
    } finally {
      malloc.free(k);
      malloc.free(v);
    }
  }

  void _putInt(Pointer<Void> opt, String key, int value) {
    final Pointer<Utf8> k = key.toNativeUtf8();
    try {
      if (_setInt(opt, k, value) != 0) _fail('设置 $key');
    } finally {
      malloc.free(k);
    }
  }

  void _putBool(Pointer<Void> opt, String key, bool value) {
    final Pointer<Utf8> k = key.toNativeUtf8();
    try {
      if (_setBool(opt, k, value) != 0) _fail('设置 $key');
    } finally {
      malloc.free(k);
    }
  }

  void _putDouble(Pointer<Void> opt, String key, double value) {
    final Pointer<Utf8> k = key.toNativeUtf8();
    try {
      if (_setDouble(opt, k, value) != 0) _fail('设置 $key');
    } finally {
      malloc.free(k);
    }
  }
}
