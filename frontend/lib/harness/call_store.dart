/// 语音通话记录：真实落盘的会话、逐句转写与状态。
///
/// 与 Rakazo 的 Calls 对齐的持久层部分：
///   * 一次通话一条记录（bot / 开始 / 结束 / 状态 / 逐句转写）；
///   * 转写按说话人区分 user / bot / system，文本上限与条数上限真实校验；
///   * 列表按时间倒序，最多保留 [maxCalls] 条，删除是真删；
///   * 损坏的记录不会伪装成有效通话。
///   * 主动外呼（OutboundCallRequest）：只调度与记录，不实际拨打真实电话；
///     未接来电自动建待回拨记录（MissedCallCallback，pending/done/skipped）。
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

/// bot 主动外呼请求：只做「调度与记录」，不实际拨打真实电话。
///
/// 调度入口：[CallStore.dueOutboundCalls]（到期未处理的外呼）+ handle 的
/// `record_outbound_attempt`（记录一次调度尝试并推进重试/终态）。
/// Routines 是按 prompt 运行的例程、没有动作分发，因此这里不硬接 Routines；
/// 干净的接线方式是：建一个 cron 触发的 Routine（prompt 写「检查并处理到期的
/// 外呼请求」），由例程执行方调 `due_outbound` + `record_outbound_attempt`；
/// 同样可由 Python 侧 TaskScheduler 按同一入口轮询。真实拨打链路
/// （PSTN / SIP / 会议 bot 入会）未实现——本层绝不假装已拨出。
class OutboundCallRequest {
  const OutboundCallRequest({
    required this.id,
    required this.botName,
    required this.reason,
    required this.scheduledAt,
    required this.maxAttempts,
    required this.attempts,
    required this.nextAttemptAt,
    required this.status,
    required this.createdAt,
    this.lastNote = '',
  });

  final String id;
  final String botName;
  final String reason;
  final DateTime scheduledAt;
  final int maxAttempts;
  final int attempts;
  final DateTime? nextAttemptAt;
  final String status;
  final DateTime createdAt;
  final String lastNote;

  /// 外呼状态：scheduled 待执行 / completed 已接通（调度方确认）/
  /// failed 重试耗尽 / cancelled 已取消。`due` 是计算态，不落盘。
  static const Set<String> statuses = <String>{
    'scheduled',
    'completed',
    'failed',
    'cancelled',
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'bot_name': botName,
    'reason': reason,
    'scheduled_at': scheduledAt.toIso8601String(),
    'max_attempts': maxAttempts,
    'attempts': attempts,
    'next_attempt_at': nextAttemptAt?.toIso8601String(),
    'status': status,
    'created_at': createdAt.toIso8601String(),
    'last_note': lastNote,
  };

  static OutboundCallRequest? tryParse(Map raw) {
    final String id = '${raw['id'] ?? ''}';
    final String botName = '${raw['bot_name'] ?? ''}'.trim();
    final DateTime? scheduledAt =
        DateTime.tryParse('${raw['scheduled_at'] ?? ''}');
    final int maxAttempts =
        raw['max_attempts'] is num ? (raw['max_attempts'] as num).toInt() : 0;
    final int attempts =
        raw['attempts'] is num ? (raw['attempts'] as num).toInt() : 0;
    final String status = '${raw['status'] ?? ''}';
    if (id.isEmpty || botName.isEmpty || scheduledAt == null) return null;
    if (!statuses.contains(status)) return null;
    if (maxAttempts < 1 || maxAttempts > 5) return null;
    if (attempts < 0 || attempts > maxAttempts) return null;
    return OutboundCallRequest(
      id: id,
      botName: botName,
      reason: '${raw['reason'] ?? ''}',
      scheduledAt: scheduledAt,
      maxAttempts: maxAttempts,
      attempts: attempts,
      nextAttemptAt: DateTime.tryParse('${raw['next_attempt_at'] ?? ''}'),
      status: status,
      createdAt: DateTime.tryParse('${raw['created_at'] ?? ''}') ?? scheduledAt,
      lastNote: '${raw['last_note'] ?? ''}',
    );
  }

  OutboundCallRequest copyWith({
    int? attempts,
    DateTime? nextAttemptAt,
    bool clearNextAttempt = false,
    String? status,
    String? lastNote,
  }) =>
      OutboundCallRequest(
        id: id,
        botName: botName,
        reason: reason,
        scheduledAt: scheduledAt,
        maxAttempts: maxAttempts,
        attempts: attempts ?? this.attempts,
        nextAttemptAt:
            clearNextAttempt ? null : (nextAttemptAt ?? this.nextAttemptAt),
        status: status ?? this.status,
        createdAt: createdAt,
        lastNote: lastNote ?? this.lastNote,
      );
}

/// 未接来电回拨记录：通话 status=missed 落盘时自动建一条 pending；
/// 用户回拨后由界面调 `mark_callback` 置 done / skipped。
class MissedCallCallback {
  const MissedCallCallback({
    required this.callId,
    required this.botName,
    required this.status,
    required this.createdAt,
    this.doneAt,
  });

  final String callId;
  final String botName;
  final String status;
  final DateTime createdAt;
  final DateTime? doneAt;

  /// 回拨状态：pending 待回拨 / done 已回拨 / skipped 已忽略。
  static const Set<String> statuses = <String>{
    'pending',
    'done',
    'skipped',
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'call_id': callId,
    'bot_name': botName,
    'status': status,
    'created_at': createdAt.toIso8601String(),
    'done_at': doneAt?.toIso8601String(),
  };

  static MissedCallCallback? tryParse(Map raw) {
    final String callId = '${raw['call_id'] ?? ''}';
    final String botName = '${raw['bot_name'] ?? ''}'.trim();
    final String status = '${raw['status'] ?? ''}';
    if (callId.isEmpty || botName.isEmpty) return null;
    if (!statuses.contains(status)) return null;
    return MissedCallCallback(
      callId: callId,
      botName: botName,
      status: status,
      createdAt: DateTime.tryParse('${raw['created_at'] ?? ''}') ?? DateTime.now(),
      doneAt: DateTime.tryParse('${raw['done_at'] ?? ''}'),
    );
  }

  MissedCallCallback copyWith({String? status, DateTime? doneAt}) =>
      MissedCallCallback(
        callId: callId,
        botName: botName,
        status: status ?? this.status,
        createdAt: createdAt,
        doneAt: doneAt ?? this.doneAt,
      );
}

class CallStore {
  CallStore(Directory root)
      : _file = File('${root.path}/calls.json'),
        _outboundFile = File('${root.path}/outbound_calls.json');

  final File _file;
  final File _outboundFile;
  List<Map<String, dynamic>>? _records;
  Future<void>? _initFuture;

  /// 外呼重试退避：与 Routines 的 60s / 300s / 900s 同一套节拍。
  static const List<Duration> outboundRetryBackoff = <Duration>[
    Duration(seconds: 60),
    Duration(seconds: 300),
    Duration(seconds: 900),
  ];

  /// 外呼与回拨记录的保留上限。
  static const int maxOutbound = 100;
  static const int maxCallbacks = 100;

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
    _outbound = <Map<String, dynamic>>[];
    _callbacks = <Map<String, dynamic>>[];
    if (!await _file.exists()) {
      await _loadOutbound();
      return;
    }
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
    await _loadOutbound();
  }

  /// 外呼与回拨记录与通话记录分文件存放：损坏的外呼文件不影响通话记录。
  List<Map<String, dynamic>> _outbound = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _callbacks = <Map<String, dynamic>>[];

  Future<void> _loadOutbound() async {
    if (!await _outboundFile.exists()) return;
    try {
      final dynamic decoded = jsonDecode(await _outboundFile.readAsString());
      if (decoded is! Map) return;
      if (decoded['outbound'] is List) {
        _outbound = (decoded['outbound'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .where((Map<String, dynamic> e) =>
                OutboundCallRequest.tryParse(e) != null)
            .toList();
      }
      if (decoded['callbacks'] is List) {
        _callbacks = (decoded['callbacks'] as List)
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .where((Map<String, dynamic> e) =>
                MissedCallCallback.tryParse(e) != null)
            .toList();
      }
    } on Object {
      // 损坏文件按空态处理。
    }
  }

  Future<void> _saveOutbound() async {
    final File tmp = File('${_outboundFile.path}.tmp');
    await tmp.writeAsString(
      jsonEncode(<String, dynamic>{
        'outbound': _outbound,
        'callbacks': _callbacks,
      }),
      flush: true,
    );
    await tmp.rename(_outboundFile.path);
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
      case 'schedule_outbound':
        return _scheduleOutbound(p);
      case 'list_outbound':
        return _listOutbound(p);
      case 'due_outbound':
        return _dueOutbound(p);
      case 'cancel_outbound':
        return _cancelOutbound(p);
      case 'record_outbound_attempt':
        return _recordOutboundAttempt(p);
      case 'list_callbacks':
        return _listCallbacks(p);
      case 'mark_callback':
        return _markCallback(p);
      default:
        return <String, dynamic>{'ok': false, 'error': '未知通话动作：$action'};
    }
  }

  // ---- 主动外呼（调度与记录，不实际拨打真实电话） ----

  /// 到期的外呼请求：status=scheduled 且 next_attempt_at 已到。
  /// 调度入口：Routine（cron 触发，prompt 写「检查并处理到期的外呼请求」）
  /// 或 TaskScheduler 轮询本方法；执行方负责真实拨打，本层只给清单。
  Future<List<OutboundCallRequest>> dueOutboundCalls({
    DateTime? now,
  }) async {
    await _ensureInit();
    final DateTime at = now ?? DateTime.now();
    final List<OutboundCallRequest> out = <OutboundCallRequest>[];
    for (final Map<String, dynamic> raw in _outbound) {
      final OutboundCallRequest? req = OutboundCallRequest.tryParse(raw);
      if (req == null || req.status != 'scheduled') continue;
      final DateTime dueAt = req.nextAttemptAt ?? req.scheduledAt;
      if (!dueAt.isAfter(at)) out.add(req);
    }
    out.sort((OutboundCallRequest a, OutboundCallRequest b) =>
        (a.nextAttemptAt ?? a.scheduledAt)
            .compareTo(b.nextAttemptAt ?? b.scheduledAt));
    return out;
  }

  Future<Map<String, dynamic>> _scheduleOutbound(
    Map<String, dynamic> p,
  ) async {
    final String botName = (p['bot_name'] ?? '').toString().trim();
    if (botName.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '外呼对象不能为空'};
    }
    final String reason = (p['reason'] ?? '').toString().trim();
    if (reason.length > 200) {
      return <String, dynamic>{'ok': false, 'error': '外呼原因不能超过 200 字'};
    }
    final DateTime? scheduledAt = DateTime.tryParse('${p['scheduled_at']}');
    if (scheduledAt == null) {
      return <String, dynamic>{'ok': false, 'error': '约定时间格式无效'};
    }
    final int maxAttempts =
        p['max_attempts'] is num ? (p['max_attempts'] as num).toInt() : 3;
    if (maxAttempts < 1 || maxAttempts > 5) {
      return <String, dynamic>{'ok': false, 'error': '最多重试只能是 1~5 次'};
    }
    final String id = (p['id'] ?? '').toString().isNotEmpty
        ? '${p['id']}'
        : 'out-${DateTime.now().microsecondsSinceEpoch}';
    final OutboundCallRequest req = OutboundCallRequest(
      id: id,
      botName: botName,
      reason: reason,
      scheduledAt: scheduledAt,
      maxAttempts: maxAttempts,
      attempts: 0,
      nextAttemptAt: scheduledAt,
      status: 'scheduled',
      createdAt: DateTime.now(),
    );
    final int idx = _outbound
        .indexWhere((Map<String, dynamic> r) => '${r['id']}' == id);
    if (idx >= 0) {
      _outbound[idx] = req.toJson();
    } else {
      _outbound.add(req.toJson());
    }
    _outbound.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        '${a['scheduled_at']}'.compareTo('${b['scheduled_at']}'));
    while (_outbound.length > maxOutbound) {
      _outbound.removeLast();
    }
    await _saveOutbound();
    return <String, dynamic>{
      'ok': true,
      'outbound': req.toJson(),
      'note': '仅已排期，未实际拨打：拨打由调度方在约定时间执行。',
    };
  }

  Future<Map<String, dynamic>> _listOutbound(Map<String, dynamic> p) async {
    final String status = (p['status'] ?? '').toString();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> raw in _outbound) {
      final OutboundCallRequest? req = OutboundCallRequest.tryParse(raw);
      if (req == null) continue;
      if (status.isNotEmpty && req.status != status) continue;
      out.add(req.toJson());
      if (out.length >= maxOutbound) break;
    }
    return <String, dynamic>{'ok': true, 'outbound': out};
  }

  Future<Map<String, dynamic>> _dueOutbound(Map<String, dynamic> p) async {
    final DateTime now =
        DateTime.tryParse('${p['now'] ?? ''}') ?? DateTime.now();
    final List<OutboundCallRequest> due =
        await dueOutboundCalls(now: now);
    return <String, dynamic>{
      'ok': true,
      'due': due.map((OutboundCallRequest r) => r.toJson()).toList(),
      'note': '到期未处理的外呼请求；本层不拨打，只给清单。',
    };
  }

  Future<Map<String, dynamic>> _cancelOutbound(
    Map<String, dynamic> p,
  ) async {
    final String id = (p['id'] ?? '').toString();
    for (int i = 0; i < _outbound.length; i++) {
      final OutboundCallRequest? req =
          OutboundCallRequest.tryParse(_outbound[i]);
      if (req == null || req.id != id) continue;
      if (req.status != 'scheduled') {
        return <String, dynamic>{
          'ok': false,
          'error': '只有待执行的外呼可以取消（当前：${req.status}）',
        };
      }
      final OutboundCallRequest cancelled =
          req.copyWith(status: 'cancelled', clearNextAttempt: true);
      _outbound[i] = cancelled.toJson();
      await _saveOutbound();
      return <String, dynamic>{'ok': true, 'outbound': cancelled.toJson()};
    }
    return <String, dynamic>{'ok': false, 'error': '外呼请求不存在'};
  }

  /// 记录一次调度尝试：`reached=true` 表示调度方确认已接通 → completed；
  /// 否则 attempts+1，未耗尽按 60s/300s/900s 退避约到下一次，耗尽 → failed。
  /// 本层不拨打电话，`reached` 的真实性由调度方负责。
  Future<Map<String, dynamic>> _recordOutboundAttempt(
    Map<String, dynamic> p,
  ) async {
    final String id = (p['id'] ?? '').toString();
    final bool reached = p['reached'] == true;
    final String note = (p['note'] ?? '').toString().trim();
    if (note.length > 200) {
      return <String, dynamic>{'ok': false, 'error': '备注不能超过 200 字'};
    }
    final DateTime now =
        DateTime.tryParse('${p['now'] ?? ''}') ?? DateTime.now();
    for (int i = 0; i < _outbound.length; i++) {
      final OutboundCallRequest? req =
          OutboundCallRequest.tryParse(_outbound[i]);
      if (req == null || req.id != id) continue;
      if (req.status != 'scheduled') {
        return <String, dynamic>{
          'ok': false,
          'error': '只有待执行的外呼可以记录尝试（当前：${req.status}）',
        };
      }
      final OutboundCallRequest updated;
      if (reached) {
        updated = req.copyWith(
          status: 'completed',
          clearNextAttempt: true,
          lastNote: note,
        );
      } else {
        final int attempts = req.attempts + 1;
        if (attempts >= req.maxAttempts) {
          updated = req.copyWith(
            attempts: attempts,
            status: 'failed',
            clearNextAttempt: true,
            lastNote: note,
          );
        } else {
          final Duration backoff = outboundRetryBackoff[
              (attempts - 1).clamp(0, outboundRetryBackoff.length - 1)];
          updated = req.copyWith(
            attempts: attempts,
            nextAttemptAt: now.add(backoff),
            lastNote: note,
          );
        }
      }
      _outbound[i] = updated.toJson();
      await _saveOutbound();
      return <String, dynamic>{'ok': true, 'outbound': updated.toJson()};
    }
    return <String, dynamic>{'ok': false, 'error': '外呼请求不存在'};
  }

  // ---- 未接来电回拨 ----

  /// 未接通话落盘时自动建一条 pending 回拨（同一通话只建一次）。
  Future<void> _ensureMissedCallback(
    String callId,
    String botName,
  ) async {
    for (final Map<String, dynamic> raw in _callbacks) {
      if ('${raw['call_id']}' == callId) return;
    }
    _callbacks.add(MissedCallCallback(
      callId: callId,
      botName: botName,
      status: 'pending',
      createdAt: DateTime.now(),
    ).toJson());
    while (_callbacks.length > maxCallbacks) {
      _callbacks.removeAt(0);
    }
    await _saveOutbound();
  }

  Future<Map<String, dynamic>> _listCallbacks(Map<String, dynamic> p) async {
    final String status = (p['status'] ?? '').toString();
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> raw in _callbacks) {
      final MissedCallCallback? cb = MissedCallCallback.tryParse(raw);
      if (cb == null) continue;
      if (status.isNotEmpty && cb.status != status) continue;
      out.add(cb.toJson());
    }
    return <String, dynamic>{'ok': true, 'callbacks': out};
  }

  Future<Map<String, dynamic>> _markCallback(Map<String, dynamic> p) async {
    final String callId = (p['call_id'] ?? '').toString();
    final String status = (p['status'] ?? '').toString();
    if (!MissedCallCallback.statuses.contains(status) ||
        status == 'pending') {
      return <String, dynamic>{
        'ok': false,
        'error': '回拨状态只能是 done / skipped',
      };
    }
    for (int i = 0; i < _callbacks.length; i++) {
      final MissedCallCallback? cb =
          MissedCallCallback.tryParse(_callbacks[i]);
      if (cb == null || cb.callId != callId) continue;
      if (cb.status != 'pending') {
        return <String, dynamic>{
          'ok': false,
          'error': '该回拨已处理（当前：${cb.status}）',
        };
      }
      final MissedCallCallback updated =
          cb.copyWith(status: status, doneAt: DateTime.now());
      _callbacks[i] = updated.toJson();
      await _saveOutbound();
      return <String, dynamic>{'ok': true, 'callback': updated.toJson()};
    }
    return <String, dynamic>{'ok': false, 'error': '回拨记录不存在'};
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
    // 未接来电自动建一条待回拨记录（同一通话只建一次，见 _ensureMissedCallback）。
    if (status == 'missed') {
      await _ensureMissedCallback(id, botName);
    }
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
