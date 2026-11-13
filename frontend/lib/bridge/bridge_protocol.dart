
import 'dart:convert';
import 'dart:typed_data';

enum BridgeChannel {
  control,
  hotPath,
  multimodal,
  realtime,
  asyncCb;

  static BridgeChannel fromWire(String s) {
    switch (s) {
      case 'control':
        return BridgeChannel.control;
      case 'hot_path':
      case 'hotpath':
        return BridgeChannel.hotPath;
      case 'multimodal':
        return BridgeChannel.multimodal;
      case 'realtime':
        return BridgeChannel.realtime;
      case 'async_cb':
        return BridgeChannel.asyncCb;
      default:
        return BridgeChannel.control;
    }
  }
}

extension BridgeChannelWire on BridgeChannel {
  String get wire {
    switch (this) {
      case BridgeChannel.control:
        return 'control';
      case BridgeChannel.hotPath:
        return 'hotpath';
      case BridgeChannel.multimodal:
        return 'multimodal';
      case BridgeChannel.realtime:
        return 'realtime';
      case BridgeChannel.asyncCb:
        return 'async_cb';
    }
  }
}

const List<String> controlDomains = [
  'rpc',
  'capability_negotiation',
  'reload',
  'agent_command',
  'model_route',
  'plugin_lifecycle',
  'im_event',
  'update_status',
  'dependency_event',
  'perception_event',
  'proactive_task',
  'security_approval',
  'code_task',
  'responsibility_trace',
  'device_file',
  'distill',
];

const List<String> hotPathTopics = [
  'stream_token',
  'stream_audio',
  'image_result',
  'subagent_state',
  'graph_result',
  'scene_description',
  'diff',
  'test_report',
  'perception_stream',
  'raw_bytes',
];

class BridgeEnvelope {
  BridgeEnvelope(
    this.channel,
    this.topic, [
    this.payload,
    this.sessionId = '',
    this.msgId = '',
  ]);

  final BridgeChannel channel;
  final String topic;
  final dynamic payload;
  final String sessionId;
  final String msgId;

  static BridgeEnvelope control(
    String topic,
    dynamic payload, [
    String sid = '',
    String msgId = '',
  ]) => BridgeEnvelope(BridgeChannel.control, topic, payload, sid, msgId);

  static BridgeEnvelope hot(
    String topic,
    dynamic payload, [
    String sid = '',
    String msgId = '',
  ]) => BridgeEnvelope(BridgeChannel.hotPath, topic, payload, sid, msgId);

  Map<String, dynamic> toJson() => {
    'msg_id': msgId,
    'channel': channel.wire,
    'topic': topic,
    'payload': payload,
    'session_id': sessionId,
  };

  factory BridgeEnvelope.fromJson(Map<String, dynamic> m) => BridgeEnvelope(
    BridgeChannel.fromWire(m['channel'] as String),
    m['topic'] as String,
    m['payload'],
    (m['session_id'] as String?) ?? '',
    (m['msg_id'] as String?) ?? '',
  );

  @override
  String toString() => jsonEncode(toJson());
}

Uint8List encodeFrame(BridgeEnvelope env) {
  final jsonBytes = utf8.encode(jsonEncode(env.toJson()));
  final out = Uint8List(4 + jsonBytes.length);
  out[0] = (jsonBytes.length >> 24) & 0xFF;
  out[1] = (jsonBytes.length >> 16) & 0xFF;
  out[2] = (jsonBytes.length >> 8) & 0xFF;
  out[3] = jsonBytes.length & 0xFF;
  out.setRange(4, out.length, jsonBytes);
  return out;
}

class FrameParser {
  final List<int> _buf = [];

  List<BridgeEnvelope> feed(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <BridgeEnvelope>[];
    while (_buf.length >= 4) {
      final n = (_buf[0] << 24) | (_buf[1] << 16) | (_buf[2] << 8) | _buf[3];
      if (_buf.length < 4 + n) break;
      final body = _buf.sublist(4, 4 + n);
      _buf.removeRange(0, 4 + n);
      try {
        final m = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
        out.add(BridgeEnvelope.fromJson(m));
      } catch (_) {
      }
    }
    return out;
  }
}
