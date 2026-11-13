import 'package:flutter/material.dart';

import '../../design/tga_design.dart';
import '../../services/announcements.dart';

/// 消息中心（#15 真实化）：公告来自发布仓库 announcements.json（真实 HTTP），
/// 已读 id 集合持久化在文档目录 read_messages.json。
/// 列表显示未读蓝点 + 标题 + 时间，点进详情显示正文（支持换行）。
class TgaMessagesPage extends StatefulWidget {
  const TgaMessagesPage({super.key});

  @override
  State<TgaMessagesPage> createState() => _TgaMessagesPageState();
}

class _TgaMessagesPageState extends State<TgaMessagesPage> {
  List<TgaMessage> _messages = <TgaMessage>[];
  Set<String> _read = <String>{};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final List<TgaMessage> msgs = await Announcements.fetch();
      final Set<String> read = await Announcements.readIds();
      if (!mounted) return;
      setState(() {
        _messages = msgs;
        _read = read;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '公告拉取失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _open(TgaMessage msg) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (BuildContext _) => _MessageDetailPage(message: msg)));
    if (!mounted) return;
    await Announcements.markRead(msg.id);
    if (!mounted) return;
    setState(() => _read = {..._read, msg.id});
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '消息中心',
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
          tooltip: '刷新',
          onPressed: _loading ? null : _load,
        ),
      ],
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
          children: <Widget>[
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                    child: SizedBox(
                        width: 26,
                        height: 26,
                        child:
                            CircularProgressIndicator(strokeWidth: 2.4))),
              )
            else if (_error.isNotEmpty)
              TgaCard(
                child: Column(
                  children: <Widget>[
                    TgaEmpty(_error, icon: Icons.cloud_off_rounded),
                    TgaButton(
                        label: '重试',
                        filled: false,
                        onTap: _load,
                        icon: Icons.refresh_rounded),
                  ],
                ),
              )
            else if (_messages.isEmpty)
              TgaCard(child: TgaEmpty('暂无消息', icon: Icons.mark_chat_unread_outlined))
            else ...<Widget>[
              Text(
                  '${_messages.length} 条公告 · ${_messages.where((TgaMessage m) => !_read.contains(m.id)).length} 条未读',
                  style: Tga.caption),
              const SizedBox(height: 10),
              for (final TgaMessage m in _messages) ...<Widget>[
                _MessageTile(
                    message: m,
                    unread: !_read.contains(m.id),
                    onTap: () => _open(m)),
                const SizedBox(height: 10),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  const _MessageTile(
      {required this.message, required this.unread, required this.onTap});
  final TgaMessage message;
  final bool unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TgaCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 10),
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: unread ? Tga.iconBlue : Colors.transparent,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  message.title,
                  style: unread
                      ? Tga.body.copyWith(fontWeight: FontWeight.w700)
                      : Tga.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Text(message.time, style: Tga.caption),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 19, color: Tga.textDim),
        ],
      ),
    );
  }
}

class _MessageDetailPage extends StatelessWidget {
  const _MessageDetailPage({required this.message});
  final TgaMessage message;

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '消息详情',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
        children: <Widget>[
          TgaCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(message.title, style: Tga.h2),
                const SizedBox(height: 6),
                Text(message.time, style: Tga.caption),
                const SizedBox(height: 12),
                Text(message.body,
                    style: Tga.body.copyWith(height: 1.7),
                    textAlign: TextAlign.left),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
