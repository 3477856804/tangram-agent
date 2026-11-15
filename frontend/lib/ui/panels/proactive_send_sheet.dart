import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../bridge/bridge_protocol.dart';
import '../../design/tga_design.dart';

/// 主动发送面板：把一条消息真正推到已接入的 QQ / 微信 / 飞书。
///
/// 目标列表来自后端 `im_event{action:send_targets}`——只包含**真实收到过
/// 消息**的会话（收消息时自动记账、重启可恢复），也可手填
/// openid / group_openid / to_user_id / open_id / chat_id。
/// 发送结果逐渠道回显真实回执或官方错误，不把「点了按钮」当成已发送。
Future<void> showProactiveSendSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Tga.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (BuildContext ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: const _ProactiveSendBody(),
    ),
  );
}

class _ProactiveSendBody extends StatefulWidget {
  const _ProactiveSendBody();

  @override
  State<_ProactiveSendBody> createState() => _ProactiveSendBodyState();
}

class _ProactiveSendBodyState extends State<_ProactiveSendBody> {
  static const List<Map<String, String>> _channels = <Map<String, String>>[
    <String, String>{'id': 'wechat', 'name': '微信'},
    <String, String>{'id': 'qq', 'name': 'QQ'},
    <String, String>{'id': 'feishu', 'name': '飞书'},
  ];

  final TextEditingController _text = TextEditingController();
  final TextEditingController _manual = TextEditingController();

  String _channel = 'wechat';
  String _scope = 'users';
  String _target = '';
  Map<String, List<Map<String, dynamic>>> _targets =
      <String, List<Map<String, dynamic>>>{};
  bool _loading = true;
  bool _sending = false;
  String _result = '';
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _loadTargets();
  }

  @override
  void dispose() {
    _text.dispose();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _loadTargets() async {
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl(
          'im_event', <String, dynamic>{'action': 'send_targets'});
      final dynamic p = env.payload;
      final Map<String, List<Map<String, dynamic>>> book =
          <String, List<Map<String, dynamic>>>{};
      if (p is Map && p['targets'] is Map) {
        for (final MapEntry<dynamic, dynamic> e
            in (p['targets'] as Map).entries) {
          final dynamic list = e.value;
          if (list is List) {
            book[e.key.toString()] = list
                .whereType<Map>()
                .map((Map m) => Map<String, dynamic>.from(m))
                .toList();
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _targets = book;
        _loading = false;
        final List<Map<String, dynamic>> mine = book[_channel] ?? <Map<String, dynamic>>[];
        if (mine.isNotEmpty) _target = (mine.first['id'] ?? '').toString();
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _result = '读取目标失败：$e';
      });
    }
  }

  List<Map<String, dynamic>> get _channelTargets =>
      _targets[_channel] ?? <Map<String, dynamic>>[];

  void _pickChannel(String id) {
    setState(() {
      _channel = id;
      _result = '';
      final List<Map<String, dynamic>> mine =
          _targets[id] ?? <Map<String, dynamic>>[];
      _target = mine.isEmpty ? '' : (mine.first['id'] ?? '').toString();
      _manual.clear();
    });
  }

  Future<void> _send() async {
    final String text = _text.text.trim();
    final String to = _manual.text.trim().isNotEmpty ? _manual.text.trim() : _target;
    if (text.isEmpty) {
      setState(() {
        _ok = false;
        _result = '消息内容为空';
      });
      return;
    }
    if (to.isEmpty) {
      setState(() {
        _ok = false;
        _result = '缺少接收方：选一个真实会话，或手填 id';
      });
      return;
    }
    setState(() {
      _sending = true;
      _result = '发送中…';
    });
    try {
      final BackendClient backend = context.read<BackendClient>();
      final BridgeEnvelope env = await backend.sendControl('im_event', <String, dynamic>{
        'action': 'send',
        'connector': _channel,
        'to': to,
        'text': text,
        'scope': _channel == 'feishu'
            ? (_scope == 'groups' ? 'chat_id' : 'open_id')
            : _scope,
      });
      final dynamic p = env.payload;
      final Map<String, dynamic> payload =
          p is Map ? p.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};
      if (!mounted) return;
      final bool ok = payload['ok'] == true;
      setState(() {
        _sending = false;
        _ok = ok;
        _result = ok
            ? '已发送到 ${payload['results'] is List && (payload['results'] as List).isNotEmpty ? ((payload['results'] as List).first as Map)['connector'] : _channel}（真实回执）'
            : '发送失败：${payload['error'] ?? '未知原因'}';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _ok = false;
        _result = '发送失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    final List<Map<String, dynamic>> targets = _channelTargets;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text('主动发送', style: Tga.h2)),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close_rounded, color: Tga.textSub),
                ),
              ],
            ),
            Text(
              '只对已授权的渠道发送；目标来自真实会话记录，或手填官方 id。',
              style: Tga.caption,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final Map<String, String> c in _channels)
                  ChoiceChip(
                    label: Text(c['name']!),
                    selected: _channel == c['id'],
                    onSelected: (_) => _pickChannel(c['id']!),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              Text('读取目标…', style: Tga.caption)
            else if (targets.isEmpty)
              Text('这个渠道还没有收到过消息：请手填 id，或先在对应平台发一条给机器人。',
                  style: Tga.caption)
            else
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  for (final Map<String, dynamic> t in targets.take(8))
                    ActionChip(
                      label: Text(
                        '${t['type'] == 'group' ? '群 ' : ''}${t['id']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      onPressed: () {
                        setState(() {
                          _target = (t['id'] ?? '').toString();
                          _manual.clear();
                        });
                      },
                    ),
                ],
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _manual,
              style: Tga.body,
              onChanged: (_) => setState(() {
                _result = '';
              }),
              decoration: InputDecoration(
                isDense: true,
                labelText: _channel == 'feishu'
                    ? 'open_id / chat_id（可留空用上方目标）'
                    : _channel == 'qq'
                        ? 'openid / group_openid（可留空用上方目标）'
                        : 'to_user_id（可留空用上方目标）',
                border: const OutlineInputBorder(),
              ),
            ),
            if (_channel == 'qq' || _channel == 'feishu') ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Text('类型', style: Tga.caption),
                  const SizedBox(width: 8),
                  SegmentedButton<String>(
                    segments: <ButtonSegment<String>>[
                      ButtonSegment<String>(
                          value: 'users',
                          label: Text(_channel == 'feishu' ? 'open_id' : '单聊')),
                      ButtonSegment<String>(
                          value: 'groups',
                          label: Text(_channel == 'feishu' ? 'chat_id' : '群')),
                    ],
                    selected: <String>{_scope},
                    onSelectionChanged: (Set<String> s) =>
                        setState(() => _scope = s.first),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _text,
              style: Tga.body,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '消息内容',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: Text(_sending ? '发送中…' : '发送'),
                  ),
                ),
              ],
            ),
            if (_result.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                _result,
                style: Tga.caption.copyWith(
                  color: _sending
                      ? Tga.textSub
                      : (_ok ? Tga.green : Tga.red),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}