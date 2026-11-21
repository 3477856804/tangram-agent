/// 语音通话记录：真实落盘的会话、逐句转写与状态。
///
/// 与 Rakazo 的 Calls 对齐的持久层部分：
///   * 一次通话一条记录（bot / 开始 / 结束 / 状态 / 逐句转写）；
///   * 转写按说话人区分 user / bot / system，文本上限与条数上限真实校验；
///   * 列表按时间倒序，最多保留 [maxCalls] 条，删除是真删；
///   * 损坏的记录不会伪装成有效通话。
///
/// 通话的语音链路在 UI 层：设备语音识别（speech_to_text）→ chat 控制域 →
/// Edge TTS 播放。本层只负责把真实发生的转写保存下来，不生成任何假内容。
library;

import 'dart:convert';
import 'dart:io';

class CallEntry {
  const CallEntry({
    required this.speaker,
    required this.text,
    required this.ts,
  });

  final String speaker;
  final String text;
  final String ts;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'speaker': speaker,
    'text': text,
    'ts': ts,
  };

  static CallEntry? tryParse(Map raw) {
    final String speaker = '${raw['speaker'] ?? ''}';
    final String text = '${raw['text'] ?? ''}'.trim();
    if (!const <String>['user', 'bot', 'system'].contains(speaker)) return null;
    if (text.isEmpty) return null;
    return CallEntry(
      speaker: speaker,
      text: text.length > 4000 ? '${text.substring(0, 4000)}…' : text,
      ts: '${raw['ts'] ?? ''}',
    );
  }
}

class CallStore {
  CallStore(Directory root) : _file = File('${root.path}/calls.json');

  final File _file;
  List<Map<String, dynamic>>? _records;
  Future<void>? _initFuture;

  static const int maxCalls = 100;
  static const int maxEntries = 500;
  static const Set<String> statuses = <String>{
    'completed',
    'missed',
    'declined',
    'failed',
  };

  Future<void> _ensureInit() => _initFuture ??= _init();

  Future<void> _init() async {
    _records = <Map<String, dynamic>>[];
    if (!await _file.exists()) return;
    try {
      final dynamic decoded = jsonDecode(await _file.readAsString());
      if (decoded is Map && decoded['calls'] is List) {
        _records = (decoded['calls'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .where((Map<String, dynamic> e) => '${e['id'] ?? ''}'.isNotEmpty)
            .toList();
      }
    } on Object {
      // 损坏文件按空态处理。
    }
  }

  Future<void> _save() async {
    final File tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, dynamic>{'calls': _records}),
      flush: true,
    );
    await tmp.rename(_file.path);
  }

  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> p,
  ) async {
    await _ensureInit();
    switch (action) {
      case 'list':
        return _list(p);
      case 'get':
        return _get(p);
      case 'save':
        return _saveCall(p);
      case 'delete':
        return _delete(p);
      case 'stats':
        return _stats();
      default:
        return <String, dynamic>{'ok': false, 'error': '未知通话动作：$action'};
    }
  }

  Future<Map<String, dynamic>> _list(Map<String, dynamic> p) async {
    final int limit = (p['limit'] is num)
        ? (p['limit'] as num).toInt().clamp(1, maxCalls)
        : 50;
    final String query = (p['query'] ?? '').toString().toLowerCase();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> r in _records!) {
      if (query.isNotEmpty &&
          !'${r['bot_name'] ?? ''}'.toLowerCase().contains(query) &&
          !_transcriptText(r).toLowerCase().contains(query)) {
        continue;
      }
      out.add(_sanitize(r));
      if (out.length >= limit) break;
    }
    return <String, dynamic>{
      'ok': true,
      'calls': out,
      'total': _records!.length,
      'note': '只保存真实发生的通话转写；没有通话时不会生成示例。',
    };
  }

  Future<Map<String, dynamic>> _get(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    for (final Map<String, dynamic> r in _records!) {
      if ('${r['id']}' == id) {
        return <String, dynamic>{'ok': true, 'call': r};
      }
    }
    return <String, dynamic>{'ok': false, 'error': '通话不存在'};
  }

  Future<Map<String, dynamic>> _saveCall(Map<String, dynamic> p) async {
    final String botName = (p['bot_name'] ?? '').toString().trim();
    if (botName.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '通话对象不能为空'};
    }
    final DateTime started =
        DateTime.tryParse('${p['started_at']}') ?? DateTime.now();
    final DateTime ended =
        DateTime.tryParse('${p['ended_at']}') ?? DateTime.now();
    if (ended.isBefore(started)) {
      return <String, dynamic>{'ok': false, 'error': '结束时间早于开始时间'};
    }
    final String status = (p['status'] ?? 'completed').toString();
    if (!statuses.contains(status)) {
      return <String, dynamic>{
        'ok': false,
        'error': '状态只能是 ${statuses.join('/')}',
      };
    }
    final List<CallEntry> entries = <CallEntry>[];
    for (final dynamic raw
        in (p['transcript'] is List ? p['transcript'] as List : <dynamic>[])) {
      if (raw is! Map) continue;
      final CallEntry? entry = CallEntry.tryParse(raw);
      if (entry == null) continue;
      entries.add(entry);
      if (entries.length >= maxEntries) break;
    }
    final String id = (p['id'] ?? '').toString().isNotEmpty
        ? '${p['id']}'
        : 'call-${DateTime.now().microsecondsSinceEpoch}';
    final Map<String, dynamic> record = <String, dynamic>{
      'id': id,
      'bot_name': botName,
      'started_at': started.toIso8601String(),
      'ended_at': ended.toIso8601String(),
      'duration_ms': ended.difference(started).inMilliseconds,
      'status': status,
      'muted': p['muted'] == true,
      'transcript': entries.map((CallEntry e) => e.toJson()).toList(),
      'note': (p['note'] ?? '').toString(),
    };
    final int idx =
        _records!.indexWhere((Map<String, dynamic> r) => '${r['id']}' == id);
    if (idx >= 0) {
      _records![idx] = record;
    } else {
      _records!.add(record);
    }
    _records!.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        '${b['started_at']}'.compareTo('${a['started_at']}'));
    while (_records!.length > maxCalls) {
      _records!.removeLast();
    }
    await _save();
    return <String, dynamic>{'ok': true, 'call': record};
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final int before = _records!.length;
    _records!.removeWhere((Map<String, dynamic> r) => '${r['id']}' == id);
    if (_records!.length == before) {
      return <String, dynamic>{'ok': false, 'error': '通话不存在'};
    }
    await _save();
    return <String, dynamic>{'ok': true, 'deleted': id};
  }

  Future<Map<String, dynamic>> _stats() async {
    int completed = 0;
    int missed = 0;
    int failed = 0;
    int duration = 0;
    for (final Map<String, dynamic> r in _records!) {
      switch ('${r['status']}') {
        case 'completed':
          completed++;
          break;
        case 'missed':
          missed++;
          break;
        case 'failed':
          failed++;
          break;
      }
      duration += r['duration_ms'] is num
          ? (r['duration_ms'] as num).toInt()
          : 0;
    }
    return <String, dynamic>{
      'ok': true,
      'total': _records!.length,
      'completed': completed,
      'missed': missed,
      'failed': failed,
      'duration_ms': duration,
    };
  }

  String _transcriptText(Map<String, dynamic> record) {
    final dynamic raw = record['transcript'];
    if (raw is! List) return '';
    final StringBuffer buf = StringBuffer();
    for (final dynamic e in raw) {
      if (e is Map) buf.writeln(e['text'] ?? '');
    }
    return buf.toString();
  }

  Map<String, dynamic> _sanitize(Map<String, dynamic> record) {
    final Map<String, dynamic> copy = Map<String, dynamic>.from(record);
    final dynamic raw = record['transcript'];
    copy['entry_count'] = raw is List ? raw.length : 0;
    copy['transcript'] = raw is List
        ? raw.whereType<Map>().map((Map e) => Map<String, dynamic>.from(e)).toList()
        : <dynamic>[];
    return copy;
  }
}
