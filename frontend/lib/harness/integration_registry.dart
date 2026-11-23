/// Integrations：MCP / OpenAPI / GraphQL 三类真实外部工具接入。
///
/// 与 Rakazo 的 Integrations 对齐的最小真实集：
///   * 一个集成一条记录，凭据单独存放（生产用 FlutterSecureStorage，
///     测试用内存 Vault），绝不写进 `integrations.json`，也绝不进入模型上下文；
///   * MCP 走真实 initialize + tools/list + tools/call（HTTP/SSE）；
///   * OpenAPI 拉取真实 spec，解析出操作与参数，调用时发真实 HTTP 请求；
///   * GraphQL 做真实 introspection，支持自定义 query / variables；
///   * 每次添加、测试、调用都写追加日志（不含凭据）。
///
/// 边界：移动端不支持 stdio MCP（需 spawn 进程），stdio 默认关闭、仅管理
/// 员可按白名单配置且只保存不启动；OAuth 登录流程未实现，凭据类型支持
/// none / Bearer / API Key Header / Query / OAuth（OAuth 只支持已持有
/// refresh_token 的令牌刷新入口，快过期自动刷新、失败标记需重绑定）。
/// 未实现的能力一律如实返回错误，不伪造成功。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'mcp_client.dart';
import 'mcp_hardening.dart';

/// 凭据仓库：生产实现走系统安全存储，测试实现只在内存。
abstract class SecretVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemorySecretVault implements SecretVault {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

/// OAuth 令牌刷新回调：入参 refresh_token，返回新令牌束；返回 null 表示
/// 刷新失败（调用方标记需重绑定）。未配置时令牌无法刷新。
typedef OAuthTokenRefresher = Future<OAuthTokenBundle?> Function(
  String refreshToken,
);

class IntegrationRegistry {
  IntegrationRegistry(
    Directory root, {
    required SecretVault vault,
    http.Client? client,
    this.refreshOAuthToken,
  })  : _dir = Directory(root.path),
        _vault = vault,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Directory _dir;
  final SecretVault _vault;
  final http.Client _client;
  final bool _ownsClient;
  final OAuthTokenRefresher? refreshOAuthToken;

  final Map<String, McpClient> _mcp = <String, McpClient>{};

  /// 远程 MCP 失败退避：集成 id →（连续失败次数，下次可重试时刻）。
  final Map<String, ({int failures, DateTime nextRetryAt})> _backoff =
      <String, ({int failures, DateTime nextRetryAt})>{};

  /// 该集成是否处于退避窗口内（窗口内不再发真实请求）。
  bool _inBackoff(String id) {
    final ({int failures, DateTime nextRetryAt})? state = _backoff[id];
    if (state == null) return false;
    if (DateTime.now().isBefore(state.nextRetryAt)) return true;
    return false;
  }

  Duration _backoffRemaining(String id) {
    final ({int failures, DateTime nextRetryAt})? state = _backoff[id];
    if (state == null) return Duration.zero;
    final Duration left = state.nextRetryAt.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  void _recordServerFailure(String id) {
    final int failures = (_backoff[id]?.failures ?? 0) + 1;
    final Duration delay = McpHardening.nextBackoffDelay(failures);
    _backoff[id] = (
      failures: failures,
      nextRetryAt: DateTime.now().add(delay),
    );
  }

  void _recordServerSuccess(String id) {
    _backoff.remove(id);
  }

  List<Map<String, dynamic>>? _records;
  Future<void>? _initFuture;

  static const int maxSpecBytes = 2 * 1024 * 1024;
  static const int maxResponseBytes = 4 * 1024 * 1024;
  static const Duration timeout = Duration(seconds: 20);

  File get _file => File('${_dir.path}/integrations.json');
  File get _logFile => File('${_dir.path}/integrations_log.jsonl');

  Future<void> _ensureInit() => _initFuture ??= _init();

  Future<void> _init() async {
    await _dir.create(recursive: true);
    _records = <Map<String, dynamic>>[];
    if (!await _file.exists()) return;
    try {
      final dynamic decoded = jsonDecode(await _file.readAsString());
      if (decoded is Map && decoded['integrations'] is List) {
        _records = (decoded['integrations'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } on Object {
      // 损坏的配置按空处理，不伪造已接入的集成。
    }
  }

  Future<void> _save() async {
    final File tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, dynamic>{'integrations': _records}),
      flush: true,
    );
    await tmp.rename(_file.path);
  }

  String _newId() => 'int-${DateTime.now().microsecondsSinceEpoch}';

  String _secretKey(String id) => 'integration.$id.token';

  Map<String, dynamic>? _byId(String id) {
    for (final Map<String, dynamic> r in _records!) {
      if ('${r['id']}' == id) return r;
    }
    return null;
  }

  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> p,
  ) async {
    await _ensureInit();
    switch (action) {
      case 'list':
        return _list();
      case 'get':
        return _get(p);
      case 'add':
        return _add(p, update: false);
      case 'update':
        return _add(p, update: true);
      case 'delete':
        return _delete(p);
      case 'test':
        return _test(p);
      case 'tools':
        return _tools(p);
      case 'call':
        return _call(p);
      case 'toggle':
        return _toggle(p);
      case 'logs':
        return _logs(p);
      case 'presets':
        return _presets();
      default:
        return <String, dynamic>{'ok': false, 'error': '未知集成动作：$action'};
    }
  }

  // ---- 读取 ----

  Future<Map<String, dynamic>> _list() async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> r in _records!) {
      out.add(await _sanitize(r));
    }
    out.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        '${a['created_at']}'.compareTo('${b['created_at']}'));
    return <String, dynamic>{
      'ok': true,
      'integrations': out,
      'stdio_supported': false,
      'oauth_supported': false,
      'mcp_hardening': <String, dynamic>{
        'stdio_default': 'disabled',
        'request_timeout_s': McpHardening.requestTimeout.inSeconds,
        'max_tools': McpHardening.maxTools,
        'max_pages': McpHardening.maxPages,
        'backoff_initial_s': McpHardening.initialBackoff.inSeconds,
        'backoff_max_s': McpHardening.maxBackoff.inSeconds,
        'oauth_refresh_supported': refreshOAuthToken != null,
      },
      'note': '凭据保存在系统安全存储；列表与模型上下文都不会包含凭据。',
    };
  }

  Future<Map<String, dynamic>> _get(Map<String, dynamic> p) async {
    final Map<String, dynamic>? r = _byId((p['id'] ?? '').toString());
    if (r == null) {
      return <String, dynamic>{'ok': false, 'error': '集成不存在'};
    }
    return <String, dynamic>{'ok': true, 'integration': await _sanitize(r)};
  }

  /// 返回给调用方的集成记录：只含元数据（名、状态、工具数等），凭据只以
  /// has_secret 布尔值出现；最后再过一遍 redaction 自查，任何残留的
  /// 凭据键一律替换为 `[redacted]`，绝不返回明文。
  Future<Map<String, dynamic>> _sanitize(Map<String, dynamic> r) async {
    final Map<String, dynamic> copy = Map<String, dynamic>.from(r);
    final String? token = await _vault.read(_secretKey('${r['id']}'));
    copy['has_secret'] = token != null && token.isNotEmpty;
    copy['from_env_or_file'] = false;
    final Map<String, dynamic> scrubbed = McpHardening.scrubSecrets(copy);
    if (McpHardening.containsSecretValue(scrubbed)) {
      // 理论上到不了：防御性兜底，若仍有残留则只保留安全字段。
      scrubbed.removeWhere(
        (String k, dynamic v) => McpHardening.isSecretKey(k),
      );
    }
    return scrubbed;
  }

  // ---- 增删改 ----

  Future<Map<String, dynamic>> _add(
    Map<String, dynamic> p, {
    required bool update,
  }) async {
    final String name = (p['name'] ?? '').toString().trim();
    final String kind = (p['kind'] ?? '').toString().toLowerCase();
    final String url = (p['url'] ?? '').toString().trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '集成名称不能为空'};
    }
    if (!const <String>['mcp', 'openapi', 'graphql'].contains(kind)) {
      return <String, dynamic>{
        'ok': false,
        'error': '类型只能是 mcp / openapi / graphql',
      };
    }
    final Uri? parsed = Uri.tryParse(url);
    if (parsed == null || (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return <String, dynamic>{'ok': false, 'error': '地址必须是 http/https'};
    }
    final Map<String, dynamic> auth = <String, dynamic>{
      'type': (p['auth_type'] ?? 'none').toString(),
      'header_name': (p['header_name'] ?? 'X-API-Key').toString(),
      'query_name': (p['query_name'] ?? 'api_key').toString(),
    };
    if (!const <String>['none', 'bearer', 'header', 'query', 'oauth']
        .contains(auth['type'])) {
      return <String, dynamic>{'ok': false, 'error': '不支持的认证方式'};
    }

    // stdio MCP：默认关闭。开启需显式配置 + 命令白名单 + 管理员确认，
    // 校验在写任何凭据之前做，拒绝的添加不落盘、不记凭据。
    final String transport =
        (p['transport'] ?? 'http').toString().toLowerCase();
    String stdioCommand = '';
    List<String> stdioArgs = <String>[];
    if (kind == 'mcp' && transport == 'stdio') {
      stdioCommand = (p['stdio_command'] ?? '').toString();
      final dynamic rawArgs = p['stdio_args'];
      stdioArgs = rawArgs is List
          ? rawArgs.map((dynamic e) => '$e').toList()
          : <String>[];
      final StdioValidation v = McpStdioPolicy.validate(
        command: stdioCommand,
        args: stdioArgs,
        stdioEnabled: p['stdio_enabled'] == true,
        adminConfirmed: p['admin_confirmed'] == true,
      );
      if (!v.ok) {
        await _log('stdio', 'add_stdio_rejected', false, v.error);
        return <String, dynamic>{'ok': false, 'error': v.error};
      }
    }

    // OAuth 需带 refresh_token 才能走「快过期自动刷新」入口，否则直接拒绝，
    // 不留一个刷不了的 OAuth 集成。
    int? oauthExpiresAtMs;
    if (auth['type'] == 'oauth') {
      if ((p['refresh_token'] ?? '').toString().isEmpty) {
        return <String, dynamic>{
          'ok': false,
          'error': 'OAuth 集成需提供 refresh_token（用于快过期自动刷新）',
        };
      }
      final dynamic exp = p['expires_at_ms'] ?? p['expires_at'];
      if (exp is num) {
        oauthExpiresAtMs = exp.toInt();
      } else if (exp is String) {
        oauthExpiresAtMs =
            DateTime.tryParse(exp)?.millisecondsSinceEpoch;
      }
    }

    final String id = update
        ? (p['id'] ?? '').toString()
        : _newId();
    final Map<String, dynamic>? existing = update ? _byId(id) : null;
    if (update && existing == null) {
      return <String, dynamic>{'ok': false, 'error': '集成不存在'};
    }
    final String token = (p['token'] ?? '').toString();
    if (auth['type'] == 'oauth' && token.isNotEmpty) {
      // OAuth 令牌束整体进安全存储（Vault），集成记录里只留过期时刻元数据。
      final OAuthTokenBundle bundle = OAuthTokenBundle(
        accessToken: token,
        refreshToken: (p['refresh_token'] ?? '').toString(),
        expiresAt: oauthExpiresAtMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(oauthExpiresAtMs,
                isUtc: true),
      );
      await _vault.write(_secretKey(id), jsonEncode(bundle.toJson()));
    } else if (token.isNotEmpty) {
      await _vault.write(_secretKey(id), token);
    } else if (p['clear_token'] == true) {
      await _vault.delete(_secretKey(id));
    } else if (!update) {
      await _vault.delete(_secretKey(id));
    }

    // 更新时若地址变了，旧地址的失败退避不再适用，清掉再测新地址。
    if (update &&
        existing != null &&
        '${existing['url'] ?? ''}' != url) {
      _backoff.remove(id);
    }

    final Map<String, dynamic> record = <String, dynamic>{
      'id': id,
      'name': name,
      'kind': kind,
      'url': url,
      'auth': auth,
      'enabled': p['enabled'] is bool
          ? p['enabled'] as bool
          : (existing?['enabled'] is bool ? existing!['enabled'] as bool : true),
      'created_at':
          existing?['created_at'] ?? DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'last_test_at': existing?['last_test_at'] ?? '',
      'last_test_ok': existing?['last_test_ok'] ?? false,
      'last_error': existing?['last_error'] ?? '',
      'tools': existing?['tools'] ?? <dynamic>[],
      'operations': existing?['operations'] ?? <dynamic>[],
      'base_url': existing?['base_url'] ?? '',
      'spec_url': (p['spec_url'] ?? existing?['spec_url'] ?? '').toString(),
      'query': (p['query'] ?? existing?['query'] ?? '').toString(),
      // MCP 加固元数据（均非凭据，可返回）：
      'transport': kind == 'mcp' ? transport : '',
      'stdio_command': kind == 'mcp' ? stdioCommand : '',
      'stdio_args': kind == 'mcp' ? stdioArgs : <String>[],
      'needs_rebind': existing?['needs_rebind'] ?? false,
      'oauth_expires_at_ms':
          oauthExpiresAtMs ?? existing?['oauth_expires_at_ms'],
      'tools_truncated': existing?['tools_truncated'] ?? false,
      'truncation_reason': existing?['truncation_reason'] ?? '',
    };

    if (kind == 'mcp' && transport == 'stdio') {
      // 通过白名单校验的 stdio 配置只保存、不启动：移动端不 spawn 进程，
      // 且 stdio 默认关闭；enabled 强制 false，test/call 会如实报未启动。
      record['enabled'] = false;
    }

    if (update) {
      _records![_records!.indexWhere((Map<String, dynamic> r) => r['id'] == id)] =
          record;
    } else {
      _records!.add(record);
    }
    await _save();
    _closeClient(id);

    final Map<String, dynamic> refreshed = await _refresh(record);
    record['tools'] = refreshed['tools'];
    record['operations'] = refreshed['operations'];
    record['base_url'] = refreshed['base_url'];
    record['tools_truncated'] = refreshed['tools_truncated'] ?? false;
    record['truncation_reason'] = refreshed['truncation_reason'] ?? '';
    record['last_test_at'] = DateTime.now().toIso8601String();
    record['last_test_ok'] = refreshed['ok'] == true;
    record['last_error'] = refreshed['error'] ?? '';
    await _save();
    await _log(id, update ? 'update' : 'add', refreshed['ok'] == true,
        '${refreshed['error'] ?? ''} ${refreshed['note'] ?? ''}'.trim());
    return <String, dynamic>{
      'ok': true,
      'integration': await _sanitize(record),
      'tested': refreshed['ok'] == true,
      'error': refreshed['error'] ?? '',
      'note': refreshed['note'] ?? '',
    };
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final Map<String, dynamic>? record = _byId(id);
    if (record == null) {
      return <String, dynamic>{'ok': false, 'error': '集成不存在'};
    }
    _records!.remove(record);
    await _save();
    _closeClient(id);
    await _vault.delete(_secretKey(id));
    await _log(id, 'delete', true, '${record['name']}');
    return <String, dynamic>{'ok': true, 'deleted': id};
  }

  Future<Map<String, dynamic>> _toggle(Map<String, dynamic> p) async {
    final Map<String, dynamic>? record = _byId((p['id'] ?? '').toString());
    if (record == null) {
      return <String, dynamic>{'ok': false, 'error': '集成不存在'};
    }
    record['enabled'] = p['enabled'] is bool
        ? p['enabled'] as bool
        : !(record['enabled'] == true);
    record['updated_at'] = DateTime.now().toIso8601String();
    await _save();
    if (record['enabled'] != true) _closeClient('${record['id']}');
    return <String, dynamic>{
      'ok': true,
      'integration': await _sanitize(record),
    };
  }

  Future<Map<String, dynamic>> _test(Map<String, dynamic> p) async {
    final Map<String, dynamic>? record = _byId((p['id'] ?? '').toString());
    if (record == null) {
      return <String, dynamic>{'ok': false, 'error': '集成不存在'};
    }
    _closeClient('${record['id']}');
    final Map<String, dynamic> r = await _refresh(record);
    record['tools'] = r['tools'];
    record['operations'] = r['operations'];
    record['base_url'] = r['base_url'];
    record['tools_truncated'] = r['tools_truncated'] ?? false;
    record['truncation_reason'] = r['truncation_reason'] ?? '';
    record['last_test_at'] = DateTime.now().toIso8601String();
    record['last_test_ok'] = r['ok'] == true;
    record['last_error'] = r['error'] ?? '';
    await _save();
    await _log('${record['id']}', 'test', r['ok'] == true,
        '${r['error'] ?? ''} ${r['note'] ?? ''}'.trim());
    return <String, dynamic>{
      'ok': r['ok'] == true,
      'tools': r['tools'],
      'note': r['note'] ?? '',
      'error': r['error'] ?? '',
    };
  }

  Future<Map<String, dynamic>> _tools(Map<String, dynamic> p) async {
    final Map<String, dynamic>? record = _byId((p['id'] ?? '').toString());
    if (record == null) {
      return <String, dynamic>{'ok': false, 'error': '集成不存在'};
    }
    if (p['refresh'] == true || (record['tools'] as List?)?.isEmpty != false) {
      final Map<String, dynamic> r = await _refresh(record);
      if (r['ok'] != true) {
        return <String, dynamic>{'ok': false, 'error': r['error']};
      }
      record['tools'] = r['tools'];
      record['operations'] = r['operations'];
      record['base_url'] = r['base_url'];
      record['tools_truncated'] = r['tools_truncated'] ?? false;
      record['truncation_reason'] = r['truncation_reason'] ?? '';
      await _save();
    }
    return <String, dynamic>{
      'ok': true,
      'tools': record['tools'] ?? <dynamic>[],
      'operations': record['operations'] ?? <dynamic>[],
    };
  }

  // ---- 调用 ----

  Future<Map<String, dynamic>> _call(Map<String, dynamic> p) async {
    final Map<String, dynamic>? record = _byId((p['id'] ?? '').toString());
    if (record == null) {
      return <String, dynamic>{'ok': false, 'error': '集成不存在'};
    }
    if ('${record['transport'] ?? ''}' == 'stdio') {
      return <String, dynamic>{'ok': false, 'error': 'stdio MCP 默认关闭，未启动'};
    }
    if (record['enabled'] != true) {
      return <String, dynamic>{'ok': false, 'error': '该集成已停用'};
    }
    final String tool = (p['tool'] ?? '').toString();
    if (tool.isEmpty && record['kind'] != 'graphql') {
      return <String, dynamic>{'ok': false, 'error': '缺少 tool 名称'};
    }
    final Map<String, dynamic> args = p['arguments'] is Map
        ? Map<String, dynamic>.from(p['arguments'] as Map)
        : <String, dynamic>{};
    final Map<String, dynamic> result;
    switch ('${record['kind']}') {
      case 'mcp':
        result = await _callMcp(record, tool, args);
        break;
      case 'openapi':
        result = await _callOpenApi(record, tool, args);
        break;
      case 'graphql':
        result = await _callGraphQL(record, tool, args);
        break;
      default:
        result = <String, dynamic>{'ok': false, 'error': '未知集成类型'};
    }
    await _log('${record['id']}', 'call:$tool', result['ok'] == true,
        '${result['error'] ?? ''}'.trim());
    return result;
  }

  Future<Map<String, dynamic>> _callMcp(
    Map<String, dynamic> record,
    String tool,
    Map<String, dynamic> args,
  ) async {
    if ('${record['transport'] ?? ''}' == 'stdio') {
      return <String, dynamic>{
        'ok': false,
        'error': 'stdio MCP 默认关闭，未启动',
      };
    }
    try {
      final McpClient? client = await _clientFor(record);
      if (client == null) {
        return <String, dynamic>{'ok': false, 'error': 'MCP 客户端未建立'};
      }
      final McpCallResult r = await client.callTool(tool, args);
      return <String, dynamic>{
        'ok': r.ok,
        'text': r.text,
        'error': r.error,
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> _callOpenApi(
    Map<String, dynamic> record,
    String tool,
    Map<String, dynamic> args,
  ) async {
    final List<dynamic> operations =
        (record['operations'] as List?) ?? const <dynamic>[];
    Map<dynamic, dynamic>? op;
    for (final dynamic raw in operations) {
      if (raw is Map && '${raw['name']}' == tool) {
        op = raw;
        break;
      }
    }
    if (op == null) {
      return <String, dynamic>{'ok': false, 'error': '操作不存在：$tool'};
    }
    final String base = '${record['base_url'] ?? ''}';
    if (base.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': 'OpenAPI 缺少 base URL'};
    }
    String path = '${op['path'] ?? '/'}';
    final Map<String, dynamic> query = <String, dynamic>{};
    final Map<String, String> headers = await _authHeaders(record);
    final Map<String, dynamic> leftovers = Map<String, dynamic>.from(args);
    final List<dynamic> params =
        (op['params'] as List?) ?? const <dynamic>[];
    for (final dynamic raw in params) {
      if (raw is! Map) continue;
      final String name = '${raw['name']}';
      final String where = '${raw['in']}';
      // body 参数保留在 leftovers 里，由下面的请求体逻辑统一处理。
      if (where == 'body') continue;
      if (!leftovers.containsKey(name)) {
        if (raw['required'] == true && where == 'path') {
          return <String, dynamic>{'ok': false, 'error': '缺少路径参数 $name'};
        }
        continue;
      }
      final dynamic value = leftovers.remove(name);
      if (where == 'path') {
        path = path.replaceAll('{$name}', Uri.encodeComponent('$value'));
      } else if (where == 'query') {
        query[name] = value;
      } else if (where == 'header') {
        headers[name] = '$value';
      }
    }
    final Uri? baseUri = Uri.tryParse(base);
    if (baseUri == null) {
      return <String, dynamic>{'ok': false, 'error': 'base URL 无效'};
    }
    Uri uri = _joinBase(baseUri, path);
    if (query.isNotEmpty) {
      uri = uri.replace(queryParameters: <String, String>{
        ...uri.queryParameters,
        ...query.map((String k, dynamic v) => MapEntry(k, '$v')),
      });
    }
    final String method = '${op['method'] ?? 'GET'}'.toUpperCase();
    Object? body;
    if (method != 'GET' && method != 'DELETE') {
      body = leftovers['body'] is Map
          ? leftovers.remove('body')
          : (leftovers.isEmpty ? null : leftovers);
      if (body != null) {
        headers['content-type'] = 'application/json';
      }
    }
    try {
      final http.Request request = http.Request(method, uri);
      request.headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final http.StreamedResponse streamed =
          await _client.send(request).timeout(timeout);
      final http.Response res = await http.Response.fromStream(streamed);
      final String text = _clip(utf8.decode(res.bodyBytes, allowMalformed: true));
      return <String, dynamic>{
        'ok': res.statusCode >= 200 && res.statusCode < 300,
        'status': res.statusCode,
        'text': text,
        if (res.statusCode >= 400) 'error': 'HTTP ${res.statusCode}',
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }

  Future<Map<String, dynamic>> _callGraphQL(
    Map<String, dynamic> record,
    String tool,
    Map<String, dynamic> args,
  ) async {
    String query = (args['query'] ?? record['query'] ?? '').toString();
    dynamic variables = args['variables'] ?? record['variables'] ?? <String, dynamic>{};
    if (query.trim().isEmpty && tool.isNotEmpty) {
      final String literal = args.entries
          .where((MapEntry<String, dynamic> e) => e.key != 'variables')
          .map((MapEntry<String, dynamic> e) =>
              '${e.key}: ${jsonEncode(e.value)}')
          .join(', ');
      final bool mutation = '${record['mutation_tool']}' == tool;
      query = '${mutation ? 'mutation' : 'query'} { $tool'
          '${literal.isEmpty ? '' : '($literal)'} }';
    }
    if (query.trim().isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '缺少 GraphQL query'};
    }
    if (variables is String) {
      try {
        variables = jsonDecode(variables);
      } on Object {
        return <String, dynamic>{'ok': false, 'error': 'variables 不是合法 JSON'};
      }
    }
    try {
      final Map<String, String> headers = await _authHeaders(record);
      final http.Request request =
          http.Request('POST', Uri.parse('${record['url']}'));
      request.headers.addAll(<String, String>{
        ...headers,
        'content-type': 'application/json',
      });
      request.body = jsonEncode(<String, dynamic>{
        'query': query,
        'variables': variables is Map ? variables : <String, dynamic>{},
      });
      final http.StreamedResponse streamed =
          await _client.send(request).timeout(timeout);
      final http.Response res = await http.Response.fromStream(streamed);
      final String text = _clip(utf8.decode(res.bodyBytes, allowMalformed: true));
      return <String, dynamic>{
        'ok': res.statusCode >= 200 && res.statusCode < 300,
        'status': res.statusCode,
        'text': text,
        if (res.statusCode >= 400) 'error': 'HTTP ${res.statusCode}',
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }

  // ---- 连接 / 刷新工具 ----

  Future<Map<String, dynamic>> _refresh(Map<String, dynamic> record) async {
    final String id = '${record['id']}';
    final bool isRemoteMcp = '${record['kind']}' == 'mcp' &&
        '${record['transport'] ?? ''}' != 'stdio';
    // 远程 MCP 处于失败退避窗口内：不再发真实请求，直接报退避。
    if (isRemoteMcp && _inBackoff(id)) {
      return <String, dynamic>{
        'ok': false,
        'error': '该 MCP 服务处于失败退避中，'
            '${_backoffRemaining(id).inSeconds} 秒后重试',
        'tools': const <dynamic>[],
        'operations': const <dynamic>[],
        'base_url': '',
      };
    }
    late final Map<String, dynamic> result;
    try {
      switch ('${record['kind']}') {
        case 'mcp':
          result = await _refreshMcp(record);
          break;
        case 'openapi':
          result = await _refreshOpenApi(record);
          break;
        case 'graphql':
          result = await _refreshGraphQL(record);
          break;
        default:
          result = <String, dynamic>{'ok': false, 'error': '未知集成类型'};
      }
    } on TimeoutException {
      result = <String, dynamic>{
        'ok': false,
        'error': '连接超时（${timeout.inSeconds} 秒）',
      };
    } on Object catch (e) {
      result = <String, dynamic>{'ok': false, 'error': '$e'};
    }
    // 远程 MCP 的成败计入退避：成功清零，失败按 30 秒起翻倍、5 分钟封顶。
    // stdio「未启动」不是远端失败，不计入退避。
    if (isRemoteMcp) {
      if (result['ok'] == true) {
        _recordServerSuccess(id);
      } else {
        _recordServerFailure(id);
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> _refreshMcp(Map<String, dynamic> record) async {
    // stdio MCP 默认关闭：配置只保存，服务本身不启动，调用如实报错。
    if ('${record['transport'] ?? ''}' == 'stdio') {
      return <String, dynamic>{
        'ok': false,
        'error': 'stdio MCP 默认关闭，未启动（移动端不 spawn 进程；配置已保存，仅管理员可改）',
        'tools': const <dynamic>[],
        'operations': const <dynamic>[],
        'base_url': '',
        'note': '',
      };
    }
    final Map<String, String> headers = await _authHeaders(record);
    final McpClient client =
        McpClient('${record['url']}', headers: headers, client: _client);
    try {
      final String title = await client.initialize().timeout(timeout);
      final McpToolPage page = await client.listToolsPaged().timeout(timeout);
      _closeClient('${record['id']}');
      _mcp['${record['id']}'] = client;
      final List<Map<String, dynamic>> tools = page.tools
          .map((McpToolInfo t) => <String, dynamic>{
                'name': t.name,
                'description': t.description,
                'input_schema': t.inputSchema,
              })
          .toList();
      return <String, dynamic>{
        'ok': true,
        'tools': tools,
        'operations': const <dynamic>[],
        'base_url': '',
        'tools_truncated': page.truncated,
        'truncation_reason': page.reason,
        'note': title.isEmpty
            ? (page.truncated ? page.reason : '')
            : '已连接 $title${page.truncated ? '；${page.reason}' : ''}',
      };
    } on Object {
      client.dispose();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _refreshOpenApi(
    Map<String, dynamic> record,
  ) async {
    final String specUrl =
        '${record['spec_url'] ?? ''}'.isNotEmpty ? '${record['spec_url']}' : '${record['url']}';
    final Uri uri = Uri.parse(specUrl);
    final Map<String, dynamic> spec =
        await _getJson(record, uri, await _authHeaders(record));
    final String base = _openApiBase(spec, uri);
    final List<Map<String, dynamic>> operations = _parseOperations(spec);
    return <String, dynamic>{
      'ok': true,
      'tools': operations
          .map((Map<String, dynamic> op) => <String, dynamic>{
                'name': op['name'],
                'description': op['description'],
              })
          .toList(),
      'operations': operations,
      'base_url': base,
      'note': '解析到 ${operations.length} 个操作',
    };
  }

  Future<Map<String, dynamic>> _refreshGraphQL(
    Map<String, dynamic> record,
  ) async {
    const String introspection = '''
query IntrospectionQuery {
  __schema {
    queryType { fields { name description args { name type { kind name ofType { kind name } } } } }
    mutationType { fields { name description args { name type { kind name ofType { kind name } } } } }
  }
}''';
    final Map<String, String> headers = await _authHeaders(record);
    final Map<String, dynamic> resp = await _postJson(
      Uri.parse('${record['url']}'),
      <String, dynamic>{'query': introspection},
      headers,
    );
    final dynamic data = resp['data'];
    final dynamic schema = data is Map ? data['__schema'] : null;
    if (schema is! Map) {
      final dynamic errors = resp['errors'];
      return <String, dynamic>{
        'ok': false,
        'error': 'GraphQL introspection 失败：'
            '${errors is List && errors.isNotEmpty ? errors.first : '服务端未返回 __schema'}',
        'tools': const <dynamic>[],
        'operations': const <dynamic>[],
        'base_url': '',
        'note': '仍可在调用时直接填写 query 与 variables。',
      };
    }
    final List<Map<String, dynamic>> tools = <Map<String, dynamic>>[];
    String mutationTool = '';
    void collect(dynamic type, String kind) {
      if (type is! Map) return;
      final dynamic fields = type['fields'];
      if (fields is! List) return;
      for (final dynamic raw in fields) {
        if (raw is! Map) continue;
        tools.add(<String, dynamic>{
          'name': '${raw['name']}',
          'description': '${raw['description'] ?? ''}',
          'kind': kind,
          'args': raw['args'] ?? <dynamic>[],
        });
        if (kind == 'mutation' && mutationTool.isEmpty) {
          mutationTool = '${raw['name']}';
        }
      }
    }

    collect(schema['queryType'], 'query');
    collect(schema['mutationType'], 'mutation');
    record['mutation_tool'] = mutationTool;
    return <String, dynamic>{
      'ok': true,
      'tools': tools,
      'operations': const <dynamic>[],
      'base_url': '',
      'note': 'introspection 发现 ${tools.length} 个字段',
    };
  }

  Future<McpClient?> _clientFor(Map<String, dynamic> record) async {
    final String id = '${record['id']}';
    McpClient? client = _mcp[id];
    if (client != null) return client;
    final Map<String, dynamic> refreshed = await _refresh(record);
    if (refreshed['ok'] != true) return null;
    client = _mcp[id];
    return client;
  }

  void _closeClient(String id) {
    _mcp.remove(id)?.dispose();
  }

  // ---- HTTP / 认证 ----

  Future<Map<String, String>> _authHeaders(Map<String, dynamic> record) async {
    final Map<String, String> headers = <String, String>{
      'accept': 'application/json, text/plain, */*',
      'user-agent': 'TangramIntegrations/1.0',
    };
    final Map<dynamic, dynamic> auth = record['auth'] is Map
        ? record['auth'] as Map
        : <dynamic, dynamic>{};
    final String type = '${auth['type'] ?? 'none'}';
    if (type == 'none') return headers;
    if (type == 'oauth') {
      final OAuthTokenBundle bundle = await _oauthBundle(record);
      headers['authorization'] = 'Bearer ${bundle.accessToken}';
      return headers;
    }
    final String? token = await _vault.read(_secretKey('${record['id']}'));
    if (token == null || token.isEmpty) {
      throw StateError('该集成缺少凭据，请重新填写');
    }
    if (type == 'bearer') {
      headers['authorization'] = 'Bearer $token';
    } else if (type == 'header') {
      headers['${auth['header_name'] ?? 'X-API-Key'}'] = token;
    }
    return headers;
  }

  /// 读取 OAuth 令牌束：快过期（过期前 60 秒内）时走刷新回调；刷新失败或
  /// 无刷新入口时标记 needs_rebind 并抛错，绝不静默用过期令牌。
  Future<OAuthTokenBundle> _oauthBundle(Map<String, dynamic> record) async {
    final String id = '${record['id']}';
    final String? raw = await _vault.read(_secretKey(id));
    if (raw == null || raw.isEmpty) {
      throw StateError('该集成缺少 OAuth 令牌，请重新绑定');
    }
    final OAuthTokenBundle bundle;
    if (raw.trim().startsWith('{')) {
      try {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is! Map) throw const FormatException('not an object');
        bundle = OAuthTokenBundle.fromJson(
          decoded.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
        );
      } on Object {
        throw StateError('OAuth 令牌损坏，请重新绑定');
      }
    } else {
      bundle = OAuthTokenBundle.fromVaultString(raw);
    }
    if (bundle.accessToken.isEmpty) {
      throw StateError('该集成缺少 OAuth 令牌，请重新绑定');
    }
    if (!bundle.needsRefresh()) return bundle;
    if (refreshOAuthToken == null || bundle.refreshToken.isEmpty) {
      await _markNeedsRebind(record);
      throw StateError('OAuth 令牌快过期且无法自动刷新，需重新绑定');
    }
    OAuthTokenBundle? fresh;
    try {
      fresh = await refreshOAuthToken!(bundle.refreshToken);
    } on Object {
      fresh = null;
    }
    if (fresh == null || fresh.accessToken.isEmpty) {
      await _markNeedsRebind(record);
      throw StateError('OAuth 令牌刷新失败，需重新绑定');
    }
    await _vault.write(_secretKey(id), jsonEncode(fresh.toJson()));
    record['oauth_expires_at_ms'] = fresh.expiresAt?.millisecondsSinceEpoch;
    record['needs_rebind'] = false;
    await _save();
    return fresh;
  }

  Future<void> _markNeedsRebind(Map<String, dynamic> record) async {
    record['needs_rebind'] = true;
    try {
      await _save();
    } on Object {
      // 标记失败不影响报错本身。
    }
  }

  Future<Uri> _authUri(Map<String, dynamic> record, Uri uri) async {
    final Map<dynamic, dynamic> auth = record['auth'] is Map
        ? record['auth'] as Map
        : <dynamic, dynamic>{};
    if ('${auth['type'] ?? ''}' != 'query') return uri;
    final String? token = await _vault.read(_secretKey('${record['id']}'));
    if (token == null || token.isEmpty) {
      throw StateError('该集成缺少凭据，请重新填写');
    }
    return uri.replace(queryParameters: <String, String>{
      ...uri.queryParameters,
      '${auth['query_name'] ?? 'api_key'}': token,
    });
  }

  Future<Map<String, dynamic>> _getJson(
    Map<String, dynamic> record,
    Uri uri,
    Map<String, String> headers,
  ) async {
    final Uri finalUri = await _authUri(record, uri);
    final http.Request request = http.Request('GET', finalUri);
    request.headers.addAll(headers);
    final http.StreamedResponse streamed =
        await _client.send(request).timeout(timeout);
    final http.Response res = await http.Response.fromStream(streamed);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('HTTP ${res.statusCode}');
    }
    if (res.bodyBytes.length > maxSpecBytes) {
      throw StateError('spec 超过 ${maxSpecBytes ~/ (1024 * 1024)}MB');
    }
    final dynamic decoded =
        jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (decoded is! Map) throw StateError('spec 不是 JSON 对象');
    return Map<String, dynamic>.from(decoded);
  }

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    Map<String, dynamic> body,
    Map<String, String> headers,
  ) async {
    final http.Request request = http.Request('POST', uri);
    request.headers.addAll(<String, String>{
      ...headers,
      'content-type': 'application/json',
    });
    request.body = jsonEncode(body);
    final http.StreamedResponse streamed =
        await _client.send(request).timeout(timeout);
    final http.Response res = await http.Response.fromStream(streamed);
    final dynamic decoded =
        jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    return <String, dynamic>{'error': 'HTTP ${res.statusCode}'};
  }

  String _openApiBase(Map<String, dynamic> spec, Uri specUri) {
    final dynamic servers = spec['servers'];
    if (servers is List && servers.isNotEmpty && servers.first is Map) {
      final String url = '${(servers.first as Map)['url'] ?? ''}';
      if (url.isNotEmpty) {
        final Uri? u = Uri.tryParse(url);
        if (u != null && u.hasScheme) return u.toString();
        return specUri.resolve(url).toString();
      }
    }
    final dynamic host = spec['host'];
    if (host != null) {
      final dynamic schemes = spec['schemes'];
      final String scheme = schemes is List && schemes.isNotEmpty
          ? '${schemes.first}'
          : 'https';
      final String basePath = '${spec['basePath'] ?? ''}';
      return '$scheme://$host$basePath';
    }
    final Uri base = specUri.replace(path: '', query: '', fragment: '');
    return base.toString();
  }

  /// OpenAPI 的 server URL 通常自带 basePath，而 paths 以 `/` 开头；
  /// 直接 `resolve` 会丢掉 basePath，这里显式拼接。
  Uri _joinBase(Uri base, String path) {
    final String basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final String rel = path.startsWith('/') ? path.substring(1) : path;
    return base.replace(path: '$basePath/$rel');
  }

  List<Map<String, dynamic>> _parseOperations(Map<String, dynamic> spec) {
    final dynamic paths = spec['paths'];
    if (paths is! Map) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final Set<String> used = <String>{};
    paths.forEach((dynamic rawPath, dynamic item) {
      if (item is! Map) return;
      final String path = '$rawPath';
      for (final String method
          in <String>['get', 'post', 'put', 'patch', 'delete']) {
        final dynamic opRaw = item[method];
        if (opRaw is! Map) continue;
        final Map<dynamic, dynamic> op = opRaw;
        String name = '${op['operationId'] ?? ''}'.trim();
        if (name.isEmpty) {
          name = '${method}_${path.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}';
        }
        name = name.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
        String unique = name;
        int i = 2;
        while (used.contains(unique)) {
          unique = '${name}_$i';
          i++;
        }
        used.add(unique);
        final List<Map<String, dynamic>> params = <Map<String, dynamic>>[];
        final List<dynamic> rawParams = <dynamic>[
          ...(item['parameters'] is List ? item['parameters'] as List : <dynamic>[]),
          ...(op['parameters'] is List ? op['parameters'] as List : <dynamic>[]),
        ];
        for (final dynamic pr in rawParams) {
          if (pr is! Map) continue;
          final String where = '${pr['in'] ?? 'query'}';
          if (!const <String>['path', 'query', 'header'].contains(where)) {
            continue;
          }
          final dynamic schema = pr['schema'];
          params.add(<String, dynamic>{
            'name': '${pr['name'] ?? ''}',
            'in': where,
            'required': pr['required'] == true,
            'type': schema is Map ? '${schema['type'] ?? 'string'}' : 'string',
          });
        }
        final dynamic requestBody = op['requestBody'];
        if (requestBody is Map) {
          params.add(<String, dynamic>{
            'name': 'body',
            'in': 'body',
            'required': requestBody['required'] == true,
            'type': 'object',
          });
        }
        out.add(<String, dynamic>{
          'name': unique,
          'method': method.toUpperCase(),
          'path': path,
          'description': '${op['summary'] ?? op['description'] ?? '$method $path'}',
          'params': params,
        });
      }
    });
    return out;
  }

  // ---- 日志 / 预置 ----

  Future<void> _log(String id, String action, bool ok, String detail) async {
    try {
      final String safe = detail.length > 300 ? '${detail.substring(0, 300)}…' : detail;
      await _logFile.writeAsString(
        '${jsonEncode(<String, dynamic>{
              'id': id,
              'action': action,
              'ok': ok,
              'detail': safe,
              'ts': DateTime.now().toIso8601String(),
            })}\n',
        mode: FileMode.append,
        flush: true,
      );
      if (await _logFile.length() > 1024 * 1024) {
        final List<String> lines = await _logFile.readAsLines();
        await _logFile.writeAsString(
          '${lines.sublist(lines.length > 1000 ? lines.length - 1000 : 0).join('\n')}\n',
          flush: true,
        );
      }
    } on Object {
      // 日志失败不影响调用。
    }
  }

  Future<Map<String, dynamic>> _logs(Map<String, dynamic> p) async {
    if (!await _logFile.exists()) {
      return <String, dynamic>{'ok': true, 'logs': <dynamic>[]};
    }
    final String id = (p['id'] ?? '').toString();
    final int limit = (p['limit'] is num)
        ? (p['limit'] as num).toInt().clamp(1, 200)
        : 80;
    final List<String> lines = await _logFile.readAsLines();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final String line in lines.reversed) {
      if (line.trim().isEmpty) continue;
      try {
        final dynamic d = jsonDecode(line);
        if (d is! Map) continue;
        if (id.isNotEmpty && '${d['id']}' != id) continue;
        out.add(Map<String, dynamic>.from(d));
        if (out.length >= limit) break;
      } on Object {
        // 跳过损坏行。
      }
    }
    return <String, dynamic>{'ok': true, 'logs': out};
  }

  /// 内置模板只提供真实可用的地址格式与认证字段，不宣称已连通。
  Map<String, dynamic> _presets() => <String, dynamic>{
        'ok': true,
        'presets': <Map<String, dynamic>>[
          <String, dynamic>{
            'kind': 'mcp',
            'name': '自定义 MCP 服务',
            'url_hint': 'https://example.com/mcp',
            'auth_types': <String>['none', 'bearer', 'header', 'query', 'oauth'],
          },
          <String, dynamic>{
            'kind': 'openapi',
            'name': '自定义 OpenAPI',
            'url_hint': 'https://example.com/openapi.json',
            'auth_types': <String>['none', 'bearer', 'header', 'query'],
          },
          <String, dynamic>{
            'kind': 'graphql',
            'name': '自定义 GraphQL',
            'url_hint': 'https://example.com/graphql',
            'auth_types': <String>['none', 'bearer', 'header'],
          },
        ],
        'note': '本机不内置第三方 OAuth 应用目录；请填写可用的 HTTP 地址。'
            'stdio MCP 默认关闭，仅管理员可按白名单配置。',
      };

  static String _clip(String text) =>
      text.length <= 4000 ? text : '${text.substring(0, 4000)}…';

  void dispose() {
    for (final McpClient c in _mcp.values) {
      c.dispose();
    }
    _mcp.clear();
    if (_ownsClient) _client.close();
  }
}
