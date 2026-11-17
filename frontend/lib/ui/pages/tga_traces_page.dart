import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';

/// 记录时间戳（秒，double），缺失记 0。
double _ts(Map<String, dynamic> r) {
  final dynamic v = r['ts'];
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

/// 秒级时间戳 → 「MM-dd HH:mm」本地时间展示。
String _fmtTime(double tsSeconds) {
  if (tsSeconds <= 0) return '时间未知';
  final DateTime t = DateTime.fromMillisecondsSinceEpoch((tsSeconds * 1000).round());
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 工作轨迹页：真实读取 distill {action:'traces'} 控制域。
///
/// 每条记录来自 harness 的 work_traces 落盘集合：
///   * kind='chat' → {text, reply, engine, ts}（聊天一次真实往返即记一条）
///   * kind='work' → {task, source, ts}（手动采集的工作记录）
/// 全部如实展示，不虚构轨迹；后端未就绪时如实报错并可重试。
///
/// 分页：首屏 limit=100/offset=0，搜索结果重置分页；「加载更多」按
/// offset 递增追加并按记录 id 去重，失败只提示错误、不清空已有列表。
class TgaTracesPage extends StatefulWidget {
  const TgaTracesPage({super.key});

  @override
  State<TgaTracesPage> createState() => _TgaTracesPageState();
}

class _TgaTracesPageState extends State<TgaTracesPage> {
  static const int _pageSize = 100;

  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

  String _query = '';
  int _offset = 0;
  int _total = 0;
  bool _loadingMore = false;
  String? _moreError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Map<String, dynamic> _params(int offset) => <String, dynamic>{
        'action': 'traces',
        'limit': _pageSize,
        'offset': offset,
        if (_query.isNotEmpty) 'query': _query,
      };

  List<Map<String, dynamic>> _normalize(List<dynamic> raw) => raw
      .whereType<Map>()
      .map((Map<dynamic, dynamic> m) =>
          m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)))
      .toList();

  /// 记录唯一键：优先 id；无 id 时用（绝对下标 + ts）组合。
  String _keyOf(Map<String, dynamic> r, int index) {
    final dynamic id = r['id'];
    return id != null ? 'id:$id' : 'i$index:${_ts(r)}';
  }

  /// 拉取真实轨迹列表（首屏 / 搜索 / 刷新，offset 归零）。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _moreError = null;
    });
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'distill',
        _params(0),
      );
      final dynamic payload = env.payload;
      if (payload is Map && payload['ok'] == true && payload['data'] is List) {
        final List<Map<String, dynamic>> rows =
            _normalize(payload['data'] as List);
        if (!mounted) return;
        setState(() {
          _rows = rows;
          _offset = rows.length;
          _total = payload['total'] is num
              ? (payload['total'] as num).toInt()
              : rows.length;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _rows = <Map<String, dynamic>>[];
          _offset = 0;
          _total = 0;
          _error = payload is Map
              ? (payload['error'] ?? '后端返回了非预期结构').toString()
              : '后端返回了非预期结构';
        });
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _rows = <Map<String, dynamic>>[];
        _offset = 0;
        _total = 0;
        _error = '读取工作轨迹失败：$e';
      });
    }
    if (mounted) setState(() => _loading = false);
  }

  /// 追加下一页；失败只在底部提示，不清空已有列表。
  Future<void> _loadMore() async {
    if (_loadingMore || _loading) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    final int offset = _offset;
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'distill',
        _params(offset),
      );
      final dynamic payload = env.payload;
      if (payload is Map && payload['ok'] == true && payload['data'] is List) {
        final List<Map<String, dynamic>> incoming =
            _normalize(payload['data'] as List);
        if (!mounted) return;
        final Set<String> seen = <String>{
          for (int i = 0; i < _rows.length; i++) _keyOf(_rows[i], i),
        };
        final List<Map<String, dynamic>> merged =
            List<Map<String, dynamic>>.of(_rows);
        for (int i = 0; i < incoming.length; i++) {
          final Map<String, dynamic> r = incoming[i];
          if (seen.add(_keyOf(r, offset + i))) merged.add(r);
        }
        setState(() {
          _rows = merged;
          _offset = offset + incoming.length;
          if (payload['total'] is num) {
            _total = (payload['total'] as num).toInt();
          }
        });
      } else {
        if (!mounted) return;
        setState(() {
          _moreError = payload is Map
              ? (payload['error'] ?? '后端返回了非预期结构').toString()
              : '后端返回了非预期结构';
        });
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _moreError = '加载更多失败：$e');
    }
    if (mounted) setState(() => _loadingMore = false);
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final String q = value.trim();
      if (q == _query || !mounted) return;
      _query = q;
      _load();
    });
  }

  Widget _body() {
    if (_loading && _rows.isEmpty) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Tga.primary),
        ),
      );
    }
    if (_error != null && _rows.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 24, Tga.pagePad, 24),
        children: <Widget>[
          TgaCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                Icon(Icons.cloud_off_rounded, size: 30, color: Tga.orange),
                const SizedBox(height: 10),
                Text(_error!, style: Tga.sub, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                TgaButton(label: '重试', onTap: _load),
              ],
            ),
          ),
        ],
      );
    }
    if (_rows.isEmpty) {
      return const Center(
        child: TgaEmpty('还没有工作轨迹，去聊一条消息就会记录',
            icon: Icons.receipt_long_outlined),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 24),
        itemCount: _rows.length + 1,
        itemBuilder: (BuildContext context, int i) {
          if (i == _rows.length) return _footer();
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _TraceCard(record: _rows[i]),
          );
        },
      ),
    );
  }

  /// 列表底部：已加载进度 + 加载更多（加载失败只报错）。
  Widget _footer() {
    final bool hasMore = _rows.length < _total;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 12),
      child: Column(
        children: <Widget>[
          Text('已加载 ${_rows.length} / 共 $_total 条', style: Tga.caption),
          if (_moreError != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_moreError!, style: Tga.sub, textAlign: TextAlign.center),
          ],
          if (hasMore) ...<Widget>[
            const SizedBox(height: 10),
            if (_loadingMore)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Tga.primary),
              )
            else
              TgaButton(label: '加载更多', onTap: _loadMore),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '工作轨迹',
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
        ),
      ],
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 6),
            child: TgaSearchField(
              hint: '搜索任务 / 内容 / 回复 / 来源',
              controller: _search,
              onChanged: _onSearchChanged,
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }
}

/// 单条轨迹卡片：时间 / 类型 / 任务 / 引擎 / 回复摘要。
class _TraceCard extends StatelessWidget {
  const _TraceCard({required this.record});
  final Map<String, dynamic> record;

  @override
  Widget build(BuildContext context) {
    final String kind = (record['kind'] ?? 'work').toString();
    final bool isChat = kind == 'chat';
    // chat 记录的问题在 text，work 记录的任务在 task。
    final String task = isChat
        ? (record['text'] ?? '').toString()
        : (record['task'] ?? record['text'] ?? '').toString();
    final String engine = (record['engine'] ?? '').toString();
    final String reply = (record['reply'] ?? '').toString();
    final String source = (record['source'] ?? '').toString();
    return TgaCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              TgaTag(isChat ? '对话' : '工作',
                  color: isChat ? Tga.primary : Tga.cyan),
              const SizedBox(width: 8),
              Text(_fmtTime(_ts(record)), style: Tga.caption),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 8),
          Text(task.isEmpty ? '(空内容)' : task,
              style: Tga.body, maxLines: 3, overflow: TextOverflow.ellipsis),
          if (isChat && reply.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text('回复：$reply',
                style: TextStyle(
                    fontSize: 12.5, color: Tga.textSub, height: 1.5),
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ],
          if (engine.isNotEmpty || source.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              <String>[
                if (engine.isNotEmpty) '引擎 $engine',
                if (source.isNotEmpty) '来源 $source',
              ].join(' · '),
              style: Tga.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
