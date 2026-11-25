/// 沙箱抽象（SandboxProvider）—— 把「内置沙箱」收到统一 provider 接口。
///
/// 设计来源：Rakazo 的沙箱抽象机制（clean-room：只参考设计思路，
/// 本文件为自行实现，未复制任何第三方源码）。
///
/// 一个 provider 覆盖四组能力：生命周期（start/stop/status）、执行
/// （exec，带超时与输出上限）、文件（read/write/list）、屏幕/会话状态
/// 查询（sessionState）。具体后端（proot 用户态 / 本机宿主 shell /
/// 以后接的远端 SSH）只实现这个接口，上层调用方不再关心是哪套沙箱。
///
/// 本文件刻意只依赖 dart:async / dart:convert / dart:io，不引
/// `proot_sandbox.dart`（后者经 `store.dart` → `path_provider` →
/// Flutter `dart:ui`，纯 Dart VM 里加载不起来）。proot 适配器在
/// `sandbox_proot_provider.dart`；本文件只含接口、注册表与本机后端，
/// 因此 Dart VM 断言脚本可以直接 import 本文件验证核心语义。
///
/// 接管门禁：每个 provider 可挂一个 [SandboxTakeover]；接管生效期间
/// [exec] 直接拒绝并返回 `takeover-active` 状态，不执行命令。
/// 文件读写不受接管影响（人接管时仍需看/改文件）；自动 exec 才被拦。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sandbox_takeover.dart';

/// 沙箱后端种类。
enum SandboxProviderKind {
  /// Android 本地 Linux 用户态（proot + Ubuntu/Alpine rootfs）。
  proot,

  /// 本机宿主 shell（桌面 bash / 安卓 toybox 回落），无用户态隔离。
  local,
}

/// 一次沙箱执行的结果。`status` 取值：
/// `ok` / `error` / `timeout` / `takeover-active` / `not-installed` / `denied`
///（`denied` = 安全策略 deny 预检拒绝，未执行命令）。
class SandboxExecResult {
  const SandboxExecResult({
    required this.ok,
    required this.kind,
    this.stdout = '',
    this.stderr = '',
    this.exitCode = -1,
    this.timedOut = false,
    this.truncated = false,
    this.status = 'ok',
    this.error = '',
    this.cwd = '.',
  });

  /// 接管期间拒绝自动执行的结果（不执行命令）。
  factory SandboxExecResult.takeoverRefused({
    required SandboxProviderKind kind,
    required String detail,
  }) =>
      SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'takeover-active',
        error: '沙箱正被人工接管，自动执行已暂停：$detail',
      );

  /// 后端未安装/未就绪的结果（不执行命令）。
  factory SandboxExecResult.notInstalled({
    required SandboxProviderKind kind,
    required String detail,
  }) =>
      SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'not-installed',
        error: detail,
      );

  /// 安全策略 deny 预检拒绝的结果（不执行命令；`rule` 为空表示
  /// 预检本身失败而 fail-closed，同样未执行）。
  factory SandboxExecResult.denied({
    required SandboxProviderKind kind,
    required String rule,
    String cwd = '.',
  }) =>
      SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'denied',
        error: rule.isEmpty
            ? '安全策略检查失败，拒绝执行'
            : '命令被安全策略拒绝（规则 $rule）',
        cwd: cwd,
      );

  final bool ok;
  final SandboxProviderKind kind;
  final String stdout;
  final String stderr;
  final int exitCode;
  final bool timedOut;

  /// 输出是否因超过上限被截断。
  final bool truncated;
  final String status;
  final String error;
  final String cwd;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ok': ok,
        'kind': kind.name,
        'status': status,
        'stdout': stdout,
        'stderr': stderr,
        'exit_code': exitCode,
        'timed_out': timedOut,
        'truncated': truncated,
        if (error.isNotEmpty) 'error': error,
        'cwd': cwd,
      };
}

/// deny 预检回调（round14 第一阶段）：只查 deny，返回命中规则的 id，
/// 未命中返回 null。不建审批单、不消费一次性凭据；回调本身抛错时调用方
/// 按 fail-closed 处理（拒绝执行），绝不静默放行。
typedef SandboxProviderDenyCheck = Future<String?> Function(
  String command,
  String cwd,
);

/// 执行审计回调：只收元数据事件，绝不收命令原文与输出。
/// 回调抛错时调用方一律吞掉，绝不阻断执行。
typedef SandboxProviderAuditCallback = void Function(
  SandboxAuditEvent event,
);

/// 沙箱执行审计事件（round14 第一阶段）：只记元数据，绝不记命令原文与输出。
///
/// 字段约定照抄 Python 侧 `im/serve.py` 的审计 detail 写法
/// （`tool=… first=… chars=…`），再补执行结果所需的字段：
///  * `tool` 工具名（`shell` / `cube`）；
///  * `first` 命令/表达式首词（≤40 字符；命令为空或只有环境变量导出时
///    回落为工具名本身）；
///  * `chars` 原始命令长度（`shellEnvPrefix` 拼进的 `export …` 前缀先剥离，
///    只计剥离后的长度，避免用长度泄露密钥）；
///  * `cwd` 相对路径（已是相对路径时原样记录）；
///  * `exit` 退出码（`-1` = 未执行：deny 拒绝 / 预检失败 / 执行体未启动）；
///  * `ms` 执行耗时毫秒；`provider` 执行后端（`local` / `proot` …）；
///  * `rule` 命中的 deny 规则 id（未命中为空）。
///
/// `decision`（`allowed` / `denied` / `failed`）不进 [detail]——它走
/// 审计写入的 decision 参数，与 Python 侧的 decision 字段同义。
/// 本文件是三条执行链里唯一能在纯 Dart VM 加载的审计载体，`detail` 格式
/// 即 canonical 格式；`SandboxedShell` 侧因 import 分层保留一份同形实现，
/// 字段顺序与本类须保持一致（见 check_sandbox_audit_round14.dart §4）。
class SandboxAuditEvent {
  const SandboxAuditEvent({
    required this.tool,
    required this.first,
    required this.chars,
    required this.cwd,
    required this.exit,
    required this.ms,
    required this.provider,
    required this.rule,
    required this.decision,
  });

  final String tool;
  final String first;
  final int chars;
  final String cwd;
  final int exit;
  final int ms;
  final String provider;
  final String rule;
  final String decision;

  /// 审计 detail 字符串：`k=v` 空格分隔，与 Python 侧同形。
  String get detail =>
      'tool=$tool first=$first chars=$chars cwd=$cwd '
      'exit=$exit ms=$ms provider=$provider rule=$rule';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tool': tool,
        'first': first,
        'chars': chars,
        'cwd': cwd,
        'exit': exit,
        'ms': ms,
        'provider': provider,
        'rule': rule,
        'decision': decision,
        'detail': detail,
      };

  /// 从原始命令构造事件：先剥离 `shellEnvPrefix` 拼进的
  /// `export K='v'; ` 前缀，再取首词与长度。
  factory SandboxAuditEvent.fromCommand({
    required String tool,
    required String command,
    String cwd = '.',
    required int exit,
    required int ms,
    required String provider,
    String rule = '',
    required String decision,
    String? root,
  }) {
    final String stripped = stripEnvPrefix(command);
    final String first = firstWord(command);
    return SandboxAuditEvent(
      tool: tool,
      first: first.isEmpty ? tool : first,
      chars: stripped.length,
      cwd: root == null ? cwd : relativeCwd(cwd, root),
      exit: exit,
      ms: ms,
      provider: provider,
      rule: rule,
      decision: decision,
    );
  }

  /// 命令首词（≤40 字符）：先剥离环境变量导出前缀再取首个空白分隔 token；
  /// 命令为空或只有导出语句时返回 ''（由 [fromCommand] 回落为工具名）。
  static String firstWord(String command) {
    final String stripped = stripEnvPrefix(command);
    if (stripped.isEmpty) return '';
    final String first = stripped.split(RegExp(r'\s+')).first;
    return first.length > 40 ? first.substring(0, 40) : first;
  }

  /// 剥离命令开头的 `export K='v'; ` 前缀（`shellEnvPrefix` 的拼法，
  /// 值内单引号以 `'\''` 转义）。逐条剥离开头的完整导出语句（以 `;` 结束）；
  /// 剥离后为空（只有前缀、无真实命令，或命令本身只有导出语句）时返回 ''，
  /// 调用方以工具名回落 first、chars 记 0，避免用长度泄露前缀里密钥的
  /// 长度。命令本身是单个无分号导出（`export FOO=bar`）时因语句不完整
  /// 而不剥离，原样保留。
  static String stripEnvPrefix(String command) {
    String s = command;
    while (true) {
      final RegExpMatch? m =
          RegExp(r"^export\s+[A-Za-z_][A-Za-z0-9_]*=").firstMatch(s);
      if (m == null) break;
      int i = m.end;
      if (i < s.length && s[i] == "'") {
        // 单引号值：'\'' 是转义后的单引号，跳过；裸 ' 闭合。
        i++;
        bool closed = false;
        while (i < s.length) {
          if (s.startsWith(r"'\''", i)) {
            i += 4;
            continue;
          }
          if (s[i] == "'") {
            closed = true;
            break;
          }
          i++;
        }
        if (!closed) break;
        i++; // 越过闭合引号。
      } else {
        // 无引号值：扫到分号。
        while (i < s.length && s[i] != ';') {
          i++;
        }
        if (i >= s.length) break; // 无分号：不是完整导出语句，不剥离。
      }
      // 分号前可有空白；分号后只允许空白，否则不是一条完整导出语句。
      while (i < s.length && s[i] == ' ') {
        i++;
      }
      if (i >= s.length || s[i] != ';') break;
      i++; // 越过分号。
      s = s.substring(i).trimLeft();
    }
    return s;
  }

  /// 绝对路径 cwd 相对化到沙箱根（已是相对路径时原样返回）。
  static String relativeCwd(String cwd, String root) {
    final String c = cwd.trim();
    if (c.isEmpty) return '.';
    final String r = root.replaceAll(RegExp(r'/+$'), '');
    if (r.isEmpty) return c;
    if (c == r) return '.';
    if (c.startsWith('$r/')) return c.substring(r.length + 1);
    return c;
  }
}

/// listDir 返回的一条文件记录。
class SandboxFileEntry {
  const SandboxFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.size = 0,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'path': path,
        'is_directory': isDirectory,
        'size': size,
      };
}

/// 沙箱后端统一接口。
abstract class SandboxProvider {
  SandboxProviderKind get kind;

  /// 展示名（如 '内置沙箱（proot + Ubuntu 24.04 base）'）。
  String get name;

  /// 人工接管管理器（可为空 = 不设接管门禁；注册表会统一注入）。
  SandboxTakeover? takeover;

  /// deny 预检回调（可选，由注册表注入或调用方直接设置；只查 deny，
  /// 返回命中规则的 id，未命中返回 null）。
  SandboxProviderDenyCheck? denyCheck;

  /// 执行审计回调（可选，只收 [SandboxAuditEvent] 元数据事件）。
  SandboxProviderAuditCallback? onAudit;

  /// deny 预检（round14）：命中时返回拒绝结果且不执行命令，同时记一条
  /// decision=`denied`、rule=规则 id 的审计；未命中返回 null（放行）。
  /// 预检回调本身抛错时按 fail-closed 处理：返回 rule 为空的拒绝结果并
  /// 记一条审计，绝不静默放行。未接线（[denyCheck] 为空）时直接放行。
  Future<SandboxExecResult?> checkDeny(
    String command, {
    required String cwd,
    required int ms,
  }) async {
    final SandboxProviderDenyCheck? check = denyCheck;
    if (check == null) return null;
    String? rule;
    try {
      rule = await check(command, cwd);
    } on Object {
      fireAudit(SandboxAuditEvent.fromCommand(
        tool: 'shell',
        command: command,
        cwd: cwd,
        exit: -1,
        ms: ms,
        provider: kind.name,
        decision: 'denied',
      ));
      return SandboxExecResult.denied(kind: kind, rule: '', cwd: cwd);
    }
    if (rule == null || rule.isEmpty) return null;
    fireAudit(SandboxAuditEvent.fromCommand(
      tool: 'shell',
      command: command,
      cwd: cwd,
      exit: -1,
      ms: ms,
      provider: kind.name,
      rule: rule,
      decision: 'denied',
    ));
    return SandboxExecResult.denied(kind: kind, rule: rule, cwd: cwd);
  }

  /// 审计发送：回调为空或抛错时静默跳过，绝不阻断执行。
  /// 各后端在 `exec` 的 choke 点调用（deny 由 [checkDeny] 代发，
  /// 成功/失败由执行收尾处发），保证每条执行最多记一条审计。
  void fireAudit(SandboxAuditEvent event) {
    final SandboxProviderAuditCallback? cb = onAudit;
    if (cb == null) return;
    try {
      cb(event);
    } on Object {
      // 审计失败绝不阻断执行。
    }
  }

  /// 生命周期：确保后端就绪。proot 未安装时返回 ok:false（不自动下载，
  /// 安装由 UI 侧 `proot.install()` 触发）；本机后端恒为就绪。
  Future<Map<String, dynamic>> start();

  /// 生命周期：停止后端。无常驻进程的后端返回 ok:true + 说明即可。
  Future<Map<String, dynamic>> stop();

  /// 状态快照（给 UI / 状态查询用）。
  Future<Map<String, dynamic>> status();

  /// 执行命令。超时强杀、输出超上限截断（`truncated=true`）；接管期间
  /// 拒绝并返回 `takeover-active`，不执行。
  Future<SandboxExecResult> exec(
    String command, {
    String cwd = '.',
    Duration timeout = const Duration(seconds: 60),
    int maxOutputChars = 65536,
  });

  /// 读沙箱内文件。成功返回 {ok:true, content, size}；
  /// 不存在/越界返回 {ok:false, error}。
  Future<Map<String, dynamic>> readFile(
    String guestPath, {
    int maxBytes = 1024 * 1024,
  });

  /// 写沙箱内文件（父目录不存在时自动创建）。返回 {ok, path, size} 或
  /// {ok:false, error}。
  Future<Map<String, dynamic>> writeFile(String guestPath, String content);

  /// 列沙箱内目录。返回 {ok:true, entries:[...]} 或 {ok:false, error}。
  Future<Map<String, dynamic>> listDir(String guestPath);

  /// 屏幕/会话状态查询。proot 用户态无独立图形屏幕，返回终端执行状态
  /// 与安装状态；以后接 Team Computer 式远端桌面时由该后端返回真实
  /// display / 会话信息（接口已预留，不用再改调用方）。
  Future<Map<String, dynamic>> sessionState();

  /// 快速自检（注册表切换前调用）：只做轻量存在性检查，不启动、不下载。
  Future<Map<String, dynamic>> selfCheck();

  /// 接管门禁：接管生效时返回拒绝结果，否则返回 null（放行）。
  SandboxExecResult? takeoverRefusal() {
    final SandboxTakeover? t = takeover;
    if (t == null) return null;
    final SandboxTakeoverLease? lease = t.activeLease;
    if (lease == null) return null;
    return SandboxExecResult.takeoverRefused(
      kind: kind,
      detail: '持有人 ${lease.holder}，原因 ${lease.reason}，'
          '租约 ${lease.id}，剩余 ${lease.remainingSecondsAt(DateTime.now())}s',
    );
  }

  /// 输出上限：超长输出截断并加尾注，调用方凭 `truncated` 判断。
  /// 纯函数，供适配器与检查脚本共用。
  static String capOutput(String text, int maxChars) {
    if (maxChars <= 0) return '';
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}\n…[输出已截断，共 ${text.length} 字符，上限 $maxChars]';
  }

  /// 沙箱内 guest 路径 → 宿主真实路径（纯函数，供适配器与检查脚本共用）。
  ///
  /// * `/workspace/...` → 工作区目录（App 沙箱 / agent_ws）；
  /// * 其他绝对路径 `/a/b` → rootfs 下的 `/a/b`；
  /// * 相对路径 `a/b` → rootfs 下的 `/root/a/b`。
  /// 含 `..` 穿越的路径返回 null（调用方按越界拒绝）。
  static String? resolveGuestPath({
    required String rootfsPath,
    required String workspacePath,
    required String guestPath,
  }) {
    final String g = guestPath.trim();
    if (g.isEmpty) return null;
    final List<String> segs = <String>[];
    for (final String s in g.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') return null;
      segs.add(s);
    }
    if (segs.isEmpty) return null;
    final String root = rootfsPath.replaceAll(RegExp(r'/+$'), '');
    final String ws = workspacePath.replaceAll(RegExp(r'/+$'), '');
    if (segs.first == 'workspace') {
      if (segs.length == 1) return ws;
      return '$ws/${segs.sublist(1).join('/')}';
    }
    if (g.startsWith('/')) {
      return '$root/${segs.join('/')}';
    }
    return '$root/root/${segs.join('/')}';
  }

  /// 工作区内宿主路径解析（本机后端用）：相对路径落在工作区内，
  /// 绝对路径必须已在工作区内，`..` 穿越返回 null。
  static String? resolveWorkspacePath({
    required String workspacePath,
    required String path,
  }) {
    final String p = path.trim();
    if (p.isEmpty) return null;
    final String ws = workspacePath.replaceAll(RegExp(r'/+$'), '');
    String joined;
    if (p.startsWith('/')) {
      joined = p;
    } else {
      joined = '$ws/$p';
    }
    final List<String> segs = <String>[];
    for (final String s in joined.split('/')) {
      if (s.isEmpty || s == '.') continue;
      if (s == '..') {
        if (segs.isEmpty) return null;
        segs.removeLast();
        continue;
      }
      segs.add(s);
    }
    final String resolved = '/${segs.join('/')}';
    if (resolved != ws && !resolved.startsWith('$ws/')) return null;
    return resolved;
  }
}

/// 本机宿主 shell 后端：桌面 bash / 安卓 toybox 回落。
/// 无用户态隔离（与 proot 不同），只在 proot 不可用时作执行回落；
/// 命令经 `/bin/sh -c` 真实执行，超时强杀、输出上限截断。
class LocalSandboxProvider extends SandboxProvider {
  LocalSandboxProvider(this.workspace, {SandboxTakeover? takeover}) {
    this.takeover = takeover;
  }

  /// 宿主工作区目录（所有相对路径与文件操作都限定在此目录内）。
  final Directory workspace;

  @override
  SandboxProviderKind get kind => SandboxProviderKind.local;

  @override
  String get name => '本机沙箱（宿主 shell）';

  @override
  Future<Map<String, dynamic>> start() async {
    try {
      if (!await workspace.exists()) {
        await workspace.create(recursive: true);
      }
      return <String, dynamic>{
        'ok': true,
        'kind': kind.name,
        'workspace': workspace.path,
      };
    } on Object catch (e) {
      return <String, dynamic>{
        'ok': false,
        'kind': kind.name,
        'error': '工作区不可用：$e',
      };
    }
  }

  @override
  Future<Map<String, dynamic>> stop() async => <String, dynamic>{
        'ok': true,
        'kind': kind.name,
        'note': '本机 shell 无常驻进程，无需停止。',
      };

  @override
  Future<Map<String, dynamic>> status() async {
    final Map<String, dynamic> check = await selfCheck();
    return <String, dynamic>{
      'ok': true,
      'kind': kind.name,
      'running': check['ok'] == true,
      'workspace': workspace.path,
      'shell': '/bin/sh',
      if (check['ok'] != true) 'error': check['error'],
    };
  }

  @override
  Future<SandboxExecResult> exec(
    String command, {
    String cwd = '.',
    Duration timeout = const Duration(seconds: 60),
    int maxOutputChars = 65536,
  }) async {
    final SandboxExecResult? refused = takeoverRefusal();
    if (refused != null) return refused;
    // round14：deny 预检（只查 deny；接管门禁优先，仍以接管拒绝为准）。
    // 预检在工作区创建 / cwd 校验之前：被拒的命令不触碰任何磁盘状态。
    final Stopwatch execSw = Stopwatch()..start();
    final SandboxExecResult? denied = await checkDeny(
      command,
      cwd: cwd,
      ms: execSw.elapsedMilliseconds,
    );
    if (denied != null) return denied;
    if (Platform.isWindows) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: '本机沙箱 exec 仅支持 POSIX shell，Windows 请用远端沙箱。',
        cwd: cwd,
      );
    }
    // exec 前确保工作区存在（start 的同款幂等创建；未 start 就 exec
    // 也不应报「目录不存在」，否则切换自检通过后首次执行仍会失败）。
    try {
      if (!await workspace.exists()) {
        await workspace.create(recursive: true);
      }
    } on Object catch (e) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: '工作区不可用：$e',
        cwd: cwd,
      );
    }
    final String? dir = SandboxProvider.resolveWorkspacePath(
      workspacePath: workspace.path,
      path: cwd,
    );
    if (dir == null) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: '工作目录越出沙箱工作区：$cwd',
        cwd: cwd,
      );
    }
    Process proc;
    try {
      proc = await Process.start(
        '/bin/sh',
        <String>['-c', command],
        workingDirectory: dir,
        runInShell: false,
      );
    } on Object catch (e) {
      return SandboxExecResult(
        ok: false,
        kind: kind,
        status: 'error',
        error: '宿主 shell 无法启动：$e',
        cwd: cwd,
      );
    }
    final Future<String> outF =
        proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
    final Future<String> errF =
        proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    bool timedOut = false;
    int exitCode;
    try {
      exitCode = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      timedOut = true;
      proc.kill(ProcessSignal.sigkill);
      exitCode = 124;
    }
    final String stdoutAll =
        await outF.timeout(const Duration(seconds: 3), onTimeout: () => '');
    final String stderrAll =
        await errF.timeout(const Duration(seconds: 3), onTimeout: () => '');
    final String out = SandboxProvider.capOutput(stdoutAll, maxOutputChars);
    final String err = SandboxProvider.capOutput(stderrAll, maxOutputChars);
    final bool truncated =
        stdoutAll.length > maxOutputChars || stderrAll.length > maxOutputChars;
    // round14：执行收尾审计（只记元数据；本方法内其余 early return 均在
    // 执行体启动前——平台不支持 / 工作区不可用 / cwd 越界 / shell 起不来——
    // 命令未执行，故不记执行审计；deny 由 checkDeny 代发，不重复记）。
    final SandboxExecResult result = SandboxExecResult(
      ok: !timedOut && exitCode == 0,
      kind: kind,
      stdout: out,
      stderr: err,
      exitCode: exitCode,
      timedOut: timedOut,
      truncated: truncated,
      status: timedOut ? 'timeout' : (exitCode == 0 ? 'ok' : 'error'),
      error: timedOut
          ? '命令超时 ${timeout.inSeconds}s 已强杀'
          : (exitCode == 0 ? '' : 'exit $exitCode'),
      cwd: cwd,
    );
    fireAudit(SandboxAuditEvent.fromCommand(
      tool: 'shell',
      command: command,
      cwd: cwd,
      exit: exitCode,
      ms: execSw.elapsedMilliseconds,
      provider: kind.name,
      decision: result.ok ? 'allowed' : 'failed',
    ));
    return result;
  }

  @override
  Future<Map<String, dynamic>> readFile(
    String guestPath, {
    int maxBytes = 1024 * 1024,
  }) async {
    final String? path = SandboxProvider.resolveWorkspacePath(
      workspacePath: workspace.path,
      path: guestPath,
    );
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越出沙箱工作区：$guestPath',
      };
    }
    final File f = File(path);
    try {
      if (!await f.exists()) {
        return <String, dynamic>{'ok': false, 'error': '文件不存在：$guestPath'};
      }
      final int size = await f.length();
      if (size > maxBytes) {
        return <String, dynamic>{
          'ok': false,
          'error': '文件过大（$size 字节，上限 $maxBytes）：$guestPath',
        };
      }
      return <String, dynamic>{
        'ok': true,
        'path': guestPath,
        'size': size,
        'content': await f.readAsString(),
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '读取失败：$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> writeFile(
    String guestPath,
    String content,
  ) async {
    final String? path = SandboxProvider.resolveWorkspacePath(
      workspacePath: workspace.path,
      path: guestPath,
    );
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越出沙箱工作区：$guestPath',
      };
    }
    try {
      final File f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString(content, flush: true);
      return <String, dynamic>{
        'ok': true,
        'path': guestPath,
        'size': content.length,
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '写入失败：$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> listDir(String guestPath) async {
    final String? path = SandboxProvider.resolveWorkspacePath(
      workspacePath: workspace.path,
      path: guestPath,
    );
    if (path == null) {
      return <String, dynamic>{
        'ok': false,
        'error': '路径越出沙箱工作区：$guestPath',
      };
    }
    final Directory d = Directory(path);
    try {
      if (!await d.exists()) {
        return <String, dynamic>{'ok': false, 'error': '目录不存在：$guestPath'};
      }
      final List<SandboxFileEntry> entries = <SandboxFileEntry>[];
      await for (final FileSystemEntity e in d.list(followLinks: false)) {
        final String name = e.path.split('/').last;
        int size = 0;
        if (e is File) {
          try {
            size = await e.length();
          } on Object {
            size = 0;
          }
        }
        entries.add(SandboxFileEntry(
          name: name,
          path: '$guestPath/$name',
          isDirectory: e is Directory,
          size: size,
        ));
      }
      entries.sort((SandboxFileEntry a, SandboxFileEntry b) =>
          a.name.compareTo(b.name));
      return <String, dynamic>{
        'ok': true,
        'path': guestPath,
        'entries': entries.map((SandboxFileEntry e) => e.toJson()).toList(),
      };
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '列目录失败：$e'};
    }
  }

  @override
  Future<Map<String, dynamic>> sessionState() async => <String, dynamic>{
        'kind': kind.name,
        'running': true,
        'workspace': workspace.path,
        'note': '本机沙箱无独立屏幕会话；会话状态即宿主终端状态。',
      };

  @override
  Future<Map<String, dynamic>> selfCheck() async {
    if (Platform.isWindows) {
      return <String, dynamic>{
        'ok': false,
        'kind': kind.name,
        'error': '本机沙箱 exec 仅支持 POSIX shell。',
      };
    }
    final bool shellOk = await File('/bin/sh').exists();
    // 工作区尚未创建也算通过：start()/exec() 会幂等创建；只有父目录
    // 也不存在（无法创建）时才算自检失败。
    bool wsOk = await workspace.exists();
    if (!wsOk) {
      try {
        wsOk = await workspace.parent.exists();
      } on Object {
        wsOk = false;
      }
    }
    return <String, dynamic>{
      'ok': shellOk && wsOk,
      'kind': kind.name,
      'shell': shellOk,
      'workspace': wsOk,
      if (!shellOk) 'error': '宿主 /bin/sh 不存在',
      if (shellOk && !wsOk) 'error': '工作区不存在且无法创建：${workspace.path}',
    };
  }
}

/// 沙箱 provider 注册表：注册 / 切换 / 执行入口。
///
/// 切换先自检（[SandboxProvider.selfCheck]），自检失败时回落默认后端
/// 并记录原因（[lastSwitchError] / [lastFallbackReason]），绝不把调用方
/// 丢在一个不可用的后端上。注册表持有唯一的 [SandboxTakeover]，注册时
/// 注入每个 provider，接管门禁因此在所有后端上一致生效。
class SandboxProviderRegistry {
  SandboxProviderRegistry({
    required this.takeover,
    this.defaultKind = SandboxProviderKind.proot,
  });

  final SandboxTakeover takeover;
  final SandboxProviderKind defaultKind;

  final Map<SandboxProviderKind, SandboxProvider Function()> _factories =
      <SandboxProviderKind, SandboxProvider Function()>{};
  SandboxProvider? _current;
  SandboxProviderKind? _currentKind;

  /// deny 预检 / 执行审计回调（round14）：注册表持有，建后端时注入各
  /// provider（与 `takeover` 同款注入）；已建好的当前后端由 setter 同步。
  /// 注册表自身不另记审计——审计只在后端 `exec` 的 choke 点记一条。
  SandboxProviderDenyCheck? _denyCheck;
  SandboxProviderDenyCheck? get denyCheck => _denyCheck;
  set denyCheck(SandboxProviderDenyCheck? value) {
    _denyCheck = value;
    _current?.denyCheck = value;
  }

  SandboxProviderAuditCallback? _onAudit;
  SandboxProviderAuditCallback? get onAudit => _onAudit;
  set onAudit(SandboxProviderAuditCallback? value) {
    _onAudit = value;
    _current?.onAudit = value;
  }

  /// 把注册表持有的 deny/审计回调注入后端（只注入已设置的，不覆盖
  /// 后端自带的回调）。
  void _injectHooks(SandboxProvider p) {
    if (_denyCheck != null) p.denyCheck = _denyCheck;
    if (_onAudit != null) p.onAudit = _onAudit;
  }

  /// 最近一次切换失败的原因（成功切换后清掉）。
  String? lastSwitchError;

  /// 最近一次回落默认后端的原因（成功切换到非默认后端后清掉）。
  String? lastFallbackReason;

  void register(
    SandboxProviderKind kind,
    SandboxProvider Function() factory,
  ) {
    _factories[kind] = factory;
  }

  List<String> get availableKinds =>
      _factories.keys.map((SandboxProviderKind k) => k.name).toList();

  SandboxProvider get current {
    final SandboxProvider? c = _current;
    if (c != null) return c;
    return _build(defaultKind);
  }

  SandboxProviderKind get currentKind => _currentKind ?? defaultKind;

  SandboxProvider _build(SandboxProviderKind kind) {
    final SandboxProvider Function()? factory = _factories[kind];
    if (factory == null) {
      throw StateError('未注册的沙箱后端：${kind.name}');
    }
    final SandboxProvider p = factory();
    p.takeover = takeover;
    _injectHooks(p);
    _current = p;
    _currentKind = kind;
    return p;
  }

  /// 切换后端：先对候选后端自检；自检失败则回落默认后端（同样先自检），
  /// 回落也失败时返回 ok:false，当前后端保持不变。
  Future<Map<String, dynamic>> switchTo(SandboxProviderKind kind) async {
    final SandboxProvider Function()? factory = _factories[kind];
    if (factory == null) {
      lastSwitchError = '未注册的沙箱后端：${kind.name}';
      return <String, dynamic>{
        'ok': false,
        'error': lastSwitchError,
      };
    }
    final SandboxProvider candidate = factory();
    candidate.takeover = takeover;
    _injectHooks(candidate);
    final Map<String, dynamic> check = await candidate.selfCheck();
    if (check['ok'] == true) {
      _current = candidate;
      _currentKind = kind;
      lastSwitchError = null;
      lastFallbackReason = null;
      return <String, dynamic>{'ok': true, 'kind': kind.name};
    }
    final String reason =
        (check['error'] ?? '自检失败').toString();
    lastSwitchError = '${kind.name} 自检失败：$reason';
    if (kind == defaultKind) {
      return <String, dynamic>{
        'ok': false,
        'error': lastSwitchError,
        'kind': kind.name,
      };
    }
    final SandboxProvider Function()? fbFactory = _factories[defaultKind];
    if (fbFactory == null) {
      return <String, dynamic>{
        'ok': false,
        'error': lastSwitchError,
        'kind': kind.name,
      };
    }
    final SandboxProvider fb = fbFactory();
    fb.takeover = takeover;
    _injectHooks(fb);
    final Map<String, dynamic> fbCheck = await fb.selfCheck();
    if (fbCheck['ok'] != true) {
      return <String, dynamic>{
        'ok': false,
        'error': lastSwitchError,
        'fallback_error': (fbCheck['error'] ?? '自检失败').toString(),
        'kind': kind.name,
      };
    }
    _current = fb;
    _currentKind = defaultKind;
    lastFallbackReason = lastSwitchError;
    return <String, dynamic>{
      'ok': true,
      'kind': defaultKind.name,
      'fallback': true,
      'reason': lastFallbackReason,
    };
  }

  /// 执行入口：委托当前后端（接管门禁、deny 预检与执行审计都在后端
  /// `exec` 的 choke 点生效；注册表只注入回调，不另记审计，避免重复记）。
  Future<SandboxExecResult> exec(
    String command, {
    String cwd = '.',
    Duration timeout = const Duration(seconds: 60),
    int maxOutputChars = 65536,
  }) =>
      current.exec(
        command,
        cwd: cwd,
        timeout: timeout,
        maxOutputChars: maxOutputChars,
      );

  /// 注册表 + 当前后端的状态快照。
  Future<Map<String, dynamic>> status() async {
    final Map<String, dynamic> currentStatus = await current.status();
    return <String, dynamic>{
      'ok': true,
      'current_kind': currentKind.name,
      'available_kinds': availableKinds,
      'takeover_active': takeover.isActive,
      if (lastSwitchError != null) 'last_switch_error': lastSwitchError,
      if (lastFallbackReason != null)
        'last_fallback_reason': lastFallbackReason,
      'current': currentStatus,
    };
  }
}
