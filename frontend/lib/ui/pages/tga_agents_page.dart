import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/tga_design.dart';
import '../../services/agents_store.dart';

/// 智能体中心：自定义智能体 JSON 落盘（agents.json），
/// 列表带「对话注入」与「子 Agent 调度」两个独立开关、角色/知识库/权限摘要，
/// 右上「+」新建，另有导入/导出全部 agents JSON。
///
/// 真实接入对话：启用（enabled）的智能体 systemPrompt 由 TangramAiProvider
/// 在每次聊天请求时经 [AgentsStore.enabledSystemPromptBlock] 追加进 system
/// 提示词；executionEnabled 只表示是否可作为子 Agent 被调度，不参与注入。
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

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openForm({TgaAgent? existing}) async {
    final bool? saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
          builder: (BuildContext _) => _AgentFormPage(existing: existing)),
    );
    if (saved == true && mounted) setState(() {});
  }

  Future<void> _delete(TgaAgent agent) async {
    final AgentsStore? store = _store;
    if (store == null) return;
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('删除智能体「${agent.name}」？', style: Tga.h2),
            content: Text(
                '将从本机 agents.json 中移除，不影响历史对话记录；'
                '其独立记忆文件 agent_memory/${agent.id}.json 不会被自动删除。',
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

  Future<void> _exportAll() async {
    final AgentsStore? store = _store;
    if (store == null) return;
    final String json = store.exportJson();
    final TextEditingController ctrl =
        TextEditingController(text: json);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return AlertDialog(
          backgroundColor: Tga.card,
          title: Text('导出全部智能体', style: Tga.h2),
          content: SizedBox(
            width: 560,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: TextField(
                controller: ctrl,
                readOnly: true,
                maxLines: null,
                style: TextStyle(
                    fontSize: 12,
                    color: Tga.text,
                    fontFamily: 'monospace',
                    height: 1.5),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Tga.bgSoft,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: json));
                Navigator.pop(ctx);
                _snack('已复制全部智能体 JSON 到剪贴板');
              },
              child: const Text('复制'),
            ),
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        );
      },
    );
    ctrl.dispose();
  }

  Future<void> _importAll() async {
    final AgentsStore? store = _store;
    if (store == null) return;
    final TextEditingController ctrl = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) {
        Tga.syncFrom(ctx);
        return AlertDialog(
          backgroundColor: Tga.card,
          title: Text('导入智能体 JSON', style: Tga.h2),
          content: SizedBox(
            width: 560,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: TextField(
                controller: ctrl,
                maxLines: null,
                style: TextStyle(
                    fontSize: 12,
                    color: Tga.text,
                    fontFamily: 'monospace',
                    height: 1.5),
                decoration: InputDecoration(
                  hintText: '[{"id":"...","name":"研究员","role":"researcher",...}]',
                  filled: true,
                  fillColor: Tga.bgSoft,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('导入'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (text == null || text.trim().isEmpty || !mounted) return;
    final Map<String, dynamic> result = await store.importJson(text);
    if (!mounted) return;
    if (result['ok'] == true) {
      setState(() {});
      _snack('已导入 ${result['imported']} 个智能体并落盘');
    } else {
      _snack('导入失败：${result['error']}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final AgentsStore? store = _store;
    final List<TgaAgent> agents = store?.agents ?? const <TgaAgent>[];
    final int enabledCount = agents.where((TgaAgent a) => a.enabled).length;
    final int executableCount =
        agents.where((TgaAgent a) => a.executionEnabled).length;

    return TgaPage(
      title: '智能体中心',
      actions: <Widget>[
        IconButton(
          icon: Icon(Icons.file_download_outlined, color: Tga.primary),
          tooltip: '导出全部智能体 JSON',
          onPressed: _loading ? null : _exportAll,
        ),
        IconButton(
          icon: Icon(Icons.file_upload_outlined, color: Tga.primary),
          tooltip: '导入智能体 JSON',
          onPressed: _loading ? null : _importAll,
        ),
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
            Text(
                '共 ${agents.length} 个 · 对话启用 $enabledCount 个 · '
                '可调度 $executableCount 个',
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
                onExecutionToggle: (bool v) async {
                  final AgentsStore? s = _store;
                  if (s == null) return;
                  await s.setExecution(a.id, v);
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
              '智能体配置保存在本机 agents.json。「对话注入」只影响聊天 system '
              'prompt；「可调度」只决定能否作为子 Agent 执行，两者互不影响。'
              '独立记忆落盘在 agent_memory/<id>.json。',
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
    required this.onExecutionToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final TgaAgent agent;
  final ValueChanged<bool> onToggle;
  final ValueChanged<bool> onExecutionToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final String desc = agent.description.trim().isEmpty
        ? (agent.systemPrompt.trim().isEmpty ? '未填写简介与人设提示词' : '未填写简介')
        : agent.description.trim();
    final String? role = agent.role;
    return TgaCard(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
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
                    Text(agent.name,
                        style: Tga.body,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 4),
                    Text(desc,
                        style: Tga.sub,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                color: Tga.card,
                icon: Icon(Icons.more_vert_rounded,
                    size: 20, color: Tga.textDim),
                onSelected: (String v) {
                  if (v == 'edit') onEdit();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                      value: 'edit', child: Text('编辑', style: Tga.body)),
                  PopupMenuItem<String>(
                      value: 'delete',
                      child: Text('删除',
                          style: TextStyle(color: Tga.red, fontSize: 14))),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              if (role != null && role.isNotEmpty)
                TgaTag(role, color: Tga.primaryDeep),
              TgaTag(agent.enabled ? '对话启用' : '对话关闭',
                  color: agent.enabled ? Tga.green : Tga.textDim),
              TgaTag(agent.executionEnabled ? '可调度' : '不调度',
                  color: agent.executionEnabled ? Tga.cyan : Tga.textDim),
              TgaTag('知识库 ${agent.knowledgeIds.length}',
                  color: Tga.purple),
              TgaTag(agent.memoryScope == TgaAgent.scopeShared
                  ? '共享记忆视图'
                  : '独立记忆'),
            ],
          ),
          const SizedBox(height: 6),
          Text(agent.permissionSummary,
              style: Tga.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              Text('对话注入', style: Tga.sub),
              Switch(value: agent.enabled, onChanged: onToggle),
              const SizedBox(width: 6),
              Text('子 Agent 可调度', style: Tga.sub),
              Switch(
                  value: agent.executionEnabled,
                  onChanged: onExecutionToggle),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 新建 / 编辑表单（名称必填，权限 JSON 结构校验）
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
  late final TextEditingController _role;
  late final TextEditingController _knowledge;
  late final TextEditingController _maxSteps;
  late final TextEditingController _modelId;
  late final TextEditingController _permissions;
  late String _memoryScope;
  late bool _executionEnabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final TgaAgent? ex = widget.existing;
    _name = TextEditingController(text: ex?.name ?? '');
    _desc = TextEditingController(text: ex?.description ?? '');
    _prompt = TextEditingController(text: ex?.systemPrompt ?? '');
    _role = TextEditingController(text: ex?.role ?? '');
    _knowledge = TextEditingController(text: ex?.knowledgeIds.join(', ') ?? '');
    _maxSteps = TextEditingController(
        text: '${ex?.maxSteps ?? TgaAgent.defaultMaxSteps}');
    _modelId = TextEditingController(text: ex?.modelId ?? '');
    _permissions = TextEditingController(
        text: const JsonEncoder.withIndent('  ')
            .convert(ex?.permissions ?? TgaAgent.defaultPermissions()));
    _memoryScope = ex?.memoryScope ?? TgaAgent.scopeIsolated;
    _executionEnabled = ex?.executionEnabled ?? false;
  }

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    _prompt.dispose();
    _role.dispose();
    _knowledge.dispose();
    _maxSteps.dispose();
    _modelId.dispose();
    _permissions.dispose();
    super.dispose();
  }

  List<String> _parseKnowledgeIds() => _knowledge.text
      .split(RegExp(r'[,，\s]+'))
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toSet()
      .toList();

  void _snack(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      _snack('名称必填');
      return;
    }
    Map<String, dynamic> permissions;
    final String raw = _permissions.text.trim();
    try {
      final dynamic decoded =
          raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('permissions 必须是 JSON 对象');
      }
      permissions = decoded.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v));
    } on Object catch (e) {
      _snack('权限 JSON 解析失败：$e');
      return;
    }
    final String? permissionError =
        TgaAgent.validatePermissions(permissions);
    if (permissionError != null) {
      _snack('权限配置不合法：$permissionError');
      return;
    }
    final int steps =
        int.tryParse(_maxSteps.text.trim()) ?? TgaAgent.defaultMaxSteps;
    setState(() => _saving = true);
    final AgentsStore store = await AgentsStore.instance();
    final TgaAgent? ex = widget.existing;
    try {
      if (ex == null) {
        await store.create(
          name: _name.text,
          description: _desc.text,
          systemPrompt: _prompt.text,
          role: _role.text,
          knowledgeIds: _parseKnowledgeIds(),
          permissions: permissions,
          maxSteps: steps,
          executionEnabled: _executionEnabled,
          modelId: _modelId.text,
          memoryScope: _memoryScope,
        );
      } else {
        await store.update(ex.copyWith(
          name: _name.text,
          description: _desc.text,
          systemPrompt: _prompt.text,
          role: _role.text,
          knowledgeIds: _parseKnowledgeIds(),
          permissions: permissions,
          maxSteps: steps,
          executionEnabled: _executionEnabled,
          modelId: _modelId.text,
          memoryScope: _memoryScope,
        ));
      }
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(e.message?.toString() ?? '智能体配置不合法');
      return;
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
                      hintText: '如：翻译官、健身教练',
                      isDense: true,
                      counterText: ''),
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
                _fieldLabel('系统提示词（人设，「对话注入」开启后生效）'),
                TextField(
                  controller: _prompt,
                  maxLines: 8,
                  minLines: 4,
                  style: Tga.body,
                  decoration: const InputDecoration(
                      hintText: '例如：你是一名资深翻译，始终用简体中文回复，'
                          '翻译时保留原文格式并附术语表。',
                      isDense: true),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _fieldLabel('角色'),
                TextField(
                  controller: _role,
                  style: Tga.body,
                  decoration: const InputDecoration(
                      hintText: 'researcher / writer / reviewer / operator（可留空）',
                      isDense: true),
                ),
                const SizedBox(height: 14),
                _fieldLabel('绑定知识库 id（逗号分隔）'),
                TextField(
                  controller: _knowledge,
                  style: Tga.body,
                  decoration: const InputDecoration(
                      hintText: 'knowledge base 的 library id，如 kb-123, kb-456',
                      isDense: true),
                ),
                const SizedBox(height: 14),
                _fieldLabel('最大执行步数（1-20）'),
                TextField(
                  controller: _maxSteps,
                  keyboardType: TextInputType.number,
                  inputFormatters: <TextInputFormatter>[
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                  style: Tga.body,
                  decoration: const InputDecoration(
                      hintText: '1 - 20', isDense: true),
                ),
                const SizedBox(height: 14),
                _fieldLabel('偏好模型 id（可留空，留空沿用全局）'),
                TextField(
                  controller: _modelId,
                  style: Tga.body,
                  decoration: const InputDecoration(
                      hintText: '如 qwen2.5-7b-instruct', isDense: true),
                ),
                const SizedBox(height: 14),
                _fieldLabel('记忆作用域'),
                TgaSegmented<String>(
                  items: const <String>[
                    TgaAgent.scopeIsolated,
                    TgaAgent.scopeShared,
                  ],
                  value: _memoryScope,
                  labelOf: (String v) => v == TgaAgent.scopeShared
                      ? '共享（只读全局视图）'
                      : '独立（仅自己）',
                  onChanged: (String v) => setState(() => _memoryScope = v),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('允许作为子 Agent 被调度', style: Tga.body),
                    ),
                    Switch(
                      value: _executionEnabled,
                      onChanged: (bool v) =>
                          setState(() => _executionEnabled = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _fieldLabel('权限 JSON（tools / files 正则 / note）'),
                TextField(
                  controller: _permissions,
                  maxLines: 10,
                  minLines: 5,
                  style: TextStyle(
                      fontSize: 12,
                      color: Tga.text,
                      fontFamily: 'monospace',
                      height: 1.5),
                  decoration: const InputDecoration(
                      hintText: '{"tools":{"allow":["read_file"],'
                          '"ask":["write_file"],"deny":["shell"]},'
                          '"files":"^workspace/.*","note":""}',
                      isDense: true),
                ),
                const SizedBox(height: 8),
                Text(
                  '默认最小权限：不 allow 任何工具、deny 全部、无文件规则。'
                  'files 为正则字符串，只用于运行时判定，不会写入对话提示词。',
                  style: Tga.caption,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text('保存后在列表分别打开「对话注入」或「子 Agent 可调度」开关。',
                style: Tga.caption),
          ),
        ],
      ),
    );
  }

  Widget _fieldLabel(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: Tga.sub));
}
