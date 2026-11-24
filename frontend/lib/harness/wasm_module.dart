/// WASM 模块级插件宿主（契约 `wasm/1`，见 `contracts/wasm-abi-v1.md`）。
///
/// 当前状态：**运行时未接线**。本机（Android / 无 wasmtime）一律类型化拒绝，
/// 绝不静默降级为「执行成功」——这是 0.0.41 审计里 G6 的诚实落法。
library;

import 'dart:convert';
import 'dart:typed_data';

/// 运行时不可用：类型化拒绝，调用方必须显式处理。
class WasmUnavailable implements Exception {
  WasmUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'WasmUnavailable: $reason';
}

/// 模块契约不合法（ABI 不匹配、缺导出、超上限）。
class WasmContractError implements Exception {
  WasmContractError(this.reason);

  final String reason;

  @override
  String toString() => 'WasmContractError: $reason';
}

/// 已加载模块的描述（只描述，不执行）。
class WasmModuleSpec {
  WasmModuleSpec({
    required this.abi,
    required this.module,
    required this.caps,
    required this.memoryPages,
    required this.fuel,
    required this.timeoutMs,
  });

  final String abi;
  final String module;
  final List<String> caps;
  final int memoryPages;
  final int fuel;
  final int timeoutMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'abi': abi,
        'module': module,
        'caps': caps,
        'limits': <String, dynamic>{
          'memoryPages': memoryPages,
          'fuel': fuel,
          'timeoutMs': timeoutMs,
        },
        'runtime': 'unavailable',
      };
}

/// 宿主：构造即拒绝（无运行时），但保留契约校验能力，便于将来接线。
class WasmModule {
  WasmModule._(this.spec);

  final WasmModuleSpec spec;

  /// 尝试加载。当前实现始终抛 [WasmUnavailable]。
  static WasmModule load(Map<String, dynamic> manifest) {
    final String abi = (manifest['abi'] ?? '').toString();
    if (abi != 'wasm/1') {
      throw WasmContractError('ABI 不匹配：$abi（仅支持 wasm/1）');
    }
    final Object? capsRaw = manifest['caps'];
    if (capsRaw is! List || capsRaw.isEmpty) {
      throw WasmContractError('T3 模块必须显式声明 caps（fail-closed）');
    }
    final Map<String, dynamic> limits = (manifest['limits'] is Map)
        ? Map<String, dynamic>.from(manifest['limits'] as Map)
        : <String, dynamic>{};
    final int pages = (limits['memoryPages'] is num)
        ? (limits['memoryPages'] as num).toInt()
        : 64;
    if (pages < 1 || pages > 256) {
      throw WasmContractError('memoryPages 越界：$pages（1..256）');
    }
    final WasmModuleSpec spec = WasmModuleSpec(
      abi: abi,
      module: (manifest['module'] ?? '').toString(),
      caps: capsRaw.map((dynamic e) => e.toString()).toList(),
      memoryPages: pages,
      fuel: (limits['fuel'] is num) ? (limits['fuel'] as num).toInt() : 1000000,
      timeoutMs:
          (limits['timeoutMs'] is num) ? (limits['timeoutMs'] as num).toInt() : 5000,
    );
    throw WasmUnavailable(
        '本机无 WASM 运行时（Android 无 wasm FFI，桌面未接 wasmtime）：${spec.module}');
  }

  /// JSON 帧编解码（供将来接线复用；现在只保证格式正确）。
  static Uint8List encodeFrame(Map<String, dynamic> payload) {
    final Uint8List body = Uint8List.fromList(
        utf8.encode(jsonEncode(payload)) as List<int>);
    final ByteData head = ByteData(4)..setUint32(0, body.length, Endian.little);
    final Uint8List out = Uint8List(4 + body.length);
    out.setRange(0, 4, head.buffer.asUint8List());
    out.setRange(4, 4 + body.length, body);
    return out;
  }

  static Map<String, dynamic> decodeFrame(Uint8List frame) {
    if (frame.length < 4) {
      throw WasmContractError('帧长度不足 4 字节');
    }
    final int len =
        ByteData.view(frame.buffer, frame.offsetInBytes).getUint32(0, Endian.little);
    if (frame.length < 4 + len) {
      throw WasmContractError('帧声明长度 $len 与实际 ${frame.length - 4} 不符');
    }
    return Map<String, dynamic>.from(
        jsonDecode(utf8.decode(frame.sublist(4, 4 + len))) as Map);
  }
}
