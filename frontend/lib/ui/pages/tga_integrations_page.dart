import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// Integrations：真实接入 MCP / OpenAPI / GraphQL。
///
/// 页面只展示后端返回的真实状态：连接测试结果、工具列表、调用输出与追加日志。
/// 凭据输入后进入系统安全存储，列表与工具结果都不会回显凭据。
class TgaIntegrationsPage extends StatefulWidget {
  const TgaIntegrationsPage({super.key});

  @override
  State<TgaIntegrationsPage> createState() => _TgaIntegrationsPageState();
}

class _TgaIntegrationsPageState extends State<TgaIntegrationsPage> {
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('integration', <String, dynamic>{
      'action': action,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await _call('list');
      if (!mounted) return;
      setState(() {
        _items = (r['integrations'] is List ? r['integrations'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('读取失败：$e');
    }
  }

  Future<void> _add() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) => const _IntegrationEditor(),
    );
    if (ok != true || !mounted) return;
    await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 3),
      ));
  }

  Widget _badge(String text, {required bool ok}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
        decoration: BoxDecoration(
          color: ok ? Tga.iconGreenBg : Tga.bgSoft,
          borderRadius: BorderRadius.circular(Tga.rChip),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: ok ? Tga.green : Tga.textSub,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '集成',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _add,
          tooltip: '接入服务',
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Tga.primary,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Text(
                    '接入 HTTP MCP / OpenAPI / GraphQL 服务，Agent 就能真实调用它们。\n'
                    '凭据只写入系统安全存储，不落配置文件，也不会进入模型上下文；'
                    '移动端不支持启动 stdio MCP 进程。',
                    style: Tga.sub,
                  ),
                ),
                TgaGroupTitle('已接入（${_items.length}）'),
                if (_items.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有接入服务\n点右上角 + 添加 MCP / OpenAPI / GraphQL',
                      icon: Icons.extension_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> item in _items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (BuildContext _) =>
                                  _IntegrationDetailPage(item: item),
                            ),
                          );
                          await _load();
                        },
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: _kindBg('${item['kind']}'),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(
                                _kindIcon('${item['kind']}'),
                                size: 19,
                                color: _kindColor('${item['kind']}'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      Flexible(
                                        child: Text(
                                          '${item['name']}',
                                          style: Tga.h2,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      _badge(
                                        item['enabled'] == true ? '已启用' : '已停用',
                                        ok: item['enabled'] == true,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_kindLabel('${item['kind']}')} · '
                                    '${(item['tools'] as List?)?.length ?? 0} 个工具'
                                    '${item['has_secret'] == true ? ' · 已保存凭据' : ''}'
                                    '${item['last_test_ok'] == true ? ' · 连接正常' : ''}',
                                    style: Tga.caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Icon(Icons.chevron_right_rounded, color: Tga.textDim),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}

String _kindLabel(String kind) => switch (kind) {
      'mcp' => 'MCP',
      'openapi' => 'OpenAPI',
      'graphql' => 'GraphQL',
      _ => kind,
    };

IconData _kindIcon(String kind) => switch (kind) {
      'mcp' => Icons.hub_outlined,
      'openapi' => Icons.api_rounded,
      'graphql' => Icons.schema_outlined,
      _ => Icons.extension_outlined,
    };

Color _kindColor(String kind) => switch (kind) {
      'mcp' => Tga.iconCyan,
      'openapi' => Tga.iconBlue,
      'graphql' => Tga.iconPurple,
      _ => Tga.textSub,
    };

Color _kindBg(String kind) => switch (kind) {
      'mcp' => Tga.iconCyanBg,
      'openapi' => Tga.iconBlueBg,
      'graphql' => Tga.iconPurpleBg,
      _ => Tga.bgSoft,
    };

class _IntegrationEditor extends StatefulWidget {
  const _IntegrationEditor();

  @override
  State<_IntegrationEditor> createState() => _IntegrationEditorState();
}

class _IntegrationEditorState extends State<_IntegrationEditor> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _specUrl = TextEditingController();
  final TextEditingController _token = TextEditingController();
  final TextEditingController _headerName =
      TextEditingController(text: 'X-API-Key');
  final TextEditingController _queryName = TextEditingController(text: 'api_key');
  String _kind = 'mcp';
  String _auth = 'none';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _specUrl.dispose();
    _token.dispose();
    _headerName.dispose();
    _queryName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('integration', <String, dynamic>{
      'action': 'add',
      'name': _name.text.trim(),
      'kind': _kind,
      'url': _url.text.trim(),
      'auth_type': _auth,
      'token': _token.text,
      'header_name': _headerName.text.trim(),
      'query_name': _queryName.text.trim(),
      'spec_url': _specUrl.text.trim(),
    });
    final dynamic raw = envelope.payload;
    final Map<String, dynamic> r = raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
    if (!mounted) return;
    if (r['ok'] != true) {
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('${r['error'] ?? '接入失败'}')));
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop(true);
    messenger.showSnackBar(SnackBar(
      content: Text(r['tested'] == true
          ? '接入成功，连接测试通过'
          : '已保存，但连接测试失败：${r['error'] ?? ''}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Tga.card,
      title: Text('接入服务', style: Tga.h2),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SegmentedButton<String>(
                segments: const <ButtonSegment<String>>[
                  ButtonSegment<String>(value: 'mcp', label: Text('MCP')),
                  ButtonSegment<String>(value: 'openapi', label: Text('OpenAPI')),
                  ButtonSegment<String>(value: 'graphql', label: Text('GraphQL')),
                ],
                selected: <String>{_kind},
                onSelectionChanged: (Set<String> v) =>
                    setState(() => _kind = v.first),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                autofocus: true,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '名称，如 团队知识服务'),
              ),
              TextField(
                controller: _url,
                style: TextStyle(color: Tga.text),
                decoration: InputDecoration(
                  hintText: _kind == 'openapi'
                      ? 'OpenAPI spec 地址（https://…/openapi.json）'
                      : '服务地址（https://…）',
                ),
              ),
              if (_kind == 'openapi')
                TextField(
                  controller: _specUrl,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                    hintText: '可选：与上方地址不同的 spec 地址',
                  ),
                ),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _auth,
                dropdownColor: Tga.card,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(labelText: '认证方式'),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem<String>(value: 'none', child: Text('无认证')),
                  DropdownMenuItem<String>(value: 'bearer', child: Text('Bearer Token')),
                  DropdownMenuItem<String>(value: 'header', child: Text('API Key Header')),
                  DropdownMenuItem<String>(value: 'query', child: Text('API Key Query')),
                ],
                onChanged: (String? v) => setState(() => _auth = v ?? 'none'),
              ),
              if (_auth == 'header')
                TextField(
                  controller: _headerName,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(labelText: 'Header 名称'),
                ),
              if (_auth == 'query')
                TextField(
                  controller: _queryName,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(labelText: 'Query 参数名'),
                ),
              if (_auth != 'none')
                TextField(
                  controller: _token,
                  obscureText: true,
                  style: TextStyle(color: Tga.text),
                  decoration: const InputDecoration(
                    labelText: '凭据',
                    helperText: '写入系统安全存储；不会出现在配置、日志或模型上下文',
                    helperMaxLines: 2,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                _kind == 'mcp'
                    ? 'MCP 只支持 HTTP/SSE；移动端无法启动 stdio 进程。'
                    : _kind == 'openapi'
                        ? '会立即拉取 spec 并解析操作；解析失败会如实显示。'
                        : '会立即执行 introspection 发现可用字段。',
                style: Tga.caption,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text('取消', style: TextStyle(color: Tga.textSub)),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(_busy ? '连接中…' : '验证并添加'),
        ),
      ],
    );
  }
}

class _IntegrationDetailPage extends StatefulWidget {
  const _IntegrationDetailPage({required this.item});

  final Map<String, dynamic> item;

  @override
  State<_IntegrationDetailPage> createState() => _IntegrationDetailPageState();
}

class _IntegrationDetailPageState extends State<_IntegrationDetailPage> {
  late Map<String, dynamic> _item;
  List<Map<String, dynamic>> _logs = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _item = widget.item;
    _load();
  }

  String get _id => '${_item['id']}';

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('integration', <String, dynamic>{
      'action': action,
      'id': _id,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    final Map<String, dynamic> r = await _call('get');
    final Map<String, dynamic> l = await _call('logs', <String, dynamic>{
      'limit': 60,
    });
    if (!mounted) return;
    setState(() {
      if (r['ok'] == true && r['integration'] is Map) {
        _item = Map<String, dynamic>.from(r['integration'] as Map);
      }
      _logs = (l['logs'] is List ? l['logs'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
      _loading = false;
    });
  }

  Future<void> _test() async {
    if (_testing) return;
    setState(() => _testing = true);
    final Map<String, dynamic> r = await _call('test');
    if (!mounted) return;
    setState(() => _testing = false);
    _toast(r['ok'] == true
        ? '连接成功，${(r['tools'] as List?)?.length ?? 0} 个工具'
        : '${r['error'] ?? '连接失败'}');
    await _load();
  }

  Future<void> _toggle() async {
    final Map<String, dynamic> r =
        await _call('toggle', <String, dynamic>{'enabled': _item['enabled'] != true});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '切换失败'}');
      return;
    }
    await _load();
  }

  Future<void> _delete() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('删除「${_item['name']}」？', style: Tga.h2),
        content: Text('会一并删除保存的凭据；已注册的 Agent 工具立即失效。', style: Tga.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Tga.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final Map<String, dynamic> r = await _call('delete');
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '删除失败'}');
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _callTool(Map<String, dynamic> tool) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext _) => _ToolCallDialog(
        integration: _item,
        tool: tool,
      ),
    );
    if (ok == true && mounted) await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final List<dynamic> tools =
        (_item['tools'] is List) ? _item['tools'] as List : <dynamic>[];
    return TgaPage(
      title: '${_item['name']}',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _test,
          tooltip: '测试连接',
          icon: _testing
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Tga.primary,
                  ),
                )
              : Icon(Icons.wifi_tethering_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading ? null : _delete,
          tooltip: '删除',
          icon: Icon(Icons.delete_outline_rounded, color: Tga.red),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Tga.primary,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '${_kindLabel('${_item['kind']}')} · ${_item['url']}',
                              style: Tga.sub,
                            ),
                          ),
                          Switch(
                            value: _item['enabled'] == true,
                            activeTrackColor: Tga.primary,
                            onChanged: (bool _) => _toggle(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '认证：${_item['auth'] is Map ? (_item['auth'] as Map)['type'] : 'none'}'
                        ' · 凭据：${_item['has_secret'] == true ? '已保存' : '未保存'}'
                        ' · 上次测试：'
                        '${_item['last_test_at'] == '' ? '未测试' : (_item['last_test_ok'] == true ? '通过' : '失败')}',
                        style: Tga.caption,
                      ),
                      if ('${_item['last_error'] ?? ''}'.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        Text('${_item['last_error']}', style: TextStyle(color: Tga.red, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
                TgaGroupTitle('工具（${tools.length}）', trailing: TextButton(
                  onPressed: _test,
                  child: Text('刷新', style: TextStyle(color: Tga.primary, fontSize: 12)),
                )),
                if (tools.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有可用工具\n点右上角测试连接重新拉取',
                      icon: Icons.build_outlined,
                    ),
                  )
                else
                  for (final dynamic raw in tools)
                    if (raw is Map)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TgaCard(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.bolt_outlined, size: 17, color: Tga.primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text('${raw['name']}', style: Tga.body),
                                    if ('${raw['description'] ?? ''}'.isNotEmpty)
                                      Text(
                                        '${raw['description']}',
                                        style: Tga.caption,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed: () =>
                                    _callTool(Map<String, dynamic>.from(raw)),
                                child: Text('调用',
                                    style: TextStyle(color: Tga.primary, fontSize: 12)),
                              ),
                            ],
                          ),
                        ),
                      ),
                TgaGroupTitle('日志（最近 ${_logs.length} 条）'),
                if (_logs.isEmpty)
                  TgaCard(child: TgaEmpty('还没有调用记录', icon: Icons.history_rounded))
                else
                  for (final Map<String, dynamic> log in _logs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: <Widget>[
                          Icon(
                            log['ok'] == true
                                ? Icons.check_circle_outline_rounded
                                : Icons.error_outline_rounded,
                            size: 14,
                            color: log['ok'] == true ? Tga.green : Tga.red,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${log['action']}'
                              '${'${log['detail'] ?? ''}'.isEmpty ? '' : ' · ${log['detail']}'}',
                              style: Tga.caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Text(
                            '${log['ts'] ?? ''}'.replaceFirst('T', ' ').split('.').first,
                            style: Tga.caption,
                          ),
                        ],
                      ),
                    ),
              ],
            ),
    );
  }
}

class _ToolCallDialog extends StatefulWidget {
  const _ToolCallDialog({required this.integration, required this.tool});

  final Map<String, dynamic> integration;
  final Map<String, dynamic> tool;

  @override
  State<_ToolCallDialog> createState() => _ToolCallDialogState();
}

class _ToolCallDialogState extends State<_ToolCallDialog> {
  final Map<String, TextEditingController> _fields =
      <String, TextEditingController>{};
  final TextEditingController _query = TextEditingController();
  final TextEditingController _variables = TextEditingController(text: '{}');
  String? _result;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic> schema =
        widget.tool['input_schema'] is Map
            ? Map<String, dynamic>.from(widget.tool['input_schema'] as Map)
            : <String, dynamic>{};
    final Map<String, dynamic> props =
        schema['properties'] is Map
            ? Map<String, dynamic>.from(schema['properties'] as Map)
            : <String, dynamic>{};
    props.forEach((String key, dynamic value) {
      _fields[key] = TextEditingController();
    });
    for (final dynamic raw in (widget.tool['args'] is List
        ? widget.tool['args'] as List
        : <dynamic>[])) {
      if (raw is Map && '${raw['name'] ?? ''}'.isNotEmpty) {
        _fields['${raw['name']}'] = TextEditingController();
      }
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in _fields.values) {
      c.dispose();
    }
    _query.dispose();
    _variables.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    final Map<String, dynamic> args = <String, dynamic>{};
    _fields.forEach((String key, TextEditingController c) {
      final String text = c.text.trim();
      if (text.isEmpty) return;
      args[key] = text;
    });
    if ('${widget.integration['kind']}' == 'graphql') {
      if (_query.text.trim().isNotEmpty) args['query'] = _query.text.trim();
      if (_variables.text.trim().isNotEmpty) args['variables'] = _variables.text.trim();
    }
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('integration', <String, dynamic>{
      'action': 'call',
      'id': '${widget.integration['id']}',
      'tool': '${widget.tool['name']}',
      'arguments': args,
    });
    final dynamic raw = envelope.payload;
    final Map<String, dynamic> r = raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['ok'] == true) {
        _result = '${r['text'] ?? ''}';
      } else {
        _error = '${r['error'] ?? '调用失败'}';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool graphql = '${widget.integration['kind']}' == 'graphql';
    return AlertDialog(
      backgroundColor: Tga.card,
      title: Text('调用 ${widget.tool['name']}', style: Tga.h2),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final MapEntry<String, TextEditingController> e
                  in _fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: e.value,
                    style: TextStyle(color: Tga.text),
                    decoration: InputDecoration(labelText: e.key),
                  ),
                ),
              if (graphql) ...<Widget>[
                TextField(
                  controller: _query,
                  minLines: 4,
                  maxLines: 8,
                  style: TextStyle(color: Tga.text, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    labelText: 'GraphQL query（留空则按工具名生成）',
                  ),
                ),
                TextField(
                  controller: _variables,
                  style: TextStyle(color: Tga.text, fontFamily: 'monospace'),
                  decoration: const InputDecoration(labelText: 'variables JSON'),
                ),
              ],
              if (_error != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: Tga.red, fontSize: 12)),
              ],
              if (_result != null) ...<Widget>[
                const SizedBox(height: 10),
                Text('结果', style: Tga.sub),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Tga.bgSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    _result!.isEmpty ? '（无文本返回）' : _result!,
                    style: Tga.body,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text('关闭', style: TextStyle(color: Tga.textSub)),
        ),
        FilledButton(
          onPressed: _busy ? null : _run,
          child: Text(_busy ? '调用中…' : '调用'),
        ),
      ],
    );
  }
}
