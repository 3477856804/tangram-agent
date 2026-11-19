import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/downloader.dart';
import '../../services/model_registry.dart';
import 'tga_run_page.dart';
import 'tga_settings_page.dart';
import 'tga_store_page.dart';

/// 概览页（LocModel 风格）：一屏汇总本机真实运行态势、模型、下载与轨迹。
///
/// 所有数字都来自真实来源，读取失败如实标注，绝不写死假数据：
///   * 物理内存 = `model_store hardware` 的 memory_gb（读不到显示「未知」）；
///   * 已装本地模型 = [ModelRegistry.localEntries]（真实磁盘扫描）；
///   * 模型文件数量 / 总字节 = `model_store list` 的 local_files；
///   * 下载任务 = 内嵌后端 [DownloadManager] 的真实 job 状态与落盘字节；
///   * 最近轨迹 = `distill traces`（harness work_traces）真实分页返回。
class TgaOverviewPage extends StatefulWidget {
  const TgaOverviewPage({super.key});

  @override
  State<TgaOverviewPage> createState() => _TgaOverviewPageState();
}

class _TgaOverviewPageState extends State<TgaOverviewPage> {
  bool _loading = true;

  /// 真实物理内存（GB）；null = 未读到，显示「未知」而非猜测。
  double? _memoryGb;

  /// `model_store list` 的 local_files 真实统计。
  int? _localCount;
  int? _localBytes;
  List<_LocalFile> _localFiles = <_LocalFile>[];
  String _listError = '';

  /// `distill traces` 真实返回：最近一页记录 + 总条数。
  int _traceTotal = 0;
  List<_TraceRow> _traces = <_TraceRow>[];
  String _traceError = '';
  String _traceFilter = '全部';

  /// 真实下载任务（仅 running 状态）。
  List<_DownloadRow> _downloads = <_DownloadRow>[];
  bool _downloadsKnown = false;
  Timer? _poll;

  /// 请求代际号：刷新时旧请求的结果直接作废，避免乱序覆盖。
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final BackendClient backend = context.read<BackendClient>();
    final int gen = ++_loadGen;
    if (mounted) setState(() => _loading = true);

    // ---- 1. 真实物理内存 ----
    double? memory;
    try {
      final envelope = await backend.sendControl(
          'model_store', <String, dynamic>{'action': 'hardware'});
      final dynamic payload = envelope.payload;
      final dynamic raw = payload is Map ? payload['memory_gb'] : null;
      memory = raw is num ? raw.toDouble() : null;
    } on Object {
      memory = null; // 后端未就绪：保持「未知」，不猜硬件
    }

    // ---- 2. 本地模型文件真实扫描 ----
    int? count;
    int? bytes;
    final List<_LocalFile> files = <_LocalFile>[];
    String listError = '';
    try {
      final envelope = await backend.sendControl('model_store',
          <String, dynamic>{'action': 'list', 'query': ''});
      final dynamic payload = envelope.payload;
      if (payload is Map && payload['local_files'] is List) {
        for (final dynamic f in payload['local_files'] as List) {
          if (f is! Map) continue;
          final String name = (f['name'] ?? '').toString();
          if (name.isEmpty) continue;
          final int size = f['size'] is num ? (f['size'] as num).toInt() : 0;
          files.add(_LocalFile(name: name, bytes: size));
        }
        count = files.length;
        bytes = files.fold<int>(0, (int a, _LocalFile b) => a + b.bytes);
      } else {
        listError = payload is Map
            ? (payload['error'] ?? '后端返回非预期结构').toString()
            : '后端返回非预期结构';
      }
    } on Object catch (e) {
      listError = '本地文件读取失败：$e';
    }

    // ---- 3. 最近真实轨迹 ----
    int total = 0;
    final List<_TraceRow> traces = <_TraceRow>[];
    String traceError = '';
    try {
      final envelope = await backend.sendControl('distill', <String, dynamic>{
        'action': 'traces',
        'limit': 5,
        'offset': 0,
      });
      final dynamic payload = envelope.payload;
      if (payload is Map && payload['ok'] == true && payload['data'] is List) {
        for (final dynamic r in payload['data'] as List) {
          if (r is! Map) continue;
          traces.add(_TraceRow(
            kind: (r['kind'] ?? '').toString(),
            text: (r['text'] ?? r['task'] ?? '').toString(),
            reply: (r['reply'] ?? '').toString(),
            source: (r['source'] ?? r['engine'] ?? '').toString(),
            ts: _tsOf(r),
          ));
        }
        total = payload['total'] is num
            ? (payload['total'] as num).toInt()
            : traces.length;
      } else {
        traceError = payload is Map
            ? (payload['error'] ?? '后端返回非预期结构').toString()
            : '后端返回非预期结构';
      }
    } on Object catch (e) {
      traceError = '读取轨迹失败：$e';
    }

    if (!mounted || gen != _loadGen) return;
    setState(() {
      _loading = false;
      _memoryGb = memory;
      _localCount = count;
      _localBytes = bytes;
      _localFiles = files;
      _listError = listError;
      _traceTotal = total;
      _traces = traces;
      _traceError = traceError;
    });
    _loadDownloads();
  }

  /// 从内嵌后端的 DownloadManager 读真实任务：`all` 拿全部 job，
  /// `job(id)` + `progress(job)` 拿真实落盘字节百分比。
  /// 仅 inProcess 模式能拿到实例，拿不到时如实标注、不编造任务。
  void _loadDownloads() {
    if (!mounted) return;
    final BackendClient backend = context.read<BackendClient>();
    final DownloadManager? manager = backend.embeddedBackend?.downloads;
    if (manager == null) {
      setState(() {
        _downloadsKnown = false;
        _downloads = <_DownloadRow>[];
      });
      _syncPolling();
      return;
    }
    final List<_DownloadRow> rows = <_DownloadRow>[];
    for (final Map<String, dynamic> json in manager.all) {
      final String id = (json['job_id'] ?? '').toString();
      final DownloadJob? job = manager.job(id);
      if (job == null || job.status != 'running') continue;
      final Map<String, dynamic> progress = manager.progress(job);
      final List<String> segments = job.target.split(RegExp(r'[\\/]'));
      rows.add(_DownloadRow(
        name: segments.isEmpty ? '未知文件' : segments.last,
        percent:
            progress['percent'] is num ? (progress['percent'] as num).toDouble() : 0,
        downloaded: progress['downloaded'] is num
            ? (progress['downloaded'] as num).toInt()
            : 0,
        total:
            progress['total'] is num ? (progress['total'] as num).toInt() : 0,
      ));
    }
    if (!mounted) return;
    setState(() {
      _downloadsKnown = true;
      _downloads = rows;
    });
    _syncPolling();
  }

  /// 有运行中的下载才轮询真实进度；没有则停掉定时器省电。
  void _syncPolling() {
    if (_downloads.isEmpty) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    _poll ??= Timer.periodic(
        const Duration(milliseconds: 1200), (_) => _loadDownloads());
  }

  void _push(Widget page) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (BuildContext _) => page));
  }

  /// 对话入口：概览页是从首页推进来的，回退到首个路由即回到对话首页。
  void _backHome() {
    Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final ModelRegistry registry = context.watch<ModelRegistry>();
    final ModelEntry selected = registry.selected;
    return TgaPage(
      title: '概览',
      actions: <Widget>[
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: _load,
        color: Tga.primary,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(Tga.pagePad, 8, Tga.pagePad, 32),
          children: <Widget>[
            _heroCard(),
            const TgaGroupTitle('本机状态'),
            Row(
              children: <Widget>[
                TgaStatCard(
                  value: _memoryGb == null
                      ? '未知'
                      : '${_memoryGb!.toStringAsFixed(1)} GB',
                  label: '物理内存',
                  color: Tga.primary,
                  icon: Icons.memory_rounded,
                ),
                const SizedBox(width: 12),
                TgaStatCard(
                  value: '${registry.localEntries.length}',
                  label: '已装本地模型',
                  color: Tga.purple,
                  icon: Icons.developer_board_outlined,
                ),
              ],
            ),
            const TgaGroupTitle('快捷入口'),
            _quickEntries(),
            const TgaGroupTitle('模型文件'),
            _modelCard(selected: selected),
            TgaGroupTitle(
              '下载任务',
              trailing: TgaTag(
                _downloads.isEmpty
                    ? (_downloadsKnown ? '空闲' : '读取中')
                    : '${_downloads.length} 个运行中',
                color: _downloads.isEmpty
                    ? (_downloadsKnown ? Tga.green : Tga.textSub)
                    : Tga.primary,
              ),
            ),
            _downloadCard(),
            TgaGroupTitle(
              '最近轨迹',
              trailing: TgaTag('$_traceTotal 条', color: Tga.textSub),
            ),
            _tracesCard(),
          ],
        ),
      ),
    );
  }

  Widget _heroCard() {
    return TgaCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      child: Row(
        children: <Widget>[
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: <Color>[Tga.iconBlue, Tga.iconPurple],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.insights_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('本机运行概览', style: Tga.h2),
                const SizedBox(height: 4),
                Text('模型、下载与轨迹均取自本地后端的真实数据', style: Tga.caption),
              ],
            ),
          ),
          TgaTag('真实数据', color: Tga.green),
        ],
      ),
    );
  }

  Widget _quickEntries() {
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _QuickCard(
                icon: Icons.storefront_outlined,
                title: '模型库',
                subtitle: '下载与导入',
                bg: Tga.iconBlueBg,
                fg: Tga.iconBlue,
                onTap: () => _push(const TgaStorePage()),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickCard(
                icon: Icons.play_circle_outline_rounded,
                title: '运行',
                subtitle: '端侧推理',
                bg: Tga.iconGreenBg,
                fg: Tga.iconGreen,
                onTap: () => _push(const TgaRunPage()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: _QuickCard(
                icon: Icons.chat_bubble_outline_rounded,
                title: '对话',
                subtitle: '回到首页',
                bg: Tga.iconPurpleBg,
                fg: Tga.iconPurple,
                onTap: _backHome,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _QuickCard(
                icon: Icons.settings_outlined,
                title: '设置',
                subtitle: '通用与服务',
                bg: Tga.iconGoldBg,
                fg: Tga.iconGold,
                onTap: () => _push(const TgaSettingsPage()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _modelCard({required ModelEntry selected}) {
    final String countText = _localCount == null ? '未知' : '$_localCount';
    final String bytesText =
        _localBytes == null ? '未知' : _fmtBytes(_localBytes!);
    return TgaCard(
      onTap: () => _push(const TgaStorePage()),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('当前选中', style: Tga.caption),
                    const SizedBox(height: 4),
                    Text(selected.displayName,
                        style: Tga.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              TgaTag(selected.tag,
                  color:
                      selected.kind == ModelKind.cloud ? Tga.cyan : Tga.primary),
            ],
          ),
          const SizedBox(height: 6),
          Text(selected.subtitle,
              style: Tga.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 10),
          Divider(height: 1, thickness: 1, color: Tga.divider),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Icon(Icons.folder_outlined, size: 16, color: Tga.textSub),
              const SizedBox(width: 8),
              Expanded(child: Text('本地权重文件', style: Tga.sub)),
              Text('$countText 个 · $bytesText', style: Tga.body),
            ],
          ),
          if (_localFiles.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                children: <Widget>[
                  for (final _LocalFile f in _localFiles.take(2))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: <Widget>[
                          const SizedBox(width: 24),
                          Expanded(
                            child: Text(f.name,
                                style: Tga.caption,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 8),
                          Text(_fmtBytes(f.bytes), style: Tga.caption),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          if (_listError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_listError,
                  style: Tga.caption.copyWith(color: Tga.red)),
            ),
          const SizedBox(height: 8),
          Text('来源：model_store list · local_files 真实磁盘扫描',
              style: Tga.caption),
        ],
      ),
    );
  }

  Widget _downloadCard() {
    if (_downloads.isEmpty) {
      return TgaCard(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: Tga.iconGreenBg,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.download_done_rounded,
                  size: 18, color: Tga.iconGreen),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('当前无进行中下载', style: Tga.body),
                  const SizedBox(height: 3),
                  Text(
                    _downloadsKnown
                        ? '在模型库发起下载后会实时显示真实进度'
                        : '仅进程内后端可读取下载任务',
                    style: Tga.caption,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return TgaCard(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        children: <Widget>[
          for (final _DownloadRow row in _downloads) _downloadRow(row),
        ],
      ),
    );
  }

  Widget _downloadRow(_DownloadRow row) {
    final double value = (row.percent / 100).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(row.name,
                    style: Tga.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              TgaTag('${row.percent.toStringAsFixed(1)}%', color: Tga.primary),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: Tga.divider,
              color: Tga.primary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${_fmtBytes(row.downloaded)}'
            ' / ${row.total > 0 ? _fmtBytes(row.total) : '总量未知'}',
            style: Tga.caption,
          ),
        ],
      ),
    );
  }

  Widget _tracesCard() {
    final List<_TraceRow> visible = _traceFilter == '全部'
        ? _traces
        : _traces.where((_TraceRow t) => t.label == _traceFilter).toList();
    return TgaCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TgaSegmented<String>(
            items: const <String>['全部', '对话', '工作'],
            value: _traceFilter,
            labelOf: (String s) => s,
            onChanged: (String v) => setState(() => _traceFilter = v),
          ),
          const SizedBox(height: 10),
          if (_traceError.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_traceError,
                  style: Tga.caption.copyWith(color: Tga.red)),
            )
          else if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  _traceFilter == '全部' ? '暂无真实轨迹' : '该类型暂无真实轨迹',
                  style: Tga.caption,
                ),
              ),
            )
          else
            for (int i = 0; i < visible.length; i++) ...<Widget>[
              if (i > 0)
                Divider(height: 1, thickness: 1, color: Tga.divider),
              _traceRow(visible[i]),
            ],
          const SizedBox(height: 8),
          Text('来源：distill traces · 最近 ${_traces.length} 条 / 共 $_traceTotal 条',
              style: Tga.caption),
        ],
      ),
    );
  }

  Widget _traceRow(_TraceRow trace) {
    final bool chat = trace.isChat;
    final Color color = chat ? Tga.purple : Tga.cyan;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.11),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(
              chat ? Icons.forum_outlined : Icons.work_outline_rounded,
              size: 16,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    TgaTag(trace.label, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _fmtTime(trace.ts),
                        style: Tga.caption,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  trace.text.isEmpty ? '（无文本）' : trace.text,
                  style: Tga.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (trace.reply.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(trace.reply,
                      style: Tga.sub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
                if (trace.source.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text('来源：${trace.source}',
                      style: Tga.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 快捷入口卡：圆形图标底 + 2–3 字功能名。
class _QuickCard extends StatelessWidget {
  const _QuickCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.bg,
    required this.fg,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TgaCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(
                color: fg.withValues(alpha: 0.14),
                width: 0.6,
              ),
            ),
            child: Icon(icon, size: 19, color: fg),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(title, style: Tga.body),
                const SizedBox(height: 3),
                Text(subtitle,
                    style: Tga.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 16, color: Tga.textDim),
        ],
      ),
    );
  }
}

class _LocalFile {
  const _LocalFile({required this.name, required this.bytes});

  final String name;
  final int bytes;
}

class _DownloadRow {
  const _DownloadRow({
    required this.name,
    required this.percent,
    required this.downloaded,
    required this.total,
  });

  final String name;
  final double percent;
  final int downloaded;
  final int total;
}

class _TraceRow {
  const _TraceRow({
    required this.kind,
    required this.text,
    required this.reply,
    required this.source,
    required this.ts,
  });

  final String kind;
  final String text;
  final String reply;
  final String source;
  final double ts;

  bool get isChat => kind == 'chat';

  String get label {
    switch (kind) {
      case 'chat':
        return '对话';
      case 'work':
        return '工作';
      default:
        return kind.isEmpty ? '记录' : kind;
    }
  }
}

/// 轨迹时间戳（秒，double），缺失记 0。
double _tsOf(Map<dynamic, dynamic> record) {
  final dynamic v = record['ts'];
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

/// 秒级时间戳 → 「MM-dd HH:mm」本地时间；0 显示「时间未知」。
String _fmtTime(double tsSeconds) {
  if (tsSeconds <= 0) return '时间未知';
  final DateTime t =
      DateTime.fromMillisecondsSinceEpoch((tsSeconds * 1000).round());
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// 人类可读字节大小（真实数值，不缩写不编造）。
String _fmtBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '$bytes B';
}
