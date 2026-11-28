/// 分级审批门 —— Ask / Auto / Deny（Dart 端，主动外发等用户侧动作）。
///
/// 与 Python 侧 `im/approval.py` 同一套语义（clean-room，未复制任何第三
/// 方源码）：
///  * ask（默认）：动作不执行，先记一条待审批，调用方收到 needs-approval；
///  * auto：放行；只有用户显式确认（confirmed=true）才能设为 auto，设置
///    时记录 actor 与时间；
///  * deny：直接拒绝。
///  * 强制拒绝：破坏性 shell（rm -rf / mkfs / dd 等）无视策略一律 deny，
///    与 `security_policy.dart` 的 default-deny-destructive-shell 同规则。
///
/// 批准是一次性的：用户对某条待审批点「批准」后，只放行下一次同一
/// （分类、键、对象）的动作（10 分钟内有效，过期作废；重启后失效），
/// 而不是把该分类永久放开；想长期放行必须显式把策略设为 auto。
///
/// 策略落盘 `approval_policy.json`，待审批落盘 `approval_pending.json`
/// （应用私有目录）。写盘失败只返回错误，绝不抛异常；读盘损坏时按空
/// 策略处理，不冒充数据。纯 Dart，不依赖 Flutter，便于独立回归测试。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tangram/harness/security_policy.dart';

class ApprovalGate {
  ApprovalGate(this.root);

  final Directory root;

  static const String levelAsk = 'ask';
  static const String levelAuto = 'auto';
  static const String levelDeny = 'deny';
  static const List<String> levels = <String>[levelAsk, levelAuto, levelDeny];
  static const String defaultLevel = levelAsk;

  static const String categoryOutbound = 'outbound_send';
  static const String categorySandbox = 'sandbox_exec';
  static const List<String> categories = <String>[
    categoryOutbound,
    categorySandbox,
  ];

  /// 一次性批准的有效期（毫秒）。
  static const int approvalTtlMs = 600 * 1000;

  /// round17：强制拒绝模式直接引用
  /// [PermissionPolicy.destructiveShellArgsPattern]（唯一真源在
  /// security_policy.dart）；Python 侧 im/approval.py 的
  /// `_FORCED_DENY_COMMAND` 与本常量同值，三处同步改。
  static final RegExp _forcedDenyCommand =
      RegExp(PermissionPolicy.destructiveShellArgsPattern);

  static const String _policyFile = 'approval_policy.json';
  static const String _pendingFile = 'approval_pending.json';

  Future<void> _tail = Future<void>.value();

  /// 所有写操作串行执行，避免并发写入把策略文件写乱。
  Future<T> _guard<T>(Future<T> Function() work) {
    final Completer<T> done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        done.complete(await work());
      } on Object catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  File get _policyTarget => File('${root.path}/$_policyFile');
  File get _pendingTarget => File('${root.path}/$_pendingFile');

  /// 一次性批准只存在内存里（重启后失效），与 Python 侧 im/approval.py
  /// 同规则；策略与待审批列表会落盘。
  final List<Map<String, dynamic>> _tokens = <Map<String, dynamic>>[];

  Map<String, dynamic> _readJson(File target) {
    try {
      if (!target.existsSync()) return <String, dynamic>{};
      final dynamic decoded = jsonDecode(target.readAsStringSync());
      if (decoded is Map) {
        return decoded.map(
          (dynamic k, dynamic v) => MapEntry(k.toString(), v),
        );
      }
    } on Object {
      // 损坏文件按空处理，不冒充数据。
    }
    return <String, dynamic>{};
  }

  Future<bool> _writeJson(File target, Map<String, dynamic> data) async {
    try {
      await target.parent.create(recursive: true);
      final File tmp = File('${target.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(target.path);
      return true;
    } on Object catch (e) {
      // 写盘失败只记录，不抛异常、不阻断调用方。
      // ignore: avoid_print
      print('[approval] 写入失败（已忽略）：$e');
      return false;
    }
  }

  Map<String, Map<String, Map<String, dynamic>>> _readLevels() {
    final Map<String, dynamic> raw = _readJson(_policyTarget);
    final Map<String, Map<String, Map<String, dynamic>>> out =
        <String, Map<String, Map<String, dynamic>>>{};
    final dynamic rawLevels = raw['levels'];
    if (rawLevels is! Map) return out;
    for (final MapEntry<dynamic, dynamic> cat in rawLevels.entries) {
      if (cat.value is! Map) continue;
      final Map<String, Map<String, dynamic>> keys =
          <String, Map<String, dynamic>>{};
      for (final MapEntry<dynamic, dynamic> e in cat.value.entries) {
        if (e.value is! Map) continue;
        final String level = '${e.value['level'] ?? ''}';
        if (!ApprovalGate.levels.contains(level)) continue;
        keys[e.key.toString()] = <String, dynamic>{
          'level': level,
          'set_by': '${e.value['set_by'] ?? ''}',
          'set_at': e.value['set_at'] is num
              ? (e.value['set_at'] as num).toDouble()
              : 0.0,
        };
      }
      out[cat.key.toString()] = keys;
    }
    return out;
  }

  List<Map<String, dynamic>> _readPending() {
    final Map<String, dynamic> raw = _readJson(_pendingTarget);
    final dynamic list = raw['pending'];
    if (list is! List) return <Map<String, dynamic>>[];
    return list
        .whereType<Map>()
        .map((Map m) => m.map(
              (dynamic k, dynamic v) => MapEntry(k.toString(), v),
            ))
        .where((Map<String, dynamic> p) => '${p['id'] ?? ''}'.isNotEmpty)
        .toList();
  }

  Future<void> _save(
    Map<String, Map<String, Map<String, dynamic>>> levels,
    List<Map<String, dynamic>> pending,
  ) async {
    await _writeJson(_policyTarget, <String, dynamic>{'levels': levels});
    await _writeJson(_pendingTarget, <String, dynamic>{'pending': pending});
  }

  String _newId() {
    final int now = DateTime.now().microsecondsSinceEpoch;
    final int salt = Random.secure().nextInt(1 << 32);
    return 'appr-${now.toRadixString(36)}-${salt.toRadixString(36)}';
  }

  /// 返回某分类的审批级别；未知分类 / 未设置一律 ask。
  Future<String> decide(String category, {String key = ''}) async {
    final Map<String, Map<String, Map<String, dynamic>>> levels =
        _readLevels();
    final Map<String, Map<String, dynamic>>? byKey = levels[category];
    Map<String, dynamic>? item = byKey?[key] ?? byKey?[''];
    if (item == null) return defaultLevel;
    final String level = '${item['level'] ?? ''}';
    return ApprovalGate.levels.contains(level) ? level : defaultLevel;
  }

  /// 沙箱命令的判定：破坏性命令强制 deny，其余走 sandbox_exec 策略。
  Future<String> decideSandbox(String command) async {
    if (_forcedDenyCommand.hasMatch(command)) return levelDeny;
    return decide(categorySandbox);
  }

  /// 设置某分类的级别。设为 auto 必须 confirmed=true（用户显式确认），
  /// 否则返回错误且不改策略；ask / deny 不要求确认。
  Future<Map<String, dynamic>> setLevel({
    required String category,
    String key = '',
    required String level,
    String actor = 'user',
    bool confirmed = false,
  }) {
    return _guard(() async {
      if (!categories.contains(category)) {
        return <String, dynamic>{'ok': false, 'error': '未知审批分类：$category'};
      }
      if (!levels.contains(level)) {
        return <String, dynamic>{'ok': false, 'error': '未知审批级别：$level'};
      }
      if (level == levelAuto && !confirmed) {
        return <String, dynamic>{
          'ok': false,
          'error': '设为 auto（不再询问）需要用户显式确认：confirmed=true',
        };
      }
      final Map<String, Map<String, Map<String, dynamic>>> all = _readLevels();
      final List<Map<String, dynamic>> pending = _readPending();
      all.putIfAbsent(category, () => <String, Map<String, dynamic>>{});
      all[category]![key] = <String, dynamic>{
        'level': level,
        'set_by': actor,
        'set_at': DateTime.now().millisecondsSinceEpoch / 1000.0,
      };
      await _save(all, pending);
      return <String, dynamic>{
        'ok': true,
        'category': category,
        'key': key,
        'level': level,
      };
    });
  }

  /// 返回当前策略快照（只含级别与设置记录，不含任何密钥）。
  Future<Map<String, dynamic>> getPolicy() async {
    return <String, dynamic>{'ok': true, 'levels': _readLevels()};
  }

  /// 记一条待审批并返回它（detail 只放元数据，绝不放消息正文与密钥）。
  Future<Map<String, dynamic>> requestApproval({
    required String category,
    String key = '',
    String subject = '',
    String detail = '',
    String actor = 'system',
  }) {
    return _guard(() async {
      final Map<String, Map<String, Map<String, dynamic>>> all = _readLevels();
      final List<Map<String, dynamic>> pending = _readPending();
      final Map<String, dynamic> entry = <String, dynamic>{
        'id': _newId(),
        'category': category,
        'key': key,
        'subject': subject,
        'detail': detail.length > 500 ? detail.substring(0, 500) : detail,
        'actor': actor,
        'created_at': DateTime.now().millisecondsSinceEpoch / 1000.0,
        'status': 'pending',
      };
      pending.add(entry);
      final List<Map<String, dynamic>> kept = pending.length > 200
          ? pending.sublist(pending.length - 200)
          : pending;
      await _save(all, kept);
      return Map<String, dynamic>.from(entry);
    });
  }

  /// 列出全部待审批（按创建时间升序）。
  Future<List<Map<String, dynamic>>> listPending() async {
    return _readPending();
  }

  /// 处理一条待审批：allow 为真时记一枚一次性批准（10 分钟内、同一
  /// 分类/键/对象只放行一次），否则直接拒绝。处理后该记录从待审批列表
  /// 移除，返回原记录；不存在返回 null。
  Future<Map<String, dynamic>?> resolveApproval(
    String id,
    bool allow, {
    String actor = 'user',
  }) {
    return _guard(() async {
      final Map<String, Map<String, Map<String, dynamic>>> all = _readLevels();
      final List<Map<String, dynamic>> pending = _readPending();
      final int index = pending.indexWhere((Map<String, dynamic> p) => p['id'] == id);
      if (index < 0) return null;
      final Map<String, dynamic> resolved =
          Map<String, dynamic>.from(pending[index]);
      final double now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      resolved['status'] = allow ? 'approved' : 'rejected';
      resolved['resolved_by'] = actor;
      resolved['resolved_at'] = now;
      pending.removeAt(index);
      await _save(all, pending);
      if (allow) {
        _tokens.add(<String, dynamic>{
          'category': resolved['category'],
          'key': resolved['key'],
          'subject': resolved['subject'],
          'approved_at': now,
          'expires_at': now + approvalTtlMs / 1000.0,
        });
      }
      return resolved;
    });
  }

  /// 消耗一枚一次性批准：同一分类/键/对象、未过期的才算数，命中即删除。
  /// 只查内存（重启后失效），不读盘。
  Future<bool> consumeApproval(
    String category, {
    String key = '',
    String subject = '',
  }) {
    return _guard(() async {
      final double now = DateTime.now().millisecondsSinceEpoch / 1000.0;
      _tokens.removeWhere((Map<String, dynamic> t) {
        final double expires = t['expires_at'] is num
            ? (t['expires_at'] as num).toDouble()
            : 0.0;
        return expires <= now;
      });
      final int index = _tokens.indexWhere((Map<String, dynamic> t) =>
          t['category'] == category &&
          t['key'] == key &&
          t['subject'] == subject);
      if (index < 0) return false;
      _tokens.removeAt(index);
      return true;
    });
  }
}
