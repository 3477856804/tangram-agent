/// 全平台真实 OTA 更新服务（2026-11-14）。
///
/// 流程：GET GitHub Releases API `releases/latest` → 语义化版本比较 →
/// 按当前平台挑选对应安装包 → 分片并行下载 + SHA256 digest 真实校验
/// （哈希取自 asset 的 digest 字段，不写进公开公告；校验不过拒绝安装）→
/// Android: MethodChannel('tangram/update').installApk 调起系统安装器覆盖安装;
/// Windows/Linux/macOS: 落盘更新脚本(杀进程→解包覆盖安装目录→自动重启),
/// 应用退出后脚本接管完成覆盖更新。
/// **不卸载、保留数据**——前提是新旧包同签名（debug keystore 每次 CI
/// 不同会导致 INSTALL_FAILED_UPDATE_INCOMPATIBLE，见 build.gradle.kts 的
/// release signingConfig 骨架：发布前必须固定 keystore）。
///
/// 仓库 owner/name 与 token 都是常量，用户换成自己的 GitHub 仓库即可。
/// 网络失败如实返回 available=false + error，绝不假装有更新。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:tangram/app_version.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
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
    this.assetName,
    this.sumsUrl,
    this.sha256,
  });

  /// 是否有可安装的新版本（latest 语义化比较 > current 且带本平台安装包资产）。
  final bool available;

  /// 当前构建版本（[UpdateService.currentVersion]）。
  final String current;

  /// Releases API tag_name 去掉前导 v 后的版本号；检查失败时为 null。
  final String? latest;

  /// 最新 Release 里本平台安装包（Android 为 .apk）的 browser_download_url。
  final String? apkUrl;

  /// 安装包资产文件名（校验 SHA256SUMS 时按名匹配）。
  final String? assetName;

  /// Release 里 SHA256SUMS.txt 资产地址（兼容历史发布的校验清单）。
  final String? sumsUrl;

  /// 本平台资产的 SHA256（GitHub asset 的 digest 字段）。
  /// 完整性校验的真源，不再依赖把哈希写进公开更新公告。
  final String? sha256;

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
        'asset_name': assetName,
        'size': size,
        'sha256': sha256,
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

  /// 用户可见的更新公告恒为这一句：公开 Release 正文不写 commit、产物清单、
  /// SHA256、签名或证书指纹，App 侧也不透出远端正文。
  static const String releaseNotes = '已修复已知问题';

  /// 构建注入版本（--dart-define=TANGRAM_VERSION），仅作兜底；
  /// 与 UI / 能力协商 / MCP 握手共用 app_version.dart 的单一真源。
  static const String fallbackVersion = kAppVersion;

  /// 真实安装包版本真源：读系统包信息（Android versionName / 桌面 pubspec），
  /// OTA 覆盖安装后立即反映新版本，不再依赖写死常量（问题 #7）。
  static Future<String> installedVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      final String v = info.version.trim();
      if (v.isNotEmpty) return v.split('+').first;
    } on Object {
      // 平台通道不可用时回退构建注入值。
    }
    return fallbackVersion;
  }

  /// 兼容旧引用：构建注入值。UI 展示一律改用 [installedVersion]。
  static String get currentVersion => fallbackVersion;

  static const MethodChannel _channel = MethodChannel('tangram/update');
  static const FlutterSecureStorage _secure = FlutterSecureStorage();
  static const String _autoKey = 'tangram.auto_update_check';

  Uri get _latestReleaseUri => Uri.parse(
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest');

  /// 拉取 releases/latest，语义化比较（0.0.1 vs 0.0.2）。
  /// 当前版本读真实安装包（[installedVersion]），已是最新不会再误报（问题 #7）。
  /// 任何网络/解析失败都如实返回 available=false + error。
  Future<UpdateInfo> checkLatest() async {
    final String current = await installedVersion();
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
      String? assetName;
      String? sumsUrl;
      String? sha256;
      int? size;
      final dynamic assets = decoded['assets'];
      if (assets is List) {
        for (final dynamic a in assets) {
          if (a is! Map) continue;
          final String name = (a['name'] ?? '').toString();
          final String url = (a['browser_download_url'] ?? '').toString();
          if (url.isEmpty) continue;
          if (name.toLowerCase() == 'sha256sums.txt') {
            sumsUrl = url;
            continue;
          }
          if (assetName == null && _matchesPlatform(name)) {
            assetName = name;
            apkUrl = url;
            final dynamic s = a['size'];
            size = s is num ? s.toInt() : null;
            // GitHub asset API 自带 integrity digest；校验改用它，
            // SHA256 不再写进用户可见的公开更新公告。
            final dynamic dg = a['digest'];
            if (dg is String && dg.startsWith('sha256:')) {
              sha256 = dg.substring(7).toLowerCase();
            }
          }
        }
      }
      // 公告统一为固定一句，不读取远端 body：Release 正文属于构建细节，
      // 不进入任何用户可见界面。
      final bool newer = compareVersions(latest, current) > 0;
      if (newer && apkUrl == null) {
        return UpdateInfo(
          available: false,
          current: current,
          latest: latest,
          notes: releaseNotes,
          error: '发现新版本 v$latest，但该 Release 未附带本平台的安装包资产',
        );
      }
      return UpdateInfo(
        available: newer,
        current: current,
        latest: latest,
        apkUrl: apkUrl,
        assetName: assetName,
        sumsUrl: sumsUrl,
        sha256: sha256,
        size: size,
        notes: releaseNotes,
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

  /// 资产名是否匹配当前平台安装包（六文件格式：exe/dmg/deb/apk/ipa/hap，
  /// 兼容历史 zip/tar.gz）。
  static bool _matchesPlatform(String name) {
    final String n = name.toLowerCase();
    if (Platform.isAndroid) return n.endsWith('.apk');
    if (Platform.isWindows) {
      return n.contains('windows') && (n.endsWith('.exe') || n.endsWith('.zip'));
    }
    if (Platform.isLinux) {
      return n.contains('linux') &&
          (n.endsWith('.appimage') ||
              n.endsWith('.deb') ||
              n.endsWith('.tar.gz'));
    }
    if (Platform.isMacOS) {
      return n.contains('macos') && (n.endsWith('.dmg') || n.endsWith('.tar.gz'));
    }
    return false;
  }

  /// 从 Release 正文的「产物校验」代码块解析本资产的期望 SHA256。
  static String? _sha256FromNotes(String? notes, String? assetName) {
    if (notes == null || assetName == null) return null;
    final RegExp line = RegExp(
        r'([0-9a-f]{64})\s+\S*' + RegExp.escape(assetName) + r'\S*');
    final RegExpMatch? m = line.firstMatch(notes);
    return m?.group(1);
  }

  /// 真实下载本平台安装包到应用私有目录（ota/ 子目录），
  /// 边下边回调真实字节进度；SHA256SUMS 校验通过后：
  /// Android 经 MethodChannel 调起系统安装器；桌面平台落盘更新脚本并退出,
  /// 由脚本完成覆盖与重启。
  /// 文件已完整下载过（大小与 asset.size 一致）时跳过下载直接安装。
  Future<InstallOutcome> downloadAndInstall(
    UpdateInfo info, {
    void Function(int received, int total)? onProgress,
  }) async {
    final String? url = info.apkUrl;
    if (url == null || url.isEmpty) {
      return const InstallOutcome(
          ok: false, error: '没有可用的安装包下载链接（Release 未附带本平台资产）');
    }
    try {
      final Directory dir = await _otaDir();
      final String fileName = info.assetName ??
          (Platform.isAndroid
              ? 'tangram-v${info.latest ?? 'latest'}.apk'
              : 'tangram-update-v${info.latest ?? 'latest'}');
      final File file = File('${dir.path}/$fileName');
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
        await _downloadResilient(url, file, expected, onProgress);
      }
      // 完整性校验：优先 GitHub asset 自带 digest，兼容历史 Release 正文
      // 清单与 SHA256SUMS.txt 资产。校验不过删包拒装。
      String? verifyError = await _verifyAgainstExpected(
          info.sha256 ?? _sha256FromNotes(info.notes, info.assetName), file);
      if (verifyError == null &&
          info.sumsUrl != null &&
          info.sumsUrl!.isNotEmpty) {
        verifyError = await _verifySha256(info.sumsUrl!, fileName, file);
      }
      if (verifyError != null) {
        try {
          await file.delete();
        } on Object {
          // 删不掉也只如实报错,绝不装校验不过的包。
        }
        return InstallOutcome(ok: false, error: verifyError);
      }
      if (!Platform.isAndroid) {
        return await _applyDesktopUpdate(file);
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

  /// 与期望 SHA256 比对；期望为空则跳过。不匹配返回错误描述。
  Future<String?> _verifyAgainstExpected(String? expected, File file) async {
    if (expected == null || expected.isEmpty) return null;
    try {
      final crypto.Digest d = await crypto.sha256.bind(file.openRead()).first;
      if (d.toString() != expected.toLowerCase()) {
        return 'SHA256 校验不通过：安装包可能被篡改（期望 $expected，实际 $d）';
      }
      return null;
    } on Object catch (e) {
      return '校验失败：$e';
    }
  }

  /// 下载 SHA256SUMS.txt 并按资产名比对；不匹配返回错误描述。
  Future<String?> _verifySha256(
      String sumsUrl, String assetName, File file) async {
    try {
      final http.Client c = http.Client();
      String sums;
      try {
        final http.Response r =
            await c.get(Uri.parse(sumsUrl)).timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) return '无法获取校验清单（HTTP ${r.statusCode}）';
        sums = utf8.decode(r.bodyBytes);
      } finally {
        c.close();
      }
      String? want;
      for (final String line in sums.split('\n')) {
        final List<String> parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length >= 2 && parts.sublist(1).join(' ').contains(assetName)) {
          want = parts[0].toLowerCase();
          break;
        }
      }
      if (want == null) return null; // 清单里没有该资产：不阻塞（如实跳过）
      final crypto.Hash h = crypto.sha256;
      final crypto.Digest d = await h.bind(file.openRead()).first;
      if (d.toString() != want) {
        return 'SHA256 校验不通过：安装包可能被篡改（期望 $want，实际 $d）';
      }
      return null;
    } on Object {
      // 校验清单拉不到：如实跳过,不因镜像问题卡更新。
      return null;
    }
  }

  /// 桌面平台（Windows/Linux/macOS）覆盖更新：
  /// 落盘更新脚本 → 脚本等待本进程退出 → 安装/解包覆盖 → 重启应用。
  /// 支持新六文件格式（exe 安装器 / deb / dmg）与历史 zip/tar.gz。
  Future<InstallOutcome> _applyDesktopUpdate(File pkg) async {
    final Directory dir = pkg.parent;
    final String exe = Platform.resolvedExecutable;
    final String v = pkg.path;
    final String lower = v.toLowerCase();
    final String script;
    final List<String> cmd;
    if (Platform.isWindows) {
      script = '${dir.path}\\update.bat';
      final String tmp = '${dir.path}\\update_new';
      final String appDir = File(exe).parent.path;
      final String exeName = exe.split('\\').last;
      final bool portable = lower.endsWith('.exe');
      // 便携单文件 exe:自解压到 %LOCALAPPDATA%\tangram 并自行拉起新应用。
      final String installStep = portable
          ? '"$v"\r\n'
          : 'rmdir /s /q "$tmp" >nul 2>&1\r\n'
              'powershell -NoProfile -Command "Expand-Archive -LiteralPath \'$v\' -DestinationPath \'$tmp\' -Force"\r\n'
              'robocopy "$tmp" "$appDir" /E /IS /IT >nul\r\n';
      File(script).writeAsStringSync(
        '@echo off\r\n'
        'timeout /t 3 /nobreak >nul\r\n'
        'taskkill /f /im "$exeName" >nul 2>&1\r\n'
        '$installStep'
        '${portable ? '' : 'start "" "$exe"\r\n'}'
        'del "%~f0"\r\n',
      );
      cmd = <String>['cmd.exe', '/c', script];
    } else {
      script = '${dir.path}/update.sh';
      final String tmp = '${dir.path}/update_new';
      String target;
      String relaunch;
      String unpack;
      if (Platform.isLinux) {
        if (lower.endsWith('.appimage')) {
          // 单文件 AppImage:直接以新包拉起,旧文件由用户/缓存清理替换。
          unpack = 'chmod +x "$v"\n';
          relaunch = '"$v" >/dev/null 2>&1 &\n';
          target = '';
        } else {
          target = File(exe).parent.path; // bundle 目录
          relaunch = '"$exe"';
          unpack = lower.endsWith('.deb')
              ? '(cd "$tmp" && ar x "$v")\n'
                  'tar -xf "$tmp"/data.tar.* -C "$tmp"\n'
                  'cp -a "$tmp"/opt/tangram/. "$target/"\n'
              : 'tar -xzf "$v" -C "$tmp"\n' 'cp -a "$tmp"/. "$target/"\n';
        }
      } else {
        // macOS: .../tangram.app/Contents/MacOS/tangram → 覆盖 .app
        target = File(exe).parent.parent.parent.parent.path;
        relaunch = 'open "$target/tangram.app"';
        unpack = lower.endsWith('.dmg')
            ? 'hdiutil attach "$v" -nobrowse -mountpoint "$tmp/mnt" >/dev/null\n'
                'rm -rf "$target/tangram.app"\n'
                'cp -R "$tmp/mnt/tangram.app" "$target/"\n'
                'hdiutil detach "$tmp/mnt" >/dev/null || true\n'
            : 'tar -xzf "$v" -C "$tmp"\n'
                'rm -rf "$target/tangram.app" && mv "$tmp/tangram.app" "$target/"\n';
      }
      File(script).writeAsStringSync(
        '#!/bin/sh\n'
        'sleep 3\n'
        'rm -rf "$tmp"\n'
        'mkdir -p "$tmp"\n'
        '$unpack'
        '$relaunch\n'
        'rm -f "$script"\n',
      );
      Process.runSync('chmod', <String>['+x', script]);
      cmd = <String>['sh', script];
    }
    await Process.start(
      cmd.first,
      cmd.skip(1).toList(),
      mode: ProcessStartMode.detached,
    );
    // 脚本已接管:2 秒后本进程退出,脚本等待期间完成覆盖并重启应用。
    Future<void>.delayed(const Duration(seconds: 2), () => exit(0));
    return InstallOutcome(
      ok: true,
      apkPath: pkg.path,
      error: null,
    );
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
    // getExternalStorageDirectory 仅 Android 实现，桌面调用会抛
    // UnimplementedError；按平台守卫并降级到应用文档目录。
    Directory? ext;
    if (Platform.isAndroid) {
      try {
        ext = await getExternalStorageDirectory();
      } on Object {
        ext = null;
      }
    }
    final Directory base = ext ?? await getApplicationDocumentsDirectory();
    final Directory dir = Directory('${base.path}/ota');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// 韧性强下载：
  ///  1. 镜像并行竞速，取首字节最快的通道，不再串行等慢镜像超时；
  ///  2. Range 分片 8 路并行下载，各分片断点续传（.part 文件记进度）；
  ///  3. 超时按"分片空闲"计——只要还在收字节就不超时；
  ///  4. 服务器不支持 Range（返回 200）时自动回退单流边下边落盘。
  static const List<String> _mirrors = <String>[
    '', // 原 URL 直连优先
    'https://gh-proxy.com/',
    'https://ghfast.top/',
    'https://ghproxy.net/',
  ];

  static Uri? _mirrorUrl(String original, String prefix) =>
      prefix.isEmpty ? Uri.parse(original) : Uri.parse('$prefix$original');

  /// 并行探测所有通道，谁先给出首字节谁胜出。
  /// 串行试错时一个不可达镜像要等满超时才换下一个，是 OTA 慢的主因。
  Future<Uri?> _raceMirror(String url) async {
    final Completer<Uri?> winner = Completer<Uri?>();
    int pending = _mirrors.length;
    for (final String prefix in _mirrors) {
      final Uri? u = _mirrorUrl(url, prefix);
      if (u == null) {
        pending--;
        continue;
      }
      unawaited(_probeMirror(u).then((bool ok) {
        if (ok && !winner.isCompleted) winner.complete(u);
        pending--;
        if (pending == 0 && !winner.isCompleted) winner.complete(null);
      }));
    }
    if (pending == 0 && !winner.isCompleted) winner.complete(null);
    return winner.future;
  }

  Future<bool> _probeMirror(Uri u) async {
    final HttpClient c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);
    try {
      final HttpClientRequest req = await c.openUrl('GET', u);
      req.headers.set('Range', 'bytes=0-0');
      if (githubToken.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $githubToken');
      }
      final HttpClientResponse resp =
          await req.close().timeout(const Duration(seconds: 8));
      await resp.drain<void>();
      return resp.statusCode == HttpStatus.partialContent ||
          resp.statusCode == HttpStatus.ok;
    } on Object {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _downloadResilient(
    String url,
    File file,
    int? expectedSize,
    void Function(int received, int total)? onProgress,
  ) async {
    // 竞速胜出者排在最前，其余通道仍作为兜底；去重避免重复下载。
    final Uri? fast = await _raceMirror(url);
    final List<Uri?> candidates = <Uri?>[
      fast,
      for (final String prefix in _mirrors) _mirrorUrl(url, prefix),
    ];
    final Set<String> seen = <String>{};
    Object? lastError;
    for (final Uri? u in candidates) {
      if (u == null || !seen.add(u.toString())) continue;
      try {
        await _downloadChunked(u, file, expectedSize, onProgress);
        return;
      } on Object catch (e) {
        lastError = e;
      }
    }
    throw StateError('所有下载通道均失败（直连+3 个加速镜像）：$lastError');
  }

  Future<void> _downloadChunked(
    Uri url,
    File file,
    int? expectedSize,
    void Function(int received, int total)? onProgress,
  ) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      // 探测总大小与 Range 支持。竞速已选出可用通道，这里无需长超时。
      int total = expectedSize ?? 0;
      bool rangeOk = true;
      if (total <= 0) {
        final HttpClientRequest head = await client.openUrl('HEAD', url);
        if (githubToken.isNotEmpty) {
          head.headers.set('Authorization', 'Bearer $githubToken');
        }
        final HttpClientResponse headResp =
            await head.close().timeout(const Duration(seconds: 8));
        await headResp.drain<void>();
        total = headResp.contentLength;
      }
      if (total <= 0) rangeOk = false; // 大小未知：单流
      if (rangeOk) {
        // 校验镜像是否真支持 Range（有些代理会吞掉 Range 头返回 200）。
        final HttpClientRequest probe = await client.openUrl('GET', url);
        probe.headers.set('Range', 'bytes=0-0');
        final HttpClientResponse probeResp =
            await probe.close().timeout(const Duration(seconds: 8));
        rangeOk = probeResp.statusCode == HttpStatus.partialContent;
        await probeResp.drain<void>();
      }
      if (!rangeOk) {
        await _downloadSingle(client, url, file, onProgress);
        return;
      }
      // 8 路分片并行 + 断点续传：提高弱网下大包吞吐。
      const int kChunks = 8;
      final int chunkSize = (total / kChunks).ceil();
      final Directory dir = file.parent;
      final String base = file.uri.pathSegments.last;
      final List<Future<void>> jobs = <Future<void>>[];
      final List<File> parts = <File>[];
      int done = 0; // 已落盘总字节（跨分片累计）
      void report() => onProgress?.call(math.min(done, total), total);
      for (int i = 0; i < kChunks; i++) {
        final int start = i * chunkSize;
        if (start >= total) break;
        final int end = math.min(start + chunkSize - 1, total - 1);
        final File part = File('${dir.path}/$base.part$i');
        parts.add(part);
        jobs.add(_fetchRange(client, url, part, start, end, () {
          done = parts.fold<int>(
              0, (int s, File p) => s + (p.existsSync() ? p.lengthSync() : 0));
          report();
        }));
      }
      report();
      await Future.wait(jobs);
      // 合并分片。
      final IOSink sink = file.openWrite();
      try {
        for (final File p in parts) {
          await sink.addStream(p.openRead());
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      for (final File p in parts) {
        try {
          await p.delete();
        } on Object {
          // 残留 part 由清理缓存负责回收。
        }
      }
      if (file.lengthSync() != total) {
        throw StateError(
            '下载不完整：${file.lengthSync()}/$total 字节（连接中断），请重试');
      }
    } finally {
      client.close(force: true);
    }
  }

  /// 单分片下载：写入 .partN（已存在则从断点续传），30s 空闲超时重试 3 次。
  Future<void> _fetchRange(HttpClient client, Uri url, File part, int start,
      int end, void Function() onBytes) async {
    Object? lastError;
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final int have = part.existsSync() ? part.lengthSync() : 0;
        final int from = start + have;
        if (from > end) return; // 分片已完成
        final HttpClientRequest req = await client.openUrl('GET', url);
        req.headers.set('Range', 'bytes=$from-$end');
        if (githubToken.isNotEmpty) {
          req.headers.set('Authorization', 'Bearer $githubToken');
        }
        final HttpClientResponse resp =
            await req.close().timeout(const Duration(seconds: 20));
        if (resp.statusCode != HttpStatus.partialContent) {
          await resp.drain<void>();
          throw StateError('分片请求未得到 206（HTTP ${resp.statusCode}）');
        }
        final IOSink sink =
            part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
        try {
          await resp
              .timeout(const Duration(seconds: 30))
              .map((List<int> chunk) {
            sink.add(chunk);
            onBytes();
            return chunk;
          }).drain<void>();
          await sink.flush();
        } finally {
          await sink.close();
        }
        final int nowHave = part.lengthSync();
        if (start + nowHave - 1 < end) {
          throw StateError('分片中断：$nowHave/${end - start + 1}');
        }
        return;
      } on Object catch (e) {
        lastError = e; // 保留 .part 断点，重试续传
      }
    }
    throw StateError('分片 $start-$end 重试 3 次仍失败：$lastError');
  }

  /// 单流回退：服务器不支持 Range 时边下边落盘，空闲 30s 才超时。
  Future<void> _downloadSingle(
    HttpClient client,
    Uri url,
    File file,
    void Function(int received, int total)? onProgress,
  ) async {
    final HttpClientRequest req = await client.openUrl('GET', url);
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
    final int total = resp.contentLength;
    final IOSink sink = file.openWrite();
    var received = 0;
    try {
      await resp.timeout(const Duration(seconds: 30)).map((List<int> chunk) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total > 0 ? total : received);
        return chunk;
      }).drain<void>();
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (total > 0 && received != total) {
      throw StateError('下载不完整：$received/$total 字节（连接中断），请重试');
    }
  }
}
