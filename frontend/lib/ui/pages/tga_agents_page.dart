import 'package:flutter/material.dart';

import '../../design/tga_design.dart';
import '../../services/agents_store.dart';

/// 智能体中心（#14 真实化）：自定义智能体 JSON 落盘（agents.json），
/// 列表带启用 Switch 与 ⋮（编辑/删除），右上「+」新建（名称必填）。
///
/// 真实接入对话：启用的智能体的 systemPrompt 由 TangramAiProvider 在每次
/// 聊天请求时经 [AgentsStore.enabledSystemPromptBlock] 追加进 system 提示词
/// （与后端技能池注入同一模式）；无启用项时对话提示词保持原样。
class TgaAgentsPage extends StatefulWidget {
  const TgaAgentsPage({super.key});

  @override
  State<TgaAgentsPage> createState() => _TgaAgentsPageState();
}

class _TgaAgentsPageState extends State<TgaAgentsPage> {
  AgentsStore? _store;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final AgentsStore store = await AgentsStore.instance();
    if (!mounted) return;
    setState(() {
      _store = store;
      _loading = false;
    });
  }

  Future<void> _openForm({TgaAgent? existing}) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
          builder: (BuildContext _) => _AgentFormPage(existing: existing)),
    );
    if (saved == true) setState(() {});
  }

  Future<void> _delete(TgaAgent agent) async {
    final AgentsStore? store = _store;
    if (store == null) return;
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('删除智能体「${agent.name}」？', style: Tga.h2),
            content: Text('将从本机 agents.json 中移除，不影响历史对话记录。',
                style: Tga.body),
            actions: <Widget>[
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text('取消', style: TextStyle(color: Tga.textSub))),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text('删除', style: TextStyle(color: Tga.red))),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await store.remove(agent.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AgentsStore? store = _store;
    final List<TgaAgent> agents = store?.agents ?? const <TgaAgent>[];
    final int enabledCount =
        agents.where((TgaAgent a) => a.enabled).length;

    return TgaPage(
      title: '智能体中心',
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.add_rounded, color: Tga.primary),
          tooltip: '新建智能体',
          onPressed: () => _openForm(),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
        children: <Widget>[
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                  child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.4)),
            ),
            )
          else if (agents.isEmpty)
            TgaCard(
              child: TgaEmpty(
                '还没有智能体\n点右上角「+」创建一个专属人设，启用后自动带入对话',
                icon: Icons.smart_toy_outlined,
              ),
            )
          else ...<Widget>[
            Text('共 ${agents.length} 个 · 已启用 $enabledCount 个（启用的人设会注入对话）',
                style: Tga.caption),
            const SizedBox(height: 10),
            for (final TgaAgent a in agents) ...<Widget>[
              _AgentTile(
                agent: a,
                onToggle: (bool v) async {
                  final AgentsStore? s = _store;
                  if (s == null) return;
                  await s.setEnabled(a.id, v);
                  if (mounted) setState(() {});
                },
                onEdit: () => _openForm(existing: a),
                onDelete: () => _delete(a),
              ),
              const SizedBox(height: 10),
            ],
          ],
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '智能体人设保存在本机 agents.json；启用后，其系统提示词会追加到每次对话的'
              ' system prompt（多个启用则全部追加），关闭即恢复原样。',
              style: Tga.caption,
            ),
          ),
        ],
      ),
    );
  }
}

class _AgentTile extends StatelessWidget {
  const _AgentTile({
    required this.agent,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final TgaAgent agent;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final String desc = agent.description.trim().isEmpty
        ? (agent.systemPrompt.trim().isEmpty ? '未填写简介与人设提示词' : '未填写简介')
        : agent.description.trim();
    return TgaCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: Tga.iconPurpleBg,
                borderRadius: BorderRadius.circular(11)),
            child: Icon(Icons.smart_toy_outlined,
                size: 21, color: Tga.iconPurple),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                        child: Text(agent.name,
                            style: Tga.body,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    if (agent.enabled)
                      TgaTag('启用中', color: Tga.green),
                  ],
                ),
                const SizedBox(height: 4),
                Text(desc,
                    style: Tga.sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Switch(value: agent.enabled, onChanged: onToggle),
          PopupMenuButton<String>(
            color: Tga.card,
            icon: Icon(Icons.more_vert_rounded, size: 20, color: Tga.textDim),
            onSelected: (String v) {
              if (v == 'edit') onEdit();
              if (v == 'delete') onDelete();
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                  value: 'edit', child: Text('编辑', style: Tga.body)),
              PopupMenuItem<String>(
                  value: 'delete',
                  child:
                      Text('删除', style: TextStyle(color: Tga.red, fontSize: 14))),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 新建 / 编辑表单（名称必填）
// ---------------------------------------------------------------------------

class _AgentFormPage extends StatefulWidget {
  const _AgentFormPage({this.existing});
  final TgaAgent? existing;

  @override
  State<_AgentFormPage> createState() => _AgentFormPageState();
}

class _AgentFormPageState extends State<_AgentFormPage> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  late final TextEditingController _prompt;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _desc = TextEditingController(text: widget.existing?.description ?? '');
    _prompt =
        TextEditingController(text: widget.existing?.systemPrompt ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('名称必填')));
      return;
    }
    setState(() => _saving = true);
    final AgentsStore store = await AgentsStore.instance();
    final TgaAgent? ex = widget.existing;
    if (ex == null) {
      await store.create(
          name: _name.text,
          description: _desc.text,
          systemPrompt: _prompt.text);
    } else {
      ex.name = _name.text;
      ex.description = _desc.text;
      ex.systemPrompt = _prompt.text;
      await store.update(ex);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: widget.existing == null ? '新建智能体' : '编辑智能体',
      actions: <Widget>[
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: TgaButton(
            label: '保存',
            onTap: _saving ? () {} : _save,
            icon: Icons.check_rounded,
          ),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 6, Tga.pagePad, 32),
        children: <Widget>[
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _fieldLabel('名称（必填）'),
                TextField(
                  controller: _name,
                  maxLength: 30,
                  style: Tga.body,
                  decoration: const InputDecoration(
                      hintText: '如：翻译官、健身教练', isDense: true, counterText: ''),
                ),
                const SizedBox(height: 14),
                _fieldLabel('简介'),
                TextField(
                  controller: _desc,
                  maxLength: 60,
                  style: Tga.body,
                  decoration: const InputDecoration(
                      hintText: '一句话说明这个智能体是做什么的',
                      isDense: true,
                      counterText: ''),
                ),
                const SizedBox(height: 14),
                _fieldLabel('系统提示词（人设，启用后注入对话）'),
                TextField(
                  controller: _prompt,
                  maxLines: 8,
                  minLines: 4,
                  style: Tga.body,
                  decoration: const InputDecoration(
                      hintText:
                          '例如：你是一名资深翻译，始终用简体中文回复，'
                          '翻译时保留原文格式并附术语表。',
                      isDense: true),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('保存后在列表打开「启用」开关，下一条对话即生效。',
                style: Tga.caption),
          ),
        ],
      ),
    );
  }

  Widget _fieldLabel(String text) =>
      Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text, style: Tga.sub));
}
