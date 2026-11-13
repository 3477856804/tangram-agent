import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../services/persona_store.dart';
import '../../services/ssh_workspace.dart';

/// 工作区域（真实化改造）：
/// - 「工作区」列表来自 PersonaStore.workspaceRoot 指向的真实目录：
///   存在性用 device_file list 校验（沙箱外路径退回 dart:io 真实探测），
///   不存在显示「未初始化」；⋮ 菜单支持设为当前 / 重命名（改记录别名）/ 删除。
/// - 「本地工作区」= device_file mkdir 真实创建目录 + setWorkspaceRoot
///   + rpc sandbox_policy_set{environment:'工作区沙箱'}。
/// - 「SSH 远程工作区」= dartssh2 真实握手与认证（密码 / 私钥），
///   「连接测试」实际登录远端并 exec `echo ok` 验证、取回 `uname -a`；
///   点条目进入真实 sftp 目录浏览。配置与凭据存 flutter_secure_storage。
class TgaWorkspacePage extends StatefulWidget {
  const TgaWorkspacePage({super.key});

  @override
  State<TgaWorkspacePage> createState() => _TgaWorkspacePageState();
}

class _TgaWorkspacePageState extends State<TgaWorkspacePage> {
  /// 本地工作区别名的安全存储 key。
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _aliasKey = 'tangram.workspace.alias.v1';

  /// 本地工作区在 App 沙箱内的相对目录（device_file 以此为根）。
  static const String _localRel = 'workspace';

  /// SSH 远程工作区服务（真实握手/认证/sftp + 配置加密持久化）。
  final SshWorkspace _sshWs = SshWorkspace();

  /// 沙箱根绝对路径（device_file status 返回的 roots[0]）。
  String _sandboxRoot = '';

  /// 本地工作区校验状态：none / ready / missing / external。
  String _localState = 'none';
  bool _loading = true;
  String _loadError = '';

  /// 已保存的 SSH 配置，null 表示尚未配置。
  SshWorkspaceConfig? _ssh;

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
      // 2) 读 SSH 配置（安全存储）与别名。
      _ssh = await _sshWs.load();
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
  // SSH 远程工作区（dartssh2 真实握手/认证 + sftp 浏览）
  // ---------------------------------------------------------------------------

  Future<void> _createSshWorkspace() async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) =>
          _SshFormDialog(initial: _ssh, workspace: _sshWs),
    );
    if (saved == true) {
      _ssh = await _sshWs.load();
      if (mounted) setState(() {});
    }
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
      _toast('已将远端设为当前工作区（仅浏览与展示，Agent 写文件仍走本地）');
    } on Object {
      _toast('已切换（沙箱策略未同步：后端未就绪）');
    }
    setState(() {});
  }

  Future<void> _deleteSsh() async {
    final PersonaStore persona = context.read<PersonaStore>();
    final bool ok = await _confirm(
      title: '删除 SSH 工作区配置？',
      message: '将清除本机加密保存的连接配置与凭据；不会断开远端任何服务。',
    );
    if (!ok) return;
    await _sshWs.delete();
    _ssh = null;
    if (persona.sandboxEnvironment == '远端沙箱（SSH）') {
      persona.setSandboxEnvironment('内置沙箱');
    }
    if (mounted) setState(() {});
    _toast('SSH 配置已清除');
  }

  void _openSshBrowser(SshWorkspaceConfig cfg) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (BuildContext _) =>
          _SshBrowserPage(config: cfg, workspace: _sshWs),
    ));
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
              subtitle: '真实 SSH 握手认证（密码/私钥），sftp 浏览远端目录',
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
                    subtitle: '连接自己的服务器（真实握手认证 + sftp 浏览）',
                    onTap: _createSshWorkspace,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '工作区为 Agent 提供隔离的可写目录。SSH 远程工作区基于 dartssh2 '
                '与远端完成真实 TCP + SSH 握手与认证（密码 / 私钥，私钥可带口令）：'
                '「连接测试」会实际登录远端、执行 `echo ok` 验证命令通道，'
                '并取回 `uname -a` 系统信息；点远端条目可用真实 sftp 浏览目录。'
                '连接配置与凭据加密存于本机（FlutterSecureStorage），不落明文磁盘。'
                '将远端设为当前工作区后仅用于浏览与展示，Agent 写文件仍在本地'
                '沙箱目录进行。',
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
                    if (!sshCurrent)
                      TgaTag('当前', color: Tga.primary)
                    else
                      TgaTag('写入位置', color: Tga.gold),
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
    final SshWorkspaceConfig cfg = _ssh!;
    final bool verified = cfg.verifiedAt.isNotEmpty;
    final String verifiedAt =
        cfg.verifiedAt.length >= 16 ? cfg.verifiedAt.substring(0, 16).replaceAll('T', ' ') : cfg.verifiedAt;
    return TgaCard(
      padding: const EdgeInsets.all(14),
      onTap: () => _openSshBrowser(cfg),
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
                    TgaTag('远端', color: Tga.purple),
                    const SizedBox(width: 6),
                    TgaTag(verified ? '已验证' : '未验证',
                        color: verified ? Tga.green : Tga.orange),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                    '${cfg.user}@${cfg.host}:${cfg.port} · ${cfg.auth}认证'
                    '${verified ? ' · 验证于 $verifiedAt' : ''}',
                    style: Tga.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (verified && cfg.remoteInfo.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(cfg.remoteInfo,
                        style: Tga.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
              ],
            ),
          ),
          _MoreMenu(renameLabel: '编辑配置', onSelected: (String v) {
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
  const _MoreMenu({required this.onSelected, this.renameLabel = '重命名'});
  final ValueChanged<String> onSelected;
  final String renameLabel;

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
            value: 'rename', child: Text(renameLabel, style: Tga.body)),
        PopupMenuItem<String>(
            value: 'delete',
            child: Text('删除', style: TextStyle(color: Tga.red, fontSize: 14))),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// SSH 表单：主机/端口/用户名/认证方式（密码/私钥）+ dartssh2 真实握手认证测试
// ---------------------------------------------------------------------------
class _SshFormDialog extends StatefulWidget {
  const _SshFormDialog({required this.initial, required this.workspace});

  final SshWorkspaceConfig? initial;
  final SshWorkspace workspace;

  @override
  State<_SshFormDialog> createState() => _SshFormDialogState();
}

class _SshFormDialogState extends State<_SshFormDialog> {
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _user;
  late final TextEditingController _secret;
  late final TextEditingController _passphrase;
  late String _auth;

  bool _testing = false;
  bool _ok = false;
  String _result = '';

  bool get _isKey => _auth == '私钥';

  @override
  void initState() {
    super.initState();
    final SshWorkspaceConfig? ini = widget.initial;
    _host = TextEditingController(text: ini?.host ?? '');
    _port = TextEditingController(text: (ini?.port ?? 22).toString());
    _user = TextEditingController(text: ini?.user ?? '');
    _auth = ini?.auth ?? '密码';
    _secret = TextEditingController(text: ini?.secret ?? '');
    _passphrase = TextEditingController(text: ini?.passphrase ?? '');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _secret.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  /// 真实连接测试：dartssh2 握手 + 认证 + exec `echo ok` 验证 + `uname -a`。
  /// 成功后立即把配置（含 verifiedAt / uname）写入安全存储。
  Future<void> _testConnection() async {
    final String host = _host.text.trim();
    final int port = int.tryParse(_port.text.trim()) ?? 0;
    final String user = _user.text.trim();
    final String secret = _isKey ? _secret.text : _secret.text.trim();
    if (host.isEmpty || port < 1 || port > 65535 || user.isEmpty) {
      setState(() {
        _ok = false;
        _result = '请填写有效主机、用户名与端口（1~65535）';
      });
      return;
    }
    if (secret.isEmpty) {
      setState(() {
        _ok = false;
        _result = _isKey ? '请粘贴 OpenSSH 私钥文本' : '请输入密码';
      });
      return;
    }
    setState(() {
      _testing = true;
      _ok = false;
      _result = '';
    });
    final SshWorkspaceConfig cfg = SshWorkspaceConfig(
      host: host,
      port: port,
      user: user,
      auth: _auth,
      secret: secret,
      passphrase: _passphrase.text,
    );
    final SshConnectResult r = await widget.workspace.testConnection(cfg);
    if (!mounted) return;
    if (!r.ok) {
      setState(() {
        _testing = false;
        _result = r.error;
      });
      return;
    }
    final SshWorkspaceConfig saved = cfg.copyWith(
      verifiedAt: DateTime.now().toIso8601String().substring(0, 19),
      remoteInfo: r.uname,
    );
    try {
      await widget.workspace.save(saved);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _result = '连接成功，但配置保存失败：$e';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _ok = true;
      _result = '握手成功 · ${r.remoteVersion}\n远端：${r.uname}';
    });
  }

  Widget _field(String label, TextEditingController ctrl,
      {String? hint, TextInputType? keyboard, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboard,
        obscureText: obscure,
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
        child: SingleChildScrollView(
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
                      onChanged: (String? v) => setState(() {
                        _auth = v ?? '密码';
                        _ok = false;
                        _result = '';
                      }),
                    ),
                  ],
                ),
              ),
              if (_isKey) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: TextField(
                    controller: _secret,
                    maxLines: 4,
                    decoration: const InputDecoration(
                        labelText: '私钥文本',
                        hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                        isDense: true),
                    style: TextStyle(fontSize: 12, color: Tga.text),
                  ),
                ),
                _field('密钥口令（加密私钥时填写）', _passphrase, obscure: true),
              ] else
                _field('密码', _secret, obscure: true),
              const SizedBox(height: 4),
              Text(
                '「连接测试」用 dartssh2 真实登录远端：完成 TCP + SSH 握手、'
                '密码/私钥认证，并实际执行 `echo ok` 与 `uname -a` 验证。'
                '通过后配置与凭据加密存于本机。',
                style: Tga.caption,
              ),
              if (_result.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(_result,
                    style: TextStyle(
                        fontSize: 12,
                        color: _ok ? Tga.green : Tga.red,
                        height: 1.4)),
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
                            label: _ok ? '完成' : '连接测试',
                            onTap: () {
                              if (_ok) {
                                Navigator.of(context).pop(true);
                              } else {
                                _testConnection();
                              }
                            },
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 远端目录浏览：真实 sftp listdir（目录/文件 + 大小 + mtime）
// ---------------------------------------------------------------------------
class _SshBrowserPage extends StatefulWidget {
  const _SshBrowserPage({required this.config, required this.workspace});

  final SshWorkspaceConfig config;
  final SshWorkspace workspace;

  @override
  State<_SshBrowserPage> createState() => _SshBrowserPageState();
}

class _SshBrowserPageState extends State<_SshBrowserPage> {
  String _path = '';
  List<SshDirEntry> _entries = <SshDirEntry>[];
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load('');
  }

  /// [path] 为空串时由服务端解析远端登录用户 home 目录。
  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final SshListing listing = await widget.workspace.listDir(
        widget.config,
        path,
      );
      if (!mounted) return;
      setState(() {
        _path = listing.path;
        _entries = listing.entries;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = SshWorkspace.describeError(e);
      });
    }
  }

  String _join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  String get _parent {
    if (_path.isEmpty || _path == '/') return _path;
    final int i = _path.lastIndexOf('/');
    return i <= 0 ? '/' : _path.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    final SshWorkspaceConfig cfg = widget.config;
    return TgaPage(
      title: '远端目录',
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
          tooltip: '刷新',
          onPressed: () => _load(_path),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, Tga.pagePad, 2),
            child: Row(
              children: <Widget>[
                IconButton(
                  icon: Icon(Icons.arrow_upward_rounded,
                      size: 20,
                      color: (_path.isEmpty || _path == '/')
                          ? Tga.textDim
                          : Tga.primary),
                  tooltip: '上级目录',
                  onPressed: (_loading || _path.isEmpty || _path == '/')
                      ? null
                      : () => _load(_parent),
                ),
                Expanded(
                  child: Text(_loading && _path.isEmpty ? '连接中…' : _path,
                      style: Tga.sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Tga.pagePad, 0, Tga.pagePad, 6),
            child: Text(
              '${cfg.user}@${cfg.host}:${cfg.port} · 真实 sftp 浏览，'
              '仅供查看；Agent 写文件仍走本地沙箱目录。',
              style: Tga.caption,
            ),
          ),
          Expanded(
            child: _buildBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: SizedBox(
            width: 26,
            height: 26,
            child:
                CircularProgressIndicator(strokeWidth: 2.4, color: Tga.primary)),
      );
    }
    if (_error.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
        children: <Widget>[
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(_error,
                    style: TextStyle(fontSize: 13, color: Tga.red, height: 1.4)),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: TgaButton(label: '重试', onTap: () => _load(_path)),
                ),
              ],
            ),
          ),
        ],
      );
    }
    if (_entries.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
        children: const <Widget>[
          TgaCard(
            child: TgaEmpty('空目录', icon: Icons.folder_open_outlined),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(_path),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
        children: <Widget>[
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                for (int i = 0; i < _entries.length; i++) ...<Widget>[
                  if (i > 0) const TgaTileDivider(),
                  _entryTile(_entries[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryTile(SshDirEntry e) {
    return TgaIconTile(
      icon: e.isDirectory ? Icons.folder_rounded : Icons.description_outlined,
      iconBg: e.isDirectory ? Tga.iconGoldBg : Tga.iconBlueBg,
      iconColor: e.isDirectory ? Tga.iconGold : Tga.iconBlue,
      title: e.name,
      subtitle: e.isDirectory
          ? '目录'
          : '${_fmtSize(e.size)} · ${_fmtMtime(e.mtime)}',
      showArrow: e.isDirectory,
      onTap: e.isDirectory ? () => _load(_join(_path, e.name)) : null,
    );
  }
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
}

String _fmtMtime(DateTime? d) {
  if (d == null) return '时间未知';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}
