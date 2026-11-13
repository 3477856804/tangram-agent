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
///    本地 QrImageView 渲染，扫码即建应用，无需网关）；微信/QQ 有网关时
///    渲染网关下发的真登录码；未发现网关时渲染「网关部署说明」真实 URL
///    的引导码 + 如实文案 + 手填网关地址即自动重试出码。
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
        _authorized
          ..clear()
          ..addAll(((jsonDecode(raw) as Map)['connected'] as List? ?? [])
              .map((dynamic e) => e.toString()));
      }
    } on Object {
      // 安全存储不可用时仅影响兜底展示。
    }
    await _refreshStatus();
    if (mounted) setState(() => _loading = false);
  }

  /// 拉取真实网关连接状态（im_event{action:'status'}）。
  Future<void> _refreshStatus() async {
    final BackendClient client = context.read<BackendClient>();
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
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45), // 列表压暗
      builder: (BuildContext ctx) => _QrAuthSheet(
        client: context.read<BackendClient>(),
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
// ---------------------------------------------------------------------------
class _QrAuthSheet extends StatefulWidget {
  const _QrAuthSheet(
      {required this.client, required this.channel, required this.onConfirmed});
  final BackendClient client;
  final _Channel channel;
  final Future<void> Function() onConfirmed;

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
    _gwCtl.dispose();
    super.dispose();
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
    setState(() {
      _status = 'loading';
      _error = '';
      _guide = false;
      _guideText = '';
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
      setState(() {
        _status = 'error';
        _error = s == 'expired'
            ? '二维码已过期，请重新获取'
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
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: Container(
        decoration: BoxDecoration(
          color: Tga.card,
          borderRadius: BorderRadius.circular(20),
        ),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            // 平台官方图标 + 标题
            Container(
              width: 46,
              height: 46,
              decoration:
                  BoxDecoration(color: widget.channel.bg, shape: BoxShape.circle),
              child: _BrandIcon(channel: widget.channel, size: 26),
            ),
            const SizedBox(height: 10),
            Text('${widget.channel.name}授权', style: Tga.h2),
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
            // 取消 / 保存到相册
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
                    onTap: _hasQr ? _saveToAlbum : null,
                    child: Container(
                      height: 40,
                      decoration: BoxDecoration(
                        color: _hasQr ? Tga.primary : Tga.bgSoft,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      alignment: Alignment.center,
                      child: Text('保存到相册',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _hasQr ? Tga.onPrimary : Tga.textDim)),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool get _hasQr => _content.isNotEmpty || _image != null;

  String _hint() {
    if (_guide) return _guideText;
    switch (_status) {
      case 'scanned':
        return '已扫码，请在手机上确认授权';
      case 'confirmed':
        return '授权成功，连接已建立';
      case 'error':
        return _error.isEmpty ? '暂时拿不到二维码' : _error;
      default:
        if (widget.channel.id == 'feishu') {
          return '请用飞书 App 扫码并确认——官方设备授权，扫码即自动创建 bot 应用';
        }
        return '请使用${widget.channel.name}扫码并确认授权';
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
              fit: BoxFit.contain);
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
