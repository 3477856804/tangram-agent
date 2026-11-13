import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/services/persona_store.dart';

enum PythonRuntimeState { unknown, available, unavailable }

/// 状态说明：本 APP 后端是纯 Dart 内嵌 harness，随 APK 内置、开箱即用，
/// 不依赖 Python 运行时。仅当显式切换到 stdio/tcp 外部桥时才需要 Python。
const String kNoPythonHint = '当前处于外部 Python 桥模式，但未检测到可用的 python3。'
    '请安装 Python 或在设置里切回「内置沙箱」（纯 Dart 内嵌后端，无需 Python）。';

/// 内置沙箱运行时：环境切换、状态展示。
///
/// 后端控制域（chat / rpc / model_route 等）由进程内 EmbeddedBackend 真实
/// 执行，绝不用假数据冒充；仅 stdio/tcp 外部桥模式才探测本机 Python。
class SandboxRuntime extends ChangeNotifier {
  SandboxRuntime({required this.backend, this.persona});

  final BackendClient backend;
  final PersonaStore? persona;

  static const List<String> environments = <String>['内置沙箱', 'TCP 桥', '仅本地'];

  PythonRuntimeState python = PythonRuntimeState.unknown;
  bool starting = false;
  String? notice;

  bool get online => backend.ready;

  String get environment => persona?.sandboxEnvironment ?? '内置沙箱';

  /// 内嵌后端是否随包常驻（inProcess 模式恒为 true）。
  bool get embeddedReady => backend.mode == BridgeMode.inProcess && backend.ready;

  /// 只有「外部 Python 桥模式」且本机确实没有 python3 时才需要提示安装 Python。
  /// 纯 Dart 内嵌后端下恒为 false —— 避免把「无需 Python」这种正常状态
  /// 误渲染成红色错误，也避免在任何面板出现误导性的 Python 排错指引。
  bool get needsPythonHint =>
      backend.mode != BridgeMode.inProcess &&
      backend.mode != BridgeMode.embedded &&
      python == PythonRuntimeState.unavailable;

  Future<void> probe() async {
    if (backend.mode == BridgeMode.inProcess ||
        backend.mode == BridgeMode.embedded) {
      // 纯 Dart 内嵌后端：无 Python 参与，如实声明 Python 不适用。
      python = PythonRuntimeState.unavailable;
    } else {
      try {
        final ProcessResult result = await Process.run(
          'python3',
          <String>['--version'],
        ).timeout(const Duration(seconds: 3));
        python = result.exitCode == 0
            ? PythonRuntimeState.available
            : PythonRuntimeState.unavailable;
      } on Object {
        python = PythonRuntimeState.unavailable;
      }
    }
    notifyListeners();
  }

  /// 「重新连接」：内嵌后端模式下真实重连并回执，绝不弹假的「未接入」提示。
  Future<void> launch() async {
    if (starting) return;
    starting = true;
    notice = null;
    notifyListeners();

    await probe();
    if (backend.mode == BridgeMode.inProcess ||
        backend.mode == BridgeMode.embedded) {
      try {
        if (!backend.ready) {
          await backend.reconnect();
        }
        notice = backend.ready
            ? null
            : '内嵌后端未就绪，请重启应用后重试。';
      } on Object catch (e) {
        notice = '内嵌后端重连失败：$e';
      }
    } else if (python != PythonRuntimeState.available) {
      notice = kNoPythonHint;
    } else if (environment == '仅本地') {
      notice = '当前为「仅本地」环境，不启动 Python 后端；'
          '如需外部桥数据请切换到「内置沙箱」或「TCP 桥」。';
    } else {
      try {
        if (!backend.ready) {
          await backend.reconnect();
        }
        notice = backend.ready ? null : '外部后端未就绪，请确认 backend/main.py 存在后重试。';
      } on Object catch (e) {
        notice = '外部 Python 启动失败：$e';
      }
    }

    starting = false;
    notifyListeners();
  }

  void setEnvironment(String value) {
    if (!environments.contains(value)) return;
    persona?.setSandboxEnvironment(value);
    notice = null;
    notifyListeners();
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }
}
