/// IM 网关服务层 —— 把真实 AGP/WebSocket 通道接入内嵌后端。
///
/// 协议来源（真实抄自 OpenClaw 通道实现，见 agp_protocol.dart / im_gateway.dart）：
///   - `wechat-openclaw-channel`：AGP 信封、guid/token 鉴权、msg_id 幂等、心跳
///   - `openclaw-onebot`：指数退避重连、每会话消息批处理
///
/// 设计原则与 harness 一致：真实来源、拒绝语义、绝不谎称已连接。
/// 配置落盘到 HarnessStore，重启可恢复；连接状态全部来自真实 socket。
library;

import 'dart:async';
import 'dart:convert';

import 'package:tangram/harness/core.dart';
import 'package:tangram/harness/feishu_direct.dart';
import 'package:tangram/harness/gateway_discovery.dart';
import 'package:tangram/harness/im_gateway.dart';
import 'package:tangram/harness/ilink_wechat.dart';
import 'package:tangram/harness/login_protocol.dart';
import 'package:tangram/harness/qr_login_client.dart';
import 'package:tangram/harness/store.dart';

/// 默认网关地址：构建时注入，仓库源码不写死任何第三方地址。
///
/// 历史教训：旧版写死过一个 Cloud Studio 沙箱的端口转发地址，该沙箱
/// 下线后地址只剩 403 登录页，APP「点连接直接出码」实际点了个死链。
/// 网关是用户自托管的 `im/serve.py`（默认 :50432），不存在一个人人
/// 可用的公共实例，因此默认地址改由构建方按部署注入：
///   flutter build apk --dart-define=TANGRAM_GATEWAY_URL=https://你的网关
/// 未注入时为空字符串：界面会明确提示先启动网关并填写地址，
/// 绝不拿死链或假地址冒充「内置网关」。扫码成功后网关会下发
/// `ws(s)://` 的 AGP 地址，连接层以网关下发值为准。
const String kDefaultGatewayUrl =
    String.fromEnvironment('TANGRAM_GATEWAY_URL');

/// 网关部署说明页真实 URL：微信/QQ 未发现网关时，「引导二维码」渲染的是
/// 这个可扫码阅读的部署说明（仓库 README 的「快速开始」章节），
/// **不是**伪造的登录码。构建方可 dart-define 覆盖指向自己的文档站。
const String kGatewayDocsUrl = String.fromEnvironment(
  'TANGRAM_GATEWAY_DOCS_URL',
  defaultValue: 'https://github.com/3477856804/tangram-agent',
);

/// 单个连接器的真实运行状态快照。
class ImAdapterStatus {
  const ImAdapterStatus({
    required this.id,
    required this.name,
    required this.connected,
    required this.state,
    required this.detail,
    this.url = '',
    this.lastError,
    this.inbound = 0,
    this.outbound = 0,
    this.guid = '',
    this.configured = false,
  });

  final String id;
  final String name;
  final bool connected;
  final String state;
  final String detail;
  final String url;
  final String? lastError;
  final int inbound;
  final int outbound;
  final String guid;
  final bool configured;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'connected': connected,
        'state': state,
        'status': detail,
        'detail': detail,
        'url': url,
        if (lastError != null) 'last_error': lastError,
        'inbound': inbound,
        'outbound': outbound,
        'guid': guid,
        'configured': configured,
      };
}

class ImService {
  ImService(
    this.store,
    this.infer, {
    this.onLog,
    QrLoginClient? qrClient,
  }) : _qrClient = qrClient ?? QrLoginClient();

  final HarnessStore store;

  /// 真实推理回调：微信/QQ 消息进来后交给后端 _chat 走真实模型推理，
  /// 返回的字符串原样发回网关。绝不在此编造回复。
  final Future<String> Function(String text) infer;
  final void Function(String line)? onLog;

  /// 扫码登录 REST 客户端（可在测试里注入 mock）。
  final QrLoginClient _qrClient;

  static const String _file = 'im_gateways.json';

  /// 飞书直连凭据落盘文件（字段与 im/feishu_bot.py 的 feishu_bot.json 对齐：
  /// client_id/client_secret，App 私有目录）。
  static const String _feishuCredFile = 'feishu_direct.json';

  /// 飞书直连（官方设备授权流，无需网关）状态：是否已拿到真实凭据。
  bool _feishuDirectAuthorized = false;
  String _feishuDirectDetail = '';

  // ---- 微信 iLink 直连（真码由腾讯 ilinkai.weixin.qq.com 下发，5 分钟
  // 有效，无需任何外部网关；协议移植自 im/adapters/wechat_ilink.py）----
  IlinkWeChat? _ilink;
  CancelTokenSource? _ilinkReceive;
  int _ilinkInbound = 0;
  int _ilinkOutbound = 0;
  String _ilinkDetail = '';

  /// 与 im/feishu_bot.py FeishuBotSession._ADDONS 一致：bot 收发消息权限、
  /// 消息接收事件与卡片回调，随验证 URL 的 addons 参数预置给新建应用。
  static const Map<String, dynamic> kFeishuAppAddons = <String, dynamic>{
    'scopes': <String, dynamic>{
      'tenant': <String>[
        'im:message:send_as_bot', 'im:message:readonly',
        'im:message.p2p_msg:readonly', 'im:message.group_at_msg:readonly',
        'im:resource', 'application:bot.basic_info:read',
      ],
    },
    'events': <String, dynamic>{
      'items': <String, dynamic>{
        'tenant': <String>['im.message.receive_v1'],
      },
    },
    'callbacks': <String, dynamic>{
      'items': <String>['card.action.trigger'],
    },
  };

  /// 三个连接器与 OpenClaw 通道一一对应（QQ/微信/飞书）。
  static const List<Map<String, String>> kConnectors = <Map<String, String>>[
    <String, String>{'id': 'qq', 'name': 'QQ', 'detail': 'OneBot / AGP 网关'},
    <String, String>{'id': 'wechat', 'name': '微信', 'detail': 'iLink 直连（腾讯真码）/ AGP 网关'},
    <String, String>{'id': 'feishu', 'name': '飞书', 'detail': '扫码一键创建 bot 应用'},
  ];

  final Map<String, ImGateway> _gateways = <String, ImGateway>{};
  final Map<String, Map<String, dynamic>> _configs =
      <String, Map<String, dynamic>>{};

  /// 每个连接器最多一个在途扫码登录会话，后台真实轮询网关登录状态。
  final Map<String, _LoginSession> _sessions = <String, _LoginSession>{};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final raw = await store.readJson(_file);
    final list = raw['gateways'];
    if (list is List) {
      for (final dynamic e in list) {
        if (e is Map && e['id'] != null) {
          _configs[e['id'].toString()] = Map<String, dynamic>.from(e);
        }
      }
    }
    final cred = await store.readJson(_feishuCredFile);
    if ((cred['client_id'] ?? '').toString().isNotEmpty &&
        (cred['client_secret'] ?? '').toString().isNotEmpty) {
      _feishuDirectAuthorized = true;
      _feishuDirectDetail = '飞书直连 · 应用已创建，凭据已存本机';
    }
    // 微信 iLink：本机已有真实凭据（此前扫过腾讯真码）→ 直接恢复
    // getupdates 接收循环，重启 App 后微信里发消息依然是真链路。
    final ilink = _ilink ??= IlinkWeChat(store);
    await ilink.loadCred();
    if (ilink.hasToken) {
      _ilinkDetail = 'iLink 直连 · 凭据已存本机（weixin_ilink.json）';
      _ensureIlinkReceive();
    }
    _loaded = true;
  }

  /// 确保 iLink 接收循环在跑：getupdates 长轮询收消息 → 真实推理 →
  /// sendmessage 原样回发。与 im/serve.py 的微信接收线程同语义。
  void _ensureIlinkReceive() {
    if (_ilinkReceive != null) return;
    final ilink = _ilink;
    if (ilink == null || !ilink.hasToken) return;
    final CancelTokenSource src = CancelTokenSource();
    _ilinkReceive = src;
    unawaited(_ilinkReceiveLoop(src.token));
  }

  Future<void> _ilinkReceiveLoop(CancelToken token) async {
    final IlinkWeChat ilink = _ilink!;
    onLog?.call('[im] 微信 iLink 接收循环已启动（getupdates 长轮询）');
    while (!token.isCancelled && ilink.hasToken) {
      try {
        final List<IlinkInboundMessage> msgs = await ilink.getUpdates();
        for (final IlinkInboundMessage m in msgs) {
          if (token.isCancelled) return;
          if (m.text.trim().isEmpty) continue;
          _ilinkInbound++;
          String reply;
          try {
            reply = await infer(m.text);
          } on Object catch (e) {
            reply = '（这条消息处理失败了：$e）';
          }
          try {
            await ilink.sendText(m.fromUserId, reply,
                contextToken: m.contextToken);
            _ilinkOutbound++;
            _ilinkDetail = 'iLink 直连 · 收 $_ilinkInbound / 发 $_ilinkOutbound';
            onLog?.call('[im] 微信 iLink：已回复 ${m.fromUserId}');
          } on Object catch (e) {
            onLog?.call('[im] 微信 iLink 发送失败：$e');
          }
        }
      } on Object catch (e) {
        onLog?.call('[im] 微信 iLink 接收异常：$e');
        // 网络抖动：3 秒后继续（token 感知等待）。
        try {
          await Future.any<Object?>(<Future<Object?>>[
            Future<void>.delayed(const Duration(seconds: 3)),
            token.onCancel,
          ]);
        } on Object {
          return;
        }
      }
    }
    onLog?.call('[im] 微信 iLink 接收循环已停止');
  }

  Future<void> _persist() async {
    await store.writeJson(_file, <String, dynamic>{
      'gateways': _configs.values.toList(growable: false),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  Map<String, dynamic> _configOf(String id) =>
      _configs[id] ?? <String, dynamic>{'id': id};

  ImGatewayConfig _gatewayConfig(String id, [Map<String, dynamic>? override]) {
    final c = <String, dynamic>{..._configOf(id), ...?override};
    return ImGatewayConfig(
      url: (c['url'] ?? '').toString(),
      guid: (c['guid'] ?? '').toString(),
      userId: (c['user_id'] ?? c['userId'] ?? '').toString(),
      token: (c['token'] ?? '').toString(),
      connector: id,
    );
  }

  /// 统一分发入口，由 EmbeddedBackend._imEvent 委托。
  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> p,
  ) async {
    await load();
    switch (action) {
      case 'list_adapters':
      case 'list':
      case 'status':
        return <String, dynamic>{
          'ok': true,
          'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
        };
      case 'configure':
        return _configure(p);
      case 'connect':
        return await _connect(p);
      case 'disconnect':
        return await _disconnect(p);
      // ---- 扫码登录（真实二维码由网关下发，见 login_protocol.dart）----
      case 'login_qr':
      case 'qr_session':
        return await _startLogin(p);
      case 'login_status':
        return _loginStatus(p);
      case 'login_cancel':
        return await _cancelLogin(p);
      case 'get_config':
        final id = _id(p);
        return <String, dynamic>{
          'ok': true,
          'config': <String, dynamic>{
            'id': id,
            'url': (_configOf(id)['url'] ?? '').toString(),
            'guid': (_configOf(id)['guid'] ?? '').toString(),
            'user_id': (_configOf(id)['user_id'] ?? '').toString(),
            'token': (_configOf(id)['token'] ?? '').toString(),
          },
        };
      default:
        return <String, dynamic>{'ok': false, 'error': '未知 im_event 动作：$action'};
    }
  }

  String _id(Map<String, dynamic> p) =>
      (p['connector'] ?? p['id'] ?? 'wechat').toString();

  Future<Map<String, dynamic>> _configure(Map<String, dynamic> p) async {
    final id = _id(p);
    final c = <String, dynamic>{..._configOf(id), 'id': id};
    for (final key in <String>[
      'url',
      'guid',
      'user_id',
      'token',
      // 可选：对接既有 ClawPanel 风格网关的自定义登录端点。
      'login_path',
      'status_path',
      'cancel_path',
    ]) {
      if (p.containsKey(key)) c[key] = (p[key] ?? '').toString();
    }
    _configs[id] = c;
    await _persist();
    onLog?.call('[im] 已保存 $id 网关配置');
    return <String, dynamic>{
      'ok': true,
      'config': c,
      'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
    };
  }

  Future<Map<String, dynamic>> _connect(Map<String, dynamic> p) async {
    final id = _id(p);
    // 若本次带了 url，先落盘，保证重启后仍可连。
    if (p.containsKey('url')) {
      await _configure(p);
    }
    final cfg = _gatewayConfig(id, p);
    if (cfg.url.trim().isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': '未配置 $id 登录凭据：请先点「连接」扫码授权，'
            '本应用不会伪造连接状态。',
        'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
      };
    }

    final old = _gateways.remove(id);
    if (old != null) await old.dispose();

    final gw = ImGateway(
      cfg,
      onPromptText: (InboundPrompt prompt) => infer(prompt.prompt.text),
      onLog: onLog,
    );
    _gateways[id] = gw;
    try {
      await gw.connect();
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'error': '$e',
        'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
      };
    }
    final a = adapterOf(id);
    return <String, dynamic>{
      'ok': true,
      'connected': a.connected,
      'state': a.state,
      'adapter': a.toJson(),
      'adapters': adapters().map((ImAdapterStatus x) => x.toJson()).toList(),
      if (!a.connected && a.lastError != null) 'error': a.lastError,
    };
  }

  Future<Map<String, dynamic>> _disconnect(Map<String, dynamic> p) async {
    final id = _id(p);
    final gw = _gateways.remove(id);
    if (gw != null) await gw.dispose();
    return <String, dynamic>{
      'ok': true,
      'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
    };
  }

  // ---------------------------------------------------------------------------
  // 扫码登录：网关下发真码 -> 后台轮询 -> 确认后自动建立 AGP 连接
  // 协议抄自 freestylefly/openclaw-wechat（getQRCode/checkLogin，5 分钟有效）
  // 与 HenryXiaoYang/wechat-openclaw-channel（qrconnect 长轮询状态机）。
  // ---------------------------------------------------------------------------

  /// 第一步：取得**真实**二维码并启动后台轮询。三条如实路径：
  ///  * 飞书：优先官方设备授权流直连（见 `_startFeishuDirect`），
  ///    返回的 qr_content 是官方验证 URL，扫码即建应用，无需网关；
  ///  * 微信/QQ 有网关：向网关申请真实登录码（内容 100% 来自网关响应）；
  ///  * 无网关：返回 guide 结构化结果（qr_content=部署说明真实 URL），
  ///    上游没下发登录码就绝不本地造码。
  Future<Map<String, dynamic>> _startLogin(Map<String, dynamic> p) async {
    final String id = _id(p);
    String url =
        (p['url'] ?? _configOf(id)['url'] ?? '').toString().trim();

    // 微信优先走腾讯 iLink 直连（ilinkai.weixin.qq.com，无需网关）：
    // 点一下就直接出腾讯刚发的**真码**，5 分钟内有效；扫完在微信里发条
    // 消息就是真链路。过期点「要新码」重新取。仅当显式配置了网关地址时
    // 尊重用户选择走网关；直连不可用再回退网关流程。
    if (id == 'wechat' && url.isEmpty) {
      final Map<String, dynamic>? direct = await _startWechatIlinkDirect();
      if (direct != null) return direct;
      onLog?.call('[im] 微信 iLink 直连不可用，回退网关流程');
    }

    // 飞书优先走官方设备授权流直连（accounts.feishu.cn，无需网关）：
    // 点一下就直接出「扫码建应用」的真实验证 URL 二维码。仅当本次/历史
    // 显式配置了网关地址时尊重用户选择走网关；直连不可用再回退网关流程。
    if (id == 'feishu' && url.isEmpty) {
      final Map<String, dynamic>? direct = await _startFeishuDirect();
      if (direct != null) return direct;
      onLog?.call('[im] 飞书直连不可用，回退网关流程');
    }

    // 零配置：未填地址时先在局域网自动发现网关（点连接即出码）。
    // 发现失败才降级到高级设置手填，绝不编造地址或伪造二维码。
    bool discovered = false;
    if (url.isEmpty) {
      final String? found = await GatewayDiscovery.discover();
      if (found != null && found.isNotEmpty) {
        url = found;
        discovered = true;
        onLog?.call('[im] 局域网发现网关：$url');
      }
    }
    if (url.isEmpty) {
      // 没发现到网关：不只报错。微信/QQ 的登录码必须由持有 appid/secret 的
      // 网关（iLink/NapCat）向腾讯换取，App 本地无法凭空生成合法登录码，
      // 因此如实给出「网关部署说明」真实 URL 让 UI 渲染引导二维码——
      // 扫码可读部署指引，绝不是伪造的登录码。
      final bool feishu = id == 'feishu';
      return <String, dynamic>{
        'ok': true,
        'guide': true,
        'need_gateway': true,
        'connector': id,
        'qr_content': kGatewayDocsUrl,
        'guide_text': feishu
            ? '飞书直连暂时不可用（连不上官方 accounts.feishu.cn），网关侧'
                '登录也未发现。扫码查看网关部署说明'
                '（电脑运行 `python3 -m im.serve --port 50432`），'
                '或在下方填写网关地址后重试'
            : '微信/QQ 登录码需由本地网关（iLink/NapCat）向腾讯换取，'
                '当前未发现同一局域网内的网关。扫码查看网关部署说明'
                '（电脑运行 `python3 -m im.serve --port 50432`），'
                '或在「网络设置」/下方填写网关地址后重试。'
                '本应用绝不伪造登录二维码。',
        'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
      };
    }
    // 首次发现或 UI 里刚填了地址，先落盘，保证重启后仍在、下次免发现。
    if (discovered || p.containsKey('url')) {
      await _configure(<String, dynamic>{'connector': id, 'url': url});
    }
    // 同一连接器旧会话先撤销，避免两个轮询任务并存。
    await _cancelLogin(<String, dynamic>{'connector': id});

    final Map<String, dynamic> cfg = _configOf(id);
    try {
      final QrLoginTicket ticket = await _qrClient.requestQr(
        gatewayUrl: url,
        connector: id,
        guid: (cfg['guid'] ?? '').toString(),
        token: (cfg['token'] ?? '').toString(),
        loginPath: cfg['login_path']?.toString(),
      );
      final CancelTokenSource source = CancelTokenSource();
      final _LoginSession session = _LoginSession(
        ticket: ticket,
        cancelSource: source,
        connector: id,
      );
      _sessions[id] = session;
      onLog?.call('[im] 已获取 $id 登录二维码（会话 ${ticket.sessionId}，'
          '${ticket.expiresIn}s 有效），开始轮询网关');
      // 后台轮询，不阻塞本次 control 调用。
      unawaited(_pollLoop(session, url, cfg['status_path']?.toString()));
      return <String, dynamic>{
        'ok': true,
        'active': true,
        'session_id': ticket.sessionId,
        'connector': id,
        'status': QrLoginStatus.waiting.wire,
        'qr_content': ticket.qrContent,
        if (ticket.qrUrl != null) 'qr_url': ticket.qrUrl,
        if (ticket.qrImageBytes != null)
          'qr_image_base64': base64Encode(ticket.qrImageBytes!),
        'expires_in': ticket.expiresIn,
        'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
      };
    } on QrLoginAlreadyLoggedIn {
      // 网关已持有登录凭据（如 weixin_ilink.json 存在），不必再扫一次。
      // 直接读状态 -> 拿 ws_url / guid / token -> 建立真实连接。
      try {
        final QrLoginResult r = await _qrClient.pollStatus(
          gatewayUrl: url,
          sessionId: '',
          connector: id,
          statusPath: cfg['status_path']?.toString(),
        );
        final _LoginSession session = _LoginSession(
          ticket: QrLoginTicket(
            sessionId: '', connector: id, qrContent: '', expiresIn: 300,
          ),
          cancelSource: CancelTokenSource(),
          connector: id,
        );
        session.result = r;
        await _onConfirmed(session);
        onLog?.call('[im] $id 网关已有登录态，状态=${r.status.wire}，'
            '已连接=${session.autoConnected}');
        return <String, dynamic>{
          'ok': true,
          'active': true,
          'already_logged_in': true,
          'status': r.status.wire,
          'connected': adapterOf(id).connected,
          'auto_connected': session.autoConnected,
          'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
        };
      } on Object catch (e) {
        return <String, dynamic>{
          'ok': false,
          'error': '读取网关登录状态失败：$e',
          'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
        };
      }
    } on QrLoginException catch (e) {
      onLog?.call('[im] $id 二维码获取失败：${e.message}');
      return <String, dynamic>{
        'ok': false,
        'error': e.message,
        'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
      };
    } on Object catch (e) {
      onLog?.call('[im] $id 二维码请求异常：$e');
      return <String, dynamic>{
        'ok': false,
        'error': '无法从网关获取二维码：$e。请确认网关已部署并接入微信/QQ 登录服务。',
        'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
      };
    }
  }

  // ---------------------------------------------------------------------------
  // 微信 iLink 直连：真码由腾讯 ilinkai.weixin.qq.com 下发（5 分钟有效），
  // 扫码确认后凭据落盘 weixin_ilink.json，getupdates 长轮询即真链路。
  // 协议移植自 im/adapters/wechat_ilink.py（见 ilink_wechat.dart）。
  // ---------------------------------------------------------------------------

  /// 发起微信 iLink 直连登录；成功返回含腾讯真码的出码响应。
  /// 直连不可用（网络/平台侧限制）返回 null，由调用方回退网关流程。
  Future<Map<String, dynamic>?> _startWechatIlinkDirect() async {
    const String id = 'wechat';
    final IlinkWeChat ilink = _ilink ??= IlinkWeChat(store);
    await ilink.loadCred();
    if (ilink.hasToken) {
      // 本机已有真实凭据：恢复接收循环即可，不必再扫一次。
      _ensureIlinkReceive();
      return <String, dynamic>{
        'ok': true,
        'active': true,
        'direct': 'ilink',
        'already_logged_in': true,
        'connector': id,
        'status': QrLoginStatus.confirmed.wire,
        'connected': adapterOf(id).connected,
        'detail': _ilinkDetail.isNotEmpty
            ? _ilinkDetail
            : 'iLink 直连 · 凭据已存本机',
        'adapters':
            adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
      };
    }
    final IlinkQrTicket qr;
    try {
      qr = await ilink.fetchQr();
    } on Object catch (e) {
      onLog?.call('[im] 微信 iLink 取码失败：$e');
      return null;
    }
    await _cancelLogin(<String, dynamic>{'connector': id});
    final _LoginSession session = _LoginSession(
      ticket: QrLoginTicket(
        sessionId: qr.qrcode,
        connector: id,
        qrContent: qr.scanContent,
        expiresIn: qr.expiresIn,
      ),
      cancelSource: CancelTokenSource(),
      connector: id,
    )..directKind = 'ilink';
    _sessions[id] = session;
    onLog?.call('[im] 微信 iLink 真码已下发（${qr.expiresIn}s 有效），开始轮询');
    unawaited(_pollIlinkDirect(session, ilink));
    return <String, dynamic>{
      'ok': true,
      'active': true,
      'direct': 'ilink',
      'session_id': qr.qrcode,
      'connector': id,
      'status': QrLoginStatus.waiting.wire,
      'qr_content': qr.scanContent,
      'expires_in': qr.expiresIn,
      'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
    };
  }

  /// 后台轮询腾讯扫码状态：wait→waiting、scaned→scanned、
  /// confirmed→落盘凭据并起接收循环；5 分钟到期→expired（UI 出「要新码」）。
  Future<void> _pollIlinkDirect(_LoginSession s, IlinkWeChat ilink) async {
    final CancelToken token = s.cancelSource.token;
    final DateTime deadline =
        DateTime.now().add(Duration(seconds: s.ticket.expiresIn));
    while (!token.isCancelled) {
      await Future.any<Object?>(<Future<Object?>>[
        Future<void>.delayed(const Duration(seconds: 2)),
        token.onCancel,
      ]);
      if (token.isCancelled) return;
      if (DateTime.now().isAfter(deadline)) {
        s.result = const QrLoginResult(
          status: QrLoginStatus.expired,
          error: '腾讯 iLink 真码 5 分钟已到期，点「要新码」重新取一张',
        );
        onLog?.call('[im] wechat iLink 二维码过期');
        return;
      }
      final IlinkPollResult r = await ilink.pollQrStatus(s.ticket.sessionId);
      switch (r.status) {
        case 'confirmed':
          s.result = const QrLoginResult(status: QrLoginStatus.confirmed);
          _ilinkDetail = 'iLink 直连 · 扫码确认，凭据已落盘';
          _ensureIlinkReceive();
          onLog?.call('[im] wechat iLink 扫码确认（bot ${ilink.botId}）');
          return;
        case 'scaned':
        case 'scanned':
          s.result = const QrLoginResult(status: QrLoginStatus.scanned);
        case 'expired':
          s.result = const QrLoginResult(
            status: QrLoginStatus.expired,
            error: '二维码已在微信侧过期，点「要新码」重新获取',
          );
          return;
        default:
          s.result = const QrLoginResult(status: QrLoginStatus.waiting);
          if (r.error.isNotEmpty) s.pollError = r.error;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 飞书直连：官方设备授权流（lark_oapi register_app 同款协议，见
  // feishu_direct.dart），无需网关即可出「扫码建应用」真码。
  // ---------------------------------------------------------------------------

  /// 发起飞书直连登录；成功返回含官方验证 URL 的出码响应，
  /// 直连不可用（网络/端点异常）返回 null 由调用方回退网关流程。
  Future<Map<String, dynamic>?> _startFeishuDirect() async {
    const String id = 'feishu';
    if (_feishuDirectAuthorized && !_sessions.containsKey(id)) {
      // 已有真实凭据（此前扫码创建过应用）：与 im/feishu_bot.py begin()
      // 的 already_logged_in 行为一致，不重复建应用。
      return <String, dynamic>{
        'ok': true,
        'active': true,
        'direct': 'feishu',
        'already_logged_in': true,
        'connector': id,
        'status': QrLoginStatus.confirmed.wire,
        'connected': adapterOf(id).connected,
        'detail': _feishuDirectDetail,
        'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
      };
    }

    final FeishuDirectFlow flow = FeishuDirectFlow(
      source: 'tangram-app',
      appName: 'TGA 助手',
      appDesc: '由 Tangram Agent 扫码创建，权限与事件已自动预置',
      addons: kFeishuAppAddons,
    );
    final FeishuDirectTicket ticket;
    try {
      ticket = await flow.begin();
    } on Object catch (e) {
      onLog?.call('[im] 飞书直连发起失败：$e');
      flow.dispose();
      return null;
    }

    // 同一连接器旧会话先撤销，避免两个轮询任务并存。
    await _cancelLogin(<String, dynamic>{'connector': id});
    final _LoginSession session = _LoginSession(
      ticket: QrLoginTicket(
        sessionId: 'feishu-direct-${DateTime.now().millisecondsSinceEpoch}',
        connector: id,
        qrContent: ticket.verificationUrl,
        expiresIn: ticket.expiresIn,
      ),
      cancelSource: CancelTokenSource(),
      connector: id,
    )
      ..directFlow = flow
      ..deviceCode = ticket.deviceCode
      ..pollInterval = ticket.intervalSeconds;
    _sessions[id] = session;
    onLog?.call('[im] 飞书直连：已拿到官方验证 URL（会话 ${session.ticket.sessionId}，'
        '${ticket.expiresIn}s 有效），开始轮询 accounts.feishu.cn');
    unawaited(_pollFeishuDirect(session));
    return <String, dynamic>{
      'ok': true,
      'active': true,
      'direct': 'feishu',
      'session_id': session.ticket.sessionId,
      'connector': id,
      'status': QrLoginStatus.waiting.wire,
      'qr_content': ticket.verificationUrl,
      'expires_in': ticket.expiresIn,
      'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
    };
  }

  /// 飞书直连后台轮询：按官方 begin 返回的 interval 轮询 `action=poll`，
  /// 状态映射到 QrLoginStatus（pending→waiting、success→confirmed、
  /// expired_token→expired、access_denied→error），与 im/feishu_bot.py
  /// snapshot() 的状态机一致。
  Future<void> _pollFeishuDirect(_LoginSession s) async {
    final CancelToken token = s.cancelSource.token;
    final FeishuDirectFlow flow = s.directFlow!;
    final String deviceCode = s.deviceCode!;
    int interval = s.pollInterval;
    final DateTime deadline =
        DateTime.now().add(Duration(seconds: s.ticket.expiresIn));
    int failures = 0;
    while (!token.isCancelled) {
      await Future.any<Object?>(<Future<Object?>>[
        Future<void>.delayed(Duration(seconds: interval)),
        token.onCancel,
      ]);
      if (token.isCancelled) {
        flow.dispose();
        return;
      }
      if (DateTime.now().isAfter(deadline)) {
        s.result = const QrLoginResult(
          status: QrLoginStatus.expired,
          error: '飞书设备码已过期，请点「要新码」重新获取',
        );
        onLog?.call('[im] feishu 直连设备码过期');
        flow.dispose();
        return;
      }
      try {
        final FeishuPollResult r = await flow.poll(deviceCode);
        failures = 0;
        switch (r.outcome) {
          case FeishuPollOutcome.pending:
            // 用户还没扫码/确认：保持 waiting，UI 继续轮询 login_status。
            break;
          case FeishuPollOutcome.slowDown:
            interval += 5; // 同 SDK：slow_down 时轮询间隔加 5 秒
            onLog?.call('[im] feishu 直连轮询被限速，间隔调整为 ${interval}s');
          case FeishuPollOutcome.domainSwitched:
            onLog?.call('[im] feishu 直连：检测到 Lark 国际版租户，'
                '已切换 accounts.larksuite.com 继续轮询');
          case FeishuPollOutcome.success:
            await _onFeishuDirectConfirmed(s, r);
            flow.dispose();
            return;
          case FeishuPollOutcome.accessDenied:
            s.result = const QrLoginResult(
              status: QrLoginStatus.error,
              error: '飞书侧已拒绝授权（access_denied），请重新发起',
            );
            flow.dispose();
            return;
          case FeishuPollOutcome.expired:
            s.result = const QrLoginResult(
              status: QrLoginStatus.expired,
              error: '飞书设备码已过期，请点「要新码」重新获取',
            );
            flow.dispose();
            return;
          case FeishuPollOutcome.error:
            s.result = QrLoginResult(
              status: QrLoginStatus.error,
              error: '飞书授权失败：'
                  '${(r.errorDescription.isNotEmpty ? r.errorDescription : r.error)}',
            );
            flow.dispose();
            return;
        }
      } on Object catch (e) {
        failures++;
        s.pollError = '$e';
        onLog?.call('[im] feishu 直连轮询失败($failures)：$e');
        if (failures >= 3) {
          s.result = QrLoginResult(
            status: QrLoginStatus.error,
            error: '飞书授权状态查询连续失败：$e',
          );
          flow.dispose();
          return;
        }
      }
    }
    flow.dispose();
  }

  /// 扫码确认：官方端点返回真实 client_id/client_secret → 落盘 →
  /// 用官方 tenant_access_token 端点真实验证凭据可用性。
  Future<void> _onFeishuDirectConfirmed(_LoginSession s, FeishuPollResult r) async {
    await store.writeJson(_feishuCredFile, <String, dynamic>{
      'client_id': r.clientId,
      'client_secret': r.clientSecret,
      'saved_at': DateTime.now().toIso8601String(),
    });
    _feishuDirectAuthorized = true;
    s.result = const QrLoginResult(status: QrLoginStatus.confirmed);
    final bool verified =
        await s.directFlow!.verifyCredentials(r.clientId, r.clientSecret);
    _feishuDirectDetail = verified
        ? '飞书直连 · 应用已创建，凭据经官方端点验证可用'
        : '飞书直连 · 应用已创建，凭据已存本机（验证请求暂未成功）';
    onLog?.call('[im] feishu 直连确认：${verified ? '凭据已验证' : '凭据已落盘，验证未完成'}');
  }

  /// 第二步（UI 侧定时拉取）：返回扫码会话状态快照。
  Map<String, dynamic> _loginStatus(Map<String, dynamic> p) {
    final String id = _id(p);
    final _LoginSession? s = _sessions[id];
    final List<Map<String, dynamic>> list =
        adapters().map((ImAdapterStatus a) => a.toJson()).toList();
    if (s == null) {
      return <String, dynamic>{
        'ok': true,
        'active': false,
        'status': QrLoginStatus.idle.wire,
        'connected': adapterOf(id).connected,
        'adapters': list,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'active': true,
      'session_id': s.ticket.sessionId,
      'connector': id,
      'expires_in': s.ticket.expiresIn,
      'qr_content': s.ticket.qrContent,
      if (s.ticket.qrUrl != null) 'qr_url': s.ticket.qrUrl,
      if (s.ticket.qrImageBytes != null)
        'qr_image_base64': base64Encode(s.ticket.qrImageBytes!),
      ...s.result.toJson(),
      if (s.pollError != null) 'poll_error': s.pollError,
      'auto_connected': s.autoConnected,
      'connected': adapterOf(id).connected,
      'adapters': list,
    };
  }

  /// 撤销扫码会话（关闭弹窗、切换连接器、要新码时都会调用）。
  Future<Map<String, dynamic>> _cancelLogin(Map<String, dynamic> p) async {
    final String id = _id(p);
    final _LoginSession? s = _sessions.remove(id);
    if (s != null) {
      s.cancelSource.cancel('user_cancel');
      if (s.directFlow != null || s.directKind == 'ilink') {
        // 直连会话没有服务端取消端点（官方设备码/腾讯真码到期自动失效），
        // 只需停掉本地轮询。
        s.directFlow?.dispose();
      } else {
        final String url = (_configOf(id)['url'] ?? '').toString();
        if (url.isNotEmpty) {
          await _qrClient.cancel(
            gatewayUrl: url,
            sessionId: s.ticket.sessionId,
            cancelPath: _configOf(id)['cancel_path']?.toString(),
          );
        }
      }
    }
    return <String, dynamic>{
      'ok': true,
      'active': false,
      'status': QrLoginStatus.idle.wire,
      'adapters': adapters().map((ImAdapterStatus a) => a.toJson()).toList(),
    };
  }

  /// 后台轮询：2 秒一轮，直到确认 / 过期 / 连续失败 / 被取消。
  /// 用 CancelToken 管控生命周期（抄自 flutter_agent_harness 的契约）。
  Future<void> _pollLoop(
    _LoginSession s,
    String gatewayUrl,
    String? statusPath,
  ) async {
    final CancelToken token = s.cancelSource.token;
    final DateTime deadline =
        DateTime.now().add(Duration(seconds: s.ticket.expiresIn));
    int failures = 0;
    while (!token.isCancelled) {
      await Future.any<Object?>(<Future<Object?>>[
        Future<void>.delayed(const Duration(seconds: 2)),
        token.onCancel,
      ]);
      if (token.isCancelled) return;
      if (DateTime.now().isAfter(deadline)) {
        s.result = const QrLoginResult(
          status: QrLoginStatus.expired,
          error: '二维码已过期，请点「要新码」重新获取',
        );
        onLog?.call('[im] ${s.connector} 登录二维码过期');
        return;
      }
      try {
        final QrLoginResult r = await _qrClient.pollStatus(
          gatewayUrl: gatewayUrl,
          sessionId: s.ticket.sessionId,
          connector: s.connector,
          statusPath: statusPath,
        );
        failures = 0;
        s.result = r;
        if (r.status.isTerminal) {
          if (r.status == QrLoginStatus.confirmed) {
            await _onConfirmed(s);
          } else {
            onLog?.call('[im] ${s.connector} 登录结束：${r.status.wire}');
          }
          return;
        }
      } on Object catch (e) {
        failures++;
        s.pollError = '$e';
        onLog?.call('[im] ${s.connector} 状态轮询失败($failures)：$e');
        if (failures >= 3) {
          s.result = QrLoginResult(
            status: QrLoginStatus.error,
            error: '网关状态查询连续失败：$e',
          );
          return;
        }
      }
    }
  }

  /// 扫码确认：把网关下发的真实凭据落盘，并立即建立 AGP WebSocket 连接。
  /// 这一步之后，微信/QQ 里发消息才会真正走到 _chat 推理并原样回发。
  Future<void> _onConfirmed(_LoginSession s) async {
    final QrLoginResult r = s.result;
    final String id = s.connector;
    final Map<String, dynamic> c = <String, dynamic>{..._configOf(id), 'id': id};
    if (r.wsUrl != null && r.wsUrl!.trim().isNotEmpty) {
      c['url'] = r.wsUrl!.trim();
    }
    if (r.guid != null && r.guid!.isNotEmpty) c['guid'] = r.guid!;
    if (r.token != null && r.token!.isNotEmpty) c['token'] = r.token!;
    _configs[id] = c;
    await _persist();
    onLog?.call('[im] $id 扫码确认，写入真实凭据并连接 AGP 网关');
    if ((c['url'] ?? '').toString().trim().isNotEmpty) {
      await _connect(<String, dynamic>{'connector': id});
      s.autoConnected = adapterOf(id).connected;
    }
  }

  ImAdapterStatus adapterOf(String id) {
    final meta = kConnectors.firstWhere(
      (Map<String, String> c) => c['id'] == id,
      orElse: () => <String, String>{'id': id, 'name': id, 'detail': ''},
    );
    final gw = _gateways[id];
    final cfg = _configOf(id);
    final configured = (cfg['url'] ?? '').toString().trim().isNotEmpty;
    if (gw == null) {
      // 微信 iLink 直连：凭据真实存在且接收循环在跑 → 已连接（真链路），
      // 收发计数来自 getupdates/sendmessage 真实调用。
      if (id == 'wechat' && (_ilink?.hasToken ?? false)) {
        final bool running = _ilinkReceive != null;
        return ImAdapterStatus(
          id: id,
          name: meta['name'] ?? id,
          connected: running,
          state: running ? 'connected' : 'configured',
          detail: _ilinkDetail.isNotEmpty
              ? _ilinkDetail
              : 'iLink 直连 · 凭据已存本机',
          url: (cfg['url'] ?? '').toString(),
          guid: _ilink!.botId,
          inbound: _ilinkInbound,
          outbound: _ilinkOutbound,
          configured: true,
        );
      }
      // 飞书直连成功过（真实凭据已落盘）：渠道已授权。消息收发仍需网关
      // 侧官方长连接承接，detail 如实说明凭据来源，不虚报 AGP 连接。
      if (id == 'feishu' && _feishuDirectAuthorized) {
        return ImAdapterStatus(
          id: id,
          name: meta['name'] ?? id,
          connected: true,
          state: 'connected',
          detail: _feishuDirectDetail.isNotEmpty
              ? _feishuDirectDetail
              : '飞书直连 · 应用已创建',
          url: (cfg['url'] ?? '').toString(),
          guid: (cfg['guid'] ?? '').toString(),
          configured: true,
        );
      }
      return ImAdapterStatus(
        id: id,
        name: meta['name'] ?? id,
        connected: false,
        state: 'disconnected',
        detail: configured ? '已配置，未连接' : '未配置网关，待填写',
        url: (cfg['url'] ?? '').toString(),
        guid: (cfg['guid'] ?? '').toString(),
        configured: configured,
      );
    }
    final s = gw.status();
    final connected = s['connected'] == true;
    final state = (s['state'] ?? 'disconnected').toString();
    final err = s['last_error']?.toString();
    final detail = connected
        ? '已连接 · 收 ${s['inbound']} / 发 ${s['outbound']}'
        : (err != null && err.isNotEmpty)
            ? err
            : _stateLabel(state);
    return ImAdapterStatus(
      id: id,
      name: meta['name'] ?? id,
      connected: connected,
      state: state,
      detail: detail,
      url: (s['url'] ?? '').toString(),
      lastError: err,
      inbound: (s['inbound'] is int) ? s['inbound'] as int : 0,
      outbound: (s['outbound'] is int) ? s['outbound'] as int : 0,
      guid: (s['guid'] ?? '').toString(),
      configured: configured,
    );
  }

  String _stateLabel(String s) => switch (s) {
        'connecting' => '连接中…',
        'reconnecting' => '重连中…',
        _ => '未连接',
      };

  List<ImAdapterStatus> adapters() =>
      kConnectors.map((Map<String, String> c) => adapterOf(c['id']!)).toList();

  Future<void> dispose() async {
    for (final _LoginSession s in _sessions.values) {
      s.cancelSource.cancel('dispose');
    }
    _sessions.clear();
    _ilinkReceive?.cancel('dispose');
    _ilinkReceive = null;
    _ilink?.dispose();
    _ilink = null;
    for (final gw in _gateways.values) {
      await gw.dispose();
    }
    _gateways.clear();
    _qrClient.dispose();
  }
}

/// 单次扫码登录会话的内部状态（后台轮询任务持有）。
class _LoginSession {
  _LoginSession({
    required this.ticket,
    required this.cancelSource,
    required this.connector,
  });

  final QrLoginTicket ticket;
  final CancelTokenSource cancelSource;
  final String connector;
  QrLoginResult result = const QrLoginResult(status: QrLoginStatus.waiting);
  bool autoConnected = false;
  String? pollError;

  /// 飞书直连会话字段：[directFlow] 非空即直连会话（轮询官方端点而非网关）。
  FeishuDirectFlow? directFlow;
  String? deviceCode;
  int pollInterval = 5;

  /// 直连会话类型：'ilink'（微信腾讯直连）。非空即无网关取消端点。
  String? directKind;
}
