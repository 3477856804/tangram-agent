import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';

/// 更多通信（真实化改造）：
///
/// 1. 紧凑单行渠道列表：官方品牌图标（assets/icons 真实下载）+ 名称 +
///    状态小标签 + 右侧「去授权」；状态来自 im_event{action:'status'}
///    返回的真实网关适配器快照，授权成功后持久化到安全存储。
/// 2. 扫码授权弹窗：点「去授权」永远出一个真实可扫的二维码——
///    飞书优先走官方设备授权流直连（im_event/login_qr 返回真实验证 URL，
///    本地 QrImageView 渲染，扫码即建应用，无需网关）；微信有网关时
///    渲染网关下发的真登录码；未发现网关时渲染「网关部署说明」真实 URL
///    的引导码 + 如实文案 + 手填网关地址即自动重试出码。
///    QQ 是两条真实路径（见 _QqAuthSheet）：①官方机器人——填 AppID/
///    AppSecret 即真实调用官方 getAppAccessToken 验证并连 wss 网关收
///    消息、被动回复；②沙箱网关（NapCat）——保留网关真码扫码流程。
///    全程轮询 login_status；绝不伪造登录二维码或画占位码。
///    「保存到相册」把真实二维码渲染成 PNG 交给系统分享。
class TgaChannelsPage extends StatefulWidget {
  const TgaChannelsPage({super.key});

  /// 每次构建按当前激活色板取值，保证主题切换后颜色即时跟随。
  static List<_Channel> get _channels => <_Channel>[
    _Channel('飞书', 'feishu', Icons.flutter_dash_rounded, Tga.iconCyanBg,
        Tga.iconCyan),
    _Channel('微信', 'wechat', Icons.wechat_rounded, Tga.iconGreenBg,
        Tga.iconGreen),
    _Channel('QQ', 'qq', Icons.chat_bubble_outline_rounded, Tga.iconBlueBg,
        Tga.iconBlue),
  ];

  @override
  State<TgaChannelsPage> createState() => _TgaChannelsPageState();
}

class _TgaChannelsPageState extends State<TgaChannelsPage> {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _authKey = 'tangram.channels.v1';

  /// im_event status 返回的真实适配器快照：connector id -> adapter json。
  Map<String, Map<String, dynamic>> _adapters =
      <String, Map<String, dynamic>>{};

  /// 本地持久化的「曾授权成功」记录（后端不可达时的如实兜底展示）。
  final Set<String> _authorized = <String>{};

  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final String? raw = await _storage.read(key: _authKey);
      if (raw != null && raw.isNotEmpty) {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map) {
          _authorized
            ..clear()
            ..addAll(((decoded['connected'] as List?) ?? <dynamic>[])
                .map((dynamic e) => e.toString()));
        }
      }
    } on Object {
      // 安全存储不可用时仅影响兜底展示。
    }
    await _refreshStatus();
    if (mounted) setState(() => _loading = false);
  }

  /// 安全读取根 Provider：任何情况下都绝不因 Provider 缺失抛出未捕获异常
  /// （未捕获的异步异常在 release 模式会直接终止进程 = 用户看到的崩溃）。
  BackendClient? _safeClient() {
    try {
      if (!mounted) return null;
      return context.read<BackendClient>();
    } on Object {
      return null;
    }
  }

  /// 拉取真实网关连接状态（im_event{action:'status'}）。
  Future<void> _refreshStatus() async {
    final BackendClient? client = _safeClient();
    if (client == null) {
      if (mounted) setState(() => _error = '后端未就绪：稍后点右上角刷新重试');
      return;
    }
    try {
      final BridgeEnvelope env =
          await client.sendControl('im_event', <String, dynamic>{
        'action': 'status',
      });
      final dynamic p = env.payload;
      final Map<String, dynamic> m =
          p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{};
      final List<dynamic> list = m['adapters'] as List? ?? <dynamic>[];
      final Map<String, Map<String, dynamic>> next =
          <String, Map<String, dynamic>>{};
      for (final dynamic a in list) {
        if (a is Map && a['id'] != null) {
          next[a['id'].toString()] = Map<String, dynamic>.from(a);
        }
      }
      if (mounted) setState(() => _adapters = next);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '后端未就绪：$e');
    }
  }

  Future<void> _markAuthorized(String id) async {
    _authorized.add(id);
    try {
      await _storage.write(
          key: _authKey,
          value: jsonEncode(<String, dynamic>{
            'connected': _authorized.toList(),
            'updated_at': DateTime.now().toIso8601String(),
          }));
    } on Object {
      // 落盘失败不影响本次会话展示。
    }
    await _refreshStatus();
  }

  /// 状态标签：优先真实适配器快照；后端不可达时如实标「本地记录」。
  (String, Color) _statusOf(_Channel ch) {
    final Map<String, dynamic>? a = _adapters[ch.id];
    if (a != null) {
      if (a['connected'] == true) return ('已连接', Tga.green);
      final String state = (a['state'] ?? '').toString();
      if (state == 'connecting' || state == 'reconnecting') {
        return ('连接中', Tga.orange);
      }
      if (a['configured'] == true) return ('已配置未连接', Tga.orange);
      return ('未连接', Tga.textSub);
    }
    if (_authorized.contains(ch.id)) return ('已授权(本地记录)', Tga.cyan);
    return ('未连接', Tga.textSub);
  }

  void _showQr(_Channel ch) {
    final BackendClient? client = _safeClient();
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('后端未就绪，暂时无法发起授权')),
      );
      return;
    }
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45), // 列表压暗
      builder: (BuildContext ctx) => ch.id == 'qq'
          // QQ 两条真实路径：官方机器人（AppID/Secret 直连官方端点）
          // 或沙箱网关（NapCat 真码），见 _QqAuthSheet。
          ? _QqAuthSheet(
              client: client,
              channel: ch,
              onConfirmed: () => _markAuthorized(ch.id),
            )
          : _QrAuthSheet(
              client: client,
              channel: ch,
              onConfirmed: () => _markAuthorized(ch.id),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '更多通信',
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: Tga.textSub),
          tooltip: '刷新连接状态',
          onPressed: () => _refreshStatus(),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 24),
        children: <Widget>[
          const TgaGroupTitle('渠道'),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(_error, style: Tga.caption),
            ),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: <Widget>[
                for (int i = 0; i < TgaChannelsPage._channels.length;
                    i++) ...<Widget>[
                  if (i > 0) const TgaTileDivider(),
                  _ChannelRow(
                    channel: TgaChannelsPage._channels[i],
                    status: _loading
                        ? ('检测中…', Tga.textDim)
                        : _statusOf(TgaChannelsPage._channels[i]),
                    onAuthorize: () => _showQr(TgaChannelsPage._channels[i]),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Channel {
  const _Channel(this.name, this.id, this.icon, this.bg, this.fg);
  final String name, id;
  final IconData icon;
  final Color bg, fg;
}

/// 紧凑单行：图标 + 名称 + 状态标签 + 右侧「去授权」。
class _ChannelRow extends StatelessWidget {
  const _ChannelRow(
      {required this.channel, required this.status, required this.onAuthorize});
  final _Channel channel;
  final (String, Color) status;
  final VoidCallback onAuthorize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration:
                BoxDecoration(color: channel.bg, shape: BoxShape.circle),
            child: _BrandIcon(channel: channel, size: 22),
          ),
          const SizedBox(width: 12),
          Text(channel.name, style: Tga.body),
          const SizedBox(width: 8),
          TgaTag(status.$1, color: status.$2),
          const Spacer(),
          TgaButton(label: '去授权', onTap: onAuthorize, filled: false),
        ],
      ),
    );
  }
}

/// 官方品牌图标：assets/icons/<id>.png 真实下载的品牌 logo；
/// 资源缺失/损坏时如实回退 Material 图标。
class _BrandIcon extends StatelessWidget {
  const _BrandIcon({required this.channel, required this.size});
  final _Channel channel;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icons/${channel.id}.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
          Icon(channel.icon, size: size * 0.72, color: channel.fg),
    );
  }
}

// ---------------------------------------------------------------------------
// 扫码授权弹窗（真实网关二维码 + 轮询 + 成功持久化）
// embedded=true 时只渲染内容区（供 QQ 双路径弹窗内嵌 NapCat 扫码页）
// ---------------------------------------------------------------------------
class _QrAuthSheet extends StatefulWidget {
  const _QrAuthSheet(
      {required this.client,
      required this.channel,
      required this.onConfirmed,
      this.embedded = false});
  final BackendClient client;
  final _Channel channel;
  final Future<void> Function() onConfirmed;
  final bool embedded;

  @override
  State<_QrAuthSheet> createState() => _QrAuthSheetState();
}

class _QrAuthSheetState extends State<_QrAuthSheet> {
  static const int _qrSize = 190;
  final GlobalKey _qrKey = GlobalKey();

  String _content = '';
  Uint8List? _image;
  String _status = 'loading'; // loading / waiting / scanned / confirmed / error
  String _error = '';
  Timer? _timer;
  bool _persisted = false;

  /// 真码有效期倒计时（腾讯 iLink 真码 5 分钟有效；网关码同样按
  /// expires_in 如实倒计时）。归零即过期，出「要新码」按钮。
  int _remaining = 0;
  Timer? _cdTimer;
  bool _expired = false;

  bool get _needsNewCode => _expired || _status == 'error';

  /// 无网关引导模式：二维码内容是网关部署说明的真实 URL（不是伪造登录码），
  /// 下方给出如实文案 + 手填网关地址入口（填了自动重试出码）。
  bool _guide = false;
  String _guideText = '';
  final TextEditingController _gwCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _requestQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _cdTimer?.cancel();
    _gwCtl.dispose();
    super.dispose();
  }

  /// 出码成功后开始 5 分钟倒计时；归零即标记过期并停轮询。
  void _startCountdown(int seconds) {
    _cdTimer?.cancel();
    _expired = false;
    _remaining = seconds <= 0 ? 300 : seconds;
    _cdTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        if (_remaining > 0) _remaining -= 1;
        if (_remaining == 0) {
          _expired = true;
          _timer?.cancel();
          _error = '真码 5 分钟已到期，点「要新码」重新取一张';
        }
      });
    });
  }

  Map<String, dynamic> _map(BridgeEnvelope env) {
    final dynamic p = env.payload;
    return p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{};
  }

  /// 网关错误如实转述；明显不支持的渠道给出人话提示，不抛堆栈。
  String _friendlyError(String raw) {
    if (raw.contains('404') || raw.contains('not found')) {
      return '该渠道暂不支持扫码授权（网关未提供对应登录端点）';
    }
    return raw;
  }

  Future<void> _requestQr({String? gatewayUrl}) async {
    _timer?.cancel();
    _cdTimer?.cancel();
    setState(() {
      _status = 'loading';
      _error = '';
      _guide = false;
      _guideText = '';
      _expired = false;
      _remaining = 0;
    });
    try {
      final BridgeEnvelope env = await widget.client.sendControl(
        'im_event',
        <String, dynamic>{
          'action': 'login_qr',
          'connector': widget.channel.id,
          if (gatewayUrl != null) 'url': gatewayUrl,
        },
      );
      final Map<String, dynamic> m = _map(env);
      if (m['ok'] != true) {
        if (!mounted) return;
        setState(() {
          _status = 'error';
          _error = _friendlyError(
              (m['error'] ?? '网关未返回二维码').toString());
        });
        return;
      }
      // 无网关的如实引导结果：渲染部署说明真实 URL，不轮询登录状态。
      if (m['guide'] == true) {
        if (!mounted) return;
        setState(() {
          _guide = true;
          _guideText = (m['guide_text'] ?? '未发现网关，扫码查看部署说明')
              .toString();
          _content = (m['qr_content'] ?? '').toString();
          _image = null;
          _status = 'waiting';
        });
        return;
      }
      if (m['already_logged_in'] == true ||
          (m['status'] ?? '').toString() == 'confirmed') {
        if (!mounted) return;
        await _onConfirmed();
        return;
      }
      final String content = (m['qr_content'] ?? '').toString();
      Uint8List? img;
      final String? b64 = m['qr_image_base64']?.toString();
      if (b64 != null && b64.isNotEmpty) {
        try {
          img = base64Decode(b64);
        } on Object {
          img = null;
        }
      }
      if (content.isEmpty && img == null) {
        if (!mounted) return;
        setState(() {
          _status = 'error';
          _error = '网关未返回二维码内容';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _content = content;
        _image = img;
        _status = 'waiting';
      });
      final int ttl =
          (m['expires_in'] is num) ? (m['expires_in'] as num).toInt() : 300;
      _startCountdown(ttl);
      _timer = Timer.periodic(const Duration(seconds: 1), (Timer _) => _poll());
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'error';
        _error = '无法连接网关：$e';
      });
    }
  }

  Future<void> _poll() async {
    Map<String, dynamic> m = <String, dynamic>{};
    try {
      final BridgeEnvelope env = await widget.client.sendControl(
        'im_event',
        <String, dynamic>{
          'action': 'login_status',
          'connector': widget.channel.id,
        },
      );
      m = _map(env);
    } on Object {
      return;
    }
    if (!mounted) return;
    final String s = (m['status'] ?? 'waiting').toString();
    if (s == 'confirmed') {
      _timer?.cancel();
      await _onConfirmed();
    } else if (s == 'expired' || s == 'error') {
      _timer?.cancel();
      _cdTimer?.cancel();
      setState(() {
        _status = 'error';
        _expired = s == 'expired';
        _error = s == 'expired'
            ? '真码已过期，点「要新码」重新获取'
            : _friendlyError(m['error']?.toString() ?? _error);
      });
    } else if (s == 'scanned' && _status != 'scanned') {
      setState(() => _status = 'scanned');
    }
  }

  /// 授权成功：状态标签变「已连接」并持久化，再刷新真实网关快照。
  Future<void> _onConfirmed() async {
    setState(() => _status = 'confirmed');
    if (!_persisted) {
      _persisted = true;
      await widget.onConfirmed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 平台官方图标 + 标题（内嵌模式由外层 QQ 弹窗统一出标题）
        if (!widget.embedded) ...<Widget>[
          Container(
            width: 46,
            height: 46,
            decoration:
                BoxDecoration(color: widget.channel.bg, shape: BoxShape.circle),
            child: _BrandIcon(channel: widget.channel, size: 26),
          ),
          const SizedBox(height: 10),
          Text('${widget.channel.name}授权', style: Tga.h2),
        ],
        const SizedBox(height: 18),
        // 二维码区域
        RepaintBoundary(
          key: _qrKey,
          child: Container(
            width: _qrSize.toDouble() + 20,
            height: _qrSize.toDouble() + 20,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Tga.border),
            ),
            alignment: Alignment.center,
            child: _buildQr(),
          ),
        ),
        const SizedBox(height: 14),
        Text(_hint(), style: Tga.sub, textAlign: TextAlign.center),
        // 引导模式：手填网关地址入口，填了自动重试出码。
        if (_guide)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Tga.bgSoft,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12),
                    child: TextField(
                      controller: _gwCtl,
                      keyboardType: TextInputType.url,
                      style: TextStyle(fontSize: 13, color: Tga.text),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'ws://192.168.x.x:50432',
                        hintStyle:
                            TextStyle(fontSize: 13, color: Tga.textDim),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _retryWithGateway,
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: Tga.primary,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    alignment: Alignment.center,
                    child: Text('填写并重试出码',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Tga.onPrimary)),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        // 取消 / 要新码（过期或失败时）/ 保存到相册（有码时）
        Row(
          children: <Widget>[
            Expanded(
              child: GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: Tga.bgSoft,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Text('取消',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Tga.textSub)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: GestureDetector(
                onTap: _needsNewCode
                    ? () => _requestQr(
                        gatewayUrl: _gwCtl.text.trim().isEmpty
                            ? null
                            : _gwCtl.text.trim())
                    : (_hasQr ? _saveToAlbum : null),
                child: Container(
                  height: 40,
                  decoration: BoxDecoration(
                    color: _needsNewCode
                        ? Tga.primary
                        : (_hasQr ? Tga.primary : Tga.bgSoft),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                      _needsNewCode
                          ? '要新码'
                          : '保存到相册',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _needsNewCode || _hasQr
                              ? Tga.onPrimary
                              : Tga.textDim)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
    if (widget.embedded) return content;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: Container(
        decoration: BoxDecoration(
          color: Tga.card,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: content,
      ),
    );
  }

  bool get _hasQr => _content.isNotEmpty || _image != null;

  String _hint() {
    if (_guide) return _guideText;
    if (_expired) {
      return _error.isEmpty ? '真码 5 分钟已到期，点「要新码」重新取一张' : _error;
    }
    switch (_status) {
      case 'scanned':
        return '已扫码，请在手机上确认授权';
      case 'confirmed':
        return '授权成功，连接已建立';
      case 'error':
        return _error.isEmpty ? '暂时拿不到二维码' : _error;
      default:
        if (widget.channel.id == 'wechat') {
          return '腾讯 iLink 刚发的真码，有效 ${_remaining}s；'
              '扫完在微信里发条消息就是真链路';
        }
        if (widget.channel.id == 'feishu') {
          return '请用飞书 App 扫码并确认——官方设备授权，扫码即自动创建 bot 应用';
        }
        return '请使用${widget.channel.name}扫码并确认授权'
            '（真码有效 ${_remaining}s）';
    }
  }

  /// 引导模式：手填网关地址后立即重试出码（login_qr 带 url 会跳过局域网
  /// 发现并在后端落盘，下次免填）。
  Future<void> _retryWithGateway() async {
    final String url = _gwCtl.text.trim();
    if (url.isEmpty) {
      setState(() {
        _guide = false;
        _status = 'error';
        _error = '请先填写网关地址（ws:// 或 http:// 开头，im.serve 默认端口 50432）';
      });
      return;
    }
    await _requestQr(gatewayUrl: url);
  }

  Widget _buildQr() {
    switch (_status) {
      case 'loading':
        return SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Tga.primary),
        );
      case 'confirmed':
        return Icon(Icons.check_circle_rounded,
            size: 62, color: Tga.green);
      case 'error':
        return Icon(Icons.link_off_rounded,
            size: 42, color: Tga.orange);
      default:
        if (_image != null) {
          return Image.memory(_image!,
              width: _qrSize.toDouble(),
              height: _qrSize.toDouble(),
              fit: BoxFit.contain,
              errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                  Icon(Icons.broken_image_rounded,
                      size: 42, color: Tga.orange));
        }
        return QrImageView(
          data: _content,
          version: QrVersions.auto,
          size: _qrSize.toDouble(),
          backgroundColor: Colors.white,
          gapless: false,
        );
    }
  }

  /// 把真实二维码渲染成 PNG 并交给系统分享面板（用户可从中保存到相册）。
  /// 无二维码时按钮置灰，不会保存占位图；截的是网关下发的真码，不是伪造图。
  Future<void> _saveToAlbum() async {
    if (!_hasQr) return;
    try {
      // 截取当前展示的二维码 widget（含网关下发图片或 QrImageView 渲染的真码）。
      final RenderRepaintBoundary boundary = _qrKey.currentContext!
          .findRenderObject()! as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('二维码渲染失败');
      final Uint8List bytes = data.buffer.asUint8List();

      final Directory dir = await getTemporaryDirectory();
      final File file = File(
          '${dir.path}/tga_${widget.channel.id}_qr_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(bytes, flush: true);
      // 系统分享面板里选择「保存到相册 / 文件」；不落地到代码库、不写入凭据。
      await Share.shareXFiles(<XFile>[
        XFile(file.path, mimeType: 'image/png'),
      ], subject: '${widget.channel.name}授权二维码');
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
    }
  }
}

// ---------------------------------------------------------------------------
// QQ 授权弹窗：两条真实路径
//  ① 官方机器人：填 AppID/AppSecret → 真实调用 QQ 官方
//     bots.qq.com/app/getAppAccessToken 验证（成功=官方真实签发 token，
//     落 App 私有目录 qq_official.json）→ 再真实连 api.sgroup.qq.com
//     wss 网关（HELLO/IDENTIFY/READY+心跳）；收到 C2C/群@ 事件走真实
//     推理并以 v2 被动回复 API 回发。协议对齐官方开源 SDK botpy。
//  ② 沙箱网关（NapCat）：保留原 im_event{action:'login_qr'} 真码流程
//     （内嵌 _QrAuthSheet，网关在跑时出 NapCat 真登录码）。
// 状态标签只认真实 token / 网关状态，UI 绝不假绿。
// ---------------------------------------------------------------------------
class _QqAuthSheet extends StatefulWidget {
  const _QqAuthSheet(
      {required this.client, required this.channel, required this.onConfirmed});
  final BackendClient client;
  final _Channel channel;
  final Future<void> Function() onConfirmed;

  @override
  State<_QqAuthSheet> createState() => _QqAuthSheetState();
}

class _QqAuthSheetState extends State<_QqAuthSheet> {
  int _tab = 0; // 0=官方机器人 1=沙箱网关(NapCat)

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
      child: Container(
        decoration: BoxDecoration(
          color: Tga.card,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 46,
                height: 46,
                decoration:
                    BoxDecoration(color: widget.channel.bg, shape: BoxShape.circle),
                child: _BrandIcon(channel: widget.channel, size: 26),
              ),
              const SizedBox(height: 10),
              Text('${widget.channel.name}授权', style: Tga.h2),
              const SizedBox(height: 14),
              // 两条路径切换
              Container(
                decoration: BoxDecoration(
                  color: Tga.bgSoft,
                  borderRadius: BorderRadius.circular(11),
                ),
                padding: const EdgeInsets.all(3),
                child: Row(
                  children: <Widget>[
                    _tabChip(0, '官方机器人'),
                    _tabChip(1, '沙箱网关（NapCat）'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_tab == 0)
                _QqOfficialBody(
                  client: widget.client,
                  onConfirmed: widget.onConfirmed,
                )
              else
                _QrAuthSheet(
                  client: widget.client,
                  channel: widget.channel,
                  onConfirmed: widget.onConfirmed,
                  embedded: true,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabChip(int idx, String label) {
    final bool active = _tab == idx;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = idx),
        child: Container(
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? Tga.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: active ? Tga.onPrimary : Tga.textSub)),
        ),
      ),
    );
  }
}

/// 官方机器人路径：真实验证 + 真实网关状态展示。
class _QqOfficialBody extends StatefulWidget {
  const _QqOfficialBody(
      {required this.client, required this.onConfirmed});
  final BackendClient client;
  final Future<void> Function() onConfirmed;

  @override
  State<_QqOfficialBody> createState() => _QqOfficialBodyState();
}

class _QqOfficialBodyState extends State<_QqOfficialBody> {
  /// QQ 开放平台真实入口（官方文档站 bot.q.qq.com 现 302 到 q.qq.com，
  /// 机器人创建与「开发设置」里的 AppID/AppSecret 都在这里）。
  static const String _consoleUrl = 'https://q.qq.com/';
  static const String _docsUrl = 'https://bot.q.qq.com/wiki/develop/api-v2/';

  final TextEditingController _appIdCtl = TextEditingController();
  final TextEditingController _secretCtl = TextEditingController();
  bool _obscure = true;
  bool _sandbox = false;
  bool _saving = false;
  bool _loading = true;

  /// qq_official_status 返回的真实快照（token/网关状态均来自官方应答）。
  Map<String, dynamic> _snap = <String, dynamic>{};
  String _detail = '';
  String _result = '';
  bool? _resultOk;

  @override
  void initState() {
    super.initState();
    _fetchStatus();
  }

  @override
  void dispose() {
    _appIdCtl.dispose();
    _secretCtl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _map(BridgeEnvelope env) {
    final dynamic p = env.payload;
    return p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{};
  }

  Future<void> _fetchStatus() async {
    try {
      final BridgeEnvelope env =
          await widget.client.sendControl('im_event', <String, dynamic>{
        'action': 'qq_official_status',
      });
      final Map<String, dynamic> m = _map(env);
      if (!mounted) return;
      setState(() {
        _snap = m['status'] is Map
            ? Map<String, dynamic>.from(m['status'] as Map)
            : <String, dynamic>{};
        _detail = (m['detail'] ?? '').toString();
        _loading = false;
        final String savedAppId = (_snap['app_id'] ?? '').toString();
        if (savedAppId.isNotEmpty && _appIdCtl.text.isEmpty) {
          _appIdCtl.text = savedAppId;
          _sandbox = _snap['sandbox'] == true;
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _result = '读取官方机器人状态失败：$e';
        _resultOk = null;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _result = '';
      _resultOk = null;
    });
    try {
      final BridgeEnvelope env =
          await widget.client.sendControl('im_event', <String, dynamic>{
        'action': 'qq_official_save',
        'app_id': _appIdCtl.text.trim(),
        'client_secret': _secretCtl.text.trim(),
        'sandbox': _sandbox,
      });
      final Map<String, dynamic> m = _map(env);
      if (!mounted) return;
      if (m['ok'] == true) {
        final int ttl = (m['token_expires_in'] is num)
            ? (m['token_expires_in'] as num).toInt()
            : 0;
        setState(() {
          _resultOk = true;
          _result = m['gateway_ready'] == true
              ? '验证成功：官方 bots.qq.com 已签发 access_token（${ttl}s 有效），'
                  '网关 wss 已连接（READY）。QQ 里给机器人发消息即真实回复。'
              : '验证成功：官方 bots.qq.com 已签发 access_token（${ttl}s 有效）。'
                  '但网关暂未连上：${m['gateway_error'] ?? '未知原因'}'
                  '——token 为真，稍后自动重试。';
        });
        await widget.onConfirmed();
        await _fetchStatus();
      } else {
        setState(() {
          _resultOk = false;
          _result = (m['error'] ?? '官方验证未通过').toString();
        });
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = '验证请求失败：$e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('打开失败：$e')));
      }
    }
  }

  (String, Color) _liveTag() {
    if (_loading) return ('检测中…', Tga.textDim);
    final bool hasCred = _snap['has_cred'] == true;
    if (!hasCred) return ('未配置', Tga.textSub);
    if (_snap['gateway_ready'] == true) return ('已连接', Tga.green);
    if (_snap['token_valid'] == true) return ('已连接', Tga.green);
    return ('token 已过期', Tga.orange);
  }

  @override
  Widget build(BuildContext context) {
    final (String tag, Color tagColor) = _liveTag();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 真实状态行：只来自官方 token / 网关状态快照
        Row(
          children: <Widget>[
            TgaTag(tag, color: tagColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _detail.isNotEmpty
                    ? _detail
                    : (_snap['has_cred'] == true
                        ? '凭据已存本机'
                        : '尚未配置官方机器人凭据'),
                style: Tga.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('在 QQ 开放平台创建机器人，拿到 AppID / AppSecret 填入即可——'
            '保存时会真实调用官方 getAppAccessToken 端点验证，'
            '验证通过才算「已连接」，本应用绝不假绿。',
            style: Tga.sub),
        const SizedBox(height: 6),
        Wrap(
          spacing: 10,
          children: <Widget>[
            _linkChip('开放平台 q.qq.com', _consoleUrl),
            _linkChip('APIv2 文档', _docsUrl),
          ],
        ),
        const SizedBox(height: 12),
        _field(_appIdCtl, 'AppID（机器人唯一标识，纯数字）',
            keyboard: TextInputType.number),
        const SizedBox(height: 8),
        _field(_secretCtl, 'AppSecret（开发设置页获取）', obscure: _obscure,
            suffix: IconButton(
              icon: Icon(_obscure ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 18, color: Tga.textDim),
              onPressed: () => setState(() => _obscure = !_obscure),
            )),
        const SizedBox(height: 4),
        CheckboxListTile(
          value: _sandbox,
          onChanged: (bool? v) => setState(() => _sandbox = v ?? false),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          title: Text('沙箱环境（机器人未发布时，官方要求先走 '
              'sandbox.api.sgroup.qq.com + 沙箱成员/群测试）',
              style: Tga.caption),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: _saving ? null : _save,
          child: Container(
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _saving ? Tga.bgSoft : Tga.primary,
              borderRadius: BorderRadius.circular(11),
            ),
            child: _saving
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Tga.primary),
                  )
                : Text('保存并真实验证',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Tga.onPrimary)),
          ),
        ),
        if (_result.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 0),
            child: Text(_result,
                style: Tga.sub.copyWith(
                    color: _resultOk == true
                        ? Tga.green
                        : (_resultOk == false ? Tga.orange : Tga.textSub))),
          ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Tga.bgSoft,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text(
            '当前已打通：官方 token 验证 · wss 网关事件接收（群@/私聊）· '
            '收到消息后真实推理并被动回复（msg_id 20 分钟内有效）。'
            '主动消息需平台开通对应消息权限，群列表拉取需用户级 OAuth 授权，'
            '本应用如实呈现边界、不伪造全链路。',
            style: Tga.caption,
          ),
        ),
      ],
    );
  }

  Widget _linkChip(String label, String url) {
    return GestureDetector(
      onTap: () => _open(url),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Tga.bgSoft,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: Tga.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.open_in_new_rounded, size: 14, color: Tga.cyan),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(fontSize: 12, color: Tga.cyan)),
          ],
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctl, String hint,
      {TextInputType? keyboard, bool obscure = false, Widget? suffix}) {
    return Container(
      decoration: BoxDecoration(
        color: Tga.bgSoft,
        borderRadius: BorderRadius.circular(11),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: ctl,
              obscureText: obscure,
              keyboardType: keyboard,
              style: TextStyle(fontSize: 13, color: Tga.text),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(fontSize: 13, color: Tga.textDim),
              ),
            ),
          ),
          if (suffix != null) suffix,
        ],
      ),
    );
  }
}
