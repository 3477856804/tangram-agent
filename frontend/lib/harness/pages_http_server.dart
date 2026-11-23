/// Pages 本地分享服务：把已保存的页面版本通过本机回环 HTTP 服务出去，
/// 让「链接可见」的页面得到一个真实能打开的地址。
///
/// 对照 Rakazo Pages「可分享链接」的产品语义，在端侧的真实落地：没有公网
/// 服务，因此只绑定 127.0.0.1、端口由系统分配（port 0），返回的 URL 形如
/// `http://127.0.0.1:<port>/pages/<id>`，在本机浏览器里真实可打开；
/// 绝不伪造公网地址。服务只读页面文件，绝不接受写请求。
///
///  * 仅 GET；其它方法返回 405；
///  * 路径只接受 `/pages/<id>`（当前版本）与 `/pages/<id>/v<n>`（指定版本），
///    id 只允许字母数字与 `-` `_`，杜绝 `..` 穿越；
///  * 页面不存在 / 版本不存在返回 404，绝不返回假内容；
///  * 只有 visibility == link 的页面才能分享，private 页面返回 403 并
///    如实说明原因（先在页面元数据里设为链接可见）。
///
/// 纯 Dart，不依赖 Flutter，便于独立回归测试。

import 'dart:async';
import 'dart:io';

import 'pages_repository.dart';

class PagesHttpServer {
  PagesHttpServer(this._pages);

  final PagesRepository _pages;

  HttpServer? _server;

  bool get isRunning => _server != null;

  int? get port => _server?.port;

  String? get baseUrl => isRunning ? 'http://127.0.0.1:$port' : null;

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9\-_]+$');

  /// 启动服务（幂等：已在运行则直接返回当前地址）。
  Future<Map<String, dynamic>> start() async {
    if (_server != null) {
      return <String, dynamic>{
        'ok': true,
        'serving': true,
        'port': _server!.port,
        'base_url': baseUrl,
      };
    }
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    _server = server;
    unawaited(server.forEach(_handle));
    return <String, dynamic>{
      'ok': true,
      'serving': true,
      'port': server.port,
      'base_url': baseUrl,
    };
  }

  /// 停止服务（幂等）。
  Future<void> stop() async {
    final HttpServer? server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }

  /// 给一个链接可见页面生成真实可打开的本机地址。
  Future<Map<String, dynamic>> shareUrl(String id) async {
    if (_server == null) {
      return <String, dynamic>{'ok': false, 'error': '分享服务未启动'};
    }
    final Map<String, dynamic> detail = await _pages.get(id);
    if (detail['ok'] != true) return detail;
    final Map<dynamic, dynamic> page = detail['page'] as Map;
    if ('${page['visibility']}' != 'link') {
      return <String, dynamic>{
        'ok': false,
        'error': '该页面未设为链接可见，请先把可见性改为链接可见',
      };
    }
    return <String, dynamic>{
      'ok': true,
      'url': '${baseUrl!}/pages/$id',
      // 实际提供的版本：有钉选时为钉选版本，否则为最新版（与 get 的默认一致）。
      'version': detail['version'],
      'pinned_version': page['pinned_version'],
      'port': _server!.port,
      'base_url': baseUrl,
    };
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method != 'GET') {
        _respond(request, HttpStatus.methodNotAllowed, '仅支持 GET');
        return;
      }
      final List<String> segments = request.uri.pathSegments;
      if (segments.length < 2 || segments[0] != 'pages') {
        _respond(request, HttpStatus.notFound, '不存在的地址');
        return;
      }
      final String id = segments[1];
      if (!_idPattern.hasMatch(id)) {
        _respond(request, HttpStatus.notFound, '页面不存在');
        return;
      }
      int? version;
      if (segments.length == 3) {
        final RegExpMatch? m =
            RegExp(r'^v(\d+)$').firstMatch(segments[2]);
        if (m == null) {
          _respond(request, HttpStatus.notFound, '不存在的地址');
          return;
        }
        version = int.tryParse(m.group(1) ?? '');
        if (version == null || version < 1) {
          _respond(request, HttpStatus.notFound, '版本不存在');
          return;
        }
      } else if (segments.length > 3) {
        _respond(request, HttpStatus.notFound, '不存在的地址');
        return;
      }
      final Map<String, dynamic> detail =
          await _pages.get(id, version: version);
      if (detail['ok'] != true) {
        _respond(request, HttpStatus.notFound, '${detail['error'] ?? '页面不存在'}');
        return;
      }
      final Map<dynamic, dynamic> page = detail['page'] as Map;
      if ('${page['visibility']}' != 'link') {
        _respond(
          request,
          HttpStatus.forbidden,
          '该页面未设为链接可见',
        );
        return;
      }
      final String html = '${detail['html'] ?? ''}';
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(html);
      await request.response.close();
    } on Object catch (e) {
      _respond(
        request,
        HttpStatus.internalServerError,
        '服务异常：$e',
      );
    }
  }

  void _respond(HttpRequest request, int status, String body) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.text
      ..write(body);
    unawaited(request.response.close());
  }
}
