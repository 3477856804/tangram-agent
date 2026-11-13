import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// SSH 远程工作区配置：主机 / 端口 / 用户名 / 认证方式 + 凭据文本。
/// 凭据（密码或私钥 PEM 文本）只写入 FlutterSecureStorage，不落明文磁盘。
class SshWorkspaceConfig {
  const SshWorkspaceConfig({
    required this.host,
    required this.port,
    required this.user,
    required this.auth,
    required this.secret,
    this.passphrase = '',
    this.verifiedAt = '',
    this.remoteInfo = '',
  });

  final String host;
  final int port;
  final String user;

  /// '密码' 或 '私钥'。
  final String auth;

  /// auth=密码 时为密码文本；auth=私钥 时为 OpenSSH 私钥 PEM 全文。
  final String secret;

  /// 私钥口令（可选，仅 auth=私钥 时生效）。
  final String passphrase;

  /// 最近一次真实握手 + 认证 + exec 验证成功的时间（ISO 字符串），
  /// 空串表示尚未通过真实验证。
  final String verifiedAt;

  /// 最近一次验证成功时远端 `uname -a` 的输出（展示用）。
  final String remoteInfo;

  bool get isPasswordAuth => auth != '私钥';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'port': port,
        'user': user,
        'auth': auth,
        'secret': secret,
        'passphrase': passphrase,
        'verified_at': verifiedAt,
        'remote_info': remoteInfo,
      };

  factory SshWorkspaceConfig.fromJson(Map<String, dynamic> json) =>
      SshWorkspaceConfig(
        host: (json['host'] ?? '').toString(),
        port: int.tryParse((json['port'] ?? 22).toString()) ?? 22,
        user: (json['user'] ?? '').toString(),
        auth: (json['auth'] ?? '密码').toString(),
        secret: (json['secret'] ?? '').toString(),
        passphrase: (json['passphrase'] ?? '').toString(),
        verifiedAt: (json['verified_at'] ?? '').toString(),
        remoteInfo: (json['remote_info'] ?? '').toString(),
      );

  SshWorkspaceConfig copyWith({
    String? verifiedAt,
    String? remoteInfo,
  }) =>
      SshWorkspaceConfig(
        host: host,
        port: port,
        user: user,
        auth: auth,
        secret: secret,
        passphrase: passphrase,
        verifiedAt: verifiedAt ?? this.verifiedAt,
        remoteInfo: remoteInfo ?? this.remoteInfo,
      );
}

/// 真实连接测试（握手 + 认证 + exec 验证）的结果。
class SshConnectResult {
  const SshConnectResult({
    required this.ok,
    this.error = '',
    this.remoteVersion = '',
    this.uname = '',
  });

  final bool ok;
  final String error;

  /// 服务端Identification 字符串，如 "SSH-2.0-OpenSSH_8.9p1"。
  final String remoteVersion;

  /// 远端 `uname -a` 输出（已裁剪到前 80 字符）。
  final String uname;
}

/// sftp 列目录得到的单个条目。
class SshDirEntry {
  const SshDirEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
    this.mtime,
  });

  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? mtime;
}

/// sftp 列目录结果（含实际解析后的目录路径）。
class SshListing {
  const SshListing({required this.path, required this.entries});

  final String path;
  final List<SshDirEntry> entries;
}

/// SSH 远程工作区服务：dartssh2 真实握手（密码 / 私钥两种认证）、
/// 连接测试（真实 exec `echo ok` 验证 + `uname -a`）、sftp 目录列表、
/// 可执行命令；配置持久化到 FlutterSecureStorage。
class SshWorkspace {
  SshWorkspace();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _storageKey = 'tangram.ssh.v1';

  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _handshakeTimeout = Duration(seconds: 15);
  static const Duration _authTimeout = Duration(seconds: 15);
  static const Duration _execTimeout = Duration(seconds: 15);
  static const Duration _sftpTimeout = Duration(seconds: 20);

  // ---------------------------------------------------------------------------
  // 配置持久化（FlutterSecureStorage，加密存储，不落明文磁盘）
  // ---------------------------------------------------------------------------

  Future<SshWorkspaceConfig?> load() async {
    try {
      final String? raw = await _storage.read(key: _storageKey);
      if (raw == null || raw.isEmpty) return null;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SshWorkspaceConfig.fromJson(
          Map<String, dynamic>.from(decoded));
    } on Object {
      return null;
    }
  }

  Future<void> save(SshWorkspaceConfig cfg) async {
    await _storage.write(key: _storageKey, value: jsonEncode(cfg.toJson()));
  }

  Future<void> delete() async {
    try {
      await _storage.delete(key: _storageKey);
    } on Object {
      // 存储不可用时无配置可删，保持静默。
    }
  }

  // ---------------------------------------------------------------------------
  // 真实连接：握手 + 认证（密码 / 私钥）
  // ---------------------------------------------------------------------------

  /// 建立 TCP 连接并构造 SSHClient；认证在后台自动进行，
  /// 调用方 `await client.authenticated` 等待真实认证结果。
  Future<SSHClient> _open(SshWorkspaceConfig cfg) async {
    // 先解析凭据（私钥文本非法时直接抛错），避免失败后泄漏已建立的 socket。
    List<SSHKeyPair>? identities;
    SSHPasswordRequestHandler? onPassword;
    if (cfg.isPasswordAuth) {
      onPassword = () => cfg.secret;
    } else {
      identities = SSHKeyPair.fromPem(
        cfg.secret,
        cfg.passphrase.isEmpty ? null : cfg.passphrase,
      );
    }
    final SSHSocket socket = await SSHSocket.connect(
      cfg.host,
      cfg.port,
      timeout: _connectTimeout,
    );
    return SSHClient(
      socket,
      username: cfg.user,
      identities: identities,
      onPasswordRequest: onPassword,
      handshakeTimeout: _handshakeTimeout,
      authTimeout: _authTimeout,
      keepAliveInterval: null,
    );
  }

  /// 连接测试：真实握手 + 认证，成功后 exec `echo ok` 验证可执行通道，
  /// 再取回 `uname -a` 前 80 字符。失败返回真实错误信息。
  Future<SshConnectResult> testConnection(SshWorkspaceConfig cfg) async {
    SSHClient? client;
    try {
      client = await _open(cfg);
      await client.authenticated.timeout(_authTimeout + _handshakeTimeout);
      final Uint8List echo =
          await client.run('echo ok').timeout(_execTimeout);
      final String echoOut = utf8.decode(echo, allowMalformed: true).trim();
      if (echoOut != 'ok') {
        return SshConnectResult(
          ok: false,
          error: '已登录但 exec 验证异常：`echo ok` 返回「${_clip(echoOut, 40)}」',
          remoteVersion: client.remoteVersion ?? '',
        );
      }
      final Uint8List uname =
          await client.run('uname -a').timeout(_execTimeout);
      return SshConnectResult(
        ok: true,
        remoteVersion: client.remoteVersion ?? '',
        uname: _clip(utf8.decode(uname, allowMalformed: true).trim(), 80),
      );
    } on Object catch (e) {
      return SshConnectResult(ok: false, error: describeError(e));
    } finally {
      client?.close();
    }
  }

  /// 在远端执行任意命令，返回合并的 stdout/stderr 文本。
  Future<String> runCommand(SshWorkspaceConfig cfg, String command) async {
    final SSHClient client = await _open(cfg);
    try {
      await client.authenticated.timeout(_authTimeout + _handshakeTimeout);
      final Uint8List out = await client.run(command).timeout(_execTimeout);
      return utf8.decode(out, allowMalformed: true);
    } finally {
      client.close();
    }
  }

  /// sftp 真实列目录；[path] 为空串时先解析远端登录用户的 home 目录。
  Future<SshListing> listDir(SshWorkspaceConfig cfg, String path) async {
    final SSHClient client = await _open(cfg);
    try {
      await client.authenticated.timeout(_authTimeout + _handshakeTimeout);
      final SftpClient sftp = await client.sftp();
      String dir = path;
      try {
        if (dir.isEmpty) {
          dir = await sftp.absolute('.').timeout(_sftpTimeout);
        }
        final List<SftpName> names =
            await sftp.listdir(dir).timeout(_sftpTimeout);
        final List<SshDirEntry> entries = <SshDirEntry>[];
        for (final SftpName n in names) {
          if (n.filename == '.' || n.filename == '..') continue;
          entries.add(SshDirEntry(
            name: n.filename,
            isDirectory: n.attr.isDirectory,
            size: n.attr.size ?? 0,
            mtime: n.attr.modifyTime != null
                ? DateTime.fromMillisecondsSinceEpoch(n.attr.modifyTime! * 1000)
                : null,
          ));
        }
        entries.sort((SshDirEntry a, SshDirEntry b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
        return SshListing(path: dir, entries: entries);
      } finally {
        await sftp.close();
      }
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 错误文案
  // ---------------------------------------------------------------------------

  /// 把 dartssh2 / dart:io 的真实异常翻译成如实描述（不掩盖失败原因）。
  static String describeError(Object e) {
    if (e is SSHAuthFailError) {
      return '认证失败：用户名/密码或私钥未被服务器接受';
    }
    if (e is SSHKeyDecryptError) {
      return '私钥受口令保护：请填写密钥口令';
    }
    if (e is SSHKeyDecodeError) {
      return '私钥解析失败：请粘贴 OpenSSH 私钥全文（-----BEGIN ... PRIVATE KEY-----）';
    }
    if (e is SSHHandshakeError) {
      return 'SSH 握手失败/超时：${e.message}';
    }
    if (e is SSHAuthAbortError) {
      return '认证中断：${e.message}';
    }
    if (e is SSHChannelOpenError) {
      return '无法打开远端会话：${e.description}';
    }
    if (e is SftpStatusError) {
      return 'sftp 错误：${e.message}（code ${e.code}）';
    }
    if (e is SftpError) {
      return 'sftp 错误：${e.message}';
    }
    if (e is SocketException) {
      return '网络错误：${e.osError?.message ?? e.message}';
    }
    if (e is TimeoutException) {
      return '操作超时';
    }
    if (e is FormatException) {
      return '数据格式错误：${e.message}';
    }
    return '$e';
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}
