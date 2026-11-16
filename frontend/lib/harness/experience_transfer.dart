/// 经验类比迁移：把真实成功过的工单 / 工作流运行沉淀为可复用经验，
/// 再用本地 BM25 检索并在新任务上做迁移。
///
/// 红线：
///  * 只从真实来源导入：手工录入、`super_tickets` 里 status=done 的工单、
///    `workflow_runs` 里 status=done 的运行；失败记录一律不导入。
///  * 检索是本地词项 BM25（中文单字 + 二元组 + 英文/数字词），返回真实命中
///    与分数；没有命中就是空列表，绝不编造经验。
///  * `adapt` 只有在注入的 chat 返回**真实模型**结果时才使用模型方案；
///    缺模型 / 内置兜底 / 远端失败时返回基于 pattern 的确定性清单，并如实
///    标注 `engine=heuristic`，绝不假装模型已经给出迁移方案。
///  * 使用次数 / 成功率由 `recordOutcome` 真实累加，落盘
///    `experience_library.json`。

import 'store.dart';

typedef ExperienceChat = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> p);

class ExperienceLibrary {
  ExperienceLibrary(this.store);

  final HarnessStore store;

  static const String _file = 'experience_library.json';

  Map<String, dynamic>? _data;

  Future<Map<String, dynamic>> _load() async {
    final Map<String, dynamic>? cached = _data;
    if (cached != null) return cached;
    final Map<String, dynamic> raw = await store.readJson(
      _file,
      fallback: <String, dynamic>{
        'version': 1,
        'patterns': <dynamic>[],
      },
    );
    raw['patterns'] = raw['patterns'] is List
        ? (raw['patterns'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];
    _data = raw;
    return raw;
  }

  Future<void> _save() async {
    final Map<String, dynamic> data = _data ?? <String, dynamic>{};
    data['updated_at'] = DateTime.now().toIso8601String();
    await store.writeJson(_file, data);
  }

  List<Map<String, dynamic>> get _patterns {
    final dynamic raw = _data?['patterns'];
    if (raw is List<Map<String, dynamic>>) return raw;
    final List<Map<String, dynamic>> list = (raw is List ? raw : <dynamic>[])
        .whereType<Map>()
        .map((Map e) => Map<String, dynamic>.from(e))
        .toList();
    _data?['patterns'] = list;
    return list;
  }

  String _id() => 'exp-${DateTime.now().microsecondsSinceEpoch}';

  /// 列表：真实落盘的全部经验模式。
  Future<List<Map<String, dynamic>>> list() async {
    await _load();
    return _patterns.map(_copyPattern).toList();
  }

  Map<String, dynamic> _copyPattern(Map<String, dynamic> p) =>
      <String, dynamic>{
        ...p,
        'tags': p['tags'] is List
            ? (p['tags'] as List).map((dynamic e) => e.toString()).toList()
            : <String>[],
        'steps': p['steps'] is List
            ? (p['steps'] as List).map((dynamic e) => e.toString()).toList()
            : <String>[],
      };

  Map<String, dynamic>? _find(String id) {
    for (final Map<String, dynamic> p in _patterns) {
      if (p['id'] == id) return p;
    }
    return null;
  }

  bool _hasSource(String source, String ref) {
    if (ref.isEmpty) return false;
    for (final Map<String, dynamic> p in _patterns) {
      if (p['source'] == source && p['source_ref'] == ref) return true;
    }
    return false;
  }

  /// 手工录入一条经验 pattern。
  Future<Map<String, dynamic>> addManual({
    required String name,
    required String task,
    required String approach,
    List<String> tags = const <String>[],
    List<String> steps = const <String>[],
  }) async {
    final String n = name.trim();
    final String t = task.trim();
    final String a = approach.trim();
    final List<String> cleanSteps = steps
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    final List<String> cleanTags = tags
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (n.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '经验名称不能为空'};
    }
    if (t.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '原场景/问题不能为空'};
    }
    if (a.isEmpty && cleanSteps.isEmpty) {
      return <String, dynamic>{
        'ok': false,
        'error': '至少填写方案说明或一个可复用步骤',
      };
    }
    await _load();
    final String now = DateTime.now().toIso8601String();
    final Map<String, dynamic> pattern = <String, dynamic>{
      'id': _id(),
      'name': n,
      'task': t,
      'approach': a,
      'steps': cleanSteps,
      'tags': cleanTags,
      'source': 'manual',
      'source_ref': '',
      'uses': 0,
      'successes': 0,
      'success_rate': 0.0,
      'outcomes': <Map<String, dynamic>>[],
      'created_at': now,
      'updated_at': now,
    };
    _patterns.add(pattern);
    await _save();
    return <String, dynamic>{'ok': true, 'pattern': _copyPattern(pattern)};
  }

  /// 手工录入的别名，便于控制域 / 页面按语义调用。
  Future<Map<String, dynamic>> addPattern({
    required String name,
    required String task,
    required String approach,
    List<String> tags = const <String>[],
    List<String> steps = const <String>[],
  }) =>
      addManual(name: name, task: task, approach: approach, tags: tags, steps: steps);

  /// 从成功工单（super_tickets status=done）导入经验。
  Future<Map<String, dynamic>> importFromTickets() async {
    await _load();
    final List<Map<String, dynamic>> tickets =
        await store.readRecords('super_tickets');
    int imported = 0;
    int skipped = 0;
    final List<String> ids = <String>[];
    for (final Map<String, dynamic> ticket in tickets) {
      if ((ticket['status'] ?? '').toString() != 'done') {
        skipped += 1;
        continue;
      }
      final String ref = (ticket['id'] ?? '').toString();
      if (ref.isEmpty || _hasSource('ticket', ref)) {
        skipped += 1;
        continue;
      }
      final String goal = (ticket['goal'] ?? '').toString().trim();
      if (goal.isEmpty) {
        skipped += 1;
        continue;
      }
      final List<String> history = (ticket['history'] is List)
          ? (ticket['history'] as List)
              .map((dynamic e) => e.toString().trim())
              .where((String s) => s.isNotEmpty)
              .toList()
          : <String>[];
      final String result = (ticket['result'] ?? '').toString().trim();
      final String approach =
          result.isNotEmpty ? result : history.isEmpty ? '' : history.last;
      if (approach.isEmpty) {
        skipped += 1;
        continue;
      }
      final String now = DateTime.now().toIso8601String();
      final Map<String, dynamic> pattern = <String, dynamic>{
        'id': _id(),
        'name': _shorten(goal, 60),
        'task': goal,
        'approach': _shorten(approach, 1600),
        'steps': history
            .map((String s) => _shorten(s, 200))
            .take(12)
            .toList(),
        'tags': <String>[
          'ticket',
          if ((ticket['source'] ?? '').toString().isNotEmpty)
            (ticket['source'] ?? '').toString(),
          if ((ticket['engine'] ?? '').toString().isNotEmpty)
            (ticket['engine'] ?? '').toString(),
        ],
        'source': 'ticket',
        'source_ref': ref,
        'uses': 0,
        'successes': 0,
        'success_rate': 0.0,
        'outcomes': <Map<String, dynamic>>[],
        'created_at': now,
        'updated_at': now,
      };
      _patterns.add(pattern);
      imported += 1;
      ids.add(pattern['id'] as String);
    }
    if (imported > 0) await _save();
    return <String, dynamic>{
      'ok': true,
      'imported': imported,
      'skipped': skipped,
      'ids': ids,
    };
  }

  Future<Map<String, dynamic>> importTickets() => importFromTickets();

  /// 从成功工作流运行（workflow_runs status=done）导入经验。
  Future<Map<String, dynamic>> importFromRuns() async {
    await _load();
    final List<Map<String, dynamic>> runs =
        await store.readRecords('workflow_runs');
    int imported = 0;
    int skipped = 0;
    final List<String> ids = <String>[];
    for (final Map<String, dynamic> run in runs) {
      if ((run['status'] ?? '').toString() != 'done') {
        skipped += 1;
        continue;
      }
      final String ref = (run['id'] ?? '').toString();
      if (ref.isEmpty || _hasSource('workflow', ref)) {
        skipped += 1;
        continue;
      }
      final String workflowName =
          (run['workflow_name'] ?? '').toString().trim();
      final List<Map<String, dynamic>> outputs = (run['outputs'] is List)
          ? (run['outputs'] as List)
              .whereType<Map>()
              .map((Map e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      if (workflowName.isEmpty && outputs.isEmpty) {
        skipped += 1;
        continue;
      }
      final String input = (run['input'] ?? '').toString().trim();
      final List<String> steps = <String>[];
      final List<String> lines = <String>[];
      for (final Map<String, dynamic> out in outputs) {
        final String step = (out['step'] ?? '').toString().trim();
        final String output = (out['output'] ?? '').toString().trim();
        if (step.isNotEmpty) steps.add(step);
        if (step.isNotEmpty || output.isNotEmpty) {
          lines.add('${step.isEmpty ? '步骤' : step}：${_shorten(output, 240)}');
        }
      }
      final String approach = lines.isEmpty
          ? _shorten((run['error'] ?? '').toString(), 1600)
          : _shorten(lines.join('\n'), 1600);
      if (approach.isEmpty) {
        skipped += 1;
        continue;
      }
      final String now = DateTime.now().toIso8601String();
      final Map<String, dynamic> pattern = <String, dynamic>{
        'id': _id(),
        'name': _shorten(
          input.isEmpty ? workflowName : '$workflowName · $input',
          60,
        ),
        'task': input.isEmpty ? workflowName : '$workflowName：$input',
        'approach': approach,
        'steps': steps.take(20).toList(),
        'tags': <String>['workflow', if (workflowName.isNotEmpty) workflowName],
        'source': 'workflow',
        'source_ref': ref,
        'uses': 0,
        'successes': 0,
        'success_rate': 0.0,
        'outcomes': <Map<String, dynamic>>[],
        'created_at': now,
        'updated_at': now,
      };
      _patterns.add(pattern);
      imported += 1;
      ids.add(pattern['id'] as String);
    }
    if (imported > 0) await _save();
    return <String, dynamic>{
      'ok': true,
      'imported': imported,
      'skipped': skipped,
      'ids': ids,
    };
  }

  Future<Map<String, dynamic>> importWorkflowRuns() => importFromRuns();

  /// 一次导入两类真实来源。
  Future<Map<String, dynamic>> importAll() async {
    final Map<String, dynamic> tickets = await importFromTickets();
    final Map<String, dynamic> runs = await importFromRuns();
    return <String, dynamic>{
      'ok': true,
      'imported':
          ((tickets['imported'] as num?)?.toInt() ?? 0) +
              ((runs['imported'] as num?)?.toInt() ?? 0),
      'skipped':
          ((tickets['skipped'] as num?)?.toInt() ?? 0) +
              ((runs['skipped'] as num?)?.toInt() ?? 0),
      'tickets': tickets,
      'runs': runs,
    };
  }

  /// 本地 BM25 检索，返回真实命中与分数；没有命中时返回空列表。
  Future<List<Map<String, dynamic>>> search(String query, [int topK = 5]) async {
    await _load();
    final String q = query.trim();
    final int k = topK.clamp(1, 50);
    if (q.isEmpty) return <Map<String, dynamic>>[];
    final Map<String, int> qtf = _tokenize(q);
    if (qtf.isEmpty) return <Map<String, dynamic>>[];

    final List<Map<String, dynamic>> pool = _patterns;
    if (pool.isEmpty) return <Map<String, dynamic>>[];

    final Map<String, Map<String, int>> tfs = <String, Map<String, int>>{};
    final Map<String, int> lengths = <String, int>{};
    for (final Map<String, dynamic> p in pool) {
      final Map<String, int> tf = _tokenize(_patternText(p));
      tfs[(p['id'] ?? '').toString()] = tf;
      lengths[(p['id'] ?? '').toString()] =
          tf.values.fold<int>(0, (int a, int b) => a + b);
    }
    final double avgdl = lengths.isEmpty
        ? 1.0
        : lengths.values.fold<int>(0, (int a, int b) => a + b) /
            lengths.length;
    final Map<String, int> df = <String, int>{};
    for (final Map<String, int> tf in tfs.values) {
      for (final String term in qtf.keys) {
        if (tf.containsKey(term)) df[term] = (df[term] ?? 0) + 1;
      }
    }

    const double k1 = 1.5;
    const double b = 0.75;
    final List<Map<String, dynamic>> scored = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> p in pool) {
      final String key = (p['id'] ?? '').toString();
      final Map<String, int> tf = tfs[key] ?? <String, int>{};
      final int dl = lengths[key] ?? 1;
      double score = 0;
      for (final String term in qtf.keys) {
        final int f = tf[term] ?? 0;
        if (f == 0) continue;
        final int n = df[term] ?? 0;
        final double idf =
            ((pool.length - n + 0.5) / (n + 0.5) + 1).clamp(0.0, 20.0);
        score += idf * (f * (k1 + 1)) / (f + k1 * (1 - b + b * dl / avgdl));
      }
      if (score <= 0) continue;
      scored.add(<String, dynamic>{
        'score': double.parse(score.toStringAsFixed(4)),
        'pattern': p,
      });
    }
    scored.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        (b['score'] as double).compareTo(a['score'] as double));
    final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> s in scored) {
      final Map<String, dynamic> p =
          Map<String, dynamic>.from(s['pattern'] as Map);
      results.add(<String, dynamic>{
        'id': p['id'],
        'name': p['name'],
        'task': p['task'],
        'approach': p['approach'],
        'tags': p['tags'],
        'steps': p['steps'],
        'source': p['source'],
        'source_ref': p['source_ref'],
        'uses': p['uses'],
        'successes': p['successes'],
        'success_rate': p['success_rate'],
        'score': s['score'],
        'snippet': _snippet(_patternText(p), qtf.keys.toList()),
      });
      if (results.length >= k) break;
    }
    return results;
  }

  /// 把一条经验迁移到新任务。
  ///
  /// 注入了真实 chat 时用模型生成；否则（或模型不可用）返回确定性清单并
  /// 标注 `engine=heuristic`。
  Future<Map<String, dynamic>> adapt(
    String patternId,
    String newTask, {
    ExperienceChat? chat,
  }) async {
    await _load();
    final Map<String, dynamic>? pattern = _find(patternId);
    if (pattern == null) {
      return <String, dynamic>{'ok': false, 'error': '经验不存在'};
    }
    final String task = newTask.trim();
    if (task.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '新任务内容不能为空'};
    }
    final double similarity = _similarity(
      (pattern['task'] ?? '').toString(),
      task,
    );
    final List<String> checklist = _checklist(pattern, task, similarity);

    String note = '';
    if (chat != null) {
      final String prompt = '你在做经验类比迁移。以下是一条真实成功过的经验：\n'
          '名称：${pattern['name']}\n'
          '原场景：${pattern['task']}\n'
          '原方案：${pattern['approach']}\n'
          '可复用步骤：${(pattern['steps'] as List? ?? <dynamic>[]).join(' / ')}\n'
          '新任务：$task\n'
          '请给出新任务的迁移方案：可复用点、必要改动、风险与验证清单。'
          '只输出方案本身，不要声称已经执行任何操作。';
      Map<String, dynamic> r;
      try {
        r = await chat(<String, dynamic>{
          'text': prompt,
          'session_id': 'exp-adapt-$patternId',
        });
      } on Object catch (e) {
        r = <String, dynamic>{'ok': false, 'error': '$e'};
      }
      final String engine = (r['engine'] ?? '').toString();
      final String reply = (r['reply'] ?? '').toString().trim();
      final bool realModel = r['ok'] != false &&
          reply.isNotEmpty &&
          engine.isNotEmpty &&
          engine != 'builtin-agent-loop' &&
          engine != 'remote-failed';
      if (realModel) {
        return <String, dynamic>{
          'ok': true,
          'pattern_id': patternId,
          'pattern_name': pattern['name'],
          'new_task': task,
          'engine': engine,
          'model': true,
          'plan': reply,
          'checklist': checklist,
          'similarity': similarity,
        };
      }
      note = '模型不可用（engine=${engine.isEmpty ? 'unknown' : engine}），'
          '已使用确定性适配清单';
    }

    final List<String> steps = (pattern['steps'] as List? ?? <dynamic>[])
        .map((dynamic e) => e.toString())
        .where((String s) => s.trim().isNotEmpty)
        .toList();
    final StringBuffer plan = StringBuffer()
      ..writeln('【经验迁移 · heuristic】')
      ..writeln('来源经验：${pattern['name']}')
      ..writeln('原场景：${pattern['task']}')
      ..writeln('新任务：$task')
      ..writeln('场景相似度：${(similarity * 100).toStringAsFixed(1)}%')
      ..writeln('可复用方案：${pattern['approach']}');
    if (steps.isNotEmpty) {
      plan.writeln('可复用步骤：');
      for (int i = 0; i < steps.length; i++) {
        plan.writeln('${i + 1}. ${steps[i]}');
      }
    }
    plan.writeln('注意：以上由本地确定性规则生成，未调用模型。');
    return <String, dynamic>{
      'ok': true,
      'pattern_id': patternId,
      'pattern_name': pattern['name'],
      'new_task': task,
      'engine': 'heuristic',
      'model': false,
      'plan': plan.toString().trim(),
      'checklist': checklist,
      'similarity': similarity,
      if (note.isNotEmpty) 'note': note,
    };
  }

  /// 真实累加使用次数与成功次数。
  Future<Map<String, dynamic>> recordOutcome(
    String patternId,
    bool success, [
    String notes = '',
  ]) async {
    await _load();
    final Map<String, dynamic>? pattern = _find(patternId);
    if (pattern == null) {
      return <String, dynamic>{'ok': false, 'error': '经验不存在'};
    }
    final int uses = (pattern['uses'] as num?)?.toInt() ?? 0;
    final int successes = (pattern['successes'] as num?)?.toInt() ?? 0;
    final int nextUses = uses + 1;
    final int nextSuccesses = successes + (success ? 1 : 0);
    pattern['uses'] = nextUses;
    pattern['successes'] = nextSuccesses;
    pattern['success_rate'] =
        double.parse((nextSuccesses / nextUses).toStringAsFixed(4));
    pattern['updated_at'] = DateTime.now().toIso8601String();
    final List<dynamic> outcomes = pattern['outcomes'] is List
        ? List<dynamic>.from(pattern['outcomes'] as List)
        : <dynamic>[];
    outcomes.add(<String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'success': success,
      'notes': notes.trim(),
    });
    pattern['outcomes'] = outcomes.length > 50
        ? outcomes.sublist(outcomes.length - 50)
        : outcomes;
    await _save();
    return <String, dynamic>{
      'ok': true,
      'pattern': _copyPattern(pattern),
      'uses': nextUses,
      'successes': nextSuccesses,
      'success_rate': pattern['success_rate'],
    };
  }

  /// 删除一条经验（仅本地记录，不影响来源工单/运行）。
  Future<Map<String, dynamic>> remove(String id) async {
    await _load();
    final int before = _patterns.length;
    _patterns.removeWhere((Map<String, dynamic> p) => p['id'] == id);
    if (_patterns.length == before) {
      return <String, dynamic>{'ok': false, 'error': '经验不存在'};
    }
    await _save();
    return <String, dynamic>{'ok': true, 'deleted': id};
  }

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    switch (action) {
      case 'list':
        return <String, dynamic>{'ok': true, 'patterns': await list()};
      case 'add':
        return addManual(
          name: (p['name'] ?? '').toString(),
          task: (p['task'] ?? '').toString(),
          approach: (p['approach'] ?? '').toString(),
          tags: _stringList(p['tags']),
          steps: _stringList(p['steps']),
        );
      case 'import_tickets':
        return importFromTickets();
      case 'import_runs':
        return importFromRuns();
      case 'import_all':
        return importAll();
      case 'search':
        final List<Map<String, dynamic>> results = await search(
          (p['query'] ?? '').toString(),
          (p['top_k'] is num) ? (p['top_k'] as num).toInt() : 5,
        );
        return <String, dynamic>{
          'ok': true,
          'query': (p['query'] ?? '').toString(),
          'results': results,
        };
      case 'adapt':
        return adapt(
          (p['pattern_id'] ?? p['id'] ?? '').toString(),
          (p['new_task'] ?? p['task'] ?? '').toString(),
        );
      case 'record_outcome':
        return recordOutcome(
          (p['pattern_id'] ?? p['id'] ?? '').toString(),
          p['success'] == true,
          (p['notes'] ?? '').toString(),
        );
      case 'delete':
        return remove((p['id'] ?? p['pattern_id'] ?? '').toString());
      default:
        return <String, dynamic>{'ok': false, 'error': '未知经验动作：$action'};
    }
  }

  // ---- 本地检索工具 ----

  Map<String, int> _tokenize(String text) {
    final String lower = text.toLowerCase();
    final Map<String, int> tf = <String, int>{};
    void add(String token) {
      if (token.isEmpty) return;
      tf[token] = (tf[token] ?? 0) + 1;
    }

    for (final RegExpMatch m in RegExp(r'[a-z0-9_]{2,}').allMatches(lower)) {
      add(m.group(0)!);
    }
    final List<String> cjk = RegExp(r'[\u4e00-\u9fff]')
        .allMatches(lower)
        .map((RegExpMatch m) => m.group(0)!)
        .toList();
    // 中文只用二元组参与打分：单字命中会把「剪辑」误配到「逻辑」这类无关经验。
    if (cjk.length == 1) add(cjk.first);
    for (int i = 0; i + 1 < cjk.length; i++) {
      add('${cjk[i]}${cjk[i + 1]}');
    }
    return tf;
  }

  String _patternText(Map<String, dynamic> p) => <String>[
        (p['name'] ?? '').toString(),
        (p['task'] ?? '').toString(),
        (p['approach'] ?? '').toString(),
        (p['tags'] is List)
            ? (p['tags'] as List).map((dynamic e) => e.toString()).join(' ')
            : '',
        (p['steps'] is List)
            ? (p['steps'] as List).map((dynamic e) => e.toString()).join(' ')
            : '',
      ].join('\n');

  double _similarity(String a, String b) {
    final Set<String> ta = _tokenize(a).keys.toSet();
    final Set<String> tb = _tokenize(b).keys.toSet();
    if (ta.isEmpty || tb.isEmpty) return 0;
    final int overlap = ta.intersection(tb).length;
    final int union = ta.union(tb).length;
    return union == 0 ? 0 : double.parse((overlap / union).toStringAsFixed(4));
  }

  List<String> _checklist(
    Map<String, dynamic> pattern,
    String task,
    double similarity,
  ) {
    final List<String> steps = (pattern['steps'] as List? ?? <dynamic>[])
        .map((dynamic e) => e.toString().trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    return <String>[
      '确认新任务与原场景的差异：$task',
      '复用原方案的核心思路：${_shorten((pattern['approach'] ?? '').toString(), 180)}',
      if (steps.isNotEmpty)
        '按原步骤执行：${steps.map((String s) => _shorten(s, 60)).join(' → ')}'
      else
        '把原方案拆成可执行步骤后再执行',
      '场景相似度 ${(similarity * 100).toStringAsFixed(1)}%，'
          '${similarity >= 0.5 ? '可直接复用大部分方案' : '需重点核对前提与边界条件'}',
      '执行后把真实结果记录回经验库（recordOutcome）',
    ];
  }

  String _snippet(String text, List<String> terms) {
    final String lower = text.toLowerCase();
    int at = -1;
    for (final String term in terms) {
      final int i = lower.indexOf(term.toLowerCase());
      if (i >= 0 && (at < 0 || i < at)) at = i;
    }
    if (at < 0) return _shorten(text, 120);
    final int start = (at - 40).clamp(0, text.length);
    final int end = (at + 80).clamp(0, text.length);
    final String piece = text.substring(start, end).replaceAll('\n', ' ').trim();
    return '${start > 0 ? '…' : ''}$piece${end < text.length ? '…' : ''}';
  }

  String _shorten(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  List<String> _stringList(dynamic raw) => raw is List
      ? raw.map((dynamic e) => e.toString()).toList()
      : <String>[];

  /// 调试 / 自检：真实落盘文件的可读快照。
  Future<Map<String, dynamic>> describe() async {
    await _load();
    return <String, dynamic>{
      'ok': true,
      'patterns': _patterns.length,
      'file': _file,
      'sources': <String, dynamic>{
        'manual': _patterns
            .where((Map<String, dynamic> p) => p['source'] == 'manual')
            .length,
        'ticket': _patterns
            .where((Map<String, dynamic> p) => p['source'] == 'ticket')
            .length,
        'workflow': _patterns
            .where((Map<String, dynamic> p) => p['source'] == 'workflow')
            .length,
      },
    };
  }
}
