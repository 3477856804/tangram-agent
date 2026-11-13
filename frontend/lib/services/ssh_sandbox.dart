import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 远端沙箱（SSH）配置。密码/私钥与主机信息一起加密存于本机
/// （flutter_secure_storage），仅在真实握手/执行时经 SSH 协议发送。
class SshConfig {
  SshConfig({
    required this.host,
    required this.port,
    required this.user,
    required this.auth,
    this.password = '',
    this.privateKey = '',
    this.passphrase = '',
  });

  final String host;
  final int port;
  final String user;

  /// '密码' 或 '私钥'。
  final String auth;
  final String password;

  /// PEM 私钥文本（auth == '私钥' 时使用）。
  final String privateKey;
  final String passphrase;

  bool get usable =>
      host.isNotEmpty &&
      user.isNotEmpty &&
      port > 0 &&
      port <= 65535 &&
      (auth == '私钥' ? privateKey.isNotEmpty : password.isNotEmpty);

  String get display => '$user@$host:$port';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'port': port,
        'user': user,
        'auth': auth,
        'password': password,
        'private_key': privateKey,
        'passphrase': passphrase,
      };

  static SshConfig fromJson(Map<String, dynamic> m) => SshConfig(
        host: (m['host'] ?? '').toString(),
        port: m['port'] is num
            ? (m['port'] as num).toInt()
            : int.tryParse('${m['port']}') ?? 22,
        user: (m['user'] ?? '').toString(),
        auth: (m['auth'] ?? '密码').toString(),
        password: (m['password'] ?? '').toString(),
        privateKey: (m['private_key'] ?? '').toString(),
        passphrase: (m['passphrase'] ?? '').toString(),
      );
}

/// 沙箱终端「远端沙箱（SSH）」环境的真实执行通道：
/// dartssh2 完整协议握手 + 密码/公钥认证 + 远端真实 shell。
/// 终端里所有命令（apt/pip/python…）都在远端 Linux 上真实执行，
/// 输出/退出码原样回传；连接失败如实报错，绝不回退本地冒充。
class SshSandbox {
  SshSandbox._();

  static final SshSandbox instance = SshSandbox._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _key = 'tangram.sandbox.ssh.v1';

  SshConfig? _config;
  SSHClient? _client;
  bool _alive = false;

  SshConfig? get config => _config;

  bool get isConnected => _client != null && _alive;

  /// 从加密存储加载配置（内存缓存一次）。
  Future<SshConfig?> loadConfig() async {
    if (_config != null) return _config;
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null && raw.isNotEmpty) {
        _config = SshConfig.fromJson(
            Map<String, dynamic>.from(jsonDecode(raw) as Map));
      }
    } on Object {
      // 存储不可用/损坏：保持未配置态，不谎称有配置。
    }
    return _config;
  }

  /// 保存配置；返回是否真实落盘（桌面缺少密钥环服务时可能失败）。
  Future<bool> saveConfig(SshConfig cfg) async {
    _config = cfg;
    disconnect();
    try {
      await _storage.write(key: _key, value: jsonEncode(cfg.toJson()));
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> clearConfig() async {
    _config = null;
    disconnect();
    try {
      await _storage.delete(key: _key);
    } on Object {
      // 已断开即可，删除失败不谎报。
    }
  }

  void disconnect() {
    final c = _client;
    _client = null;
    _alive = false;
    if (c != null) {
      try {
        c.close();
      } on Object {
        // 关闭失败无需上报：连接已弃用。
      }
    }
  }

  Future<SSHClient> _connect(SshConfig cfg) async {
    final SSHSocket socket = await SSHSocket.connect(
      cfg.host,
      cfg.port,
      timeout: const Duration(seconds: 10),
    );
    final List<SSHKeyPair>? identities = cfg.auth == '私钥' && cfg.privateKey.isNotEmpty
        ? SSHKeyPair.fromPem(cfg.privateKey,
            cfg.passphrase.isEmpty ? null : cfg.passphrase)
        : null;
    final SSHClient client = SSHClient(
      socket,
      username: cfg.user,
      identities: identities,
      onPasswordRequest: cfg.auth == '密码' ? () => cfg.password : null,
    );
    unawaited(client.done.whenComplete(() {
      if (identical(_client, client)) _alive = false;
    }));
    return client;
  }

  Future<SSHClient> _ensureClient(SshConfig cfg) async {
    final c = _client;
    if (c != null && _alive) return c;
    final fresh = await _connect(cfg);
    _client = fresh;
    _alive = true;
    return fresh;
  }

  /// 真实连接测试：完整 SSH 握手 + 认证 + 远端执行 `uname -a`。
  /// 返回远端真实系统信息；任何一步失败都抛真实异常。
  Future<String> testConnection(SshConfig cfg) async {
    final SSHClient client = await _connect(cfg);
    try {
      final SSHRunResult r = await client
          .runWithResult('uname -a && id -un')
          .timeout(const Duration(seconds: 20));
      if (r.exitCode != null && r.exitCode != 0) {
        throw StateError('远端 uname 退出码 ${r.exitCode}：'
            '${utf8.decode(r.stderr, allowMalformed: true).trim()}');
      }
      return utf8.decode(r.stdout, allowMalformed: true).trim();
    } finally {
      client.close();
    }
  }

  /// 在远端真实执行一条命令。协议与本地真实 shell 一致：
  /// 用唯一 marker 分离「真实输出 / 新 cwd / 退出码」。
  Future<Map<String, dynamic>> run(String raw, String cwd) async {
    final SshConfig? cfg = _config ?? await loadConfig();
    if (cfg == null || !cfg.usable) {
      return <String, dynamic>{
        'ok': false,
        'stdout': '',
        'error': '远端沙箱未配置：点终端右上「⚙」填写 SSH 主机/用户/凭据，'
            '连接测试通过后再执行命令。',
        'cwd': cwd,
        'cube': 'shell',
        'remote': true,
      };
    }
    final String marker =
        '__TGA_END_${DateTime.now().microsecondsSinceEpoch}__';
    final String startDir = cwd == '.' ? '~' : _shellQuote(cwd);
    final String script =
        'cd $startDir 2>/dev/null; $raw; __rc=\$?; '
        'printf "\\n$marker%s$marker\$__rc\\n" "\$(pwd -P 2>/dev/null)"; '
        'exit \$__rc';
    try {
      final SSHClient client = await _ensureClient(cfg);
      final SSHRunResult r = await client
          .runWithResult(script)
          .timeout(const Duration(seconds: 60));
      final String stdoutAll =
          utf8.decode(r.stdout, allowMalformed: true);
      final String stderrAll =
          utf8.decode(r.stderr, allowMalformed: true);
      String out = stdoutAll;
      String newCwd = cwd;
      int exitCode = r.exitCode ?? 1;
      final int first = stdoutAll.indexOf(marker);
      final int last = stdoutAll.lastIndexOf(marker);
      if (first >= 0 && last > first) {
        out = stdoutAll.substring(0, first);
        final String tail = stdoutAll.substring(last + marker.length).trim();
        final String mid =
            stdoutAll.substring(first + marker.length, last);
        exitCode = int.tryParse(tail) ?? exitCode;
        final String pwd = mid.trim();
        if (pwd.isNotEmpty) newCwd = pwd;
      }
      final String text =
          out + (stderrAll.isEmpty ? '' : '\n$stderrAll');
      return <String, dynamic>{
        'ok': exitCode == 0,
        'stdout': text,
        'error': exitCode == 0 ? '' : 'exit $exitCode',
        'exit_code': exitCode,
        'cwd': newCwd,
        'cube': 'shell',
        'real': true,
        'remote': true,
        'remote_target': cfg.display,
      };
    } on Object catch (e) {
      disconnect();
      return <String, dynamic>{
        'ok': false,
        'stdout': '',
        'error': 'SSH 执行失败（${cfg.display}）：$e —— '
            '命令未在远端执行；请检查网络/凭据，或切回「内置沙箱」。',
        'cwd': cwd,
        'cube': 'shell',
        'remote': true,
      };
    }
  }

  static String _shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}
