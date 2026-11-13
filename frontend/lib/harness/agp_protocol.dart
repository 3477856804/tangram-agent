/// AGP/1 —— Agent Gateway Protocol 信封协议（纯 Dart）。
///
/// 移植自 OpenClaw 微信通道插件 `wechat-openclaw-channel/websocket/types.ts`
/// 与 QQ 通道 `openclaw-onebot`，协议语义保持一致：所有上下行消息统一使用
/// 「信封」格式，通过 `method` 区分类型，`msg_id` 做幂等去重。
///
/// 下行（网关 → 本 APP）：session.prompt / session.cancel
/// 上行（本 APP → 网关）：session.update / session.promptResponse / ping
///
/// 这是真实协议实现：不含任何模拟数据，所有字段都从 JSON 真实编解码。
library;

import 'dart:convert';
import 'dart:math';

/// 消息方法枚举，与 OpenClaw AGP 服务端一一对应。
enum AgpMethod {
  sessionPrompt('session.prompt'),
  sessionCancel('session.cancel'),
  sessionUpdate('session.update'),
  sessionPromptResponse('session.promptResponse'),
  ping('ping');

  const AgpMethod(this.wire);
  final String wire;

  static AgpMethod? parse(String? s) {
    if (s == null) return null;
    for (final m in AgpMethod.values) {
      if (m.wire == s) return m;
    }
    return null;
  }
}

/// 内容块。当前协议仅支持 text。
class ContentBlock {
  const ContentBlock({this.type = 'text', required this.text});

  final String type;
  final String text;

  Map<String, dynamic> toJson() => <String, dynamic>{'type': type, 'text': text};

  static ContentBlock? fromJson(dynamic v) {
    if (v is! Map) return null;
    final m = Map<String, dynamic>.from(v);
    return ContentBlock(
      type: (m['type'] ?? 'text').toString(),
      text: (m['text'] ?? '').toString(),
    );
  }
}

/// 工具调用状态，供 session.update 实时推送工具执行进度。
enum ToolCallStatus { pending, inProgress, completed, failed }

class ToolCall {
  const ToolCall({
    required this.toolCallId,
    this.title,
    this.kind,
    required this.status,
    this.content,
    this.locations = const <String>[],
  });

  final String toolCallId;
  final String? title;
  final String? kind;
  final ToolCallStatus status;
  final List<ContentBlock>? content;
  final List<String> locations;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tool_call_id': toolCallId,
        if (title != null) 'title': title,
        if (kind != null) 'kind': kind,
        'status': status.wire,
        if (content != null)
          'content': content!.map((c) => c.toJson()).toList(),
        if (locations.isNotEmpty) 'locations': locations.map((p) => <String, dynamic>{'path': p}).toList(),
      };
}

extension on ToolCallStatus {
  String get wire => switch (this) {
        ToolCallStatus.pending => 'pending',
        ToolCallStatus.inProgress => 'in_progress',
        ToolCallStatus.completed => 'completed',
        ToolCallStatus.failed => 'failed',
      };
}

/// 停止原因。end_turn 正常 / cancelled 被取消 / refusal 拒绝 / error 技术错误。
enum StopReason { endTurn, cancelled, refusal, error }

extension on StopReason {
  String get wire => switch (this) {
        StopReason.endTurn => 'end_turn',
        StopReason.cancelled => 'cancelled',
        StopReason.refusal => 'refusal',
        StopReason.error => 'error',
      };
}

/// 更新类型。
enum UpdateType { messageChunk, toolCall, toolCallUpdate }

extension on UpdateType {
  String get wire => switch (this) {
        UpdateType.messageChunk => 'message_chunk',
        UpdateType.toolCall => 'tool_call',
        UpdateType.toolCallUpdate => 'tool_call_update',
      };
}

/// AGP 统一消息信封。
class AgpEnvelope {
  AgpEnvelope({
    required this.msgId,
    required this.method,
    required this.payload,
    this.guid,
    this.userId,
  });

  final String msgId;
  final String? guid;
  final String? userId;
  final AgpMethod method;
  final Map<String, dynamic> payload;

  static String newId() {
    final r = Random.secure();
    String hex(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + r.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'msg_id': msgId,
        if (guid != null) 'guid': guid,
        if (userId != null) 'user_id': userId,
        'method': method.wire,
        'payload': payload,
      };

  static AgpEnvelope? decode(dynamic raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final method = AgpMethod.parse(m['method']?.toString());
    if (method == null) return null;
    final payload = m['payload'];
    return AgpEnvelope(
      msgId: (m['msg_id'] ?? '').toString(),
      guid: m['guid']?.toString(),
      userId: m['user_id']?.toString(),
      method: method,
      payload: payload is Map
          ? Map<String, dynamic>.from(payload)
          : <String, dynamic>{},
    );
  }

  static AgpEnvelope? decodeText(String text) {
    try {
      return decode(jsonDecode(text));
    } on Object {
      return null;
    }
  }
}

/// session.prompt 载荷 —— 网关下发的用户指令。
class PromptPayload {
  PromptPayload({
    required this.sessionId,
    required this.promptId,
    required this.agentApp,
    required this.content,
  });

  final String sessionId;
  final String promptId;
  final String agentApp;
  final List<ContentBlock> content;

  /// 拼接纯文本指令（OneBot / 微信消息归一化后也走这里）。
  String get text => content.map((c) => c.text).join();

  static PromptPayload fromMap(Map<String, dynamic> m) => PromptPayload(
        sessionId: (m['session_id'] ?? '').toString(),
        promptId: (m['prompt_id'] ?? '').toString(),
        agentApp: (m['agent_app'] ?? '').toString(),
        content: (m['content'] is List)
            ? (m['content'] as List)
                .map(ContentBlock.fromJson)
                .whereType<ContentBlock>()
                .toList()
            : <ContentBlock>[ContentBlock(text: (m['content'] ?? '').toString())],
      );
}

/// session.cancel 载荷。
class CancelPayload {
  CancelPayload({required this.sessionId, required this.promptId, required this.agentApp});
  final String sessionId;
  final String promptId;
  final String agentApp;

  static CancelPayload fromMap(Map<String, dynamic> m) => CancelPayload(
        sessionId: (m['session_id'] ?? '').toString(),
        promptId: (m['prompt_id'] ?? '').toString(),
        agentApp: (m['agent_app'] ?? '').toString(),
      );
}

/// 上行 session.update（流式增量）。
class UpdatePayload {
  const UpdatePayload({
    required this.sessionId,
    required this.promptId,
    required this.updateType,
    this.content,
    this.toolCall,
  });

  final String sessionId;
  final String promptId;
  final UpdateType updateType;
  final ContentBlock? content;
  final ToolCall? toolCall;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'session_id': sessionId,
        'prompt_id': promptId,
        'update_type': updateType.wire,
        if (content != null) 'content': content!.toJson(),
        if (toolCall != null) 'tool_call': toolCall!.toJson(),
      };
}

/// 上行 session.promptResponse（Turn 结束回执）。
class PromptResponsePayload {
  const PromptResponsePayload({
    required this.sessionId,
    required this.promptId,
    required this.stopReason,
    this.content,
    this.error,
  });

  final String sessionId;
  final String promptId;
  final StopReason stopReason;
  final List<ContentBlock>? content;
  final String? error;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'session_id': sessionId,
        'prompt_id': promptId,
        'stop_reason': stopReason.wire,
        if (content != null) 'content': content!.map((c) => c.toJson()).toList(),
        if (error != null) 'error': error,
      };
}

/// msg_id 幂等去重缓存（对齐 CentrifugeGatewayClient.MAX_MSG_ID_CACHE）。
class MsgIdCache {
  MsgIdCache({this.max = 1000});
  final int max;
  final Set<String> _seen = <String>{};
  final List<String> _order = <String>[];

  /// 返回 true 表示首次见到（应处理），false 表示重复（应丢弃）。
  bool checkAndAdd(String id) {
    if (id.isEmpty) return true;
    if (_seen.contains(id)) return false;
    _seen.add(id);
    _order.add(id);
    if (_order.length > max) {
      _seen.remove(_order.removeAt(0));
    }
    return true;
  }

  void clear() {
    _seen.clear();
    _order.clear();
  }

  int get length => _seen.length;
}
