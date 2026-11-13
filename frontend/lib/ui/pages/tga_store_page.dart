import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 模型商店（2026-11-13 真实化改造）：
/// - 搜索：防抖后调用后端 `model_store ms_search` RPC（魔搭 PUT dolphin 接口，
///   返回真实模型仓库）；空关键词默认搜 'GGUF'，保证首屏即有可下载的真实内容。
///   在线卡片显示真实名称（中文名优先）、owner、下载量（千分位）、任务标签 chips。
/// - 分类胶囊（全部/文本生成/文生图/视觉多模态/语音合成/其他）按返回的
///   tasks / tags 真实归类，识别不了归「其他」。
/// - 点击在线条目 → 底部弹层 `ms_files` 列出真实 GGUF 文件（名称 + 人类可读
///   大小，按大小升序），每个文件「下载」走 `ms_download`（后端真实 Range 分片
///   下载），弹层内该行显示真实字节进度（轮询 `download_status`）；完成 toast
///   提示可在训练设置选用，失败如实显示 job.error。
/// - 本地已下载区：沿用 `model_store list` 的 local_files 真实扫描，
///   下载完成静默刷新后即出现。
/// - 网络失败 / 无结果：如实显示错误与重试按钮，不放假数据。
class TgaStorePage extends StatefulWidget {
  const TgaStorePage({super.key});

  @override
  State<TgaStorePage> createState() => _TgaStorePageState();
}

class _TgaStorePageState extends State<TgaStorePage> {
  /// 分类胶囊（任务类型）。
  static const List<String> _cats = <String>[
    '全部', '文本生成', '文生图', '视觉多模态', '语音合成', '其他',
  ];

  /// 空关键词时的默认搜索词：限定端侧可直接下载的 GGUF 仓库，首屏即真实内容。
  static const String _defaultQuery = 'GGUF';

  String _cat = '全部';
  bool _loading = false;
  String _note = ''; // 在线搜索来源说明（如实展示，不静默吞掉）
  String _error = ''; // 在线搜索失败原因（如实展示 + 重试按钮）
  String _localError = ''; // 本地扫描失败原因
  final TextEditingController _searchCtrl = TextEditingController();
  List<_ModelItem> _online = <_ModelItem>[];
  List<_ModelItem> _local = <_ModelItem>[];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 输入防抖：停顿 700ms 后才真正发起 ms_search，避免逐字符打接口。
  void _onQueryChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () => _search());
  }

  /// 拉取模型列表：在线 ms_search（真实魔搭模型仓库）+ 本地 list/local_files
  /// 真实扫描。[quiet] 用于下载完成后的静默刷新（不闪 loading）。
  Future<void> _search({bool quiet = false}) async {
    final String q = _searchCtrl.text.trim();
    final String query = q.isEmpty ? _defaultQuery : q;
    final BackendClient backend = context.read<BackendClient>();
    if (!quiet) setState(() => _loading = true);

    final List<_ModelItem> online = <_ModelItem>[];
    final List<_ModelItem> local = <_ModelItem>[];
    String error = '';
    String note = '';
    String localError = '';

    // ---- 1. 在线真实搜索：model_store ms_search ----
    try {
      final env = await backend.sendControl('model_store', <String, dynamic>{
        'action': 'ms_search',
        'query': query,
      });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        if (p['models'] is List) {
          for (final dynamic m in p['models'] as List) {
            if (m is! Map) continue;
            final Map<String, dynamic> md = _asMap(m);
            final String path = (md['path'] ?? '').toString();
            if (path.isEmpty) continue;
            final String name = (md['name'] ?? path).toString();
            final String cn = (md['chinese_name'] ?? '').toString();
            final String owner = (md['owner'] ?? '').toString();
            final List<String> tasks = md['tasks'] is List
                ? (md['tasks'] as List)
                    .map((dynamic t) => t.toString())
                    .where((String s) => s.isNotEmpty)
                    .toList()
                : <String>[];
            final List<String> tags = md['tags'] is List
                ? (md['tags'] as List).map((dynamic t) => t.toString()).toList()
                : <String>[];
            final int? downloads =
                md['downloads'] is num ? (md['downloads'] as num).toInt() : null;
            online.add(_ModelItem(
              id: path,
              name: cn.isNotEmpty ? cn : name,
              desc: path,
              type: _classify(<String>[...tasks, ...tags, name, path].join(' ')),
              owner: owner.isEmpty ? '魔搭社区' : owner,
              downloadsText: downloads != null ? _fmtThousands(downloads) : '—',
              tasks: tasks,
              online: true,
            ));
          }
        }
        note = '在线结果来自 ${(p['source'] ?? 'modelscope.cn')} · '
            '本页 ${online.length} 个真实模型仓库';
      } else {
        error = '在线搜索失败：'
            '${p is Map ? p['error'] ?? '后端返回非预期结构' : '后端返回非预期结构'}';
      }
    } on Object catch (e) {
      error = '在线搜索失败：$e';
    }

    // ---- 2. 本地已下载区：model_store list → local_files 真实扫描 ----
    try {
      final env = await backend.sendControl('model_store', <String, dynamic>{
        'action': 'list',
        'query': '',
      });
      final dynamic p = env.payload;
      if (p is Map && p['local_files'] is List) {
        for (final dynamic f in p['local_files'] as List) {
          if (f is! Map) continue;
          final Map<String, dynamic> fd = _asMap(f);
          final String fname = (fd['name'] ?? '').toString();
          if (fname.isEmpty) continue;
          final int bytes = fd['size'] is num ? (fd['size'] as num).toInt() : 0;
          local.add(_ModelItem(
            id: 'file:$fname',
            name: fname,
            desc: '本地已下载权重文件',
            type: _classify(fname),
            owner: '本地',
            sizeText: bytes > 0 ? _fmtBytes(bytes) : '—',
            downloaded: true,
          ));
        }
      } else {
        localError = '本地文件扫描失败：'
            '${p is Map ? p['error'] ?? '后端返回非预期结构' : '后端返回非预期结构'}';
      }
    } on Object catch (e) {
      localError = '本地文件扫描失败：$e';
    }

    if (!mounted) return;
    setState(() {
      _online = online;
      _local = local;
      _error = error;
      _localError = localError;
      _note = note;
      _loading = false;
    });
  }

  /// 按 ms_search 真实返回的 tasks / tags（其次名称/路径关键词）归类任务类型；
  /// 识别不了归「其他」。
  static String _classify(String raw) {
    final String s = raw.toLowerCase();
    if (s.contains('文生图') ||
        s.contains('图像生成') ||
        s.contains('text-to-image') ||
        s.contains('image-generation') ||
        s.contains('diffusion') ||
        s.contains('stable-diffusion')) return '文生图';
    if (s.contains('语音合成') ||
        s.contains('语音') ||
        s.contains('tts') ||
        s.contains('speech-synthesis') ||
        s.contains('cosyvoice') ||
        s.contains('voice-clone')) return '语音合成';
    if (s.contains('视觉') ||
        s.contains('多模态') ||
        s.contains('图文') ||
        s.contains('vision') ||
        s.contains('multimodal') ||
        s.contains('visual') ||
        s.contains('image-caption')) return '视觉多模态';
    if (s.contains('文本生成') ||
        s.contains('text-generation') ||
        s.contains('instruct') ||
        s.contains('chat') ||
        s.contains('llm') ||
        s.contains('nlp')) return '文本生成';
    return '其他';
  }

  /// 点击在线条目 → 底部弹层列出该仓库真实 GGUF 文件并可逐个下载。
  void _openFilesSheet(_ModelItem item) {
    final BackendClient backend = context.read<BackendClient>();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Tga.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext ctx) => _MsFilesSheet(
        backend: backend,
        item: item,
        onDownloaded: () => _search(quiet: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<_ModelItem> online = _cat == '全部'
        ? _online
        : _online.where((_ModelItem i) => i.type == _cat).toList();
    final List<_ModelItem> local = _cat == '全部'
        ? _local
        : _local.where((_ModelItem i) => i.type == _cat).toList();
    final bool allEmpty = online.isEmpty && local.isEmpty;

    final String caption = <String>[
      if (_error.isNotEmpty) _error,
      if (_localError.isNotEmpty) _localError,
      if (_note.isNotEmpty) _note,
    ].join('；');

    return TgaPage(
      title: '模型商店',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 0),
            child: TgaSearchField(
              hint: '搜索魔搭模型，例如 qwen',
              controller: _searchCtrl,
              onChanged: _onQueryChanged,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Tga.pagePad, 8, Tga.pagePad, 0),
            child: Text(
              caption.isNotEmpty
                  ? caption
                  : '魔搭真实模型 · 点击条目选择 GGUF 权重下载',
              style: Tga.caption,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Tga.pagePad, 12, 0, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TgaSegmented<String>(
                    items: _cats,
                    value: _cat,
                    labelOf: (String s) => s,
                    onChanged: (String v) => setState(() => _cat = v),
                  ),
                ),
                if (_loading)
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Tga.primary),
                  ),
                const SizedBox(width: Tga.pagePad),
              ],
            ),
          ),
          Expanded(
            child: allEmpty
                ? (_loading
                    ? TgaEmpty('正在加载…', icon: Icons.storefront_outlined)
                    : _error.isNotEmpty
                        ? _errorArea()
                        : TgaEmpty(_cat == '全部' ? '没有找到相关模型' : '该分类暂无模型',
                            icon: Icons.storefront_outlined))
                : ListView(
                    padding:
                        const EdgeInsets.fromLTRB(Tga.pagePad, 0, Tga.pagePad, 24),
                    children: <Widget>[
                      if (online.isNotEmpty) _sectionTitle('在线模型 · 魔搭社区'),
                      for (final _ModelItem it in online)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _StoreCard(
                            item: it,
                            onTap: () => _openFilesSheet(it),
                          ),
                        ),
                      if (local.isNotEmpty) _sectionTitle('本地已下载'),
                      for (final _ModelItem it in local)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _StoreCard(item: it, onTap: () {}),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// 搜索失败：如实显示错误 + 重试按钮，不放假数据。
  Widget _errorArea() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.wifi_off_rounded, size: 34, color: Tga.textDim),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(_error,
                style: Tga.sub,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 12),
          TgaButton(
              label: '重试',
              onTap: () => _search(),
              icon: Icons.refresh_rounded,
              filled: false),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 2, 0, 8),
        child: Text(t, style: Tga.sub),
      );
}

/// 在线 / 本地模型条目（字段全部来自后端真实返回，缺失显示「—」）。
class _ModelItem {
  _ModelItem({
    required this.id,
    required this.name,
    required this.desc,
    required this.type,
    required this.owner,
    this.tasks = const <String>[],
    this.downloadsText = '',
    this.sizeText = '',
    this.downloaded = false,
    this.online = false,
  });
  final String id, name, desc, type, owner;
  final List<String> tasks;
  final String downloadsText, sizeText;
  final bool downloaded, online;

  Color get color {
    switch (type) {
      case '文生图':
        return Tga.purple;
      case '视觉多模态':
        return Tga.cyan;
      case '语音合成':
        return Tga.gold;
      case '文本生成':
        return Tga.primary;
      default:
        return Tga.textSub;
    }
  }
}

class _StoreCard extends StatelessWidget {
  const _StoreCard({required this.item, required this.onTap});
  final _ModelItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TgaCard(
      padding: const EdgeInsets.all(14),
      onTap: item.online ? onTap : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: item.color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.auto_awesome_outlined,
                    size: 20, color: item.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(item.name,
                        style: Tga.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    if (item.desc.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(item.desc,
                          style: Tga.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        TgaTag(item.type, color: item.color),
                        for (final String t in item.tasks.take(3))
                          TgaTag(t, color: Tga.textSub),
                        if (item.online) TgaTag('魔搭在线', color: Tga.textSub),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _trailing(),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Icon(Icons.person_outline_rounded,
                  size: 13, color: Tga.textDim),
              const SizedBox(width: 5),
              Expanded(
                child: Text(item.owner,
                    style: Tga.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (item.online) ...<Widget>[
                Icon(Icons.download_outlined, size: 13, color: Tga.textDim),
                const SizedBox(width: 5),
                Text('${item.downloadsText} 次下载', style: Tga.sub),
              ] else ...<Widget>[
                Icon(Icons.data_usage_outlined, size: 13, color: Tga.textDim),
                const SizedBox(width: 5),
                Text(item.sizeText, style: Tga.sub),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 右侧操作区：在线条目提示点击进入 GGUF 文件弹层；本地条目如实标记已下载。
  Widget _trailing() {
    if (item.online) {
      return Row(
        children: <Widget>[
          Text('GGUF 文件', style: Tga.caption),
          Icon(Icons.chevron_right_rounded, size: 18, color: Tga.textDim),
        ],
      );
    }
    if (item.downloaded) return TgaTag('已下载', color: Tga.green);
    return const SizedBox.shrink();
  }
}

/// GGUF 文件条目（ms_files 真实返回，按大小升序）。
class _MsFile {
  _MsFile({required this.path, required this.name, required this.size});
  final String path, name;
  final int size;
}

/// 弹层内单个文件的真实下载进度（字节来自后端落盘统计，不编造）。
class _FileJob {
  _FileJob({required this.jobId, required this.fileName});
  final String jobId, fileName;
  double percent = 0;
  int downloaded = 0, total = 0;
  String status = 'running';
  String error = '';
}

/// 底部弹层：ms_files 列出真实 GGUF 文件，逐个 ms_download 真实下载，
/// 行内显示真实进度（轮询 download_status），完成 toast + 刷新本地列表。
class _MsFilesSheet extends StatefulWidget {
  const _MsFilesSheet({
    required this.backend,
    required this.item,
    required this.onDownloaded,
  });
  final BackendClient backend;
  final _ModelItem item;
  final VoidCallback onDownloaded;

  @override
  State<_MsFilesSheet> createState() => _MsFilesSheetState();
}

class _MsFilesSheetState extends State<_MsFilesSheet> {
  final List<_MsFile> _files = <_MsFile>[];
  final Map<String, _FileJob> _jobs = <String, _FileJob>{};
  bool _loading = true;
  String _error = '';
  Timer? _timer;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _loadFiles() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final env = await widget.backend.sendControl('model_store',
          <String, dynamic>{'action': 'ms_files', 'model_path': widget.item.id});
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        final List<_MsFile> files = <_MsFile>[];
        if (p['files'] is List) {
          for (final dynamic f in p['files'] as List) {
            if (f is! Map) continue;
            final Map<String, dynamic> fd = _asMap(f);
            final String path = (fd['path'] ?? '').toString();
            if (path.isEmpty) continue;
            files.add(_MsFile(
              path: path,
              name: (fd['name'] ?? path.split('/').last).toString(),
              size: fd['size'] is num ? (fd['size'] as num).toInt() : 0,
            ));
          }
        }
        if (!mounted) return;
        setState(() {
          _files
            ..clear()
            ..addAll(files);
          _loading = false;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _error = '读取文件列表失败：'
              '${p is Map ? p['error'] ?? '后端返回非预期结构' : '后端返回非预期结构'}';
          _loading = false;
        });
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读取文件列表失败：$e';
        _loading = false;
      });
    }
  }

  /// 发起真实下载（ms_download → 后端 Range 分片 + 断点续传）。
  Future<void> _startDownload(_MsFile f) async {
    try {
      final env = await widget.backend.sendControl('model_store',
          <String, dynamic>{
        'action': 'ms_download',
        'model_path': widget.item.id,
        'file': f.path,
      });
      final dynamic p = env.payload;
      if (p is Map && p['ok'] == true) {
        setState(() {
          _jobs[f.path] = _FileJob(
            jobId: (p['job_id'] ?? '').toString(),
            fileName: f.name,
          );
        });
        _ensureTimer();
      } else {
        _toast('下载未启动：'
            '${p is Map ? p['error'] ?? '未知原因' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      _toast('下载请求失败：$e');
    }
  }

  void _ensureTimer() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(milliseconds: 900), (_) => _poll());
  }

  /// 轮询 download_status 取真实落盘字节进度；完成/失败如实呈现。
  Future<void> _poll() async {
    if (_polling) return;
    final List<MapEntry<String, _FileJob>> running = _jobs.entries
        .where((MapEntry<String, _FileJob> e) => e.value.status == 'running')
        .toList();
    if (running.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _polling = true;
    bool finished = false;
    try {
      for (final MapEntry<String, _FileJob> e in running) {
        try {
          final env = await widget.backend.sendControl('model_store',
              <String, dynamic>{
                'action': 'download_status',
                'job_id': e.value.jobId,
              });
          final dynamic p = env.payload;
          if (p is Map && p['job'] is Map) {
            final Map<String, dynamic> job = _asMap(p['job'] as Map);
            e.value.percent =
                job['percent'] is num ? (job['percent'] as num).toDouble() : 0;
            e.value.downloaded =
                job['downloaded'] is num ? (job['downloaded'] as num).toInt() : 0;
            e.value.total = job['total'] is num ? (job['total'] as num).toInt() : 0;
            final String status = (job['status'] ?? '').toString();
            if (status == 'done') {
              e.value.status = 'done';
              finished = true;
              _toast('「${e.value.fileName}」已下载,可在训练设置-本地基底模型选用');
            } else if (status == 'failed' || status == 'cancelled') {
              e.value.status = status;
              e.value.error = (job['error'] ?? '').toString();
            }
          } else {
            // 任务不存在等：如实把原因留在该行。
            e.value.status = 'failed';
            e.value.error =
                '${p is Map ? p['error'] ?? '后端返回非预期结构' : '后端返回非预期结构'}';
          }
        } on Object catch (err) {
          e.value.status = 'failed';
          e.value.error = '进度查询异常：$err';
        }
      }
    } finally {
      _polling = false;
    }
    if (!mounted) return;
    setState(() {});
    if (_jobs.values.every((_FileJob j) => j.status != 'running')) {
      _timer?.cancel();
      _timer = null;
    }
    // 有文件下载完成 → 通知页面静默刷新，本地已下载区真实呈现。
    if (finished) widget.onDownloaded();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.65,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(widget.item.name,
                            style: Tga.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Text(widget.item.desc,
                            style: Tga.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close_rounded, color: Tga.textSub),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Tga.primary),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Text(_error,
                  style: Tga.sub,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(height: 12),
            TgaButton(
                label: '重试',
                onTap: _loadFiles,
                icon: Icons.refresh_rounded,
                filled: false),
          ],
        ),
      );
    }
    if (_files.isEmpty) {
      return Center(
        child: Text('该仓库没有可直接下载的 GGUF 文件', style: Tga.sub),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: _files.length,
      itemBuilder: (BuildContext context, int i) => _fileRow(_files[i]),
    );
  }

  Widget _fileRow(_MsFile f) {
    final _FileJob? job = _jobs[f.path];
    final bool running = job != null && job.status == 'running';
    final bool failed =
        job != null && (job.status == 'failed' || job.status == 'cancelled');
    final bool done = job != null && job.status == 'done';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(f.name,
                    style: Tga.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                if (running) ...<Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                        value: (job.percent / 100).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: Tga.divider),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${job.percent.toStringAsFixed(1)}% · '
                    '${_fmtShort(job.downloaded)}'
                    '${job.total > 0 ? ' / ${_fmtShort(job.total)}' : ''}',
                    style: Tga.caption,
                  ),
                ] else ...<Widget>[
                  Text(_fmtBytes(f.size), style: Tga.caption),
                  if (failed)
                    Text(
                        '${job.status == 'cancelled' ? '下载已取消' : '下载失败'}'
                        '${job.error.isEmpty ? '' : '：${job.error}'}',
                        style: Tga.caption.copyWith(color: Tga.red)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (running)
            TgaTag('下载中', color: Tga.primary)
          else if (done)
            TgaTag('已下载', color: Tga.green)
          else
            TgaButton(
                label: failed ? '重试' : '下载',
                onTap: () => _startDownload(f),
                icon: Icons.download_rounded,
                filled: false),
        ],
      ),
    );
  }
}

Map<String, dynamic> _asMap(Map<dynamic, dynamic> m) =>
    m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));

/// 人类可读字节大小。
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

/// 进度行短格式（与页面原进度样式一致）。
String _fmtShort(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}G';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
  return '${bytes}B';
}

/// 下载量千分位（真实数值，不缩写不编造）。
String _fmtThousands(int n) {
  final String s = n.toString();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
