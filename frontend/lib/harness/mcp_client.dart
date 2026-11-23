/// 真实 MCP（Model Context Protocol）客户端——HTTP/SSE（streamable HTTP）传输。
///
/// 为什么只做 HTTP 传输：MCP 的 stdio 传输需要父进程 spawn 子进程，
/// Android / iOS 沙箱不允许启动外部进程，因此 stdio 服务只能在桌面端或
/// 自建网关侧运行；移动端能真实连接的是暴露 HTTP 端点的 MCP 服务。
///
/// 协议流程（JSON-RPC 2.0 over HTTP POST）：
///   1. initialize（携带 protocolVersion / capabilities / clientInfo）
///      → 读回 server 的 capabilities，若响应头带 Mcp-Session-Id 则后续透传。
///   2. notifications/initialized（通知，无 id）。
///   3. tools/list → 得到 [{name, description, inputSchema}]。
///   4. tools/call {name, arguments} → 得到 content（文本 / 资源）。
/// 每一步都真实发请求；失败如实返回错误，不编造工具或结果。

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:tangram/app_version.dart';

import 'mcp_hardening.dart';

class McpToolInfo {
  const McpToolInfo({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

/// 工具发现的一页结果：工具列表 + 是否因上限截断 + 原因 + 已取页数。
class McpToolPage {
  const McpToolPage({
    required this.tools,
    required this.truncated,
    required this.reason,
    required this.pagesFetched,
  });
  final List<McpToolInfo> tools;
  final bool truncated;
  final String reason;
  final int pagesFetched;
}

class McpCallResult {
  const McpCallResult({required this.ok, this.text = '', this.error = ''});
  final bool ok;
  final String text;
  final String error;
}

class McpClient {
  McpClient(this.url, {this.headers = const <String, String>{}, http.Client? client})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final String url;
  final Map<String, String> headers;
  final http.Client _client;
  final bool _ownsClient;

  String? _sessionId;
  int _rpcId = 0;
  bool _initialized = false;

  static const String protocolVersion = '2024-11-05';

  Map<String, String> get _baseHeaders => <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        ...headers,
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      };

  /// 握手：initialize + initialized 通知。返回 server 标题（若有）。
  Future<String> initialize() async {
    final resp = await _rpc('initialize', <String, dynamic>{
      'protocolVersion': protocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': <String, dynamic>{
        'name': 'tangram-agent',
        'version': kAppVersion,
      },
    });
    String title = '';
    final result = resp['result'];
    if (result is Map) {
      final info = result['serverInfo'];
      if (info is Map) title = (info['name'] ?? '').toString();
    }
    // initialized 是通知（无 id），失败不致命。
    try {
      await _notify('notifications/initialized', <String, dynamic>{});
    } on Object {
      // 有些服务端不接受该通知名，忽略即可。
    }
    _initialized = true;
    return title;
  }

  /// 列出工具（分页跟进 nextCursor，上限 250 个工具 / 20 页，超了截断并记原因）。
  /// 未初始化会先 initialize。
  Future<McpToolPage> listToolsPaged() async {
    if (!_initialized) await initialize();
    final List<McpToolInfo> out = <McpToolInfo>[];
    String? cursor;
    int pages = 0;
    bool truncated = false;
    String reason = '';
    while (pages < McpHardening.maxPages) {
      final Map<String, dynamic> params = <String, dynamic>{};
      if (cursor != null) params['cursor'] = cursor;
      final Map<String, dynamic> resp = await _rpc('tools/list', params);
      final dynamic result = resp['result'];
      pages++;
      if (result is Map) {
        final dynamic list = result['tools'];
        if (list is List) {
          for (final dynamic t in list.whereType<Map>()) {
            final String name = (t['name'] ?? '').toString();
            if (name.isEmpty) continue;
            out.add(McpToolInfo(
              name: name,
              description: (t['description'] ?? '').toString(),
              inputSchema: t['inputSchema'] is Map
                  ? Map<String, dynamic>.from(t['inputSchema'] as Map)
                  : <String, dynamic>{},
            ));
          }
        }
        final dynamic next = result['nextCursor'];
        cursor = next is String && next.isNotEmpty ? next : null;
      }
      if (out.length >= McpHardening.maxTools) {
        truncated = true;
        reason =
            '工具数超过上限 ${McpHardening.maxTools}，已截断到 ${McpHardening.maxTools} 个';
        break;
      }
      if (cursor == null) break;
    }
    if (!truncated && pages >= McpHardening.maxPages && cursor != null) {
      truncated = true;
      reason = '工具分页超过上限 ${McpHardening.maxPages} 页，已截断';
    }
    final List<McpToolInfo> kept = out.length > McpHardening.maxTools
        ? out.sublist(0, McpHardening.maxTools)
        : out;
    return McpToolPage(
      tools: kept,
      truncated: truncated,
      reason: reason,
      pagesFetched: pages,
    );
  }

  /// 列出工具。未初始化会先 initialize（走分页版，同样受上限约束）。
  Future<List<McpToolInfo>> listTools() async {
    final McpToolPage page = await listToolsPaged();
    return page.tools;
  }

  /// 调用工具，返回聚合文本内容。
  Future<McpCallResult> callTool(
      String name, Map<String, dynamic> arguments) async {
    if (!_initialized) {
      try {
        await initialize();
      } on Object catch (e) {
        return McpCallResult(ok: false, error: 'MCP 初始化失败：$e');
      }
    }
    try {
      final resp = await _rpc('tools/call', <String, dynamic>{
        'name': name,
        'arguments': arguments,
      });
      if (resp.containsKey('error')) {
        final err = resp['error'];
        final msg = err is Map ? (err['message'] ?? '$err') : '$err';
        return McpCallResult(ok: false, error: msg.toString());
      }
      final result = resp['result'];
      final buf = StringBuffer();
      if (result is Map) {
        final content = result['content'];
        if (content is List) {
          for (final c in content.whereType<Map>()) {
            final type = (c['type'] ?? '').toString();
            if (type == 'text') {
              buf.writeln((c['text'] ?? '').toString());
            } else if (type == 'resource') {
              buf.writeln('[资源] ${c['resource'] ?? ''}');
            }
          }
        }
        if (result['isError'] == true) {
          return McpCallResult(
              ok: false, text: buf.toString().trim(), error: '工具返回错误');
        }
      }
      return McpCallResult(ok: true, text: buf.toString().trim());
    } on Object catch (e) {
      return McpCallResult(ok: false, error: '$e');
    }
  }

  Future<Map<String, dynamic>> _rpc(String method, Map<String, dynamic> params) async {
    final id = ++_rpcId;
    final body = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    });
    final http.Response resp;
    try {
      resp = await _client
          .post(Uri.parse(url), headers: _baseHeaders, body: body)
          .timeout(McpHardening.requestTimeout);
    } on Object catch (e) {
      throw StateError('连接 MCP 服务失败：$e');
    }
    final sid = resp.headers['mcp-session-id'] ?? resp.headers['Mcp-Session-Id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;
    if (resp.statusCode ~/ 100 != 2) {
      throw StateError('HTTP ${resp.statusCode}：${_trim(resp.body)}');
    }
    // 兼容两种响应体：纯 JSON，或 SSE（text/event-stream）里的 data: 行。
    final decoded = _parseBody(resp.body);
    if (decoded == null) throw StateError('MCP 返回空响应');
    return decoded;
  }

  Future<void> _notify(String method, Map<String, dynamic> params) async {
    final body = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'method': method,
      'params': params,
    });
    await _client
        .post(Uri.parse(url), headers: _baseHeaders, body: body)
        .timeout(const Duration(seconds: 10));
  }

  Map<String, dynamic>? _parseBody(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    if (t.startsWith('{') || t.startsWith('[')) {
      final d = jsonDecode(t);
      if (d is Map) return Map<String, dynamic>.from(d);
      if (d is List && d.isNotEmpty && d.first is Map) {
        return Map<String, dynamic>.from(d.first as Map);
      }
      return null;
    }
    // SSE：取最后一条含 id 的 data: JSON。
    Map<String, dynamic>? last;
    for (final line in const LineSplitter().convert(raw)) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        final d = jsonDecode(payload);
        if (d is Map) last = Map<String, dynamic>.from(d);
      } on Object {
        // 忽略非 JSON 行。
      }
    }
    return last;
  }

  static String _trim(String s) =>
      s.length > 200 ? '${s.substring(0, 200)}…' : s;

  void dispose() {
    if (_ownsClient) _client.close();
  }
}
