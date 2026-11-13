
import 'dart:async';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/bridge/bridge_protocol.dart';

class BackendCapabilities {
  const BackendCapabilities({
    required this.name,
    required this.version,
    required this.transport,
    this.controlDomains = const <String>[],
    this.hotPathTopics = const <String>[],
    this.multimodalChannels = const <String>[],
    this.ready = false,
  });

  final String name;

  final String version;

  final String transport;

  final List<String> controlDomains;

  final List<String> hotPathTopics;

  final List<String> multimodalChannels;

  final bool ready;

  static BackendCapabilities fromJson(Map<String, dynamic> json) {
    List<String> listOf(String key) {
      final value = json[key];
      if (value is List) {
        return value.map((e) => e.toString()).toList(growable: false);
      }
      return const <String>[];
    }

    return BackendCapabilities(
      name: (json['name'] ?? 'unknown').toString(),
      version: (json['version'] ?? '0.0.1').toString(),
      transport: (json['transport'] ?? 'unknown').toString(),
      controlDomains: listOf('control_domains'),
      hotPathTopics: listOf('hot_path_topics'),
      multimodalChannels: listOf('multimodal_channels'),
      ready: json['ready'] == true,
    );
  }

  String get summary =>
      '$name v$version via $transport（control ${controlDomains.length} 域 / '
      'hot-path ${hotPathTopics.length} 主题${ready ? '，已就绪' : '，未就绪'}）';

  BackendCapabilities copyWith({
    String? name,
    String? version,
    String? transport,
    List<String>? controlDomains,
    List<String>? hotPathTopics,
    List<String>? multimodalChannels,
    bool? ready,
  }) => BackendCapabilities(
    name: name ?? this.name,
    version: version ?? this.version,
    transport: transport ?? this.transport,
    controlDomains: controlDomains ?? this.controlDomains,
    hotPathTopics: hotPathTopics ?? this.hotPathTopics,
    multimodalChannels: multimodalChannels ?? this.multimodalChannels,
    ready: ready ?? this.ready,
  );

  @override
  String toString() => summary;
}

abstract class BackendPort {
  BackendCapabilities get capabilities;

  bool get isReady;

  Future<void> start();

  Future<void> stop();

  Stream<BridgeEnvelope> get onHotPath;

  Future<BridgeEnvelope?> chat(String text, {String sessionId = ''});
}

class BridgeBackendPort implements BackendPort {
  BridgeBackendPort({
    this.pythonExecutable = 'python3',
    this.workingDirectory = '',
    this.host = '127.0.0.1',
    this.mode = BridgeMode.stdio,
  });

  final String pythonExecutable;

  final String workingDirectory;

  final String host;

  final BridgeMode mode;

  late final BackendClient _client = BackendClient(
    mode: mode,
    host: host,
    pythonExecutable: pythonExecutable,
    workingDirectory: workingDirectory,
  );

  // 协商完成前不编造能力信息；真实 name/version/transport/domains 来自
  // 后端 capability_negotiation 响应。
  BackendCapabilities _capabilities = const BackendCapabilities(
    name: 'unknown',
    version: '0.0.1',
    transport: 'unknown',
  );

  BackendClient get rawClient => _client;

  @override
  BackendCapabilities get capabilities => _capabilities;

  @override
  bool get isReady => _client.ready;

  @override
  Stream<BridgeEnvelope> get onHotPath => _client.onHotPath;

  @override
  Future<void> start() async {
    await _client.connect();
    _capabilities = _capabilities.copyWith(ready: _client.ready);
    try {
      final env = await _client.sendControl(
        'capability_negotiation',
        <String, dynamic>{},
      );
      final payload = env.payload;
      if (payload is Map) {
        _capabilities = BackendCapabilities.fromJson(
          payload.map((k, v) => MapEntry(k.toString(), v)),
        ).copyWith(ready: _client.ready);
      }
    } on Object {
    }
  }

  @override
  Future<void> stop() async {
    await _client.disconnect();
    _capabilities = _capabilities.copyWith(ready: false);
  }

  @override
  Future<BridgeEnvelope?> chat(String text, {String sessionId = ''}) async {
    return _client.sendControl('chat', <String, dynamic>{
      'text': text,
      'session_id': sessionId,
    });
  }

  Future<BridgeEnvelope?> send(String topic, Map<String, dynamic> payload) =>
      _client.sendControl(topic, payload);
}
