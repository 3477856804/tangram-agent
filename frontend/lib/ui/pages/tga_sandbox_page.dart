import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';

/// 内置沙箱（真实化改造）：
/// - 去掉顶部假「策略」横幅；
/// - 终端字体紧凑真实：等宽 fontSize 12、行高 1.35、letterSpacing 0，
///   提示符 `tga@sandbox:~$`，欢迎语/能力契约输出更像 Linux shell；
/// - 终端执行走现有 code_task RPC（eval → 受限 Isolate 真实求值），
///   输出/失败原因如实回显，不再用演示假回显。
class TgaSandboxPage extends StatefulWidget {
  const TgaSandboxPage({super.key});

  @override
  State<TgaSandboxPage> createState() => _TgaSandboxPageState();
}

class _TgaSandboxPageState extends State<TgaSandboxPage> {
  final TextEditingController _input = TextEditingController();
  final List<String> _lines = <String>[];
  bool _running = false;

  static const Color _termBg = Color(0xFF141A26);
  static const Color _termFg = Color(0xFFCFD8E8);
  static const Color _termGreen = Color(0xFF5FD6A0);
  static const Color _termDim = Color(0xFF9FB0CC);

  @override
  void initState() {
    super.initState();
    // 会话建立时间真实取当前时刻（打开本页即一次真实登录）。
    final DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    _lines.add('Last login: ${two(now.month)} ${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)} on in-app tty');
  }

  String _cwd = '~';

  /// 执行一条命令：走 code_task shell RPC（沙箱根内真实文件操作，
  /// pwd/ls/cd/cat/mkdir/rm/mv/cp/head/tail/wc/date/whoami/uname/help，
  /// 纯算式自动落表达式求值）。结果如实回显，失败不编造。
  Future<void> _submit() async {
    final String cmd = _input.text.trim();
    if (cmd.isEmpty || _running) return;
    _input.clear();
    final String shownCwd = _cwd;
    setState(() {
      _lines.add('tga@sandbox:$shownCwd\$ $cmd');
      _running = true;
    });
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'code_task',
        <String, dynamic>{
          'action': 'shell',
          'command': cmd,
          'cwd': _cwd == '~' ? '.' : _cwd.substring(2),
        },
      );
      final dynamic payload = env.payload;
      if (!mounted) return;
      setState(() {
        if (payload is Map) {
          final String rel = (payload['cwd'] ?? '.').toString();
          _cwd = rel == '.' ? '~' : '~/';
          if (rel != '.') _cwd = '~/$rel';
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

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Scaffold(
      backgroundColor: Tga.bg,
      appBar: AppBar(
        backgroundColor: Tga.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('内置沙箱', style: Tga.h1),
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
                  // 终端标题条
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    color: const Color(0xFF1B2333),
                    child: Row(
                      children: <Widget>[
                        _dot(const Color(0xFFE86A6A)),
                        const SizedBox(width: 6),
                        _dot(const Color(0xFFE8BE6A)),
                        const SizedBox(width: 6),
                        _dot(const Color(0xFF5FD6A0)),
                        const SizedBox(width: 12),
                        const Text('tga@sandbox — 50x14',
                            style: TextStyle(
                                fontSize: 12,
                                letterSpacing: 0,
                                color: Color(0xFF8C99B0),
                                fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                  // 欢迎语 + 能力契约 + 执行历史（靠上）
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: <Widget>[
                        const Text('tga@sandbox:~\$ tangram-sandbox --version',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.35,
                                letterSpacing: 0,
                                color: _termGreen)),
                        const Text('Tangram Sandbox v0.0.1 '
                            '(pure-dart in-process harness)',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.35,
                                letterSpacing: 0,
                                color: _termFg)),
                        const SizedBox(height: 8),
                        const Text(
                            'Welcome to the isolated agent workspace.\n'
                            'Commands run in a restricted Isolate via the '
                            'code_task RPC.\n'
                            'Type an expression and press Enter, e.g. 2+3*4',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.35,
                                letterSpacing: 0,
                                color: _termFg)),
                        const SizedBox(height: 12),
                        const Text('tga@sandbox:~\$ cat /etc/capability_contract',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.35,
                                letterSpacing: 0,
                                color: _termGreen)),
                        ..._contract.map(
                          (String s) => Text(s,
                              style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                  height: 1.35,
                                  letterSpacing: 0,
                                  color: _termDim)),
                        ),
                        ..._lines.map(
                          (String s) => Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(s,
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    height: 1.35,
                                    letterSpacing: 0,
                                    color: s.startsWith('tga@sandbox')
                                        ? _termGreen
                                        : _termDim)),
                          ),
                        ),
                        if (_running)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text('running…',
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    height: 1.35,
                                    letterSpacing: 0,
                                    color: _termDim)),
                          ),
                      ],
                    ),
                  ),
                  // 命令输入行（贴底部）
                  Container(
                    padding: const EdgeInsets.fromLTRB(14, 8, 10, 12),
                    decoration: const BoxDecoration(
                      border: Border(
                          top: BorderSide(color: Color(0xFF2A3446), width: 1)),
                    ),
                    child: Row(
                      children: <Widget>[
                        const Text('tga@sandbox:~\$ ',
                            style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.35,
                                letterSpacing: 0,
                                color: _termGreen)),
                        Expanded(
                          child: TextField(
                            controller: _input,
                            onSubmitted: (_) => _submit(),
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                                height: 1.35,
                                letterSpacing: 0,
                                color: _termFg),
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

  /// 能力契约：以 shell 输出风格如实描述内置沙箱的真实边界。
  static const List<String> _contract = <String>[
    '1. execution : dart expression evaluated in a restricted isolate',
    '2. filesystem: writable root = app-private sandbox dir only',
    '3. network   : subject to policy, outside authorized dirs -> denied',
    '4. timeout   : enforced by sandbox_policy.timeout_seconds',
    '5. tools     : sandbox · current_time · recall_memory · remember_note',
  ];
}
