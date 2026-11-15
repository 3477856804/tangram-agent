/// QQ 沙箱直连（扫码绑定）—— 走「我们的沙箱」真实执行腾讯官方
/// @tencent-connect/dsh-qqbot 插件，捕获其终端输出的扫码二维码，并像微信
/// iLink 那样在 UI 渲染真码、轮询绑定状态。
///
/// 真实流程（抄自 dsh-qqbot 官方 README）：
///   1. 确保沙箱内有 Node.js（桌面真 shell / 安卓 Debian 用户态）；
///   2. npx -y @deepseek-ai/dsh plugin --profile qqbot add @tencent-connect/dsh-qqbot
///   3. npx -y @deepseek-ai/dsh --profile qqbot
///      —— 阻塞进程，终端输出二维码 → 手机 QQ 扫码绑定 → 凭据自动保存到
///         沙箱 HOME 下的 dsh profile。
///
/// 设计原则与 harness 一致：真实来源、拒绝语义、绝不伪造二维码。拿不到真码
/// 就如实报错（缺 Node / 沙箱不可用）；解析不到二维码链接就如实返回原始输出。

import 'dart:async';
import 'dart:io';

/// 真实 shell 执行能力（由后端注入实现），把 QQ 通道层与「桌面 bash /
/// 安卓 proot / SSH」等具体 shell 解耦，且能真实跑 dsh 这种长驻进程。
abstract class QqShellRunner {
  /// 一次性命令（如检查 Node 版本），返回真实 stdout / 退出码。
  Future<Map<String, dynamic>> runOnce(String command, {String cwd = '.'});

  /// 启动一个长驻进程（如 dsh 阻塞等待扫码），返回句柄供轮询与 kill。
  Future<QqShellProc> startDaemon(
    String command, {
    String cwd = '.',
    Map<String, String>? env,
  });
}

/// 一个已经启动的托管 shell 进程句柄。
abstract class QqShellProc {
  /// 已累计的 stdout + stderr（用于解析二维码链接与绑定状态）。
  String get output;
  bool get alive;
  int? get exitCode;
  Future<void> kill();
}

/// QQ 沙箱直连扫码控制器：检查运行环境 → 拉起 dsh → 解析终端二维码 →
/// 轮询绑定结果。二维码内容（链接）来自 dsh 真实终端输出，不做任何本地生成。
class QqSandboxController {
  QqSandboxController({required this.runner, required this.profileDir});

  final QqShellRunner runner;

  /// 沙箱根目录（作为 dsh 的 HOME），凭据会落在这里的 dsh profile 里。
  final Directory profileDir;

  QqShellProc? _proc;
  String _lastQr = '';

  /// 终端输出里的 http(s) 链接（dsh >=0.4.0 会打印一个可点击的在浏览器打开
  /// 的绑定链接，我们把它渲染成二维码）。优先取含 bind/qbot/qq 的链接。
  static final RegExp _urlRe = RegExp(r'https?://\S+');
  static final List<String> _bindHints = <String>[
    'bind',
    'qbot',
    'qq.com',
    'qzone',
  ];

  /// 绑定成功的关键词（dsh 在扫码确认后通常会打印这些）。
  static final List<String> _confirmHints = <String>[
    '绑定成功',
    'bind success',
    '登录成功',
    '绑定完成',
    '已连接',
    'already logged',
    'login success',
    'success',
  ];

  /// 第一步：确保 Node 可用并拉起 dsh（后台阻塞进程）。
  Future<Map<String, dynamic>> start() async {
    // 0) 确保 Node.js 存在；缺失时尝试在沙箱里就地安装（安卓 proot apk /
    //    桌面 apt 通常不在 App 权限内，会如实失败并给出指引）。
    final nodeCheck = await runner.runOnce('node --version', cwd: '.');
    final nodeOk = nodeCheck['ok'] == true &&
        (nodeCheck['stdout'] ?? '').toString().trim().isNotEmpty;
    if (!nodeOk) {
      onLog?.call('[qq-sandbox] 沙箱未检测到 Node.js，尝试就地安装…');
      await runner.runOnce(
        'command -v apk >/dev/null 2>&1 && apk add --no-cache nodejs npm '
        '|| (command -v apt-get >/dev/null 2>&1 && apt-get install -y nodejs npm)',
        cwd: '.',
      );
      final re = await runner.runOnce('node --version', cwd: '.');
      final ok2 = re['ok'] == true &&
          (re['stdout'] ?? '').toString().trim().isNotEmpty;
      if (!ok2) {
        return <String, dynamic>{
          'ok': false,
          'error': '沙箱里没有 Node.js，无法运行腾讯官方 dsh-qqbot。'
              '请先在「沙箱（SSH / Debian 扩展包）」里安装 Node.js：'
              '安卓执行 `apk add nodejs npm`，桌面执行 `apt install nodejs npm` 或 '
              '前往 nodejs.org 安装后重试。本应用不会伪造扫码二维码。',
        };
      }
    }

    // 1) 拉起 dsh：先装插件（跳过错误，已装则幂等），再阻塞启动等待扫码。
    //    整条链路在后台进程里跑，规避一次性命令的 60s 超时限制。
    const String cmd = 'export NPM_CONFIG_YES=true; '
        'npx -y @deepseek-ai/dsh plugin --profile qqbot '
        'add @tencent-connect/dsh-qqbot >/dev/null 2>&1; '
        'npx -y @deepseek-ai/dsh --profile qqbot';
    try {
      _proc = await runner.startDaemon(
        cmd,
        cwd: '.',
        env: <String, String>{'NPM_CONFIG_YES': 'true'},
      );
      onLog?.call('[qq-sandbox] dsh 已启动，等待终端输出扫码二维码…');
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '启动 dsh 失败：$e'};
    }
    return <String, dynamic>{
      'ok': true,
      'active': true,
      'connector': 'qq',
      'status': 'waiting',
    };
  }

  /// 第二步（UI 侧定时拉取）：解析终端输出里的二维码链接 + 绑定状态。
  Map<String, dynamic> poll() {
    final proc = _proc;
    if (proc == null) {
      return <String, dynamic>{'active': false, 'status': 'idle'};
    }
    final String out = proc.output;

    // 解析二维码内容（链接）：扫描所有 http(s) 链接，优先含 bind/qbot/qq 的。
    String? qr = _pickQr(out);
    if (qr != null) _lastQr = qr;

    // 绑定成功判定：终端出现确认关键词。
    final bool confirmed = _confirmHints
        .any((String h) => out.toLowerCase().contains(h.toLowerCase()));
    if (confirmed) {
      return <String, dynamic>{
        'active': true,
        'status': 'confirmed',
        if (_lastQr.isNotEmpty) 'qr_content': _lastQr,
      };
    }

    // 进程异常退出且未确认 → 如实报错并附尾部输出。
    if (!proc.alive) {
      return <String, dynamic>{
        'active': false,
        'status': 'error',
        'error': 'dsh 进程已退出（exit=${proc.exitCode}），未检测到扫码绑定。'
            '尾部输出：\n${_tail(out)}',
      };
    }

    // 仍在等待扫码：有码则给码，供 UI 渲染。
    return <String, dynamic>{
      'active': true,
      'status': 'waiting',
      if (_lastQr.isNotEmpty) 'qr_content': _lastQr,
      'expires_in': 300,
    };
  }

  /// 撤销扫码会话（关闭弹窗 / 要新码 / 未确认退出时调用）。
  Future<Map<String, dynamic>> cancel() async {
    await _proc?.kill();
    _proc = null;
    _lastQr = '';
    return <String, dynamic>{'ok': true, 'active': false, 'status': 'idle'};
  }

  /// 从终端输出里挑选二维码内容（链接）：优先含 bind/qbot/qq 关键词的链接，
  /// 否则取第一条 http(s) 链接。结尾的标点/引号会被裁掉，避免误扫。
  static String? _pickQr(String s) {
    final List<String> urls = _urlRe
        .allMatches(s)
        .map((Match m) => _trimUrl(m.group(0)!))
        .where((String u) => u.isNotEmpty)
        .toList();
    if (urls.isEmpty) return null;
    for (final String u in urls) {
      if (_bindHints.any((String h) => u.toLowerCase().contains(h))) return u;
    }
    return urls.first;
  }

  static String _trimUrl(String u) {
    String v = u;
    while (v.isNotEmpty && '.,);]}\'"'.contains(v[v.length - 1])) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  static String _tail(String s, [int n = 1000]) =>
      s.length <= n ? s : s.substring(s.length - n);

  /// 真实日志回调（可选），由上层注入。
  void Function(String line)? onLog;
}
