
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:tangram/bridge/bridge_protocol.dart';
import 'package:tangram/harness/embedded_backend.dart';

/// * `inProcess`：纯 Dart 内嵌后端（默认，随 APK 内置，开箱即用）——
///   所有 control 域在 APP 进程内真实执行，数据落到 App 私有目录。
/// * `embedded`：历史遗留的 Chaquopy/CPython MethodChannel 模式（已停用）。
/// * `stdio` / `tcp`：桌面端连接外部 Python 进程 / TCP 桥。
enum BridgeMode { inProcess, stdio, tcp, embedded }

enum BridgeConnectionState { disconnected, connecting, connected, reconnecting }

/// 后端桥未连接。APK 独立运行（未打包 Python 运行时）或后端进程已退出时，
/// 所有 control 请求都应**立即失败**并如实告知，而不是静默丢弃后等超时、
/// 更不能用硬编码假数据冒充真实响应。
class BackendNotConnected implements Exception {
  const BackendNotConnected();

  @override
  String toString() =>
      '后端尚未就绪：进程未连接或连接失败。请点击离线状态条上的「重新连接」，'
      '或在设置里连接外部 TCP 桥。';
}

class BackendClient {
  /// 与 Android MainActivity 中注册的原生通道保持一致。
  static const MethodChannel _embeddedChannel =
      MethodChannel('tangram/embedded_bridge');

  BackendClient({
    this.mode = BridgeMode.inProcess,
    this.host = '127.0.0.1',
    this.port = 0,
    this.workingDirectory = '',
    this.pythonExecutable = 'python3',
    // 云端 OpenAI 兼容推理允许最长 30s HTTP，加上工具链路余量取 45s。
    // 本地控制域即时返回，不会因上限变大而变慢。
    this.requestTimeout = const Duration(seconds: 45),
  });

  final BridgeMode mode;
  final String host;
  final int port;
  final String workingDirectory;
  final String pythonExecutable;
  final Duration requestTimeout;

  Process? _process;
  Socket? _socket;
  final FrameParser _parser = FrameParser();
  final StreamController<BridgeEnvelope> _hotStream =
      StreamController<BridgeEnvelope>.broadcast();
  final Map<String, Completer<BridgeEnvelope>> _pending = {};
  int _seq = 0;
  bool _ready = false;
  bool _closed = false;
  Map<String, dynamic> _embeddedInfo = const <String, dynamic>{};
  BridgeConnectionState _connState = BridgeConnectionState.disconnected;
  int _reconnectAttempts = 0;
  final StreamController<BridgeConnectionState> _connController =
      StreamController<BridgeConnectionState>.broadcast();

  /// 纯 Dart 内嵌后端实例（inProcess 模式）。
  EmbeddedBackend? _embedded;

  /// inProcess 模式下把后端 hot-path 事件实时转发到客户端流。
  /// 此前只在 control 返回后批量投递，流式 token 要等整段生成完才可见，
  /// 首字延迟等同全量推理；实时桥接后 SSE 增量即时到达 UI。
  StreamSubscription<Map<String, dynamic>>? _embeddedHotSub;

  bool get ready => _ready;

  /// 内置 Python 运行时的真实初始化信息（版本、已注册 handler 数、数据目录等）。
  Map<String, dynamic> get embeddedInfo => _embeddedInfo;

  BridgeConnectionState get connectionState => _connState;

  Stream<BridgeConnectionState> get onConnectionState => _connController.stream;

  Stream<BridgeEnvelope> get onHotPath => _hotStream.stream;

  void _setConnState(BridgeConnectionState s) {
    if (_connState == s) return;
    _connState = s;
    if (!_connController.isClosed) _connController.add(s);
  }

  Future<void> connect() async {
    _closed = false;
    _setConnState(BridgeConnectionState.connecting);
    try {
      if (mode == BridgeMode.inProcess) {
        // 纯 Dart 内嵌后端：随 APK 内置，无 Python / 无 MethodChannel / 无子进程。
        // 初始化失败时如实抛错，绝不退回假数据或谎报「已连接」。
        _embedded = await EmbeddedBackend.instance();
        _embeddedHotSub = _embedded!.onHotPath.listen((Map<String, dynamic> e) {
          final String t = (e['topic'] ?? '').toString();
          if (t.isEmpty || _hotStream.isClosed) return;
          _hotStream.add(BridgeEnvelope.hot(t, e, '', _nextMsgId()));
        });
        _embeddedInfo = <String, dynamic>{
          'ok': true,
          'backend': 'pure-dart-in-process',
          'version': EmbeddedBackend.version,
          'data_dir': _embedded!.store.root.path,
        };
      } else if (mode == BridgeMode.embedded) {
        // 内置 CPython：原生层解包源码树 + 装配后端，失败时如实抛错，
        // 绝不退回假数据或假「已连接」状态。
        final String? raw = await _embeddedChannel.invokeMethod<String>('init');
        final Map<String, dynamic> info = raw == null
            ? <String, dynamic>{'ok': false, 'error': '原生层返回空结果'}
            : Map<String, dynamic>.from(jsonDecode(raw) as Map);
        if (info['ok'] != true) {
          throw StateError(
            '内置 Python 启动失败：${info['error'] ?? '未知原因'}',
          );
        }
        _embeddedInfo = info;
      } else if (mode == BridgeMode.tcp) {
        _socket = await Socket.connect(host, port);
        _socket!.listen(
          _onData,
          onDone: _onDisconnect,
          onError: (_) => _onDisconnect(),
        );
      } else {
        _process = await Process.start(
          pythonExecutable,
          _buildArgs(),
          workingDirectory: workingDirectory.isEmpty ? null : workingDirectory,
        );
        _process!.stdout.listen(_onData, onDone: _onDisconnect);
        _process!.stderr.listen((d) => stderr.add(d));
      }
      _ready = true;
      _reconnectAttempts = 0;
      _setConnState(BridgeConnectionState.connected);
    } on Object {
      _ready = false;
      _setConnState(BridgeConnectionState.disconnected);
      rethrow;
    }
  }

  List<String> _buildArgs() {
    if (mode == BridgeMode.tcp) {
      return ['main.py', '--bridge', 'tcp', '--bridge-port', port.toString()];
    }
    return ['main.py', '--bridge', 'stdio'];
  }

  Future<BridgeEnvelope> sendControl(
    String topic,
    Map<String, dynamic> payload,
  ) async {
    // 未连接就立即失败：不让请求静默丢弃后干等 10 秒超时，
    // 也不给上层任何用假数据填充界面的机会。
    if (!_ready) {
      throw const BackendNotConnected();
    }
    final id = _nextMsgId();
    if (mode == BridgeMode.inProcess) {
      final backend = _embedded;
      if (backend == null) throw const BackendNotConnected();
      // 对话走 SSE 流式，长回复可能超过普通控制域的 45s 上限；单独放宽，
      // 让流式逐字到达，而不是被整体超时掐断后回退成一次性长等待。
      final Duration budget = (topic == 'agent_command' || topic == 'chat')
          ? const Duration(minutes: 10)
          : requestTimeout;
      final reply = await backend.dispatch(topic, payload).timeout(budget);
      // 轨迹 / 下载进度 / 流式 token 等事件已在 connect 里经 onHotPath
      // 实时投递，不再二次批量投递，避免重复。
      return BridgeEnvelope(BridgeChannel.control, topic, reply.payload, '', id);
    }
    if (mode == BridgeMode.embedded) {
      final String? raw = await _embeddedChannel
          .invokeMethod<String>(
            'call',
            <String, dynamic>{
              'topic': topic,
              'payload': jsonEncode(payload),
              'msg_id': id,
            },
          )
          .timeout(requestTimeout);
      final dynamic decoded = raw == null
          ? <String, dynamic>{
              'ok': false,
              'error': '原生层返回空结果',
            }
          : jsonDecode(raw);
      return BridgeEnvelope(BridgeChannel.control, topic, decoded, '', id);
    }
    if (_process == null && _socket == null) {
      throw const BackendNotConnected();
    }
    final env = BridgeEnvelope.control(topic, payload, '', id);
    final completer = Completer<BridgeEnvelope>();
    _pending[id] = completer;
    _write(encodeFrame(env));
    try {
      return await completer.future.timeout(requestTimeout);
    } on TimeoutException {
      _pending.remove(id);
      throw TimeoutException('control $topic 超时（msg_id=$id）', requestTimeout);
    }
  }

  /// 经 device_file 控制域发起一次真实设备文件操作。
  /// 返回后端 FileOpResult 风格 payload（ok / op / data / error / needs_permission）。
  Future<Map<String, dynamic>> deviceFile(
    String action, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    final env = await sendControl('device_file', <String, dynamic>{
      'action': action,
      'args': args,
    });
    final payload = env.payload;
    if (payload is Map) {
      return payload.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{
      'ok': false,
      'op': action,
      'error': '后端返回了非预期结构',
    };
  }

  /// 经 distill 控制域发起一次真实工作蒸馏操作。
  /// agent = model + harness：本地下载基底模型或调用 API → 工作蒸馏 → 产出自己的模型。
  /// 返回后端 DistillResult 风格 payload（ok / action / data / error）。
  Future<Map<String, dynamic>> distill(
    String action, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    final env = await sendControl('distill', <String, dynamic>{
      'action': action,
      'args': args,
    });
    final payload = env.payload;
    if (payload is Map) {
      return payload.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{
      'ok': false,
      'action': action,
      'error': '后端返回了非预期结构',
    };
  }

  void sendHotPath(String topic, dynamic payload, [String sid = '']) {
    pushHotPath(BridgeEnvelope.hot(topic, payload, sid, _nextMsgId()));
  }

  void pushHotPath(BridgeEnvelope env) {
    // inProcess 模式不经帧通道，直接本地广播，保证事件真实可达。
    if (mode == BridgeMode.inProcess) {
      if (!_hotStream.isClosed) _hotStream.add(env);
      return;
    }
    _write(encodeFrame(env));
  }

  Future<void> disconnect() async {
    _closed = true;
    _ready = false;
    _pending.clear();
    _setConnState(BridgeConnectionState.disconnected);
    if (_process != null) {
      await _process!.stdin.close();
      _process!.kill();
      _process = null;
    }
    if (_socket != null) {
      await _socket!.close();
      _socket = null;
    }
  }

  Future<void> reconnect({
    Duration maxBackoff = const Duration(seconds: 8),
  }) async {
    if (_closed) return;
    _setConnState(BridgeConnectionState.reconnecting);
    final attempt = _reconnectAttempts;
    final backoff = Duration(
      milliseconds: (200 * (1 << attempt)).clamp(0, maxBackoff.inMilliseconds),
    );
    if (attempt > 0) {
      await Future<void>.delayed(backoff);
    }
    try {
      await disconnect();
      await connect();
      _reconnectAttempts = 0;
    } on Object {
      _reconnectAttempts = attempt + 1;
      _setConnState(BridgeConnectionState.disconnected);
      rethrow;
    }
  }

  void dispose() {
    disconnect();
    _embeddedHotSub?.cancel();
    _embeddedHotSub = null;
    _hotStream.close();
    if (!_connController.isClosed) _connController.close();
  }

  void _write(Uint8List frame) {
    // 进程内模式 control 由 sendControl 直接本地分发，hot-path 由
    // pushHotPath 本地广播，都不经帧通道。
    if (mode == BridgeMode.inProcess || mode == BridgeMode.embedded) return;
    if (_socket != null) {
      _socket!.add(frame);
    } else if (_process != null) {
      _process!.stdin.add(frame);
    }
  }

  void _onData(List<int> chunk) {
    for (final env in _parser.feed(chunk)) {
      if (env.channel == BridgeChannel.hotPath) {
        _hotStream.add(env);
        continue;
      }
      final completer = _pending.remove(env.msgId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(env);
      }
    }
  }

  void _onDisconnect() {
    _ready = false;
    if (!_closed) {
      _pending.clear();
      _setConnState(BridgeConnectionState.disconnected);
      reconnect().catchError((_) {
      });
    }
  }

  String _nextMsgId() {
    _seq += 1;
    return '$_seq-${DateTime.now().microsecondsSinceEpoch}';
  }
}
