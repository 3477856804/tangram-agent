/// 本机全局搜索：在真实落盘的数据里找对话、页面、知识库、通话、Routine、
/// 工作流与集成。
///
/// 全部按关键字大小写不敏感匹配，返回命中片段与来源引用；不调用网络、
/// 不生成示例结果。搜索只读文件，不修改任何数据。
library;

import 'dart:convert';
import 'dart:io';

class LocalSearchService {
  LocalSearchService(Directory root) : _root = root;

  final Directory _root;

  static const int maxResults = 100;
  static const int maxScanRecords = 20000;

  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> p,
  ) async {
    if (action != 'query') {
      return <String, dynamic>{'ok': false, 'error': '未知搜索动作：$action'};
    }
    return _query(p);
  }

  Future<Map<String, dynamic>> _query(Map<String, dynamic> p) async {
    final String query = (p['query'] ?? '').toString().trim();
    if (query.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '搜索关键字不能为空'};
    }
    final String q = query.toLowerCase();
    final int limit = (p['limit'] is num)
        ? (p['limit'] as num).toInt().clamp(1, maxResults)
        : 50;
    final Set<String> types = p['types'] is List
        ? (p['types'] as List).map((dynamic e) => '$e').toSet()
        : <String>{};
    final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
    int scanned = 0;

    Future<void> addAll(Future<List<Map<String, dynamic>>> future) async {
      final List<Map<String, dynamic>> items = await future;
      scanned += items.length;
      for (final Map<String, dynamic> r in items) {
        if (types.isNotEmpty && !types.contains('${r['type']}')) continue;
        results.add(r);
      }
    }

    await addAll(_searchTurns(q));
    await addAll(_searchPages(q));
    await addAll(_searchKnowledge(q));
    await addAll(_searchCalls(q));
    await addAll(_searchRoutines(q));
    await addAll(_searchWorkflows(q));
    await addAll(_searchIntegrations(q));

    results.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final int score = (b['score'] as int).compareTo(a['score'] as int);
      if (score != 0) return score;
      return '${b['ts'] ?? ''}'.compareTo('${a['ts'] ?? ''}');
    });
    final Map<String, int> groups = <String, int>{};
    for (final Map<String, dynamic> r in results) {
      groups['${r['type']}'] = (groups['${r['type']}'] ?? 0) + 1;
    }
    final List<Map<String, dynamic>> top =
        results.length <= limit ? results : results.sublist(0, limit);
    return <String, dynamic>{
      'ok': true,
      'query': query,
      'results': top,
      'total': results.length,
      'groups': groups,
      'scanned': scanned,
      'truncated': results.length > limit,
    };
  }

  // ---- 各数据源 ----

  Future<List<Map<String, dynamic>>> _searchTurns(String q) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> turns = await _readRecords('turns.json', 'turns');
    for (final Map<String, dynamic> t in turns) {
      final String text = '${t['text'] ?? ''}';
      final int score = _score(text, q);
      if (score == 0) continue;
      final bool user = '${t['role']}' == 'user';
      out.add(<String, dynamic>{
        'type': 'chat',
        'title': user ? '你说' : '助手回复',
        'snippet': _snippet(text, q),
        'content': _clip(text, 3000),
        'ref': '${t['session_id'] ?? ''}',
        'ts': _ts(t['ts']),
        'score': score,
      });
      if (out.length >= maxScanRecords) break;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchPages(String q) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> pages =
        await _readRecords('pages.json', 'pages');
    for (final Map<String, dynamic> p in pages) {
      final String id = '${p['id'] ?? ''}';
      final String title = '${p['title'] ?? ''}';
      final int version = p['current_version'] is num
          ? (p['current_version'] as num).toInt()
          : int.tryParse('${p['current_version']}') ?? 0;
      if (id.isEmpty) continue;
      String content = '';
      if (version > 0) {
        final File f = File('${_root.path}/pages/$id/v$version.html');
        if (await f.exists()) {
          try {
            content = _stripHtml(await f.readAsString());
          } on Object {
            content = '';
          }
        }
      }
      final int score = _score(title, q) * 3 + _score(content, q);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'page',
        'title': title,
        'snippet': _snippet(content.isEmpty ? title : content, q),
        'content': _clip(content, 3000),
        'ref': id,
        'ts': '${p['updated_at'] ?? ''}',
        'score': score,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchKnowledge(String q) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final File f = File('${_root.path}/knowledge_base.json');
    if (!await f.exists()) return out;
    Map<String, dynamic> data;
    try {
      final dynamic decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return out;
      data = Map<String, dynamic>.from(decoded);
    } on Object {
      return out;
    }
    final Map<String, String> titles = <String, String>{};
    for (final dynamic raw
        in (data['documents'] is List ? data['documents'] as List : <dynamic>[])) {
      if (raw is Map && '${raw['id'] ?? ''}'.isNotEmpty) {
        titles['${raw['id']}'] = '${raw['title'] ?? '文档'}';
      }
    }
    final Map<String, Map<String, dynamic>> byDoc =
        <String, Map<String, dynamic>>{};
    for (final dynamic raw
        in (data['chunks'] is List ? data['chunks'] as List : <dynamic>[])) {
      if (raw is! Map) continue;
      final String text = '${raw['text'] ?? ''}';
      final int score = _score(text, q);
      if (score == 0) continue;
      final String docId = '${raw['document_id'] ?? ''}';
      if (docId.isEmpty) continue;
      final Map<String, dynamic> hit = <String, dynamic>{
        'type': 'knowledge',
        'title': titles[docId] ?? '知识库文档',
        'snippet': _snippet(text, q),
        'content': _clip(text, 3000),
        'ref': docId,
        'ts': '',
        'score': score,
      };
      final Map<String, dynamic>? existing = byDoc[docId];
      if (existing == null || score > (existing['score'] as int)) {
        byDoc[docId] = hit;
      }
    }
    out.addAll(byDoc.values);
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchCalls(String q) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> calls =
        await _readRecords('calls.json', 'calls');
    for (final Map<String, dynamic> c in calls) {
      final StringBuffer text = StringBuffer('${c['bot_name'] ?? ''}\n');
      if (c['transcript'] is List) {
        for (final dynamic e in c['transcript'] as List) {
          if (e is Map) text.writeln(e['text'] ?? '');
        }
      }
      final int score = _score(text.toString(), q);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'call',
        'title': '${c['bot_name'] ?? '通话'}',
        'snippet': _snippet(text.toString(), q),
        'content': _clip(text.toString(), 3000),
        'ref': '${c['id'] ?? ''}',
        'ts': '${c['started_at'] ?? ''}',
        'score': score,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchRoutines(String q) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> routines =
        await _readRecords('routines/routines.json', 'routines');
    for (final Map<String, dynamic> r in routines) {
      final int score =
          _score('${r['name'] ?? ''}', q) * 2 + _score('${r['prompt'] ?? ''}', q);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'routine',
        'title': '${r['name'] ?? 'Routine'}',
        'snippet': _snippet('${r['prompt'] ?? ''}', q),
        'content': _clip(
          '${r['prompt'] ?? ''}\n时区：${r['timezone'] ?? ''}',
          3000,
        ),
        'ref': '${r['id'] ?? ''}',
        'ts': '${r['updated_at'] ?? ''}',
        'score': score,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchWorkflows(String q) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> flows =
        await _readRecords('workflows.json', 'workflows');
    for (final Map<String, dynamic> f in flows) {
      final StringBuffer text = StringBuffer('${f['name'] ?? ''}\n');
      text.writeln(f['description'] ?? '');
      if (f['steps'] is List) {
        for (final dynamic s in f['steps'] as List) {
          if (s is Map) text.writeln(s['prompt'] ?? s['command'] ?? '');
        }
      }
      final int score = _score(text.toString(), q);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'workflow',
        'title': '${f['name'] ?? '工作流'}',
        'snippet': _snippet(text.toString(), q),
        'content': _clip(text.toString(), 3000),
        'ref': '${f['id'] ?? ''}',
        'ts': '${f['updated_at'] ?? ''}',
        'score': score,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchIntegrations(String q) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> items =
        await _readRecords('integrations.json', 'integrations');
    for (final Map<String, dynamic> i in items) {
      final int score =
          _score('${i['name'] ?? ''}', q) * 2 + _score('${i['url'] ?? ''}', q);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'integration',
        'title': '${i['name'] ?? '集成'}',
        'snippet': '${i['kind']} · ${i['url']}',
        'content': '${i['kind']} · ${i['url']}',
        'ref': '${i['id'] ?? ''}',
        'ts': '${i['updated_at'] ?? ''}',
        'score': score,
      });
    }
    return out;
  }

  // ---- 工具 ----

  Future<List<Map<String, dynamic>>> _readRecords(
    String relative,
    String key,
  ) async {
    final File f = File('${_root.path}/$relative');
    if (!await f.exists()) return <Map<String, dynamic>>[];
    try {
      final dynamic decoded = jsonDecode(await f.readAsString());
      dynamic list;
      if (decoded is Map) {
        list = decoded[key];
      } else if (decoded is List) {
        list = decoded;
      }
      if (list is! List) return <Map<String, dynamic>>[];
      return list
          .whereType<Map>()
          .take(maxScanRecords)
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
    } on Object {
      return <Map<String, dynamic>>[];
    }
  }

  static int _score(String text, String q) {
    if (text.isEmpty) return 0;
    final String lower = text.toLowerCase();
    int index = lower.indexOf(q);
    if (index < 0) return 0;
    int score = 0;
    while (index >= 0 && score < 10) {
      score++;
      index = lower.indexOf(q, index + q.length);
    }
    return score;
  }

  static String _snippet(String text, String q) {
    final String lower = text.toLowerCase();
    final int index = lower.indexOf(q);
    if (index < 0) return _clip(text.trim(), 120);
    final int start = index - 40 < 0 ? 0 : index - 40;
    final int end = index + q.length + 60 > text.length
        ? text.length
        : index + q.length + 60;
    final String slice = text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
    return '${start > 0 ? '…' : ''}$slice${end < text.length ? '…' : ''}';
  }

  static String _stripHtml(String html) {
    String out = html
        .replaceAll(RegExp(r'<script\b[^>]*>[\s\S]*?</script>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<style\b[^>]*>[\s\S]*?</style>', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"');
    return out.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _clip(String text, int max) {
    final String t = text.trim();
    return t.length <= max ? t : '${t.substring(0, max)}…';
  }

  static String _ts(dynamic raw) {
    if (raw is num) {
      final int ms = raw > 100000000000 ? raw.toInt() : (raw * 1000).round();
      return DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String();
    }
    return '${raw ?? ''}';
  }
}
