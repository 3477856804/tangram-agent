/// AI 账号自主运营（人工确认）：账号、草稿、审批、发布与审计。
///
/// 设计红线：
///  * 账号只保存 `credential_ref`（凭据**引用**，如 `env:WECHAT_TOKEN`），
///    绝不保存明文密钥；检测到疑似明文密钥直接拒绝落盘。
///  * 草稿状态机：draft → pending → approved / rejected → published / failed。
///  * **publish 只允许 approved 草稿调用注入的 send**；send 失败 / 抛异常时
///    如实写 failed 与错误，绝不伪造 published。
///  * 审计日志 append-only：账号增删启停、草稿创建提交审批发布全部留痕。
///  * 平台规则（不刷量 / 不造假 / 人工确认）作为只读字段返回，不做假开关。
///
/// 落盘：`account_ops.json`。

import 'store.dart';

typedef AccountSender = Future<Map<String, dynamic>> Function(
  String channel,
  Map<String, dynamic> payload,
);

class AccountOps {
  AccountOps(this.store, {required this.send});

  final HarnessStore store;
  final AccountSender send;

  static const String _file = 'account_ops.json';

  /// 平台规则提示：只读字段，不存在“自动刷量”“跳过人工确认”的开关。
  static const List<String> platformRules = <String>[
    '不刷量：不购买或伪造阅读、点赞、评论、粉丝、播放等数据',
    '不造假：不虚构用户评价、销量、效果或平台认证',
    '遵守平台规则：发布前核对广告标识、版权与敏感词要求',
    '人工确认：草稿必须经人工 approve 后才允许调用发布通道',
  ];

  Map<String, dynamic>? _data;

  Future<Map<String, dynamic>> _load() async {
    final Map<String, dynamic>? cached = _data;
    if (cached != null) return cached;
    final Map<String, dynamic> raw = await store.readJson(
      _file,
      fallback: <String, dynamic>{
        'version': 1,
        'accounts': <dynamic>[],
        'drafts': <dynamic>[],
        'interactions': <dynamic>[],
        'orders': <dynamic>[],
        'audit': <dynamic>[],
      },
    );
    for (final String key in <String>[
      'accounts',
      'drafts',
      'interactions',
      'orders',
      'audit',
    ]) {
      raw[key] = raw[key] is List
          ? (raw[key] as List)
              .whereType<Map>()
              .map((Map e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
    }
    _data = raw;
    return raw;
  }

  List<Map<String, dynamic>> _list(String key) {
    final dynamic raw = _data?[key];
    if (raw is List<Map<String, dynamic>>) return raw;
    final List<Map<String, dynamic>> list = (raw is List ? raw : <dynamic>[])
        .whereType<Map>()
        .map((Map e) => Map<String, dynamic>.from(e))
        .toList();
    _data?[key] = list;
    return list;
  }

  List<Map<String, dynamic>> get _accounts => _list('accounts');
  List<Map<String, dynamic>> get _drafts => _list('drafts');
  List<Map<String, dynamic>> get _interactions => _list('interactions');
  List<Map<String, dynamic>> get _orders => _list('orders');
  List<Map<String, dynamic>> get _auditLog => _list('audit');

  Future<void> _save() async {
    final Map<String, dynamic> data = _data ?? <String, dynamic>{};
    data['updated_at'] = DateTime.now().toIso8601String();
    await store.writeJson(_file, data);
  }

  String _id(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  Map<String, dynamic>? _findAccount(String id) {
    for (final Map<String, dynamic> a in _accounts) {
      if (a['id'] == id) return a;
    }
    return null;
  }

  Map<String, dynamic>? _findDraft(String id) {
    for (final Map<String, dynamic> d in _drafts) {
      if (d['id'] == id) return d;
    }
    return null;
  }

  // ---- 审计（append-only）----

  Map<String, dynamic> _appendAudit({
    required String action,
    required String object,
    String actor = 'system',
    String detail = '',
    Map<String, dynamic>? draft,
  }) {
    final Map<String, dynamic> entry = <String, dynamic>{
      'id': _id('audit'),
      'ts': DateTime.now().toIso8601String(),
      'actor': actor,
      'action': action,
      'object': object,
      'detail': detail,
    };
    _auditLog.add(entry);
    if (draft != null) {
      final List<dynamic> history =
          draft['audit'] is List ? List<dynamic>.from(draft['audit'] as List) : <dynamic>[];
      history.add(Map<String, dynamic>.from(entry));
      draft['audit'] = history;
    }
    return entry;
  }

  // ---- 账号 ----

  Future<List<Map<String, dynamic>>> listAccounts() async {
    await _load();
    return _accounts.map(_copyAccount).toList();
  }

  Future<List<Map<String, dynamic>>> accounts() => listAccounts();

  Future<Map<String, dynamic>> addAccount({
    required String channel,
    required String name,
    required String credentialRef,
  }) async {
    final String ch = channel.trim();
    final String n = name.trim();
    final String ref = credentialRef;
    if (ch.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '渠道不能为空'};
    }
    if (n.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '账号名称不能为空'};
    }
    final String? refError = _credentialRefError(ref);
    if (refError != null) {
      return <String, dynamic>{'ok': false, 'error': refError};
    }
    await _load();
    for (final Map<String, dynamic> a in _accounts) {
      if (a['channel'] == ch && a['name'] == n) {
        return <String, dynamic>{'ok': false, 'error': '同渠道下账号名称已存在'};
      }
    }
    final String now = DateTime.now().toIso8601String();
    final Map<String, dynamic> account = <String, dynamic>{
      'id': _id('acct'),
      'channel': ch,
      'name': n,
      // 只保存引用，绝不保存明文密钥。
      'credential_ref': ref,
      'enabled': true,
      'created_at': now,
      'updated_at': now,
    };
    _accounts.add(account);
    _appendAudit(
      action: 'account.add',
      object: account['id'].toString(),
      actor: 'human',
      detail: '$ch/$n（credential_ref=$ref）',
    );
    await _save();
    return <String, dynamic>{'ok': true, 'account': _copyAccount(account)};
  }

  Future<Map<String, dynamic>> removeAccount(String id) async {
    await _load();
    final Map<String, dynamic>? account = _findAccount(id);
    if (account == null) {
      return <String, dynamic>{'ok': false, 'error': '账号不存在'};
    }
    _accounts.remove(account);
    _appendAudit(
      action: 'account.remove',
      object: id,
      actor: 'human',
      detail: '${account['channel']}/${account['name']}',
    );
    await _save();
    return <String, dynamic>{'ok': true, 'deleted': id};
  }

  Future<Map<String, dynamic>> toggleAccount(String id, bool enabled) async {
    await _load();
    final Map<String, dynamic>? account = _findAccount(id);
    if (account == null) {
      return <String, dynamic>{'ok': false, 'error': '账号不存在'};
    }
    account['enabled'] = enabled;
    account['updated_at'] = DateTime.now().toIso8601String();
    _appendAudit(
      action: enabled ? 'account.enable' : 'account.disable',
      object: id,
      actor: 'human',
      detail: '${account['channel']}/${account['name']}',
    );
    await _save();
    return <String, dynamic>{'ok': true, 'account': _copyAccount(account)};
  }

  /// 检测疑似明文密钥；返回错误文案，合法引用返回 null。
  String? _credentialRefError(String ref) {
    if (ref.isEmpty) return 'credential_ref 不能为空，请填写凭据引用';
    if (ref.trim() != ref) return 'credential_ref 不能包含首尾空格';
    if (ref.contains('\n') || ref.contains('\r')) {
      return 'credential_ref 不能包含换行';
    }
    final String lower = ref.toLowerCase();
    if (RegExp(r'^(sk-|pk-|ghp_|gho_|github_pat_|xox[abprs]-|akia|aiza|glpat-|bearer[:\s])')
        .hasMatch(lower)) {
      return '检测到明文密钥，拒绝保存；请填写凭据引用（如 env:WECHAT_TOKEN）';
    }
    if (ref.contains('-----BEGIN')) {
      return '检测到私钥内容，拒绝保存；请填写凭据引用';
    }
    if (RegExp(r'^eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.').hasMatch(ref)) {
      return '检测到 JWT 明文令牌，拒绝保存；请填写凭据引用';
    }
    final bool hasScheme =
        RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(ref);
    final bool isSlug =
        RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$').hasMatch(ref);
    if (!hasScheme && !isSlug) {
      if (RegExp(r'^[A-Za-z0-9+/=_-]{20,}$').hasMatch(ref)) {
        return '检测到疑似明文密钥，拒绝保存；请填写凭据引用';
      }
      return '请填写凭据引用（如 env:WECHAT_TOKEN / vault://...），不要填写明文密钥';
    }
    return null;
  }

  Map<String, dynamic> _copyAccount(Map<String, dynamic> a) =>
      Map<String, dynamic>.from(a);

  /// 互动/订单只允许业务元数据：命中疑似密钥形态时拒绝落盘。
  bool _containsLikelySecret(String text) {
    final String lower = text.toLowerCase();
    if (RegExp(
            r'(sk-|pk-|ghp_|gho_|github_pat_|xox[abprs]-|akia|aiza|glpat-|bearer[:\s])')
        .hasMatch(lower)) {
      return true;
    }
    if (text.contains('-----BEGIN')) return true;
    if (RegExp(r'^eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.')
        .hasMatch(text.trim())) {
      return true;
    }
    // 长串高熵 token（Base64/十六进制形态）同样不写入业务记录。
    return RegExp(r'[A-Za-z0-9+/=_-]{32,}').hasMatch(text);
  }

  // ---- 互动记录（只存业务元数据，不存密钥/隐私正文）----

  Future<List<Map<String, dynamic>>> listInteractions({
    String accountId = '',
    String direction = '',
    String status = '',
    int limit = 0,
  }) async {
    await _load();
    final String acct = accountId.trim();
    final String dir = direction.trim();
    final String st = status.trim();
    final List<Map<String, dynamic>> filtered = _interactions
        .where((Map<String, dynamic> i) {
      if (acct.isNotEmpty && (i['account_id'] ?? '').toString() != acct) {
        return false;
      }
      if (dir.isNotEmpty && (i['direction'] ?? '').toString() != dir) {
        return false;
      }
      if (st.isNotEmpty && (i['status'] ?? '').toString() != st) return false;
      return true;
    }).toList();
    final List<Map<String, dynamic>> newestFirst =
        filtered.reversed.map(_copyInteraction).toList();
    if (limit > 0 && newestFirst.length > limit) {
      return newestFirst.sublist(0, limit);
    }
    return newestFirst;
  }

  Future<Map<String, dynamic>> addInteraction({
    required String channel,
    required String accountId,
    required String target,
    required String direction,
    required String summary,
    String status = 'logged',
    String at = '',
  }) async {
    await _load();
    final String acctId = accountId.trim();
    final Map<String, dynamic>? account =
        acctId.isEmpty ? null : _findAccount(acctId);
    if (acctId.isNotEmpty && account == null) {
      return <String, dynamic>{'ok': false, 'error': '账号不存在'};
    }
    final String ch = channel.trim().isEmpty
        ? (account?['channel'] ?? '').toString()
        : channel.trim();
    if (ch.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '渠道不能为空'};
    }
    final String dir = direction.trim().toLowerCase();
    if (dir != 'in' && dir != 'out') {
      return <String, dynamic>{'ok': false, 'error': 'direction 只能是 in 或 out'};
    }
    final String text = summary.trim();
    if (text.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '互动摘要不能为空'};
    }
    if (text.length > 500) {
      return <String, dynamic>{
        'ok': false,
        'error': '互动摘要过长（最多 500 字），请只记录业务元数据',
      };
    }
    if (_containsLikelySecret(text)) {
      return <String, dynamic>{
        'ok': false,
        'error': '互动摘要疑似包含明文密钥，拒绝保存；只记录业务元数据',
      };
    }
    final String time = at.trim();
    if (time.isNotEmpty && DateTime.tryParse(time) == null) {
      return <String, dynamic>{
        'ok': false,
        'error': 'at 不是有效的 ISO8601 时间',
      };
    }
    final String now = DateTime.now().toIso8601String();
    final Map<String, dynamic> record = <String, dynamic>{
      'id': _id('intr'),
      'channel': ch,
      'account_id': acctId,
      'target': target.trim(),
      'direction': dir,
      'summary': text,
      'status': status.trim().isEmpty ? 'logged' : status.trim(),
      'at': time.isEmpty ? now : time,
      'created_at': now,
      'updated_at': now,
    };
    _interactions.add(record);
    _appendAudit(
      action: 'interaction.add',
      object: record['id'].toString(),
      actor: 'human',
      detail: '$dir/$ch → ${record['target']}',
    );
    await _save();
    return <String, dynamic>{'ok': true, 'interaction': _copyInteraction(record)};
  }

  Future<Map<String, dynamic>> updateInteractionStatus(
      String id, String status) async {
    await _load();
    final String st = status.trim();
    if (st.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '状态不能为空'};
    }
    for (final Map<String, dynamic> i in _interactions) {
      if ((i['id'] ?? '').toString() != id) continue;
      final String before = (i['status'] ?? '').toString();
      i['status'] = st;
      i['updated_at'] = DateTime.now().toIso8601String();
      _appendAudit(
        action: 'interaction.status',
        object: id,
        actor: 'human',
        detail: '$before → $st',
      );
      await _save();
      return <String, dynamic>{'ok': true, 'interaction': _copyInteraction(i)};
    }
    return <String, dynamic>{'ok': false, 'error': '互动记录不存在'};
  }

  Map<String, dynamic> _copyInteraction(Map<String, dynamic> i) =>
      Map<String, dynamic>.from(i);

  // ---- 订单记录（只存业务元数据）----

  Future<List<Map<String, dynamic>>> listOrders({
    String accountId = '',
    String status = '',
  }) async {
    await _load();
    final String acct = accountId.trim();
    final String st = status.trim();
    final List<Map<String, dynamic>> filtered = _orders
        .where((Map<String, dynamic> o) {
      if (acct.isNotEmpty && (o['account_id'] ?? '').toString() != acct) {
        return false;
      }
      if (st.isNotEmpty && (o['status'] ?? '').toString() != st) return false;
      return true;
    }).toList()
      ..sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
          (b['updated_at'] ?? '').toString().compareTo(
              (a['updated_at'] ?? '').toString()));
    return filtered.map(_copyOrder).toList();
  }

  /// 按 account_id + platform_order_id 幂等写入：存在即更新，不产生重复订单。
  Future<Map<String, dynamic>> upsertOrder({
    required String accountId,
    required String platformOrderId,
    required String title,
    required num amount,
    String status = 'pending',
    String updatedAt = '',
  }) async {
    await _load();
    final String acctId = accountId.trim();
    final Map<String, dynamic>? account = _findAccount(acctId);
    if (account == null) {
      return <String, dynamic>{'ok': false, 'error': '账号不存在'};
    }
    final String orderId = platformOrderId.trim();
    if (orderId.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '平台订单号不能为空'};
    }
    final String name = title.trim();
    if (name.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '订单标题不能为空'};
    }
    if (name.length > 200) {
      return <String, dynamic>{'ok': false, 'error': '订单标题过长（最多 200 字）'};
    }
    if (_containsLikelySecret(name)) {
      return <String, dynamic>{
        'ok': false,
        'error': '订单标题疑似包含明文密钥，拒绝保存；只记录业务元数据',
      };
    }
    if (amount < 0) {
      return <String, dynamic>{'ok': false, 'error': '金额不能为负数'};
    }
    final String time = updatedAt.trim();
    if (time.isNotEmpty && DateTime.tryParse(time) == null) {
      return <String, dynamic>{
        'ok': false,
        'error': 'updated_at 不是有效的 ISO8601 时间',
      };
    }
    final String now = DateTime.now().toIso8601String();
    final String stamp = time.isEmpty ? now : time;
    final String st = status.trim().isEmpty ? 'pending' : status.trim();
    Map<String, dynamic>? existing;
    for (final Map<String, dynamic> o in _orders) {
      if ((o['account_id'] ?? '').toString() == acctId &&
          (o['platform_order_id'] ?? '').toString() == orderId) {
        existing = o;
        break;
      }
    }
    if (existing != null) {
      existing['title'] = name;
      existing['amount'] = amount;
      existing['status'] = st;
      existing['updated_at'] = stamp;
      _appendAudit(
        action: 'order.upsert',
        object: existing['id'].toString(),
        actor: 'human',
        detail: '更新 $orderId → $st',
      );
      await _save();
      return <String, dynamic>{
        'ok': true,
        'created': false,
        'order': _copyOrder(existing),
      };
    }
    final Map<String, dynamic> order = <String, dynamic>{
      'id': _id('order'),
      'account_id': acctId,
      'platform_order_id': orderId,
      'title': name,
      'amount': amount,
      'status': st,
      'created_at': now,
      'updated_at': stamp,
    };
    _orders.add(order);
    _appendAudit(
      action: 'order.upsert',
      object: order['id'].toString(),
      actor: 'human',
      detail: '新增 $orderId → $st',
    );
    await _save();
    return <String, dynamic>{
      'ok': true,
      'created': true,
      'order': _copyOrder(order),
    };
  }

  Future<Map<String, dynamic>> updateOrderStatus(
      String id, String status) async {
    await _load();
    final String st = status.trim();
    if (st.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '状态不能为空'};
    }
    for (final Map<String, dynamic> o in _orders) {
      if ((o['id'] ?? '').toString() != id) continue;
      final String before = (o['status'] ?? '').toString();
      o['status'] = st;
      o['updated_at'] = DateTime.now().toIso8601String();
      _appendAudit(
        action: 'order.status',
        object: id,
        actor: 'human',
        detail: '$before → $st',
      );
      await _save();
      return <String, dynamic>{'ok': true, 'order': _copyOrder(o)};
    }
    return <String, dynamic>{'ok': false, 'error': '订单不存在'};
  }

  Map<String, dynamic> _copyOrder(Map<String, dynamic> o) =>
      Map<String, dynamic>.from(o);

  // ---- 定时发布（绝不自动审批）----

  /// 到期草稿：status=approved、scheduled_at 非空且 <= now、关联账号 enabled。
  /// 只读筛选，绝不修改任何状态，更不会自动审批 pending 草稿。
  Future<List<Map<String, dynamic>>> dueDrafts({DateTime? now}) async {
    await _load();
    final DateTime ref = now ?? DateTime.now();
    final List<Map<String, dynamic>> due = _drafts.where((Map<String, dynamic> d) {
      if ((d['status'] ?? '').toString() != 'approved') return false;
      final String raw = (d['scheduled_at'] ?? '').toString().trim();
      if (raw.isEmpty) return false;
      final DateTime? at = DateTime.tryParse(raw);
      if (at == null || at.isAfter(ref)) return false;
      final Map<String, dynamic>? account =
          _findAccount((d['account_id'] ?? '').toString());
      return account != null && account['enabled'] != false;
    }).map(_copyDraft).toList()
      ..sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
          (a['scheduled_at'] ?? '')
              .toString()
              .compareTo((b['scheduled_at'] ?? '').toString()));
    return due;
  }

  /// 逐个发布到期草稿（内部仍走 [publishDraft]，只允许 approved）。
  /// 真实成功/失败分别计数，失败原因原样保留在草稿 error 与本结果中。
  Future<Map<String, dynamic>> publishDue({
    DateTime? now,
    int limit = 10,
  }) async {
    final DateTime ref = now ?? DateTime.now();
    final List<Map<String, dynamic>> due = await dueDrafts(now: ref);
    final int take = limit > 0 && due.length > limit ? limit : due.length;
    int published = 0;
    int failed = 0;
    final List<Map<String, dynamic>> results = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> draft in due.take(take)) {
      final String id = (draft['id'] ?? '').toString();
      Map<String, dynamic> r;
      try {
        r = await publishDraft(id);
      } on Object catch (e) {
        r = <String, dynamic>{'ok': false, 'error': '发布调用异常：$e'};
      }
      final bool ok = r['ok'] == true;
      if (ok) {
        published += 1;
      } else {
        failed += 1;
      }
      results.add(<String, dynamic>{
        'id': id,
        'ok': ok,
        'status': (r['draft'] is Map)
            ? ((r['draft'] as Map)['status'] ?? '').toString()
            : (r['status'] ?? '').toString(),
        'error': (r['error'] ?? '').toString(),
      });
    }
    return <String, dynamic>{
      'ok': true,
      'now': ref.toIso8601String(),
      'due': due.length,
      'attempted': results.length,
      'published': published,
      'failed': failed,
      'skipped': due.length - results.length,
      'results': results,
    };
  }

  // ---- 草稿 ----

  Future<Map<String, dynamic>> createDraft({
    required String accountId,
    required String content,
    List<String> mediaPaths = const <String>[],
    String target = '',
    String scheduledAt = '',
  }) async {
    await _load();
    final Map<String, dynamic>? account = _findAccount(accountId);
    if (account == null) {
      return <String, dynamic>{'ok': false, 'error': '账号不存在'};
    }
    if (account['enabled'] == false) {
      return <String, dynamic>{'ok': false, 'error': '账号已停用，不能新建草稿'};
    }
    final String text = content.trim();
    final List<String> media = mediaPaths
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    if (text.isEmpty && media.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '草稿内容和素材至少填写一项'};
    }
    final String schedule = scheduledAt.trim();
    if (schedule.isNotEmpty && DateTime.tryParse(schedule) == null) {
      return <String, dynamic>{
        'ok': false,
        'error': 'scheduled_at 不是有效的 ISO8601 时间',
      };
    }
    final String now = DateTime.now().toIso8601String();
    final Map<String, dynamic> draft = <String, dynamic>{
      'id': _id('draft'),
      'account_id': accountId,
      'channel': account['channel'],
      'content': text,
      'media_paths': media,
      'target': target.trim().isEmpty
          ? account['channel'].toString()
          : target.trim(),
      'status': 'draft',
      'scheduled_at': schedule,
      'created_at': now,
      'updated_at': now,
      'error': '',
      'audit': <dynamic>[],
    };
    _drafts.add(draft);
    _appendAudit(
      action: 'draft.create',
      object: draft['id'].toString(),
      actor: 'human',
      detail: '账号 ${account['name']}，目标 ${draft['target']}',
      draft: draft,
    );
    await _save();
    return <String, dynamic>{'ok': true, 'draft': _copyDraft(draft)};
  }

  Future<List<Map<String, dynamic>>> listDrafts({String status = ''}) async {
    await _load();
    final String filter = status.trim();
    return _drafts
        .where((Map<String, dynamic> d) =>
            filter.isEmpty || (d['status'] ?? '').toString() == filter)
        .map(_copyDraft)
        .toList();
  }

  Future<Map<String, dynamic>> submitDraft(String id) async {
    await _load();
    final Map<String, dynamic>? draft = _findDraft(id);
    if (draft == null) {
      return <String, dynamic>{'ok': false, 'error': '草稿不存在'};
    }
    final String status = (draft['status'] ?? '').toString();
    if (status != 'draft' && status != 'rejected') {
      return <String, dynamic>{
        'ok': false,
        'error': '仅 draft/rejected 草稿可提交，当前 $status',
      };
    }
    final String content = (draft['content'] ?? '').toString().trim();
    final bool hasMedia =
        draft['media_paths'] is List && (draft['media_paths'] as List).isNotEmpty;
    if (content.isEmpty && !hasMedia) {
      return <String, dynamic>{'ok': false, 'error': '草稿内容为空，无法提交'};
    }
    draft['status'] = 'pending';
    draft['submitted_at'] = DateTime.now().toIso8601String();
    draft['updated_at'] = draft['submitted_at'];
    draft['error'] = '';
    _appendAudit(
      action: 'draft.submit',
      object: id,
      actor: 'human',
      detail: '提交人工审批',
      draft: draft,
    );
    await _save();
    return <String, dynamic>{'ok': true, 'draft': _copyDraft(draft)};
  }

  Future<Map<String, dynamic>> approveDraft(
    String id, {
    String actor = 'human',
  }) async {
    await _load();
    final Map<String, dynamic>? draft = _findDraft(id);
    if (draft == null) {
      return <String, dynamic>{'ok': false, 'error': '草稿不存在'};
    }
    final String status = (draft['status'] ?? '').toString();
    if (status != 'pending') {
      return <String, dynamic>{
        'ok': false,
        'error': '仅 pending 草稿可审批通过，当前 $status',
      };
    }
    final String now = DateTime.now().toIso8601String();
    draft['status'] = 'approved';
    draft['approved_at'] = now;
    draft['approved_by'] = actor.trim().isEmpty ? 'human' : actor.trim();
    draft['updated_at'] = now;
    _appendAudit(
      action: 'draft.approve',
      object: id,
      actor: actor.trim().isEmpty ? 'human' : actor.trim(),
      detail: '人工确认通过',
      draft: draft,
    );
    await _save();
    return <String, dynamic>{'ok': true, 'draft': _copyDraft(draft)};
  }

  Future<Map<String, dynamic>> rejectDraft(String id, String reason) async {
    await _load();
    final Map<String, dynamic>? draft = _findDraft(id);
    if (draft == null) {
      return <String, dynamic>{'ok': false, 'error': '草稿不存在'};
    }
    final String status = (draft['status'] ?? '').toString();
    if (status != 'pending' && status != 'approved') {
      return <String, dynamic>{
        'ok': false,
        'error': '仅 pending/approved 草稿可驳回，当前 $status',
      };
    }
    final String now = DateTime.now().toIso8601String();
    draft['status'] = 'rejected';
    draft['rejected_at'] = now;
    draft['reject_reason'] = reason.trim();
    draft['updated_at'] = now;
    _appendAudit(
      action: 'draft.reject',
      object: id,
      actor: 'human',
      detail: reason.trim().isEmpty ? '人工驳回' : '人工驳回：${reason.trim()}',
      draft: draft,
    );
    await _save();
    return <String, dynamic>{'ok': true, 'draft': _copyDraft(draft)};
  }

  /// 发布：只有 approved 草稿才允许调用 send；失败如实写 failed。
  Future<Map<String, dynamic>> publishDraft(String id) async {
    await _load();
    final Map<String, dynamic>? draft = _findDraft(id);
    if (draft == null) {
      return <String, dynamic>{'ok': false, 'error': '草稿不存在'};
    }
    final String status = (draft['status'] ?? '').toString();
    if (status != 'approved') {
      _appendAudit(
        action: 'draft.publish_denied',
        object: id,
        actor: 'system',
        detail: '状态 $status 不是 approved，拒绝调用发布通道',
        draft: draft,
      );
      await _save();
      return <String, dynamic>{
        'ok': false,
        'error': '仅 approved 草稿可发布，当前 $status',
        'status': status,
        'draft': _copyDraft(draft),
      };
    }
    final Map<String, dynamic>? account =
        _findAccount((draft['account_id'] ?? '').toString());
    if (account == null) {
      _appendAudit(
        action: 'draft.publish_denied',
        object: id,
        actor: 'system',
        detail: '关联账号不存在',
        draft: draft,
      );
      await _save();
      return <String, dynamic>{'ok': false, 'error': '关联账号不存在，未调用发布通道'};
    }
    if (account['enabled'] == false) {
      _appendAudit(
        action: 'draft.publish_denied',
        object: id,
        actor: 'system',
        detail: '关联账号已停用',
        draft: draft,
      );
      await _save();
      return <String, dynamic>{'ok': false, 'error': '关联账号已停用，未调用发布通道'};
    }

    final String channel = (account['channel'] ?? '').toString();
    final String now = DateTime.now().toIso8601String();
    final Map<String, dynamic> payload = <String, dynamic>{
      'draft_id': draft['id'],
      'account_id': account['id'],
      'account_name': account['name'],
      'channel': channel,
      // 只传引用，send 由宿主按引用取真实凭据；明文密钥永不进入本模块。
      'credential_ref': account['credential_ref'],
      'content': draft['content'],
      'media_paths': draft['media_paths'] is List
          ? List<dynamic>.from(draft['media_paths'] as List)
          : <dynamic>[],
      'target': draft['target'],
      'scheduled_at': draft['scheduled_at'],
    };
    _appendAudit(
      action: 'draft.publish_attempt',
      object: id,
      actor: 'system',
      detail: 'channel=$channel target=${draft['target']}',
      draft: draft,
    );
    draft['attempted_at'] = now;
    draft['updated_at'] = now;

    Map<String, dynamic> result;
    try {
      result = await send(channel, payload);
    } on Object catch (e) {
      result = <String, dynamic>{'ok': false, 'error': '发布调用异常：$e'};
    }
    final bool succeeded = result['ok'] == true &&
        (result['error'] ?? '').toString().trim().isEmpty;
    if (succeeded) {
      draft['status'] = 'published';
      draft['published_at'] = DateTime.now().toIso8601String();
      draft['updated_at'] = draft['published_at'];
      draft['error'] = '';
      draft['result'] = Map<String, dynamic>.from(result);
      _appendAudit(
        action: 'draft.publish_success',
        object: id,
        actor: 'system',
        detail: '通道确认发布成功',
        draft: draft,
      );
      await _save();
      return <String, dynamic>{
        'ok': true,
        'draft': _copyDraft(draft),
        'result': result,
      };
    }

    final String error = (result['error'] ?? '').toString().trim().isEmpty
        ? '发布通道返回失败'
        : (result['error'] ?? '').toString().trim();
    draft['status'] = 'failed';
    draft['failed_at'] = DateTime.now().toIso8601String();
    draft['updated_at'] = draft['failed_at'];
    draft['error'] = error;
    draft['result'] = Map<String, dynamic>.from(result);
    _appendAudit(
      action: 'draft.publish_failed',
      object: id,
      actor: 'system',
      detail: error,
      draft: draft,
    );
    await _save();
    return <String, dynamic>{
      'ok': false,
      'error': error,
      'status': 'failed',
      'draft': _copyDraft(draft),
      'result': result,
    };
  }

  Map<String, dynamic> _copyDraft(Map<String, dynamic> d) => <String, dynamic>{
        ...d,
        'media_paths': d['media_paths'] is List
            ? List<dynamic>.from(d['media_paths'] as List)
            : <dynamic>[],
        'audit': d['audit'] is List
            ? List<dynamic>.from(d['audit'] as List)
            : <dynamic>[],
      };

  /// 审计日志（append-only，按时间正序返回）。
  Future<List<Map<String, dynamic>>> audit({int limit = 200}) async {
    await _load();
    final int take = limit <= 0 ? _auditLog.length : limit;
    final List<Map<String, dynamic>> all =
        _auditLog.map((Map<String, dynamic> e) => Map<String, dynamic>.from(e)).toList();
    return all.length <= take
        ? all
        : all.sublist(all.length - take);
  }

  Future<Map<String, dynamic>> describe() async {
    await _load();
    return <String, dynamic>{
      'ok': true,
      'accounts': _accounts.length,
      'enabled_accounts':
          _accounts.where((Map<String, dynamic> a) => a['enabled'] != false).length,
      'drafts': _drafts.length,
      'pending': _drafts
          .where((Map<String, dynamic> d) => d['status'] == 'pending')
          .length,
      'approved': _drafts
          .where((Map<String, dynamic> d) => d['status'] == 'approved')
          .length,
      'published': _drafts
          .where((Map<String, dynamic> d) => d['status'] == 'published')
          .length,
      'failed': _drafts
          .where((Map<String, dynamic> d) => d['status'] == 'failed')
          .length,
      'scheduled': _drafts
          .where((Map<String, dynamic> d) =>
              (d['scheduled_at'] ?? '').toString().trim().isNotEmpty)
          .length,
      'due_approved': (await dueDrafts()).length,
      'interactions': _interactions.length,
      'orders': _orders.length,
      'audit_entries': _auditLog.length,
      'platform_rules': platformRules,
      'policy': 'publish 必须经过人工 approve，且只允许 approved 草稿调用 send',
      'file': _file,
    };
  }

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    switch (action) {
      case 'accounts':
      case 'list':
        return <String, dynamic>{
          'ok': true,
          'accounts': await listAccounts(),
          'platform_rules': platformRules,
        };
      case 'add':
        return addAccount(
          channel: (p['channel'] ?? '').toString(),
          name: (p['name'] ?? '').toString(),
          credentialRef: (p['credential_ref'] ?? p['credentialRef'] ?? '').toString(),
        );
      case 'remove':
        return removeAccount((p['id'] ?? p['account_id'] ?? '').toString());
      case 'toggle':
        return toggleAccount(
          (p['id'] ?? p['account_id'] ?? '').toString(),
          p['enabled'] == true,
        );
      case 'drafts':
        return <String, dynamic>{
          'ok': true,
          'drafts': await listDrafts(status: (p['status'] ?? '').toString()),
        };
      case 'create_draft':
        return createDraft(
          accountId: (p['account_id'] ?? '').toString(),
          content: (p['content'] ?? '').toString(),
          mediaPaths: (p['media_paths'] is List)
              ? (p['media_paths'] as List)
                  .map((dynamic e) => e.toString())
                  .toList()
              : <String>[],
          target: (p['target'] ?? '').toString(),
          scheduledAt: (p['scheduled_at'] ?? '').toString(),
        );
      case 'submit':
        return submitDraft((p['id'] ?? '').toString());
      case 'approve':
        return approveDraft(
          (p['id'] ?? '').toString(),
          actor: (p['actor'] ?? 'human').toString(),
        );
      case 'reject':
        return rejectDraft(
          (p['id'] ?? '').toString(),
          (p['reason'] ?? '').toString(),
        );
      case 'publish':
        return publishDraft((p['id'] ?? '').toString());
      case 'publish_due':
        return publishDue(
          now: DateTime.tryParse((p['now'] ?? '').toString().trim()),
          limit: (p['limit'] is num) ? (p['limit'] as num).toInt() : 10,
        );
      case 'due':
        return <String, dynamic>{
          'ok': true,
          'due': await dueDrafts(
            now: DateTime.tryParse((p['now'] ?? '').toString().trim()),
          ),
        };
      case 'interactions':
        return <String, dynamic>{
          'ok': true,
          'interactions': await listInteractions(
            accountId: (p['account_id'] ?? '').toString(),
            direction: (p['direction'] ?? '').toString(),
            status: (p['status'] ?? '').toString(),
            limit: (p['limit'] is num) ? (p['limit'] as num).toInt() : 0,
          ),
        };
      case 'add_interaction':
        return addInteraction(
          channel: (p['channel'] ?? '').toString(),
          accountId: (p['account_id'] ?? '').toString(),
          target: (p['target'] ?? '').toString(),
          direction: (p['direction'] ?? '').toString(),
          summary: (p['summary'] ?? '').toString(),
          status: (p['status'] ?? 'logged').toString(),
          at: (p['at'] ?? '').toString(),
        );
      case 'interaction_status':
        return updateInteractionStatus(
          (p['id'] ?? '').toString(),
          (p['status'] ?? '').toString(),
        );
      case 'orders':
        return <String, dynamic>{
          'ok': true,
          'orders': await listOrders(
            accountId: (p['account_id'] ?? '').toString(),
            status: (p['status'] ?? '').toString(),
          ),
        };
      case 'upsert_order':
        return upsertOrder(
          accountId: (p['account_id'] ?? '').toString(),
          platformOrderId: (p['platform_order_id'] ?? '').toString(),
          title: (p['title'] ?? '').toString(),
          amount: (p['amount'] is num) ? p['amount'] as num : 0,
          status: (p['status'] ?? 'pending').toString(),
          updatedAt: (p['updated_at'] ?? '').toString(),
        );
      case 'order_status':
        return updateOrderStatus(
          (p['id'] ?? '').toString(),
          (p['status'] ?? '').toString(),
        );
      case 'audit':
        return <String, dynamic>{
          'ok': true,
          'audit': await audit(
            limit: (p['limit'] is num) ? (p['limit'] as num).toInt() : 200,
          ),
        };
      case 'rules':
        return <String, dynamic>{
          'ok': true,
          'platform_rules': platformRules,
          'policy': 'publish 必须经过人工 approve，且只允许 approved 草稿调用 send',
        };
      case 'describe':
        return describe();
      default:
        return <String, dynamic>{'ok': false, 'error': '未知账号运营动作：$action'};
    }
  }
}
