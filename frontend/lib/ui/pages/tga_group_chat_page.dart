import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';
import '../../services/model_registry.dart';

/// 多模型群聊：把本地/云端模型拉进同一场讨论。
///
/// 每个成员独立作答，再由主持人交叉比对一致点与分歧并裁决。
/// 密钥只随本次请求进入本进程内嵌后端，不写日志、不在结果中回显。
class TgaGroupChatPage extends StatefulWidget {
  const TgaGroupChatPage({super.key});

  @override
  State<TgaGroupChatPage> createState() => _TgaGroupChatPageState();
}

class _TgaGroupChatPageState extends State<TgaGroupChatPage> {
  final TextEditingController _prompt = TextEditingController();
  final Set<String> _selected = <String>{};
  bool _running = false;
  Map<String, dynamic>? _result;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final String text = _prompt.text.trim();
    if (text.isEmpty) {
      _toast('请输入要讨论的问题');
      return;
    }
    final ModelRegistry registry = context.read<ModelRegistry>();
    final List<ModelEntry> selected = registry.entries
        .where((ModelEntry e) => _selected.contains(e.id))
        .toList();
    if (selected.isEmpty) {
      _toast('至少选择一个模型');
      return;
    }
    setState(() {
      _running = true;
      _result = null;
    });
    try {
      final List<Map<String, dynamic>> members = selected.map((ModelEntry e) {
        final Map<String, dynamic> params = registry.paramsOf(e);
        return <String, dynamic>{
          'name': e.name,
          ...params,
        };
      }).toList();
      // 主持人优先用第一个云端成员；没有云端时走内置引擎汇总。
      ModelEntry? aggregator;
      for (final ModelEntry e in selected) {
        if (e.kind == ModelKind.cloud) {
          aggregator = e;
          break;
        }
      }
      final BackendClient backend = context.read<BackendClient>();
      final envelope = await backend.sendControl('model_group', <String, dynamic>{
        'text': text,
        'models': members,
        if (aggregator != null) 'aggregator': registry.paramsOf(aggregator),
      });
      final dynamic raw = envelope.payload;
      if (!mounted) return;
      setState(() {
        _result = raw is Map
            ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
            : <String, dynamic>{'ok': false, 'error': '返回格式异常'};
        _running = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _result = <String, dynamic>{'ok': false, 'error': '$e'};
      });
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final ModelRegistry registry = context.watch<ModelRegistry>();
    final List<ModelEntry> entries = registry.entries;
    return TgaPage(
      title: '多模型群聊',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('参与模型（最多 6 个）', style: Tga.h2),
                const SizedBox(height: 6),
                if (entries.isEmpty)
                  Text('还没有可用模型，请先到「模型商店」添加或下载。', style: Tga.sub)
                else
                  for (final ModelEntry e in entries)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _selected.contains(e.id),
                      onChanged: (bool? v) {
                        setState(() {
                          if (v == true) {
                            if (_selected.length >= 6) {
                              _toast('最多选择 6 个模型');
                              return;
                            }
                            _selected.add(e.id);
                          } else {
                            _selected.remove(e.id);
                          }
                        });
                      },
                      title: Text(e.displayName, style: Tga.body),
                      subtitle: Text(e.subtitle, style: Tga.caption),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          TgaCard(
            child: TextField(
              controller: _prompt,
              minLines: 4,
              maxLines: 8,
              style: TextStyle(color: Tga.text),
              decoration: InputDecoration(
                hintText: '输入一个值得讨论的问题…',
                hintStyle: Tga.sub,
                border: InputBorder.none,
                suffixIcon: IconButton(
                  onPressed: _running ? null : _run,
                  icon: _running
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Tga.primary))
                      : Icon(Icons.forum_rounded, color: Tga.primary),
                ),
              ),
            ),
          ),
          if (_result != null) ...<Widget>[
            TgaGroupTitle('讨论结果'),
            if (_result!['ok'] != true)
              TgaCard(
                child: Text((_result!['error'] ?? '执行失败').toString(),
                    style: Tga.body.copyWith(color: Tga.red)),
              )
            else ...<Widget>[
              TgaCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(Icons.gavel_rounded, size: 17, color: Tga.primary),
                        const SizedBox(width: 6),
                        Text('主持人裁决', style: Tga.h2),
                        const Spacer(),
                        Text(
                          '${_result!['synthesis_engine'] ?? ''}',
                          style: Tga.caption,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SelectableText((_result!['synthesis'] ?? '').toString(),
                        style: Tga.body),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              for (final dynamic raw
                  in (_result!['replies'] is List
                      ? _result!['replies'] as List
                      : <dynamic>[]))
                if (raw is Map)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: TgaCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                raw['ok'] == true
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.error_outline_rounded,
                                size: 16,
                                color: raw['ok'] == true ? Tga.green : Tga.red,
                              ),
                              const SizedBox(width: 6),
                              Text((raw['name'] ?? '模型').toString(), style: Tga.h2),
                              const Spacer(),
                              Text(
                                '${raw['engine'] ?? ''} · ${raw['ms'] ?? 0}ms',
                                style: Tga.caption,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            raw['ok'] == true
                                ? (raw['reply'] ?? '').toString()
                                : '失败：${raw['error'] ?? ''}',
                            style: Tga.body,
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          ],
        ],
      ),
    );
  }
}
