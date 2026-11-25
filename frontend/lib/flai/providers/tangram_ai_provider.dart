import 'dart:async';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../harness/cloud_error.dart';
import '../../services/agents_store.dart';
import '../../services/model_registry.dart';
import '../../services/persona_store.dart';
import '../../services/presence_store.dart';
import '../core/models/chat_event.dart';
import '../core/models/chat_request.dart';
import '../core/models/message.dart';
import 'ai_provider.dart';

class TangramAiProvider implements AiProvider {
  TangramAiProvider({
    required this.client,
    // 对话走真流式，需大于 BackendClient 的 chat 预算，避免长回复被提前掐断；
    // 短控制域仍由 BackendClient.requestTimeout(45s) 兜底。
    this.timeout = const Duration(minutes: 10),
  });

  final BackendClient client;
  final Duration timeout;

  /// 当前选中的真实模型。选中云端模型时，聊天请求会带上真实 api_base /
  /// api_key / model，让后端发起真实 HTTP 推理；由 main 在注册表加载后注入。
  ModelRegistry? registry;

  /// 用户的人格/对话参数（system prompt、temperature 等），真实注入推理请求。
  PersonaStore? persona;

  /// 场景感知 / 情绪 / 打断恢复状态；由主流程注入。
  /// 为 null 时提示词与行为完全保持改造前不变。
  PresenceStore? presence;

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
  /// 复用 [friendlyCloudError] 单一真源：覆盖 429 限流并去除裸 JSON，
  /// 与内嵌后端保持一致，避免两处转译不一致。
  String _friendlyCloudError(String raw) => friendlyCloudError(raw);

  Map<String, dynamic> _payload(ChatRequest request, String system) {
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
    'system': system,
    'metadata': <String, dynamic>{
      ...?request.metadata,
      'seq': _sequence++,
    },
    ...modelParams,
    };
  }

  /// 人格 system prompt + 当前启用的自定义智能体人设（智能体中心 #14）
  /// + 在场状态块（场景模式 / 情绪 / 打断任务）。
  /// 无启用智能体且未注入 PresenceStore 时与改造前完全一致；
  /// agents.json 读取失败也不影响对话。
  Future<String> _systemWithAgents() async {
    final String base = persona?.systemPrompt ?? '';
    final String agents = await AgentsStore.enabledSystemPromptBlock();
    final String presenceBlock = presence?.summaryBlock() ?? '';
    final List<String> parts = <String>[];
    if (base.isNotEmpty) parts.add(base);
    if (agents.isNotEmpty) parts.add(agents);
    if (presenceBlock.isNotEmpty) parts.add(presenceBlock);
    return parts.join('\n\n');
  }

  @override
  Stream<ChatEvent> streamChat(ChatRequest request) {
    late StreamController<ChatEvent> controller;
    StreamSubscription<BridgeEnvelope>? subscription;
    bool emitted = false;
    bool closed = false;
    bool replyRecorded = false;
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
      // 每轮用户消息只在这里记录一次，供场景/情绪状态判断语气。
      final String prompt = _promptOf(request);
      if (prompt.trim().isNotEmpty) {
        presence?.recordUserMessage(prompt);
      }
      // 保留 hot-path 监听：将来后端推送真实逐 token 流时可直接消费。
      // 当前内嵌后端把完整回复放在 control payload，下面用打字机分片呈现，
      // 内容 100% 来自后端真实计算，不做任何编造。
      subscription = client.onHotPath.listen((BridgeEnvelope env) {
        if (env.topic == 'chat_status') {
          final dynamic p = env.payload;
          if (p is Map) {
            final String phase = (p['phase'] ?? '').toString();
            if (phase.isEmpty) return;
            final List<Map<String, String>> results = <Map<String, String>>[];
            final dynamic rawResults = p['results'];
            if (rawResults is List) {
              for (final dynamic r in rawResults) {
                if (r is Map) {
                  results.add(<String, String>{
                    'title': (r['title'] ?? '').toString(),
                    'url': (r['url'] ?? '').toString(),
                  });
                }
              }
            }
            emit(SearchStatus(
              phase: phase,
              query: p['query']?.toString(),
              results: results,
              points: p['points']?.toString(),
            ));
          }
          return;
        }
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
        final Map<String, dynamic> payload =
            _payload(request, await _systemWithAgents());
        final BridgeEnvelope response = await client
            .sendControl('agent_command', payload)
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
          // 提速：仅在后端完全没发流式 token 时走此兜底。把分片加大、
          // 间隔缩短，把「逐字观感」的额外开销从约 0.4s 压到 <0.1s；
          // 真流式路径（emitted=true）完全不经过这里，零人为延迟。
          const int chunk = 24;
          const int delayMs = 3;
          for (var i = 0; i < runes.length; i += chunk) {
            if (closed || _cancelled) break;
            final end = (i + chunk > runes.length) ? runes.length : i + chunk;
            final piece = String.fromCharCodes(runes.sublist(i, end));
            buffer.write(piece);
            emit(TextDelta(piece));
            if (delayMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: delayMs));
            }
          }
        }
        emit(TextDone(buffer.toString()));
        if (!replyRecorded && buffer.isNotEmpty) {
          replyRecorded = true;
          presence?.recordAssistantReply(buffer.toString());
        }
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
