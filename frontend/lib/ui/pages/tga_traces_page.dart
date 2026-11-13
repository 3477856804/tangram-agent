import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';

/// 记录时间戳（秒，double），缺失记 0。
double _ts(Map<String, dynamic> r) {
  final dynamic v = r['ts'];
  return v is num ? v.toDouble() : 0;
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
class TgaTracesPage extends StatefulWidget {
  const TgaTracesPage({super.key});

  @override
  State<TgaTracesPage> createState() => _TgaTracesPageState();
}

class _TgaTracesPageState extends State<TgaTracesPage> {
  List<Map<String, dynamic>> _rows = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 拉取真实轨迹列表（按时间倒序，最新在前）。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'distill',
        <String, dynamic>{'action': 'traces'},
      );
      final dynamic payload = env.payload;
      if (payload is Map && payload['ok'] == true && payload['data'] is List) {
        final List<Map<String, dynamic>> rows =
            (payload['data'] as List).whereType<Map>().map(
          (Map<dynamic, dynamic> m) => m.map(
            (dynamic k, dynamic v) => MapEntry(k.toString(), v),
          ),
        ).toList();
        rows.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
            _ts(b).compareTo(_ts(a)));
        _rows = rows;
      } else {
        _rows = <Map<String, dynamic>>[];
        _error = payload is Map
            ? (payload['error'] ?? '后端返回了非预期结构').toString()
            : '后端返回了非预期结构';
      }
    } on Object catch (e) {
      _rows = <Map<String, dynamic>>[];
      _error = '读取工作轨迹失败：$e';
    }
    if (mounted) setState(() => _loading = false);
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
      child: _loading
          ? Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Tga.primary),
              ),
            )
          : _error != null
              ? ListView(
                  padding:
                      const EdgeInsets.fromLTRB(Tga.pagePad, 24, Tga.pagePad, 24),
                  children: <Widget>[
                    TgaCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: <Widget>[
                          Icon(Icons.cloud_off_rounded,
                              size: 30, color: Tga.orange),
                          const SizedBox(height: 10),
                          Text(_error!,
                              style: Tga.sub, textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          TgaButton(label: '重试', onTap: _load),
                        ],
                      ),
                    ),
                  ],
                )
              : _rows.isEmpty
                  ? const Center(
                      child: TgaEmpty('还没有工作轨迹，去聊一条消息就会记录',
                          icon: Icons.receipt_long_outlined),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                            Tga.pagePad, 6, Tga.pagePad, 24),
                        itemCount: _rows.length,
                        itemBuilder: (BuildContext context, int i) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _TraceCard(record: _rows[i]),
                        ),
                      ),
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
