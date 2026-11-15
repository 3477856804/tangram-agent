import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/services/persona_store.dart';
import 'package:tangram/services/ssh_sandbox.dart';

enum PythonRuntimeState { unknown, available, unavailable }

/// 状态说明：本 APP 后端是纯 Dart 内嵌 harness，随 APK 内置、开箱即用，
/// 不依赖 Python 运行时。仅当显式切换到 stdio/tcp 外部桥时才需要 Python。
const String kNoPythonHint = '当前处于外部 Python 桥模式，但未检测到可用的 python3。'
    '请安装 Python 或在设置里切回「内置沙箱」（纯 Dart 内嵌后端，无需 Python）。';

/// 内置沙箱运行时：环境切换、状态展示。
///
/// 环境模型（2026-11 统一）：
///  * **安卓端只有一套 Linux 环境** —— App 私有目录里的 proot + Alpine
///    用户态（uid=0、apk/python/pip 真实可用）。宿主 Android shell
///    （toybox、uid=10541、只读系统分区）不再作为任何「环境」暴露，
///    也绝不作为命令执行后端：那样会出现两套互相矛盾的探测结果。
///  * 桌面端保留四套入口（内置 / 远端 SSH / TCP 桥 / 仅本地），按需切换。
///
/// 后端控制域（chat / rpc / model_route 等）由进程内 EmbeddedBackend 真实
/// 执行，绝不用假数据冒充；仅 stdio/tcp 外部桥模式才探测本机 Python。
class SandboxRuntime extends ChangeNotifier {
  SandboxRuntime({required this.backend, this.persona});

  final BackendClient backend;
  final PersonaStore? persona;

  /// 唯一受管 Linux 环境的名字（安卓端只有它）。
  static const String kBuiltin = '内置沙箱';

  /// 安卓端是否只有一套 Linux 环境（单一环境模型）。
  static bool get singleLinuxHost => Platform.isAndroid;

  /// 当前平台可选环境。安卓端恒为单元素列表，UI 因此不会出现第二个选项，
  /// 也不可能再切出「另一台机器」。
  static List<String> get environments => Platform.isAndroid
      ? const <String>[kBuiltin]
      : const <String>[
          kBuiltin,
          '远端沙箱（SSH）',
          'TCP 桥',
          '仅本地',
        ];

  PythonRuntimeState python = PythonRuntimeState.unknown;
  bool starting = false;
  String? notice;

  bool get online => backend.ready;

  /// 生效环境：安卓端强制归一为内置 Linux 环境，历史遗留值（旧版本存过
  /// SSH/TCP/仅本地）一律不再生效，避免「同一台机器两套环境」。
  String get environment {
    final String saved = persona?.sandboxEnvironment ?? kBuiltin;
    if (Platform.isAndroid) return kBuiltin;
    return environments.contains(saved) ? saved : kBuiltin;
  }

  /// 当前环境是否就是那套受管 Linux（安卓恒为 true）。
  bool get managedLinux => Platform.isAndroid && environment == kBuiltin;

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
    // 安卓端只有一套 Linux 环境：非内置值直接忽略（不写盘、不弹错），
    // 保证任何入口都切不出第二套环境。
    if (Platform.isAndroid && value != kBuiltin) return;
    if (!environments.contains(value)) return;
    persona?.setSandboxEnvironment(value);
    notice = null;
    if (value != '远端沙箱（SSH）') {
      // 切离远端：真实断开 SSH 会话，不留悬空连接。
      SshSandbox.instance.disconnect();
    }
    // 同步后端沙箱策略（code_task shell 路由按此分流），失败如实提示。
    unawaited(_syncBackendEnvironment(value));
    notifyListeners();
  }

  Future<void> _syncBackendEnvironment(String value) async {
    try {
      await backend.sendControl('rpc', <String, dynamic>{
        'action': 'sandbox_policy_set',
        'environment': value,
      });
    } on Object {
      notice = '环境已在本机保存；后端策略同步失败（后端未就绪），'
          '终端将按后端当前环境执行。';
      notifyListeners();
    }
  }

  /// 环境自检：由后端在**唯一那套 Linux** 里真实执行 uname/id/disk/apk 探测，
  /// 返回一份口径统一的结果（前端与 Agent 都读这一份，不再各测各的）。
  Future<Map<String, dynamic>> report() async {
    try {
      final env = await backend.sendControl(
          'code_task', <String, dynamic>{'action': 'env_report'});
      final payload = env.payload;
      if (payload is Map) {
        return payload.map((k, v) => MapEntry(k.toString(), v));
      }
      return <String, dynamic>{'ok': false, 'error': '后端返回了非预期结构'};
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }
}