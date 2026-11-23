/// Team Computer 的浏览器会话：真实 HTTP 请求 + Cookie + 历史 + 快照。
///
/// 每个智能体拥有独立 profile 目录（`cookies.json` / `history.json`），
/// 登录态与浏览历史互不干扰、重启后恢复。页面操作基于 [HtmlSnapshot]：
///   * `navigate` 发起真实 GET/POST，跟随重定向并保存 Set-Cookie；
///   * `act` 支持 click / fill / submit / back / forward / reload；
///   * 每次操作返回最新文字快照，Agent 工具与页面共用同一份结果。
///
/// 真实性边界（必须在 UI 与能力声明中如实标注）：
///   * 不执行 JavaScript，脚本动态渲染的内容不会出现；
///   * 不做验证码识别、不自动登录、不绕过站点风控；
///   * 仅允许 http/https，单页上限 4MB，超时 25 秒。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart' show IOClient;

import 'html_snapshot.dart';

class BrowserSession {
  BrowserSession({
    required this.profileDir,
    http.Client? client,
    this.timeout = const Duration(seconds: 25),
  })  : _client = client ?? _directClient(),
        _ownsClient = client == null;

  /// 真实直连客户端。
  ///
  /// 不沿用系统/环境里的 HTTP 代理：部分 Android 设备的代理配置会把
  /// `https://baidu.com` 解析成 `baidu.com:<代理端口>`，导致
  /// `Connection refused`（真实用户反馈）。Team Computer 的浏览器只做
  /// 普通出站访问，显式 DIRECT 才能稳定工作。
  static http.Client _directClient() {
    final HttpClient inner = HttpClient()
      ..findProxy = ((Uri _) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 15);
    return IOClient(inner);
  }

  final Directory profileDir;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  static const int maxBodyBytes = 4 * 1024 * 1024;
  static const int maxHistory = 200;

  /// host -> cookie 名 -> {value, secure}
  final Map<String, Map<String, Map<String, String>>> _cookies =
      <String, Map<String, Map<String, String>>>{};
  final List<Map<String, dynamic>> _history = <Map<String, dynamic>>[];
  final Map<String, String> _formValues = <String, String>{};

  int _cursor = -1;
  String? _currentUrl;
  int _status = 0;
  HtmlSnapshot? _snapshot;
  bool _loaded = false;

  String? get currentUrl => _currentUrl;
  int get status => _status;
  HtmlSnapshot? get snapshot => _snapshot;
  bool get canBack => _cursor > 0;
  bool get canForward => _cursor >= 0 && _cursor < _history.length - 1;

  List<Map<String, dynamic>> get history =>
      List<Map<String, dynamic>>.unmodifiable(_history);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!await profileDir.exists()) {
      await profileDir.create(recursive: true);
    }
    final File cookies = File('${profileDir.path}/cookies.json');
    if (await cookies.exists()) {
      try {
        final dynamic decoded = jsonDecode(await cookies.readAsString());
        if (decoded is Map) {
          decoded.forEach((dynamic host, dynamic jar) {
            if (jar is! Map) return;
            final Map<String, Map<String, String>> entry =
                <String, Map<String, String>>{};
            jar.forEach((dynamic name, dynamic raw) {
              if (raw is Map) {
                entry['$name'] = <String, String>{
                  'value': '${raw['value'] ?? ''}',
                  'secure': '${raw['secure']}' == 'true' ? 'true' : 'false',
                };
              }
            });
            _cookies['$host'] = entry;
          });
        }
      } on Object {
        // 损坏的 cookie 文件按空处理，不冒充已有登录态。
      }
    }
    final File hist = File('${profileDir.path}/history.json');
    if (await hist.exists()) {
      try {
        final dynamic decoded = jsonDecode(await hist.readAsString());
        if (decoded is List) {
          for (final dynamic raw in decoded) {
            if (raw is Map && raw['url'] != null) {
              _history.add(<String, dynamic>{
                'url': '${raw['url']}',
                'title': '${raw['title'] ?? ''}',
                'ts': '${raw['ts'] ?? ''}',
              });
            }
          }
        }
      } on Object {
        // 同上：历史损坏不阻塞浏览器启动。
      }
      if (_history.isNotEmpty) {
        _cursor = _history.length - 1;
        _currentUrl = '${_history.last['url']}';
      }
    }
  }

  /// 打开地址并返回文字快照；支持省略协议（默认 https）。
  Future<Map<String, dynamic>> navigate(String rawUrl) {
    final Uri? uri = _normalize(rawUrl);
    if (uri == null) {
      return Future<Map<String, dynamic>>.value(<String, dynamic>{
        'ok': false,
        'error': '只支持 http/https 地址：$rawUrl',
      });
    }
    return _navigateUri(uri);
  }

  Future<Map<String, dynamic>> reload() {
    final String? url = _currentUrl;
    if (url == null) {
      return Future<Map<String, dynamic>>.value(
        <String, dynamic>{'ok': false, 'error': '还没有打开的页面'},
      );
    }
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) {
      return Future<Map<String, dynamic>>.value(
        <String, dynamic>{'ok': false, 'error': '当前地址无效'},
      );
    }
    return _navigateUri(uri, recordHistory: false);
  }

  Future<Map<String, dynamic>> back() => _go(-1);

  Future<Map<String, dynamic>> forward() => _go(1);

  Future<Map<String, dynamic>> _go(int delta) async {
    await load();
    final int target = _cursor + delta;
    if (target < 0 || target >= _history.length) {
      return <String, dynamic>{
        'ok': false,
        'error': delta < 0 ? '没有上一页' : '没有下一页',
      };
    }
    _cursor = target;
    final Uri? uri = Uri.tryParse('${_history[target]['url']}');
    if (uri == null) {
      return <String, dynamic>{'ok': false, 'error': '历史地址无效'};
    }
    return _navigateUri(uri, recordHistory: false);
  }

  /// 页面动作。ref 来自当前快照；[values] 可一次填多个字段。
  Future<Map<String, dynamic>> act({
    required String action,
    String ref = '',
    String value = '',
    Map<String, String> values = const <String, String>{},
  }) async {
    await load();
    if (action == 'back') return back();
    if (action == 'forward') return forward();
    if (action == 'reload') return reload();

    final HtmlSnapshot? snap = _snapshot;
    if (snap == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '还没有打开页面，请先 navigate',
      };
    }
    _formValues.addAll(values);

    switch (action) {
      case 'click':
        final HtmlLink? link = snap.link(ref);
        if (link != null) return navigate(link.href);
        final HtmlField? submit = snap.field(ref);
        if (submit != null && submit.isSubmit) {
          return _submit(submit.formRef, submit);
        }
        return <String, dynamic>{
          'ok': false,
          'error': '当前页面没有链接或提交按钮 $ref，请重新获取快照',
        };
      case 'fill':
        final HtmlField? field = snap.field(ref);
        if (field == null || field.hidden) {
          return <String, dynamic>{
            'ok': false,
            'error': '当前页面没有可填写字段 $ref',
          };
        }
        _formValues[ref] = value;
        return <String, dynamic>{
          'ok': true,
          'filled': <String, String>{ref: field.isPassword ? '******' : value},
          'display': snap.render(filled: _formValues),
        };
      case 'submit':
      case 'enter':
        String formRef = ref;
        final HtmlForm? direct = snap.form(ref);
        if (direct != null) {
          formRef = direct.ref;
        } else {
          final HtmlField? field = snap.field(ref);
          if (field != null) formRef = field.formRef;
        }
        if (snap.form(formRef) == null) {
          return <String, dynamic>{
            'ok': false,
            'error': '当前页面没有表单 $ref',
          };
        }
        return _submit(formRef, null);
      default:
        return <String, dynamic>{
          'ok': false,
          'error': '未知动作：$action（支持 click/fill/submit/back/forward/reload）',
        };
    }
  }

  Future<Map<String, dynamic>> _submit(
    String formRef,
    HtmlField? submitter,
  ) async {
    final HtmlForm? form = _snapshot?.form(formRef);
    if (form == null) {
      return <String, dynamic>{'ok': false, 'error': '表单不存在：$formRef'};
    }
    final Uri base = Uri.tryParse(_currentUrl ?? '') ?? Uri();
    Uri target = base;
    if (form.action.isNotEmpty) {
      final Uri? parsed = Uri.tryParse(form.action);
      if (parsed == null) {
        return <String, dynamic>{'ok': false, 'error': '表单地址无效'};
      }
      target = base.hasScheme ? base.resolveUri(parsed) : parsed;
    }
    if (target.scheme != 'http' && target.scheme != 'https') {
      return <String, dynamic>{'ok': false, 'error': '表单只支持 http/https'};
    }

    final Map<String, String> fields = <String, String>{};
    for (final HtmlField f in form.fields) {
      if (f.isSubmit) continue;
      if (f.name.isEmpty) continue;
      fields[f.name] = _formValues[f.ref] ?? f.value;
    }
    if (submitter != null && submitter.name.isNotEmpty) {
      fields[submitter.name] = _formValues[submitter.ref] ?? submitter.value;
    }

    final Map<String, String> submitted = Map<String, String>.of(fields);
    _formValues.clear();
    if (form.method == 'POST') {
      return _navigateUri(
        target,
        method: 'POST',
        body: submitted,
      );
    }
    final Map<String, String> query = <String, String>{
      ...target.queryParameters,
      ...submitted,
    };
    return _navigateUri(target.replace(queryParameters: query));
  }

  Future<Map<String, dynamic>> _navigateUri(
    Uri uri, {
    bool recordHistory = true,
    String method = 'GET',
    Map<String, String>? body,
  }) async {
    await load();
    final _Fetched fetched;
    try {
      fetched = await _fetch(uri, method: method, body: body);
    } on TimeoutException {
      return <String, dynamic>{
        'ok': false,
        'error': '打开超时（${timeout.inSeconds} 秒）：$uri',
        'url': '$uri',
      };
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'error': '打开失败：$e',
        'url': '$uri',
      };
    }

    _currentUrl = fetched.url;
    _status = fetched.status;
    _formValues.clear();
    _snapshot = _parse(fetched);
    if (recordHistory) {
      while (_history.length > _cursor + 1) {
        _history.removeLast();
      }
      _history.add(<String, dynamic>{
        'url': fetched.url,
        'title': _snapshot!.title,
        'ts': DateTime.now().toIso8601String(),
      });
      if (_history.length > maxHistory) {
        _history.removeRange(0, _history.length - maxHistory);
      }
      _cursor = _history.length - 1;
    }
    await _saveState();
    return _result();
  }

  HtmlSnapshot _parse(_Fetched fetched) {
    final String contentType = fetched.contentType.toLowerCase();
    final String lower = fetched.body.trimLeft().toLowerCase();
    final bool html = contentType.contains('html') ||
        lower.startsWith('<!doctype') ||
        lower.startsWith('<html') ||
        lower.contains('<body');
    if (html) {
      return parseHtmlSnapshot(url: fetched.url, html: fetched.body);
    }
    final String text = fetched.body.trim();
    return HtmlSnapshot(
      url: fetched.url,
      title: fetched.contentType,
      text: text.length <= 4000 ? text : '${text.substring(0, 4000)}…',
      links: const <HtmlLink>[],
      forms: const <HtmlForm>[],
    );
  }

  Future<Map<String, dynamic>> _result() async {
    final HtmlSnapshot? snap = _snapshot;
    if (snap == null) {
      return <String, dynamic>{'ok': false, 'error': '没有页面快照'};
    }
    return <String, dynamic>{
      'ok': true,
      'url': _currentUrl,
      'status': _status,
      'snapshot': snap.toJson(),
      'display': snap.render(filled: _formValues),
      'can_back': canBack,
      'can_forward': canForward,
      'js': false,
    };
  }

  /// 当前状态（不发起网络请求）。
  Map<String, dynamic> state() {
    final HtmlSnapshot? snap = _snapshot;
    return <String, dynamic>{
      'ok': true,
      'url': _currentUrl,
      'status': _status,
      'snapshot': snap?.toJson(),
      'display': snap?.render(filled: _formValues),
      'can_back': canBack,
      'can_forward': canForward,
      'js': false,
      'cookies': _cookies.values.fold<int>(
        0,
        (int sum, Map<String, Map<String, String>> jar) => sum + jar.length,
      ),
    };
  }

  Future<_Fetched> _fetch(
    Uri uri, {
    String method = 'GET',
    Map<String, String>? body,
  }) async {
    final Map<String, String> headers = <String, String>{
      'user-agent': 'TangramTeamComputer/1.0 (+https://tangram.local)',
      'accept':
          'text/html,application/xhtml+xml,application/json;q=0.8,text/plain;q=0.7,*/*;q=0.5',
      'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
    final String cookie = _cookieHeader(uri);
    if (cookie.isNotEmpty) headers['cookie'] = cookie;

    final http.Request request = http.Request(method, uri);
    request.headers.addAll(headers);
    if (method == 'POST') {
      request.bodyFields = body ?? const <String, String>{};
    }
    final http.StreamedResponse streamed =
        await _client.send(request).timeout(timeout);
    final http.Response res = await http.Response.fromStream(streamed);

    _absorbCookies(uri, streamed);
    final Uint8List bytes = res.bodyBytes;
    if (bytes.length > maxBodyBytes) {
      throw StateError(
        '响应超过 ${maxBodyBytes ~/ (1024 * 1024)}MB 上限（${bytes.length} 字节）',
      );
    }
    final String text = utf8.decode(bytes, allowMalformed: true);
    final Object response = streamed;
    final String finalUrl = response is http.BaseResponseWithUrl
        ? response.url.toString()
        : uri.toString();
    return _Fetched(
      url: finalUrl,
      status: res.statusCode,
      contentType: res.headers['content-type'] ?? '',
      body: text,
    );
  }

  Uri? _normalize(String raw) {
    String value = raw.trim();
    if (value.isEmpty) return null;
    if (value.startsWith('//')) value = 'https:$value';
    if (!value.contains('://')) value = 'https://$value';
    final Uri? uri = Uri.tryParse(value);
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    return uri;
  }

  void _absorbCookies(Uri uri, http.StreamedResponse res) {
    final List<String> rawCookies =
        res.headersSplitValues['set-cookie'] ?? const <String>[];
    for (final String raw in rawCookies) {
      final List<String> parts = raw.split(';');
      if (parts.isEmpty) continue;
      final int eq = parts.first.indexOf('=');
      if (eq <= 0) continue;
      final String name = parts.first.substring(0, eq).trim();
      String value = parts.first.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      bool secure = false;
      String? domain;
      for (final String attr in parts.skip(1)) {
        final String a = attr.trim();
        final int i = a.indexOf('=');
        final String key = (i < 0 ? a : a.substring(0, i)).trim().toLowerCase();
        final String val = i < 0 ? '' : a.substring(i + 1).trim();
        if (key == 'secure') secure = true;
        if (key == 'domain' && val.isNotEmpty) {
          domain = val.startsWith('.') ? val.substring(1) : val;
        }
      }
      final String host = (domain ?? uri.host).toLowerCase();
      if (value == 'deleted') value = '';
      _cookies.putIfAbsent(
        host,
        () => <String, Map<String, String>>{},
      )[name] = <String, String>{
        'value': value,
        'secure': secure ? 'true' : 'false',
      };
    }
  }

  String _cookieHeader(Uri uri) {
    final String host = uri.host.toLowerCase();
    final List<String> parts = <String>[];
    _cookies.forEach((String domain, Map<String, Map<String, String>> jar) {
      final bool match = host == domain || host.endsWith('.$domain');
      if (!match) return;
      jar.forEach((String name, Map<String, String> raw) {
        if (raw['secure'] == 'true' && uri.scheme != 'https') return;
        final String value = raw['value'] ?? '';
        if (value.isEmpty) return;
        parts.add('$name=$value');
      });
    });
    return parts.join('; ');
  }

  Future<void> _saveState() async {
    if (!await profileDir.exists()) {
      await profileDir.create(recursive: true);
    }
    await _writeJson(
      File('${profileDir.path}/cookies.json'),
      _cookies,
    );
    await _writeJson(
      File('${profileDir.path}/history.json'),
      _history,
    );
  }

  static Future<void> _writeJson(File file, Object value) async {
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(file.path);
  }

  /// 测试 / 页面退出时释放连接。
  void close() {
    if (_ownsClient) _client.close();
  }

  /// 清空该智能体的浏览器 profile（Cookie + 历史），真实删除磁盘文件。
  Future<void> clearProfile() async {
    _cookies.clear();
    _history.clear();
    _cursor = -1;
    _currentUrl = null;
    _snapshot = null;
    _formValues.clear();
    for (final String name in <String>['cookies.json', 'history.json']) {
      final File f = File('${profileDir.path}/$name');
      if (await f.exists()) await f.delete();
    }
  }
}

class _Fetched {
  const _Fetched({
    required this.url,
    required this.status,
    required this.contentType,
    required this.body,
  });

  final String url;
  final int status;
  final String contentType;
  final String body;
}
