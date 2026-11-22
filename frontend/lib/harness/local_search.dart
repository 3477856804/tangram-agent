/// 本机全局搜索：在真实落盘的数据里找对话、页面、知识库、通话、Routine、
/// 工作流与集成，并读产物文件（work/ 与 Team Computer 的 computer/homes/）
/// 的真实内容。
///
/// 多词查询按词频打分：每词命中次数累加，标题/文件名命中加权，全部词都
/// 命中时额外加分；单字查询与原来完全一致。只读文件，不修改任何数据；
/// 超大文件、二进制文件、浏览器配置与凭据类文件（cookie/secret/token）
/// 一律跳过，不读不搜。
library;

import 'dart:convert';
import 'dart:io';

class LocalSearchService {
  LocalSearchService(Directory root) : _root = root;

  final Directory _root;

  static const int maxResults = 100;
  static const int maxScanRecords = 20000;

  /// 产物文件内容搜索：单次最多扫描的文件数与单个文件上限。
  static const int maxScanFiles = 200;
  static const int maxFileBytes = 64 * 1024;

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
    // 多词查询拆词去重；单字查询 terms == [q]，打分与原来完全一致。
    final List<String> terms = q
        .split(RegExp(r'\s+'))
        .where((String s) => s.isNotEmpty)
        .toSet()
        .toList();
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

    await addAll(_searchTurns(terms));
    await addAll(_searchPages(terms));
    await addAll(_searchKnowledge(terms));
    await addAll(_searchCalls(terms));
    await addAll(_searchRoutines(terms));
    await addAll(_searchWorkflows(terms));
    await addAll(_searchIntegrations(terms));
    await addAll(_searchFiles(terms));

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

  Future<List<Map<String, dynamic>>> _searchTurns(List<String> terms) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> turns = await _readRecords('turns.json', 'turns');
    for (final Map<String, dynamic> t in turns) {
      final String text = '${t['text'] ?? ''}';
      final int score = _score(text, terms);
      if (score == 0) continue;
      final bool user = '${t['role']}' == 'user';
      out.add(<String, dynamic>{
        'type': 'chat',
        'title': user ? '你说' : '助手回复',
        'snippet': _snippet(text, terms),
        'content': _clip(text, 3000),
        'ref': '${t['session_id'] ?? ''}',
        'ts': _ts(t['ts']),
        'score': score,
      });
      if (out.length >= maxScanRecords) break;
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchPages(List<String> terms) async {
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
      final int score = _score(title, terms) * 3 + _score(content, terms);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'page',
        'title': title,
        'snippet': _snippet(content.isEmpty ? title : content, terms),
        'content': _clip(content, 3000),
        'ref': id,
        'ts': '${p['updated_at'] ?? ''}',
        'score': score,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchKnowledge(List<String> terms) async {
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
      final int score = _score(text, terms);
      if (score == 0) continue;
      final String docId = '${raw['document_id'] ?? ''}';
      if (docId.isEmpty) continue;
      final Map<String, dynamic> hit = <String, dynamic>{
        'type': 'knowledge',
        'title': titles[docId] ?? '知识库文档',
        'snippet': _snippet(text, terms),
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

  Future<List<Map<String, dynamic>>> _searchCalls(List<String> terms) async {
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
      final int score = _score(text.toString(), terms);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'call',
        'title': '${c['bot_name'] ?? '通话'}',
        'snippet': _snippet(text.toString(), terms),
        'content': _clip(text.toString(), 3000),
        'ref': '${c['id'] ?? ''}',
        'ts': '${c['started_at'] ?? ''}',
        'score': score,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchRoutines(List<String> terms) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> routines =
        await _readRecords('routines/routines.json', 'routines');
    for (final Map<String, dynamic> r in routines) {
      final int score =
          _score('${r['name'] ?? ''}', terms) * 2 + _score('${r['prompt'] ?? ''}', terms);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'routine',
        'title': '${r['name'] ?? 'Routine'}',
        'snippet': _snippet('${r['prompt'] ?? ''}', terms),
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

  Future<List<Map<String, dynamic>>> _searchWorkflows(List<String> terms) async {
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
      final int score = _score(text.toString(), terms);
      if (score == 0) continue;
      out.add(<String, dynamic>{
        'type': 'workflow',
        'title': '${f['name'] ?? '工作流'}',
        'snippet': _snippet(text.toString(), terms),
        'content': _clip(text.toString(), 3000),
        'ref': '${f['id'] ?? ''}',
        'ts': '${f['updated_at'] ?? ''}',
        'score': score,
      });
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _searchIntegrations(List<String> terms) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> items =
        await _readRecords('integrations.json', 'integrations');
    for (final Map<String, dynamic> i in items) {
      final int score =
          _score('${i['name'] ?? ''}', terms) * 2 + _score('${i['url'] ?? ''}', terms);
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

  /// 产物文件内容搜索：读 work/ 与 computer/homes/ 下文本文件的真实内容。
  ///
  /// pages/ 的内容已由 _searchPages（读当前版本 HTML）覆盖，这里不再重复
  /// 扫，避免同一内容出现两次。只读、不改；超大、二进制、浏览器配置与
  /// 凭据类文件一律跳过。
  Future<List<Map<String, dynamic>>> _searchFiles(
    List<String> terms,
  ) async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    const List<String> roots = <String>['work', 'computer/homes'];
    const Set<String> exts = <String>{
      '.md',
      '.txt',
      '.html',
      '.json',
      '.jsonl',
      '.csv',
      '.log',
    };
    // 文件名里带这些词的一律不读（凭据 / 会话数据，不应出现在搜索结果里）。
    const List<String> blockedNameParts = <String>[
      'cookie',
      'secret',
      'token',
      'credential',
      'password',
    ];
    final String prefix =
        _root.path.endsWith('/') ? _root.path : '${_root.path}/';
    int scannedFiles = 0;
    for (final String root in roots) {
      if (scannedFiles >= maxScanFiles) break;
      final Directory dir = Directory('$prefix$root');
      if (!await dir.exists()) continue;
      await for (final FileSystemEntity e
          in dir.list(recursive: true, followLinks: false)) {
        if (scannedFiles >= maxScanFiles) break;
        if (e is! File) continue;
        final String rel = e.path.startsWith(prefix)
            ? e.path.substring(prefix.length)
            : e.path;
        if (rel.contains('..')) continue;
        final String lowerRel = rel.toLowerCase();
        if (lowerRel.contains('/browser/') ||
            lowerRel.contains('browser-profile')) {
          continue;
        }
        final String fileName =
            e.uri.pathSegments.isEmpty ? '' : e.uri.pathSegments.last;
        final String lowerName = fileName.toLowerCase();
        if (blockedNameParts.any(lowerName.contains)) continue;
        final int dot = lowerName.lastIndexOf('.');
        final String ext = dot < 0 ? '' : lowerName.substring(dot);
        if (!exts.contains(ext)) continue;
        int size;
        try {
          size = await e.length();
        } on Object {
          continue;
        }
        if (size > maxFileBytes) continue;
        String content;
        try {
          content = await e.readAsString();
        } on Object {
          // 二进制 / 无法解码 → 跳过，不伪造内容。
          continue;
        }
        scannedFiles++;
        final String plain = ext == '.html' ? _stripHtml(content) : content;
        final int score = _score(fileName, terms) * 3 + _score(plain, terms);
        if (score == 0) continue;
        out.add(<String, dynamic>{
          'type': 'file',
          'title': fileName,
          'snippet': _snippet(plain.isEmpty ? fileName : plain, terms),
          'content': _clip(plain, 3000),
          'ref': rel.replaceAll('\\', '/'),
          'ts': '',
          'score': score,
        });
      }
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

  /// 词频打分：每词命中次数累加（每词最多计 10 次），全部词都命中时
  /// 额外 +5；单字查询与原来的子串计数完全一致。
  static int _score(String text, List<String> terms) {
    if (text.isEmpty || terms.isEmpty) return 0;
    final String lower = text.toLowerCase();
    int score = 0;
    int matchedTerms = 0;
    for (final String term in terms) {
      int index = lower.indexOf(term);
      if (index < 0) continue;
      matchedTerms++;
      int count = 0;
      while (index >= 0 && count < 10) {
        count++;
        index = lower.indexOf(term, index + term.length);
      }
      score += count;
    }
    if (score == 0) return 0;
    if (terms.length > 1 && matchedTerms == terms.length) score += 5;
    return score;
  }

  /// 命中片段：取任一词最早出现的位置，前后各留上下文；无命中返回截断文本。
  static String _snippet(String text, List<String> terms) {
    final String lower = text.toLowerCase();
    int first = -1;
    String hit = '';
    for (final String term in terms) {
      final int index = lower.indexOf(term);
      if (index >= 0 && (first < 0 || index < first)) {
        first = index;
        hit = term;
      }
    }
    if (first < 0) return _clip(text.trim(), 120);
    final int start = first - 40 < 0 ? 0 : first - 40;
    final int end = first + hit.length + 60 > text.length
        ? text.length
        : first + hit.length + 60;
    final String slice =
        text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
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
