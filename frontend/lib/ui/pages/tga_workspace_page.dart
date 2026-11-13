import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../services/persona_store.dart';

/// 工作区域（真实化改造）：
/// - 「工作区」列表来自 PersonaStore.workspaceRoot 指向的真实目录：
///   存在性用 device_file list 校验（沙箱外路径退回 dart:io 真实探测），
///   不存在显示「未初始化」；⋮ 菜单支持设为当前 / 重命名（改记录别名）/ 删除。
/// - 「本地工作区」= device_file mkdir 真实创建目录 + setWorkspaceRoot
///   + rpc sandbox_policy_set{environment:'工作区沙箱'}。
/// - 「SSH 远程工作区」= 表单 + Socket.connect 真实 TCP 可达性测试
///   （明确不做假认证），成功后配置存 flutter_secure_storage。
class TgaWorkspacePage extends StatefulWidget {
  const TgaWorkspacePage({super.key});

  @override
  State<TgaWorkspacePage> createState() => _TgaWorkspacePageState();
}

class _TgaWorkspacePageState extends State<TgaWorkspacePage> {
  /// SSH 配置与本地工作区别名的安全存储 key。
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _sshKey = 'tangram.ssh.v1';
  static const String _aliasKey = 'tangram.workspace.alias.v1';

  /// 本地工作区在 App 沙箱内的相对目录（device_file 以此为根）。
  static const String _localRel = 'workspace';

  /// 沙箱根绝对路径（device_file status 返回的 roots[0]）。
  String _sandboxRoot = '';

  /// 本地工作区校验状态：none / ready / missing / external。
  String _localState = 'none';
  bool _loading = true;
  String _loadError = '';

  /// 已保存的 SSH 配置（tangram.ssh.v1），null 表示尚未配置。
  Map<String, dynamic>? _ssh;

  /// workspaceRoot 绝对路径 -> 展示别名（重命名只改记录，不动磁盘）。
  Map<String, String> _aliases = <String, String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ---------------------------------------------------------------------------
  // 数据装载与真实校验
  // ---------------------------------------------------------------------------

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = '';
    });
    final BackendClient client = context.read<BackendClient>();
    try {
      // 1) 取沙箱根目录（真实文件操作域 status）。
      final Map<String, dynamic> st = await client.deviceFile('status');
      if (st['ok'] == true && st['data'] is Map) {
        final dynamic roots = (st['data'] as Map)['roots'];
        _sandboxRoot =
            (roots is List && roots.isNotEmpty) ? roots.first.toString() : '';
      }
      // 2) 读 SSH 配置与别名。
      final String? sshRaw = await _storage.read(key: _sshKey);
      _ssh = (sshRaw != null && sshRaw.isNotEmpty)
          ? Map<String, dynamic>.from(jsonDecode(sshRaw) as Map)
          : null;
      final String? aliasRaw = await _storage.read(key: _aliasKey);
      _aliases = (aliasRaw != null && aliasRaw.isNotEmpty)
          ? Map<String, String>.from(
              (jsonDecode(aliasRaw) as Map).map(
                  (dynamic k, dynamic v) => MapEntry(k.toString(), v.toString())))
          : <String, String>{};
      // 3) 校验当前 workspaceRoot 指向的真实目录。
      await _verifyLocal(client);
    } on Object catch (e) {
      _loadError = '后端未就绪：$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  /// workspaceRoot 相对沙箱根的路径；不在沙箱内返回 null。
  String? _relOf(String abs) {
    if (_sandboxRoot.isEmpty) return null;
    if (abs == _sandboxRoot) return '';
    if (abs.startsWith('$_sandboxRoot/')) {
      return abs.substring(_sandboxRoot.length + 1);
    }
    return null;
  }

  /// 真实校验本地工作区目录是否存在。
  Future<void> _verifyLocal(BackendClient client) async {
    final String ws = context.read<PersonaStore>().workspaceRoot ?? '';
    if (ws.isEmpty) {
      _localState = 'none';
      return;
    }
    final String? rel = _relOf(ws);
    if (rel != null) {
      try {
        final Map<String, dynamic> r =
            await client.deviceFile('list', args: <String, dynamic>{'path': rel});
        _localState = r['ok'] == true ? 'ready' : 'missing';
      } on Object {
        _localState = 'missing';
      }
    } else {
      // 沙箱外的绝对路径（如系统文件选择器选的目录）：dart:io 真实探测，
      // 存在则如实标「外部路径」，不存在标「未初始化」。
      _localState = Directory(ws).existsSync() ? 'external' : 'missing';
    }
  }

  Future<void> _saveAliases() async {
    try {
      await _storage.write(key: _aliasKey, value: jsonEncode(_aliases));
    } on Object {
      // 存储不可用时保持内存态，不谎称已保存。
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------------------------------------------------------------------
  // 本地工作区：真实创建 / 菜单操作
  // ---------------------------------------------------------------------------

  Future<void> _createLocalWorkspace() async {
    final BackendClient client = context.read<BackendClient>();
    final PersonaStore persona = context.read<PersonaStore>();
    try {
      // 1) 在 App 私有沙箱内真实创建 workspace 目录（幂等）。
      final Map<String, dynamic> r = await client.deviceFile(
          'mkdir', args: <String, dynamic>{'path': _localRel});
      if (r['ok'] != true) {
        _toast('创建失败：${r['error'] ?? '未知错误'}');
        return;
      }
      final String abs = ((r['data'] as Map?)?['path'] ?? '').toString();
      // 2) 写入工作区记录 + 沙箱环境。
      persona.setWorkspaceRoot(abs);
      persona.setSandboxEnvironment('工作区沙箱');
      _aliases[abs] = '本地工作区';
      await _saveAliases();
      // 3) 后端沙箱策略同步切到「工作区沙箱」。
      await client.sendControl('rpc', <String, dynamic>{
        'action': 'sandbox_policy_set',
        'environment': '工作区沙箱',
      });
      await _verifyLocal(client);
      if (mounted) setState(() {});
      _toast('本地工作区已创建：$abs');
    } on Object catch (e) {
      _toast('创建失败：$e');
    }
  }

  Future<void> _setLocalCurrent() async {
    final BackendClient client = context.read<BackendClient>();
    final PersonaStore persona = context.read<PersonaStore>();
    persona.setSandboxEnvironment('工作区沙箱');
    try {
      await client.sendControl('rpc', <String, dynamic>{
        'action': 'sandbox_policy_set',
        'environment': '工作区沙箱',
      });
    } on Object {
      // 后端未就绪时本地记录已更新，如实提示。
      _toast('已设为当前工作区（沙箱策略未同步：后端未就绪）');
      setState(() {});
      return;
    }
    _toast('已设为当前工作区');
    setState(() {});
  }

  Future<void> _renameLocal() async {
    final String ws = context.read<PersonaStore>().workspaceRoot ?? '';
    if (ws.isEmpty) return;
    final String? name = await _promptText(
      title: '重命名工作区',
      hint: '显示名称',
      initial: _displayName(ws),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    // 重命名 = 改记录里的别名（device_file rename 只支持文件，
    // 目录改名会破坏真实路径，故不动磁盘、只改展示名）。
    _aliases[ws] = name.trim();
    await _saveAliases();
    if (mounted) setState(() {});
  }

  Future<void> _deleteLocal() async {
    final String ws = context.read<PersonaStore>().workspaceRoot ?? '';
    if (ws.isEmpty) return;
    final String? rel = _relOf(ws);
    final bool inside = rel != null && rel.isNotEmpty;
    final bool ok = await _confirm(
      title: '删除工作区记录？',
      message: inside
          ? '将清空本条工作区记录，并删除 App 沙箱内的目录「$rel」。\n'
              '不会删除 App 私有目录之外的任何内容。'
          : '将清空本条工作区记录。\n'
              '「$ws」在 App 沙箱之外，不会被删除，磁盘内容原样保留。',
    );
    if (!ok || !mounted) return;
    final BackendClient client = context.read<BackendClient>();
    final PersonaStore persona = context.read<PersonaStore>();
    if (inside) {
      try {
        await client.deviceFile('delete', args: <String, dynamic>{'path': rel});
      } on Object catch (e) {
        _toast('沙箱目录删除失败：$e（记录仍会清除）');
      }
    }
    persona.setWorkspaceRoot(null);
    persona.setSandboxEnvironment('内置沙箱');
    _aliases.remove(ws);
    await _saveAliases();
    await _verifyLocal(client);
    if (mounted) setState(() {});
    _toast('已清除工作区记录${inside ? '及沙箱内目录' : '（外部目录未动）'}');
  }

  // ---------------------------------------------------------------------------
  // SSH 远程工作区
  // ---------------------------------------------------------------------------

  Future<void> _createSshWorkspace() async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => _SshFormDialog(
        initial: _ssh,
        onConnected: (Map<String, dynamic> cfg) async {
          // TCP 可达后：配置落盘 + 环境切「远端沙箱（SSH）」。
          await _storage.write(key: _sshKey, value: jsonEncode(cfg));
          if (!mounted) return;
          final PersonaStore persona = context.read<PersonaStore>();
          persona.setSandboxEnvironment('远端沙箱（SSH）');
          final BackendClient client = context.read<BackendClient>();
          try {
            await client.sendControl('rpc', <String, dynamic>{
              'action': 'sandbox_policy_set',
              'environment': '远端沙箱（SSH）',
            });
          } on Object {
            // 后端未就绪：本地记录已保存，如实说明。
          }
        },
      ),
    );
    if (saved == true) {
      _ssh = await _readSsh();
      if (mounted) setState(() {});
    }
  }
  Future<Map<String, dynamic>?> _readSsh() async {
    final String? raw = await _storage.read(key: _sshKey);
    return (raw != null && raw.isNotEmpty)
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : null;
  }

  Future<void> _setSshCurrent() async {
    final BackendClient client = context.read<BackendClient>();
    final PersonaStore persona = context.read<PersonaStore>();
    persona.setSandboxEnvironment('远端沙箱（SSH）');
    try {
      await client.sendControl('rpc', <String, dynamic>{
        'action': 'sandbox_policy_set',
        'environment': '远端沙箱（SSH）',
      });
      _toast('已切换为远端沙箱（SSH）');
    } on Object {
      _toast('已切换（沙箱策略未同步：后端未就绪）');
    }
    setState(() {});
  }

  Future<void> _deleteSsh() async {
    final PersonaStore persona = context.read<PersonaStore>();
    final bool ok = await _confirm(
      title: '删除 SSH 工作区配置？',
      message: '将清除本机加密保存的连接配置；不会断开远端任何服务。',
    );
    if (!ok) return;
    await _storage.delete(key: _sshKey);
    _ssh = null;
    if (persona.sandboxEnvironment == '远端沙箱（SSH）') {
      persona.setSandboxEnvironment('内置沙箱');
    }
    if (mounted) setState(() {});
    _toast('SSH 配置已清除');
  }

  // ---------------------------------------------------------------------------
  // 通用小工具
  // ---------------------------------------------------------------------------

  String _displayName(String abs) {
    final String? alias = _aliases[abs];
    if (alias != null && alias.isNotEmpty) return alias;
    final String seg = abs.split('/').where((String s) => s.isNotEmpty).last;
    return seg.isEmpty ? abs : seg;
  }

  Future<String?> _promptText({
    required String title,
    required String hint,
    String initial = '',
  }) async {
    final TextEditingController ctrl = TextEditingController(text: initial);
    final String? result = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text(title, style: Tga.h2),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          style: Tga.body,
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text),
              child: Text('保存', style: TextStyle(color: Tga.primary))),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  Future<bool> _confirm(
      {required String title, required String message}) async {
    final bool? r = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text(title, style: Tga.h2),
        content: Text(message, style: Tga.body),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('确定', style: TextStyle(color: Tga.red))),
        ],
      ),
    );
    return r == true;
  }

  void _showCreateSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Tga.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('新建工作区', style: Tga.h2)),
            ),
            TgaIconTile(
              icon: Icons.computer_outlined,
              title: '本地工作区',
              subtitle: '在 App 沙箱内创建真实可写目录',
              onTap: () {
                Navigator.of(ctx).pop();
                _createLocalWorkspace();
              },
            ),
            const TgaTileDivider(),
            TgaIconTile(
              icon: Icons.dns_outlined,
              iconBg: Tga.iconPurpleBg,
              iconColor: Tga.iconPurple,
              title: 'SSH 远程工作区',
              subtitle: '配置主机并测试 TCP 可达性',
              onTap: () {
                Navigator.of(ctx).pop();
                _createSshWorkspace();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final PersonaStore persona = context.watch<PersonaStore>();
    final String ws = persona.workspaceRoot ?? '';
    final bool sshCurrent = persona.sandboxEnvironment == '远端沙箱（SSH）';
    final bool hasSsh = _ssh != null;

    return TgaPage(
      title: '工作区域',
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.add_rounded, color: Tga.primary),
          tooltip: '新建工作区',
          onPressed: _showCreateSheet,
        ),
      ],
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
          children: <Widget>[
            const TgaGroupTitle('工作区'),
            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                    child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Tga.primary))),
              )
            else if (_loadError.isNotEmpty)
              TgaCard(
                child: Text(_loadError, style: Tga.sub),
              )
            else if (ws.isEmpty && !hasSsh)
              TgaCard(
                child: TgaEmpty('还没有工作区，点右上角「+」新建本地或 SSH 工作区',
                    icon: Icons.folder_open_outlined),
              )
            else ...<Widget>[
              if (ws.isNotEmpty) _localCard(persona, ws, sshCurrent),
              if (hasSsh) _sshCard(sshCurrent),
            ],

            // ---------- 新建入口（两种类型）----------
            const TgaGroupTitle('新建工作区'),
            TgaCard(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: <Widget>[
                  TgaIconTile(
                    icon: Icons.computer_outlined,
                    title: '本地工作区',
                    subtitle: 'App 沙箱内真实目录（device_file mkdir）',
                    onTap: _createLocalWorkspace,
                  ),
                  const TgaTileDivider(),
                  TgaIconTile(
                    icon: Icons.dns_outlined,
                    iconBg: Tga.iconPurpleBg,
                    iconColor: Tga.iconPurple,
                    title: 'SSH 远程工作区',
                    subtitle: '连接自己的服务器（TCP 可达性测试）',
                    onTap: _createSshWorkspace,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '工作区为 Agent 提供隔离的可写目录；SSH 配置加密存于本机。'
                '「连接测试」只验证端口 TCP 可达（Socket.connect，5 秒超时），'
                '不做真实认证，也不代表已登录远端。',
                style: Tga.caption,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _localCard(PersonaStore persona, String ws, bool sshCurrent) {
    final (String label, Color color) = switch (_localState) {
      'ready' => ('就绪', Tga.green),
      'external' => ('外部路径', Tga.gold),
      'missing' => ('未初始化', Tga.orange),
      _ => ('未知', Tga.textSub),
    };
    return TgaCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: Tga.iconBlueBg, borderRadius: BorderRadius.circular(11)),
            child: Icon(Icons.folder_copy_outlined,
                size: 22, color: Tga.iconBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                        child: Text(_displayName(ws),
                            style: Tga.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    if (!sshCurrent) TgaTag('当前', color: Tga.primary),
                    const SizedBox(width: 6),
                    TgaTag(label, color: color),
                  ],
                ),
                const SizedBox(height: 6),
                Text(ws,
                    style: Tga.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          _MoreMenu(onSelected: (String v) {
            switch (v) {
              case 'current':
                _setLocalCurrent();
              case 'rename':
                _renameLocal();
              case 'delete':
                _deleteLocal();
            }
          }),
        ],
      ),
    );
  }

  Widget _sshCard(bool sshCurrent) {
    final Map<String, dynamic> cfg = _ssh!;
    final String host = (cfg['host'] ?? '').toString();
    final String port = (cfg['port'] ?? 22).toString();
    final String user = (cfg['user'] ?? '').toString();
    final String tested = (cfg['tested_at'] ?? '').toString();
    return TgaCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: <Widget>[
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: Tga.iconPurpleBg,
                borderRadius: BorderRadius.circular(11)),
            child: Icon(Icons.dns_outlined,
                size: 22, color: Tga.iconPurple),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                        child: Text('SSH 远程工作区',
                            style: Tga.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    if (sshCurrent) TgaTag('当前', color: Tga.primary),
                    const SizedBox(width: 6),
                    TgaTag('TCP 可达', color: Tga.cyan),
                  ],
                ),
                const SizedBox(height: 6),
                Text('$user@$host:$port'
                    '${tested.isEmpty ? '' : ' · 测试于 $tested'}',
                    style: Tga.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          _MoreMenu(onSelected: (String v) {
            switch (v) {
              case 'current':
                _setSshCurrent();
              case 'rename':
                _createSshWorkspace(); // 重新编辑配置
              case 'delete':
                _deleteSsh();
            }
          }),
        ],
      ),
    );
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({required this.onSelected});
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: onSelected,
      color: Tga.card,
      icon: Icon(Icons.more_vert_rounded, size: 20, color: Tga.textDim),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
            value: 'current', child: Text('设为当前', style: Tga.body)),
        PopupMenuItem<String>(
            value: 'rename', child: Text('重命名', style: Tga.body)),
        PopupMenuItem<String>(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: Tga.red, fontSize: 14))),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// SSH 表单：主机/端口/用户名/认证方式 + 真实 TCP 可达性测试
// ---------------------------------------------------------------------------
class _SshFormDialog extends StatefulWidget {
  const _SshFormDialog({required this.initial, required this.onConnected});

  final Map<String, dynamic>? initial;
  final Future<void> Function(Map<String, dynamic> cfg) onConnected;

  @override
  State<_SshFormDialog> createState() => _SshFormDialogState();
}

class _SshFormDialogState extends State<_SshFormDialog> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late String _auth;

  bool _testing = false;
  String _result = '';

  @override
  void initState() {
    super.initState();
    _host = TextEditingController(text: (widget.initial?['host'] ?? '').toString());
    _port = TextEditingController(text: (widget.initial?['port'] ?? '22').toString());
    _user = TextEditingController(text: (widget.initial?['user'] ?? '').toString());
    _auth = (widget.initial?['auth'] ?? '密码').toString();
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    super.dispose();
  }

  /// 真实 TCP 探测：仅验证端口可达，不做任何认证。
  Future<void> _testConnection() async {
    final String host = _host.text.trim();
    final int port = int.tryParse(_port.text.trim()) ?? 0;
    if (host.isEmpty || port < 1 || port > 65535) {
      setState(() => _result = '请填写有效主机与端口（1~65535）');
      return;
    }
    setState(() {
      _testing = true;
      _result = '';
    });
    String err = '';
    try {
      final Socket socket =
          await Socket.connect(host, port, timeout: const Duration(seconds: 5));
      socket.destroy();
    } on SocketException catch (e) {
      err = e.osError?.message ?? e.message;
    } on TimeoutException {
      err = '连接超时（5 秒）';
    } on Object catch (e) {
      err = '$e';
    }
    if (!mounted) return;
    if (err.isEmpty) {
      final Map<String, dynamic> cfg = <String, dynamic>{
        'host': host,
        'port': port,
        'user': _user.text.trim(),
        'auth': _auth,
        'tested_at': DateTime.now().toIso8601String().substring(0, 19),
      };
      await widget.onConnected(cfg);
      if (mounted) Navigator.of(context).pop(true);
    } else {
      setState(() {
        _testing = false;
        _result = 'TCP 不可达：$err';
      });
    }
  }

  Widget _field(String label, TextEditingController ctrl,
      {String? hint, TextInputType? keyboard}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboard,
        decoration: InputDecoration(
            labelText: label, hintText: hint, isDense: true),
        style: Tga.body,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Tga.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text('SSH 远程工作区', style: Tga.h2),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _field('主机', _host, hint: '如 192.168.1.10'),
            _field('端口', _port, hint: '22', keyboard: TextInputType.number),
            _field('用户名', _user, hint: '如 deploy'),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: <Widget>[
                  Text('认证方式', style: Tga.sub),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: _auth,
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
            ),
            const SizedBox(height: 4),
            Text(
              '「连接测试」用 Socket.connect 真实探测端口 TCP 可达性（5 秒超时），'
              '不做假认证；密码/私钥不会保存到本机。',
              style: Tga.caption,
            ),
            if (_result.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(_result,
                  style: TextStyle(fontSize: 12, color: Tga.red)),
            ],
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TgaButton(
                      label: '取消',
                      onTap: () => Navigator.of(context).pop(false),
                      filled: false),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _testing
                      ? Center(
                          child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2.4, color: Tga.primary)))
                      : TgaButton(
                          label: '连接测试',
                          onTap: _testConnection),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
