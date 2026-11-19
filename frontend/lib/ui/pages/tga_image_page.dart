/// 本机画图：MiniMax-H3-Image / Stable Diffusion 系列 GGUF 扩散推理。
///
/// 引擎是 stable-diffusion.cpp 的跨平台 C API（见 harness/diffusion_engine.dart
/// 与 native/sdcpp）。页面不伪造图片：库未编译或组件缺失时如实提示。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../design/tga_design.dart';
import '../../harness/diffusion_engine.dart';

class TgaImageStudioPage extends StatefulWidget {
  const TgaImageStudioPage({super.key});

  @override
  State<TgaImageStudioPage> createState() => _TgaImageStudioPageState();
}

class _TgaImageStudioPageState extends State<TgaImageStudioPage> {
  static const String _kDiffusion = 'tga.image.diffusion';
  static const String _kVae = 'tga.image.vae';
  static const String _kLlm = 'tga.image.llm';

  final TextEditingController _prompt = TextEditingController();
  String _diffusionPath = '';
  String _vaePath = '';
  String _llmPath = '';
  int _width = 1024;
  int _height = 1024;
  int _steps = 6;
  bool _busy = false;
  String? _error;
  String? _outputPath;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _diffusionPath = p.getString(_kDiffusion) ?? '';
        _vaePath = p.getString(_kVae) ?? '';
        _llmPath = p.getString(_kLlm) ?? '';
      });
    } on Object {
      // 无平台实现时保持空路径，由用户手动选择。
    }
  }

  Future<void> _pick(String kind) async {
    final FilePickerResult? r = await FilePicker.platform.pickFiles(
      type: FileType.any,
    );
    final String? path = r?.files.single.path;
    if (path == null) return;
    setState(() {
      if (kind == 'diffusion') _diffusionPath = path;
      if (kind == 'vae') _vaePath = path;
      if (kind == 'llm') _llmPath = path;
      _error = null;
    });
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(
        kind == 'diffusion'
            ? _kDiffusion
            : kind == 'vae'
            ? _kVae
            : _kLlm,
        path,
      );
    } on Object {
      // 选择结果本会话有效；持久化失败不阻断生成。
    }
  }

  Future<void> _generate() async {
    final DiffusionEngine? engine = DiffusionEngine.isAvailable
        ? DiffusionEngine.open()
        : null;
    if (engine == null) {
      setState(() {
        _error =
            '当前安装包未编译扩散原生库。\n'
            '请先执行 scripts/build_sdcpp_android.sh（或桌面脚本）重新打包；'
            '库缺失时不会伪造图片。';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final DiffusionResult r = await engine.generate(
        DiffusionRequest(
          diffusionModelPath: _diffusionPath,
          vaePath: _vaePath,
          textEncoderPath: _llmPath,
          prompt: _prompt.text.trim(),
          width: _width,
          height: _height,
          steps: _steps,
        ),
      );
      if (!mounted) return;
      setState(() {
        _outputPath = r.ok ? r.path : null;
        _error = r.ok ? null : r.error;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final bool ready =
        _diffusionPath.isNotEmpty &&
        _vaePath.isNotEmpty &&
        _llmPath.isNotEmpty &&
        _prompt.text.trim().isNotEmpty;
    return TgaPage(
      title: '画图',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: <Widget>[
          TgaCard(
            child: Row(
              children: <Widget>[
                Icon(
                  DiffusionEngine.isAvailable
                      ? Icons.memory_rounded
                      : Icons.extension_off_outlined,
                  color: Tga.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    DiffusionEngine.isAvailable
                        ? '本地扩散引擎已就绪（stable-diffusion.cpp）'
                        : '本地扩散库未编译：页面可用，生成需先构建原生库',
                    style: TextStyle(color: Tga.text, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const TgaGroupTitle('模型组件'),
          _fileRow(
            '扩散模型',
            _diffusionPath,
            'diffusion',
            'MiniMax-H3-Image diffusion / 单文件 SD、Flux 检查点',
          ),
          _fileRow('VAE', _vaePath, 'vae', 'MiniMax-H3-Image 专用 VAE'),
          _fileRow(
            '文本编码器',
            _llmPath,
            'llm',
            'Qwen3-VL-32B / P-H3-Image（H3 必填）',
          ),
          const TgaGroupTitle('生成参数'),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                TextField(
                  controller: _prompt,
                  minLines: 3,
                  maxLines: 6,
                  onChanged: (_) => setState(() {}),
                  style: TextStyle(color: Tga.text, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '描述你想生成的画面…',
                    hintStyle: TextStyle(color: Tga.textDim),
                    border: InputBorder.none,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    _sizeChip('1024×1024', 1024, 1024),
                    _sizeChip('768×1344', 768, 1344),
                    _sizeChip('1344×768', 1344, 768),
                    _stepsChip(6),
                    _stepsChip(20),
                    _stepsChip(30),
                  ],
                ),
              ],
            ),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 12),
            TgaCard(
              child: Text(
                _error!,
                style: TextStyle(color: Tga.text, fontSize: 13, height: 1.5),
              ),
            ),
          ],
          if (_outputPath != null) ...<Widget>[
            const TgaGroupTitle('生成结果'),
            TgaCard(
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Tga.rCard),
                child: Image.file(File(_outputPath!), fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _outputPath!,
              style: TextStyle(color: Tga.textSub, fontSize: 11),
            ),
          ],
          const SizedBox(height: 18),
          TgaButton(
            label: _busy ? '生成中…' : '生成图片',
            icon: Icons.auto_awesome_rounded,
            onTap: ready && !_busy ? _generate : () {},
            color: ready && !_busy ? null : Tga.textDim,
          ),
        ],
      ),
    );
  }

  Widget _fileRow(String title, String path, String kind, String hint) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        onTap: () => _pick(kind),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(
                      color: Tga.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    path.isEmpty ? hint : path.split('/').last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: path.isEmpty ? Tga.textDim : Tga.textSub,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.folder_open_rounded, color: Tga.textDim, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _sizeChip(String label, int w, int h) {
    final bool on = _width == w && _height == h;
    return _chip(
      label,
      on,
      () => setState(() {
        _width = w;
        _height = h;
      }),
    );
  }

  Widget _stepsChip(int steps) =>
      _chip('$steps 步', _steps == steps, () => setState(() => _steps = steps));

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on ? Tga.primary : Tga.cardAlt,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: on ? Tga.primary : Tga.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on ? Tga.onPrimary : Tga.text,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
