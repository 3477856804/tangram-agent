import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 全局搜索：真实扫描本机对话、页面、知识库、通话、Routine、工作流与集成。
///
/// 输入后自动防抖查询；结果只来自磁盘上已有的记录，不联网、不编造。
class TgaSearchPage extends StatefulWidget {
  const TgaSearchPage({super.key});

  @override
  State<TgaSearchPage> createState() => _TgaSearchPageState();
}

class _TgaSearchPageState extends State<TgaSearchPage> {
  final TextEditingController _query = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = <Map<String, dynamic>>[];
  Map<String, int> _groups = <String, int>{};
  String _type = '';
  bool _loading = false;
  String _error = '';
  int _total = 0;

  static const Map<String, String> _typeLabels = <String, String>{
    'chat': '对话',
    'page': '页面',
    'knowledge': '知识库',
    'call': '通话',
    'routine': 'Routine',
    'workflow': '工作流',
    'integration': '集成',
  };

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _search);
  }

  Future<void> _search() async {
    final String q = _query.text.trim();
    if (q.isEmpty) {
      setState(() {
        _results = <Map<String, dynamic>>[];
        _groups = <String, int>{};
        _total = 0;
        _error = '';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final BackendClient backend = context.read<BackendClient>();
      final envelope = await backend.sendControl('search', <String, dynamic>{
        'action': 'query',
        'query': q,
        'limit': 60,
        'types': _type.isEmpty ? <String>[] : <String>[_type],
      });
      final dynamic raw = envelope.payload;
      if (!mounted) return;
      if (raw is! Map || raw['ok'] != true) {
        setState(() {
          _loading = false;
          _error = raw is Map ? '${raw['error'] ?? '搜索失败'}' : '后端返回格式异常';
        });
        return;
      }
      setState(() {
        _results = (raw['results'] is List ? raw['results'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _groups = raw['groups'] is Map
            ? (raw['groups'] as Map).map(
                (dynamic k, dynamic v) => MapEntry('$k', v is num ? v.toInt() : 0))
            : <String, int>{};
        _total = raw['total'] is num ? (raw['total'] as num).toInt() : _results.length;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '搜索失败：$e';
      });
    }
  }

  void _setType(String type) {
    setState(() => _type = type == _type ? '' : type);
    if (_query.text.trim().isNotEmpty) _search();
  }

  Future<void> _open(Map<String, dynamic> result) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text(
          '[${_typeLabels[result['type']] ?? result['type']}] ${result['title']}',
          style: Tga.h2,
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SelectableText(
                  '${result['content'] ?? result['snippet'] ?? ''}',
                  style: Tga.body,
                ),
                const SizedBox(height: 10),
                Text(
                  '来源：${result['type']} · ${result['ref'] ?? ''}'
                  '${'${result['ts'] ?? ''}'.isEmpty ? '' : ' · ${result['ts']}'}',
                  style: Tga.caption,
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('关闭', style: TextStyle(color: Tga.textSub)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '搜索',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          TgaCard(
            child: TextField(
              controller: _query,
              autofocus: true,
              style: TextStyle(color: Tga.text),
              decoration: InputDecoration(
                hintText: '搜索对话、页面、知识库、通话、Routine、工作流…',
                suffixIcon: _query.text.isEmpty
                    ? Icon(Icons.search_rounded, color: Tga.textSub)
                    : IconButton(
                        onPressed: () {
                          _query.clear();
                          _search();
                        },
                        icon: Icon(Icons.close_rounded, color: Tga.textSub),
                      ),
              ),
              onChanged: _onChanged,
              onSubmitted: (String _) => _search(),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: <Widget>[
                for (final MapEntry<String, String> e in _typeLabels.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _chip(
                      '${e.value}${_groups[e.key] == null ? '' : ' ${_groups[e.key]}'}',
                      selected: _type == e.key,
                      onTap: () => _setType(e.key),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (_error.isNotEmpty)
            TgaCard(child: Text(_error, style: TextStyle(color: Tga.red)))
          else if (_query.text.trim().isEmpty)
            TgaCard(
              child: TgaEmpty(
                '输入关键字开始搜索\n只搜索本机真实数据，不联网',
                icon: Icons.manage_search_rounded,
              ),
            )
          else if (_results.isEmpty)
            TgaCard(child: TgaEmpty('没有匹配结果', icon: Icons.search_off_rounded))
          else ...<Widget>[
            Text('共 $_total 条，显示 ${_results.length} 条', style: Tga.caption),
            const SizedBox(height: 8),
            for (final Map<String, dynamic> r in _results)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TgaCard(
                  onTap: () => _open(r),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: Tga.bgSoft,
                          borderRadius: BorderRadius.circular(Tga.rChip),
                        ),
                        child: Text(
                          _typeLabels[r['type']] ?? '${r['type']}',
                          style: Tga.caption,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text('${r['title']}', style: Tga.body),
                            const SizedBox(height: 2),
                            Text(
                              '${r['snippet']}',
                              style: Tga.caption,
                              maxLines: 2,
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
        ],
      ),
    );
  }

  Widget _chip(String label, {required bool selected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? Tga.primary : Tga.bgSoft,
          borderRadius: BorderRadius.circular(Tga.rChip),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: selected ? Tga.onPrimary : Tga.text,
          ),
        ),
      ),
    );
  }
}
