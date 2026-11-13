import 'dart:io';

import 'package:flutter/services.dart';

import 'package:tangram/services/device_files.dart';

/// 平台注入层：把「设备文件访问授权」这一平台差异收敛到唯一文件。
///
/// 核心 device_files.dart 不含任何平台判断，全平台共用；本文件按 Platform 提供
/// 对应网关实现。Android 的「所有文件访问」(MANAGE_EXTERNAL_STORAGE) 需要跳系统
/// 设置页，原生侧由 scripts/inject_android_permissions.py 在生成平台运行器时
/// 注入 MethodChannel 处理，channel 名与方法名在此约定，两侧一致。

const String kDeviceFileChannel = 'tangram/device_files';

const String kMethodCheck = 'checkAccess';
const String kMethodRequest = 'requestAccess';
const String kMethodRoots = 'storageRoots';

/// Android 网关：经 MethodChannel 询问/申请系统「所有文件访问」权限。
/// 原生插件缺失（例如桌面端误用）时优雅降级为 denied，绝不伪造授权成功。
class AndroidDeviceFileGateway implements DeviceFileGateway {
  AndroidDeviceFileGateway({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(kDeviceFileChannel);

  final MethodChannel _channel;

  @override
  Future<DeviceFileAccess> check() async {
    try {
      final bool? ok = await _channel.invokeMethod<bool>(kMethodCheck);
      return ok == true
          ? DeviceFileAccess.granted
          : DeviceFileAccess.needsSystemSettings;
    } on MissingPluginException {
      return DeviceFileAccess.denied;
    } on PlatformException {
      return DeviceFileAccess.denied;
    }
  }

  @override
  Future<DeviceFileAccess> request() async {
    try {
      // 原生侧拉起 ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION 设置页；
      // 返回用户回到 App 后的即时授权状态。
      final bool? ok = await _channel.invokeMethod<bool>(kMethodRequest);
      return ok == true
          ? DeviceFileAccess.granted
          : DeviceFileAccess.needsSystemSettings;
    } on MissingPluginException {
      return DeviceFileAccess.denied;
    } on PlatformException {
      return DeviceFileAccess.denied;
    }
  }

  @override
  List<DeviceRoot> roots() {
    try {
      final List<dynamic>? raw = _cachedRoots;
      if (raw == null) return _defaultAndroidRoots();
      return raw
          .map((dynamic e) => DeviceRoot(
                (e['path'] ?? '').toString(),
                (e['label'] ?? '共享存储').toString(),
                writable: e['writable'] != false,
              ))
          .toList();
    } on Object {
      return _defaultAndroidRoots();
    }
  }

  List<dynamic>? _cachedRoots;

  /// 由 App 启动阶段把原生返回的根目录注入（避免每次 roots() 走异步通道）。
  void setRoots(List<dynamic> raw) => _cachedRoots = raw;

  static List<DeviceRoot> _defaultAndroidRoots() => const <DeviceRoot>[
        DeviceRoot('/storage/emulated/0', '设备共享存储'),
        DeviceRoot('/storage/emulated/0/Download', '下载'),
        DeviceRoot('/storage/emulated/0/DCIM', '相册'),
        DeviceRoot('/storage/emulated/0/Documents', '文档'),
      ];

  /// 异步从原生侧拉取真实可用根目录（App 启动时调用一次）。
  Future<void> refreshRoots() async {
    try {
      final List<dynamic>? raw =
          await _channel.invokeListMethod<dynamic>(kMethodRoots);
      if (raw != null) _cachedRoots = raw;
    } on MissingPluginException {
      _cachedRoots = null;
    } on PlatformException {
      _cachedRoots = null;
    }
  }
}

/// 按当前平台构造合适的网关（平台无关核心不动，仅此处分流）。
DeviceFileGateway buildPlatformGateway({String? appDocumentsPath}) {
  if (Platform.isAndroid) {
    return AndroidDeviceFileGateway();
  }
  if (Platform.isIOS) {
    // iOS 无「所有文件访问」概念：仅 App 文档目录 + 通过文档选择器授权的目录。
    final String base = appDocumentsPath ?? Directory.current.path;
    return LocalDeviceFileGateway(<DeviceRoot>[
      DeviceRoot(base, 'App 文档'),
    ]);
  }
  // 桌面（Linux / Windows / macOS）：家目录直接可读写，无需系统授权页。
  final String home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
  return LocalDeviceFileGateway(<DeviceRoot>[
    DeviceRoot(home, '用户目录'),
    DeviceRoot('$home/Downloads', '下载'),
    DeviceRoot('$home/Documents', '文档'),
  ]);
}
