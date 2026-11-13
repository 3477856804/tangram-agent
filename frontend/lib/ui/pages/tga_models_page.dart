import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';
import 'tga_training_page.dart';

/// 蒸馏模型管理（真实化改造）：
/// - 列表数据源为 distill {action:'models'} 的 own_models
///   （真实蒸馏/本地 GGUF 权重，含 name/path/size），空态引导去训练设置。
/// - 每张卡：名称/大小/路径；操作：
///   * 详情：distill describe 的 harness 统计 + 文件大小/修改时间（真实 stat）
///   * 重命名：distill rename_model 真实改文件名
///   * 删除：distill delete_model 真实删权重文件
///   * 切割：compute isolate 里按字节把权重切成 N 卷（默认 4），
///     产出 xxx.gguf.part1..N；原文件保留，可另行删除
///   * 跑分：内置 5 道中文评测题经 chat RPC 对该权重真实推理，
///     按关键词命中率计分；推理失败如实显示失败，不编造分数。
class TgaModelsPage extends StatefulWidget {
  const TgaModelsPage({super.key});

  @override
  State<TgaModelsPage> createState() => _TgaModelsPageState();
}

/// 一道评测题：问题 + 判分关键词（回复命中任意一个即算该题得分）。
class _BenchQuestion {
  const _BenchQuestion(this.question, this.keywords);
  final String question;
  final List<String> keywords;
}

const List<_BenchQuestion> _kBenchQuestions = <_BenchQuestion>[
  _BenchQuestion('中国的首都是哪座城市？', <String>['北京']),
  _BenchQuestion('12 乘以 8 等于多少？请直接给出数字。', <String>['96']),
  _BenchQuestion('太阳系中距离太阳最近的行星是哪一颗？', <String>['水星']),
  _BenchQuestion('请用一句话说明“编程”是什么。', <String>['指令', '代码', '程序']),
  _BenchQuestion('“未雨绸缪”这个成语的意思是什么？', <String>['事先', '准备', '提前']),
];

class _TgaModelsPageState extends State<TgaModelsPage> {
  List<Map<String, dynamic>> _ownModels = <Map<String, dynamic>>[];
  bool _loading = true;
  String? _error;

  /// 正在跑分的模型名（跑分期间禁用其按钮并显示进度）。
  String? _benchRunning;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _toast(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Tga.red : null,
      duration: const Duration(seconds: 2),
    ));
  }

  /// 拉真实蒸馏/本地 GGUF 列表（distill models → own_models）。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'distill',
        <String, dynamic>{'action': 'models'},
      );
      final dynamic payload = env.payload;
      final dynamic data = payload is Map ? payload['data'] : null;
      if (payload is Map && payload['ok'] == true && data is Map) {
        final dynamic own = data['own_models'];
        _ownModels = own is List
            ? own
                .whereType<Map>()
                .map((Map<dynamic, dynamic> m) => m.map(
                      (dynamic k, dynamic v) => MapEntry(k.toString(), v),
                    ))
                .toList()
            : <Map<String, dynamic>>[];
      } else {
        _ownModels = <Map<String, dynamic>>[];
        _error = payload is Map
            ? (payload['error'] ?? '后端返回了非预期结构').toString()
            : '后端返回了非预期结构';
      }
    } on Object catch (e) {
      _ownModels = <Map<String, dynamic>>[];
      _error = '读取蒸馏模型列表失败：$e';
    }
    if (mounted) setState(() => _loading = false);
  }

  static String _nameOf(Map<String, dynamic> m) =>
      (m['name'] ?? '').toString();
  static String _pathOf(Map<String, dynamic> m) => (m['path'] ?? '').toString();
  static int _sizeOf(Map<String, dynamic> m) =>
      m['size'] is num ? (m['size'] as num).toInt() : 0;

  static String _sizeText(int bytes) {
    if (bytes <= 0) return '大小未知';
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }

  // ------------------------------------------------------------------
  // 详情：distill describe（harness 真实统计）+ 文件大小/修改时间
  // ------------------------------------------------------------------

  Future<void> _showDetail(Map<String, dynamic> m) async {
    final String path = _pathOf(m);
    String harnessText = 'harness 统计读取失败';
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'distill',
        <String, dynamic>{'action': 'describe'},
      );
      final dynamic payload = env.payload;
      final dynamic data = payload is Map ? payload['data'] : null;
      if (data is Map) {
        final dynamic harness = data['harness'];
        final List<String> lines = <String>[
          '版本：${data['version'] ?? '未知'}',
          '公式：${data['equation'] ?? 'agent = model + harness'}',
        ];
        if (harness is Map) {
          lines.add('工作轨迹：${harness['work_traces'] ?? 0} 条');
          lines.add('对话轮数：${harness['dialog_turns'] ?? 0}');
          lines.add('后端：${harness['backend'] ?? '未知'}');
          final dynamic tools = harness['tools'];
          if (tools is List && tools.isNotEmpty) {
            lines.add('工具：${tools.join(' · ')}');
          }
        }
        harnessText = lines.join('\n');
      }
    } on Object {
      // 保持失败文案，不编造统计。
    }
    // 文件大小/修改时间：对真实权重文件做磁盘 stat。
    final File f = File(path);
    String fileText = '权重文件不存在或不可读：$path';
    if (f.existsSync()) {
      final FileStat stat = f.statSync();
      fileText = '路径：$path\n'
          '大小：${_sizeText(stat.size)}（${stat.size} 字节）\n'
          '修改时间：${stat.modified.toString()}';
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(_nameOf(m)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('harness 统计', style: Tga.h2),
              const SizedBox(height: 6),
              Text(harnessText, style: Tga.sub),
              const SizedBox(height: 14),
              Text('权重文件', style: Tga.h2),
              const SizedBox(height: 6),
              Text(fileText, style: Tga.sub),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // 重命名：distill rename_model 真实改文件名
  // ------------------------------------------------------------------

  Future<void> _renameModel(Map<String, dynamic> m) async {
    final String oldName = _nameOf(m);
    final TextEditingController ctrl =
        TextEditingController(text: oldName.replaceAll(RegExp(r'\.gguf$'), ''));
    final String? input = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('重命名模型'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新名称（自动补 .gguf）'),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final String v = ctrl.text.trim();
              Navigator.of(ctx).pop(v.isEmpty ? null : v);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    final String? next = input;
    ctrl.dispose();
    if (next == null || !mounted) return;
    final String newName = next.toLowerCase().endsWith('.gguf') ? next : '$next.gguf';
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'distill',
        <String, dynamic>{
          'action': 'rename_model',
          'name': oldName,
          'new_name': newName,
        },
      );
      final dynamic payload = env.payload;
      if (payload is Map && payload['ok'] == true) {
        _toast('已重命名为 $newName');
        await _load();
      } else {
        _toast('重命名失败：${payload is Map ? payload['error'] : '后端返回异常'}',
            error: true);
      }
    } on Object catch (e) {
      _toast('重命名失败：$e', error: true);
    }
  }

  // ------------------------------------------------------------------
  // 删除：distill delete_model 真实删除权重
  // ------------------------------------------------------------------

  Future<void> _deleteModel(Map<String, dynamic> m) async {
    final String name = _nameOf(m);
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除蒸馏模型'),
        content: Text('确认删除「$name」？权重文件将从磁盘真实移除。'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('删除', style: TextStyle(color: Tga.red))),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
        'distill',
        <String, dynamic>{'action': 'delete_model', 'name': name},
      );
      final dynamic payload = env.payload;
      if (payload is Map && payload['ok'] == true) {
        _toast('已删除「$name」');
        await _load();
      } else {
        _toast('删除失败：${payload is Map ? payload['error'] : '后端返回异常'}',
            error: true);
      }
    } on Object catch (e) {
      _toast('删除失败：$e', error: true);
    }
  }

  // ------------------------------------------------------------------
  // 切割：把权重文件按字节切成 N 卷（compute isolate 真实读写字节）
  // ------------------------------------------------------------------

  Future<void> _splitModel(Map<String, dynamic> m) async {
    final TextEditingController partsCtrl = TextEditingController(text: '4');
    final int? parts = await showDialog<int>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('切割权重文件'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('把权重按字节切成 N 卷，产出 xxx.gguf.part1..N。\n'
                '切割后原文件保留（确认分卷无误后可在本页删除原文件）。',
                style: Tga.sub),
            const SizedBox(height: 12),
            TextField(
              controller: partsCtrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(labelText: '卷数（2~10）'),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final int? n = int.tryParse(partsCtrl.text.trim());
              Navigator.of(ctx).pop(n == null || n < 2 || n > 10 ? null : n);
            },
            child: const Text('开始切割'),
          ),
        ],
      ),
    );
    final int? n = parts;
    partsCtrl.dispose();
    if (n == null || !mounted) return;
    final String path = _pathOf(m);
    if (path.isEmpty) {
      _toast('切割失败：权重路径为空', error: true);
      return;
    }
    _toast('开始切割为 $n 卷…');
    try {
      // compute：在后台 isolate 用 dart:io 真实读写字节，不阻塞 UI。
      final List<String> outPaths = await compute(
        _splitFileIsolate,
        <String, dynamic>{'path': path, 'parts': n},
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('切割完成'),
          content: SingleChildScrollView(
            child: Text(
              '已产出 ${outPaths.length} 个分卷：\n\n'
              '${outPaths.map((String p) => p.split('/').last).join('\n')}\n\n'
              '原文件保留未动；分卷文件以 .partN 结尾，不会被识别为模型。',
              style: Tga.sub,
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('关闭')),
          ],
        ),
      );
    } on Object catch (e) {
      _toast('切割失败：$e', error: true);
    }
  }

  // ------------------------------------------------------------------
  // 跑分：5 道中文评测题经 chat RPC 对该权重真实推理
  // ------------------------------------------------------------------

  Future<void> _benchModel(Map<String, dynamic> m) async {
    final String name = _nameOf(m);
    final String path = _pathOf(m);
    setState(() => _benchRunning = name);
    final BackendClient backend = context.read<BackendClient>();
    final List<Map<String, String>> rows = <Map<String, String>>[];
    int hits = 0;
    for (final _BenchQuestion q in _kBenchQuestions) {
      String answer;
      bool ok = false;
      try {
        final BridgeEnvelope env = await backend.sendControl(
          'chat',
          <String, dynamic>{
            'text': q.question,
            'model_kind': 'local',
            'local_model_path': path,
          },
        );
        final dynamic payload = env.payload;
        final String engine =
            payload is Map ? (payload['engine'] ?? '').toString() : '';
        final String reply = payload is Map
            ? (payload['reply'] ?? payload['text'] ?? '').toString()
            : '';
        // 只有真实走通端侧 llama.cpp 推理才算成功；
        // 失败回复（local-inference-failed 等）如实记录，不参与命中计分。
        ok = engine.startsWith('llama.cpp');
        answer = ok
            ? reply
            : '推理失败：${reply.isEmpty ? engine : reply.split('\n').first}';
      } on TimeoutException {
        answer = '推理失败：请求超时（45s）';
      } on Object catch (e) {
        answer = '推理失败：$e';
      }
      bool hit = false;
      if (ok) {
        hit = q.keywords.any((String k) => answer.contains(k));
        if (hit) hits += 1;
      }
      rows.add(<String, String>{
        'q': q.question,
        'a': answer,
        'r': ok ? (hit ? '✓ 命中' : '✗ 未命中') : '✗ 失败',
      });
    }
    if (!mounted) return;
    setState(() => _benchRunning = null);
    final int score = (hits * 100 / _kBenchQuestions.length).round();
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text('跑分结果 · $name'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('得分：$hits / ${_kBenchQuestions.length}（$score 分）',
                    style: Tga.h2),
                const SizedBox(height: 4),
                Text('按关键词命中率计分；推理失败的题记 0 分，不编造结果。',
                    style: Tga.caption),
                const SizedBox(height: 12),
                ...rows.map((Map<String, String> r) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('${r['r']}　${r['q']}',
                              style: Tga.body,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text('${r['a']}',
                              style: Tga.sub,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    )),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '蒸馏模型管理',
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
                          Text(_error!, style: Tga.sub,
                              textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          TgaButton(label: '重试', onTap: _load),
                        ],
                      ),
                    ),
                  ],
                )
              : _ownModels.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.fromLTRB(
                          Tga.pagePad, 24, Tga.pagePad, 24),
                      children: <Widget>[
                        TgaCard(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: <Widget>[
                              Icon(Icons.local_florist_outlined,
                                  size: 34, color: Tga.textDim),
                              const SizedBox(height: 10),
                              Text(
                                '还没有蒸馏/本地模型。\n'
                                '去「训练设置」下载基底 GGUF 权重或配置 API 教师，'
                                '蒸馏产出后会出现在这里。',
                                style: Tga.sub,
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 14),
                              TgaButton(
                                label: '去训练设置',
                                icon: Icons.tune_outlined,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (BuildContext _) =>
                                        const TgaTrainingPage(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(
                          Tga.pagePad, 6, Tga.pagePad, 24),
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 10),
                          child: Text(
                            '${_ownModels.length} 个蒸馏/本地权重 · '
                            '共 ${_sizeText(_ownModels.fold<int>(
                                0, (int s, Map<String, dynamic> m) => s + _sizeOf(m)))}',
                            style: Tga.sub,
                          ),
                        ),
                        ..._ownModels.map((Map<String, dynamic> m) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _DistillModelCard(
                                model: m,
                                benching: _benchRunning == _nameOf(m),
                                onDetail: () => _showDetail(m),
                                onRename: () => _renameModel(m),
                                onDelete: () => _deleteModel(m),
                                onSplit: () => _splitModel(m),
                                onBench: () => _benchModel(m),
                              ),
                            )),
                      ],
                    ),
    );
  }
}

/// 在后台 isolate 里按字节切分权重文件，产出 path.part1..N，返回分卷路径。
/// 原文件保留不删。RandomAccessFile 分块读写，不把整文件读进内存。
List<String> _splitFileIsolate(Map<String, dynamic> args) {
  final String path = args['path'] as String;
  final int parts = (args['parts'] as int).clamp(2, 10);
  final File src = File(path);
  if (!src.existsSync()) throw StateError('权重文件不存在：$path');
  final int total = src.lengthSync();
  if (total <= 0) throw StateError('权重文件为空，无法切割');
  final int chunk = (total / parts).ceil();
  final List<String> out = <String>[];
  final RandomAccessFile raf = src.openSync();
  try {
    int offset = 0;
    int idx = 1;
    while (offset < total) {
      final int len = math.min(chunk, total - offset);
      raf.setPositionSync(offset);
      final Uint8List buf = raf.readSync(len);
      final File part = File('$path.part$idx');
      part.writeAsBytesSync(buf, flush: true);
      out.add(part.path);
      offset += len;
      idx += 1;
    }
  } finally {
    raf.closeSync();
  }
  return out;
}

/// 蒸馏模型卡片：名称/大小/路径 + 详情/重命名/删除/切割/跑分。
class _DistillModelCard extends StatelessWidget {
  const _DistillModelCard({
    required this.model,
    required this.benching,
    required this.onDetail,
    required this.onRename,
    required this.onDelete,
    required this.onSplit,
    required this.onBench,
  });
  final Map<String, dynamic> model;
  final bool benching;
  final VoidCallback onDetail;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onSplit;
  final VoidCallback onBench;

  @override
  Widget build(BuildContext context) {
    final String name = (model['name'] ?? '').toString();
    final String path = (model['path'] ?? '').toString();
    final int size = model['size'] is num ? (model['size'] as num).toInt() : 0;
    return TgaCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                    color: Tga.iconPurpleBg,
                    borderRadius: BorderRadius.circular(11)),
                child: Icon(Icons.psychology_outlined,
                    size: 20, color: Tga.iconPurple),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(name,
                        style: Tga.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Text(path,
                        style: Tga.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TgaTag(size > 0
                  ? (size >= 1073741824
                      ? '${(size / 1073741824).toStringAsFixed(2)} GB'
                      : '${(size / 1048576).toStringAsFixed(1)} MB')
                  : '大小未知', color: Tga.textSub),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              TgaButton(label: '详情', filled: false, onTap: onDetail,
                  icon: Icons.info_outline_rounded),
              TgaButton(label: '重命名', filled: false, onTap: onRename,
                  icon: Icons.drive_file_rename_outline_rounded),
              TgaButton(label: '切割', filled: false, onTap: onSplit,
                  icon: Icons.content_cut_rounded),
              TgaButton(
                label: benching ? '跑分中…' : '跑分',
                filled: false,
                onTap: benching ? () {} : onBench,
                icon: Icons.speed_outlined,
              ),
              TgaButton(label: '删除', color: Tga.red, onTap: onDelete,
                  icon: Icons.delete_outline_rounded),
            ],
          ),
        ],
      ),
    );
  }
}
