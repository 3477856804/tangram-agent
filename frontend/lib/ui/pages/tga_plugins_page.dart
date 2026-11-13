import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 插件社区（2026-11-13 真实化）：
/// - 插件标签：已安装 = `plugin_lifecycle list`（真实 plugins 池 JSON 文件，
///   ⋮ 菜单可 `uninstall`）；发现精选 = `plugin_community catalog`（内置能力
///   清单，点击 → `install` 真实落盘注册记录）。
/// - 技能标签：`plugin_community skills_list` 真实扫描 skills 目录；空态提示
///   可用 ＋ 从本地添加（经 `plugin_community skill_add` 真实写入 skills/）。
/// - MCP 服务标签：`mcp_list` 真实读取 mcp_servers.json；每条显示
///   name / transport / command+args 或 url，⋮ 菜单 `mcp_remove` 删除；
///   ＋ 弹表单（stdio 命令 或 SSE URL）→ `mcp_add`。
/// - ＋ 按钮按当前标签分流：插件 = file_picker 选 .json → `install_local`；
///   技能 = file_picker 选 .md/.json → device_file write；MCP = 添加表单。
/// - 所有添加 / 安装 / 卸载后即时刷新对应列表，成功失败 toast 如实转述
///   后端 error，不粉饰。
class TgaPluginsPage extends StatefulWidget {
  const TgaPluginsPage({super.key});

  @override
  State<TgaPluginsPage> createState() => _TgaPluginsPageState();
}

class _TgaPluginsPageState extends State<TgaPluginsPage> {
  String _tab = '插件';
  bool _busy = false;
  String _loadError = '';

  /// plugin_lifecycle list 的真实已安装插件（name 含 .json 文件名）。
  List<Map<String, dynamic>> _installed = <Map<String, dynamic>>[];
  String _poolDir = '';
  /// plugin_community catalog 的内置能力条目。
  List<Map<String, dynamic>> _catalog = <Map<String, dynamic>>[];
  /// plugin_community skills_list 的真实技能文件。
  List<Map<String, dynamic>> _skills = <Map<String, dynamic>>[];
  String _skillsDir = '';
  /// plugin_community mcp_list 的真实 MCP 配置。
  List<Map<String, dynamic>> _mcp = <Map<String, dynamic>>[];
  /// plugin_community mcp_sync 的真实连接结果（connected/failed/skipped）。
  Map<String, dynamic> _mcpStatus = const <String, dynamic>{};
  bool _mcpSyncing = false;

  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshAll();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Map<String, dynamic> _asMap(Map<dynamic, dynamic> m) =>
      m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((Map<dynamic, dynamic> e) => _asMap(e))
        .toList();
  }

  /// 一次性拉全四类真实数据（切标签时也复用，保证列表即时刷新）。
  Future<void> _refreshAll() async {
    final BackendClient backend = context.read<BackendClient>();
    setState(() => _busy = true);
    final List<String> errors = <String>[];
    try {
      final env = await backend.sendControl(
          'plugin_lifecycle', <String, dynamic>{'action': 'list'});
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _installed = _mapList(p['plugins']);
        _poolDir = (p['pool'] ?? '').toString();
      } else {
        errors.add('已安装插件加载失败：'
            '${p is Map ? p['error'] ?? '非预期结构' : '非预期结构'}');
      }
    } on Object catch (e) {
      errors.add('已安装插件加载失败：$e');
    }
    try {
      final env = await backend.sendControl(
          'plugin_community', <String, dynamic>{'action': 'catalog'});
      final dynamic p = env.payload;
      _catalog = p is Map ? _mapList(p['items']) : <Map<String, dynamic>>[];
    } on Object catch (e) {
      errors.add('精选目录加载失败：$e');
    }
    try {
      final env = await backend.sendControl(
          'plugin_community', <String, dynamic>{'action': 'skills_list'});
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _skills = _mapList(p['skills']);
        _skillsDir = (p['dir'] ?? '').toString();
      } else {
        errors.add('技能列表加载失败：'
            '${p is Map ? p['error'] ?? '非预期结构' : '非预期结构'}');
      }
    } on Object catch (e) {
      errors.add('技能列表加载失败：$e');
    }
    try {
      final env = await backend.sendControl(
          'plugin_community', <String, dynamic>{'action': 'mcp_list'});
      final dynamic p = env.payload;
      _mcp = p is Map && p['ok'] == true
          ? _mapList(p['servers'])
          : <Map<String, dynamic>>[];
      if (p is Map && p['ok'] != true) {
        errors.add('MCP 列表加载失败：${p['error'] ?? '非预期结构'}');
      }
    } on Object catch (e) {
      errors.add('MCP 列表加载失败：$e');
    }
    if (!mounted) return;
    setState(() {
      _loadError = errors.join('；');
      _busy = false;
    });
  }

  /// 已安装插件展示名：后端 list 返回的是文件名（含 .json），去掉后缀。
  static String _pluginName(Map<String, dynamic> row) {
    final String raw = (row['name'] ?? row['id'] ?? '').toString();
    return raw.endsWith('.json')
        ? raw.substring(0, raw.length - 5)
        : raw;
  }

  bool _match(String text) {
    final String kw = _searchCtrl.text.trim().toLowerCase();
    if (kw.isEmpty) return true;
    return text.toLowerCase().contains(kw);
  }

  // ---------------------------------------------------------------- 插件动作

  /// 安装精选条目（plugin_community install → 真实写入 plugins 池）。
  Future<void> _installCatalog(String name) async {
    final BackendClient backend = context.read<BackendClient>();
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{'action': 'install', 'name': name});
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _toast('已安装「$name」（写入本地插件池）');
      } else {
        _toast('安装失败：${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('安装请求失败：$e');
    }
    await _refreshAll();
  }

  Future<void> _uninstall(String name) async {
    final BackendClient backend = context.read<BackendClient>();
    try {
      final env = await backend.sendControl('plugin_lifecycle',
          <String, dynamic>{'action': 'uninstall', 'name': name});
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _toast('已卸载「$name」');
      } else {
        _toast('卸载失败：插件文件不存在或后端返回 ok=false（$name）');
      }
    } on Object catch (e) {
      _toast('卸载请求失败：$e');
    }
    await _refreshAll();
  }

  void _confirmUninstall(String name) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('卸载「$name」？'),
        content: const Text('将删除插件池里对应的本地注册文件，操作不可恢复。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              unawaited(_uninstall(name));
            },
            child: const Text('卸载'),
          ),
        ],
      ),
    );
  }

  /// ＋（插件标签）：file_picker 选 .json → 读文本 → install_local。
  Future<void> _addPluginFromLocal() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['json'],
        withData: true,
      );
      final PlatformFile? file =
          (result?.files.isNotEmpty ?? false) ? result!.files.first : null;
      if (file == null) return; // 用户取消
      final String? text = _readFileText(file);
      if (text == null) {
        _toast('无法把「${file.name}」读成 UTF-8 文本，请确认是 JSON 文件');
        return;
      }
      final String name = file.name.endsWith('.json')
          ? file.name.substring(0, file.name.length - 5)
          : file.name;
      if (!mounted) return;
      final BackendClient backend = context.read<BackendClient>();
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{
            'action': 'install_local',
            'name': name,
            'content': text,
          });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _toast('已从本地文件安装「$name」');
      } else {
        _toast('安装失败：'
            '${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('选择/安装本地插件失败：$e');
    }
    await _refreshAll();
  }

  // ---------------------------------------------------------------- 技能动作

  /// ＋（技能标签）：file_picker 选 .md/.json → 经 plugin_community skill_add
  /// 真实写入 skills/ 目录（device_file 根限定 sandbox/，越界不可达）。
  Future<void> _addSkillFromLocal() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['md', 'json'],
        withData: true,
      );
      final PlatformFile? file =
          (result?.files.isNotEmpty ?? false) ? result!.files.first : null;
      if (file == null) return; // 用户取消
      final String? text = _readFileText(file);
      if (text == null) {
        _toast('无法把「${file.name}」读成文本，请确认是 .md/.json 文件');
        return;
      }
      if (!mounted) return;
      final BackendClient backend = context.read<BackendClient>();
      final env = await backend.sendControl('plugin_community', <String, dynamic>{
        'action': 'skill_add',
        'name': file.name,
        'content': text,
      });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        final Map<String, dynamic> data =
            p['data'] is Map ? _asMap(p['data'] as Map) : <String, dynamic>{};
        final String written = (data['path'] ?? '').toString();
        _toast('已写入技能文件：${written.isEmpty ? file.name : written}');
      } else {
        _toast('写入失败：'
            '${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('添加本地技能失败：$e');
    }
    await _refreshAll();
  }

  /// 优先用 file_picker 带回的字节；个别平台只给路径时回退读文件。
  static String? _readFileText(PlatformFile file) {
    try {
      if (file.bytes != null) return utf8.decode(file.bytes!);
      final String? path = file.path;
      if (path != null) return File(path).readAsStringSync();
    } on Object {
      // 解码/读取失败统一返回 null，由调用方如实 toast。
    }
    return null;
  }

  // ---------------------------------------------------------------- MCP 动作

  /// ＋（MCP 标签）：弹表单（名称 / stdio 命令+参数 或 SSE URL）→ mcp_add。
  Future<void> _showMcpForm() async {
    final TextEditingController nameCtrl = TextEditingController();
    final TextEditingController cmdCtrl = TextEditingController();
    final TextEditingController argsCtrl = TextEditingController();
    final TextEditingController urlCtrl = TextEditingController();
    String transport = 'stdio';

    final bool? submit = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDlg) => AlertDialog(
          title: const Text('添加 MCP 服务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                      labelText: '名称 *', isDense: true),
                ),
                const SizedBox(height: 10),
                TgaSegmented<String>(
                  items: const <String>['stdio', 'sse'],
                  value: transport,
                  labelOf: (String s) => s,
                  onChanged: (String v) => setDlg(() => transport = v),
                ),
                const SizedBox(height: 10),
                if (transport == 'stdio') ...<Widget>[
                  TextField(
                    controller: cmdCtrl,
                    decoration: const InputDecoration(
                        labelText: '启动命令 *（如 npx）', isDense: true),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: argsCtrl,
                    decoration: const InputDecoration(
                        labelText: '参数（空格分隔，可空）', isDense: true),
                  ),
                ] else ...<Widget>[
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                        labelText: 'SSE URL *（http/https）', isDense: true),
                  ),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('添加')),
          ],
        ),
      ),
    );
    final String name = nameCtrl.text.trim();
    final String command = cmdCtrl.text.trim();
    final String url = urlCtrl.text.trim();
    final List<String> args = argsCtrl.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((String s) => s.isNotEmpty)
        .toList();
    nameCtrl.dispose();
    cmdCtrl.dispose();
    argsCtrl.dispose();
    urlCtrl.dispose();
    if (submit != true) return;

    if (name.isEmpty) {
      _toast('MCP 服务名不能为空');
      return;
    }
    if (transport == 'stdio' && command.isEmpty) {
      _toast('stdio 传输必须填写启动命令');
      return;
    }
    if (transport == 'sse' && !url.startsWith('http')) {
      _toast('SSE 传输必须填写 http/https URL');
      return;
    }
    if (!mounted) return;
    final BackendClient backend = context.read<BackendClient>();
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{
            'action': 'mcp_add',
            'name': name,
            'transport': transport,
            'command': command,
            'args': args,
            'url': url,
          });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _toast('已添加 MCP 服务「$name」（当前共 ${p['count'] ?? '?'} 个）');
        if (p['mcp_status'] is Map) {
          setState(() => _mcpStatus = _asMap(p['mcp_status'] as Map));
        }
      } else {
        _toast('添加失败：${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('添加请求失败：$e');
    }
    await _refreshAll();
  }

  /// 手动重连全部 MCP 服务，展示真实 connected/failed/skipped 结果。
  Future<void> _syncMcp() async {
    if (_mcpSyncing) return;
    setState(() => _mcpSyncing = true);
    final BackendClient backend = context.read<BackendClient>();
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{'action': 'mcp_sync'});
      final dynamic p = env.payload;
      if (!mounted) return;
      setState(() {
        _mcpSyncing = false;
        if (p is Map && p['ok'] == true) {
          _mcpStatus = _asMap(p);
        }
      });
      final int n = _mcpStatus['registered_tools'] is int
          ? _mcpStatus['registered_tools'] as int
          : 0;
      _toast(n > 0
          ? 'MCP 重连完成：已注册 $n 个真实工具进 AgentLoop'
          : 'MCP 重连完成：无可用 HTTP/SSE 服务（stdio 需桌面/网关侧运行）');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _mcpSyncing = false);
      _toast('重连失败：$e');
    }
  }

  Future<void> _removeMcp(String name) async {
    final BackendClient backend = context.read<BackendClient>();
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{'action': 'mcp_remove', 'name': name});
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _toast('已删除 MCP 服务「$name」');
      } else {
        _toast('删除失败：${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('删除请求失败：$e');
    }
    await _refreshAll();
  }

  // -------------------------------------------------------------------- UI

  void _onPlus() {
    switch (_tab) {
      case '插件':
        unawaited(_addPluginFromLocal());
        break;
      case '技能':
        unawaited(_addSkillFromLocal());
        break;
      default:
        unawaited(_showMcpForm());
    }
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  Widget _menuTrailing(List<String> actions, void Function(String) onPick) {
    return PopupMenuButton<String>(
      tooltip: '更多操作',
      icon: Icon(Icons.more_vert_rounded, size: 18, color: Tga.textSub),
      padding: EdgeInsets.zero,
      onSelected: (String v) => onPick(v),
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
        for (final String a in actions)
          PopupMenuItem<String>(value: a, child: Text(a)),
      ],
    );
  }

  /// 插件标签：已安装（lifecycle）+ 发现精选（community catalog）。
  List<Widget> _pluginTab() {
    final List<Map<String, dynamic>> installed = _installed
        .where((Map<String, dynamic> r) => _match(_pluginName(r)))
        .toList();
    final Set<String> installedNames =
        _installed.map(_pluginName).toSet();
    final List<Map<String, dynamic>> discover = _catalog
        .where((Map<String, dynamic> r) => _match(
            '${r['name'] ?? ''} ${r['description'] ?? ''}'))
        .toList();

    return <Widget>[
      TgaGroupTitle(
        '已安装',
        trailing: TgaTag('${installed.length} 个', color: Tga.textSub),
      ),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: installed.isEmpty
            ? const TgaEmpty('还没有安装任何插件，点右侧「＋」从本地 JSON 添加',
                icon: Icons.extension_off_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < installed.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    TgaIconTile(
                      icon: Icons.extension_outlined,
                      title: _pluginName(installed[i]),
                      subtitle: '版本 ${installed[i]['latest'] ?? '—'} · '
                          '依赖 ${installed[i]['dep_status'] ?? '—'} · '
                          '权限 ${installed[i]['permission'] ?? '—'}',
                      showArrow: false,
                      trailing: _menuTrailing(
                        const <String>['卸载'],
                        (String v) =>
                            _confirmUninstall(_pluginName(installed[i])),
                      ),
                    ),
                  ],
                ],
              ),
      ),
      if (_poolDir.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text('插件池目录：$_poolDir', style: Tga.caption),
        ),
      TgaGroupTitle(
        '发现精选',
        trailing: _busy
            ? SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Tga.primary),
              )
            : GestureDetector(
                onTap: _refreshAll,
                child: Text('刷新',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Tga.primary)),
              ),
      ),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: discover.isEmpty
            ? const TgaEmpty('精选目录为空', icon: Icons.explore_off_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < discover.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    TgaIconTile(
                      icon: Icons.explore_outlined,
                      iconBg: Tga.iconPurpleBg,
                      iconColor: Tga.iconPurple,
                      title: (discover[i]['name'] ?? '').toString(),
                      subtitle: '${discover[i]['kind'] ?? ''} · '
                          '${discover[i]['source'] ?? ''} · '
                          '${discover[i]['description'] ?? ''}',
                      showArrow: false,
                      trailing: installedNames
                              .contains((discover[i]['name'] ?? '').toString())
                          ? TgaTag('已安装', color: Tga.green)
                          : TgaButton(
                              label: '安装',
                              filled: false,
                              onTap: () => unawaited(_installCatalog(
                                  (discover[i]['name'] ?? '').toString())),
                            ),
                    ),
                  ],
                ],
              ),
      ),
    ];
  }

  /// 技能标签：skills_list 真实扫描结果。
  List<Widget> _skillTab() {
    final List<Map<String, dynamic>> visible = _skills
        .where((Map<String, dynamic> r) => _match(
            '${r['name'] ?? ''} ${r['description'] ?? ''}'))
        .toList();
    return <Widget>[
      TgaGroupTitle(
        '本地技能',
        trailing: TgaTag('${visible.length} 个', color: Tga.textSub),
      ),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: visible.isEmpty
            ? const TgaEmpty('技能目录为空，可用 ＋ 从本地添加',
                icon: Icons.psychology_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < visible.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    TgaIconTile(
                      icon: Icons.psychology_alt_outlined,
                      iconBg: Tga.iconCyanBg,
                      iconColor: Tga.iconCyan,
                      title: (visible[i]['name'] ?? '').toString(),
                      subtitle: '${visible[i]['description'] ?? ''} · '
                          '${_fmtBytes(visible[i]['size'] is num ? (visible[i]['size'] as num).toInt() : 0)}',
                      showArrow: false,
                    ),
                  ],
                ],
              ),
      ),
      if (_skillsDir.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text('技能扫描目录：$_skillsDir', style: Tga.caption),
        ),
    ];
  }

  /// MCP 服务标签：mcp_list 真实配置。
  List<Widget> _mcpTab() {
    final List<Map<String, dynamic>> visible =
        _mcp.where((Map<String, dynamic> r) => _match((r['name'] ?? '').toString()))
            .toList();
    return <Widget>[
      TgaGroupTitle(
        'MCP 服务',
        trailing: TextButton.icon(
          onPressed: _mcpSyncing ? null : () => unawaited(_syncMcp()),
          icon: Icon(Icons.sync_rounded, size: 16, color: Tga.groupTitle),
          label: Text(_mcpSyncing ? '连接中…' : '重连并查看状态',
              style: TextStyle(color: Tga.groupTitle, fontSize: 13)),
        ),
      ),
      if (_mcpStatus.isNotEmpty) _mcpStatusCard(),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: visible.isEmpty
            ? const TgaEmpty('还没有配置 MCP 服务，用 ＋ 添加（stdio 命令或 SSE URL）',
                icon: Icons.hub_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < visible.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    TgaIconTile(
                      icon: Icons.dns_outlined,
                      iconBg: Tga.iconGoldBg,
                      iconColor: Tga.iconGold,
                      title: (visible[i]['name'] ?? '').toString(),
                      subtitle: _mcpSubtitle(visible[i]),
                      showArrow: false,
                      trailing: _menuTrailing(
                        const <String>['删除'],
                        (String v) => unawaited(
                            _removeMcp((visible[i]['name'] ?? '').toString())),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    ];
  }

  /// stdio 显示 command + args，其余（sse/http）显示 url。
  static String _mcpSubtitle(Map<String, dynamic> row) {
    final String transport = (row['transport'] ?? 'stdio').toString();
    if (transport == 'stdio') {
      final List<dynamic> args =
          row['args'] is List ? row['args'] as List : <dynamic>[];
      final String argText = args.map((dynamic a) => a.toString()).join(' ');
      return 'stdio · ${(row['command'] ?? '').toString()}'
          '${argText.isEmpty ? '' : ' $argText'}';
    }
    return '$transport · ${(row['url'] ?? '—').toString()}';
  }

  /// mcp_sync 的真实结果面板：已连接（列出注册进 AgentLoop 的工具名）、
  /// 连接失败（后端原始错误）、移动端跳过（如实说明 stdio 限制）。
  Widget _mcpStatusCard() {
    final connected = _mcpStatus['connected'] is List
        ? (_mcpStatus['connected'] as List).whereType<Map>().toList()
        : <Map>[];
    final failed = _mcpStatus['failed'] is List
        ? (_mcpStatus['failed'] as List).whereType<Map>().toList()
        : <Map>[];
    final skipped = _mcpStatus['skipped'] is List
        ? (_mcpStatus['skipped'] as List).whereType<Map>().toList()
        : <Map>[];
    final rows = <Widget>[];
    for (final c in connected) {
      final tools = c['tools'] is List
          ? (c['tools'] as List).map((t) => t.toString()).join('、')
          : '';
      rows.add(_statusRow(Icons.link_rounded, Tga.green,
          '${c['name']}：已连接，注册 ${tools.isEmpty ? '0' : '${(c['tools'] as List).length}'} 个工具（$tools）'));
    }
    for (final f in failed) {
      rows.add(_statusRow(Icons.link_off_rounded, Tga.red,
          '${f['name']}：连接失败（${f['error']}）'));
    }
    for (final s in skipped) {
      rows.add(_statusRow(Icons.info_outline_rounded, Tga.textSub,
          '${s['name']}：未启用（${s['reason']}）'));
    }
    if (rows.isEmpty) {
      rows.add(_statusRow(Icons.info_outline_rounded, Tga.textSub,
          '没有已配置的 MCP 服务被连接'));
    }
    return TgaCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _statusRow(IconData icon, Color color, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: Tga.sub)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '插件社区',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
        children: <Widget>[
          // ---------- 顶部分段（切换即刷新，保证数据即时） ----------
          _TabBar(
            items: const <String>['插件', '技能', 'MCP 服务'],
            value: _tab,
            onChanged: (String v) {
              setState(() => _tab = v);
              unawaited(_refreshAll());
            },
          ),
          const SizedBox(height: 14),
          // ---------- 搜索框 + 加号（按当前标签分流） ----------
          Row(
            children: <Widget>[
              Expanded(
                child: TgaSearchField(
                  hint: _tab == 'MCP 服务'
                      ? '搜索 MCP 服务名'
                      : _tab == '技能'
                          ? '搜索本地技能'
                          : '搜索插件名 / 描述',
                  controller: _searchCtrl,
                  onChanged: (String _) => setState(() {}),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _busy ? null : _onPlus,
                child: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _busy ? Tga.textDim : Tga.primary,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(Icons.add_rounded,
                      size: 22, color: Tga.onPrimary),
                ),
              ),
            ],
          ),
          if (_loadError.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            // 加载失败如实展示，不静默吞掉。
            TgaCard(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Icon(Icons.error_outline_rounded,
                      size: 16, color: Tga.red),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_loadError, style: Tga.sub)),
                  TextButton(onPressed: _refreshAll, child: const Text('重试')),
                ],
              ),
            ),
          ],
          ...switch (_tab) {
            '技能' => _skillTab(),
            'MCP 服务' => _mcpTab(),
            _ => _pluginTab(),
          },
        ],
      ),
    );
  }
}

/// 顶部分段（下划线式，区别于胶囊）。
class _TabBar extends StatelessWidget {
  const _TabBar(
      {required this.items, required this.value, required this.onChanged});
  final List<String> items;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Tga.card,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: <Widget>[
          for (final String it in items) ...<Widget>[
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(it),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    color: it == value ? Tga.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    it,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: it == value ? Tga.onPrimary : Tga.textSub,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
