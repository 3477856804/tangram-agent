import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 安全中心：审批队列 / 权限策略 / 审计日志。
///
/// 所有读写都经 `security_approval` 控制域真实下发（list / approve / deny /
/// policy_list / policy_set / policy_remove / policy_evaluate / audit_list /
/// audit_export），本页不缓存任何伪造记录，也不在本地推断审批或审计结果：
/// 后端未实现、未连接或返回异常时如实展示错误，列表为空时如实展示空态。
class TgaSecurityPage extends StatefulWidget {
  const TgaSecurityPage({super.key});

  @override
  State<TgaSecurityPage> createState() => _TgaSecurityPageState();
}

class _TgaSecurityPageState extends State<TgaSecurityPage> {
  // ---- ① 审批队列 ----
  List<Map<String, dynamic>> _approvals = <Map<String, dynamic>>[];
  bool _approvalsLoading = true;
  String _approvalsError = '';
  final Set<String> _approvalBusy = <String>{};

  // ---- ② 权限策略 ----
  List<Map<String, dynamic>> _rules = <Map<String, dynamic>>[];
  String _fallback = '';
  bool _policyLoading = true;
  String _policyError = '';
  bool _ruleSaving = false;
  String _ruleBusyId = '';

  final TextEditingController _newTool = TextEditingController();
  final TextEditingController _newPath = TextEditingController();
  final TextEditingController _newArgs = TextEditingController();
  final TextEditingController _newNote = TextEditingController();
  String _newDecision = 'ask';
  bool _newEnabled = true;

  // ---- 策略试算 ----
  final TextEditingController _evalTool = TextEditingController();
  final TextEditingController _evalPath = TextEditingController();
  final TextEditingController _evalArgs = TextEditingController();
  Map<String, dynamic>? _evalResult;
  String _evalError = '';
  bool _evalBusy = false;

  // ---- ③ 审计日志 ----
  List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];
  bool _auditLoading = true;
  String _auditError = '';
  bool _exportBusy = false;
  bool _chainBusy = false;
  Map<String, dynamic>? _chainResult;
  final TextEditingController _auditFilter = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_loadApprovals());
    unawaited(_loadPolicy());
    unawaited(_loadAudit());
  }

  @override
  void dispose() {
    _newTool.dispose();
    _newPath.dispose();
    _newArgs.dispose();
    _newNote.dispose();
    _evalTool.dispose();
    _evalPath.dispose();
    _evalArgs.dispose();
    _auditFilter.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // 通用工具
  // -------------------------------------------------------------------------

  Map<String, dynamic> _asMap(dynamic m) => m is Map
      ? m.map(
          (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v),
        )
      : <String, dynamic>{};

  List<Map<String, dynamic>> _mapList(dynamic raw) => raw is List
      ? raw
            .whereType<Map>()
            .map<Map<String, dynamic>>((Map e) => _asMap(e))
            .toList()
      : <Map<String, dynamic>>[];

  /// 调一次 security_approval：统一是 action + 扁平参数。
  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    final BackendClient backend = context.read<BackendClient>();
    final env = await backend.sendControl(
      'security_approval',
      <String, dynamic>{'action': action, ...payload},
    );
    final dynamic raw = env.payload;
    if (raw is! Map) {
      return <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
    }
    return _asMap(raw);
  }

  /// 后端未显式给 ok=false 且无 error 也视为成功（兼容裸 payload 返回）。
  bool _ok(Map<String, dynamic> p) =>
      p['ok'] == true || (p['ok'] == null && p['error'] == null);

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  double _tsValue(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0;
    return 0;
  }

  String _fmtTs(dynamic v) {
    if (v == null) return '时间未知';
    if (v is num && v > 0) {
      // 后端既有秒级时间戳，也兼容毫秒。
      final int ms = v > 1e11 ? v.round() : (v * 1000).round();
      final DateTime t = DateTime.fromMillisecondsSinceEpoch(ms);
      String two(int n) => n.toString().padLeft(2, '0');
      return '${t.year}-${two(t.month)}-${two(t.day)} '
          '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    }
    final String s = v.toString().trim();
    if (s.isEmpty) return '时间未知';
    return s.replaceFirst('T', ' ').split('.').first;
  }

  String _compact(dynamic v) {
    String s;
    if (v is Map || v is List) {
      try {
        s = jsonEncode(v);
      } on Object {
        s = v.toString();
      }
    } else {
      s = v.toString();
    }
    s = s.replaceAll('\n', ' ');
    return s.length > 180 ? '${s.substring(0, 180)}…' : s;
  }

  Color _decisionColor(String decision) {
    switch (decision.toLowerCase()) {
      case 'allow':
        return Tga.green;
      case 'deny':
        return Tga.red;
      case 'ask':
        return Tga.orange;
      default:
        return Tga.textSub;
    }
  }

  String _decisionLabel(String decision) {
    switch (decision.toLowerCase()) {
      case 'allow':
        return 'allow · 放行';
      case 'deny':
        return 'deny · 拒绝';
      case 'ask':
        return 'ask · 询问';
      default:
        return decision.isEmpty ? '未知' : decision;
    }
  }

  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'approved':
        return Tga.green;
      case 'denied':
        return Tga.red;
      case 'pending':
        return Tga.orange;
      default:
        return Tga.textSub;
    }
  }

  bool _enabledOf(Map<String, dynamic> rule) {
    final dynamic v = rule['enabled'];
    return v == true || v == 1;
  }

  Widget _loadingLine(String text) => Row(
    children: <Widget>[
      SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: Tga.primary),
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: Tga.sub)),
    ],
  );

  Widget _errorCard(String text, VoidCallback retry) => TgaCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(text, style: Tga.sub.copyWith(color: Tga.red)),
        const SizedBox(height: 10),
        TgaButton(
          label: '重试',
          icon: Icons.refresh_rounded,
          filled: false,
          onTap: retry,
        ),
      ],
    ),
  );

  Widget _kv(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(width: 64, child: Text(label, style: Tga.caption)),
        Expanded(child: Text(value, style: Tga.sub)),
      ],
    ),
  );

  // -------------------------------------------------------------------------
  // ① 审批队列
  // -------------------------------------------------------------------------

  Future<void> _loadApprovals() async {
    if (mounted) {
      setState(() {
        _approvalsLoading = true;
        _approvalsError = '';
      });
    }
    try {
      final Map<String, dynamic> p = await _call('list');
      if (!mounted) return;
      setState(() {
        _approvalsLoading = false;
        if (_ok(p) && p['approvals'] is List) {
          _approvals = _mapList(p['approvals']);
        } else {
          _approvals = <Map<String, dynamic>>[];
          _approvalsError = (p['error'] ?? '审批列表读取失败').toString();
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _approvalsLoading = false;
        _approvals = <Map<String, dynamic>>[];
        _approvalsError = '审批列表请求失败：$e';
      });
    }
  }

  Future<void> _decide(Map<String, dynamic> row, String action) async {
    final dynamic rawId = row['id'];
    final String id = (rawId ?? '').toString();
    if (id.isEmpty) {
      _toast('该审批记录缺少 id，无法操作');
      return;
    }
    final String key = '$action#$id';
    setState(() => _approvalBusy.add(key));
    try {
      final Map<String, dynamic> p = await _call(action, <String, dynamic>{
        'id': rawId,
      });
      if (!mounted) return;
      if (_ok(p)) {
        _toast(action == 'approve' ? '已批准 #$id' : '已拒绝 #$id');
        await _loadApprovals();
      } else {
        _toast((p['error'] ?? '操作失败').toString());
      }
    } on Object catch (e) {
      _toast('操作失败：$e');
    } finally {
      if (mounted) setState(() => _approvalBusy.remove(key));
    }
  }

  Widget _approvalCard(Map<String, dynamic> row) {
    final String status = (row['status'] ?? '').toString();
    final bool pending = status.toLowerCase() == 'pending';
    final String id = (row['id'] ?? '').toString();
    final bool approving = _approvalBusy.contains('approve#$id');
    final bool denying = _approvalBusy.contains('deny#$id');
    final bool busy = approving || denying;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    (row['action'] ?? '未命名操作').toString(),
                    style: Tga.body,
                  ),
                ),
                TgaTag(
                  status.isEmpty ? '状态未知' : status,
                  color: _statusColor(status),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                if (id.isNotEmpty) Text('#$id', style: Tga.caption),
                if (id.isNotEmpty) const SizedBox(width: 10),
                Text(_fmtTs(row['ts']), style: Tga.caption),
              ],
            ),
            if (pending) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TgaButton(
                    label: approving ? '批准中…' : '批准',
                    icon: Icons.check_rounded,
                    color: Tga.green,
                    onTap: busy
                        ? () {}
                        : () => unawaited(_decide(row, 'approve')),
                  ),
                  const SizedBox(width: 8),
                  TgaButton(
                    label: denying ? '拒绝中…' : '拒绝',
                    icon: Icons.close_rounded,
                    color: Tga.red,
                    filled: false,
                    onTap: busy ? () {} : () => unawaited(_decide(row, 'deny')),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _approvalsBlock() {
    if (_approvalsLoading) {
      return TgaCard(child: _loadingLine('正在读取审批队列…'));
    }
    if (_approvalsError.isNotEmpty) {
      return _errorCard(_approvalsError, () => unawaited(_loadApprovals()));
    }
    if (_approvals.isEmpty) {
      return TgaCard(
        child: TgaEmpty('暂无审批记录', icon: Icons.verified_user_outlined),
      );
    }
    return Column(
      children: <Widget>[
        for (final Map<String, dynamic> row in _approvals) _approvalCard(row),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // ② 权限策略
  // -------------------------------------------------------------------------

  Future<void> _loadPolicy() async {
    if (mounted) {
      setState(() {
        _policyLoading = true;
        _policyError = '';
      });
    }
    try {
      final Map<String, dynamic> p = await _call('policy_list');
      if (!mounted) return;
      setState(() {
        _policyLoading = false;
        if (_ok(p) && p['rules'] is List) {
          _rules = _mapList(p['rules']);
          _fallback = (p['fallback'] ?? '').toString();
        } else {
          _rules = <Map<String, dynamic>>[];
          _policyError = (p['error'] ?? '权限策略读取失败').toString();
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _policyLoading = false;
        _rules = <Map<String, dynamic>>[];
        _policyError = '权限策略请求失败：$e';
      });
    }
  }

  /// 把规则展开成扁平字段提交；新增时不带 id。
  Map<String, dynamic> _rulePayload(
    Map<String, dynamic> rule, {
    bool includeId = true,
  }) => <String, dynamic>{
    if (includeId && rule['id'] != null) 'id': rule['id'],
    'tool': (rule['tool'] ?? '').toString(),
    'path': (rule['path'] ?? '').toString(),
    'args': (rule['args'] ?? '').toString(),
    'decision': (rule['decision'] ?? 'ask').toString(),
    'enabled': _enabledOf(rule),
    'note': (rule['note'] ?? '').toString(),
  };

  Future<void> _setRuleEnabled(Map<String, dynamic> rule, bool enabled) async {
    final String id = (rule['id'] ?? '').toString();
    if (id.isEmpty) {
      _toast('该策略缺少 id，无法更新');
      return;
    }
    setState(() => _ruleBusyId = id);
    try {
      final Map<String, dynamic> payload = _rulePayload(rule);
      payload['enabled'] = enabled;
      final Map<String, dynamic> p = await _call('policy_set', payload);
      if (!mounted) return;
      if (_ok(p)) {
        await _loadPolicy();
        _toast(enabled ? '策略已启用' : '策略已停用');
      } else {
        _toast((p['error'] ?? '策略更新失败').toString());
      }
    } on Object catch (e) {
      _toast('策略更新失败：$e');
    } finally {
      if (mounted) setState(() => _ruleBusyId = '');
    }
  }

  Future<void> _removeRule(Map<String, dynamic> rule) async {
    final String id = (rule['id'] ?? '').toString();
    if (id.isEmpty) {
      _toast('该策略缺少 id，无法删除');
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('删除策略 #$id？', style: Tga.h2),
        content: Text(
          '将真实调用 policy_remove 删除该规则：\n'
          'tool=${(rule['tool'] ?? '').toString()} '
          'path=${(rule['path'] ?? '').toString()}',
          style: Tga.sub,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _ruleBusyId = id);
    try {
      final Map<String, dynamic> p = await _call(
        'policy_remove',
        <String, dynamic>{'id': rule['id']},
      );
      if (!mounted) return;
      if (_ok(p)) {
        await _loadPolicy();
        _toast('已删除策略 #$id');
      } else {
        _toast((p['error'] ?? '删除失败').toString());
      }
    } on Object catch (e) {
      _toast('删除失败：$e');
    } finally {
      if (mounted) setState(() => _ruleBusyId = '');
    }
  }

  Future<void> _addRule() async {
    final String tool = _newTool.text.trim();
    if (tool.isEmpty) {
      _toast('请填写工具名（tool）');
      return;
    }
    // 契约里 tool/path/args 都是正则；非空时先在本地校验，避免提交坏正则。
    for (final MapEntry<String, String> entry in <String, String>{
      'tool': tool,
      'path': _newPath.text.trim(),
      'args': _newArgs.text.trim(),
    }.entries) {
      if (entry.value.isEmpty) continue;
      try {
        RegExp(entry.value);
      } on FormatException catch (e) {
        _toast('${entry.key} 正则无效：${e.message}');
        return;
      }
    }
    setState(() => _ruleSaving = true);
    try {
      // 后端 policy_set 要求规则带 id：新增时用时间戳生成，更新走原 id。
      final String newId = 'rule-${DateTime.now().microsecondsSinceEpoch}';
      final Map<String, dynamic> p =
          await _call('policy_set', <String, dynamic>{
            'id': newId,
            'tool': tool,
            'path': _newPath.text.trim(),
            'args': _newArgs.text.trim(),
            'decision': _newDecision,
            'enabled': _newEnabled,
            'note': _newNote.text.trim(),
          });
      if (!mounted) return;
      if (_ok(p)) {
        _newTool.clear();
        _newPath.clear();
        _newArgs.clear();
        _newNote.clear();
        setState(() {
          _newDecision = 'ask';
          _newEnabled = true;
        });
        await _loadPolicy();
        _toast('策略已保存');
      } else {
        _toast((p['error'] ?? '策略保存失败').toString());
      }
    } on Object catch (e) {
      _toast('策略保存失败：$e');
    } finally {
      if (mounted) setState(() => _ruleSaving = false);
    }
  }

  Widget _ruleCard(Map<String, dynamic> rule) {
    final String id = (rule['id'] ?? '').toString();
    final bool enabled = _enabledOf(rule);
    final bool busy = _ruleBusyId.isNotEmpty && _ruleBusyId == id;
    final String decision = (rule['decision'] ?? 'ask').toString();
    final String tool = (rule['tool'] ?? '').toString();
    final String path = (rule['path'] ?? '').toString();
    final String args = (rule['args'] ?? '').toString();
    final String note = (rule['note'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(tool.isEmpty ? '（未限定工具）' : tool, style: Tga.body),
                ),
                TgaTag(
                  _decisionLabel(decision),
                  color: _decisionColor(decision),
                ),
              ],
            ),
            if (path.isNotEmpty) _kv('路径', path),
            if (args.isNotEmpty) _kv('参数', args),
            if (note.isNotEmpty) _kv('备注', note),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Text(id.isEmpty ? '无 id' : '#$id', style: Tga.caption),
                const Spacer(),
                Text(enabled ? '已启用' : '已停用', style: Tga.caption),
                Switch(
                  value: enabled,
                  activeColor: Tga.primary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: busy
                      ? null
                      : (bool v) => unawaited(_setRuleEnabled(rule, v)),
                ),
                const SizedBox(width: 4),
                TgaButton(
                  label: busy ? '处理中…' : '删除',
                  color: Tga.red,
                  filled: false,
                  onTap: busy ? () {} : () => unawaited(_removeRule(rule)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _newRuleCard() {
    return TgaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('新增 / 更新策略', style: Tga.h2),
          const SizedBox(height: 8),
          TextField(
            controller: _newTool,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: r'tool 正则，如 ^shell$',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _newPath,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: 'path 正则（可选，空表示不限路径）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _newArgs,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: 'args 正则（可选，对参数文本匹配）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: _newDecision,
            dropdownColor: Tga.card,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              labelText: '决策（decision）',
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem<String>(value: 'allow', child: Text('allow 放行')),
              DropdownMenuItem<String>(value: 'ask', child: Text('ask 询问')),
              DropdownMenuItem<String>(value: 'deny', child: Text('deny 拒绝')),
            ],
            onChanged: (String? v) => setState(() => _newDecision = v ?? 'ask'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _newNote,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: '备注（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Text('新增后启用', style: Tga.sub),
              Switch(
                value: _newEnabled,
                activeColor: Tga.primary,
                onChanged: (bool v) => setState(() => _newEnabled = v),
              ),
              const Spacer(),
              TgaButton(
                label: _ruleSaving ? '保存中…' : '保存策略',
                icon: Icons.save_rounded,
                onTap: _ruleSaving ? () {} : () => unawaited(_addRule()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _evaluatePolicy() async {
    final String tool = _evalTool.text.trim();
    if (tool.isEmpty) {
      _toast('试算需要填写 tool');
      return;
    }
    setState(() {
      _evalBusy = true;
      _evalError = '';
      _evalResult = null;
    });
    try {
      final Map<String, dynamic> p = await _call(
        'policy_evaluate',
        <String, dynamic>{
          'tool': tool,
          'path': _evalPath.text.trim(),
          'args': _evalArgs.text.trim(),
        },
      );
      if (!mounted) return;
      setState(() {
        _evalBusy = false;
        if (_ok(p)) {
          _evalResult = p;
        } else {
          _evalError = (p['error'] ?? '策略试算失败').toString();
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _evalBusy = false;
        _evalError = '策略试算请求失败：$e';
      });
    }
  }

  Widget _evalCard() {
    final Map<String, dynamic>? r = _evalResult;
    final String decision = (r?['decision'] ?? '').toString();
    final dynamic matched = r?['matched'];
    return TgaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('策略试算', style: Tga.h2),
          const SizedBox(height: 4),
          Text('按当前规则真实调用 policy_evaluate，不预判结果。', style: Tga.caption),
          const SizedBox(height: 8),
          TextField(
            controller: _evalTool,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: 'tool，如 shell',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _evalPath,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: 'path（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _evalArgs,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: 'args（可选，如 {"cmd":"rm -rf"}）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TgaButton(
              label: _evalBusy ? '试算中…' : '试算决策',
              icon: Icons.rule_rounded,
              onTap: _evalBusy ? () {} : () => unawaited(_evaluatePolicy()),
            ),
          ),
          if (_evalError.isNotEmpty) ...<Widget>[
            const Divider(height: 20),
            Text(_evalError, style: Tga.sub.copyWith(color: Tga.red)),
          ] else if (r != null) ...<Widget>[
            const Divider(height: 20),
            Row(
              children: <Widget>[
                TgaTag(
                  _decisionLabel(decision),
                  color: _decisionColor(decision),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    matched == null
                        ? '未命中规则，按 fallback：'
                              '${_fallback.isEmpty ? '未知' : _fallback}'
                        : '命中规则 #$matched',
                    style: Tga.sub,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _policyBlock() {
    final List<Widget> list = <Widget>[];
    if (_policyLoading) {
      list.add(TgaCard(child: _loadingLine('正在读取权限策略…')));
    } else if (_policyError.isNotEmpty) {
      list.add(_errorCard(_policyError, () => unawaited(_loadPolicy())));
    } else if (_rules.isEmpty) {
      list.add(
        TgaCard(child: TgaEmpty('暂无权限策略，可在下方新增', icon: Icons.rule_outlined)),
      );
    } else {
      for (final Map<String, dynamic> rule in _rules) {
        list.add(_ruleCard(rule));
      }
    }
    final String fallback = _fallback.isEmpty ? '未知' : _fallback;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TgaCard(
          child: Row(
            children: <Widget>[
              Expanded(child: Text('未命中任何规则时的默认决策（fallback）', style: Tga.sub)),
              TgaTag(
                _decisionLabel(fallback),
                color: _fallback.isEmpty
                    ? Tga.textSub
                    : _decisionColor(fallback),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ...list,
        const SizedBox(height: 10),
        _newRuleCard(),
        const SizedBox(height: 10),
        _evalCard(),
      ],
    );
  }

  // -------------------------------------------------------------------------
  // ③ 审计日志
  // -------------------------------------------------------------------------

  Future<void> _loadAudit() async {
    if (mounted) {
      setState(() {
        _auditLoading = true;
        _auditError = '';
      });
    }
    try {
      final Map<String, dynamic> p = await _call('audit_list');
      if (!mounted) return;
      setState(() {
        _auditLoading = false;
        if (_ok(p) && p['events'] is List) {
          final List<Map<String, dynamic>> events = _mapList(p['events']);
          // 后端按时间升序返回；页面按「最近事件」倒序展示。
          events.sort(
            (Map<String, dynamic> a, Map<String, dynamic> b) =>
                _tsValue(b['ts']).compareTo(_tsValue(a['ts'])),
          );
          _events = events;
        } else {
          _events = <Map<String, dynamic>>[];
          _auditError = (p['error'] ?? '审计日志读取失败').toString();
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _auditLoading = false;
        _events = <Map<String, dynamic>>[];
        _auditError = '审计日志请求失败：$e';
      });
    }
  }

  List<Map<String, dynamic>> get _filteredEvents {
    final String q = _auditFilter.text.trim().toLowerCase();
    if (q.isEmpty) return _events;
    return _events.where((Map<String, dynamic> e) {
      final String category = (e['category'] ?? e['kind'] ?? '')
          .toString()
          .toLowerCase();
      return category.contains(q);
    }).toList();
  }

  Future<void> _exportAudit() async {
    setState(() => _exportBusy = true);
    try {
      final Map<String, dynamic> p = await _call('audit_export');
      if (!mounted) return;
      if (!_ok(p) || p['jsonl'] == null) {
        _toast((p['error'] ?? '导出失败：后端未返回 jsonl').toString());
        return;
      }
      final String jsonl = p['jsonl'].toString();
      if (jsonl.trim().isEmpty) {
        _toast('没有可导出的审计事件（jsonl 为空）');
        return;
      }
      final TextEditingController ctrl = TextEditingController(text: jsonl);
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) {
          Tga.syncFrom(ctx);
          return AlertDialog(
            backgroundColor: Tga.card,
            title: Text('审计日志 JSONL', style: Tga.h2),
            content: SizedBox(
              width: 540,
              height: 360,
              child: TextField(
                controller: ctrl,
                readOnly: true,
                maxLines: null,
                expands: true,
                style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  color: Tga.text,
                  height: 1.5,
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Tga.bgSoft,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: jsonl));
                  Navigator.pop(ctx);
                  _toast('已复制 JSONL 到剪贴板');
                },
                child: const Text('复制'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      );
      ctrl.dispose();
    } on Object catch (e) {
      _toast('导出失败：$e');
    } finally {
      if (mounted) setState(() => _exportBusy = false);
    }
  }

  Widget _eventCard(Map<String, dynamic> event) {
    final String category = (event['category'] ?? event['kind'] ?? '')
        .toString();
    const Set<String> skip = <String>{'category', 'kind', 'ts', 'id'};
    final List<MapEntry<String, dynamic>> fields = event.entries
        .where(
          (MapEntry<String, dynamic> e) =>
              !skip.contains(e.key) &&
              e.value != null &&
              e.value.toString().trim().isNotEmpty,
        )
        .take(6)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TgaCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                TgaTag(category.isEmpty ? '未分类' : category, color: Tga.cyan),
                const SizedBox(width: 8),
                Text(_fmtTs(event['ts']), style: Tga.caption),
                const Spacer(),
                if ((event['id'] ?? '').toString().isNotEmpty)
                  Text('#${event['id']}', style: Tga.caption),
              ],
            ),
            const SizedBox(height: 6),
            if (fields.isEmpty)
              Text('（该事件无更多字段）', style: Tga.sub)
            else
              for (final MapEntry<String, dynamic> field in fields)
                _kv(field.key, _compact(field.value)),
          ],
        ),
      ),
    );
  }

  String _chainLabel() {
    final Map<String, dynamic>? r = _chainResult;
    if (r == null) return '校验 append-only 哈希链，检测日志是否被改写';
    final String reason = (r['reason'] ?? '').toString().trim();
    if (r['ok'] != true) {
      // 失败时如实带上后端原因与断点；字段缺失则逐级降级，不伪造位置。
      final String why = reason.isNotEmpty
          ? reason
          : (r['error'] ?? '').toString().trim();
      final String broken = (r['broken_at'] ?? '').toString().trim();
      final String head = '链校验失败：${why.isEmpty ? '原因未知' : why}';
      return broken.isEmpty ? head : '$head（断点 #$broken）';
    }
    return '链校验通过：${r['total'] ?? 0} 条'
        '${(r['legacy'] ?? 0) == 0 ? '' : '（旧格式 ${r['legacy']} 条已跳过）'}'
        '${reason.isEmpty ? '' : '（$reason）'}';
  }

  Future<void> _verifyChain() async {
    setState(() {
      _chainBusy = true;
      _chainResult = null;
    });
    try {
      final Map<String, dynamic> p = await _call('audit_verify');
      final Object? raw = p['result'];
      final Map<String, dynamic> result = raw is Map
          ? raw.map((Object? k, Object? v) => MapEntry(k.toString(), v))
          : p;
      if (!mounted) return;
      setState(() => _chainResult = result);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _chainResult = <String, dynamic>{'ok': false, 'error': '$e'});
    } finally {
      if (mounted) setState(() => _chainBusy = false);
    }
  }

  Widget _auditBlock() {
    final List<Map<String, dynamic>> rows = _filteredEvents;
    final List<Widget> list = <Widget>[];
    if (_auditLoading) {
      list.add(TgaCard(child: _loadingLine('正在读取审计日志…')));
    } else if (_auditError.isNotEmpty) {
      list.add(_errorCard(_auditError, () => unawaited(_loadAudit())));
    } else if (_events.isEmpty) {
      list.add(
        TgaCard(child: TgaEmpty('暂无审计事件', icon: Icons.receipt_long_outlined)),
      );
    } else if (rows.isEmpty) {
      list.add(
        TgaCard(
          child: TgaEmpty(
            '没有 category 匹配「${_auditFilter.text.trim()}」的事件',
            icon: Icons.filter_alt_off_outlined,
          ),
        ),
      );
    } else {
      for (final Map<String, dynamic> event in rows) {
        list.add(_eventCard(event));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        TgaCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '最近 ${_events.length} 条事件，按 category 本地过滤'
                      '（当前 ${rows.length} 条）',
                      style: Tga.caption,
                    ),
                  ),
                  TgaButton(
                    label: _exportBusy ? '导出中…' : '导出 JSONL',
                    icon: Icons.download_rounded,
                    onTap: _exportBusy
                        ? () {}
                        : () => unawaited(_exportAudit()),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TgaSearchField(
                hint: '按 category 过滤，如 approval',
                controller: _auditFilter,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  TgaButton(
                    label: _chainBusy ? '校验中…' : '校验审计链',
                    icon: Icons.verified_user_outlined,
                    onTap: _chainBusy
                        ? () {}
                        : () => unawaited(_verifyChain()),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(_chainLabel(), style: Tga.caption)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ...list,
      ],
    );
  }

  // -------------------------------------------------------------------------
  // 页面
  // -------------------------------------------------------------------------

  Future<void> _refreshAll() async {
    await Future.wait(<Future<void>>[
      _loadApprovals(),
      _loadPolicy(),
      _loadAudit(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '安全中心',
      actions: <Widget>[
        IconButton(
          onPressed: () => unawaited(_refreshAll()),
          tooltip: '刷新全部',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          TgaCard(
            child: Text(
              '全部数据经 security_approval 控制域实时读写：审批、策略与审计均由'
              '后端真实落盘。后端未实现或不可达时，下方如实展示错误，不填充假记录。',
              style: Tga.caption,
            ),
          ),
          TgaGroupTitle(
            '① 审批队列（${_approvals.length} 条）',
            trailing: TgaButton(
              label: '刷新',
              icon: Icons.refresh_rounded,
              onTap: () => unawaited(_loadApprovals()),
            ),
          ),
          _approvalsBlock(),
          TgaGroupTitle(
            '② 权限策略（${_rules.length} 条）',
            trailing: TgaButton(
              label: '刷新',
              icon: Icons.refresh_rounded,
              onTap: () => unawaited(_loadPolicy()),
            ),
          ),
          _policyBlock(),
          TgaGroupTitle(
            '③ 审计日志',
            trailing: TgaButton(
              label: '刷新',
              icon: Icons.refresh_rounded,
              onTap: () => unawaited(_loadAudit()),
            ),
          ),
          _auditBlock(),
        ],
      ),
    );
  }
}
