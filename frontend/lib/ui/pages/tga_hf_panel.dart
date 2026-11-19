import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/store.dart';
import '../../services/model_registry.dart';

/// 抱脸（HuggingFace）模型面板：
/// - 直接搜索模型名，或粘贴 huggingface.co / hf-mirror.com 链接；
/// - 列出仓库里真实的 .gguf 文件与大小；
/// - 真实 Range 分片下载，进度按落盘字节回写；
/// - 下载完成后直接「运行」，把本地权重设为当前模型并回到对话页。
class TgaHfPanel extends StatefulWidget {
  const TgaHfPanel({super.key, required this.onDownloaded});

  final VoidCallback onDownloaded;

  @override
  State<TgaHfPanel> createState() => _TgaHfPanelState();
}

class _TgaHfPanelState extends State<TgaHfPanel> {
  static const String _recentsFile = 'hf_recents.json';
  final TextEditingController _ctrl = TextEditingController();
  final List<String> _recents = <String>[];
  List<Map<String, dynamic>> _models = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _files = <Map<String, dynamic>>[];
  final Map<String, _HfJob> _jobs = <String, _HfJob>{};
  String _repo = '';
  String _error = '';
  String _note = '';
  bool _loading = false;
  bool _loadingFiles = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _loadRecents();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _loadRecents() async {
    try {
      final store = await HarnessStore.instance();
      final raw = await store.readJson(_recentsFile);
      final list = raw['items'];
      if (list is List && mounted) {
        setState(() {
          _recents
            ..clear()
            ..addAll(list.map((e) => e.toString()).where((e) => e.isNotEmpty));
        });
      }
    } on Object {
      // 本地记录读取失败不影响搜索。
    }
  }

  Future<void> _remember(String q) async {
    final s = q.trim();
    if (s.isEmpty) return;
    setState(() {
      _recents.remove(s);
      _recents.insert(0, s);
      if (_recents.length > 8) _recents.removeLast();
    });
    try {
      final store = await HarnessStore.instance();
      await store.writeJson(_recentsFile, <String, dynamic>{'items': _recents});
    } on Object {
      // 写失败只影响下次启动的记录，不阻断搜索。
    }
  }

  Future<void> _search([String? text]) async {
    final q = (text ?? _ctrl.text).trim();
    if (q.isEmpty) return;
    if (text != null) _ctrl.text = text;
    _poll?.cancel();
    setState(() {
      _loading = true;
      _error = '';
      _note = '';
      _models = <Map<String, dynamic>>[];
      _files = <Map<String, dynamic>>[];
      _repo = '';
    });
    await _remember(q);
    if (!mounted) return;
    try {
      final env = await context
          .read<BackendClient>()
          .sendControl('model_store', <String, dynamic>{
        'action': 'hf_search',
        'query': q,
      });
      final p = env.payload;
      if (!mounted) return;
      if (p is Map && p['ok'] == true && p['models'] is List) {
        final models = (p['models'] as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        setState(() {
          _models = models;
          _note = '结果来自 ${(p['source'] ?? 'huggingface.co')} · '
              '共 ${models.length} 个仓库';
        });
        // 粘贴的链接只有一条结果，直接展开文件列表。
        if (models.length == 1) {
          await _openRepo(models.first);
        }
      } else {
        setState(() => _error =
            '搜索失败：${p is Map ? p['error'] ?? '后端返回非预期结构' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '搜索失败：$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openRepo(Map<String, dynamic> m) async {
    final repo = (m['id'] ?? m['repo'] ?? '').toString();
    if (repo.isEmpty) return;
    setState(() {
      _repo = repo;
      _loadingFiles = true;
      _error = '';
      _files = <Map<String, dynamic>>[];
    });
    try {
      final env = await context
          .read<BackendClient>()
          .sendControl('model_store', <String, dynamic>{
        'action': 'hf_files',
        'repo': repo,
      });
      final p = env.payload;
      if (!mounted) return;
      if (p is Map && p['ok'] == true && p['files'] is List) {
        setState(() {
          _files = (p['files'] as List)
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
          _note = (p['note'] ?? '').toString();
        });
      } else {
        setState(() => _error =
            '读取文件失败：${p is Map ? p['error'] ?? '后端返回非预期结构' : '后端返回非预期结构'}');
      }
    } on Object catch (e) {
      if (mounted) setState(() => _error = '读取文件失败：$e');
    } finally {
      if (mounted) setState(() => _loadingFiles = false);
    }
  }

  Future<void> _download(Map<String, dynamic> f) async {
    final file = (f['path'] ?? f['name'] ?? '').toString();
    if (_repo.isEmpty || file.isEmpty) return;
    try {
      final env = await context
          .read<BackendClient>()
          .sendControl('model_store', <String, dynamic>{
        'action': 'hf_download',
        'repo': _repo,
        'file': file,
        'size': f['size'] ?? 0,
      });
      final p = env.payload;
      if (p is Map && p['job_id'] != null) {
        setState(() {
          _jobs[file] = _HfJob(
            id: p['job_id'].toString(),
            target: (p['target'] ?? '').toString(),
            status: (p['status'] ?? 'running').toString(),
            error: (p['error'] ?? '').toString(),
          );
        });
        _startPolling();
      } else {
        setState(() => _error =
            '下载启动失败：${p is Map ? p['error'] ?? '后端未返回任务' : '后端未返回任务'}');
      }
    } on Object catch (e) {
      setState(() => _error = '下载启动失败：$e');
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 900), (Timer t) async {
      final running = _jobs.entries
          .where((MapEntry<String, _HfJob> e) => e.value.status == 'running')
          .toList();
      if (running.isEmpty) {
        t.cancel();
        return;
      }
      for (final e in running) {
        try {
          final env = await context
              .read<BackendClient>()
              .sendControl('model_store', <String, dynamic>{
            'action': 'download_status',
            'job_id': e.value.id,
          });
          final p = env.payload;
          final job = p is Map ? p['job'] : null;
          if (job is Map && mounted) {
            final status = (job['status'] ?? '').toString();
            setState(() {
              e.value
                ..status = status
                ..received =
                    job['received'] is num ? (job['received'] as num).toInt() : 0
                ..total = job['total'] is num ? (job['total'] as num).toInt() : 0
                ..error = (job['error'] ?? '').toString();
            });
            if (status == 'done') widget.onDownloaded();
          }
        } on Object {
          // 单次轮询失败继续，不中断其它任务。
        }
      }
    });
  }

  Future<void> _run(_HfJob job) async {
    try {
      final ModelRegistry registry = context.read<ModelRegistry>();
      await registry.refresh();
      ModelEntry? match;
      for (final e in registry.localEntries) {
        if (e.path == job.target) {
          match = e;
          break;
        }
      }
      if (match == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('权重还没合并完成，请等下载结束后再点运行'),
          ));
        }
        return;
      }
      await registry.setSelected(match.id);
      if (!mounted) return;
      Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('启动失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Tga.pagePad, 0, Tga.pagePad, 24),
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TgaSearchField(
                hint: '搜索模型名，或粘贴 HuggingFace 模型链接…',
                controller: _ctrl,
                onChanged: (_) {},
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _loading ? null : () => _search(),
              child: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('搜索'),
            ),
          ],
        ),
        if (_recents.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text('保存的信息', style: Tga.caption),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _recents
                .map((String q) => ActionChip(
                      label: Text(q, maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      onPressed: () => _search(q),
                    ))
                .toList(),
          ),
        ],
        if (_error.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(_error, style: Tga.caption.copyWith(color: Tga.iconRed)),
        ],
        if (_note.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          Text(_note, style: Tga.caption),
        ],
        if (_models.isNotEmpty && _repo.isEmpty) ...<Widget>[
          const SizedBox(height: 12),
          for (final Map<String, dynamic> m in _models)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Card(
                color: Tga.card,
                child: ListTile(
                  title: Text((m['id'] ?? '').toString(), style: Tga.body),
                  subtitle: Text(
                    '${(m['downloads'] ?? 0)} 次下载 · '
                    '${(m['pipeline_tag'] ?? '').toString().isEmpty ? '仓库' : m['pipeline_tag']}',
                    style: Tga.caption,
                  ),
                  trailing: Icon(Icons.chevron_right_rounded,
                      color: Tga.textDim),
                  onTap: () => _openRepo(m),
                ),
              ),
            ),
        ],
        if (_repo.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              IconButton(
                onPressed: () => setState(() {
                  _repo = '';
                  _files = <Map<String, dynamic>>[];
                }),
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
              ),
              Expanded(
                child: Text(_repo,
                    style: Tga.body, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          if (_loadingFiles)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_files.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                _note.isEmpty ? '该仓库没有可直接下载的 GGUF 文件' : _note,
                style: Tga.sub,
              ),
            )
          else
            for (final Map<String, dynamic> f in _files)
              _fileRow(f),
        ],
      ],
    );
  }

  Widget _fileRow(Map<String, dynamic> f) {
    final file = (f['path'] ?? '').toString();
    final job = _jobs[file];
    final int size = f['size'] is num ? (f['size'] as num).toInt() : 0;
    final bool running = job?.status == 'running';
    final bool done = job?.status == 'done';
    final double value = job != null && job.total > 0
        ? (job.received / job.total).clamp(0.0, 1.0)
        : 0;
    return Card(
      color: Tga.card,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(file.split('/').last,
                      style: Tga.body, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Text(_fmtBytes(size), style: Tga.caption),
              ],
            ),
            if (running) ...<Widget>[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: value),
              const SizedBox(height: 4),
              Text(
                '${_fmtBytes(job!.received)} / ${_fmtBytes(job.total)} · '
                '${(value * 100).toStringAsFixed(1)}%',
                style: Tga.caption,
              ),
            ],
            if (job?.error.isNotEmpty == true)
              Text(job!.error, style: Tga.caption.copyWith(color: Tga.iconRed)),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (done)
                  FilledButton.icon(
                    onPressed: () => _run(job!),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('运行'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: running ? null : () => _download(f),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(running ? '下载中' : '下载'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _fmtBytes(int n) {
    if (n <= 0) return '—';
    const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    double v = n.toDouble();
    int i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }
}

class _HfJob {
  _HfJob({
    required this.id,
    required this.target,
    required this.status,
    this.error = '',
  });

  final String id;
  final String target;
  String status;
  String error;
  int received = 0;
  int total = 0;
}
