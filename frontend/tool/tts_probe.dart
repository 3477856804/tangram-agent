// 临时验证脚本：真实跑 Edge TTS 协议（音色列表 + Sec-MS-GEC v2 + WS 合成）。
// 用法：dart run tool/tts_probe.dart（或独立包内 dart run tts_probe.dart）
import 'dart:io';
import 'dart:typed_data';

import 'package:tangram/services/tts_edge.dart';

Future<void> main(List<String> args) async {
  final List<EdgeTtsVoice> voices = await EdgeTts.fetchVoices();
  stdout.writeln('voices: ${voices.length} '
      '(zh=${voices.where((EdgeTtsVoice v) => v.isChinese).length}, '
      'en=${voices.where((EdgeTtsVoice v) => !v.isChinese).length})');
  for (final EdgeTtsVoice v in voices.take(8)) {
    stdout.writeln('  ${v.shortName} ${v.displayName} ${v.gender}');
  }
  stdout.writeln('dart token: ${EdgeTts.secMsGecToken()}');

  for (final String voice in <String>[
    'zh-CN-XiaoyiNeural',
    'en-US-AriaNeural',
  ]) {
    final Uint8List bytes = await EdgeTts.synthesizeMp3(
      'TGA，让每个人拥有自己的模型',
      voice: voice,
    );
    final File out = File('/tmp/tga_tts_$voice.mp3');
    await out.writeAsBytes(bytes);
    stdout.writeln('OK $voice -> ${out.path} ${bytes.length} bytes');
  }
}
