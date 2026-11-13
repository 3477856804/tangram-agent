/// Android 端真实 OTA 更新服务（2026-11-13）。
///
/// 流程：GET GitHub Releases API `releases/latest` → 语义化版本比较 →
/// 真实下载 APK 到应用私有 external files 目录（边下边回调真实字节进度）→
/// MethodChannel('tangram/update').installApk 调起系统安装器覆盖安装。
/// **不卸载、保留数据**——前提是新旧 APK 同签名（debug keystore 每次 CI
/// 不同会导致 INSTALL_FAILED_UPDATE_INCOMPATIBLE，见 build.gradle.kts 的
/// release signingConfig 骨架：发布前必须固定 keystore）。
///
/// 仓库 owner/name 与 token 都是常量，用户换成自己的 GitHub 仓库即可。
/// 网络失败如实返回 available=false + error，绝不假装有更新。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 一次「检查最新真实版本」的结果。error 非空表示检查失败（如实上报）。
class UpdateInfo {
  const UpdateInfo({
    required this.available,
    required this.current,
    this.latest,
    this.apkUrl,
    this.size,
    this.notes,
    this.error,
  });

  /// 是否有可安装的新版本（latest 语义化比较 > current 且带 .apk 资产）。
  final bool available;

  /// 当前构建版本（[UpdateService.currentVersion]）。
  final String current;

  /// Releases API tag_name 去掉前导 v 后的版本号；检查失败时为 null。
  final String? latest;

  /// 最新 Release 里 .apk 资产的 browser_download_url。
  final String? apkUrl;

  /// APK 真实字节大小（GitHub asset.size）；未知时为 null。
  final int? size;

  /// Release 正文（更新说明），空则为 null。
  final String? notes;

  /// 网络/API 失败原因；成功时为 null。
  final String? error;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'available': available,
        'current': current,
        'latest': latest,
        'apk_url': apkUrl,
        'size': size,
        'notes': notes,
        'error': error,
      };
}

/// 下载 + 调起安装的结果。
class InstallOutcome {
  const InstallOutcome({
    required this.ok,
    this.pendingPermission = false,
    this.apkPath,
    this.error,
  });

  /// 系统安装器已调起。
  final bool ok;

  /// 未授予「安装未知应用」权限：原生侧已跳转系统授权页，
  /// 授权后重新点「检查更新」即可直接安装（APK 已下载，不会重复下载）。
  final bool pendingPermission;

  final String? apkPath;
  final String? error;
}

class UpdateService {
  UpdateService();

  // ---- 更新源常量：换成自己的 GitHub 仓库时只改这里 ----

  /// 仓库 owner（发布通道：3477856804/tangram-agent-releases）。
  static const String repoOwner = '3477856804';

  /// 发布通道仓库名——公开，但只含 Release 构建产物，无任何源码
  /// （源码仓库 tangram-agent 为闭源私有，OTA 匿名可读产物清单）。
  static const String repoName = 'tangram-agent-releases';

  /// 可选 GitHub token：构建时 --dart-define=TANGRAM_GITHUB_TOKEN=xxx 注入
  /// （私有仓库 / 提高匿名 60 次/小时限流）。空串表示匿名访问。
  static const String githubToken =
      String.fromEnvironment('TANGRAM_GITHUB_TOKEN', defaultValue: '');

  // ---- 版本真源 ----

  /// 当前版本真源：构建时以 `--dart-define=TANGRAM_VERSION=<pubspec version>`
  /// 注入；默认值与 pubspec.yaml 的 version 字段及仓库根 VERSION 文件保持一致。
  static const String currentVersion =
      String.fromEnvironment('TANGRAM_VERSION', defaultValue: '0.0.1');

  static const MethodChannel _channel = MethodChannel('tangram/update');
  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static const String _autoKey = 'tangram.auto_update_check';

  Uri get _latestReleaseUri => Uri.parse(
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest');

  /// 拉取 releases/latest，语义化比较（0.0.1 vs 0.0.2）。
  /// 任何网络/解析失败都如实返回 available=false + error。
  Future<UpdateInfo> checkLatest() async {
    final String current = currentVersion;
    http.Client? client;
    try {
      client = http.Client();
      final Map<String, String> headers = <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        if (githubToken.isNotEmpty) 'Authorization': 'Bearer $githubToken',
      };
      final http.Response resp =
          await client.get(_latestReleaseUri, headers: headers)
              .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 404) {
        return UpdateInfo(
            available: false,
            current: current,
            error: '仓库 $repoOwner/$repoName 尚无已发布的 Release（API 404）');
      }
      if (resp.statusCode != 200) {
        return UpdateInfo(
            available: false,
            current: current,
            error: 'GitHub Releases API 返回 HTTP ${resp.statusCode}');
      }
      final dynamic decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map) {
        return UpdateInfo(
            available: false, current: current, error: 'Releases API 响应结构异常');
      }
      final String tag = (decoded['tag_name'] ?? '').toString();
      if (tag.isEmpty) {
        return UpdateInfo(
            available: false, current: current, error: '最新 Release 缺少 tag_name');
      }
      final String latest = tag.replaceFirst(RegExp(r'^[vV]'), '');
      String? apkUrl;
      int? size;
      final dynamic assets = decoded['assets'];
      if (assets is List) {
        for (final dynamic a in assets) {
          if (a is Map &&
              (a['name'] ?? '').toString().toLowerCase().endsWith('.apk')) {
            final String url = (a['browser_download_url'] ?? '').toString();
            if (url.isNotEmpty) {
              apkUrl = url;
              final dynamic s = a['size'];
              size = s is num ? s.toInt() : null;
              break;
            }
          }
        }
      }
      final String notes = (decoded['body'] ?? '').toString().trim();
      final bool newer = compareVersions(latest, current) > 0;
      if (newer && apkUrl == null) {
        return UpdateInfo(
          available: false,
          current: current,
          latest: latest,
          notes: notes.isEmpty ? null : notes,
          error: '发现新版本 v$latest，但该 Release 未附带 .apk 资产；'
              '请先在 Release 中上传 APK 再检查',
        );
      }
      return UpdateInfo(
        available: newer,
        current: current,
        latest: latest,
        apkUrl: apkUrl,
        size: size,
        notes: notes.isEmpty ? null : notes,
      );
    } on TimeoutException {
      return UpdateInfo(
          available: false,
          current: current,
          error: '检查更新超时（15s）：网络不可达或 GitHub 响应缓慢');
    } on http.ClientException catch (e) {
      return UpdateInfo(
          available: false, current: current, error: '网络请求失败：$e');
    } on Object catch (e) {
      return UpdateInfo(
          available: false,
          current: current,
          error: '检查更新失败：${e.runtimeType}: $e');
    } finally {
      client?.close();
    }
  }

  /// 真实下载 APK 到应用私有 external files 目录（ota/ 子目录），
  /// 边下边回调真实字节进度；完成后经 MethodChannel 调起系统安装器。
  /// 文件已完整下载过（大小与 asset.size 一致）时跳过下载直接调起安装。
  Future<InstallOutcome> downloadAndInstall(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final String? url = info.apkUrl;
    if (url == null || url.isEmpty) {
      return const InstallOutcome(
          ok: false, error: '没有可用的 APK 下载链接（Release 未附带 .apk 资产）');
    }
    try {
      final Directory dir = await _otaDir();
      final File file =
          File('${dir.path}/tangram-v${info.latest ?? 'latest'}.apk');
      final int? expected = info.size;
      bool alreadyComplete = false;
      if (file.existsSync()) {
        if (expected != null && expected > 0 && file.lengthSync() == expected) {
          alreadyComplete = true;
        } else {
          // 上次中断的残留：字节数与真实大小不符，删掉重下。
          await file.delete();
        }
      }
      if (alreadyComplete) {
        final int len = file.lengthSync();
        onProgress?.call(len, expected ?? len);
      } else {
        await _downloadTo(url, file, onProgress);
      }
      final Map<Object?, Object?>? res =
          await _channel.invokeMethod<Map<Object?, Object?>>(
        'installApk',
        <String, Object>{
          'filePath': file.path,
          'fileType': 'application/vnd.android.package-archive',
        },
      );
      final bool pending = res?['pendingPermission'] == true;
      final bool started = res?['ok'] == true;
      if (!started && !pending) {
        return InstallOutcome(
          ok: false,
          apkPath: file.path,
          error: (res?['error'] ?? '调起系统安装器失败（原生侧未返回 ok）').toString(),
        );
      }
      return InstallOutcome(
          ok: started, pendingPermission: pending, apkPath: file.path);
    } on MissingPluginException {
      return const InstallOutcome(
          ok: false,
          error: '当前平台未实现 installApk（MethodChannel tangram/update 仅 Android）');
    } on Object catch (e) {
      return InstallOutcome(ok: false, error: '${e.runtimeType}: $e');
    }
  }

  /// 「自动检查更新」开关持久化（FlutterSecureStorage，随 App 卸载清除）。
  Future<bool> loadAutoCheck() async {
    try {
      final String? v = await _secure.read(key: _autoKey);
      return v == '1' || v == 'true';
    } on Object {
      // 存储不可用：如实视为关闭，不假装开启。
      return false;
    }
  }

  /// 持久化开关；失败会 rethrow，由调用方如实提示，不静默吞掉。
  Future<void> saveAutoCheck(bool enabled) async {
    await _secure.write(key: _autoKey, value: enabled ? '1' : '0');
  }

  /// 语义化版本比较：逐段数字比较（0.0.1 < 0.0.2 < 0.1.0）。
  /// 返回 >0 表示 a 新于 b；非数字段按 0 处理；忽略 -/+/build 后缀。
  static int compareVersions(String a, String b) {
    final List<int> pa = _semverParts(a);
    final List<int> pb = _semverParts(b);
    final int n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final int x = i < pa.length ? pa[i] : 0;
      final int y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  static List<int> _semverParts(String v) {
    String s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    s = s.split('+').first.split('-').first;
    return s
        .split('.')
        .map((String p) => int.tryParse(p.trim()) ?? 0)
        .toList(growable: false);
  }

  static String formatSize(int? bytes) {
    if (bytes == null || bytes <= 0) return '大小未知';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<Directory> _otaDir() async {
    final Directory? ext = await getExternalStorageDirectory();
    final Directory base = ext ?? await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${base.path}/ota');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// dart:io HttpClient 真实流式下载（GitHub 资产 URL 会 302 到对象存储，
  /// HttpClient 默认自动跟随重定向）。进度 = 真实落盘字节数。
  Future<void> _downloadTo(
    String url,
    File file,
    void Function(int received, int total)? onProgress,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final HttpClientRequest req =
          await client.openUrl('GET', Uri.parse(url));
      if (githubToken.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $githubToken');
        req.headers.set('Accept', 'application/octet-stream');
      }
      final HttpClientResponse resp =
          await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != HttpStatus.ok) {
        await resp.drain<void>();
        throw StateError('下载失败：HTTP ${resp.statusCode}（$url）');
      }
      final int total = resp.contentLength; // 可能为 -1（未知）
      final int? expectedSize = total > 0 ? total : null;
      final IOSink sink = file.openWrite();
      var received = 0;
      try {
        await for (final List<int> chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, expectedSize ?? received);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (expectedSize != null && received != expectedSize) {
        throw StateError(
            '下载不完整：$received/$expectedSize 字节（连接中断），请重试');
      }
    } finally {
      client.close(force: true);
    }
  }
}
