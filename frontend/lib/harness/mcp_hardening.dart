/// MCP 接入安全加固（Rakazo 调研报告机制 #5 的 clean-room 实现）。
///
/// 纯 Dart，不依赖 flutter / package:http，可被 Dart VM 断言脚本直接引用。
/// 覆盖四件事：
///   * stdio MCP 默认关闭 + 命令白名单 + 仅管理员可添加；
///   * 远程 MCP 单服务器超时 20 秒、失败退避、工具发现上限；
///   * OAuth 令牌快过期自动刷新入口，刷新失败标记需重绑定；
///   * 凭据永不经接口返回明文（redaction 自查）。
library;

/// 加固常量：集中一处，注册表与客户端共用同一份数字。
class McpHardening {
  /// 远程 MCP 单服务器请求超时。
  static const Duration requestTimeout = Duration(seconds: 20);

  /// 工具发现上限：单个服务器最多保留的工具数。
  static const int maxTools = 250;

  /// 工具发现上限：tools/list 最多跟进的分页数。
  static const int maxPages = 20;

  /// 失败退避起点。
  static const Duration initialBackoff = Duration(seconds: 30);

  /// 失败退避封顶。
  static const Duration maxBackoff = Duration(minutes: 5);

  /// OAuth 令牌过期前多少秒开始尝试刷新。
  static const Duration refreshAhead = Duration(seconds: 60);

  /// 连续失败 n 次（n >= 1）后的下一次退避时长：30 秒起翻倍，5 分钟封顶。
  static Duration nextBackoffDelay(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return Duration.zero;
    int seconds = initialBackoff.inSeconds;
    for (int i = 1; i < consecutiveFailures; i++) {
      seconds *= 2;
      if (seconds >= maxBackoff.inSeconds) return maxBackoff;
    }
    if (seconds > maxBackoff.inSeconds) return maxBackoff;
    return Duration(seconds: seconds);
  }

  // ---- 凭据 redaction 自查 ----

  /// 视为凭据的键名片段（小写匹配）。出现在返回体里的这类键一律不带真值。
  static const List<String> secretKeySubstrings = <String>[
    'token',
    'secret',
    'password',
    'passwd',
    'api_key',
    'apikey',
    'access_key',
    'authorization',
    'credential',
    'private_key',
    'client_secret',
  ];

  /// 形似凭据但只表示「是否存在 / 存在哪」的元数据键，不能被打码，
  /// 否则界面无法判断「已保存凭据」。例如 has_secret 含有 secret 片段。
  static const Set<String> metadataKeys = <String>{
    'has_secret',
    'has_token',
    'secret_storage',
    'token_type',
  };

  static bool isSecretKey(String key) {
    final String k = key.toLowerCase();
    if (metadataKeys.contains(k)) return false;
    for (final String sub in secretKeySubstrings) {
      if (k.contains(sub)) return true;
    }
    return false;
  }

  /// 深拷贝并清洗：凭据键的值替换为 `[redacted]`，其余原样保留。
  static Map<String, dynamic> scrubSecrets(Map<String, dynamic> input) {
    final Map<String, dynamic> out = <String, dynamic>{};
    input.forEach((String key, dynamic value) {
      if (isSecretKey(key)) {
        out[key] = '[redacted]';
      } else if (value is Map) {
        out[key] = scrubSecrets(
          value.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
        );
      } else if (value is List) {
        out[key] = value
            .map((dynamic e) => e is Map
                ? scrubSecrets(
                    e.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
                  )
                : e)
            .toList();
      } else {
        out[key] = value;
      }
    });
    return out;
  }

  /// 返回体里是否还残留凭据键的真值（已是 `[redacted]` 的不算）。
  static bool containsSecretValue(Map<String, dynamic> input) {
    bool found = false;
    void walk(dynamic value) {
      if (found) return;
      if (value is Map) {
        value.forEach((Object? k, Object? v) {
          if (found) return;
          if (isSecretKey(k.toString()) &&
              v != null &&
              v != '' &&
              v != '[redacted]') {
            found = true;
            return;
          }
          walk(v);
        });
      } else if (value is List) {
        for (final dynamic e in value) {
          walk(e);
          if (found) return;
        }
      }
    }

    walk(input);
    return found;
  }

  /// 已知凭据值是否以明文出现在待返回结构里（转 JSON 后子串检查）。
  static bool leaksSecret(Map<String, dynamic> payload, String secret) {
    if (secret.isEmpty) return false;
    // 简化 JSON 编码：只做子串检查，不依赖 dart:convert 之外的能力。
    final StringBuffer buf = StringBuffer();
    void walk(dynamic value) {
      if (value is Map) {
        value.forEach((Object? k, Object? v) {
          buf.write(k.toString());
          walk(v);
        });
      } else if (value is List) {
        for (final dynamic e in value) {
          walk(e);
        }
      } else if (value != null) {
        buf.write(value.toString());
      }
    }

    walk(payload);
    return buf.toString().contains(secret);
  }
}

/// stdio MCP 校验结果。
class StdioValidation {
  const StdioValidation({required this.ok, this.error = ''});
  final bool ok;
  final String error;
}

/// stdio MCP 策略：默认关闭；开启需显式配置 + 管理员确认 + 命令白名单。
///
/// 白名单只放「启动 MCP 服务器的常规方式」：npx / node / uvx / uv /
/// python3 / deno。命令必须是裸可执行名（不含路径分隔符），首个参数
/// 必须符合该命令允许的前缀；任何参数含 shell 元字符一律拒绝。
/// 本移动端不 spawn 进程——通过校验只是「配置准入」，服务本身仍不启动。
class McpStdioPolicy {
  /// 可执行名 → 允许的首参数前缀；空串前缀表示任意首参数（仍受元字符检查）。
  static const Map<String, List<String>> allowedCommands =
      <String, List<String>>{
    'npx': <String>['-y', '--yes', '@'],
    'node': <String>['/', './', '../'],
    'uvx': <String>[''],
    'uv': <String>['run', 'tool', 'x'],
    'python3': <String>['-m'],
    'python': <String>['-m'],
    'deno': <String>['run'],
  };

  static const String _metaChars = ';|&`\$><\n\r';

  static bool _hasMetaChars(String s) {
    for (int i = 0; i < s.length; i++) {
      if (_metaChars.contains(s[i])) return true;
    }
    return false;
  }

  static StdioValidation validate({
    required String command,
    required List<String> args,
    required bool stdioEnabled,
    required bool adminConfirmed,
  }) {
    if (!stdioEnabled) {
      return StdioValidation(
        ok: false,
        error: 'stdio MCP 默认关闭：需显式开启 stdio_enabled',
      );
    }
    if (!adminConfirmed) {
      return StdioValidation(
        ok: false,
        error: '添加 stdio MCP 服务器仅管理员可操作，需 admin_confirmed 确认',
      );
    }
    final String cmd = command.trim();
    if (cmd.isEmpty) {
      return StdioValidation(ok: false, error: 'stdio 命令不能为空');
    }
    if (cmd.contains('/') || cmd.contains('\\')) {
      return StdioValidation(
        ok: false,
        error: 'stdio 命令只允许白名单里的裸可执行名，不含路径：$cmd',
      );
    }
    final List<String>? prefixes = allowedCommands[cmd];
    if (prefixes == null) {
      return StdioValidation(
        ok: false,
        error: 'stdio 命令不在白名单内：$cmd（可用：${allowedCommands.keys.join('、')}）',
      );
    }
    if (args.isEmpty) {
      return StdioValidation(ok: false, error: 'stdio 参数不能为空');
    }
    if (_hasMetaChars(cmd)) {
      return StdioValidation(ok: false, error: 'stdio 命令含非法字符');
    }
    for (final String a in args) {
      if (_hasMetaChars(a)) {
        return StdioValidation(ok: false, error: 'stdio 参数含 shell 元字符，已拒绝：$a');
      }
    }
    final String first = args.first;
    final bool prefixOk =
        prefixes.any((String p) => p.isEmpty || first.startsWith(p));
    if (!prefixOk) {
      return StdioValidation(
        ok: false,
        error: 'stdio 首参数不在 $cmd 的白名单前缀内：$first',
      );
    }
    return StdioValidation(ok: true);
  }
}

/// 工具发现截断结果。
class ToolTruncation {
  const ToolTruncation({
    required this.tools,
    required this.truncated,
    required this.reason,
  });
  final List<Map<String, dynamic>> tools;
  final bool truncated;
  final String reason;
}

/// 工具发现上限：超过 250 个工具或 20 页时截断并记原因。
ToolTruncation truncateTools(
  List<Map<String, dynamic>> tools, {
  required int pagesFetched,
  bool morePages = false,
}) {
  if (tools.length > McpHardening.maxTools) {
    return ToolTruncation(
      tools: tools.sublist(0, McpHardening.maxTools),
      truncated: true,
      reason: '工具数 ${tools.length} 超过上限 ${McpHardening.maxTools}，已截断',
    );
  }
  if (pagesFetched >= McpHardening.maxPages && morePages) {
    return ToolTruncation(
      tools: tools,
      truncated: true,
      reason: '工具分页超过上限 ${McpHardening.maxPages} 页，已截断',
    );
  }
  return ToolTruncation(tools: tools, truncated: false, reason: '');
}

/// OAuth 令牌束：只存安全存储（Vault），永不进入集成记录与返回体。
class OAuthTokenBundle {
  const OAuthTokenBundle({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;

  /// access_token 过期时刻（UTC）。为 null 表示未知，视为需要刷新。
  final DateTime? expiresAt;

  /// 快过期（过期前 60 秒内）或已过期时需要刷新。
  bool needsRefresh({DateTime? now}) {
    final DateTime at = now ?? DateTime.now();
    if (expiresAt == null) return true;
    return !expiresAt!.isAfter(at.add(McpHardening.refreshAhead));
  }

  bool get isExpired {
    if (expiresAt == null) return true;
    return !expiresAt!.isAfter(DateTime.now());
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'expires_at_ms': expiresAt?.millisecondsSinceEpoch,
      };

  factory OAuthTokenBundle.fromJson(Map<String, dynamic> json) {
    final Object? ms = json['expires_at_ms'];
    DateTime? exp;
    if (ms is num) {
      exp = DateTime.fromMillisecondsSinceEpoch(ms.toInt(), isUtc: true);
    } else if (json['expires_at'] is String) {
      exp = DateTime.tryParse(json['expires_at'] as String);
    }
    return OAuthTokenBundle(
      accessToken: '${json['access_token'] ?? ''}',
      refreshToken: '${json['refresh_token'] ?? ''}',
      expiresAt: exp,
    );
  }

  /// 兼容旧的纯 token 字符串：无过期信息，视为需要刷新。
  /// JSON 形式的令牌束由调用方用 jsonDecode 后走 [OAuthTokenBundle.fromJson]。
  factory OAuthTokenBundle.fromVaultString(String raw) {
    return OAuthTokenBundle(
      accessToken: raw,
      refreshToken: '',
      expiresAt: null,
    );
  }
}

/// OAuth 刷新结果：成功带新令牌束；失败时调用方标记需重绑定。
class TokenRefreshResult {
  const TokenRefreshResult({
    required this.ok,
    this.bundle,
    this.error = '',
  });
  final bool ok;
  final OAuthTokenBundle? bundle;
  final String error;
}
