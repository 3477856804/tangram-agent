/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/bridge/bridge_protocol.dart';
import 'package:tangram/harness/im_service.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/ui/panels/async_panel_mixin.dart';
import 'package:tangram/ui/social_gateway.dart';

/// 更多通信：QQ / 微信 / 飞书连接器。
///
/// 真实接入：扫码登录走仓库自带网关 `im/serve.py` 的 REST 端点
/// （`/api/login/wechat/qr` 等，二维码由腾讯 iLink / NapCat 真实下发），
/// 登录成功后网关回传 AGP WebSocket 地址与凭据，底层走 OpenClaw AGP 协议
/// （见 harness/agp_protocol.dart、im_gateway.dart、im_service.dart）建立
/// 真实连接。消息经端侧真实模型推理后原样发回，状态与收发计数全部来自
/// 真实 socket，绝不谎称已连接，也绝不本地伪造二维码。
class PersonalIMPanel extends StatefulWidget {
  const PersonalIMPanel({super.key});

  @override
  State<PersonalIMPanel> createState() => _PersonalIMPanelState();
}

class _PersonalIMPanelState extends State<PersonalIMPanel>
    with AsyncPanelMixin {
  final List<Map<String, dynamic>> _adapters = <Map<String, dynamic>>[];
  final TextEditingController _urlCtrl =
      TextEditingController(text: kDefaultGatewayUrl);
  final TextEditingController _guidCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();
  String _connector = 'wechat';
  String? _notice;
  bool _configExpanded = false;

  static const List<Map<String, String>> _connectors =
      <Map<String, String>>[
    <String, String>{'id': 'wechat', 'name': '微信'},
    <String, String>{'id': 'qq', 'name': 'QQ'},
    <String, String>{'id': 'feishu', 'name': '飞书'},
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _guidCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env = await backend.sendControl('im_event', <String, dynamic>{
          'action': 'list_adapters',
        });
        _readAdapters(env);
      });

  void _readAdapters(BridgeEnvelope env) {
    final payload = env.payload;
    if (payload is Map && payload['adapters'] is List) {
      _adapters
        ..clear()
        ..addAll((payload['adapters'] as List)
            .whereType<Map>()
            .map((Map<dynamic, dynamic> a) => Map<String, dynamic>.from(a)));
    }
  }

  /// 手填优先；留空时回退到构建注入的默认网关（未注入则为空，
  /// 由调用方明确提示用户先启动并填写网关，不拿死链冒充内置网关）。
  String _effectiveUrl() {
    final String v = _urlCtrl.text.trim();
    return v.isEmpty ? kDefaultGatewayUrl : v;
  }

  static const String _noGatewayHint =
      '未找到网关：请确认电脑上的网关已启动且与手机在同一 WiFi；'
      '或展开下方手动填写地址。';

  Future<void> _loadConfig(String connector) => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env = await backend.sendControl('im_event', <String, dynamic>{
          'action': 'get_config',
          'connector': connector,
        });
        final payload = env.payload;
        if (payload is Map && payload['config'] is Map) {
          final c = Map<String, dynamic>.from(payload['config'] as Map);
          // 只有保存过自定义网关才覆盖；未配置时保留当前输入，别把输入框清空。
          final String saved = (c['url'] ?? '').toString().trim();
          if (saved.isNotEmpty) _urlCtrl.text = saved;
          _guidCtrl.text = (c['guid'] ?? '').toString();
          _tokenCtrl.text = (c['token'] ?? '').toString();
        }
      });

  Future<void> _applyAndConnect() => runGuarded(() async {
        if (_effectiveUrl().isEmpty) {
          setState(() => _notice = _noGatewayHint);
          return;
        }
        final backend = context.read<BackendClient>();
        // 先落盘配置再直接拉起扫码弹窗，无需先建 AGP 连接。
        await backend.sendControl('im_event', <String, dynamic>{
          'action': 'configure',
          'connector': _connector,
          'url': _effectiveUrl(),
          'guid': _guidCtrl.text.trim(),
          'token': _tokenCtrl.text.trim(),
        });
        await _openQrLogin(_connector);
      });

  /// 连接器行里的「连接」= 直接弹出真二维码；扫码确认后由 ImService
  /// 自动落盘凭据并建立 AGP WebSocket 连接，不需要用户手填任何地址。
  Future<void> _connectOne(String id) => _openQrLogin(id);

  Future<void> _disconnect(String id) => runGuarded(() async {
        final backend = context.read<BackendClient>();
        final env = await backend.sendControl('im_event', <String, dynamic>{
          'action': 'disconnect',
          'connector': id,
        });
        _notice = '已断开 $id';
        _readAdapters(env);
      });

  /// 打开扫码接入弹窗：向网关申请真实登录二维码。
  /// 弹窗关闭后刷新适配器状态（扫码成功时可能已自动建立连接）。
  Future<void> _openQrLogin([String? connector]) async {
    // 零配置：即使未填网关地址，也直接打开扫码弹窗。ImService 会先在局域网
    // 自动发现网关；只有发现失败才在弹窗内给出「手动填写」的引导。
    final BackendClient backend = context.read<BackendClient>();
    final String id = connector ?? _connector;
    final String name = _connectors.firstWhere(
      (Map<String, String> c) => c['id'] == id,
      orElse: () => <String, String>{'name': id},
    )['name'] ??
        id;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => QrLoginSheet(
        client: backend,
        connector: id,
        connectorName: name,
        gatewayUrl: _effectiveUrl(),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final int connected =
        _adapters.where((Map<String, dynamic> a) => a['connected'] == true).length;
    return PanelPage(
      children: <Widget>[
        SectionTitle(
          title: '更多通信',
          subtitle: 'QQ / 微信 / 飞书',
          icon: Icons.forum_outlined,
          accent: TangramColors.jade,
          trailing: StatusPill(
            label: '$connected / ${_adapters.length} 已连接',
            color: connected > 0
                ? TangramColors.success
                : TangramColors.textMuted,
            dense: true,
          ),
        ),
        buildStatusBlock(),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(top: TangramSpacing.sm),
            child: Text(
              _notice!,
              style: const TextStyle(
                  color: TangramColors.textSecondary, fontSize: 12),
            ),
          ),
        const SizedBox(height: TangramSpacing.md),

        // ---- 真实网关配置 ----
        SectionTitle(
          title: '网关配置',
          subtitle: '一般无需填写，自动发现失败时再用',
          icon: Icons.settings_ethernet,
          accent: TangramColors.gold,
          trailing: IconButton(
            icon: Icon(_configExpanded ? Icons.expand_less : Icons.expand_more),
            onPressed: () =>
                setState(() => _configExpanded = !_configExpanded),
          ),
        ),
        GlassCard(
          padding: const EdgeInsets.all(TangramSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (_configExpanded) ...<Widget>[
                DropdownButtonFormField<String>(
                  value: _connector,
                  decoration: const InputDecoration(
                    labelText: '连接器',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: _connectors
                      .map((Map<String, String> c) =>
                          DropdownMenuItem<String>(
                            value: c['id'],
                            child: Text(c['name'] ?? ''),
                          ))
                      .toList(),
                  onChanged: (String? v) {
                    if (v == null) return;
                    setState(() => _connector = v);
                    _loadConfig(v);
                  },
                ),
                const SizedBox(height: TangramSpacing.sm),
                TextField(
                  controller: _urlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '网关地址',
                    hintText: 'https://域名 或 http://IP:50432',
                    border: OutlineInputBorder(),
                    isDense: true,
                    prefixIcon: Icon(Icons.link, size: 18),
                  ),
                ),
                // 空态下 TextField 只显示 label、不显示 hint，格式示例改为常显，
                // 避免用户不知道该填什么。
                const Padding(
                  padding: EdgeInsets.only(top: 5, left: 2),
                  child: Text(
                    '仅当自动发现失败时才需手填：网关在电脑上运行并开启局域网广播后，'
                    '点「连接」即可自动找到。跨网段可填 http://电脑IP:50432',
                    style: TextStyle(
                        color: TangramColors.textCaption,
                        fontSize: 11,
                        height: 1.4),
                  ),
                ),
                const SizedBox(height: TangramSpacing.sm),
                TextField(
                  controller: _guidCtrl,
                  decoration: const InputDecoration(
                    labelText: 'GUID（可选）',
                    hintText: '设备标识',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: TangramSpacing.sm),
                TextField(
                  controller: _tokenCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Token（可选）',
                    hintText: '网关鉴权令牌',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: TangramSpacing.md),
              ] else
                const Text(
                  '直接点下方「连接」即可：同一 WiFi 下会自动找到电脑上的网关并弹出二维码，'
                  '无需填写任何地址。',
                  style: TextStyle(
                      color: TangramColors.textSecondary,
                      fontSize: 12,
                      height: 1.5),
                ),
              const SizedBox(height: TangramSpacing.md),
              Wrap(
                spacing: TangramSpacing.sm,
                runSpacing: TangramSpacing.sm,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: loading
                        ? null
                        : () {
                            setState(() => _configExpanded = true);
                            _applyAndConnect();
                          },
                    icon: const Icon(Icons.power, size: 16),
                    label: const Text('保存并扫码'),
                  ),
                  OutlinedButton.icon(
                    onPressed: loading ? null : _load,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('刷新状态'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: TangramSpacing.md),

        // ---- 扫码接入：点一下就向网关申请真二维码 ----
        _QrLoginCard(
          connector: _connector,
          onConnectorChanged: (String v) {
            setState(() => _connector = v);
            _loadConfig(v);
          },
          onStart: () => _openQrLogin(_connector),
        ),
        const SizedBox(height: TangramSpacing.md),
        // 真实接入路径说明：把「部署网关 → 扫码 → 下载小模型」串成一条路径。
        const _ConnectGuideCard(),
        const SizedBox(height: TangramSpacing.xl),

        // ---- 连接器真实状态 ----
        const SectionTitle(
          title: '连接器',
          subtitle: '连接状态与收发计数',
          icon: Icons.link_outlined,
        ),
        ..._adapters.map((Map<String, dynamic> a) {
          final online = a['connected'] == true;
          final id = (a['id'] ?? '').toString();
          final name = (a['name'] ?? id).toString();
          final detail = (a['status'] ?? a['detail'] ?? '').toString();
          final inbound = a['inbound'] ?? 0;
          final outbound = a['outbound'] ?? 0;
          return Padding(
            padding: const EdgeInsets.only(bottom: TangramSpacing.sm),
            child: InfoTile(
              icon: online ? Icons.link : Icons.link_off,
              title: name,
              subtitle: '$detail · 收 $inbound / 发 $outbound',
              color: online ? TangramColors.success : TangramColors.textMuted,
              trailing: online
                  ? TextButton(
                      onPressed: loading ? null : () => _disconnect(id),
                      child: const Text('断开'),
                    )
                  : TextButton(
                      onPressed: loading ? null : () => _connectOne(id),
                      child: const Text('连接'),
                    ),
            ),
          );
        }),
        if (_adapters.isEmpty)
          const Padding(
            padding: EdgeInsets.all(TangramSpacing.md),
            child: Text(
              '正在读取连接状态…',
              style: TextStyle(color: TangramColors.textMuted, fontSize: 12),
            ),
          ),
        const SizedBox(height: TangramSpacing.xl),
        const SocialShareSection(),
      ],
    );
  }
}

/// 接入指引：把「点连接出码 → 扫码 → 下载小模型」串成三步。
/// 网关地址已内置，全部是真实操作说明，不含虚构的「一键登录 / 已连接」状态。
class _ConnectGuideCard extends StatelessWidget {
  const _ConnectGuideCard();

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(TangramSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: const <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.help_outline, size: 16, color: TangramColors.gold),
              SizedBox(width: TangramSpacing.sm),
              Text(
                '接入微信 / QQ 三步',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TangramColors.textPrimary,
                ),
              ),
            ],
          ),
          SizedBox(height: TangramSpacing.sm),
          _GuideStep(
            '1',
            '直接点「连接」或「获取登录二维码」',
          ),
          _GuideStep(
            '2',
            '用手机微信/QQ 扫码并确认，确认后自动连接',
          ),
          _GuideStep(
            '3',
            '下载模型并在聊天页选中，就能发消息了',
          ),
        ],
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep(this.no, this.text);

  final String no;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: TangramColors.accentSoft,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Text(
              no,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: TangramColors.accent,
              ),
            ),
          ),
          const SizedBox(width: TangramSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: TangramColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 扫码接入：向 OpenClaw 网关申请真实登录二维码
// ---------------------------------------------------------------------------

/// 扫码接入卡片：选通道 → 点一下申请真二维码。
/// 二维码内容全部来自网关响应，本卡片不生成任何二维码。
class _QrLoginCard extends StatelessWidget {
  const _QrLoginCard({
    required this.connector,
    required this.onConnectorChanged,
    required this.onStart,
  });

  final String connector;
  final ValueChanged<String> onConnectorChanged;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(TangramSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.qr_code_2, size: 18, color: TangramColors.jade),
              SizedBox(width: TangramSpacing.sm),
              Text(
                '扫码接入微信 / QQ',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TangramColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: TangramSpacing.sm),
          const Text(
            '点一下向网关申请登录二维码，用手机微信/QQ 扫码即可。二维码由网关生成。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: TangramColors.textSecondary,
            ),
          ),
          const SizedBox(height: TangramSpacing.md),
          DropdownButtonFormField<String>(
            value: connector,
            decoration: const InputDecoration(
              labelText: '要接入的通道',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: 'wechat', child: Text('微信')),
              DropdownMenuItem<String>(value: 'qq', child: Text('QQ')),
              DropdownMenuItem<String>(value: 'feishu', child: Text('飞书')),
            ],
            onChanged: (String? v) {
              if (v != null) onConnectorChanged(v);
            },
          ),
          const SizedBox(height: TangramSpacing.md),
          FilledButton.icon(
            onPressed: onStart,
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('获取登录二维码'),
          ),
        ],
      ),
    );
  }
}

/// 扫码弹窗的展示阶段（对应网关返回的登录状态机）。
enum _QrPhase { loading, waiting, scanned, confirmed, expired, needVerify, error }

/// 扫码登录弹窗。
///
/// 真实链路：请求网关二维码 → 渲染（qr_flutter）→ 每秒轮询登录状态 →
/// 确认后由 ImService 自动落盘凭据并建立 AGP WebSocket 连接。
/// 网关未下发二维码时只展示真实错误原因，**不画占位码**。
class QrLoginSheet extends StatefulWidget {
  const QrLoginSheet({
    super.key,
    required this.client,
    required this.connector,
    required this.connectorName,
    required this.gatewayUrl,
  });

  final BackendClient client;
  final String connector;
  final String connectorName;
  final String gatewayUrl;

  @override
  State<QrLoginSheet> createState() => _QrLoginSheetState();
}

class _QrLoginSheetState extends State<QrLoginSheet> {
  _QrPhase _phase = _QrPhase.loading;
  String _qrContent = '';
  Uint8List? _qrImage;
  String? _qrUrl;
  String? _verifyUrl;
  String? _error;
  String? _sessionId;
  int _remaining = 0;
  bool _busy = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _requestQr();
  }

  @override
  void dispose() {
    _timer?.cancel();
    // 关闭弹窗时撤销在途登录会话（已确认的不撤销，连接保持）。
    if (_sessionId != null && _phase != _QrPhase.confirmed) {
      unawaited(_cancelSession());
    }
    super.dispose();
  }

  Future<void> _cancelSession() async {
    try {
      await widget.client.sendControl('im_event', <String, dynamic>{
        'action': 'login_cancel',
        'connector': widget.connector,
      });
    } on Object {
      // 关闭阶段忽略取消失败。
    }
  }

  Map<String, dynamic> _map(BridgeEnvelope env) {
    final dynamic p = env.payload;
    return p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{};
  }

  Future<void> _requestQr() async {
    _timer?.cancel();
    setState(() {
      _phase = _QrPhase.loading;
      _error = null;
      _verifyUrl = null;
      _busy = true;
    });
    try {
      final BridgeEnvelope env =
          await widget.client.sendControl('im_event', <String, dynamic>{
        'action': 'login_qr',
        'connector': widget.connector,
        if (widget.gatewayUrl.isNotEmpty) 'url': widget.gatewayUrl,
      });
      final Map<String, dynamic> m = _map(env);
      if (m['ok'] != true) {
        if (!mounted) return;
        setState(() {
          _phase = _QrPhase.error;
          _error = (m['error'] ?? '网关未返回二维码').toString();
          _busy = false;
        });
        return;
      }
      // 网关已有登录态：不必再出码，直接展示成功并自动建立连接。
      if (m['already_logged_in'] == true ||
          (m['status'] ?? '').toString() == 'confirmed') {
        if (!mounted) return;
        setState(() {
          _phase = _QrPhase.confirmed;
          _error = null;
          _busy = false;
        });
        Future<void>.delayed(const Duration(milliseconds: 1800), () {
          if (mounted) Navigator.of(context).pop();
        });
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
          _phase = _QrPhase.error;
          _error = '网关未返回二维码内容。';
          _busy = false;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _qrContent = content;
        _qrImage = img;
        _qrUrl = m['qr_url']?.toString();
        _sessionId = m['session_id']?.toString();
        _remaining =
            m['expires_in'] is int ? m['expires_in'] as int : 300;
        _phase = _QrPhase.waiting;
        _busy = false;
      });
      _startPolling();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _QrPhase.error;
        _error = '无法连接网关：$e';
        _busy = false;
      });
    }
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer _) => _tick());
  }

  Future<void> _tick() async {
    if (!mounted) {
      _timer?.cancel();
      return;
    }
    Map<String, dynamic> m = <String, dynamic>{};
    try {
      final BridgeEnvelope env =
          await widget.client.sendControl('im_event', <String, dynamic>{
        'action': 'login_status',
        'connector': widget.connector,
      });
      m = _map(env);
    } on Object catch (e) {
      m = <String, dynamic>{'poll_error': '$e'};
    }
    if (!mounted) return;
    _apply(m);
  }

  void _apply(Map<String, dynamic> m) {
    final _QrPhase next = _phaseOf((m['status'] ?? 'idle').toString());
    setState(() {
      if (_remaining > 0) _remaining--;
      if (next != _QrPhase.loading) _phase = next;
      if (m['error'] != null) _error = m['error'].toString();
      if (m['verify_url'] != null) _verifyUrl = m['verify_url'].toString();
      final String? pollErr = m['poll_error']?.toString();
      if (pollErr != null && (_error == null || _error!.isEmpty)) {
        _error = pollErr;
      }
    });
    if (next == _QrPhase.confirmed ||
        next == _QrPhase.expired ||
        next == _QrPhase.error) {
      _timer?.cancel();
      if (next == _QrPhase.confirmed) {
        Future<void>.delayed(const Duration(milliseconds: 1800), () {
          if (mounted) Navigator.of(context).pop();
        });
      }
    }
  }

  _QrPhase _phaseOf(String s) => switch (s) {
        'scanned' => _QrPhase.scanned,
        'confirmed' => _QrPhase.confirmed,
        'expired' => _QrPhase.expired,
        'need_verify' => _QrPhase.needVerify,
        'error' => _QrPhase.error,
        _ => _QrPhase.waiting,
      };

  String _clock(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Icon(Icons.qr_code_2, size: 20),
          const SizedBox(width: 8),
          Text('扫码接入${widget.connectorName}'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _buildQrArea(),
            const SizedBox(height: 16),
            _buildStatus(),
          ],
        ),
      ),
      actions: <Widget>[
        if (_phase == _QrPhase.expired ||
            _phase == _QrPhase.error ||
            _phase == _QrPhase.needVerify)
          TextButton.icon(
            onPressed: _busy ? null : _requestQr,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('要新码'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildQrArea() {
    if (_phase == _QrPhase.loading) {
      return const SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CircularProgressIndicator(),
              SizedBox(height: 14),
              Text('正在申请二维码…',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      );
    }
    if (_phase == _QrPhase.confirmed) {
      return SizedBox(
        height: 200,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const <Widget>[
              Icon(Icons.check_circle, color: TangramColors.success, size: 64),
              SizedBox(height: 14),
              Text('登录成功', style: TextStyle(fontSize: 15)),
              SizedBox(height: 6),
              Text('连接已建立，去发条消息试试',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      );
    }
    if (_qrContent.isEmpty && _qrImage == null) {
      // 错误原因在下方状态区展示一次即可，这里只给一句下一步引导，
      // 避免同一段文字重复三遍。
      return const SizedBox(
        height: 190,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.link_off, color: Colors.orange, size: 40),
              SizedBox(height: 12),
              Text('暂时拿不到登录二维码',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              SizedBox(height: 8),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  '网关没返回二维码，可能已过期或网络不通，点「要新码」重试。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.5,
                      color: TangramColors.textCaption),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: _qrImage != null
              ? Image.memory(_qrImage!,
                  width: 200, height: 200, fit: BoxFit.contain)
              : QrImageView(
                  data: _qrContent,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                  gapless: false,
                ),
        ),
        const SizedBox(height: 10),
        Text(
          '有效 ${_clock(_remaining)} · 用手机${widget.connectorName}扫一扫',
          style: const TextStyle(
              fontSize: 12, color: TangramColors.textSecondary),
        ),
        if (_qrUrl != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '来源：$_qrUrl',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 10, color: TangramColors.textCaption),
            ),
          ),
      ],
    );
  }

  Widget _buildStatus() {
    late final IconData icon;
    late final Color color;
    late final String label;
    switch (_phase) {
      case _QrPhase.loading:
        icon = Icons.hourglass_empty;
        color = TangramColors.textMuted;
        label = '正在申请二维码…';
        break;
      case _QrPhase.waiting:
        icon = Icons.qr_code_scanner;
        color = TangramColors.jade;
        label = '等待扫码';
        break;
      case _QrPhase.scanned:
        icon = Icons.touch_app;
        color = TangramColors.gold;
        label = '已扫码，请在手机上确认登录';
        break;
      case _QrPhase.confirmed:
        icon = Icons.check_circle;
        color = TangramColors.success;
        label = '登录成功，正在连接…';
        break;
      case _QrPhase.expired:
        icon = Icons.timer_off;
        color = Colors.orange;
        label = '二维码已过期，点「要新码」重新获取';
        break;
      case _QrPhase.needVerify:
        icon = Icons.verified_user;
        color = TangramColors.gold;
        label = '需要辅助验证';
        break;
      case _QrPhase.error:
        icon = Icons.error_outline;
        color = Colors.redAccent;
        label = '接入失败';
        break;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: color)),
            ),
          ],
        ),
        if (_error != null && _phase != _QrPhase.loading)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: TangramColors.textSecondary),
            ),
          ),
        if (_verifyUrl != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '验证链接：$_verifyUrl',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 11, color: TangramColors.textCaption),
            ),
          ),
      ],
    );
  }
}
