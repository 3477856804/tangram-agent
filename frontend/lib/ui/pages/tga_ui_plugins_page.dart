import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';

/// UI 插件槽宿主页：真实读取内核注册的 widget_slots / pages 并渲染。
///
/// 数据来源只有 `plugin_kernel {action:'widget_slots'}` 与
/// `plugin_kernel {action:'pages', op:'list'}`，不做任何本地编造。
///
/// 安全边界：槽位元数据只按声明式白名单（title / text / button / link / card）
/// 渲染成原生 Flutter 组件；**绝不执行任意 HTML / JS**，未知类型如实显示
/// 「不支持的组件类型」，按钮/链接只展示、不绑定可执行动作。
class TgaUiPluginsPage extends StatefulWidget {
  const TgaUiPluginsPage({super.key});

  @override
  State<TgaUiPluginsPage> createState() => _TgaUiPluginsPageState();
}

class _TgaUiPluginsPageState extends State<TgaUiPluginsPage> {
  static const Set<String> _componentTypes = <String>{
    'title',
    'text',
    'button',
    'link',
    'card',
  };

  bool _loading = true;
  String _error = '';
  List<Map<String, dynamic>> _slots = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _pages = const <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    // 首帧后拉取，避免在 initState 内同步 setState。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) => _load());
  }

  BackendClient? _client() {
    if (!mounted) return null;
    try {
      return Provider.of<BackendClient>(context, listen: false);
    } on Object {
      return null;
    }
  }

  Future<void> _load() async {
    final BackendClient? client = _client();
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '后端未就绪：无法读取插件槽位与页面';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    String? slotsError;
    String? pagesError;
    List<Map<String, dynamic>> slots = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> pages = const <Map<String, dynamic>>[];
    try {
      final BridgeEnvelope env = await client.sendControl(
          'plugin_kernel', <String, dynamic>{'action': 'widget_slots'});
      slots = _mapList(_okList(env, 'slots'));
    } on Object catch (e) {
      slotsError = '读取槽位失败：$e';
    }
    try {
      final BridgeEnvelope env = await client.sendControl('plugin_kernel',
          <String, dynamic>{'action': 'pages', 'op': 'list'});
      pages = _mapList(_okList(env, 'pages'));
    } on Object catch (e) {
      pagesError = '读取页面失败：$e';
    }
    if (!mounted) return;
    setState(() {
      _slots = slots;
      _pages = pages;
      _error = <String?>[slotsError, pagesError]
          .whereType<String>()
          .join('\n');
      _loading = false;
    });
  }

  static List<dynamic> _okList(BridgeEnvelope env, String key) {
    final dynamic payload = env.payload;
    if (payload is! Map) {
      throw const FormatException('plugin_kernel 返回了非对象响应');
    }
    if (payload['ok'] == false) {
      throw StateError((payload['error'] ?? '未知错误').toString());
    }
    final dynamic data = payload[key];
    return data is List ? data : <dynamic>[];
  }

  static List<Map<String, dynamic>> _mapList(List<dynamic> raw) => raw
      .whereType<Map>()
      .map((Map<dynamic, dynamic> m) => m.map(
          (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v)))
      .toList(growable: false);

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is! Map) return <String, dynamic>{};
    return value.map(
        (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v));
  }

  static String _str(dynamic value, String fallback) {
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is num || value is bool) return value.toString();
    return fallback;
  }

  /// 声明式组件列表：兼容 components / widgets / children / items / blocks，
  /// 也接受「meta 自身就是一个组件」（含 type）。
  static List<Map<String, dynamic>> _componentsOf(Map<String, dynamic> meta) {
    for (final String key in const <String>[
      'components',
      'widgets',
      'children',
      'items',
      'blocks',
    ]) {
      final dynamic raw = meta[key];
      if (raw is List) {
        return raw
            .whereType<Map>()
            .map((Map<dynamic, dynamic> m) => m.map((dynamic k, dynamic v) =>
                MapEntry<String, dynamic>(k.toString(), v)))
            .toList(growable: false);
      }
    }
    if (meta['type'] is String) return <Map<String, dynamic>>[meta];
    return const <Map<String, dynamic>>[];
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Widget _unsupported(String type) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, size: 15, color: Tga.orange),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '不支持的组件类型：${type.isEmpty ? '未声明' : type}',
              style: TextStyle(fontSize: 12.5, color: Tga.orange),
            ),
          ),
        ],
      ),
    );
  }

  Widget _component(Map<String, dynamic> c, int depth) {
    final String type = (c['type'] ?? '').toString().toLowerCase();
    if (!_componentTypes.contains(type)) return _unsupported(type);
    if (depth > 3) {
      return Text('嵌套层级过深，已折叠', style: Tga.caption);
    }
    switch (type) {
      case 'title':
        return Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(_str(c['text'] ?? c['title'] ?? c['label'], '未命名标题'),
              style: Tga.h2),
        );
      case 'text':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text(
            _str(c['text'] ?? c['content'] ?? c['value'], ''),
            style: Tga.body,
          ),
        );
      case 'button':
        final String buttonLabel =
            _str(c['label'] ?? c['text'] ?? c['title'], '按钮');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => _notify('插件按钮「$buttonLabel」仅展示，未绑定可执行动作'),
              child: Text(buttonLabel),
            ),
          ),
        );
      case 'link':
        final String linkLabel = _str(c['label'] ?? c['text'], '链接');
        final String linkUrl = _str(c['url'] ?? c['href'], '');
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.link_rounded, size: 15, color: Tga.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(linkLabel,
                        style: TextStyle(fontSize: 13, color: Tga.primary)),
                    if (linkUrl.isNotEmpty)
                      Text(linkUrl, style: Tga.caption, maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
        );
      case 'card':
        final List<Map<String, dynamic>> children = _componentsOf(c);
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Tga.bgSoft,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Tga.border),
          ),
          child: children.isEmpty
              ? Text(
                  _str(c['text'] ?? c['title'] ?? c['content'], '空卡片'),
                  style: Tga.sub,
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children
                      .map((Map<String, dynamic> child) =>
                          _component(child, depth + 1))
                      .toList(growable: false),
                ),
        );
      default:
        return _unsupported(type);
    }
  }

  Widget _slotCard(Map<String, dynamic> slot) {
    final Map<String, dynamic> meta = _asMap(slot['meta']);
    final String id = _str(slot['id'], '未命名槽位');
    final String title = _str(meta['title'], id);
    final String description = _str(meta['description'] ?? meta['subtitle'], '');
    final List<Map<String, dynamic>> components = _componentsOf(meta);
    return TgaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.widgets_outlined, size: 16, color: Tga.primary),
              const SizedBox(width: 6),
              Expanded(child: Text(title, style: Tga.h2)),
              TgaTag('组件槽'),
            ],
          ),
          const SizedBox(height: 2),
          Text(id, style: Tga.caption),
          if (description.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(description, style: Tga.sub),
          ],
          const SizedBox(height: 8),
          if (components.isEmpty) ...<Widget>[
            Text('该槽位未声明可渲染组件', style: Tga.sub),
            if (meta.isNotEmpty) ...<Widget>[
              const SizedBox(height: 2),
              Text('声明字段：${meta.keys.join('、')}', style: Tga.caption),
            ],
          ] else
            ...components
                .map((Map<String, dynamic> c) => _component(c, 0)),
        ],
      ),
    );
  }

  Widget _pageRow(Map<String, dynamic> page) {
    final Map<String, dynamic> meta = _asMap(page['meta']);
    final String id = _str(page['id'], '未命名页面');
    final String title = _str(meta['title'], id);
    final String owner = _str(page['owner'], '');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(Icons.web_asset_outlined, size: 16, color: Tga.textSub),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: Tga.body),
                Text(
                  owner.isEmpty ? id : '$id · $owner',
                  style: Tga.caption,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: 'UI 插件槽',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新槽位与页面',
          onPressed: _loading ? null : _load,
          icon: Icon(Icons.refresh_rounded, color: Tga.textSub),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
        children: <Widget>[
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                _error,
                style: TextStyle(fontSize: 12.5, color: Tga.red, height: 1.5),
              ),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...<Widget>[
            TgaGroupTitle(
              '组件槽',
              trailing: TgaTag('${_slots.length}', color: Tga.textSub),
            ),
            if (_slots.isEmpty)
              const TgaCard(child: TgaEmpty('还没有插件注册组件槽'))
            else
              ..._slots.map(_slotCard),
            TgaGroupTitle(
              '注册页面',
              trailing: TgaTag('${_pages.length}', color: Tga.textSub),
            ),
            if (_pages.isEmpty)
              const TgaCard(
                child: TgaEmpty('还没有插件注册页面', icon: Icons.web_asset_outlined),
              )
            else
              TgaCard(
                child: Column(
                  children: <Widget>[
                    for (int i = 0; i < _pages.length; i++) ...<Widget>[
                      if (i > 0) Divider(height: 12, color: Tga.divider),
                      _pageRow(_pages[i]),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '槽位与页面来自内嵌内核的真实注册表；组件按声明式白名单渲染，'
              '不执行 HTML / JS。',
              style: Tga.caption,
            ),
          ],
        ],
      ),
    );
  }
}
