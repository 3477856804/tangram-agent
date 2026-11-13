
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tangram/bridge/backend_client.dart';

class SandboxQuota {
  const SandboxQuota({
    required this.cpuPercent,
    required this.memoryMb,
    required this.timeoutSeconds,
    required this.actionOnExceed,
  });

  final int cpuPercent;

  final int memoryMb;

  final int timeoutSeconds;

  final String actionOnExceed;

  String get summary =>
      'CPU ≤${cpuPercent}% · 内存 ≤${memoryMb}MB · 超时 ${timeoutSeconds}s · 超限 $actionOnExceed';

  static SandboxQuota fromJson(Map<String, dynamic> json) {
    return SandboxQuota(
      cpuPercent: _asInt(json['cpu_percent']),
      memoryMb: _asInt(json['memory_mb']),
      timeoutSeconds: _asInt(json['timeout_seconds']),
      actionOnExceed: (json['action_on_exceed'] ?? 'terminate').toString(),
    );
  }
}

class SandboxStatus {
  const SandboxStatus({
    required this.version,
    required this.fileIsolationEnabled,
    required this.writableRoots,
    required this.readOnlyRoots,
    required this.networkEnabled,
    required this.networkAllowlist,
    required this.quota,
    required this.deniedModules,
    required this.allowedModules,
  });

  final String version;

  final bool fileIsolationEnabled;

  final List<String> writableRoots;

  final List<String> readOnlyRoots;

  final bool networkEnabled;

  final List<String> networkAllowlist;

  final SandboxQuota quota;

  final List<String> deniedModules;

  final List<String> allowedModules;

  /// 「未加载」占位：所有字段都是空的，不含任何预置策略数字。
  /// 真实策略只能来自后端 rpc{sandbox_policy}（sandbox_policy.json）。
  static const SandboxStatus notLoaded = SandboxStatus(
    version: '未加载',
    fileIsolationEnabled: false,
    writableRoots: <String>[],
    readOnlyRoots: <String>[],
    networkEnabled: false,
    networkAllowlist: <String>[],
    quota: SandboxQuota(
      cpuPercent: 0,
      memoryMb: 0,
      timeoutSeconds: 0,
      actionOnExceed: '—',
    ),
    deniedModules: <String>[],
    allowedModules: <String>[],
  );

  static SandboxStatus fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return notLoaded;
    return fromJson(decoded.map((k, v) => MapEntry(k.toString(), v)));
  }

  static SandboxStatus fromJson(Map<String, dynamic> json) {
    final gates = json['gates'];
    if (gates is! Map) return notLoaded;
    final g = gates.map((k, v) => MapEntry(k.toString(), v));

    Map<String, dynamic> section(String key) {
      final value = g[key];
      if (value is Map) return value.map((k, v) => MapEntry(k.toString(), v));
      return const <String, dynamic>{};
    }

    final fileIsolation = section('file_isolation');
    final network = section('network_proxy');
    final quotaJson = section('quota');
    final moduleGating = section('module_gating');

    return SandboxStatus(
      version: (json['version'] ?? notLoaded.version).toString(),
      fileIsolationEnabled: fileIsolation['enabled'] == true,
      writableRoots: _asStringList(fileIsolation['writable_roots']),
      readOnlyRoots: _asStringList(fileIsolation['read_only_roots']),
      networkEnabled: network['enabled'] == true,
      networkAllowlist: _asStringList(network['allowlist']),
      quota: SandboxQuota.fromJson(quotaJson),
      deniedModules: _asStringList(moduleGating['deny_by_default']),
      allowedModules: _asStringList(moduleGating['allow']),
    );
  }

  String get writableSummary =>
      writableRoots.isEmpty ? '（无可写根）' : writableRoots.join('、');

  String get networkSummary =>
      networkAllowlist.isEmpty ? '（无出站白名单）' : networkAllowlist.join('、');

  /// 精简摘要：UI 默认只展示这一行，避免长路径刷屏。
  String get briefSummary => quota.summary;

  String get summary => <String>[
    '策略版本 $version',
    '可写根：$writableSummary',
    '只读根：${readOnlyRoots.join('、')}',
    '网络白名单：$networkSummary',
    '配额：${quota.summary}',
  ].join('\n');

  @override
  String toString() => summary;
}

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

List<String> _asStringList(dynamic v) {
  if (v is List) {
    return List<String>.unmodifiable(v.map((e) => e.toString()));
  }
  return const <String>[];
}

class SandboxView extends ChangeNotifier {
  SandboxView({SandboxStatus status = SandboxStatus.notLoaded})
    : _status = status;

  SandboxStatus _status;
  bool _loading = false;
  bool _loaded = false;

  SandboxStatus get status => _status;

  bool get loading => _loading;

  /// 只有后端真正返回了 gates 才算加载成功；加载失败一律回到 notLoaded，
  /// 不展示任何预置策略数字。
  bool get isLoaded => _loaded;

  Future<void> load(BackendClient client) async {
    _loading = true;
    notifyListeners();
    try {
      final env = await client.sendControl('rpc', <String, dynamic>{
        'action': 'sandbox_policy',
      });
      final payload = env.payload;
      if (payload is Map && payload['gates'] is Map) {
        _status = SandboxStatus.fromJson(
          payload.map((k, v) => MapEntry(k.toString(), v)),
        );
        _loaded = true;
      } else {
        _status = SandboxStatus.notLoaded;
        _loaded = false;
      }
    } on Object {
      _status = SandboxStatus.notLoaded;
      _loaded = false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }
}
