import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../ui/i18n/tga_strings.dart';

/// 插件内核（万物皆插件）管理页。
///
/// 全部数据来自后端 `plugin_kernel` 控制域的真实返回：概览 status / 运行模式
/// modes+set_mode / 插件树 tree+mount+unmount / 能力接缝 seams+set_provider+invoke /
/// 四层配置 dump_config+set_patch / append-only 事件流 events+search+fork。
/// 不伪造任何条目：加载失败或动作失败都把后端 error 原样展示在「最近操作」卡片。
class TgaKernelPage extends StatefulWidget {
  const TgaKernelPage({super.key});

  @override
  State<TgaKernelPage> createState() => _TgaKernelPageState();
}

class _TgaKernelPageState extends State<TgaKernelPage> {
  static const List<String> _tabs = <String>[
    '概览',
    '插件树',
    '能力接缝',
    '配置与事件',
    '自定义能力',
  ];

  String _tab = '概览';
  bool _busy = false;
  String _loadError = '';
  String _lastResult = '';

  Map<String, dynamic> _status = <String, dynamic>{};
  List<Map<String, dynamic>> _nodes = <Map<String, dynamic>>[];
  List<String> _catalog = <String>[];
  List<Map<String, dynamic>> _seams = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _modes = <Map<String, dynamic>>[];
  String _activeMode = '';
  Map<String, dynamic> _config = <String, dynamic>{};
  List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];
  // 自定义能力：全部来自内核真实返回，不伪造任何条目。
  List<Map<String, dynamic>> _pages = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _textOverrides = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _permissionPolicies = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _widgetSlots = <Map<String, dynamic>>[];

  String _selectedSeam = '';
  final TextEditingController _invokeMethod = TextEditingController(text: 'status');
  final TextEditingController _invokeArgs = TextEditingController(text: '{}');
  final TextEditingController _patchKey = TextEditingController();
  final TextEditingController _patchValue = TextEditingController();
  final TextEditingController _bundleId = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _forkSeq = TextEditingController(text: '1');
  String _patchLayer = 'runtime';
  // 自定义能力编辑输入。
  final TextEditingController _pageId = TextEditingController();
  final TextEditingController _pageMeta = TextEditingController(text: '{}');
  final TextEditingController _textLocale = TextEditingController(text: 'zh');
  final TextEditingController _textKey = TextEditingController();
  final TextEditingController _textValue = TextEditingController();
  final TextEditingController _permId = TextEditingController();
  final TextEditingController _permPolicy = TextEditingController(text: '{}');

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _invokeMethod.dispose();
    _invokeArgs.dispose();
    _patchKey.dispose();
    _patchValue.dispose();
    _bundleId.dispose();
    _searchCtrl.dispose();
    _forkSeq.dispose();
    _pageId.dispose();
    _pageMeta.dispose();
    _textLocale.dispose();
    _textKey.dispose();
    _textValue.dispose();
    _permId.dispose();
    _permPolicy.dispose();
    super.dispose();
  }

  Map<String, dynamic> _asMap(dynamic m) => m is Map
      ? m.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v))
      : <String, dynamic>{};

  List<Map<String, dynamic>> _mapList(dynamic raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map<Map<String, dynamic>>((dynamic e) => _asMap(e))
        .toList();
  }

  List<String> _stringList(dynamic raw) => raw is List
      ? raw.map((dynamic e) => e.toString()).toList()
      : <String>[];

  Future<Map<String, dynamic>> _call(
    BackendClient backend,
    String action, [
    Map<String, dynamic> extra = const <String, dynamic>{},
  ]) async {
    final env = await backend.sendControl(
        'plugin_kernel', <String, dynamic>{'action': action, ...extra});
    return _asMap(env.payload);
  }

  String _brief(Map<String, dynamic> p) {
    final String s = p.toString();
    return s.length > 260 ? '${s.substring(0, 260)}…' : s;
  }

  /// 解析用户填写的 JSON 对象；空串按空对象处理。失败时明确报错并返回 null，
  /// 绝不把非法输入伪装成空参数偷偷调用。
  Map<String, dynamic>? _parseJsonObject(String raw, String label) {
    final String s = raw.trim();
    if (s.isEmpty) return <String, dynamic>{};
    try {
      final dynamic decoded = jsonDecode(s);
      if (decoded is! Map) {
        _toast('$label 必须是 JSON 对象（形如 {"key":"value"}），实际为 ${decoded.runtimeType}');
        return null;
      }
      return _asMap(decoded);
    } on Object catch (e) {
      _toast('$label 不是合法 JSON：$e');
      return null;
    }
  }

  /// 经当前激活 provider 真实调用；args 来自 JSON 文本框。
  Future<void> _invoke() async {
    final Map<String, dynamic>? args = _parseJsonObject(_invokeArgs.text, 'args');
    if (args == null) return;
    await _act('invoke $_selectedSeam', 'invoke', <String, dynamic>{
      'seam': _selectedSeam,
      'method': _invokeMethod.text.trim(),
      'args': args,
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// 一次性拉全真实数据；任何一项失败都如实记录到 _loadError。
  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _busy = true);
    final BackendClient backend = context.read<BackendClient>();
    final List<String> errors = <String>[];

    Future<void> load(String label, String action,
        void Function(Map<String, dynamic> ok) apply) async {
      try {
        final Map<String, dynamic> p = await _call(backend, action);
        if (p['ok'] == true) {
          apply(p);
        } else {
          errors.add('$label：${p['error'] ?? '后端返回 ok=false'}');
        }
      } on Object catch (e) {
        errors.add('$label：$e');
      }
    }

    await load('概览', 'status', (Map<String, dynamic> p) => _status = p);
    await load('插件树', 'tree', (Map<String, dynamic> p) {
      _nodes = _mapList(p['nodes']);
      _catalog = _stringList(p['catalog']);
    });
    await load('能力接缝', 'seams', (Map<String, dynamic> p) {
      _seams = _mapList(p['seams']);
      if (_selectedSeam.isEmpty && _seams.isNotEmpty) {
        _selectedSeam = (_seams.first['name'] ?? '').toString();
      }
    });
    await load('运行模式', 'modes', (Map<String, dynamic> p) {
      _modes = _mapList(p['modes']);
      _activeMode = (p['active'] ?? '').toString();
    });
    await load('配置叠加', 'dump_config',
        (Map<String, dynamic> p) => _config = p);
    await load('事件流', 'events',
        (Map<String, dynamic> p) => _events = _mapList(p['events']));
    await load('自定义页面', 'pages',
        (Map<String, dynamic> p) => _pages = _mapList(p['pages']));
    await load('文案覆盖', 'text_overrides',
        (Map<String, dynamic> p) => _textOverrides = _mapList(p['overrides']));
    await load('权限策略', 'permission_policies',
        (Map<String, dynamic> p) =>
            _permissionPolicies = _mapList(p['policies']));
    await load('组件槽', 'widget_slots',
        (Map<String, dynamic> p) => _widgetSlots = _mapList(p['slots']));

    if (!mounted) return;
    setState(() {
      _busy = false;
      _loadError = errors.join('；');
    });
  }

  /// 执行一个写动作，把真实返回（含 ok=false 的 error）写进「最近操作」。
  Future<void> _act(
      String label, String action, Map<String, dynamic> extra) async {
    if (_busy) return;
    setState(() => _busy = true);
    final BackendClient backend = context.read<BackendClient>();
    try {
      final Map<String, dynamic> p = await _call(backend, action, extra);
      if (!mounted) return;
      setState(() => _lastResult = '[$label] ${_brief(p)}');
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _lastResult = '[$label] 请求失败：$e');
    }
    await _refresh();
  }

  Future<void> _searchEvents() async {
    final String q = _searchCtrl.text.trim();
    setState(() => _busy = true);
    final BackendClient backend = context.read<BackendClient>();
    try {
      final Map<String, dynamic> p = await _call(
          backend, 'search', <String, dynamic>{'query': q});
      if (!mounted) return;
      setState(() {
        _events = _mapList(p['events']);
        _lastResult = '[检索 "$q"] ${_brief(p)}';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _lastResult = '[检索] 请求失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------- 概览

  Widget _metric(String label, String value) => Container(
        width: 108,
        margin: const EdgeInsets.all(4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: Tga.bgSoft,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Tga.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(value,
                style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    color: Tga.primary)),
            const SizedBox(height: 3),
            Text(label, style: Tga.caption, maxLines: 1),
          ],
        ),
      );

  List<Widget> _overviewTab() {
    final List<List<String>> metrics = <List<String>>[
      <String>['装配状态', _status['booted'] == true ? '已就绪' : '未就绪'],
      <String>['运行模式', (_status['mode'] ?? '—').toString()],
      <String>['已挂载插件', '${_status['mounted'] ?? 0}'],
      <String>['能力接缝', '${_status['seams'] ?? 0}'],
      <String>['共享服务', '${_status['services'] ?? 0}'],
      <String>['控制动作', '${_status['control_actions'] ?? 0}'],
      <String>['提示词片段', '${_status['prompt_sections'] ?? 0}'],
      <String>['事件序号', '${_status['event_seq'] ?? 0}'],
    ];
    final List<String> modeIds =
        _modes.map((Map<String, dynamic> m) => (m['id'] ?? '').toString()).toList();
    return <Widget>[
      TgaGroupTitle('内核装配状态',
          trailing: TgaTag('profile ${_status['profile'] ?? '—'}',
              color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          children: <Widget>[
            for (final List<String> m in metrics) _metric(m[0], m[1]),
          ],
        ),
      ),
      TgaGroupTitle('运行模式（切换即真实裁剪 / 重装插件树）',
          trailing: TgaTag(_activeMode, color: Tga.primary)),
      TgaCard(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (modeIds.isEmpty)
              Text('运行模式列表加载失败（见顶部错误）', style: Tga.sub)
            else
              TgaSegmented<String>(
                items: modeIds,
                value: modeIds.contains(_activeMode) ? _activeMode : modeIds.first,
                labelOf: (String s) => s,
                onChanged: (String v) => unawaited(_act(
                    '切换运行模式 $v', 'set_mode', <String, dynamic>{'mode': v})),
              ),
            const SizedBox(height: 8),
            for (final Map<String, dynamic> m in _modes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${m['id'] ?? ''} · ${m['description'] ?? ''}',
                    style: Tga.caption),
              ),
          ],
        ),
      ),
      TgaGroupTitle('架构说明'),
      TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('万物皆插件 · Cordis 式插件树', style: Tga.body),
            const SizedBox(height: 6),
            Text(
              'Model / Tools / Skills / Sessions / Sandboxes / Storage / Loops / '
              'Scheduling / UI 均为可挂载、可卸载、可依赖校验的插件节点；'
              '插件经共享 ctx 提供服务、注入依赖、注册工具与控制动作、监听类型化事件。',
              style: Tga.sub,
            ),
            const SizedBox(height: 6),
            Text(
              '能力接缝 = Definition + Provider + Consumer，换 provider 后所有 consumer 一起迁移；'
              '配置四层叠加（profile bundle → profile → home → runtime）逐项标来源；'
              '会话为 append-only 事件流，支持 replay / search / fork。',
              style: Tga.sub,
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TgaButton(
                label: '查看组合后的系统提示词',
                filled: false,
                onTap: () => unawaited(
                    _act('组合提示词', 'compose_prompt', const <String, dynamic>{})),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------- 插件树

  List<Widget> _treeTab() {
    final Set<String> mountedIds = _nodes
        .map((Map<String, dynamic> n) => (n['id'] ?? '').toString())
        .toSet();
    final List<String> notMounted =
        _catalog.where((String id) => !mountedIds.contains(id)).toList();
    return <Widget>[
      TgaGroupTitle('已挂载插件树',
          trailing: TgaTag('${_nodes.length} 个节点', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _nodes.isEmpty
            ? const TgaEmpty('插件树为空或加载失败', icon: Icons.account_tree_outlined)
            : Column(
                children: _treeTiles(),
              ),
      ),
      if (notMounted.isNotEmpty) ...<Widget>[
        TgaGroupTitle('目录里未挂载的插件',
            trailing: TgaTag('${notMounted.length} 个', color: Tga.textSub)),
        TgaCard(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            children: <Widget>[
              for (int i = 0; i < notMounted.length; i++) ...<Widget>[
                if (i > 0) const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.extension_off_outlined,
                  iconBg: Tga.iconGoldBg,
                  iconColor: Tga.iconGold,
                  title: notMounted[i],
                  subtitle: '已注册到内核目录，尚未挂载',
                  showArrow: false,
                  trailing: TgaButton(
                    label: '挂载',
                    filled: false,
                    onTap: () => unawaited(_act('挂载 ${notMounted[i]}', 'mount',
                        <String, dynamic>{'plugin': notMounted[i]})),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ];
  }

  /// 按 parent/children 真实关系渲染缩进层级树。环或缺失 parent 的节点兜底展示，
  /// 绝不因为数据异常而让节点凭空消失。
  List<Widget> _treeTiles() {
    final Map<String, Map<String, dynamic>> byId =
        <String, Map<String, dynamic>>{
      for (final Map<String, dynamic> n in _nodes)
        (n['id'] ?? '').toString(): n,
    };
    final Set<String> ids = byId.keys.toSet();
    final List<Widget> out = <Widget>[];
    final Set<String> walked = <String>{};

    void walk(String id, int depth, Set<String> visiting) {
      final Map<String, dynamic>? node = byId[id];
      if (node == null || visiting.contains(id) || walked.contains(id)) return;
      walked.add(id);
      out.add(Padding(
        padding: EdgeInsets.only(left: depth * 16.0),
        child: _nodeTile(node, depth: depth),
      ));
      final List<String> children = node['children'] is List
          ? (node['children'] as List)
              .map((dynamic c) => c.toString())
              .where((String c) => ids.contains(c))
              .toList()
          : <String>[];
      final Set<String> nextVisiting = Set<String>.from(visiting)..add(id);
      for (final String c in children) {
        walk(c, depth + 1, nextVisiting);
      }
    }

    for (final Map<String, dynamic> n in _nodes) {
      final String id = (n['id'] ?? '').toString();
      final String parent = (n['parent'] ?? '').toString();
      if (parent.isEmpty || !ids.contains(parent)) {
        walk(id, 0, <String>{});
      }
    }
    // 兜底：不成根、又未被父节点递归到的节点（例如 parent 指向环）也要真实显示。
    for (final Map<String, dynamic> n in _nodes) {
      final String id = (n['id'] ?? '').toString();
      if (!walked.contains(id)) walk(id, 0, <String>{});
    }
    return out;
  }

  Widget _nodeTile(Map<String, dynamic> n, {int depth = 0}) {
    final String state = (n['state'] ?? '').toString();
    final String err = (n['error'] ?? '').toString();
    final bool failed = state == 'failed';
    final List<String> children = n['children'] is List
        ? (n['children'] as List).map((dynamic c) => c.toString()).toList()
        : <String>[];
    return TgaIconTile(
      icon: failed ? Icons.error_outline_rounded : Icons.extension_outlined,
      iconBg: failed ? Tga.iconRedBg : Tga.iconPurpleBg,
      iconColor: failed ? Tga.iconRed : Tga.iconPurple,
      title: '${n['name'] ?? n['id'] ?? ''} · v${n['version'] ?? '—'}',
      subtitle: '${depth > 0 ? 'L$depth ' : ''}${n['id'] ?? ''} · ${state} · '
          '来源 ${n['source'] ?? '—'} · 层 ${n['config_layer'] ?? '—'} · '
          '效果 ${n['effects'] ?? 0} · children ${children.join(',')}'
          '${err.isEmpty ? '' : ' · $err'}',
      showArrow: false,
      trailing: TgaButton(
        label: '卸载',
        filled: false,
        color: Tga.red,
        onTap: () => unawaited(_act('卸载 ${n['id']}', 'unmount',
            <String, dynamic>{'plugin': (n['id'] ?? '').toString()})),
      ),
    );
  }

  // ---------------------------------------------------------------- 能力接缝

  List<Widget> _seamsTab() {
    return <Widget>[
      TgaGroupTitle('能力接缝（Seam）',
          trailing: TgaTag('${_seams.length} 条', color: Tga.textSub)),
      if (_seams.isEmpty)
        const TgaCard(
          child: TgaEmpty('能力接缝为空或加载失败', icon: Icons.tune_outlined),
        )
      else
        for (final Map<String, dynamic> s in _seams) _seamCard(s),
      TgaGroupTitle('真实调用接缝（invoke）'),
      TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('经当前激活 provider 真实执行；provider 不支持该 method 时如实报错。',
                style: Tga.caption),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  flex: 2,
                  child: _seamDropdown(),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _invokeMethod,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'method',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _invokeArgs,
              style: TextStyle(
                  fontSize: 12, fontFamily: 'monospace', color: Tga.text),
              maxLines: 3,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'args（JSON 对象；留空按空对象处理）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TgaButton(
              label: '调用',
              onTap: () => unawaited(_invoke()),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _seamDropdown() {
    final List<String> names = _seams
        .map((Map<String, dynamic> s) => (s['name'] ?? '').toString())
        .where((String n) => n.isNotEmpty)
        .toList();
    if (!names.contains(_selectedSeam)) {
      _selectedSeam = names.isEmpty ? '' : names.first;
    }
    return DropdownButton<String>(
      value: _selectedSeam.isEmpty ? null : _selectedSeam,
      isExpanded: true,
      style: TextStyle(fontSize: 13, color: Tga.text),
      items: <DropdownMenuItem<String>>[
        for (final String n in names)
          DropdownMenuItem<String>(value: n, child: Text(n, overflow: TextOverflow.ellipsis)),
      ],
      onChanged: (String? v) => setState(() => _selectedSeam = v ?? ''),
    );
  }

  Widget _seamCard(Map<String, dynamic> s) {
    final String name = (s['name'] ?? '').toString();
    final String active = (s['active_provider'] ?? '').toString();
    final List<Map<String, dynamic>> providers = _mapList(s['providers']);
    final List<String> consumers = _stringList(s['consumers']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.tune_rounded, size: 17, color: Tga.primary),
                const SizedBox(width: 8),
                Expanded(child: Text(name, style: Tga.body)),
                TgaTag('当前：$active', color: Tga.green),
              ],
            ),
            const SizedBox(height: 5),
            Text((s['definition'] ?? '').toString(), style: Tga.caption),
            const SizedBox(height: 8),
            Text('Providers（${providers.length}）· Consumers（${consumers.length}）',
                style: Tga.caption),
            const SizedBox(height: 6),
            for (final Map<String, dynamic> p in providers)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('${p['id'] ?? ''} · ${p['description'] ?? ''} '
                          '（owner ${p['owner'] ?? '—'}）',
                          style: Tga.sub, overflow: TextOverflow.ellipsis),
                    ),
                    if ((p['id'] ?? '').toString() != active)
                      TgaButton(
                        label: '切换',
                        filled: false,
                        onTap: () => unawaited(_act(
                            '切换 $name → ${p['id']}', 'set_provider',
                            <String, dynamic>{
                              'seam': name,
                              'provider': (p['id'] ?? '').toString(),
                            })),
                      )
                    else
                      TgaTag('激活中', color: Tga.textSub),
                  ],
                ),
              ),
            if (consumers.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text('Consumers：${consumers.join('、')}',
                  style: Tga.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 配置与事件

  List<Widget> _configTab() {
    final List<String> layers = _stringList(_config['layers']);
    final List<Map<String, dynamic>> entries = _mapList(_config['entries']);
    return <Widget>[
      TgaGroupTitle('四层配置叠加（dump_config）',
          trailing: TgaTag('mode ${_config['mode'] ?? '—'}', color: Tga.primary)),
      TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              children: <Widget>[
                for (final String l in layers)
                  Padding(
                    padding: const EdgeInsets.only(right: 6, bottom: 6),
                    child: TgaTag(l, color: Tga.textSub),
                  ),
              ],
            ),
            if (layers.isEmpty) Text('配置层信息加载失败（见顶部错误）', style: Tga.sub),
            const SizedBox(height: 6),
            const Divider(height: 1),
            const SizedBox(height: 6),
            if (entries.isEmpty)
              Text('当前无叠加配置条目', style: Tga.sub)
            else
              for (final Map<String, dynamic> e in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text('${e['key'] ?? ''} = ${e['value'] ?? ''}',
                            style: Tga.sub, overflow: TextOverflow.ellipsis),
                      ),
                      TgaTag('来源 ${e['layer'] ?? '—'}', color: Tga.primary),
                    ],
                  ),
                ),
          ],
        ),
      ),
      TgaGroupTitle('写入配置 patch（bundle / profile / home / runtime）'),
      TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('后层覆盖前层；bundle 层需填写真实 bundle id（如 core / ext）。',
                style: Tga.caption),
            const SizedBox(height: 10),
            TgaSegmented<String>(
              items: const <String>['bundle', 'profile', 'home', 'runtime'],
              value: _patchLayer,
              labelOf: (String s) => s,
              onChanged: (String v) => setState(() => _patchLayer = v),
            ),
            if (_patchLayer == 'bundle') ...<Widget>[
              const SizedBox(height: 10),
              TextField(
                controller: _bundleId,
                style: TextStyle(fontSize: 13, color: Tga.text),
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'bundle id',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _patchKey,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _patchValue,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'value',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TgaButton(
                label: '写入 $_patchLayer 层',
                onTap: () {
                  final String k = _patchKey.text.trim();
                  if (k.isEmpty) {
                    _toast('key 不能为空');
                    return;
                  }
                  final Map<String, dynamic> extra = <String, dynamic>{
                    'layer': _patchLayer,
                    'key': k,
                    'value': _patchValue.text,
                  };
                  if (_patchLayer == 'bundle') {
                    final String bid = _bundleId.text.trim();
                    if (bid.isEmpty) {
                      _toast('bundle 层需填写 bundle id');
                      return;
                    }
                    extra['bundle'] = bid;
                  }
                  unawaited(_act('写入配置 $k', 'set_patch', extra));
                },
              ),
            ),
          ],
        ),
      ),
      TgaGroupTitle('append-only 会话事件流',
          trailing: TgaTag('${_events.length} 条', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                style: TextStyle(fontSize: 13, color: Tga.text),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '检索事件内容（search，空则回放全部）',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TgaButton(label: '检索', filled: false, onTap: () => unawaited(_searchEvents())),
          ],
        ),
      ),
      const SizedBox(height: 10),
      TgaCard(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _events.isEmpty
            ? const TgaEmpty('暂无事件', icon: Icons.timeline_outlined)
            : Column(
                children: <Widget>[
                  for (int i = 0; i < _events.length; i++) ...<Widget>[
                    if (i > 0) const TgaTileDivider(),
                    _eventTile(_events[i]),
                  ],
                ],
              ),
      ),
      const SizedBox(height: 10),
      TgaGroupTitle('事件流分叉（fork，可选起点）'),
      TgaCard(
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 150,
              child: TextField(
                controller: _forkSeq,
                style: TextStyle(fontSize: 13, color: Tga.text),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'from_seq',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            TgaButton(
              label: '分叉',
              filled: false,
              onTap: () {
                final int? seq = int.tryParse(_forkSeq.text.trim());
                if (seq == null || seq < 0) {
                  _toast('from_seq 必须是非负整数');
                  return;
                }
                unawaited(_act('分叉事件流', 'fork',
                    <String, dynamic>{'from_seq': seq}));
              },
            ),
          ],
        ),
      ),
    ];
  }

  // ---------------------------------------------------------------- 自定义能力

  Future<void> _addPageFromInput() async {
    final String id = _pageId.text.trim();
    if (id.isEmpty) {
      _toast('页面 id 不能为空');
      return;
    }
    final Map<String, dynamic>? meta = _parseJsonObject(_pageMeta.text, 'meta');
    if (meta == null) return;
    await _act('添加页面 $id', 'pages', <String, dynamic>{
      'op': 'add',
      'id': id,
      'meta': meta,
    });
  }

  Future<void> _reorderPage(String id, int delta) async {
    final List<String> ids = _pages
        .map((Map<String, dynamic> p) => (p['id'] ?? '').toString())
        .toList();
    final int i = ids.indexOf(id);
    final int j = i + delta;
    if (i < 0 || j < 0 || j >= ids.length) {
      _toast('该页面已在边界，无法继续移动');
      return;
    }
    final List<String> next = List<String>.of(ids);
    final String tmp = next[i];
    next[i] = next[j];
    next[j] = tmp;
    await _act('重排页面 $id', 'pages', <String, dynamic>{
      'op': 'reorder',
      'ids': next,
    });
  }

  Future<void> _setTextOverrideFromInput() async {
    final String locale = _textLocale.text.trim();
    final String key = _textKey.text.trim();
    if (locale.isEmpty || key.isEmpty) {
      _toast('locale 与 key 不能为空');
      return;
    }
    await _act('设置文案 $locale/$key', 'text_overrides', <String, dynamic>{
      'op': 'set',
      'locale': locale,
      'key': key,
      'value': _textValue.text,
    });
  }

  Future<void> _getTextOverrideFromInput() async {
    final String locale = _textLocale.text.trim();
    final String key = _textKey.text.trim();
    if (locale.isEmpty || key.isEmpty) {
      _toast('locale 与 key 不能为空');
      return;
    }
    await _act('查询文案 $locale/$key', 'text_overrides', <String, dynamic>{
      'op': 'get',
      'locale': locale,
      'key': key,
    });
  }

  Future<void> _setPermissionPolicyFromInput() async {
    final String id = _permId.text.trim();
    if (id.isEmpty) {
      _toast('权限策略 id 不能为空');
      return;
    }
    final Map<String, dynamic>? policy =
        _parseJsonObject(_permPolicy.text, 'policy');
    if (policy == null) return;
    await _act('设置权限策略 $id', 'permission_policies', <String, dynamic>{
      'op': 'set',
      'id': id,
      'policy': policy,
    });
  }

  List<Widget> _customTab() {
    return <Widget>[
      TgaGroupTitle('自定义页面注册表（pages）',
          trailing: TgaTag('${_pages.length} 条', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('经 ui/pages 接缝真实读写内核注册表；真实导航基线不受影响。',
                style: Tga.caption),
            const SizedBox(height: 8),
            if (_pages.isEmpty) Text('当前无自定义页面', style: Tga.sub),
            for (final Map<String, dynamic> pg in _pages) ...<Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${pg['id'] ?? ''} · ${pg['meta'] ?? ''} · owner '
                        '${pg['owner'] ?? ''}',
                        style: Tga.sub,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TgaButton(
                      label: '↑',
                      filled: false,
                      onTap: () =>
                          unawaited(_reorderPage((pg['id'] ?? '').toString(), -1)),
                    ),
                    const SizedBox(width: 4),
                    TgaButton(
                      label: '↓',
                      filled: false,
                      onTap: () =>
                          unawaited(_reorderPage((pg['id'] ?? '').toString(), 1)),
                    ),
                    const SizedBox(width: 4),
                    TgaButton(
                      label: '移除',
                      filled: false,
                      color: Tga.red,
                      onTap: () => unawaited(_act(
                          '移除页面 ${pg['id']}', 'pages', <String, dynamic>{
                        'op': 'remove',
                        'id': (pg['id'] ?? '').toString(),
                      })),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _pageId,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'page id',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _pageMeta,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'meta（JSON 对象）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TgaButton(
                label: '添加页面',
                onTap: () => unawaited(_addPageFromInput()),
              ),
            ),
          ],
        ),
      ),
      TgaGroupTitle('文案覆盖（text_overrides）',
          trailing: TgaTag('${_textOverrides.length} 条', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('内核级覆盖存储；查询 get 返回真实覆盖值与 found。',
                style: Tga.caption),
            const SizedBox(height: 8),
            if (_textOverrides.isEmpty) Text('当前无文案覆盖', style: Tga.sub),
            for (final Map<String, dynamic> o in _textOverrides)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${o['locale'] ?? ''} / ${o['key'] ?? ''} = ${o['value'] ?? ''}',
                  style: Tga.sub,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _textLocale,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'locale',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _textKey,
                    style: TextStyle(fontSize: 13, color: Tga.text),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _textValue,
              style: TextStyle(fontSize: 13, color: Tga.text),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'value',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                TgaButton(
                  label: '设置 set',
                  onTap: () => unawaited(_setTextOverrideFromInput()),
                ),
                const SizedBox(width: 10),
                TgaButton(
                  label: '查询 get',
                  filled: false,
                  onTap: () => unawaited(_getTextOverrideFromInput()),
                ),
              ],
            ),
          ],
        ),
      ),
      TgaGroupTitle('权限策略（permission_policies）',
          trailing: TgaTag('${_permissionPolicies.length} 条',
              color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('策略为纯数据规则，由调用方真实判定，内核不在此假装放行。',
                style: Tga.caption),
            const SizedBox(height: 8),
            if (_permissionPolicies.isEmpty)
              Text('当前无权限策略', style: Tga.sub),
            for (final Map<String, dynamic> pol in _permissionPolicies)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${pol['id'] ?? ''} · ${pol['policy'] ?? ''}',
                  style: Tga.sub,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _permId,
              style: TextStyle(fontSize: 13, color: Tga.text),
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'policy id',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _permPolicy,
              style: TextStyle(
                  fontSize: 12, fontFamily: 'monospace', color: Tga.text),
              maxLines: 2,
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'policy（JSON 对象）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TgaButton(
                label: '设置策略',
                onTap: () => unawaited(_setPermissionPolicyFromInput()),
              ),
            ),
          ],
        ),
      ),
      TgaGroupTitle('UI 组件槽（widget_slots，只读）',
          trailing: TgaTag('${_widgetSlots.length} 条', color: Tga.textSub)),
      TgaCard(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (_widgetSlots.isEmpty) Text('当前无组件槽', style: Tga.sub),
            for (final Map<String, dynamic> s in _widgetSlots)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${s['id'] ?? ''} · ${s['meta'] ?? ''}',
                  style: Tga.sub,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _eventTile(Map<String, dynamic> e) {
    final String data = (e['data'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TgaTag('#${e['seq'] ?? '—'}', color: Tga.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('${e['topic'] ?? ''} · ${e['source'] ?? ''}',
                    style: Tga.body),
                const SizedBox(height: 2),
                Text(
                  '${e['ts'] ?? ''} · '
                  '${data.length > 120 ? '${data.substring(0, 120)}…' : data}',
                  style: Tga.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _lastResultCard() {
    if (_lastResult.isEmpty) return <Widget>[];
    return <Widget>[
      TgaGroupTitle('最近操作（真实后端返回）'),
      TgaCard(
        child: SelectableText(_lastResult,
            style: TextStyle(
                fontSize: 12, fontFamily: 'monospace', color: Tga.text)),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return TgaPage(
      title: context.t('kernel.title'),
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.groupTitle),
          onPressed: _busy ? null : () => unawaited(_refresh()),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 40),
        children: <Widget>[
          TgaSegmented<String>(
            items: _tabs,
            value: _tab,
            labelOf: (String s) => s,
            onChanged: (String v) => setState(() => _tab = v),
          ),
          const SizedBox(height: 12),
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_loadError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TgaCard(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.error_outline_rounded, size: 16, color: Tga.red),
                    const SizedBox(width: 8),
                    Expanded(child: Text('加载异常：$_loadError', style: Tga.sub)),
                  ],
                ),
              ),
            ),
          ...switch (_tab) {
            '插件树' => _treeTab(),
            '能力接缝' => _seamsTab(),
            '配置与事件' => _configTab(),
            '自定义能力' => _customTab(),
            _ => _overviewTab(),
          },
          ..._lastResultCard(),
        ],
      ),
    );
  }
}
