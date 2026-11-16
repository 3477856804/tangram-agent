import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/store.dart';
import '../../harness/video_studio.dart';

/// AI 视频剪辑工作室：素材路径 → 真实 ffmpeg / video_edit.py 命令 → 执行。
///
/// 页面只调用 [VideoStudio]：生成可执行命令、展示依赖检查、真实执行并把
/// stdout JSON / 退出码 / 错误原样展示；任务历史落盘可删。预览时可注入
/// 空 shell 回调，缺依赖 / 失败都会如实显示。
class TgaVideoStudioPage extends StatefulWidget {
  const TgaVideoStudioPage({super.key, this.studio, this.shell});

  /// 构造时可注入服务或 shell；预览默认回调如实返回未接入。
  final VideoStudio? studio;
  final VideoShell? shell;

  @override
  State<TgaVideoStudioPage> createState() => _TgaVideoStudioPageState();
}

class _TgaVideoStudioPageState extends State<TgaVideoStudioPage> {
  final TextEditingController _assets = TextEditingController();
  final TextEditingController _output = TextEditingController();
  final TextEditingController _subtitles = TextEditingController();
  final TextEditingController _music = TextEditingController();
  final TextEditingController _width = TextEditingController(text: '1280');
  final TextEditingController _height = TextEditingController(text: '720');
  final TextEditingController _fps = TextEditingController(text: '30');

  VideoStudio? _studio;
  List<Map<String, dynamic>> _jobs = <Map<String, dynamic>>[];
  Map<String, dynamic>? _built;
  Map<String, dynamic>? _lastRun;
  bool _loading = true;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _assets.dispose();
    _output.dispose();
    _subtitles.dispose();
    _music.dispose();
    _width.dispose();
    _height.dispose();
    _fps.dispose();
    super.dispose();
  }

  static Future<Map<String, dynamic>> _previewShell(
      String command, String cwd) async {
    return <String, dynamic>{
      'ok': false,
      'exit_code': 1,
      'stdout': '',
      'stderr': '未接入沙箱 shell（请在宿主注入真实 shell 回调）',
    };
  }

  VideoShell _shellFromBackend() {
    final BackendClient backend = context.read<BackendClient>();
    if (backend.embeddedBackend == null) return _previewShell;
    return (String command, String cwd) => backend
        .sendControl('code_task', <String, dynamic>{
          'action': 'shell',
          'command': command,
          'cwd': cwd,
        })
        .then((dynamic env) => env.payload is Map
            ? Map<String, dynamic>.from(env.payload as Map)
            : <String, dynamic>{'ok': false, 'exit_code': 1, 'error': '返回格式异常'});
  }

  Future<void> _init() async {
    try {
      final VideoStudio studio = widget.studio ??
          VideoStudio(
            await HarnessStore.instance(),
            shell: widget.shell ?? _shellFromBackend(),
          );
      final List<Map<String, dynamic>> jobs = await studio.listJobs();
      if (!mounted) return;
      setState(() {
        _studio = studio;
        _jobs = jobs;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '视频工作室读取失败：$e';
      });
    }
  }

  Future<void> _refreshJobs() async {
    final VideoStudio? studio = _studio;
    if (studio == null) return;
    final List<Map<String, dynamic>> jobs = await studio.listJobs();
    if (!mounted) return;
    setState(() => _jobs = jobs);
  }

  List<String> _assetList() => _assets.text
      .split('\n')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  int _intOr(TextEditingController c, int fallback) =>
      int.tryParse(c.text.trim()) ?? fallback;

  Map<String, dynamic>? _build() {
    final VideoStudio? studio = _studio;
    if (studio == null) return null;
    final Map<String, dynamic> built = studio.buildAutoEditCommand(
      _assetList(),
      _output.text,
      subtitles: _subtitles.text,
      music: _music.text,
      width: _intOr(_width, 1280),
      height: _intOr(_height, 720),
      fps: _intOr(_fps, 30),
    );
    if (!mounted) return built;
    setState(() => _built = built);
    return built;
  }

  Future<void> _generate() async {
    final Map<String, dynamic>? built = _build();
    if (built == null) return;
    _toast(built['ok'] == true ? '命令已生成' : (built['error'] ?? '生成失败').toString());
  }

  Future<void> _run() async {
    final VideoStudio? studio = _studio;
    if (studio == null || _busy) return;
    final Map<String, dynamic> built = _build() ?? <String, dynamic>{};
    if (built['ok'] != true) {
      _toast((built['error'] ?? '命令参数无效').toString());
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final Map<String, dynamic> r = await studio.runJob(
      assets: _assetList(),
      output: _output.text,
      subtitles: _subtitles.text,
      music: _music.text,
      width: _intOr(_width, 1280),
      height: _intOr(_height, 720),
      fps: _intOr(_fps, 30),
      cwd: '.',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastRun = r;
      if (r['ok'] != true) _error = (r['error'] ?? '执行失败').toString();
    });
    _toast(r['ok'] == true ? '剪辑完成' : (r['error'] ?? '执行失败').toString());
    await _refreshJobs();
  }

  Future<void> _deleteJob(Map<String, dynamic> job) async {
    final VideoStudio? studio = _studio;
    if (studio == null) return;
    final Map<String, dynamic> r =
        await studio.deleteJob(job['id'] ?? '');
    if (!mounted) return;
    _toast(r['ok'] == true ? '已删除任务记录' : (r['error'] ?? '删除失败').toString());
    await _refreshJobs();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  Map<String, dynamic> _info(Map<String, dynamic>? run) {
    if (run == null) return <String, dynamic>{};
    final dynamic result = run['result'];
    if (result is Map && result['info'] is Map) {
      return Map<String, dynamic>.from(result['info'] as Map);
    }
    return <String, dynamic>{};
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '视频工作室',
      actions: <Widget>[
        IconButton(
          tooltip: '依赖检查命令',
          onPressed: _built == null
              ? null
              : () => _toast((_built?['dependency_check'] ?? '').toString()),
          icon: Icon(Icons.rule_rounded, color: Tga.primary),
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
              padding:
                  const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                if (_error.isNotEmpty)
                  TgaCard(
                    child:
                        Text(_error, style: Tga.sub.copyWith(color: Tga.red)),
                  ),
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('素材路径（每行一个）', style: Tga.h2),
                      const SizedBox(height: 4),
                      TextField(
                        controller: _assets,
                        minLines: 4,
                        maxLines: 10,
                        style: TextStyle(color: Tga.text),
                        decoration: const InputDecoration(
                          hintText: 'sandbox/video/a.mp4\nsandbox/video/b.mp4',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _output,
                        style: TextStyle(color: Tga.text),
                        decoration: const InputDecoration(
                            hintText: '输出路径，如 sandbox/video/final.mp4'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _subtitles,
                        style: TextStyle(color: Tga.text),
                        decoration: const InputDecoration(
                            hintText: 'SRT 字幕路径（可选）'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _music,
                        style: TextStyle(color: Tga.text),
                        decoration: const InputDecoration(
                            hintText: '背景音乐路径（可选）'),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _width,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: Tga.text),
                              decoration:
                                  const InputDecoration(labelText: '宽'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _height,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: Tga.text),
                              decoration:
                                  const InputDecoration(labelText: '高'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _fps,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: Tga.text),
                              decoration:
                                  const InputDecoration(labelText: '帧率'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          TgaButton(
                            label: '生成命令',
                            filled: false,
                            icon: Icons.terminal_rounded,
                            onTap: _busy ? () {} : _generate,
                          ),
                          const SizedBox(width: 8),
                          TgaButton(
                            label: _busy ? '执行中…' : '执行剪辑',
                            icon: Icons.movie_filter_outlined,
                            onTap: _busy ? () {} : _run,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (_built != null) ...<Widget>[
                  const TgaGroupTitle('命令与依赖'),
                  TgaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SelectableText(
                          (_built?['command'] ?? '').toString(),
                          style: Tga.caption.copyWith(fontFamily: 'monospace'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '依赖检查：${_built?['dependency_check'] ?? ''}',
                          style: Tga.caption,
                        ),
                        if ((_built?['import_check'] ?? '').toString().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '模块检查：${_built?['import_check']}',
                              style: Tga.caption,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                if (_lastRun != null) ...<Widget>[
                  const TgaGroupTitle('最近一次执行'),
                  TgaCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(
                              _lastRun!['ok'] == true
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.error_outline_rounded,
                              size: 16,
                              color: _lastRun!['ok'] == true
                                  ? Tga.green
                                  : Tga.red,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _lastRun!['ok'] == true ? '已完成（真实输出）' : '失败（如实记录）',
                              style: Tga.h2,
                            ),
                            const Spacer(),
                            TgaTag(
                              (_lastRun!['job'] is Map
                                  ? ((_lastRun!['job'] as Map)['status'] ?? '')
                                  : '')
                                  .toString(),
                              color: _lastRun!['ok'] == true
                                  ? Tga.green
                                  : Tga.red,
                            ),
                          ],
                        ),
                        if ((_lastRun!['error'] ?? '').toString().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              _lastRun!['error'].toString(),
                              style: Tga.sub.copyWith(color: Tga.red),
                            ),
                          ),
                        if (_info(_lastRun)['duration'] != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '时长 ${_info(_lastRun)['duration']}s · '
                              '${_info(_lastRun)['width']}×${_info(_lastRun)['height']} · '
                              '${_info(_lastRun)['video_codec'] ?? ''}',
                              style: Tga.caption,
                            ),
                          ),
                        if ((_lastRun!['result'] is Map) &&
                            (_lastRun!['result'] as Map)['output'] != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '输出：${(_lastRun!['result'] as Map)['output']}',
                              style: Tga.caption,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                TgaGroupTitle('任务历史（${_jobs.length}）'),
                if (_jobs.isEmpty)
                  TgaCard(
                    child: TgaEmpty('还没有执行记录\n生成命令并真实执行后会落盘',
                        icon: Icons.video_library_outlined),
                  )
                else
                  for (final Map<String, dynamic> job in _jobs)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Text(
                                    (job['output'] ?? '未命名输出').toString(),
                                    style: Tga.h2,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                TgaTag(
                                  (job['status'] ?? '').toString(),
                                  color: job['status'] == 'done'
                                      ? Tga.green
                                      : Tga.red,
                                ),
                                IconButton(
                                  tooltip: '删除记录',
                                  onPressed: () => _deleteJob(job),
                                  icon: Icon(Icons.delete_outline_rounded,
                                      size: 18, color: Tga.red),
                                ),
                              ],
                            ),
                            Text(
                              '${(job['assets'] is List) ? (job['assets'] as List).length : 0} 个素材'
                              ' · ${job['width']}×${job['height']}@${job['fps']}'
                              ' · exit ${job['exit_code']}',
                              style: Tga.caption,
                            ),
                            Text(
                              '${(job['started_at'] ?? '').toString().replaceFirst('T', ' ').split('.').first}'
                              '${(job['error'] ?? '').toString().isEmpty ? '' : ' · ${job['error']}'}',
                              style: Tga.caption.copyWith(
                                color: (job['error'] ?? '').toString().isEmpty
                                    ? Tga.textDim
                                    : Tga.red,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
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
