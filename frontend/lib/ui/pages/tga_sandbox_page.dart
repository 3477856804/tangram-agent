import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';
import '../../services/persona_store.dart';
import '../../services/sandbox_runtime.dart';
import '../../services/ssh_sandbox.dart';

/// 沙箱终端（问题 #2/#22 真实化）：
/// - 「内置沙箱」：桌面端系统 bash/sh（apt/pkg/pip 真命令）；安卓
///   /system/bin/sh（toybox，如实报 command not found），并提供
///   「Debian 扩展包」入口——真实下载 proot + Alpine rootfs 后，
///   apk/python/pip 在用户态里真跑（exec 被 ROM 拒绝时如实报错）。
/// - 「远端沙箱（SSH）」：dartssh2 真实握手 + 密码/私钥认证，终端所有
///   命令在远端真实 Linux 执行；右上「⚙」配置主机/凭据，「连接测试」
///   走完整 SSH 认证并在远端执行 uname。
/// - #22 紧凑真实 tty：等宽 12 号、行高 1.3、80x24、欢迎横幅 2~3 行。
class TgaSandboxPage extends StatefulWidget {
  const TgaSandboxPage({super.key});

  @override
  State<TgaSandboxPage> createState() => _TgaSandboxPageState();
}

// 终端配色（页面与 SSH 配置对话框共用）。
const Color _termBg = Color(0xFF141A26);
const Color _termFg = Color(0xFFCFD8E8);
const Color _termGreen = Color(0xFF5FD6A0);
const Color _termDim = Color(0xFF9FB0CC);

class _TgaSandboxPageState extends State<TgaSandboxPage> {
  final TextEditingController _input = TextEditingController();
  final List<String> _lines = <String>[];
  bool _running = false;

  /// 已加载的 SSH 配置（null = 未配置）。
  SshConfig? _ssh;

  /// Android Debian 扩展包状态（code_task debian_status 真实回执）。
  Map<String, dynamic> _debian = const <String, dynamic>{};
  Timer? _debianTimer;

  static const TextStyle _ts = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.3,
      letterSpacing: 0,
      color: _termFg);

  @override
  void initState() {
    super.initState();
    // 会话建立时间真实取当前时刻（打开本页即一次真实登录）。
    final DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    _lines.add('Last login: ${two(now.month)} ${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)} on in-app tty');
    SshSandbox.instance.loadConfig().then((SshConfig? c) {
      if (mounted) setState(() => _ssh = c);
    });
    if (Platform.isAndroid) {
      _refreshDebianStatus();
    }
  }

  @override
  void dispose() {
    _debianTimer?.cancel();
    _input.dispose();
    super.dispose();
  }

  /// 后端维护的真实 cwd：'.'=沙箱根；相对路径=根内子目录；
  /// '/' 开头=已 cd 到系统绝对路径（和真 Linux 一样）。
  String _cwd = '.';

  String get _cwdShown => _cwd == '.'
      ? '~'
      : _cwd.startsWith('/')
          ? _cwd
          : '~/$_cwd';

  bool get _remote {
    final String env = context.read<PersonaStore>().sandboxEnvironment;
    return env.contains('SSH');
  }

  bool get _debianReady => _debian['installed'] == true;

  /// 提示符主机名：远端 user@host / Debian root@debian / 本地 tga@sandbox。
  String get _hostShown {
    if (_remote) {
      final c = _ssh;
      return c != null && c.host.isNotEmpty
          ? '${c.user}@${c.host.split('.').first}'
          : 'tga@remote';
    }
    if (Platform.isAndroid && _debianReady) return 'root@debian';
    return 'tga@sandbox';
  }

  /// 执行一条命令：走 code_task shell RPC，由后端按沙箱环境分流
  /// （远端 SSH / Debian 用户态 / 系统真实 shell / 内置解释器兜底）。
  /// 输出/退出码/失败原因全部如实回显，失败不编造。
  Future<void> _submit() async {
    final String cmd = _input.text.trim();
    if (cmd.isEmpty || _running) return;
    _input.clear();
    final String shownCwd = _cwdShown;
    final String prompt = '$_hostShown:$shownCwd\$ ';
    setState(() {
      _lines.add('$prompt$cmd');
      _running = true;
    });
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'code_task',
        <String, dynamic>{
          'action': 'shell',
          'command': cmd,
          'cwd': _cwd,
        },
      );
      final dynamic payload = env.payload;
      if (!mounted) return;
      setState(() {
        if (payload is Map) {
          _cwd = (payload['cwd'] ?? '.').toString();
          final String out = (payload['stdout'] ?? '').toString();
          if (out.contains('\x1bclear\x1b')) {
            _lines.clear();
          } else if (out.trim().isNotEmpty) {
            _lines.add(out.trimRight());
          } else if (payload['ok'] != true) {
            _lines.add((payload['error'] ?? '执行失败').toString().trimRight());
          }
        } else {
          _lines.add('sandbox: 后端返回了非预期结构');
        }
        _running = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _lines.add('sandbox: $e');
        _running = false;
      });
    }
  }

  // ---- Debian 扩展包：真实下载进度 ----

  Future<void> _refreshDebianStatus() async {
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
          'code_task', <String, dynamic>{'action': 'debian_status'});
      if (!mounted) return;
      if (env.payload is Map) {
        setState(() => _debian = Map<String, dynamic>.from(env.payload as Map));
        final String step = (_debian['step'] ?? 'idle').toString();
        if (step == 'downloading' || step == 'extracting') {
          _debianTimer ??= Timer.periodic(
              const Duration(milliseconds: 800), (_) => _refreshDebianStatus());
        } else {
          _debianTimer?.cancel();
          _debianTimer = null;
        }
      }
    } on Object {
      // 后端未就绪：保持上次状态，不谎报。
    }
  }

  void _showDebianSheet() {
    _refreshDebianStatus();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1B2333),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext ctx) => _DebianSheetBody(
        client: context.read<BackendClient>(),
        onChanged: () {
          // 安装状态变化同步回页面（图标 / 主机名 / 欢迎语）。
          if (mounted) _refreshDebianStatus();
        },
      ),
    );
  }

  // ---- 远端 SSH 配置 ----

  void _showSshDialog() {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _SshConfigDialog(
        initial: _ssh,
        onSaved: (SshConfig cfg, bool savedReal) async {
          setState(() => _ssh = cfg);
          // 切到远端环境（本地记录 + 后端策略真实同步）。
          if (context.mounted) {
            context.read<SandboxRuntime>().setEnvironment('远端沙箱（SSH）');
          }
          if (!savedReal && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content:
                    Text('配置仅保存在内存：本机加密存储不可用（桌面缺少密钥环等）')));
          }
        },
        onCleared: () {
          setState(() => _ssh = null);
          if (context.mounted && _remote) {
            context.read<SandboxRuntime>().setEnvironment('内置沙箱');
          }
        },
      ),
    );
  }

  /// 欢迎横幅：按环境如实描述（2~3 行，真实 tty 风格）。
  List<String> get _welcome {
    if (_remote) {
      final c = _ssh;
      final String target = c != null && c.host.isNotEmpty ? c.display : '未配置';
      return <String>[
        'remote linux via ssh · $target',
        'apt · pip · python 全部在远端真实执行；连接失败如实报错。',
        '右上「设置」改主机/凭据；输入 help 看说明。',
      ];
    }
    if (Platform.isAndroid) {
      if (_debianReady) {
        return <String>[
          'alpine 3.20 userland via proot · apk · python · pip 真实执行',
          '（apt 为 Debian 系命令，此 rootfs 用 apk；需要 apt 请用「远端沙箱(SSH)」。）',
        ];
      }
      return <String>[
        'toybox /system/bin/sh · 安卓本机无 apt/pip（如实 command not found）',
        '跑 apt：右上「下载」装 Debian 扩展包（proot），或「设置」连远端 Linux(SSH)。',
      ];
    }
    return <String>[
      'system shell bash/sh · apt · pkg · pip · curl · gcc 全部真实执行',
      'missing commands report honestly, never faked.',
    ];
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    context.watch<PersonaStore>(); // 环境切换实时刷新
    final String host = _hostShown;
    final bool remote = _remote;
    return Scaffold(
      backgroundColor: Tga.bg,
      appBar: AppBar(
        backgroundColor: Tga.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(remote ? '沙箱终端 · 远端' : '沙箱终端', style: Tga.h1),
        actions: <Widget>[
          if (Platform.isAndroid && !remote)
            IconButton(
              icon: Icon(
                  _debianReady
                      ? Icons.verified_outlined
                      : Icons.download_outlined,
                  color: Tga.primary),
              tooltip: 'Debian 扩展包（proot 用户态）',
              onPressed: _showDebianSheet,
            ),
          IconButton(
            icon: Icon(Icons.settings_outlined,
                color: remote ? _termGreen : Tga.primary),
            tooltip: '远端沙箱（SSH）配置',
            onPressed: _showSshDialog,
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // ---------- 深色终端（从顶部延伸到底部）----------
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, Tga.pagePad),
              decoration: BoxDecoration(
                color: _termBg,
                borderRadius: BorderRadius.circular(14),
                boxShadow: <BoxShadow>[Tga.softShadow],
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // 终端标题条：主机 + 80x24
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 8),
                    color: const Color(0xFF1B2333),
                    child: Row(
                      children: <Widget>[
                        _dot(const Color(0xFFE86A6A)),
                        const SizedBox(width: 6),
                        _dot(const Color(0xFFE8BE6A)),
                        const SizedBox(width: 6),
                        _dot(const Color(0xFF5FD6A0)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text('$host — 80x24',
                              style: const TextStyle(
                                  fontSize: 12,
                                  letterSpacing: 0,
                                  color: Color(0xFF8C99B0),
                                  fontFamily: 'monospace')),
                        ),
                        Text(remote
                            ? (SshSandbox.instance.isConnected
                                ? 'ssh · connected'
                                : 'ssh · 未连接')
                            : (Platform.isAndroid
                                ? (_debianReady ? 'proot' : 'toybox')
                                : 'bash/sh'),
                            style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF5A6880),
                                fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                  // 欢迎语 + 执行历史（靠上）
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                      children: <Widget>[
                        for (final String line in _welcome)
                          Text(line, style: _ts),
                        ..._lines.map(
                          (String s) => Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(s,
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    height: 1.3,
                                    letterSpacing: 0,
                                    color: s.startsWith('$host:')
                                        ? _termGreen
                                        : _termDim)),
                          ),
                        ),
                        if (_running)
                          const Padding(
                            padding: EdgeInsets.only(top: 2),
                            child: Text('running…',
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    height: 1.3,
                                    letterSpacing: 0,
                                    color: _termDim)),
                          ),
                      ],
                    ),
                  ),
                  // 命令输入行（贴底部）
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 6, 10, 10),
                    decoration: const BoxDecoration(
                      border: Border(
                          top: BorderSide(color: Color(0xFF2A3446), width: 1)),
                    ),
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text('$host:$_cwdShown\$ ',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  height: 1.3,
                                  letterSpacing: 0,
                                  color: _termGreen)),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _input,
                            onSubmitted: (_) => _submit(),
                            style: _ts,
                            cursorColor: _termGreen,
                            decoration: const InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: 'enter command…',
                              hintStyle: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  letterSpacing: 0,
                                  color: Color(0xFF5A6880)),
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: _running ? null : _submit,
                          child: const Icon(Icons.play_arrow_rounded,
                              size: 20, color: _termGreen),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _dot(Color c) => Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: c, shape: BoxShape.circle),
      );
}

// ---------------------------------------------------------------------------
// Debian 扩展包面板（问题 #5）：监听 proot_progress hot-path 事件，
// 进度条按真实接收字节推进；解包显示「正在解包…」；失败如实显示
// 错误并恢复按钮；已装显示「已安装」。debian_status 轮询作兜底。
// ---------------------------------------------------------------------------
class _DebianSheetBody extends StatefulWidget {
  const _DebianSheetBody({required this.client, required this.onChanged});

  final BackendClient client;
  final VoidCallback onChanged;

  @override
  State<_DebianSheetBody> createState() => _DebianSheetBodyState();
}

class _DebianSheetBodyState extends State<_DebianSheetBody> {
  StreamSubscription<BridgeEnvelope>? _hotSub;
  Timer? _poll;

  Map<String, dynamic> _status = const <String, dynamic>{};
  bool _starting = false;

  // proot_progress 事件上报的最新进度（received/total 为累计真实字节，
  // total=-1 表示 Content-Length 未知；speed 为 bytes/s）。
  String _phase = '';
  int _received = 0;
  int _total = -1;
  double _speed = 0;

  bool get _installed => _status['installed'] == true;
  bool get _busy => _status['installing'] == true || _starting;

  @override
  void initState() {
    super.initState();
    _hotSub = widget.client.onHotPath.listen((BridgeEnvelope env) {
      if (env.topic != 'proot_progress') return;
      final dynamic p = env.payload;
      if (p is! Map || !mounted) return;
      setState(() {
        _phase = (p['phase'] ?? '').toString();
        _received = (p['received'] as num?)?.toInt() ?? _received;
        _total = (p['total'] as num?)?.toInt() ?? _total;
        _speed = (p['speed'] as num?)?.toDouble() ?? _speed;
      });
    });
    _pollStatus();
  }

  @override
  void dispose() {
    _hotSub?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _pollStatus() async {
    try {
      final BridgeEnvelope env = await widget.client.sendControl(
          'code_task', <String, dynamic>{'action': 'debian_status'});
      if (!mounted) return;
      final dynamic p = env.payload;
      if (p is! Map) return;
      setState(() {
        _status = Map<String, dynamic>.from(p);
        // 兜底：事件迟到时，进度条也按真实字节推进。
        if (_status['installing'] == true) {
          final int d = (_status['downloaded'] as num?)?.toInt() ?? 0;
          if (d > _received) _received = d;
          final int t = (_status['total'] as num?)?.toInt() ?? -1;
          if (t > 0) _total = t;
          final String step = (_status['step'] ?? '').toString();
          if (step == 'extracting') {
            _phase = 'extract';
          } else if (step == 'downloading' && _phase != 'extract') {
            _phase = 'download';
          }
        }
      });
      if (_status['installing'] == true) {
        _poll ??= Timer.periodic(
            const Duration(milliseconds: 800), (_) => _pollStatus());
      } else {
        _poll?.cancel();
        _poll = null;
        widget.onChanged();
      }
    } on Object {
      // 后端未就绪：保持上次状态，不谎报。
    }
  }

  Future<void> _install() async {
    setState(() => _starting = true);
    try {
      final BridgeEnvelope env = await widget.client.sendControl(
          'code_task', <String, dynamic>{'action': 'debian_install'});
      if (!mounted) return;
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        setState(() {
          _starting = false;
          _phase = 'download';
          _received = 0;
          _speed = 0;
        });
        _pollStatus();
      } else {
        setState(() {
          _starting = false;
          _status = <String, dynamic>{
            ..._status,
            'error': p is Map ? (p['error'] ?? '未知错误') : '未知错误',
          };
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _status = <String, dynamic>{..._status, 'error': '$e'};
        });
      }
    }
  }

  static String _mb(num bytes) {
    final int b = bytes.toInt();
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _progressLine() {
    if (_installed) return 'Debian 用户态已就绪';
    if (!_busy) return '未安装 · 共约 4.1 MB，进度按真实接收字节统计';
    if (_phase == 'extract') return '正在解包…';
    final String tot = _total > 0 ? ' / ${_mb(_total)}' : '';
    final String sp = _speed > 1 ? ' · ${_mb(_speed)}/s' : '';
    return '下载中 · ${_mb(_received)}$tot$sp';
  }

  @override
  Widget build(BuildContext context) {
    final String error = (_status['error'] ?? '').toString();
    final double? frac =
        _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;
    final double? barValue;
    if (_installed) {
      barValue = 1;
    } else if (!_busy) {
      barValue = frac != null && _received > 0 ? frac : 0.0;
    } else if (_phase == 'extract') {
      barValue = null; // 解包：不确定进度
    } else {
      barValue = frac; // total 未知时如实走不确定进度
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Debian 扩展包（proot 用户态）',
              style: const TextStyle(
                  color: _termGreen, fontSize: 14, fontFamily: 'monospace')),
          const SizedBox(height: 8),
          Text(
              '下载 proot（UserLAnd arm64）+ Alpine 3.20 minirootfs，'
              '解包后 apk/python/pip 在本机用户态真实执行。',
              style: const TextStyle(
                  color: _termDim, fontSize: 12, height: 1.4)),
          const SizedBox(height: 12),
          if (_installed)
            Text('已安装：${_status['rootfs']}',
                style: const TextStyle(
                    color: _termGreen, fontSize: 12, fontFamily: 'monospace'))
          else ...<Widget>[
            LinearProgressIndicator(
              value: barValue,
              minHeight: 6,
              backgroundColor: const Color(0xFF2A3446),
              color: _termGreen,
            ),
            const SizedBox(height: 6),
            Text(_progressLine(),
                style: const TextStyle(color: _termDim, fontSize: 12)),
            if (error.isNotEmpty && !_busy)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('失败：$error',
                    style: const TextStyle(
                        color: Color(0xFFE86A6A), fontSize: 12)),
              ),
          ],
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  onPressed: _installed || _busy ? null : _install,
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _termGreen,
                      side: const BorderSide(color: _termGreen)),
                  child: Text(_installed
                      ? '已安装'
                      : _busy
                          ? '安装中…'
                          : '下载并安装'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _termDim,
                      side: const BorderSide(color: Color(0xFF2A3446))),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '注：Android 10+ 若 ROM 强制禁止执行应用私有目录文件，首次执行会'
            '如实报错；此时请用「远端沙箱（SSH）」跑 apt。',
            style: const TextStyle(color: Color(0xFF5A6880), fontSize: 11)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 远端沙箱（SSH）配置：主机/端口/用户/密码或私钥 + 真实握手连接测试
// ---------------------------------------------------------------------------
class _SshConfigDialog extends StatefulWidget {
  const _SshConfigDialog({
    required this.initial,
    required this.onSaved,
    required this.onCleared,
  });

  final SshConfig? initial;
  final Future<void> Function(SshConfig cfg, bool savedReal) onSaved;
  final VoidCallback onCleared;

  @override
  State<_SshConfigDialog> createState() => _SshConfigDialogState();
}

class _SshConfigDialogState extends State<_SshConfigDialog> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _password;
  late final TextEditingController _key;
  late final TextEditingController _passphrase;
  late String _auth;

  bool _testing = false;
  String _result = '';
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    final SshConfig? c = widget.initial;
    _host = TextEditingController(text: c?.host ?? '');
    _port = TextEditingController(text: '${c?.port ?? 22}');
    _user = TextEditingController(text: c?.user ?? '');
    _password = TextEditingController(text: c?.password ?? '');
    _key = TextEditingController(text: c?.privateKey ?? '');
    _passphrase = TextEditingController(text: c?.passphrase ?? '');
    _auth = c?.auth ?? '密码';
  }

  @override
  void dispose() {
    for (final t in <TextEditingController>[
      _host,
      _port,
      _user,
      _password,
      _key,
      _passphrase,
    ]) {
      t.dispose();
    }
    super.dispose();
  }

  SshConfig _collect() => SshConfig(
        host: _host.text.trim(),
        port: int.tryParse(_port.text.trim()) ?? 22,
        user: _user.text.trim(),
        auth: _auth,
        password: _auth == '密码' ? _password.text : '',
        privateKey: _auth == '私钥' ? _key.text : '',
        passphrase: _auth == '私钥' ? _passphrase.text : '',
      );

  /// 真实握手测试：完整 SSH 传输层协商 + 认证 + 远端执行 uname -a。
  Future<void> _test() async {
    final SshConfig cfg = _collect();
    if (cfg.host.isEmpty || cfg.user.isEmpty || !cfg.usable) {
      setState(() {
        _result = '请填写主机、用户名与${_auth == '私钥' ? '私钥' : '密码'}';
        _resultOk = false;
      });
      return;
    }
    setState(() {
      _testing = true;
      _result = '';
    });
    try {
      final String info = await SshSandbox.instance.testConnection(cfg);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _resultOk = true;
        _result = '握手+认证成功：$info';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _resultOk = false;
        _result = '连接失败：$e';
      });
    }
  }

  Future<void> _save() async {
    final SshConfig cfg = _collect();
    if (cfg.host.isEmpty || cfg.user.isEmpty || !cfg.usable) {
      setState(() {
        _resultOk = false;
        _result = '请填写主机、用户名与${_auth == '私钥' ? '私钥' : '密码'}';
      });
      return;
    }
    final bool savedReal = await SshSandbox.instance.saveConfig(cfg);
    if (!mounted) return;
    await widget.onSaved(cfg, savedReal);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _clear() async {
    await SshSandbox.instance.clearConfig();
    if (!mounted) return;
    widget.onCleared();
    Navigator.of(context).pop();
  }

  Widget _field(String label, TextEditingController ctrl,
      {bool obscure = false, TextInputType? keyboard, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: ctrl,
        obscureText: obscure,
        keyboardType: keyboard,
        maxLines: maxLines,
        style: const TextStyle(
            fontFamily: 'monospace', fontSize: 13, color: _termFg),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          labelStyle: const TextStyle(fontSize: 12, color: _termDim),
          enabledBorder:
              const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF2A3446))),
          focusedBorder:
              const UnderlineInputBorder(borderSide: BorderSide(color: _termGreen)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _termBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('远端沙箱（SSH）',
          style: TextStyle(
              color: _termGreen, fontSize: 15, fontFamily: 'monospace')),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _field('主机', _host),
              _field('端口', _port, keyboard: TextInputType.number),
              _field('用户名', _user),
              Row(
                children: <Widget>[
                  const Text('认证方式',
                      style: TextStyle(fontSize: 12, color: _termDim)),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: _auth,
                    dropdownColor: _termBg,
                    style: const TextStyle(fontSize: 13, color: _termFg),
                    underline: const SizedBox.shrink(),
                    items: const <DropdownMenuItem<String>>[
                      DropdownMenuItem<String>(value: '密码', child: Text('密码')),
                      DropdownMenuItem<String>(value: '私钥', child: Text('私钥')),
                    ],
                    onChanged: (String? v) =>
                        setState(() => _auth = v ?? '密码'),
                  ),
                ],
              ),
              if (_auth == '密码')
                _field('密码', _password, obscure: true)
              else ...<Widget>[
                _field('私钥（PEM）', _key, maxLines: 5),
                _field('私钥口令（可选）', _passphrase, obscure: true),
              ],
              if (_result.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(_result,
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.3,
                        fontFamily: 'monospace',
                        color: _resultOk ? _termGreen : const Color(0xFFE86A6A))),
              ],
              const SizedBox(height: 6),
              const Text('「连接测试」= 真实 SSH 握手 + 认证 + 远端 uname；凭据加密存于本机。',
                  style: TextStyle(fontSize: 11, color: Color(0xFF5A6880))),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _testing ? null : _test,
                      style: OutlinedButton.styleFrom(
                          foregroundColor: _termGreen,
                          side: const BorderSide(color: _termGreen)),
                      child: _testing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: _termGreen))
                          : const Text('连接测试',
                              style: TextStyle(fontSize: 13)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _save,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF274058),
                          foregroundColor: _termFg),
                      child: const Text('保存并启用',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
              ),
              if (widget.initial != null) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    TextButton(
                      onPressed: () {
                        SshSandbox.instance.disconnect();
                        setState(() {
                          _resultOk = false;
                          _result = '已断开 SSH 会话。';
                        });
                      },
                      child: const Text('断开连接',
                          style: TextStyle(fontSize: 12, color: _termDim)),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: _clear,
                      child: const Text('清除配置',
                          style:
                              TextStyle(fontSize: 12, color: Color(0xFFE86A6A))),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
