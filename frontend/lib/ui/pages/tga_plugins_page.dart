import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 插件社区（2026-11-14 真实在线目录，问题 #23/#24/#25）：
/// - 插件/技能/MCP 三个标签的「发现」区都接真实远端源：后端
///   `plugin_community discover` 用 GitHub Search API（topic:claude-code-plugin /
///   topic:claude-skills / topic:mcp-server，按 star 排序）搜索真实仓库，
///   展示名称/描述/star/更新时间；「刷新」重新拉，「搜索」把关键词带到
///   远端过滤（不是本地过滤）。另合并官方注册表来源（发布通道仓库
///   raw plugins.json，文件不存在时如实跳过）。
/// - 「安装」= 后端真实下载该仓库根目录 plugin.json / SKILL.md / README
///   （raw.githubusercontent.com），落盘到现有插件池目录，安装后出现在
///   「已安装」并可卸载（`plugin_lifecycle uninstall`）。
/// - 插件标签「已安装」= `plugin_lifecycle list`（真实 plugins 池 JSON 文件）。
/// - 技能标签：`plugin_community skills_list` 真实扫描 skills 目录，
///   frontmatter 正确解析 name/description；每条带启用/停用 Switch
///   （停用 = 不进对话技能池，后端 `_chat` 真实过滤）与 ⋮ 菜单
///   （编辑 = SKILL.md 文本编辑器保存落盘；删除 = 真实删文件）。
/// - MCP 服务标签：`mcp_list` 真实读取 mcp_servers.json；每条显示
///   name / transport / command+args 或 url，⋮ 菜单 `mcp_remove` 删除；
///   ＋ 弹重做后的干净表单（stdio/sse 分段胶囊 + 小标签圆角输入框成对）。
/// - ＋ 按钮按当前标签分流：插件 = file_picker 选 .json → `install_local`；
///   技能 = file_picker 选 .md/.json → `skill_add`；MCP = 添加表单。
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
  /// plugin_community skills_list 的真实技能文件。
  List<Map<String, dynamic>> _skills = <Map<String, dynamic>>[];
  String _skillsDir = '';
  /// plugin_community mcp_list 的真实 MCP 配置。
  List<Map<String, dynamic>> _mcp = <Map<String, dynamic>>[];
  /// plugin_community mcp_sync 的真实连接结果（connected/failed/skipped）。
  Map<String, dynamic> _mcpStatus = const <String, dynamic>{};
  bool _mcpSyncing = false;

  /// 当前标签「发现」区的真实远端条目（GitHub Search API + 官方注册表）。
  List<Map<String, dynamic>> _discover = <Map<String, dynamic>>[];
  bool _discoverBusy = false;
  String _discoverError = '';
  /// 正在安装的仓库：点击即置入，给「安装中…」并防重复点击。
  final Set<String> _installingRepos = <String>{};
  /// 已应用到远端的搜索关键词（空 = 浏览 topic 热门）。
  String _appliedQuery = '';

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

  /// 当前标签对应的远端发现源 kind。
  String get _discoverKind => switch (_tab) {
        '技能' => 'skill',
        'MCP 服务' => 'mcp',
        _ => 'plugin',
      };

  /// 一次性拉全本地真实数据（切标签时也复用，保证列表即时刷新），
  /// 并重新拉当前标签的真实远端发现目录。
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
    unawaited(_loadDiscover());
  }

  /// 「发现」区真实远端拉取：kind 按当前标签，query 带到 GitHub Search API
  /// 做远端过滤（问题 #23：不是本地过滤）。
  Future<void> _loadDiscover({String? query}) async {
    final String kw = (query ?? _searchCtrl.text).trim();
    if (!_discoverBusy) setState(() => _discoverBusy = true);
    final BackendClient backend = context.read<BackendClient>();
    List<Map<String, dynamic>> items = <Map<String, dynamic>>[];
    String error = '';
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{
            'action': 'discover',
            'kind': _discoverKind,
            'query': kw,
          });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        items = _mapList(p['items']);
        // GitHub 失败但注册表有结果时如实转述 partial_error。
        error = (p['partial_error'] ?? '').toString();
      } else {
        error = p is Map
            ? (p['error'] ?? '未知原因').toString()
            : '后端返回非预期结构';
      }
    } on Object catch (e) {
      error = '发现目录加载失败：$e';
    }
    if (!mounted) return;
    setState(() {
      _discover = items;
      _discoverError = error;
      _appliedQuery = kw;
      _discoverBusy = false;
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

  /// 发现条目落盘名：后端 install_repo 用 name 做非法字符替换后写
  /// plugins/<safe>.json，与「已安装」列表按同一规则匹配。
  static String _safeName(String name) =>
      name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// 安装发现条目（问题 #23）：后端真实下载该仓库根目录
  /// plugin.json / SKILL.md / README（raw.githubusercontent.com）落盘插件池。
  Future<void> _installRepo(Map<String, dynamic> item) async {
    final String repo = (item['repo'] ?? '').toString();
    final String name = (item['name'] ?? repo).toString();
    if (repo.isEmpty) {
      _toast('该条目没有可下载的 GitHub 仓库，无法安装');
      return;
    }
    if (_installingRepos.contains(repo)) return; // 防止连点重复请求
    // 点击即给可见状态：置入集合 + setState，按钮立刻变「安装中…」并禁用。
    setState(() => _installingRepos.add(repo));
    final BackendClient backend = context.read<BackendClient>();
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{
            'action': 'install_repo',
            'repo': repo,
            'name': name,
            'branch': (item['branch'] ?? '').toString(),
          });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        final String file = (p['file'] ?? '').toString();
        final String path = (p['path'] ?? '').toString();
        _toast('已下载 $repo 的 $file 并安装到插件池'
            '${path.isEmpty ? '' : '（$path）'}');
      } else {
        _toast('安装失败：'
            '${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('安装请求失败：$e');
    } finally {
      if (mounted) setState(() => _installingRepos.remove(repo));
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

  /// 问题 #25①：启用/停用技能（plugin_community skill_set_enabled 持久化，
  /// 后端 _chat 只注入已启用技能进对话技能池——停用即真实不进对话）。
  Future<void> _setSkillEnabled(Map<String, dynamic> row, bool enabled) async {
    final String file = (row['file'] ?? '').toString();
    final String name = (row['name'] ?? file).toString();
    if (file.isEmpty) return;
    final BackendClient backend = context.read<BackendClient>();
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{
            'action': 'skill_set_enabled',
            'name': file,
            'enabled': enabled,
          });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _toast(enabled ? '已启用技能「$name」（进入对话技能池）'
            : '已停用技能「$name」（不再进入对话技能池）');
      } else {
        _toast('设置失败：'
            '${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('设置请求失败：$e');
    }
    await _refreshAll();
  }

  /// 问题 #25②：⋮ 菜单「编辑」——读技能文件真实文本，弹全文编辑器，
  /// 保存经 plugin_community skill_save 真实落盘。
  Future<void> _editSkill(Map<String, dynamic> row) async {
    final String file = (row['file'] ?? '').toString();
    if (file.isEmpty) return;
    final BackendClient backend = context.read<BackendClient>();
    String content;
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{'action': 'skill_read', 'name': file});
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        content = (p['content'] ?? '').toString();
      } else {
        _toast('读取技能文件失败：'
            '${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
        return;
      }
    } on Object catch (e) {
      _toast('读取请求失败：$e');
      return;
    }
    if (!mounted) return;
    final TextEditingController ctrl = TextEditingController(text: content);
    final bool? save = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return Dialog(
          backgroundColor: Tga.card,
          insetPadding: const EdgeInsets.symmetric(horizontal: 24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SizedBox(
            height: 460,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('编辑 $file', style: Tga.h2),
                  const SizedBox(height: 4),
                  Text('保存后真实写回技能文件（SKILL.md 全文可直接编辑）',
                      style: Tga.caption),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Tga.bgSoft,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Tga.border),
                      ),
                      child: TextField(
                        controller: ctrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: TextStyle(
                            fontSize: 13,
                            fontFamily: 'monospace',
                            color: Tga.text,
                            height: 1.5),
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.all(12),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        style: TextButton.styleFrom(
                            foregroundColor: Tga.textSub),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: FilledButton.styleFrom(
                            backgroundColor: Tga.primary,
                            foregroundColor: Tga.onPrimary),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    final String newText = ctrl.text;
    ctrl.dispose();
    if (save != true || !mounted) return;
    try {
      final env = await backend.sendControl('plugin_community',
          <String, dynamic>{
            'action': 'skill_save',
            'name': file,
            'content': newText,
          });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _toast('已保存「$file」（真实落盘）');
      } else {
        _toast('保存失败：'
            '${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('保存请求失败：$e');
    }
    await _refreshAll();
  }

  /// 问题 #25②：⋮ 菜单「删除」——确认后经 plugin_community skill_remove
  /// 真实删除 skills 目录下的技能文件。
  void _confirmDeleteSkill(Map<String, dynamic> row) {
    final String file = (row['file'] ?? '').toString();
    final String name = (row['name'] ?? file).toString();
    final String base =
        file.contains('.') ? file.substring(0, file.lastIndexOf('.')) : file;
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('删除技能「$name」？'),
        content: Text('将真实删除技能目录里的 $file，操作不可恢复。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final BackendClient backend = context.read<BackendClient>();
              try {
                final env = await backend.sendControl('plugin_community',
                    <String, dynamic>{
                      'action': 'skill_remove',
                      'name': base,
                    });
                final dynamic p = env.payload;
                if (p is Map && p['ok'] == true) {
                  _toast('已删除技能「$name」');
                } else {
                  _toast('删除失败：'
                      '${p is Map ? p['error'] ?? '文件不存在' : '后端返回非预期结构'}');
                }
              } on Object catch (e) {
                _toast('删除请求失败：$e');
              }
              await _refreshAll();
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- MCP 动作

  /// ＋（MCP 标签）：问题 #24 重做后的干净表单弹窗
  /// （stdio/sse 分段胶囊、小标签+圆角输入框成对、按钮右对齐、跟随 Tga 色板）。
  Future<void> _showMcpForm() async {
    final Map<String, dynamic>? entry = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext ctx) => const _McpFormDialog(),
    );
    if (entry == null || !mounted) return;
    final BackendClient backend = context.read<BackendClient>();
    try {
      final env = await backend.sendControl(
          'plugin_community', <String, dynamic>{'action': 'mcp_add', ...entry});
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        _toast('已添加 MCP 服务「${entry['name']}」（当前共 ${p['count'] ?? '?'} 个）');
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

  /// star 数格式化（1.2k）。
  static String _fmtStars(int stars) =>
      stars >= 1000 ? '${(stars / 1000).toStringAsFixed(1)}k' : '$stars';

  /// GitHub pushed_at（ISO）取日期部分展示。
  static String _fmtDate(String iso) {
    if (iso.isEmpty) return '—';
    return iso.split('T').first;
  }

  /// 「发现」区（三个标签共用，问题 #23）：真实远端条目展示
  /// 名称/描述/star/更新时间；「搜索」把关键词带到远端过滤，
  /// 「刷新」重新拉；「安装」真实下载仓库文件落盘插件池。
  List<Widget> _discoverSection() {
    final Set<String> installedNames = _installed.map(_pluginName).toSet();
    return <Widget>[
      TgaGroupTitle(
        '发现',
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_appliedQuery.isNotEmpty) ...<Widget>[
              TgaTag('“$_appliedQuery”', color: Tga.primary),
              const SizedBox(width: 10),
            ],
            _discoverBusy
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Tga.primary),
                  )
                : GestureDetector(
                    onTap: () => unawaited(_loadDiscover()),
                    child: Text('搜索',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: Tga.primary)),
                  ),
            const SizedBox(width: 12),
            if (!_discoverBusy)
              GestureDetector(
                onTap: () => unawaited(_loadDiscover(query: _appliedQuery)),
                child: Text('刷新',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Tga.textSub)),
              ),
          ],
        ),
      ),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _discover.isEmpty
            ? (_discoverBusy
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 34),
                    child: Center(
                        child: Text('正在拉取真实远端目录…', style: Tga.sub)),
                  )
                : TgaEmpty(
                    _discoverError.isEmpty
                        ? '远端目录暂无结果'
                        : '远端目录加载失败：$_discoverError',
                    icon: Icons.wifi_tethering_off_rounded))
            : Column(
                children: <Widget>[
                  for (int i = 0; i < _discover.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    _discoverTile(_discover[i],
                        installedNames.contains(_safeName(
                            (_discover[i]['name'] ?? '').toString()))),
                  ],
                ],
              ),
      ),
      if (_discoverError.isNotEmpty && _discover.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text('部分来源失败：$_discoverError', style: Tga.caption),
        ),
    ];
  }

  /// 发现条目行：名称 / 描述（最多两行）/ ★star / 更新时间 / 来源 + 安装。
  Widget _discoverTile(Map<String, dynamic> item, bool installed) {
    final String name = (item['name'] ?? '').toString();
    final String desc = (item['description'] ?? '').toString();
    final int stars = item['stars'] is num ? (item['stars'] as num).toInt() : 0;
    final String updated = _fmtDate((item['updated'] ?? '').toString());
    final String source = (item['source'] ?? '').toString();
    final String repo = (item['repo'] ?? '').toString();
    final bool installing = _installingRepos.contains(repo);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: source == '官方注册表' ? Tga.iconGreenBg : Tga.iconPurpleBg,
              shape: BoxShape.circle,
            ),
            child: Icon(
                source == '官方注册表'
                    ? Icons.verified_outlined
                    : Icons.code_rounded,
                size: 19,
                color: source == '官方注册表' ? Tga.iconGreen : Tga.iconPurple),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(name, style: Tga.body),
                if (desc.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(desc,
                      style: Tga.sub, maxLines: 2, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 5),
                Row(
                  children: <Widget>[
                    Icon(Icons.star_rounded, size: 13, color: Tga.gold),
                    const SizedBox(width: 3),
                    Text(_fmtStars(stars), style: Tga.caption),
                    const SizedBox(width: 10),
                    Text('更新 $updated', style: Tga.caption),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(source,
                          style: Tga.caption, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          installed
              ? TgaTag('已安装', color: Tga.green)
              : installing
                  ? TgaTag('安装中…', color: Tga.textSub)
                  : TgaButton(
                      label: '安装',
                      filled: false,
                      onTap: () => unawaited(_installRepo(item)),
                    ),
        ],
      ),
    );
  }

  /// 插件标签：已安装（lifecycle）+ 发现（真实在线目录）。
  List<Widget> _pluginTab() {
    final List<Map<String, dynamic>> installed = _installed
        .where((Map<String, dynamic> r) => _match(_pluginName(r)))
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
      ..._discoverSection(),
    ];
  }

  /// 技能标签：本地技能（启用/停用 Switch + ⋮ 编辑/删除）+ 发现（真实在线目录）。
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
                    _skillTile(visible[i]),
                  ],
                ],
              ),
      ),
      if (_skillsDir.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
          child: Text('技能扫描目录：$_skillsDir', style: Tga.caption),
        ),
      ..._discoverSection(),
    ];
  }

  /// 技能条目（问题 #25）：启用/停用 Switch（停用 = 不进对话技能池）
  /// + ⋮ 菜单（编辑 = SKILL.md 文本编辑器保存落盘；删除 = 真实删文件）。
  Widget _skillTile(Map<String, dynamic> row) {
    final bool enabled = row['enabled'] != false;
    final String desc = (row['description'] ?? '').toString();
    return TgaIconTile(
      icon: Icons.psychology_alt_outlined,
      iconBg: Tga.iconCyanBg,
      iconColor: Tga.iconCyan,
      title: enabled
          ? (row['name'] ?? '').toString()
          : '${row['name'] ?? ''}（已停用）',
      subtitle: '$desc · '
          '${_fmtBytes(row['size'] is num ? (row['size'] as num).toInt() : 0)}',
      showArrow: false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Switch(
            value: enabled,
            onChanged: (bool v) => unawaited(_setSkillEnabled(row, v)),
          ),
          _menuTrailing(
            const <String>['编辑', '删除'],
            (String v) {
              if (v == '编辑') {
                unawaited(_editSkill(row));
              } else {
                _confirmDeleteSkill(row);
              }
            },
          ),
        ],
      ),
    );
  }

  /// MCP 服务标签：mcp_list 真实配置 + 发现（真实在线目录）。
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
      ..._discoverSection(),
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
                      ? '搜索 MCP 服务名 / 发现区关键词点「搜索」'
                      : _tab == '技能'
                          ? '搜索本地技能 / 发现区关键词点「搜索」'
                          : '搜索插件名 / 描述（发现区点「搜索」走远端）',
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

/// 问题 #24：重做的「添加 MCP 服务」表单弹窗——stdio/sse 分段胶囊、
/// 每个字段小标签 + 圆角输入框成对、校验错误就地展示、按钮右对齐，
/// 深浅主题全部消费 Tga 色板 token（不改动设计系统本身）。
class _McpFormDialog extends StatefulWidget {
  const _McpFormDialog();

  @override
  State<_McpFormDialog> createState() => _McpFormDialogState();
}

class _McpFormDialogState extends State<_McpFormDialog> {
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _cmdCtrl = TextEditingController();
  final TextEditingController _argsCtrl = TextEditingController();
  final TextEditingController _urlCtrl = TextEditingController();
  String _transport = 'stdio';
  String _error = '';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cmdCtrl.dispose();
    _argsCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _nameCtrl.text.trim();
    final String command = _cmdCtrl.text.trim();
    final String url = _urlCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '服务名称不能为空');
      return;
    }
    if (_transport == 'stdio' && command.isEmpty) {
      setState(() => _error = 'stdio 传输必须填写启动命令');
      return;
    }
    if (_transport == 'sse' && !url.startsWith('http')) {
      setState(() => _error = 'SSE 传输必须填写 http/https URL');
      return;
    }
    final List<String> args = _argsCtrl.text
        .trim()
        .split(RegExp(r'\s+'))
        .where((String s) => s.isNotEmpty)
        .toList();
    Navigator.pop(context, <String, dynamic>{
      'name': name,
      'transport': _transport,
      'command': command,
      'args': args,
      'url': url,
    });
  }

  TextStyle get _labelStyle => TextStyle(
      fontSize: 12, fontWeight: FontWeight.w600, color: Tga.textSub);

  /// 小标签 + 圆角输入框成对。
  Widget _fieldPair(String label, TextEditingController ctrl, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: _labelStyle),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          style: TextStyle(fontSize: 13.5, color: Tga.text),
          onChanged: (String _) {
            if (_error.isNotEmpty) setState(() => _error = '');
          },
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(fontSize: 13, color: Tga.textDim),
            filled: true,
            fillColor: Tga.bgSoft,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Tga.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Tga.primary, width: 1.4),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Tga.border),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Dialog(
      backgroundColor: Tga.card,
      insetPadding: const EdgeInsets.symmetric(horizontal: 26),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('添加 MCP 服务', style: Tga.h2),
            const SizedBox(height: 14),
            TgaSegmented<String>(
              items: const <String>['stdio', 'sse'],
              value: _transport,
              labelOf: (String s) => s,
              onChanged: (String v) => setState(() {
                _transport = v;
                _error = '';
              }),
            ),
            const SizedBox(height: 16),
            _fieldPair('服务名称', _nameCtrl, '如 filesystem'),
            const SizedBox(height: 12),
            if (_transport == 'stdio')
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: _fieldPair('启动命令', _cmdCtrl, '如 npx'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _fieldPair('参数（空格分隔，可空）', _argsCtrl, '…'),
                  ),
                ],
              )
            else
              _fieldPair('SSE URL', _urlCtrl, 'https://…/sse'),
            if (_error.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Icon(Icons.error_outline_rounded, size: 14, color: Tga.red),
                  const SizedBox(width: 6),
                  Expanded(
                      child:
                          Text(_error, style: TextStyle(fontSize: 12, color: Tga.red))),
                ],
              ),
            ],
            const SizedBox(height: 18),
            // 按钮右对齐。
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(foregroundColor: Tga.textSub),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _submit,
                  style: FilledButton.styleFrom(
                      backgroundColor: Tga.primary,
                      foregroundColor: Tga.onPrimary),
                  child: const Text('添加'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
