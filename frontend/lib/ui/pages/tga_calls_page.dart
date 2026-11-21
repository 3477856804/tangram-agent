import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../flai/providers/speech_voice_provider.dart';
import '../../flai/providers/voice_provider.dart';
import '../../services/agents_store.dart';
import '../../services/persona_store.dart';
import '../../services/tts_edge.dart';

/// 语音通话：设备识别 → chat 控制域 → Edge TTS 播放，转写真实落盘。
///
/// 真实链路：
///   * `SpeechToTextVoiceProvider` 走平台麦克风识别，最终结果才进入对话；
///   * 文本经 `chat` 控制域交给内置 AgentLoop / 已配置模型；
///   * 回复用 Edge TTS 真实合成 mp3 并播放（音色来自人格设置）；
///   * 挂断时把逐句转写写入 `call` 控制域（calls.json）。
///
/// 诚实边界：麦克风不可用时显示真实错误并提供文字输入；TTS 失败保留文字
/// 转写并标注失败原因；不伪造「机器人主动打来」的通话。
class TgaCallsPage extends StatefulWidget {
  const TgaCallsPage({super.key});

  @override
  State<TgaCallsPage> createState() => _TgaCallsPageState();
}

class _TgaCallsPageState extends State<TgaCallsPage> {
  List<Map<String, dynamic>> _calls = <Map<String, dynamic>>[];
  List<String> _botNames = <String>['助手'];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope = await backend.sendControl('call', <String, dynamic>{
      'action': action,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    final Map<String, dynamic> r = await _call('list', <String, dynamic>{
      'limit': 50,
    });
    List<String> names = <String>['助手'];
    try {
      final AgentsStore agents = await AgentsStore.instance();
      final List<String> list =
          agents.agents.map((TgaAgent a) => a.name.trim()).where((String n) => n.isNotEmpty).toList();
      if (list.isNotEmpty) names = <String>[...list, '助手'];
    } on Object {
      // 智能体读取失败不影响使用默认通话对象。
    }
    if (!mounted) return;
    setState(() {
      _calls = (r['calls'] is List ? r['calls'] as List : <dynamic>[])
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
      _botNames = names;
      _loading = false;
    });
  }

  Future<void> _start() async {
    final TextEditingController name =
        TextEditingController(text: _botNames.first);
    final String? picked = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('发起通话', style: Tga.h2),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final String n in _botNames.take(8))
                  ActionChip(
                    label: Text(n, style: Tga.body),
                    backgroundColor: Tga.bgSoft,
                    onPressed: () => name.text = n,
                  ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: name,
              style: TextStyle(color: Tga.text),
              decoration: const InputDecoration(labelText: '通话对象'),
            ),
            const SizedBox(height: 8),
            Text(
              '通话会真实开启麦克风识别，并把回复用 Edge TTS 读出来；'
              '转写会保存到本机通话记录。',
              style: Tga.caption,
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(name.text.trim()),
            child: const Text('拨打'),
          ),
        ],
      ),
    );
    name.dispose();
    if (picked == null || picked.isEmpty || !mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (BuildContext _) => _CallSheet(botName: picked),
    );
    await _load();
  }

  Future<void> _open(Map<String, dynamic> call) async {
    final Map<String, dynamic> r = await _call('get', <String, dynamic>{
      'id': '${call['id']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '读取通话失败'}');
      return;
    }
    final Map<String, dynamic> full =
        Map<String, dynamic>.from(r['call'] as Map);
    final List<dynamic> entries =
        (full['transcript'] as List?) ?? const <dynamic>[];
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('${full['bot_name']} · 通话转写', style: Tga.h2),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${full['status']} · ${((full['duration_ms'] as num?) ?? 0).toInt() ~/ 1000} 秒 · '
                  '${full['started_at']}',
                  style: Tga.caption,
                ),
                const SizedBox(height: 10),
                if (entries.isEmpty)
                  Text('这次通话没有可显示的转写。', style: Tga.sub)
                else
                  for (final dynamic raw in entries)
                    if (raw is Map)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${raw['speaker']}' == 'user'
                                  ? '你'
                                  : '${raw['speaker']}' == 'bot'
                                      ? '${full['bot_name']}'
                                      : '系统',
                              style: Tga.caption,
                            ),
                            Text('${raw['text']}', style: Tga.body),
                          ],
                        ),
                      ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('关闭', style: TextStyle(color: Tga.textSub)),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(Map<String, dynamic> call) async {
    final Map<String, dynamic> r = await _call('delete', <String, dynamic>{
      'id': '${call['id']}',
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast('${r['error'] ?? '删除失败'}');
      return;
    }
    await _load();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '通话',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _start,
          tooltip: '发起通话',
          icon: Icon(Icons.call_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Tga.primary,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Text(
                    '用麦克风与智能体实时通话：设备识别 → 对话 → Edge TTS 朗读。\n'
                    '逐句转写保存在本机；没有麦克风权限时可改用文字输入。',
                    style: Tga.sub,
                  ),
                ),
                TgaGroupTitle('通话记录（${_calls.length}）'),
                if (_calls.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有通话\n点右上角电话图标发起',
                      icon: Icons.phone_in_talk_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> call in _calls)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TgaCard(
                        onTap: () => _open(call),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              call['status'] == 'completed'
                                  ? Icons.call_made_rounded
                                  : Icons.call_missed_rounded,
                              size: 18,
                              color: call['status'] == 'completed' ? Tga.green : Tga.red,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text('${call['bot_name']}', style: Tga.body),
                                  Text(
                                    '${call['status']} · '
                                    '${((call['duration_ms'] as num?) ?? 0).toInt() ~/ 1000} 秒 · '
                                    '${call['entry_count']} 句',
                                    style: Tga.caption,
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${call['started_at'] ?? ''}'.replaceFirst('T', ' ').split('.').first,
                              style: Tga.caption,
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline_rounded, size: 17, color: Tga.red),
                              onPressed: () => _delete(call),
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

class _CallSheet extends StatefulWidget {
  const _CallSheet({required this.botName});

  final String botName;

  @override
  State<_CallSheet> createState() => _CallSheetState();
}

class _CallSheetState extends State<_CallSheet> {
  final SpeechToTextVoiceProvider _voice = SpeechToTextVoiceProvider();
  StreamSubscription<VoiceEvent>? _sub;
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _typed = TextEditingController();

  final List<Map<String, dynamic>> _entries = <Map<String, dynamic>>[];
  late final DateTime _startedAt;
  Timer? _timer;

  String _status = '准备中…';
  bool _listening = false;
  bool _thinking = false;
  bool _speaking = false;
  bool _muted = false;
  double _amplitude = 0;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    _startedAt = DateTime.now();
    _sub = _voice.conversationEvents.listen(_onVoiceEvent);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _ended) return;
      setState(() {});
    });
    // 真实打开麦克风；失败时 VoiceError 会把原因显示出来。
    _startListening();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    _player.dispose();
    _typed.dispose();
    super.dispose();
  }

  void _onVoiceEvent(VoiceEvent event) {
    if (!mounted || _ended) return;
    switch (event) {
      case VoiceTranscript(:final text):
        if (_muted) return;
        setState(() => _listening = false);
        _send(text);
      case VoiceAmplitude(:final level):
        if (_muted) return;
        setState(() => _amplitude = level);
      case VoiceError(:final message):
        setState(() {
          _listening = false;
          _status = message;
        });
      case VoiceConversationDone():
        setState(() {
          _listening = false;
          _amplitude = 0;
          if (!_thinking && !_speaking) _status = '已就绪，点麦克风继续';
        });
      case VoiceAudio():
        break;
    }
  }

  Future<void> _startListening() async {
    if (_muted || _ended || _listening) return;
    setState(() {
      _listening = true;
      _status = '正在听…';
      _amplitude = 0;
    });
    await _voice.startConversation();
    if (!mounted) return;
    if (!_voice.isListening) {
      setState(() {
        _listening = false;
        _status = '没有开始识别，可使用下方文字输入';
      });
    }
  }

  Future<void> _stopListening() async {
    if (!_listening) return;
    setState(() => _listening = false);
    await _voice.stopConversation();
  }

  Future<void> _send(String text) async {
    final String value = text.trim();
    if (value.isEmpty || _thinking || _ended) return;
    final String now = DateTime.now().toIso8601String();
    setState(() {
      _entries.add(<String, dynamic>{
        'speaker': 'user',
        'text': value,
        'ts': now,
      });
      _thinking = true;
      _speaking = false;
      _status = '思考中…';
      _amplitude = 0;
    });
    String reply = '';
    try {
      final BackendClient backend = context.read<BackendClient>();
      final envelope = await backend.sendControl('chat', <String, dynamic>{
        'text': value,
        'session_id': 'call:${widget.botName}',
      });
      final dynamic payload = envelope.payload;
      if (payload is Map) {
        reply = '${payload['reply'] ?? payload['text'] ?? ''}'.trim();
        if (payload['ok'] != true && reply.isEmpty) {
          reply = '（后端未返回内容：${payload['error'] ?? 'ok=false'}）';
        }
      }
    } on Object catch (e) {
      reply = '（通话请求失败：$e）';
    }
    if (!mounted || _ended) return;
    setState(() {
      _entries.add(<String, dynamic>{
        'speaker': 'bot',
        'text': reply.isEmpty ? '（没有回复）' : reply,
        'ts': DateTime.now().toIso8601String(),
      });
      _thinking = false;
      _speaking = true;
      _status = '正在朗读…';
    });
    if (reply.trim().isNotEmpty && !_muted) {
      await _speak(reply);
    }
    if (!mounted || _ended) return;
    setState(() {
      _speaking = false;
      _status = '已就绪，点麦克风继续';
    });
  }

  Future<void> _speak(String text) async {
    try {
      final String voice = context.read<PersonaStore>().voiceName;
      final Uint8List bytes = await EdgeTts.synthesizeMp3(
        text,
        voice: voice.isEmpty ? 'zh-CN-XiaoxiaoNeural' : voice,
      );
      if (!mounted || _ended) return;
      await _player.stop();
      await _player.play(BytesSource(bytes));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _entries.add(<String, dynamic>{
          'speaker': 'system',
          'text': '语音合成失败：$e',
          'ts': DateTime.now().toIso8601String(),
        });
      });
    }
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    if (_muted) {
      await _stopListening();
      await _player.stop();
      if (mounted) setState(() => _status = '麦克风已静音');
    } else if (mounted) {
      setState(() => _status = '已取消静音');
    }
  }

  Future<void> _hangUp() async {
    if (_ended) return;
    setState(() {
      _ended = true;
      _status = '已挂断';
    });
    final BackendClient backend = context.read<BackendClient>();
    try {
      await _voice.stopConversation();
    } on Object {
      // 识别器已结束时忽略。
    }
    await _player.stop();
    try {
      await backend.sendControl('call', <String, dynamic>{
        'action': 'save',
        'bot_name': widget.botName,
        'started_at': _startedAt.toIso8601String(),
        'ended_at': DateTime.now().toIso8601String(),
        'status': 'completed',
        'muted': _muted,
        'transcript': _entries,
      });
    } on Object {
      // 保存失败时页面仍关闭，历史列表会如实没有这条记录。
    }
    if (mounted) Navigator.of(context).pop();
  }

  String get _clock {
    final Duration d = DateTime.now().difference(_startedAt);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inMinutes)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        height: MediaQuery.of(context).size.height * 0.86,
        decoration: BoxDecoration(
          color: Tga.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: <Widget>[
            const SizedBox(height: 12),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Tga.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 14),
            Text(widget.botName, style: Tga.h1),
            const SizedBox(height: 4),
            Text('$_status · $_clock', style: Tga.sub),
            const SizedBox(height: 14),
            SizedBox(
              height: 54,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  for (int i = 0; i < 24; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: 4,
                      height: math.max(
                        4,
                        6 +
                            math.sin((i + 1) * 0.7) *
                                (_listening ? _amplitude * 40 : 0),
                      ),
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: _listening ? Tga.primary : Tga.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: _entries.isEmpty
                  ? Center(
                      child: Text('开口说话，或使用下方文字输入', style: Tga.sub),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
                      itemCount: _entries.length,
                      itemBuilder: (BuildContext _, int i) {
                        final Map<String, dynamic> e = _entries[i];
                        final bool mine = e['speaker'] == 'user';
                        final bool system = e['speaker'] == 'system';
                        return Align(
                          alignment: mine
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            constraints:
                                const BoxConstraints(maxWidth: 320),
                            decoration: BoxDecoration(
                              color: system
                                  ? Tga.bgSoft
                                  : mine
                                      ? Tga.primary
                                      : Tga.card,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              '${e['text']}',
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.4,
                                color: system
                                    ? Tga.textSub
                                    : mine
                                        ? Tga.onPrimary
                                        : Tga.text,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _typed,
                      style: TextStyle(color: Tga.text),
                      decoration: const InputDecoration(
                        hintText: '没有麦克风？直接输入',
                        isDense: true,
                      ),
                      onSubmitted: (String v) {
                        _typed.clear();
                        _send(v);
                      },
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      final String v = _typed.text;
                      _typed.clear();
                      _send(v);
                    },
                    icon: Icon(Icons.send_rounded, color: Tga.primary),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  _roundButton(
                    icon: _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    label: _muted ? '取消静音' : '静音',
                    color: _muted ? Tga.orange : Tga.bgSoft,
                    iconColor: _muted ? Tga.onPrimary : Tga.text,
                    onTap: _toggleMute,
                  ),
                  _roundButton(
                    icon: _listening
                        ? Icons.stop_circle_outlined
                        : Icons.graphic_eq_rounded,
                    label: _listening ? '停止' : '说话',
                    color: _listening ? Tga.primary : Tga.bgSoft,
                    iconColor: _listening ? Tga.onPrimary : Tga.text,
                    onTap: _listening ? _stopListening : _startListening,
                  ),
                  _roundButton(
                    icon: Icons.call_end_rounded,
                    label: '挂断',
                    color: Tga.red,
                    iconColor: Tga.onPrimary,
                    onTap: _hangUp,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 24),
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: Tga.caption),
      ],
    );
  }
}
