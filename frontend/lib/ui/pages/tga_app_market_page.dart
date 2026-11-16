import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../services/persona_store.dart';

/// Agent 应用市场：行业工作站模板。
///
/// 安装会真实创建工作流与知识库；人格预设可选写入 PersonaStore。
/// 权限建议只展示、不自动放宽；没有支付系统，付费标记不产生扣款。
class TgaAppMarketPage extends StatefulWidget {
  const TgaAppMarketPage({super.key});

  @override
  State<TgaAppMarketPage> createState() => _TgaAppMarketPageState();
}

class _TgaAppMarketPageState extends State<TgaAppMarketPage> {
  List<Map<String, dynamic>> _installed = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _templates = <Map<String, dynamic>>[];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('app_market', <String, dynamic>{
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
        _installed = (r['installed'] is List ? r['installed'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList()
            .reversed
            .toList();
        _templates = (r['templates'] is List ? r['templates'] as List : <dynamic>[])
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

  Future<void> _install(Map<String, dynamic> pkg) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('安装「${pkg['name']}」', style: Tga.h2),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(pkg['description'].toString(), style: Tga.body),
              const SizedBox(height: 8),
              Text(
                '将创建：${(pkg['workflows'] is List) ? (pkg['workflows'] as List).length : 0} 个工作流 · '
                '${(pkg['knowledge'] is List) ? (pkg['knowledge'] as List).length : 0} 个知识库。'
                '\n人格预设可在安装后选择是否启用。'
                '\n权限建议只展示，不会自动放宽。',
                style: Tga.sub,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('安装')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    final Map<String, dynamic> r =
        await _call('install', <String, dynamic>{'package': pkg});
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      final List<dynamic> errors =
          r['errors'] is List ? r['errors'] as List : <dynamic>[];
      _toast(errors.isEmpty
          ? (r['error'] ?? '安装失败').toString()
          : '安装部分失败：${errors.first}');
      await _load();
      return;
    }
    await _load();
    await _maybeApplyPersona(r['persona']);
    _toast('已安装：${pkg['name']}');
  }

  Future<void> _maybeApplyPersona(dynamic raw) async {
    if (raw is! Map || raw.isEmpty) return;
    final Map<String, dynamic> p = Map<String, dynamic>.from(raw);
    final String name = (p['name'] ?? '').toString().trim();
    if (name.isEmpty) return;
    final bool? apply = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('启用应用人格？', style: Tga.h2),
        content: Text(
          '应用自带人格「$name」。启用会新建一个人格并切换为当前人格，'
          '系统提示词随之更新；可随时在「人格设置」切回。',
          style: Tga.body,
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('暂不启用', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('启用')),
        ],
      ),
    );
    if (apply != true || !mounted) return;
    final PersonaStore store = context.read<PersonaStore>();
    store.addPersona(name);
    store.updateActivePersona(
      identity: (p['identity'] ?? '').toString(),
      personality: (p['personality'] ?? '').toString(),
      audience: (p['audience'] ?? '').toString(),
    );
  }

  Future<void> _import() async {
    final TextEditingController ctrl = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('导入应用包', style: Tga.h2),
        content: TextField(
          controller: ctrl,
          minLines: 6,
          maxLines: 14,
          style: TextStyle(color: Tga.text, fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(
              hintText: '{ "format": "tga-app/1", "name": "...", ... }'),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () async {
                final ClipboardData? data = await Clipboard.getData('text/plain');
                if (data?.text != null) ctrl.text = data!.text!;
              },
              child: Text('从剪贴板', style: TextStyle(color: Tga.textSub))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('导入')),
        ],
      ),
    );
    if (go != true) {
      ctrl.dispose();
      return;
    }
    setState(() => _busy = true);
    final Map<String, dynamic> r =
        await _call('import', <String, dynamic>{'json': ctrl.text});
    ctrl.dispose();
    if (!mounted) return;
    setState(() => _busy = false);
    if (r['ok'] != true) {
      _toast((r['error'] ?? '导入失败').toString());
      return;
    }
    await _load();
    await _maybeApplyPersona(r['persona']);
    _toast('导入完成');
  }

  Future<void> _export(Map<String, dynamic> app) async {
    final Map<String, dynamic> r =
        await _call('export', <String, dynamic>{'id': app['id']});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '导出失败').toString());
      return;
    }
    await Clipboard.setData(ClipboardData(text: r['json'].toString()));
    _toast('应用包 JSON 已复制到剪贴板');
  }

  Future<void> _delete(Map<String, dynamic> app) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('移除应用记录？', style: Tga.h2),
        content: Text('仅移除安装记录；已创建的工作流与知识库会保留，需在对应页面手动删除。',
            style: Tga.body),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('移除', style: TextStyle(color: Tga.red))),
        ],
      ),
    );
    if (ok != true) return;
    await _call('delete', <String, dynamic>{'id': app['id']});
    await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: 'Agent 应用市场',
      actions: <Widget>[
        IconButton(
          onPressed: _loading || _busy ? null : _import,
          tooltip: '导入应用包',
          icon: Icon(Icons.file_download_outlined, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading || _busy ? null : _load,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Tga.primary)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(Icons.storefront_outlined, size: 18, color: Tga.primary),
                          const SizedBox(width: 8),
                          Text('行业工作站模板', style: Tga.h2),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '应用包 = 人格 + 工作流 + 知识库模板 + 权限建议 + 模型组合。\n'
                        '安装后可在对应页面继续编辑；权限建议不会自动放宽。',
                        style: Tga.sub,
                      ),
                    ],
                  ),
                ),
                TgaGroupTitle('内置模板（${_templates.length}）'),
                for (final Map<String, dynamic> t in _templates)
                  _PackageTile(
                    pkg: t,
                    onInstall: _busy ? null : () => _install(t),
                  ),
                TgaGroupTitle('已安装（${_installed.length}）'),
                if (_installed.isEmpty)
                  TgaCard(
                      child: TgaEmpty('还没有安装应用',
                          icon: Icons.widgets_outlined))
                else
                  for (final Map<String, dynamic> app in _installed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: Tga.iconGreenBg,
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Icon(Icons.widgets_rounded,
                                  size: 18, color: Tga.iconGreen),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(app['name'].toString(), style: Tga.h2),
                                  Text(
                                    '${(app['workflow_ids'] is List) ? (app['workflow_ids'] as List).length : 0} 个工作流 · '
                                    '${(app['knowledge_ids'] is List) ? (app['knowledge_ids'] as List).length : 0} 个知识库'
                                    '${(app['price'] is num && (app['price'] as num) > 0) ? ' · 付费 ${app['price']} ${app['currency']}' : ' · 免费'}',
                                    style: Tga.caption,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '导出 JSON',
                              icon: Icon(Icons.ios_share_rounded,
                                  size: 18, color: Tga.textSub),
                              onPressed: () => _export(app),
                            ),
                            IconButton(
                              tooltip: '移除记录',
                              icon: Icon(Icons.delete_outline_rounded,
                                  size: 18, color: Tga.red),
                              onPressed: () => _delete(app),
                            ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}

class _PackageTile extends StatelessWidget {
  const _PackageTile({required this.pkg, this.onInstall});

  final Map<String, dynamic> pkg;
  final VoidCallback? onInstall;

  @override
  Widget build(BuildContext context) {
    final List<dynamic> tags =
        pkg['tags'] is List ? pkg['tags'] as List : <dynamic>[];
    final Map? permissions =
        pkg['permissions'] is Map ? pkg['permissions'] as Map : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Tga.iconPurpleBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.extension_rounded,
                      size: 19, color: Tga.iconPurple),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(pkg['name'].toString(), style: Tga.h2),
                      Text(
                        '${pkg['author'] ?? ''} · v${pkg['version'] ?? ''} · '
                        '${(pkg['price'] is num && (pkg['price'] as num) > 0) ? '付费' : '免费'}',
                        style: Tga.caption,
                      ),
                    ],
                  ),
                ),
                TgaButton(label: '安装', onTap: onInstall ?? () {}),
              ],
            ),
            const SizedBox(height: 6),
            Text(pkg['description'].toString(), style: Tga.body),
            if (tags.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  for (final dynamic tag in tags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Tga.bgSoft,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(tag.toString(), style: Tga.caption),
                    ),
                ],
              ),
            ],
            if (permissions != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                '权限建议：工具 ${permissions['tools'] ?? '—'} · 文件 ${permissions['files'] ?? '—'}',
                style: Tga.caption,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
