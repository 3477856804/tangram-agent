/// 人工接管（Take Control）—— 沙箱执行租约。
///
/// 设计来源：Rakazo 的 Team Computer「屏幕操作租约 + 人工接管」机制
/// （clean-room：只参考设计思路，本文件为自行实现，未复制任何第三方源码）。
///
/// 语义：
/// * 接管是一份租约（lease）：一次只能有一份生效租约，持有人、原因、
///   过期时间都写在租约里；默认最长 10 分钟，到期自动释放（惰性过期：
///   每次读取 `activeLease` / `isActive` 时先清掉已过期租约）。
/// * 接管期间沙箱的自动 exec 被拒绝（见 [SandboxProvider] 的接管门禁），
///   返回 `takeover-active` 状态，不执行命令。
/// * 接管与释放写审计日志：只记元数据（持有人、原因标签、租约 id、
///   剩余秒数），绝不记命令全文与密钥。本模块不直接依赖审计实现，
///   由调用方通过 [onAudit] 注入（生产接线见文件末尾注释）；审计回调
///   抛错时只吞掉，绝不阻断接管流程。
///
/// 微信 / 飞书扫码、2FA / 验证码场景的接线方式（只写明接线，不实际扫码、
/// 不发真实消息、不读验证码）：
/// * 微信扫码：iLink 流程在终端输出二维码链接时，agent 以
///   `reason: 'qr-login:wechat'` 申请接管；人已在 App 内扫码完成
///   （现有 `ilink_wechat.dart` 流程），完成后 `release`，bot 恢复执行。
/// * 飞书扫码：同理，`reason: 'qr-login:feishu'`。
/// * QQ 扫码：`QqSandboxController.poll()` 返回 `qr_content` 时申请，
///   `reason: 'qr-login:qq'`；dsh 终端确认绑定后释放。
/// * 2FA / 验证码：终端出现验证码输入提示时申请，
///   `reason: '2fa:totp'` 或 `'2fa:sms'`；人手工输入后释放。
///   验证码本身只进终端输入，绝不进审计日志与租约记录。
/// * 接管期间 bot 的自动 exec 一律拒绝；人若需在接管期替 bot 执行命令，
///   走 App 已有的手动终端入口，不走本租约的自动通道。
library;

/// 租约状态：requested（已申请未授权）→ granted（生效中）→
/// released（已释放）/ expired（到期自动释放）。
enum SandboxTakeoverLeaseStatus { requested, granted, released, expired }

/// 一份接管租约。只含元数据：持有人、原因标签、时间，不含任何命令与密钥。
class SandboxTakeoverLease {
  const SandboxTakeoverLease({
    required this.id,
    required this.holder,
    required this.reason,
    required this.requestedAt,
    required this.duration,
    this.grantedAt,
    this.status = SandboxTakeoverLeaseStatus.requested,
    this.releasedReason = '',
  });

  final String id;

  /// 持有人标识（如 'user' / 'operator'），只作审计元数据。
  final String holder;

  /// 原因标签，如 'qr-login:wechat' / '2fa:totp' / 'manual-debug'。
  /// 只接受短标签，不接受命令全文与验证码。
  final String reason;
  final DateTime requestedAt;

  /// 授权后生效时长（grant 时起算；request 时传入，超过上限会被截断）。
  final Duration duration;
  final DateTime? grantedAt;
  final SandboxTakeoverLeaseStatus status;

  /// 释放原因（'done' / 'cancelled' / 'expired' 等），仅元数据。
  final String releasedReason;

  /// 授权后的过期时刻；未授权时按申请时刻 + 时长估算。
  DateTime get expiresAt =>
      (grantedAt ?? requestedAt).add(duration);

  /// 在 [now] 时刻是否已过期（仅对 granted 的租约有意义）。
  bool isExpiredAt(DateTime now) =>
      status == SandboxTakeoverLeaseStatus.granted &&
      !now.isBefore(expiresAt);

  /// 剩余秒数（未授权按申请时刻起算；已释放/已过期返回 0）。
  int remainingSecondsAt(DateTime now) {
    if (status != SandboxTakeoverLeaseStatus.granted) return 0;
    final int s = expiresAt.difference(now).inSeconds;
    return s > 0 ? s : 0;
  }

  SandboxTakeoverLease copyWith({
    SandboxTakeoverLeaseStatus? status,
    DateTime? grantedAt,
    String? releasedReason,
  }) =>
      SandboxTakeoverLease(
        id: id,
        holder: holder,
        reason: reason,
        requestedAt: requestedAt,
        duration: duration,
        grantedAt: grantedAt ?? this.grantedAt,
        status: status ?? this.status,
        releasedReason: releasedReason ?? this.releasedReason,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'holder': holder,
        'reason': reason,
        'status': status.name,
        'requested_at': requestedAt.toIso8601String(),
        if (grantedAt != null)
          'granted_at': grantedAt!.toIso8601String(),
        'expires_at': expiresAt.toIso8601String(),
        if (releasedReason.isNotEmpty) 'released_reason': releasedReason,
      };
}

/// 人工接管管理器：租约申请 / 授权 / 释放 + 到期自动释放 + 审计回调。
///
/// 审计只记元数据：回调收到的 detail 只有 holder / reason / lease id /
/// 剩余秒数，调用方（生产接线：`AuditLog.append(category:
/// 'sandbox.takeover', ...)`）不得往里塞命令全文与密钥。
class SandboxTakeover {
  SandboxTakeover({this.onAudit, DateTime Function()? now})
      : _nowFn = now;

  /// 默认租约时长与上限：10 分钟（Rakazo 租约语义的同等上限）。
  static const Duration defaultLease = Duration(minutes: 10);
  static const Duration maxLease = Duration(minutes: 10);

  /// 审计回调：(action, detail)。action 如 'takeover.request' /
  /// 'takeover.grant' / 'takeover.release' / 'takeover.expired'。
  /// 回调抛错会被吞掉（只记不住断），绝不阻断接管流程。
  final void Function(String action, Map<String, dynamic> detail)? onAudit;

  final DateTime Function()? _nowFn;
  DateTime _now() => _nowFn?.call() ?? DateTime.now();

  SandboxTakeoverLease? _lease;
  int _seq = 0;

  /// 当前生效租约（读取时先清掉已过期的租约并记一条过期审计）。
  SandboxTakeoverLease? get activeLease {
    _sweepExpired();
    final SandboxTakeoverLease? l = _lease;
    if (l != null && l.status == SandboxTakeoverLeaseStatus.granted) {
      return l;
    }
    return null;
  }

  /// 是否正被人工接管（自动 exec 应拒绝）。
  bool get isActive => activeLease != null;

  /// 申请接管。已有生效或待授权租约时拒绝（返回 ok:false + 现有租约），
  /// 不覆盖、不排队。duration 超过 [maxLease] 会被截断到上限。
  Map<String, dynamic> request({
    required String holder,
    required String reason,
    Duration? duration,
  }) {
    _sweepExpired();
    final SandboxTakeoverLease? existing = _lease;
    if (existing != null &&
        (existing.status == SandboxTakeoverLeaseStatus.requested ||
            existing.status == SandboxTakeoverLeaseStatus.granted)) {
      return <String, dynamic>{
        'ok': false,
        'status': 'already-active',
        'error': '已有接管租约生效或待授权，不能重复申请',
        'lease': existing.toJson(),
      };
    }
    Duration d = duration ?? defaultLease;
    if (d > maxLease) d = maxLease;
    if (d <= Duration.zero) d = defaultLease;
    final String id =
        'takeover-${_now().microsecondsSinceEpoch}-${_seq++}';
    final SandboxTakeoverLease lease = SandboxTakeoverLease(
      id: id,
      holder: holder,
      reason: reason,
      requestedAt: _now(),
      duration: d,
    );
    _lease = lease;
    _audit('takeover.request', lease, <String, dynamic>{
      'requested_seconds': d.inSeconds,
    });
    return <String, dynamic>{
      'ok': true,
      'status': 'requested',
      'lease': lease.toJson(),
    };
  }

  /// 授权一份待授权租约（人确认接管）。租约 id 不符或状态不对时拒绝。
  Map<String, dynamic> grant(String leaseId, {String by = 'human'}) {
    _sweepExpired();
    final SandboxTakeoverLease? l = _lease;
    if (l == null || l.id != leaseId) {
      return <String, dynamic>{
        'ok': false,
        'status': 'not-found',
        'error': '接管租约不存在：$leaseId',
      };
    }
    if (l.status != SandboxTakeoverLeaseStatus.requested) {
      return <String, dynamic>{
        'ok': false,
        'status': 'wrong-state',
        'error': '租约当前状态为 ${l.status.name}，不能授权',
        'lease': l.toJson(),
      };
    }
    final SandboxTakeoverLease granted = l.copyWith(
      status: SandboxTakeoverLeaseStatus.granted,
      grantedAt: _now(),
    );
    _lease = granted;
    _audit('takeover.grant', granted, <String, dynamic>{'by': by});
    return <String, dynamic>{
      'ok': true,
      'status': 'granted',
      'lease': granted.toJson(),
    };
  }

  /// 释放一份租约（人办完交还 bot，或取消待授权申请）。
  /// 已释放/已过期的租约再次释放返回 ok:false，不重复记审计。
  Map<String, dynamic> release(
    String leaseId, {
    String by = 'human',
    String reason = 'done',
  }) {
    _sweepExpired();
    final SandboxTakeoverLease? l = _lease;
    if (l == null || l.id != leaseId) {
      return <String, dynamic>{
        'ok': false,
        'status': 'not-found',
        'error': '接管租约不存在：$leaseId',
      };
    }
    if (l.status != SandboxTakeoverLeaseStatus.requested &&
        l.status != SandboxTakeoverLeaseStatus.granted) {
      return <String, dynamic>{
        'ok': false,
        'status': 'wrong-state',
        'error': '租约当前状态为 ${l.status.name}，不能释放',
        'lease': l.toJson(),
      };
    }
    final SandboxTakeoverLease released = l.copyWith(
      status: SandboxTakeoverLeaseStatus.released,
      releasedReason: reason,
    );
    _lease = released;
    _audit('takeover.release', released, <String, dynamic>{
      'by': by,
      'released_reason': reason,
    });
    return <String, dynamic>{
      'ok': true,
      'status': 'released',
      'lease': released.toJson(),
    };
  }

  /// 当前接管状态（给 UI / 状态查询用，只含元数据）。
  Map<String, dynamic> status() {
    final SandboxTakeoverLease? l = activeLease;
    return <String, dynamic>{
      'active': l != null,
      if (l != null) ...<String, dynamic>{
        'lease': l.toJson(),
        'remaining_seconds': l.remainingSecondsAt(_now()),
      },
      'max_lease_seconds': maxLease.inSeconds,
    };
  }

  /// 惰性过期：已授权且过了 expiresAt 的租约自动转为 expired 并记审计。
  void _sweepExpired() {
    final SandboxTakeoverLease? l = _lease;
    if (l == null) return;
    if (l.status == SandboxTakeoverLeaseStatus.granted &&
        l.isExpiredAt(_now())) {
      final SandboxTakeoverLease expired = l.copyWith(
        status: SandboxTakeoverLeaseStatus.expired,
        releasedReason: 'expired',
      );
      _lease = expired;
      _audit('takeover.expired', expired, <String, dynamic>{});
    }
  }

  void _audit(
    String action,
    SandboxTakeoverLease lease,
    Map<String, dynamic> extra,
  ) {
    final void Function(String, Map<String, dynamic>)? cb = onAudit;
    if (cb == null) return;
    final Map<String, dynamic> detail = <String, dynamic>{
      'lease': lease.id,
      'holder': lease.holder,
      'reason': lease.reason,
      'remaining_seconds': lease.remainingSecondsAt(_now()),
      ...extra,
    };
    try {
      cb(action, detail);
    } on Object {
      // 审计回调失败绝不阻断接管流程。
    }
  }
}
