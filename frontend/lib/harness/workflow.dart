/// 可视化工作流 / 批量自动化引擎。
///
/// 工作流是**真实可执行**的步骤序列，不是示意图：
///  * `prompt` 步骤走对话推理；
///  * `shell` 步骤走当前沙箱真实 shell（退出码非 0 视为失败）；
///  * `knowledge` 步骤走私有知识库检索。
/// 步骤输出可通过 `{{变量名}}` 在后续步骤引用；`save_as` 把输出写入变量。
///
/// 所有定义与运行记录落盘（`workflows.json` / `workflow_runs.json`），
/// 支持 JSON 导入导出、每日定时触发标记与批量输入。没有可用执行器时如实失败，
/// 不伪造步骤成功。

import 'dart:async';
import 'dart:convert';

import 'store.dart';

typedef WorkflowChat = Future<Map<String, dynamic>> Function(Map<String, dynamic>);
typedef WorkflowShell = Future<Map<String, dynamic>> Function(
    String command, String cwd);
typedef WorkflowKnowledge = Future<String> Function(String query);

class WorkflowEngine {
  WorkflowEngine(
    this.store, {
    required this.chat,
    required this.shell,
    this.knowledge,
  });

  final HarnessStore store;
  final WorkflowChat chat;
  final WorkflowShell shell;
  final WorkflowKnowledge? knowledge;

  static const String _file = 'workflows.json';

  Map<String, dynamic>? _cache;

  Future<Map<String, dynamic>> _load() async {
    final Map<String, dynamic>? c = _cache;
    if (c != null) return c;
    final Map<String, dynamic> raw =
        await store.readJson(_file, fallback: <String, dynamic>{
      'version': 1,
      'workflows': <dynamic>[],
    });
    raw['workflows'] = raw['workflows'] is List ? raw['workflows'] : <dynamic>[];
    _cache = raw;
    return raw;
  }

  Future<List<Map<String, dynamic>>> _defs() async {
    final Map<String, dynamic> data = await _load();
    return (data['workflows'] as List)
        .whereType<Map>()
        .map((Map e) => Map<String, dynamic>.from(e))
        .toList();
  }

  Future<void> _saveDefs(List<Map<String, dynamic>> list) async {
    final Map<String, dynamic> data = await _load();
    data['workflows'] = list;
    data['updated_at'] = DateTime.now().toIso8601String();
    await store.writeJson(_file, data);
  }

  Future<List<Map<String, dynamic>>> _runs() async =>
      (await store.readRecords('workflow_runs'));

  String _id(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    switch (action) {
      case 'list':
        final List<Map<String, dynamic>> list = await _defs();
        return <String, dynamic>{
          'ok': true,
          'workflows': list,
          'templates': templates(),
        };
      case 'get':
        return await _get(p);
      case 'save':
        return await _save(p);
      case 'delete':
        return await _delete(p);
      case 'run':
        return await _run(p);
      case 'batch':
        return await _batch(p);
      case 'runs':
        return <String, dynamic>{
          'ok': true,
          'runs': (await _runs()).reversed.take(80).toList(),
        };
      case 'run_detail':
        return await _runDetail(p);
      case 'templates':
        return <String, dynamic>{'ok': true, 'templates': templates()};
      case 'import':
        return await _import(p);
      case 'export':
        return await _export(p);
      case 'due':
        return await _due();
      default:
        return <String, dynamic>{'ok': false, 'error': '未知工作流动作：$action'};
    }
  }

  Future<Map<String, dynamic>> _get(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    for (final Map<String, dynamic> w in await _defs()) {
      if (w['id'] == id) return <String, dynamic>{'ok': true, 'workflow': w};
    }
    return <String, dynamic>{'ok': false, 'error': '工作流不存在'};
  }

  Future<Map<String, dynamic>> _save(Map<String, dynamic> p) async {
    final dynamic raw = p['workflow'];
    if (raw is! Map) {
      return <String, dynamic>{'ok': false, 'error': '缺少 workflow 定义'};
    }
    final Map<String, dynamic> input =
        raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    final String name = (input['name'] ?? '').toString().trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '工作流名称不能为空'};
    }
    final dynamic stepsRaw = input['steps'];
    if (stepsRaw is! List || stepsRaw.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '至少需要一个步骤'};
    }
    if (stepsRaw.length > 20) {
      return <String, dynamic>{'ok': false, 'error': '步骤上限 20 个'};
    }
    final List<Map<String, dynamic>> steps = <Map<String, dynamic>>[];
    for (int i = 0; i < stepsRaw.length; i++) {
      final dynamic s = stepsRaw[i];
      if (s is! Map) {
        return <String, dynamic>{'ok': false, 'error': '第 ${i + 1} 步格式无效'};
      }
      final Map<String, dynamic> step =
          s.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
      final String type = (step['type'] ?? 'prompt').toString();
      if (!<String>{'prompt', 'shell', 'knowledge'}.contains(type)) {
        return <String, dynamic>{
          'ok': false,
          'error': '第 ${i + 1} 步类型只支持 prompt / shell / knowledge',
        };
      }
      final String content =
          (step['input'] ?? step['content'] ?? '').toString().trim();
      if (content.isEmpty) {
        return <String, dynamic>{'ok': false, 'error': '第 ${i + 1} 步内容为空'};
      }
      steps.add(<String, dynamic>{
        'id': (step['id'] ?? 'step-${i + 1}').toString(),
        'name': (step['name'] ?? '第 ${i + 1} 步').toString(),
        'type': type,
        'input': content,
        'save_as': (step['save_as'] ?? '').toString(),
        'continue_on_error': step['continue_on_error'] == true,
      });
    }
    final List<Map<String, dynamic>> list = await _defs();
    final String id = (input['id'] ?? '').toString();
    final String now = DateTime.now().toIso8601String();
    Map<String, dynamic>? existing;
    for (final Map<String, dynamic> w in list) {
      if (w['id'] == id) {
        existing = w;
        break;
      }
    }
    final Map<String, dynamic> wf = <String, dynamic>{
      'id': id.isEmpty ? _id('wf') : id,
      'name': name,
      'description': (input['description'] ?? '').toString().trim(),
      'enabled': input['enabled'] != false,
      'steps': steps,
      'variables': input['variables'] is Map
          ? Map<String, dynamic>.from(input['variables'] as Map)
          : <String, dynamic>{},
      'triggers': input['triggers'] is Map
          ? Map<String, dynamic>.from(input['triggers'] as Map)
          : <String, dynamic>{'manual': true, 'schedule': ''},
      'created_at': existing?['created_at'] ?? now,
      'updated_at': now,
      'last_run_at': existing?['last_run_at'] ?? '',
      'last_status': existing?['last_status'] ?? '',
    };
    if (existing != null) {
      list[list.indexOf(existing)] = wf;
    } else {
      list.add(wf);
    }
    await _saveDefs(list);
    return <String, dynamic>{'ok': true, 'workflow': wf};
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final List<Map<String, dynamic>> list = await _defs();
    final int before = list.length;
    list.removeWhere((Map<String, dynamic> w) => w['id'] == id);
    if (list.length == before) {
      return <String, dynamic>{'ok': false, 'error': '工作流不存在'};
    }
    await _saveDefs(list);
    return <String, dynamic>{'ok': true, 'deleted': id};
  }

  Future<Map<String, dynamic>> _batch(Map<String, dynamic> p) async {
    final dynamic inputs = p['inputs'];
    if (inputs is! List || inputs.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '批量运行需要非空 inputs 列表'};
    }
    if (inputs.length > 50) {
      return <String, dynamic>{'ok': false, 'error': '单次批量上限 50 条'};
    }
    final List<Map<String, dynamic>> runs = <Map<String, dynamic>>[];
    for (final dynamic input in inputs) {
      final Map<String, dynamic> r = await _run(<String, dynamic>{
        'id': p['id'],
        'input': input.toString(),
        'cwd': p['cwd'],
      });
      runs.add(r);
    }
    return <String, dynamic>{
      'ok': true,
      'count': runs.length,
      'succeeded': runs.where((Map<String, dynamic> r) => r['ok'] == true).length,
      'runs': runs,
    };
  }

  Future<Map<String, dynamic>> _run(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    Map<String, dynamic>? wf;
    for (final Map<String, dynamic> w in await _defs()) {
      if (w['id'] == id) {
        wf = w;
        break;
      }
    }
    if (wf == null) {
      return <String, dynamic>{'ok': false, 'error': '工作流不存在'};
    }
    if (wf['enabled'] == false) {
      return <String, dynamic>{'ok': false, 'error': '工作流已停用'};
    }
    final String runId = _id('run');
    final Map<String, dynamic> vars = <String, dynamic>{
      if (wf['variables'] is Map) ...Map<String, dynamic>.from(wf['variables'] as Map),
      'input': (p['input'] ?? '').toString(),
    };
    final String cwd =
        (p['cwd'] ?? wf['cwd'] ?? 'sandbox').toString();
    final List<Map<String, dynamic>> outputs = <Map<String, dynamic>>[];
    String status = 'done';
    String error = '';
    final String started = DateTime.now().toIso8601String();
    for (final dynamic rawStep in (wf['steps'] as List)) {
      final Map<String, dynamic> step =
          Map<String, dynamic>.from(rawStep as Map);
      final String name = (step['name'] ?? '步骤').toString();
      final String type = (step['type'] ?? 'prompt').toString();
      final String input = _render((step['input'] ?? '').toString(), vars);
      final int t0 = DateTime.now().millisecondsSinceEpoch;
      Map<String, dynamic> out = <String, dynamic>{
        'step': name,
        'type': type,
        'input': input,
      };
      bool failed = false;
      try {
        if (type == 'prompt') {
          final Map<String, dynamic> r =
              await chat(<String, dynamic>{'text': input, 'session_id': 'wf-$runId'});
          out['engine'] = (r['engine'] ?? '').toString();
          if (r['ok'] == false) {
            failed = true;
            out['output'] = (r['error'] ?? '推理失败').toString();
          } else {
            out['output'] = (r['reply'] ?? '').toString();
          }
        } else if (type == 'shell') {
          final Map<String, dynamic> r = await shell(input, cwd);
          out['output'] = ((r['stdout'] ?? '').toString().trim().isEmpty
                  ? (r['error'] ?? '')
                  : r['stdout'])
              .toString();
          out['exit_code'] = r['exit_code'] ?? r['code'] ?? 0;
          final int code = (r['exit_code'] is num)
              ? (r['exit_code'] as num).toInt()
              : ((r['code'] is num) ? (r['code'] as num).toInt() : 0);
          failed = r['ok'] == false || code != 0;
        } else {
          final WorkflowKnowledge? kb = knowledge;
          if (kb == null) {
            failed = true;
            out['output'] = '知识库未接入';
          } else {
            final String context = await kb(input);
            out['output'] = context.isEmpty ? '（知识库未命中）' : context;
          }
        }
      } on Object catch (e) {
        failed = true;
        out['output'] = '执行异常：$e';
      }
      out['ms'] = DateTime.now().millisecondsSinceEpoch - t0;
      out['ok'] = !failed;
      outputs.add(out);
      final String saveAs = (step['save_as'] ?? '').toString().trim();
      if (saveAs.isNotEmpty) vars[saveAs] = out['output'];
      if (failed && step['continue_on_error'] != true) {
        status = 'failed';
        error = '$name 失败：${out['output']}';
        break;
      }
    }
    final String finished = DateTime.now().toIso8601String();
    final Map<String, dynamic> run = <String, dynamic>{
      'id': runId,
      'workflow_id': id,
      'workflow_name': wf['name'],
      'status': status,
      'error': error,
      'input': (p['input'] ?? '').toString(),
      'outputs': outputs,
      'variables': vars,
      'started_at': started,
      'finished_at': finished,
    };
    await store.insert('workflow_runs', run);
    final List<Map<String, dynamic>> list = await _defs();
    for (final Map<String, dynamic> w in list) {
      if (w['id'] == id) {
        w['last_run_at'] = finished;
        w['last_status'] = status;
        break;
      }
    }
    await _saveDefs(list);
    return <String, dynamic>{
      'ok': status == 'done',
      'run': run,
      if (error.isNotEmpty) 'error': error,
    };
  }

  Future<Map<String, dynamic>> _runDetail(Map<String, dynamic> p) async {
    final String id = (p['run_id'] ?? '').toString();
    for (final Map<String, dynamic> r in await _runs()) {
      if (r['id'] == id) return <String, dynamic>{'ok': true, 'run': r};
    }
    return <String, dynamic>{'ok': false, 'error': '运行记录不存在'};
  }

  String _render(String template, Map<String, dynamic> vars) {
    String out = template;
    for (final MapEntry<String, dynamic> e in vars.entries) {
      out = out.replaceAll('{{${e.key}}}', e.value.toString());
    }
    return out;
  }

  Future<Map<String, dynamic>> _import(Map<String, dynamic> p) async {
    final dynamic raw = p['json'] ?? p['workflow'];
    Map<String, dynamic>? wf;
    try {
      if (raw is String) {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map) {
          wf = decoded.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        }
      } else if (raw is Map) {
        wf = Map<String, dynamic>.from(raw);
      }
    } on Object {
      return <String, dynamic>{'ok': false, 'error': 'JSON 解析失败'};
    }
    if (wf == null) {
      return <String, dynamic>{'ok': false, 'error': '导入内容不是工作流对象'};
    }
    // 导入不覆盖已有同 id：清空 id 新建副本，避免误删本地流程。
    wf['id'] = '';
    wf['name'] = '${wf['name'] ?? '导入的工作流'}（导入）';
    return _save(<String, dynamic>{'workflow': wf});
  }

  Future<Map<String, dynamic>> _export(Map<String, dynamic> p) async {
    final Map<String, dynamic> r =
        await _get(<String, dynamic>{'id': p['id']});
    if (r['ok'] != true) return r;
    return <String, dynamic>{
      'ok': true,
      'json': jsonEncode(r['workflow']),
      'workflow': r['workflow'],
    };
  }

  /// 每日定时触发：返回已到点且今天尚未执行的启用工作流。
  /// 由 TaskScheduler 每 30 秒轮询调用。
  Future<Map<String, dynamic>> _due() async {
    final DateTime now = DateTime.now();
    final String today =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final List<Map<String, dynamic>> due = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> w in await _defs()) {
      if (w['enabled'] == false) continue;
      final dynamic triggers = w['triggers'];
      if (triggers is! Map) continue;
      final String schedule = (triggers['schedule'] ?? '').toString().trim();
      final RegExpMatch? m =
          RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(schedule);
      if (m == null) continue;
      final int hour = int.tryParse(m.group(1)!) ?? -1;
      final int minute = int.tryParse(m.group(2)!) ?? -1;
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) continue;
      final DateTime at = DateTime(now.year, now.month, now.day, hour, minute);
      if (now.isBefore(at)) continue;
      final String last = (w['last_run_at'] ?? '').toString();
      if (last.startsWith(today)) continue;
      due.add(w);
    }
    return <String, dynamic>{'ok': true, 'due': due, 'checked_at': now.toIso8601String()};
  }

  /// 内置模板：全部是可执行步骤，不含占位数据。
  static List<Map<String, dynamic>> templates() => <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'tpl-daily-review',
          'name': '每日工作复盘',
          'description': '读取当天工作区变更并输出结构化复盘',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '昨日产物',
              'type': 'shell',
              'input': 'ls -lt sandbox | head -20',
              'save_as': 'files',
            },
            <String, dynamic>{
              'name': '复盘',
              'type': 'prompt',
              'input': '基于下面的工作区文件清单，输出今日完成、阻塞与明日计划：\n{{files}}',
            },
          ],
        },
        <String, dynamic>{
          'id': 'tpl-kb-ingest',
          'name': '批量知识入库检查',
          'description': '对输入主题做知识库检索并总结引用',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '检索',
              'type': 'knowledge',
              'input': '{{input}}',
              'save_as': 'context',
            },
            <String, dynamic>{
              'name': '总结',
              'type': 'prompt',
              'input': '只依据以下知识库命中内容，总结要点并标注来源：\n{{context}}',
            },
          ],
        },
        <String, dynamic>{
          'id': 'tpl-batch-review',
          'name': '批量文本处理',
          'description': '把每条输入统一处理为结构化结果',
          'steps': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': '处理',
              'type': 'prompt',
              'input': '请处理这条输入并给出结论：{{input}}',
            },
          ],
        },
      ];
}
