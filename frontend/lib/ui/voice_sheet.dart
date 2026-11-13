import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../design/tga_design.dart';
import '../services/persona_store.dart';
import '../services/tts_edge.dart';

/// 音色设置底部表（问题 #12：接入真实 Edge TTS）。
///
/// 打开即真实拉取微软 Edge TTS 音色列表（zh-CN / en-US），分组展示；
/// 每行可试听（在线合成短句并用 audioplayers 播放 mp3），点行选择音色
/// 并持久化到 [PersonaStore]，当前选中打勾。加载/失败状态如实显示。
Future<void> showTgaVoiceSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => const _TgaVoiceSheet(),
  );
}

class _TgaVoiceSheet extends StatefulWidget {
  const _TgaVoiceSheet();

  @override
  State<_TgaVoiceSheet> createState() => _TgaVoiceSheetState();
}

class _TgaVoiceSheetState extends State<_TgaVoiceSheet> {
  static const String _previewText = 'TGA，让每个人拥有自己的模型';

  late Future<List<EdgeTtsVoice>> _voices;
  final AudioPlayer _player = AudioPlayer();

  /// 正在试听（合成/播放中）的音色 ShortName；null 表示空闲。
  String? _previewing;

  @override
  void initState() {
    super.initState();
    _voices = EdgeTts.fetchVoices();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _preview(EdgeTtsVoice voice) async {
    if (_previewing != null) return;
    setState(() => _previewing = voice.shortName);
    String? error;
    try {
      final Uint8List bytes = await EdgeTts.synthesizeMp3(
        _previewText,
        voice: voice.shortName,
      );
      await _player.stop();
      await _player.play(BytesSource(bytes));
    } on Object catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() => _previewing = null);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('试听失败：$error'),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  Widget _groupTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
        child: Text(
            text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Tga.groupTitle)),
      );

  Widget _voiceRow(EdgeTtsVoice voice, bool selected) {
    final PersonaStore store = context.read<PersonaStore>();
    return InkWell(
      onTap: () => store.setVoice(voice.displayName, voice.shortName),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: <Widget>[
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: voice.isFemale ? Tga.iconPinkBg : Tga.iconBlueBg,
                  shape: BoxShape.circle),
              child: Icon(
                  voice.isFemale
                      ? Icons.face_retouching_natural_rounded
                      : Icons.person_rounded,
                  size: 18,
                  color: voice.isFemale ? Tga.iconPink : Tga.iconBlue),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(voice.displayName, style: Tga.body),
                  const SizedBox(height: 3),
                  Text(
                    '${voice.isFemale ? '女声' : '男声'} · ${voice.shortName}',
                    style: Tga.caption,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 34,
              height: 34,
              child: _previewing == voice.shortName
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: CircularProgressIndicator(
                          strokeWidth: 2.2, color: Tga.iconCyan),
                    )
                  : IconButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => _preview(voice),
                      icon: Icon(Icons.play_arrow_rounded,
                          size: 21, color: Tga.iconCyan),
                      tooltip: '试听',
                    ),
            ),
            const SizedBox(width: 6),
            Icon(
              selected ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 20,
              color: selected ? Tga.primary : Tga.textDim,
            ),
          ],
        ),
      ),
    );
  }

  Widget _voiceList(List<EdgeTtsVoice> voices) {
    final PersonaStore store = context.watch<PersonaStore>();
    final List<EdgeTtsVoice> zh =
        voices.where((EdgeTtsVoice v) => v.isChinese).toList();
    final List<EdgeTtsVoice> en =
        voices.where((EdgeTtsVoice v) => !v.isChinese).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: <Widget>[
        if (zh.isNotEmpty) ...<Widget>[
          _groupTitle('中文'),
          for (final EdgeTtsVoice v in zh)
            _voiceRow(v, store.voiceShortName == v.shortName),
        ],
        if (en.isNotEmpty) ...<Widget>[
          _groupTitle('英文'),
          for (final EdgeTtsVoice v in en)
            _voiceRow(v, store.voiceShortName == v.shortName),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
          child: Text('试听为微软 Edge 在线合成，需联网；点行即选中并保存。',
              style: Tga.caption),
        ),
      ],
    );
  }

  Widget _loading() => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 40),
          CircularProgressIndicator(strokeWidth: 2.6, color: Tga.primary),
          const SizedBox(height: 16),
          Text('正在获取音色列表…', style: Tga.sub),
          const SizedBox(height: 40),
        ],
      );

  Widget _error(Object e) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SizedBox(height: 30),
          Icon(Icons.cloud_off_rounded, size: 34, color: Tga.textDim),
          const SizedBox(height: 12),
          Text('音色列表加载失败', style: Tga.body),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child:
                Text('$e', style: Tga.caption, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          TgaButton(
            label: '重试',
            icon: Icons.refresh_rounded,
            onTap: () => setState(() => _voices = EdgeTts.fetchVoices()),
          ),
          const SizedBox(height: 36),
        ],
      );

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.78,
      decoration: BoxDecoration(
        color: Tga.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text('音色', style: Tga.h2),
                        const SizedBox(height: 2),
                        Text('微软 Edge TTS · 云端合成', style: Tga.caption),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: Tga.textDim),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<EdgeTtsVoice>>(
                future: _voices,
                builder:
                    (BuildContext ctx, AsyncSnapshot<List<EdgeTtsVoice>> snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return Center(child: _loading());
                  }
                  if (snap.hasError) {
                    return Center(child: _error(snap.error!));
                  }
                  return _voiceList(snap.data!);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
