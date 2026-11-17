import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 性能诊断：真实读取后端启动阶段耗时、数据目录占用、知识库计数与审计文件。
///
/// 所有数字都来自 `rpc` 域 `perf` 动作的真实响应；
/// 缺字段如实显示未知，不构造任何示例数据，也不做虚假进度动画。
class TgaPerformancePage extends StatefulWidget {
  const TgaPerformancePage({super.key});

  @override
  State<TgaPerformancePage> createState() => _TgaPerformancePageState();
}

class _TgaPerformancePageState extends State<TgaPerformancePage> {
  Map<String, dynamic> _timeline = const <String, dynamic>{};
  Map<String, dynamic> _storage = const <String, dynamic>{};
  Map<String, dynamic> _knowledge = const <String, dynamic>{};
  Map<String, dynamic>? _audit;
  bool _loading = true;
  bool _copying = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final BackendClient backend = context.read<BackendClient>();
      final envelope = await backend.sendControl(
        'rpc',
        <String, dynamic>{'action': 'perf'},
      );
      final dynamic raw = envelope.payload;
      final Map<String, dynamic> r = raw is Map
          ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
          : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (r['ok'] != true) {
          // 失败时清空旧数据，避免把上一次结果当成当前状态展示。
          _error = (r['error'] ?? '性能诊断失败').toString();
          _timeline = const <String, dynamic>{};
          _storage = const <String, dynamic>{};
          _knowledge = const <String, dynamic>{};
          _audit = null;
          return;
        }
        _error = '';
        _timeline = _asMap(r['timeline']);
        _storage = _asMap(r['storage']);
        _knowledge = _asMap(r['knowledge']);
        _audit = r['audit'] is Map ? _asMap(r['audit']) : null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '性能诊断失败：$e';
        _timeline = const <String, dynamic>{};
        _storage = const <String, dynamic>{};
        _knowledge = const <String, dynamic>{};
        _audit = null;
      });
    }
  }

  void _refresh() {
    setState(() {
      _loading = true;
      _error = '';
    });
    _load();
  }

  /// 复制脱敏诊断包：json 由后端真实生成，失败如实提示，不谎报成功。
  Future<void> _copyDiagnostics() async {
    if (_copying) return;
    setState(() => _copying = true);
    try {
      final BackendClient backend = context.read<BackendClient>();
      final envelope = await backend.sendControl(
        'rpc',
        <String, dynamic>{'action': 'diagnostics'},
      );
      final dynamic raw = envelope.payload;
      final Map<String, dynamic> r = raw is Map
          ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
          : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
      if (r['ok'] != true) {
        _toast('诊断包导出失败：${r['error'] ?? '后端未返回 ok'}', error: true);
        return;
      }
      final String json = (r['json'] ?? '').toString();
      if (json.isEmpty) {
        _toast('诊断包导出失败：后端未返回 json', error: true);
        return;
      }
      await Clipboard.setData(ClipboardData(text: json));
      _toast('诊断包已复制到剪贴板');
    } on Object catch (e) {
      _toast('诊断包导出失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  void _toast(String text, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          duration: const Duration(seconds: 3),
          backgroundColor: error ? Tga.red : null,
        ),
      );
  }

  Map<String, dynamic> _asMap(dynamic raw) => raw is Map
      ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
      : <String, dynamic>{};

  List<Map<String, dynamic>> _mapList(dynamic raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((Map m) =>
              m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)))
          .toList()
      : <Map<String, dynamic>>[];

  /// 毫秒：整数按原样，小数保留 1 位；缺字段如实显示未知。
  String _ms(dynamic v) {
    if (v is int) return '$v ms';
    if (v is num) return '${v.toStringAsFixed(1)} ms';
    return '未知';
  }

  /// 真实字节数按 B / KB / MB / GB 格式化，非数字如实显示未知。
  String _bytes(dynamic v) {
    if (v is! num) return '未知';
    final double b = v.toDouble();
    if (b < 1024) return '${b.toStringAsFixed(0)} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / 1048576).toStringAsFixed(1)} MB';
    return '${(b / 1073741824).toStringAsFixed(2)} GB';
  }

  /// 知识库原始计数：兼容直接字段与嵌套在 stats 里的两种结构，
  /// 只展示标量值，未知字段名原样保留，不做任何推算。
  List<MapEntry<String, String>> _knowledgeRows() {
    final Map<String, dynamic> merged = <String, dynamic>{};
    final dynamic nested = _knowledge['stats'];
    if (nested is Map) {
      nested.forEach((dynamic k, dynamic v) {
        merged[k.toString()] = v;
      });
    }
    _knowledge.forEach((String k, dynamic v) {
      if (k == 'ok' || k == 'error' || k == 'stats') return;
      merged[k] = v;
    });
    const Map<String, String> labels = <String, String>{
      'library_count': '知识库数',
      'enabled_libraries': '启用中',
      'documents': '文档数',
      'chunks': '分块数',
      'data_file': '数据文件',
    };
    final List<MapEntry<String, String>> rows = <MapEntry<String, String>>[];
    merged.forEach((String k, dynamic v) {
      if (v is Map || v is List) return;
      final String label = labels[k] ?? k;
      rows.add(MapEntry<String, String>(label, v is bool ? (v ? '是' : '否') : '$v'));
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> stages = _mapList(_timeline['stages']);
    final List<Map<String, dynamic>> dirs = _mapList(_storage['dirs']);
    final List<MapEntry<String, String>> knowledgeRows = _knowledgeRows();
    final List<dynamic> overNames =
        _timeline['over_budget'] is List ? _timeline['over_budget'] as List : <dynamic>[];
    final bool truncated = _storage['truncated'] == true;
    final bool empty = stages.isEmpty &&
        dirs.isEmpty &&
        knowledgeRows.isEmpty &&
        _audit == null;
    return TgaPage(
      title: '性能诊断',
      actions: <Widget>[
        IconButton(
          onPressed: _loading || _copying ? null : _copyDiagnostics,
          tooltip: '复制诊断包',
          icon: _copying
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Tga.primary),
                )
              : Icon(Icons.content_copy_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading ? null : _refresh,
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
                    strokeWidth: 2, color: Tga.primary),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                if (_error.isNotEmpty)
                  TgaCard(
                    child: Text(_error,
                        style: Tga.body.copyWith(color: Tga.red)),
                  ),
                if (!empty) ...<Widget>[
                  TgaGroupTitle('启动阶段'),
                  TgaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _row('总计', _ms(_timeline['total_ms'])),
                        if (overNames.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              '超标阶段：${overNames.map((dynamic e) => e.toString()).join('、')}',
                              style: Tga.caption.copyWith(color: Tga.red),
                            ),
                          ),
                        const SizedBox(height: 4),
                        if (stages.isEmpty)
                          Text('后端未返回阶段数据', style: Tga.sub)
                        else
                          for (final Map<String, dynamic> s in stages)
                            _stageRow(s),
                      ],
                    ),
                  ),
                  TgaGroupTitle('存储占用'),
                  TgaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (dirs.isEmpty)
                          Text('后端未返回目录占用', style: Tga.sub)
                        else
                          for (final Map<String, dynamic> d in dirs) _dirRow(d),
                        if (truncated)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Row(
                              children: <Widget>[
                                Icon(Icons.warning_amber_rounded,
                                    size: 15, color: Tga.orange),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    '统计已截断：仅统计了部分目录，字节合计并不完整',
                                    style:
                                        Tga.caption.copyWith(color: Tga.orange),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  TgaGroupTitle('知识库与审计'),
                  TgaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        if (knowledgeRows.isEmpty)
                          Text('后端未返回知识库计数', style: Tga.sub)
                        else ...<Widget>[
                          Text('知识库',
                              style: Tga.sub
                                  .copyWith(fontWeight: FontWeight.w600)),
                          for (final MapEntry<String, String> row
                              in knowledgeRows)
                            _row(row.key, row.value),
                        ],
                        const SizedBox(height: 10),
                        Text('审计文件',
                            style:
                                Tga.sub.copyWith(fontWeight: FontWeight.w600)),
                        if (_audit == null)
                          Text('后端未返回审计信息', style: Tga.sub)
                        else ...<Widget>[
                          _row(
                            '存在性',
                            _audit!['exists'] is bool
                                ? (_audit!['exists'] as bool ? '存在' : '不存在')
                                : '未知',
                          ),
                          _row('大小', _bytes(_audit!['bytes'])),
                        ],
                      ],
                    ),
                  ),
                ] else if (_error.isEmpty)
                  const TgaEmpty('暂无性能诊断数据'),
              ],
            ),
    );
  }

  /// 阶段是否超标：优先用后端显式标记；后端只给耗时与预算时，
  /// 按其后端同一规则（预算 > 0 且耗时超出）判定。
  bool _stageOver(Map<String, dynamic> s) {
    final dynamic flag = s['over_budget'];
    if (flag is bool) return flag;
    final dynamic budget = s['budget_ms'];
    final dynamic duration = s['duration_ms'];
    return budget is num &&
        budget > 0 &&
        duration is num &&
        duration > budget;
  }

  Widget _stageRow(Map<String, dynamic> s) {
    final bool background = s['background'] == true;
    final bool over = _stageOver(s);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text((s['name'] ?? '未命名阶段').toString(),
                    style: Tga.body),
              ),
              if (background) ...<Widget>[
                TgaTag('后台', color: Tga.cyan),
                const SizedBox(width: 4),
              ],
              if (over) TgaTag('超标', color: Tga.red),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '耗时 ${_ms(s['duration_ms'])} · 预算 ${_ms(s['budget_ms'])}',
            style: Tga.sub.copyWith(color: over ? Tga.red : null),
          ),
        ],
      ),
    );
  }

  Widget _dirRow(Map<String, dynamic> d) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text((d['name'] ?? '未命名目录').toString(),
                      style: Tga.body),
                  Text(
                    d['file_count'] is num
                        ? '${(d['file_count'] as num).toInt()} 个文件'
                        : '文件数未知',
                    style: Tga.caption,
                  ),
                ],
              ),
            ),
            Text(_bytes(d['bytes']),
                style: Tga.body.copyWith(fontWeight: FontWeight.w600)),
          ],
        ),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(width: 96, child: Text(label, style: Tga.sub)),
            Expanded(child: Text(value, style: Tga.body)),
          ],
        ),
      );
}
