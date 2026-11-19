import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../harness/store.dart';
import '../../services/model_registry.dart';
import 'tga_store_page.dart';

/// 端侧「运行」页：选本地权重、看真实分层规划、调推理参数并启动。
///
/// 数据全部来自真实来源：
///   * 模型列表 = [ModelRegistry.localEntries]（磁盘扫描的已完成权重）；
///   * 文件大小 = [File.length] 实际字节；
///   * 本机内存 = 后端 `model_store hardware` 的 memory_gb；
///   * 参数落盘 = [HarnessStore] 的 run_config.json，由
///     [LocalInference] 加载模型时读取。
class TgaRunPage extends StatefulWidget {
  const TgaRunPage({super.key});

  @override
  State<TgaRunPage> createState() => _TgaRunPageState();
}

class _TgaRunPageState extends State<TgaRunPage> {
  /// 驻留判断留 20% 给系统与运行时缓冲。
  static const double _kUsableRatio = 0.8;

  /// 加载耗时估算吞吐：GPU 走显存映射、CPU 走主机内存拷贝。
  static const double _kGpuBytesPerSec = 1.0e9;
  static const double _kCpuBytesPerSec = 3.5e8;

  static const List<int> _ctxOptions = <int>[8192, 16384, 32768, 65536];

  /// 文件大小按路径缓存，避免滑杆每次重建都重新 stat。
  final Map<String, Future<int>> _sizeFutures = <String, Future<int>>{};

  String? _selectedId;
  double? _memoryGb;
  bool _hardwareLoading = true;

  int _contextSize = 8192;
  late int _threads;
  bool _gpu = true;
  bool _flash = false;
  String _kv = 'f16';
  bool _thinking = false;

  int get _maxThreads => math.max(2, Platform.numberOfProcessors);

  @override
  void initState() {
    super.initState();
    _threads = math.min(_maxThreads, math.max(2, _maxThreads - 1));
    unawaited(_loadHardware());
    unawaited(_loadConfig());
  }

  Future<void> _loadHardware() async {
    try {
      final BackendClient backend = context.read<BackendClient>();
      final envelope = await backend.sendControl(
          'model_store', <String, dynamic>{'action': 'hardware'});
      final dynamic payload = envelope.payload;
      final dynamic raw = payload is Map ? payload['memory_gb'] : null;
      if (!mounted) return;
      setState(() {
        _memoryGb = raw is num ? raw.toDouble() : null;
        _hardwareLoading = false;
      });
    } on Object {
      if (!mounted) return;
      // 探测失败如实显示未知，不猜硬件。
      setState(() => _hardwareLoading = false);
    }
  }

  Future<void> _loadConfig() async {
    try {
      final HarnessStore store = await HarnessStore.instance();
      final Map<String, dynamic> cfg = await store.readJson('run_config.json');
      final dynamic ctxRaw = cfg['context_size'];
      final dynamic threadsRaw = cfg['threads'];
      final dynamic gpuRaw = cfg['gpu_layers'];
      final dynamic flashRaw = cfg['flash_attn'];
      final dynamic thinkingRaw = cfg['thinking'];
      final String kvRaw = (cfg['kv_cache'] ?? '').toString();
      if (!mounted) return;
      setState(() {
        if (ctxRaw is num && _ctxOptions.contains(ctxRaw.toInt())) {
          _contextSize = ctxRaw.toInt();
        }
        if (threadsRaw is num) {
          _threads = threadsRaw.toInt().clamp(2, _maxThreads).toInt();
        }
        if (gpuRaw is num) _gpu = gpuRaw.toInt() > 0;
        if (flashRaw is bool) _flash = flashRaw;
        if (kvRaw == 'q8_0' || kvRaw == 'q4_0' || kvRaw == 'f16') _kv = kvRaw;
        if (thinkingRaw is bool) _thinking = thinkingRaw;
        if (_kv != 'f16') _flash = true;
      });
    } on Object {
      // 没有配置就用默认值，不阻塞页面。
    }
  }

  Future<void> _saveConfig() async {
    try {
      final HarnessStore store = await HarnessStore.instance();
      await store.writeJson('run_config.json', <String, dynamic>{
        'context_size': _contextSize,
        'threads': _threads,
        'gpu_layers': _gpu ? 99 : 0,
        'gpu_backend': _gpu ? 'vulkan' : 'cpu',
        'flash_attn': _flash,
        'kv_cache': _kv,
        'thinking': _thinking,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } on Object catch (e) {
      if (!mounted) return;
      _toast('保存参数失败：$e');
    }
  }

  void _setKV(String kv) {
    setState(() {
      _kv = kv;
      // llama.cpp 拒绝非 F16 KV 搭配关闭的 Flash Attention。
      if (kv != 'f16') _flash = true;
    });
    unawaited(_saveConfig());
  }

  Future<int> _sizeOf(String path) =>
      _sizeFutures.putIfAbsent(path, () => File(path).length());

  String? _effectiveId(List<ModelEntry> local, ModelRegistry registry) {
    if (local.isEmpty) return null;
    final bool has = local.any((ModelEntry e) => e.id == _selectedId);
    if (has) return _selectedId;
    if (local.any((ModelEntry e) => e.id == registry.selectedId)) {
      return registry.selectedId;
    }
    return local.first.id;
  }

  ModelEntry? _entryOf(List<ModelEntry> local, String? id) {
    for (final ModelEntry e in local) {
      if (e.id == id) return e;
    }
    return null;
  }

  Future<void> _start(ModelEntry? entry) async {
    if (entry == null) {
      _toast('请先选择本地模型');
      return;
    }
    try {
      await context.read<ModelRegistry>().setSelected(entry.id);
      if (!mounted) return;
      Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
    } on Object catch (e) {
      if (!mounted) return;
      _toast('启动失败：$e');
    }
  }

  void _openStore() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const TgaStorePage()),
    );
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final ModelRegistry registry = context.watch<ModelRegistry>();
    final List<ModelEntry> local = registry.localEntries;
    final String? selectedId = _effectiveId(local, registry);
    final ModelEntry? selected = _entryOf(local, selectedId);
    final String? path = selected?.path;

    return TgaPage(
      title: '运行',
      actions: <Widget>[
        IconButton(
          onPressed: _hardwareLoading
              ? null
              : () {
                  setState(() => _hardwareLoading = true);
                  unawaited(_loadHardware());
                },
          tooltip: '重测硬件',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      bottom: local.isEmpty
          ? null
          : Container(
              color: Tga.bg,
              padding: const EdgeInsets.fromLTRB(
                  Tga.pagePad, 10, Tga.pagePad, 12),
              child: SafeArea(
                top: false,
                child: SizedBox(
                  width: double.infinity,
                  child: TgaButton(
                    label: '启动',
                    icon: Icons.play_arrow_rounded,
                    compact: false,
                    onTap: () => unawaited(_start(selected)),
                  ),
                ),
              ),
            ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 32),
        children: <Widget>[
          if (local.isEmpty) ...<Widget>[
            const SizedBox(height: 40),
            TgaCard(
              child: Column(
                children: <Widget>[
                  const TgaEmpty(
                    '还没有本地模型\n去模型库下载或导入 GGUF 权重',
                    icon: Icons.memory_rounded,
                  ),
                  const SizedBox(height: 6),
                  TgaButton(
                    label: '去模型库',
                    icon: Icons.storefront_rounded,
                    compact: false,
                    onTap: _openStore,
                  ),
                ],
              ),
            ),
          ] else ...<Widget>[
            TgaGroupTitle('模型'),
            TgaCard(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: selectedId,
                            hint: Text('选择本地模型', style: Tga.sub),
                            borderRadius: BorderRadius.circular(14),
                            dropdownColor: Tga.card,
                            icon: Icon(Icons.expand_more_rounded,
                                color: Tga.textSub),
                            items: <DropdownMenuItem<String>>[
                              for (final ModelEntry e in local)
                                DropdownMenuItem<String>(
                                  value: e.id,
                                  child: Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: Text(
                                          e.name,
                                          style: Tga.body,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      if (e.path != null)
                                        FutureBuilder<int>(
                                          future: _sizeOf(e.path!),
                                          builder: (BuildContext ctx,
                                              AsyncSnapshot<int> snap) {
                                            final int? bytes = snap.data;
                                            return Text(
                                              bytes == null
                                                  ? '—'
                                                  : _fmtBytes(bytes),
                                              style: Tga.caption,
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                            ],
                            onChanged: (String? v) {
                              if (v == null) return;
                              setState(() => _selectedId = v);
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      TgaTag('本地', color: Tga.green),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    path ?? '权重路径未知',
                    style: Tga.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            TgaGroupTitle('分层'),
            TgaCard(child: _planCard(path)),
            TgaGroupTitle('参数'),
            TgaCard(child: _configCard()),
          ],
        ],
      ),
    );
  }

  Widget _planCard(String? path) {
    return FutureBuilder<int>(
      future: path == null ? null : _sizeOf(path),
      builder: (BuildContext context, AsyncSnapshot<int> snap) {
        final int? bytes = snap.data;
        final bool fileError = path != null && snap.hasError;
        final double? memGb = _memoryGb;
        final double? budgetGb = memGb == null ? null : memGb * _kUsableRatio;
        final int? budgetBytes = budgetGb == null
            ? null
            : (budgetGb * 1024 * 1024 * 1024).round();
        final bool? fits = (bytes != null && budgetBytes != null)
            ? bytes <= budgetBytes
            : null;
        final double? seconds = bytes == null
            ? null
            : bytes / (_gpu ? _kGpuBytesPerSec : _kCpuBytesPerSec) + 2;

        String memText;
        if (_hardwareLoading) {
          memText = '探测中…';
        } else if (memGb == null) {
          memText = '未知';
        } else {
          memText = '${memGb.toStringAsFixed(1)} GB';
        }

        String sizeText;
        if (path == null) {
          sizeText = '—';
        } else if (fileError) {
          sizeText = '读取失败';
        } else if (bytes == null) {
          sizeText = '读取中…';
        } else {
          sizeText = _fmtBytes(bytes);
        }

        String fitText;
        if (fits == null) {
          fitText = '未知';
        } else if (fits) {
          fitText = '可全部放进内存';
        } else {
          final int over = bytes! - budgetBytes!;
          fitText = '部分驻留 · 超出 ${_fmtBytes(over)}';
        }

        final String planText = _gpu
            ? 'GPU 全层（Vulkan）→ 失败回退 CPU'
            : 'CPU 全层（gpu_layers=0）';
        final String timeText = seconds == null
            ? '未知'
            : '约 ${seconds.toStringAsFixed(1)} 秒';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _row('本机内存', memText),
            _row('模型大小', sizeText),
            _row('可用预算', budgetGb == null
                ? '未知'
                : '${budgetGb.toStringAsFixed(1)} GB（80%）'),
            _row('驻留判断', fitText,
                color: fits == true
                    ? Tga.green
                    : (fits == false ? Tga.orange : null)),
            _row('预计加载', timeText),
            _row('分层方案', planText),
            const SizedBox(height: 8),
            Text(
              '内存来自后端硬件探测，模型大小为落盘字节；'
              '加载时间按实际大小与所选后端吞吐估算，'
              '失败时按 180 秒超时逐级降级。',
              style: Tga.caption,
            ),
          ],
        );
      },
    );
  }

  Widget _configCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('上下文', style: Tga.sub),
        const SizedBox(height: 8),
        TgaSegmented<int>(
          items: _ctxOptions,
          value: _contextSize,
          labelOf: (int v) => '${v ~/ 1024}K',
          onChanged: (int v) {
            setState(() => _contextSize = v);
            unawaited(_saveConfig());
          },
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Text('线程', style: Tga.sub),
            const Spacer(),
            Text('$_threads / $_maxThreads', style: Tga.body),
          ],
        ),
        Slider(
          value: _threads
              .toDouble()
              .clamp(2, _maxThreads.toDouble())
              .toDouble(),
          min: 2,
          max: _maxThreads.toDouble(),
          divisions: _maxThreads > 2 ? _maxThreads - 2 : null,
          label: '$_threads',
          onChanged: (double v) => setState(() => _threads = v.round()),
          onChangeEnd: (double _) => unawaited(_saveConfig()),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _gpu,
          onChanged: (bool v) {
            setState(() => _gpu = v);
            unawaited(_saveConfig());
          },
          title: Text('显卡 · Vulkan', style: Tga.body),
          subtitle: Text('加载失败自动回退 CPU', style: Tga.caption),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _flash,
          onChanged: (bool v) {
            if (!v && _kv != 'f16') {
              _toast('非 F16 KV 缓存必须开启 Flash Attention');
              return;
            }
            setState(() => _flash = v);
            unawaited(_saveConfig());
          },
          title: Text('Flash Attention', style: Tga.body),
          subtitle: Text(
            _kv == 'f16' ? '开启后降低长上下文显存占用' : '非 F16 KV 必须开启',
            style: Tga.caption,
          ),
        ),
        const SizedBox(height: 4),
        Text('KV 精度', style: Tga.sub),
        const SizedBox(height: 8),
        TgaSegmented<String>(
          items: const <String>['q8_0', 'f16', 'q4_0'],
          value: _kv,
          labelOf: (String v) => v == 'q8_0'
              ? 'Q8'
              : (v == 'q4_0' ? 'Q4' : 'F16'),
          onChanged: _setKV,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _thinking,
          onChanged: (bool v) {
            setState(() => _thinking = v);
            unawaited(_saveConfig());
          },
          title: Text('思考模式', style: Tga.body),
          subtitle: Text('对话时注入深度思考前缀', style: Tga.caption),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: <Widget>[
            SizedBox(width: 76, child: Text(label, style: Tga.sub)),
            Expanded(
              child: Text(
                value,
                style: Tga.body.copyWith(color: color),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      );
}
