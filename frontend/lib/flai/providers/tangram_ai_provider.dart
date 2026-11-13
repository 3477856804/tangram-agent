import 'dart:async';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../services/model_registry.dart';
import '../../services/persona_store.dart';
import '../core/models/chat_event.dart';
import '../core/models/chat_request.dart';
import '../core/models/message.dart';
import 'ai_provider.dart';

class TangramAiProvider implements AiProvider {
  TangramAiProvider({
    required this.client,
    // 需大于 BackendClient.requestTimeout(45s)，避免云端推理被上层提前掐断。
    this.timeout = const Duration(seconds: 60),
  });

  final BackendClient client;
  final Duration timeout;

  /// 当前选中的真实模型。选中云端模型时，聊天请求会带上真实 api_base /
  /// api_key / model，让后端发起真实 HTTP 推理；由 main 在注册表加载后注入。
  ModelRegistry? registry;

  /// 用户的人格/对话参数（system prompt、temperature 等），真实注入推理请求。
  PersonaStore? persona;

  StreamSubscription<BridgeEnvelope>? _active;
  int _sequence = 0;
  bool _cancelled = false;

  // 内嵌后端（capability_negotiation 已确认）提供真实的逐 token hot-path
  // 事件与工具调用轨迹；回复内容由后端真实计算，不做任何编造。
  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsToolUse => true;

  @override
  bool get supportsVision => false;

  @override
  bool get supportsThinking => false;

  String _textOf(dynamic payload) {
    if (payload is String) return payload;
    if (payload is Map) {
      final dynamic value = payload['token'] ??
          payload['text'] ??
          payload['reply'] ??
          payload['answer'] ??
          payload['content'];
      if (value is String) return value;
    }
    return '';
  }

  String _promptOf(ChatRequest request) {
    for (final Message message in request.messages.reversed) {
      if (message.role == MessageRole.user) return message.content;
    }
    return request.messages.isEmpty ? '' : request.messages.last.content;
  }

  /// 把云端推理的底层错误转成用户可懂的中文，绝不伪造成功。
  /// 仍如实携带原始信息片段，便于排查，但不把裸错误丢给用户。
  String _friendlyCloudError(String raw) {
    final String s = raw.toLowerCase();
    if (s.contains('401') ||
        s.contains('403') ||
        s.contains('unauthorized') ||
        s.contains('invalid api key') ||
        s.contains('incorrect api key')) {
      return 'API Key 无效或已过期，请到「训练设置」核对后重新保存';
    }
    if (s.contains('404') || s.contains('not found') || s.contains('does not exist')) {
      return '该模型在此 Base URL 下不存在，请核对模型名（如 deepseek-chat）';
    }
    if (s.contains('connection') ||
        s.contains('socket') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('enotfound') ||
        s.contains('econnrefused') ||
        s.contains('network')) {
      return '无法连接该 API 地址，请检查网络或 Base URL 是否正确';
    }
    final String trimmed = raw.length > 80 ? '${raw.substring(0, 80)}…' : raw;
    return '云端调用失败：$trimmed';
  }

  Map<String, dynamic> _payload(ChatRequest request) {
    // 真实模型参数由注册表按当前选中项产出：云端 → API 凭据 + 模型名，
    // 本地权重 → 真实路径，内置 → 引擎标识。放在最后覆盖默认空 model。
    final Map<String, dynamic> modelParams =
        registry?.chatParams() ?? <String, dynamic>{};
    return <String, dynamic>{
    'action': 'chat',
    'text': _promptOf(request),
    'model': request.model ?? '',
    'stream': request.stream ?? true,
    // 「深度思考 / 智能搜索」两个胶囊的真实状态透传给内嵌后端：
    // thinking=true 走两遍推理，search=true 做真实 DuckDuckGo 检索注入上下文。
    'thinking': request.thinking,
    'search': request.search,
    'messages': request.messages
        .map(
          (Message m) => <String, dynamic>{
            'id': m.id,
            'role': m.role.name,
            'content': m.content,
            'timestamp': m.timestamp.toIso8601String(),
          },
        )
        .toList(growable: false),
    'tools': (request.tools ?? <ToolDefinition>[])
        .map(
          (ToolDefinition t) => <String, dynamic>{
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          },
        )
        .toList(growable: false),
    'temperature': persona?.temperature ?? request.temperature ?? 0.7,
    'max_tokens': persona?.maxTokens ?? request.maxTokens ?? 2048,
    'top_p': persona?.topP ?? 0.9,
    'system': persona?.systemPrompt ?? '',
    'metadata': <String, dynamic>{
      ...?request.metadata,
      'seq': _sequence++,
    },
    ...modelParams,
    };
  }

  @override
  Stream<ChatEvent> streamChat(ChatRequest request) {
    late StreamController<ChatEvent> controller;
    StreamSubscription<BridgeEnvelope>? subscription;
    bool emitted = false;
    bool closed = false;
    final StringBuffer buffer = StringBuffer();

    void emit(ChatEvent event) {
      if (!closed && !controller.isClosed) controller.add(event);
    }

    Future<void> finish() async {
      if (closed) return;
      closed = true;
      await subscription?.cancel();
      if (_active == subscription) _active = null;
      emit(const ChatDone());
      if (!controller.isClosed) await controller.close();
    }

    Future<void> start() async {
      _cancelled = false;
      // 保留 hot-path 监听：将来后端推送真实逐 token 流时可直接消费。
      // 当前内嵌后端把完整回复放在 control payload，下面用打字机分片呈现，
      // 内容 100% 来自后端真实计算，不做任何编造。
      subscription = client.onHotPath.listen((BridgeEnvelope env) {
        if (env.topic != 'stream_token') return;
        final String token = _textOf(env.payload);
        if (token.isEmpty) return;
        final bool thinking = env.payload is Map &&
            env.payload['thinking'] == true;
        if (thinking) {
          emit(ThinkingDelta(token));
          return;
        }
        emitted = true;
        buffer.write(token);
        emit(TextDelta(token));
      });
      _active = subscription;
      try {
        final BridgeEnvelope response = await client
            .sendControl('agent_command', _payload(request))
            .timeout(timeout);
        if (!emitted) {
          final Map<String, dynamic>? payloadMap =
              response.payload is Map ? response.payload as Map<String, dynamic> : null;
          // 后端明确报错时如实转成错误事件，绝不把错误当正文渲染。
          if (payloadMap != null && payloadMap['ok'] == false) {
            final err = (payloadMap['error'] ?? '后端返回失败').toString();
            emit(ChatError(StateError(_friendlyCloudError(err)), StackTrace.current));
            await finish();
            return;
          }
          final String reply = _textOf(response.payload);
          // 按 Unicode codepoint 边界分片，避免切断 emoji 代理对；
          // 每片带短延迟，呈现真实的逐字输出观感。
          final runes = reply.runes.toList();
          const int chunk = 12;
          for (var i = 0; i < runes.length; i += chunk) {
            if (closed || _cancelled) break;
            final end = (i + chunk > runes.length) ? runes.length : i + chunk;
            final piece = String.fromCharCodes(runes.sublist(i, end));
            buffer.write(piece);
            emit(TextDelta(piece));
            await Future<void>.delayed(const Duration(milliseconds: 9));
          }
        }
        emit(TextDone(buffer.toString()));
        await finish();
      } catch (error, stack) {
        emit(ChatError(StateError(_friendlyCloudError(error.toString())), stack));
        await finish();
      }
    }

    controller = StreamController<ChatEvent>(
      onListen: start,
      onCancel: () async {
        _cancelled = true;
        await subscription?.cancel();
        if (_active == subscription) _active = null;
      },
    );
    return controller.stream;
  }

  @override
  Future<ChatResponse> chat(ChatRequest request) async {
    final StringBuffer buffer = StringBuffer();
    await for (final ChatEvent event in streamChat(request)) {
      if (event is TextDelta) buffer.write(event.text);
    }
    return ChatResponse(
      message: Message(
        id: 'assistant_${DateTime.now().microsecondsSinceEpoch}',
        role: MessageRole.assistant,
        content: buffer.toString(),
        timestamp: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    await _active?.cancel();
    _active = null;
  }

  Future<void> dispose() async {
    await cancel();
  }
}
