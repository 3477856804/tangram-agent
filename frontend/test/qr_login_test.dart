/// 扫码登录协议测试：验证对三套真实上游字段的兼容解析，以及
/// 「上游没下发二维码就拒绝渲染」这条诚实约束。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tangram/harness/im_service.dart';
import 'package:tangram/harness/login_protocol.dart';
import 'package:tangram/harness/qr_login_client.dart';

void main() {
  group('网关地址 -> REST 源', () {
    test('wss 推导为 https 并保留端口、丢弃 WebSocket 路径', () {
      expect(
        QrLoginClient.originOf('wss://gw.example.com:50432/ws').toString(),
        'https://gw.example.com:50432',
      );
    });

    test('ws 推导为 http', () {
      expect(
        QrLoginClient.originOf('ws://192.168.1.10:50432/ws').toString(),
        'http://192.168.1.10:50432',
      );
    });

    test('直接填 http(s) 也接受（im.serve 就是 HTTP 网关）', () {
      expect(
        QrLoginClient.originOf('http://192.168.1.10:50432').host,
        '192.168.1.10',
      );
    });

    test('非法地址抛错，不猜测主机', () {
      expect(
        () => QrLoginClient.originOf('not-a-url'),
        throwsA(isA<QrLoginException>()),
      );
    });
  });

  group('端点映射（对齐 im/serve.py）', () {
    test('微信 / QQ 各自走真实扫码端点', () {
      expect(QrLoginClient.loginPathFor('wechat'),
          '/api/login/wechat/qr');
      expect(QrLoginClient.statusPathFor('wechat'),
          '/api/login/wechat/status');
      expect(QrLoginClient.loginPathFor('qq'), '/api/login/qq/qr');
      expect(QrLoginClient.statusPathFor('qq'), '/api/login/qq/status');
    });

    test('配置可覆盖端点（对接 ClawPanel 风格网关）', () {
      expect(QrLoginClient.loginPathFor('qq', '/napcat/qrcode'),
          '/napcat/qrcode');
    });
  });

  group('QrLoginTicket 上游字段兼容', () {
    test('freestylefly：qrCodeUrl + wId', () {
      final t = QrLoginTicket.fromJson(<String, dynamic>{
        'qrCodeUrl': 'https://wx.example/q/abc',
        'wId': 'w-123',
      }, connector: 'wechat');
      expect(t, isNotNull);
      expect(t!.sessionId, 'w-123');
      expect(t.qrContent, 'https://wx.example/q/abc');
      expect(t.expiresIn, 300);
    });

    test('im.serve text-only：只有 url、没有 session_id 也能渲染', () {
      final t = QrLoginTicket.fromJson(<String, dynamic>{
        'ok': true,
        'render': 'text-only',
        'url': 'https://liteapp.weixin.qq.com/q/7GiQu1?qrcode=abc&bot_type=3',
      });
      expect(t, isNotNull);
      expect(t!.sessionId, isEmpty);
      expect(t.qrContent, contains('liteapp.weixin.qq.com'));
      expect(t.hasRenderableQr, isTrue);
    });

    test('网关直接下发 base64 二维码图片', () {
      final t = QrLoginTicket.fromJson(<String, dynamic>{
        'session_id': 's1',
        'qr_image_base64': base64Encode(<int>[1, 2, 3, 4]),
      });
      expect(t!.qrImageBytes, isA<Uint8List>());
      expect(t.hasRenderableQr, isTrue);
    });

    test('上游没给任何二维码 -> 返回 null（绝不本地伪造）', () {
      expect(
        QrLoginTicket.fromJson(<String, dynamic>{'session_id': 's1'}),
        isNull,
      );
    });
  });

  group('QrLoginResult 状态机', () {
    test('im.serve 微信 waiting', () {
      final r = QrLoginResult.fromJson(<String, dynamic>{
        'ok': true,
        'logged_in': false,
        'login_state': 'waiting_scan',
        'status': 'waiting',
      });
      expect(r.status, QrLoginStatus.waiting);
    });

    test('im.serve 微信已扫码待确认', () {
      final r = QrLoginResult.fromJson(<String, dynamic>{
        'login_state': 'scanned',
        'status': 'scanned',
      });
      expect(r.status, QrLoginStatus.scanned);
    });

    test('im.serve 微信确认 + 真实凭据', () {
      final r = QrLoginResult.fromJson(<String, dynamic>{
        'ok': true,
        'logged_in': true,
        'status': 'confirmed',
        'ws_url': 'ws://192.168.1.10:50432/ws',
        'guid': 'tga-abcd',
        'token': 'real-token',
        'bot_id': 'bot-1',
      });
      expect(r.status, QrLoginStatus.confirmed);
      expect(r.hasCredentials, isTrue);
      expect(r.wsUrl, 'ws://192.168.1.10:50432/ws');
      expect(r.token, 'real-token');
    });

    test('im.serve QQ online', () {
      final r = QrLoginResult.fromJson(<String, dynamic>{
        'ok': true,
        'online': true,
        'user_id': 10001,
        'nickname': '测试用户',
        'status': 'confirmed',
        'ws_url': 'ws://192.168.1.10:50432/ws',
        'guid': 'g',
        'token': 't',
      });
      expect(r.status, QrLoginStatus.confirmed);
      expect(r.hasCredentials, isTrue);
    });

    test('freestylefly logged_in / need_verify', () {
      expect(
        QrLoginResult.fromJson(<String, dynamic>{'status': 'logged_in'})
            .status,
        QrLoginStatus.confirmed,
      );
      expect(
        QrLoginResult.fromJson(<String, dynamic>{'status': 'need_verify'})
            .status,
        QrLoginStatus.needVerify,
      );
    });

    test('显式 error 才置失败；hint/reason 不误伤等待态', () {
      final r = QrLoginResult.fromJson(<String, dynamic>{
        'status': 'waiting',
        'hint': 'NapCat 暂未启动，请稍候',
      });
      expect(r.status, QrLoginStatus.waiting);
    });
  });

  group('QrLoginClient HTTP（真实响应解析）', () {
    test('image/png 真二维码直接转成票据', () async {
      final c = QrLoginClient(client: MockClient((http.Request req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/login/wechat/qr');
        return http.Response.bytes(
          <int>[0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10, 1, 2, 3],
          200,
          headers: <String, String>{'content-type': 'image/png'},
        );
      }));
      final t = await c.requestQr(
        gatewayUrl: 'http://192.168.1.10:50432',
        connector: 'wechat',
      );
      expect(t.qrImageBytes, isNotNull);
      expect(t.qrContent, isEmpty);
      expect(t.hasRenderableQr, isTrue);
    });

    test('im.serve text-only JSON 也能渲染真 URL', () async {
      final c = QrLoginClient(client: MockClient((_) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'render': 'text-only',
            'url': 'https://liteapp.weixin.qq.com/q/real?qrcode=xyz',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }));
      final t = await c.requestQr(
        gatewayUrl: 'http://192.168.1.10:50432',
        connector: 'wechat',
      );
      expect(t.qrContent, contains('liteapp.weixin.qq.com'));
    });

    test('已登录时抛 QrLoginAlreadyLoggedIn（不出假码）', () async {
      final c = QrLoginClient(client: MockClient((_) async {
        return http.Response(
          jsonEncode(<String, dynamic>{'ok': true, 'already_logged_in': true}),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }));
      await expectLater(
        c.requestQr(
            gatewayUrl: 'http://192.168.1.10:50432', connector: 'wechat'),
        throwsA(isA<QrLoginAlreadyLoggedIn>()),
      );
    });

    test('网关 503 且无二维码 -> 抛错带真实原因', () async {
      final c = QrLoginClient(client: MockClient((_) async {
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'hint': 'NapCat 未提供二维码（本服务不伪造二维码）'
          }),
          503,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }));
      await expectLater(
        c.requestQr(gatewayUrl: 'http://127.0.0.1:50432', connector: 'qq'),
        throwsA(isA<QrLoginException>()),
      );
    });

    test('pollStatus 解析 confirmed + 凭据', () async {
      final c = QrLoginClient(client: MockClient((http.Request req) async {
        expect(req.url.path, '/api/login/wechat/status');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'ok': true,
            'logged_in': true,
            'status': 'confirmed',
            'ws_url': 'ws://192.168.1.10:50432/ws',
            'guid': 'g1',
            'token': 't1',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }));
      final r = await c.pollStatus(
        gatewayUrl: 'http://192.168.1.10:50432',
        sessionId: '',
        connector: 'wechat',
      );
      expect(r.status, QrLoginStatus.confirmed);
      expect(r.hasCredentials, isTrue);
    });
  });

  group('默认网关（构建注入，源码不写死）', () {
    test('默认地址不含已下线的沙箱转发域名，注入时才可推导 REST 源', () {
      // 历史教训：写死的 Cloud Studio 沙箱地址下线后只剩 403，
      // 「点连接出码」实际是死链。默认地址只能由构建方注入。
      expect(kDefaultGatewayUrl, isNot(contains('cloudstudio')));
      expect(kDefaultGatewayUrl, isNot(contains('sandbox')));
      if (kDefaultGatewayUrl.isNotEmpty) {
        final Uri u = QrLoginClient.originOf(kDefaultGatewayUrl);
        expect(u.host, isNotEmpty);
        expect(u.path, isEmpty);
      }
    });

    test('飞书走官方设备授权流的真实端点（扫码建应用，不伪造二维码）', () {
      // im/serve.py 已实现 /api/login/feishu/*：走 lark_oapi.register_app()
      // 设备授权流，返回飞书官方验证链接渲染的真二维码。
      expect(QrLoginClient.loginPathFor('feishu'),
          '/api/login/feishu/qr');
      expect(QrLoginClient.statusPathFor('feishu'),
          '/api/login/feishu/status');
      // 未登记/自定义通道仍回落通用网关协议，保证向后兼容。
      expect(QrLoginClient.loginPathFor('custom'),
          QrLoginClient.kGenericLoginPath);
    });
  });
}
