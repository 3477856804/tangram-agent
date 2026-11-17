import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 认知工作台：澄清提问 / 风险扫描 / 方案对比 / 决策日志。
///
/// 全部请求走 `super_agent` 控制域（clarify / risk_scan / options /
/// decision_log / log_decision），不在这里 new SuperAgent，也不在本页做任何
/// 推理兜底：模型未配置或回复无法解析时，如实展示 unstructured / 降级原因，
/// 绝不伪造问题、风险或路线。
class TgaCognitionPage extends StatefulWidget {
  const TgaCognitionPage({super.key});

  @override
  State<TgaCognitionPage> createState() => _TgaCognitionPageState();
}

// ---------------------------------------------------------------------------
// 纯逻辑（供单测，不依赖网络 / Provider）
// ---------------------------------------------------------------------------

/// 风险等级颜色：critical/high 红、medium 橙、low 绿、未知灰。
Color riskLevelColor(String level) {
  switch (level.toLowerCase()) {
    case 'critical':
    case 'high':
      return const Color(0xFFE8585B);
    case 'medium':
      return const Color(0xFFF0A02C);
    case 'low':
      return const Color(0xFF2FAE74);
    default:
      return const Color(0xFFA3AEBD);
  }
}

String riskLevelLabel(String level) {
  switch (level.toLowerCase()) {
    case 'critical':
      return '极高';
    case 'high':
      return '高';
    case 'medium':
      return '中';
    case 'low':
      return '低';
    default:
      return level.isEmpty ? '未知' : level;
  }
}

/// 一条路线是否信息完整：名称、收益、代价、风险、适用场景、取舍都要有。
bool optionIsComplete(Map<String, dynamic> option) {
  bool hasList(dynamic v) => v is List && v.isNotEmpty;
  final String name = (option['name'] ?? '').toString().trim();
  final String fit = (option['fit'] ?? '').toString().trim();
  final String tradeoff = (option['tradeoff'] ?? '').toString().trim();
  return name.isNotEmpty &&
      fit.isNotEmpty &&
      tradeoff.isNotEmpty &&
      hasList(option['benefits']) &&
      hasList(option['costs']) &&
      hasList(option['risks']);
}

int completeOptionCount(List<Map<String, dynamic>> options) =>
    options.where(optionIsComplete).length;

/// 方案对比要求 2-3 条路线（模型给少了不补齐）。
bool meetsRouteRange(int count) => count >= 2 && count <= 3;

/// 结构化结论缺失时的如实说明；正常结构化返回空串。
String cognitionDegradationNote(Map<String, dynamic> result) {
  if (result['structured'] == true) return '';
  final String engine = (result['engine'] ?? '').toString().trim();
  final bool degraded = result['degraded'] == true;
  return '未获得结构化结论（engine=${engine.isEmpty ? '未知' : engine}'
      '${degraded ? '，已降级' : ''}）；以下不展示伪造结论。';
}

/// 风险扫描里模型补充未解析时的说明；规则结果仍然有效。
String riskScanModelNote(Map<String, dynamic> result) {
  if (result['model_structured'] == true) return '';
  final String engine = (result['engine'] ?? '').toString().trim();
  return '模型补充未解析（engine=${engine.isEmpty ? '未知' : engine}）；'
      '下方只展示确定性规则命中的结果。';
}

class _TgaCognitionPageState extends State<TgaCognitionPage> {
  final TextEditingController _clarifyGoal = TextEditingController();
  final TextEditingController _clarifyContext = TextEditingController();
  final TextEditingController _riskGoal = TextEditingController();
  final TextEditingController _riskTools = TextEditingController();
  final TextEditingController _optionGoal = TextEditingController();
  final TextEditingController _optionContext = TextEditingController();
  final TextEditingController _optionConstraints = TextEditingController();

  Map<String, dynamic>? _clarifyResult;
  Map<String, dynamic>? _riskResult;
  Map<String, dynamic>? _optionResult;
  String _clarifyError = '';
  String _riskError = '';
  String _optionError = '';

  List<Map<String, dynamic>> _decisionLog = <Map<String, dynamic>>[];
  String _decisionError = '';

  bool _clarifyBusy = false;
  bool _riskBusy = false;
  bool _optionBusy = false;
  bool _decisionBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDecisionLog());
  }

  @override
  void dispose() {
    _clarifyGoal.dispose();
    _clarifyContext.dispose();
    _riskGoal.dispose();
    _riskTools.dispose();
    _optionGoal.dispose();
    _optionContext.dispose();
    _optionConstraints.dispose();
    super.dispose();
  }

  Map<String, dynamic> _asMap(dynamic m) => m is Map
      ? m.map((dynamic k, dynamic v) =>
          MapEntry<String, dynamic>(k.toString(), v))
      : <String, dynamic>{};

  List<Map<String, dynamic>> _mapList(dynamic raw) => raw is List
      ? raw
          .whereType<Map>()
          .map<Map<String, dynamic>>((Map e) => _asMap(e))
          .toList()
      : <Map<String, dynamic>>[];

  List<String> _strList(dynamic raw) =>
      raw is List ? raw.map((dynamic e) => e.toString()).toList() : <String>[];

  List<String> _splitList(String text) => text
      .split(RegExp(r'[,，、\s]+'))
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList();

  Future<Map<String, dynamic>> _call(
      String action, Map<String, dynamic> extra) async {
    final BackendClient backend = context.read<BackendClient>();
    final env = await backend.sendControl(
        'super_agent', <String, dynamic>{'action': action, ...extra});
    return _asMap(env.payload);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _runClarify() async {
    final String goal = _clarifyGoal.text.trim();
    if (goal.isEmpty) {
      _toast('请先填写要澄清的目标');
      return;
    }
    setState(() {
      _clarifyBusy = true;
      _clarifyError = '';
    });
    try {
      final Map<String, dynamic> p = await _call('clarify', <String, dynamic>{
        'goal': goal,
        'context': _clarifyContext.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _clarifyBusy = false;
        if (p['ok'] == true) {
          _clarifyResult = p;
        } else {
          _clarifyResult = null;
          _clarifyError = (p['error'] ?? '澄清失败').toString();
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _clarifyBusy = false;
        _clarifyResult = null;
        _clarifyError = '请求失败：$e';
      });
    }
  }

  Future<void> _runRiskScan() async {
    final String goal = _riskGoal.text.trim();
    if (goal.isEmpty) {
      _toast('请先填写要扫描的目标');
      return;
    }
    setState(() {
      _riskBusy = true;
      _riskError = '';
    });
    try {
      final Map<String, dynamic> p = await _call('risk_scan', <String, dynamic>{
        'goal': goal,
        'tools': _splitList(_riskTools.text),
      });
      if (!mounted) return;
      setState(() {
        _riskBusy = false;
        if (p['ok'] == true) {
          _riskResult = p;
        } else {
          _riskResult = null;
          _riskError = (p['error'] ?? '风险扫描失败').toString();
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _riskBusy = false;
        _riskResult = null;
        _riskError = '请求失败：$e';
      });
    }
  }

  Future<void> _runOptions() async {
    final String goal = _optionGoal.text.trim();
    if (goal.isEmpty) {
      _toast('请先填写要对比的目标');
      return;
    }
    setState(() {
      _optionBusy = true;
      _optionError = '';
    });
    try {
      final Map<String, dynamic> p = await _call('options', <String, dynamic>{
        'goal': goal,
        'context': _optionContext.text.trim(),
        'constraints': _splitList(_optionConstraints.text),
      });
      if (!mounted) return;
      setState(() {
        _optionBusy = false;
        if (p['ok'] == true) {
          _optionResult = p;
        } else {
          _optionResult = null;
          _optionError = (p['error'] ?? '方案生成失败').toString();
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _optionBusy = false;
        _optionResult = null;
        _optionError = '请求失败：$e';
      });
    }
  }

  Future<void> _loadDecisionLog() async {
    setState(() => _decisionBusy = true);
    try {
      final Map<String, dynamic> p = await _call(
          'decision_log', <String, dynamic>{'limit': 30});
      if (!mounted) return;
      setState(() {
        _decisionBusy = false;
        if (p['ok'] == true) {
          _decisionLog = _mapList(p['decision_log']);
          _decisionError = '';
        } else {
          _decisionError = (p['error'] ?? '决策日志读取失败').toString();
        }
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _decisionBusy = false;
        _decisionError = '决策日志请求失败：$e';
      });
    }
  }

  Future<void> _showLogDecision() async {
    final TextEditingController choice = TextEditingController();
    final TextEditingController reason = TextEditingController();
    final TextEditingController considered = TextEditingController();
    final TextEditingController constraints = TextEditingController();
    final TextEditingController rejected = TextEditingController();
    final TextEditingController ticket = TextEditingController();
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('记录一次决策', style: Tga.h2),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: choice,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '决策结论（必填）'),
              ),
              TextField(
                controller: reason,
                maxLines: 2,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '决策理由'),
              ),
              TextField(
                controller: considered,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(
                    hintText: '考虑过的选项（逗号分隔）'),
              ),
              TextField(
                controller: constraints,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(
                    hintText: '约束条件（逗号分隔）'),
              ),
              TextField(
                controller: rejected,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(
                    hintText: '已否决的方案（逗号分隔）'),
              ),
              TextField(
                controller: ticket,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(
                    hintText: '关联工单 id（可选）'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: Tga.textSub)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final String choiceText = choice.text.trim();
    final Map<String, dynamic> payload = <String, dynamic>{
      'choice': choiceText,
      'reason': reason.text.trim(),
      'options_considered': _splitList(considered.text),
      'constraints': _splitList(constraints.text),
      'rejected': _splitList(rejected.text),
      'ticket_id': ticket.text.trim(),
    };
    choice.dispose();
    reason.dispose();
    considered.dispose();
    constraints.dispose();
    rejected.dispose();
    ticket.dispose();
    if (go != true || !mounted) return;
    if (choiceText.isEmpty) {
      _toast('决策结论不能为空');
      return;
    }
    try {
      final Map<String, dynamic> p = await _call('log_decision', payload);
      if (!mounted) return;
      _toast(p['ok'] == true
          ? '决策已写入决策日志'
          : (p['error'] ?? '写入失败').toString());
      await _loadDecisionLog();
    } on Object catch (e) {
      _toast('写入失败：$e');
    }
  }

  Widget _errorLine(String text) => Text(text,
      style: Tga.sub.copyWith(color: Tga.red));

  List<Widget> _listSection(String title, List<String> items) {
    if (items.isEmpty) return <Widget>[];
    return <Widget>[
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(title, style: Tga.body),
      ),
      for (final String item in items)
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('· ', style: Tga.sub),
              Expanded(child: Text(item, style: Tga.sub)),
            ],
          ),
        ),
    ];
  }

  Widget _clarifyBlock() {
    final Map<String, dynamic>? r = _clarifyResult;
    final List<Widget> result = <Widget>[];
    if (_clarifyError.isNotEmpty) {
      result.add(_errorLine(_clarifyError));
    } else if (r == null) {
      result.add(Text('尚未运行澄清：填写目标后点击「生成澄清问题」。', style: Tga.sub));
    } else {
      final String note = cognitionDegradationNote(r);
      result.add(Row(
        children: <Widget>[
          TgaTag('engine ${(r['engine'] ?? '').toString().isEmpty ? '未知' : r['engine']}'),
          const SizedBox(width: 6),
          TgaTag(r['structured'] == true ? '结构化' : 'unstructured',
              color: r['structured'] == true ? Tga.green : Tga.orange),
          if (r['degraded'] == true) ...<Widget>[
            const SizedBox(width: 6),
            TgaTag('降级', color: Tga.red),
          ],
        ],
      ));
      if (note.isNotEmpty) {
        result.addAll(<Widget>[
          const SizedBox(height: 8),
          Text(note, style: Tga.sub.copyWith(color: Tga.orange)),
          const SizedBox(height: 4),
          Text(
            '原始回复：${((_asMap(r['clarification'])['raw']) ?? '').toString()}',
            style: Tga.caption,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
          ),
        ]);
      } else {
        result.addAll(<Widget>[
          ..._listSection('待确认问题', _strList(r['questions'])),
          if ((r['implicit_goal'] ?? '').toString().trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text('隐性目标', style: Tga.body),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text((r['implicit_goal'] ?? '').toString(), style: Tga.sub),
            ),
          ],
          ..._listSection('缺失条件', _strList(r['missing_conditions'])),
          ..._listSection('验收标准', _strList(r['acceptance_criteria'])),
          if (_strList(r['questions']).isEmpty &&
              _strList(r['missing_conditions']).isEmpty &&
              _strList(r['acceptance_criteria']).isEmpty &&
              (r['implicit_goal'] ?? '').toString().trim().isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('结构化结果为空：需要补充目标上下文后重试。', style: Tga.sub),
            ),
        ]);
      }
    }
    return TgaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _clarifyGoal,
            maxLines: 2,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: '要澄清的目标，如「优化登录流程」',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _clarifyContext,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: '已知上下文（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TgaButton(
            label: _clarifyBusy ? '澄清中…' : '生成澄清问题',
            icon: Icons.help_outline_rounded,
            onTap: _clarifyBusy ? () {} : () => unawaited(_runClarify()),
          ),
          const Divider(height: 24),
          ...result,
        ],
      ),
    );
  }

  Widget _riskBlock() {
    final Map<String, dynamic>? r = _riskResult;
    final List<Widget> result = <Widget>[];
    if (_riskError.isNotEmpty) {
      result.add(_errorLine(_riskError));
    } else if (r == null) {
      result.add(Text('尚未运行风险扫描：填写目标（可带拟用工具）后开始。', style: Tga.sub));
    } else {
      final List<Map<String, dynamic>> risks = _mapList(r['risks']);
      result.add(Row(
        children: <Widget>[
          TgaTag(r['high_risk'] == true ? '存在高危' : '无高危',
              color: r['high_risk'] == true ? Tga.red : Tga.green),
          const SizedBox(width: 6),
          TgaTag('${risks.length} 条', color: Tga.textSub),
          if (r['audit_logged'] == true) ...<Widget>[
            const SizedBox(width: 6),
            TgaTag('已写审计', color: Tga.primary),
          ],
        ],
      ));
      final String modelNote = riskScanModelNote(r);
      if (modelNote.isNotEmpty) {
        result.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(modelNote, style: Tga.caption),
        ));
      }
      if (risks.isEmpty) {
        result.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('未发现规则风险或模型补充。', style: Tga.sub),
        ));
      } else {
        for (final Map<String, dynamic> risk in risks) {
          result.add(Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Tga.bgSoft,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: riskLevelColor(
                            (risk['level'] ?? '').toString())
                        .withValues(alpha: 0.35)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      TgaTag(
                        riskLevelLabel((risk['level'] ?? '').toString()),
                        color: riskLevelColor(
                            (risk['level'] ?? '').toString()),
                      ),
                      const SizedBox(width: 6),
                      TgaTag((risk['type'] ?? '').toString(),
                          color: Tga.textSub),
                      const Spacer(),
                      Text(
                        (risk['source'] ?? '').toString() == 'model'
                            ? '模型补充'
                            : '规则命中',
                        style: Tga.caption,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text((risk['detail'] ?? '').toString(), style: Tga.sub),
                  if ((risk['mitigation'] ?? '').toString().trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '规避建议：${risk['mitigation']}',
                        style: Tga.caption.copyWith(color: Tga.primary),
                      ),
                    ),
                ],
              ),
            ),
          ));
        }
      }
    }
    return TgaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _riskGoal,
            maxLines: 2,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: '要扫描的目标/动作，如「批量删除生产数据」',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _riskTools,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: '拟使用工具（逗号分隔，如 shell, chat）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TgaButton(
            label: _riskBusy ? '扫描中…' : '扫描风险',
            icon: Icons.shield_outlined,
            onTap: _riskBusy ? () {} : () => unawaited(_runRiskScan()),
          ),
          const Divider(height: 24),
          ...result,
        ],
      ),
    );
  }

  Widget _optionsBlock() {
    final Map<String, dynamic>? r = _optionResult;
    final List<Widget> result = <Widget>[];
    if (_optionError.isNotEmpty) {
      result.add(_errorLine(_optionError));
    } else if (r == null) {
      result.add(Text('尚未生成方案：填写目标后请求 2-3 条互不相同的路线。', style: Tga.sub));
    } else {
      final List<Map<String, dynamic>> options = _mapList(r['options']);
      final String note = cognitionDegradationNote(r);
      result.add(Row(
        children: <Widget>[
          TgaTag('${options.length} 条路线',
              color: meetsRouteRange(options.length) ? Tga.green : Tga.orange),
          const SizedBox(width: 6),
          TgaTag('完整 ${completeOptionCount(options)}/${options.length}',
              color: Tga.textSub),
        ],
      ));
      if (note.isNotEmpty) {
        result.addAll(<Widget>[
          const SizedBox(height: 6),
          Text(note, style: Tga.sub.copyWith(color: Tga.orange)),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '原始回复：${((_asMap(r['report'])['raw']) ?? '').toString()}',
              style: Tga.caption,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]);
      }
      if (options.isEmpty) {
        result.add(Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('没有可用路线：模型未返回结构化方案，请补充上下文后重试。',
              style: Tga.sub),
        ));
      } else {
        for (final Map<String, dynamic> option in options) {
          result.add(Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Tga.bgSoft,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Tga.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          (option['name'] ?? '').toString().isEmpty
                              ? '（未命名路线）'
                              : option['name'].toString(),
                          style: Tga.h2,
                        ),
                      ),
                      TgaTag(optionIsComplete(option) ? '信息完整' : '信息不全',
                          color: optionIsComplete(option)
                              ? Tga.green
                              : Tga.orange),
                    ],
                  ),
                  ..._listSection('收益', _strList(option['benefits'])),
                  ..._listSection('代价', _strList(option['costs'])),
                  ..._listSection('风险', _strList(option['risks'])),
                  if ((option['fit'] ?? '').toString().trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('适用：${option['fit']}', style: Tga.caption),
                    ),
                  if ((option['tradeoff'] ?? '').toString().trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('取舍：${option['tradeoff']}',
                          style: Tga.caption),
                    ),
                ],
              ),
            ),
          ));
        }
        final String recommendation =
            (r['recommendation'] ?? '').toString().trim();
        if (recommendation.isNotEmpty) {
          result.addAll(<Widget>[
            const SizedBox(height: 10),
            Text('推荐', style: Tga.body),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(recommendation, style: Tga.sub),
            ),
          ]);
        }
      }
    }
    return TgaCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _optionGoal,
            maxLines: 2,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: '要对比的目标，如「选择登录修复路线」',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _optionContext,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: '已知上下文（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _optionConstraints,
            style: TextStyle(color: Tga.text),
            decoration: const InputDecoration(
              hintText: '约束（逗号分隔，可选）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TgaButton(
            label: _optionBusy ? '生成中…' : '对比 2-3 条路线',
            icon: Icons.alt_route,
            onTap: _optionBusy ? () {} : () => unawaited(_runOptions()),
          ),
          const Divider(height: 24),
          ...result,
        ],
      ),
    );
  }

  Widget _decisionBlock() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_decisionError.isNotEmpty)
          TgaCard(child: _errorLine(_decisionError)),
        if (_decisionLog.isEmpty)
          TgaCard(
            child: TgaEmpty(
              _decisionBusy ? '读取中…' : '暂无决策记录\n点击右上角「记录决策」写入第一条',
              icon: Icons.history_rounded,
            ),
          )
        else
          for (final Map<String, dynamic> entry in _decisionLog)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TgaCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        TgaTag(
                          (entry['kind'] ?? 'decision').toString() ==
                                  'implicit_goal'
                              ? '隐性目标'
                              : '决策',
                          color: (entry['kind'] ?? '') == 'implicit_goal'
                              ? Tga.purple
                              : Tga.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            (entry['choice'] ??
                                    entry['implicit_goal'] ??
                                    '（无结论）')
                                .toString(),
                            style: Tga.body,
                          ),
                        ),
                        Text(
                          (entry['ts'] ?? '')
                              .toString()
                              .replaceFirst('T', ' ')
                              .split('.')
                              .first,
                          style: Tga.caption,
                        ),
                      ],
                    ),
                    if ((entry['reason'] ?? '').toString().trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('理由：${entry['reason']}', style: Tga.sub),
                      ),
                    if (_strList(entry['options_considered']).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          '考虑过：${_strList(entry['options_considered']).join(' / ')}',
                          style: Tga.caption,
                        ),
                      ),
                    if (_strList(entry['rejected']).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '已否决：${_strList(entry['rejected']).join(' / ')}',
                          style: Tga.caption,
                        ),
                      ),
                    if (_strList(entry['constraints']).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '约束：${_strList(entry['constraints']).join(' / ')}',
                          style: Tga.caption,
                        ),
                      ),
                    if ((entry['ticket_id'] ?? '').toString().trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('工单：${entry['ticket_id']}',
                            style: Tga.caption),
                      ),
                  ],
                ),
              ),
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return TgaPage(
      title: '认知工作台',
      actions: <Widget>[
        IconButton(
          tooltip: '记录决策',
          onPressed: _showLogDecision,
          icon: Icon(Icons.edit_note_rounded, color: Tga.primary),
        ),
        IconButton(
          tooltip: '刷新决策日志',
          onPressed: _decisionBusy ? null : () => unawaited(_loadDecisionLog()),
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          TgaCard(
            child: Text(
              '认知闭环全部调用 super_agent 控制域。模型未配置或回复无法解析时，'
              '页面如实标注 unstructured / 降级原因，不补写问题、风险或路线。',
              style: Tga.caption,
            ),
          ),
          const TgaGroupTitle('① 澄清提问（clarify）'),
          _clarifyBlock(),
          const TgaGroupTitle('② 风险扫描（risk_scan）'),
          _riskBlock(),
          const TgaGroupTitle('③ 方案对比（options）'),
          _optionsBlock(),
          TgaGroupTitle(
            '④ 决策日志（${_decisionLog.length} 条）',
            trailing: TgaButton(
              label: '记录决策',
              icon: Icons.add_rounded,
              onTap: _showLogDecision,
            ),
          ),
          _decisionBlock(),
        ],
      ),
    );
  }
}
