import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 硬件自适应调度：真实探针 + 量化/后端/路由建议 + 轻/重任务队列。
///
/// 只做调度建议与排队，不执行模型；探针不可读的字段如实显示未知。
class TgaComputePage extends StatefulWidget {
  const TgaComputePage({super.key});

  @override
  State<TgaComputePage> createState() => _TgaComputePageState();
}

class _TgaComputePageState extends State<TgaComputePage> {
  final TextEditingController _task = TextEditingController();
  Map<String, dynamic>? _probe;
  Map<String, dynamic>? _recommendation;
  Map<String, dynamic>? _decision;
  int _pendingLight = 0;
  int _pendingHeavy = 0;
  bool _loading = true;
  bool _heavy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _task.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('compute', <String, dynamic>{
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
      final Map<String, dynamic> r = await _call('detect');
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (r['ok'] != true) {
          _error = (r['error'] ?? '探测失败').toString();
          return;
        }
        _probe = r['probe'] is Map ? Map<String, dynamic>.from(r['probe'] as Map) : null;
        _recommendation = r['recommendation'] is Map
            ? Map<String, dynamic>.from(r['recommendation'] as Map)
            : null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '探测失败：$e';
      });
    }
  }

  Future<void> _schedule() async {
    final String id = _task.text.trim();
    if (id.isEmpty) {
      _toast('请输入任务 id');
      return;
    }
    final Map<String, dynamic> r = await _call('schedule', <String, dynamic>{
      'id': id,
      'weight': _heavy ? 'heavy' : 'light',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '入队失败').toString());
      return;
    }
    setState(() {
      _decision = r['decision'] is Map
          ? Map<String, dynamic>.from(r['decision'] as Map)
          : null;
      _pendingLight = (r['pending_light'] is num)
          ? (r['pending_light'] as num).toInt()
          : 0;
      _pendingHeavy = (r['pending_heavy'] is num)
          ? (r['pending_heavy'] as num).toInt()
          : 0;
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String _num(dynamic v, [String suffix = '']) {
    if (v is num) return '${v.toStringAsFixed(v is int ? 0 : 1)}$suffix';
    return '未知';
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> p = _probe ?? <String, dynamic>{};
    final Map<String, dynamic> rec = _recommendation ?? <String, dynamic>{};
    final List<dynamic> reasons =
        rec['reasons'] is List ? rec['reasons'] as List : <dynamic>[];
    return TgaPage(
      title: '算力调度',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: '重新探测',
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
                if (_error.isNotEmpty)
                  TgaCard(
                    child: Text(_error, style: Tga.body.copyWith(color: Tga.red)),
                  ),
                TgaGroupTitle('本机硬件'),
                TgaCard(
                  child: Column(
                    children: <Widget>[
                      _row('平台', (p['platform'] ?? '未知').toString()),
                      _row('CPU 核心', _num(p['cores'])),
                      _row('内存', '${_num(p['total_mem_mb'], ' MB')}'
                          '（可用 ${_num(p['free_mem_mb'], ' MB')}）'),
                      _row('GPU', (p['gpu_name'] ?? '未检测到').toString()),
                      _row('显存', _num(p['vram_mb'], ' MB')),
                      _row('温度状态', (p['thermal'] ?? 'unknown').toString()),
                      _row('电量',
                          (p['battery'] is num && (p['battery'] as num) >= 0)
                              ? '${p['battery']}%'
                              : '未知'),
                    ],
                  ),
                ),
                TgaGroupTitle('调度建议'),
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _row('量化', (rec['quantization'] ?? '—').toString()),
                      _row('推理后端', (rec['backend'] ?? '—').toString()),
                      _row('任务路由', (rec['route'] ?? '—').toString()),
                      _row('并发上限', _num(rec['max_concurrency'])),
                      _row('降级', rec['degraded'] == true ? '是' : '否'),
                      if (reasons.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 6),
                        Text('原因', style: Tga.sub.copyWith(fontWeight: FontWeight.w600)),
                        for (final dynamic r in reasons)
                          Text('· ${r.toString()}', style: Tga.caption),
                      ],
                      const SizedBox(height: 6),
                      Text('仅做调度建议，不执行模型；显存/温度/电量不可读时如实标未知。',
                          style: Tga.caption),
                    ],
                  ),
                ),
                TgaGroupTitle('任务排队'),
                TgaCard(
                  child: Column(
                    children: <Widget>[
                      TextField(
                        controller: _task,
                        style: TextStyle(color: Tga.text),
                        decoration: const InputDecoration(
                            hintText: '任务 id，例如 批量视频导出'),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _heavy,
                        onChanged: (bool v) => setState(() => _heavy = v),
                        title: Text('重量任务（优先 PC / GPU）', style: Tga.body),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TgaButton(
                            label: '加入队列', icon: Icons.playlist_add_rounded, onTap: _schedule),
                      ),
                      const SizedBox(height: 6),
                      _row('轻任务队列', '$_pendingLight'),
                      _row('重任务队列', '$_pendingHeavy'),
                      if (_decision != null) ...<Widget>[
                        const SizedBox(height: 6),
                        Text(
                          '${_decision!['status']} · ${_decision!['route']} · 位置 ${_decision!['position']}',
                          style: Tga.body.copyWith(color: Tga.primary),
                        ),
                        Text(
                          (_decision!['reason'] ?? '').toString(),
                          style: Tga.caption,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: <Widget>[
            SizedBox(width: 88, child: Text(label, style: Tga.sub)),
            Expanded(child: Text(value, style: Tga.body)),
          ],
        ),
      );
}
