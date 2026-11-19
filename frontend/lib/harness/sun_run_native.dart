import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// 爱阳光跑原生桥：Flutter ↔ Kotlin 系统位置注入。
///
/// 只有 Android 有实现；其它平台返回 `supported:false`，不伪造已注入。
/// 原生侧需要用户在开发者选项里把本应用设为「模拟位置信息应用」，
/// 并授予位置权限；未授权时如实返回 `mock_allowed:false`。
class SunRunNative {
  SunRunNative._();

  static const MethodChannel _channel = MethodChannel('tga/sun_run');

  static bool get supported => !kIsWeb && Platform.isAndroid;

  static Future<Map<String, dynamic>> status() async {
    if (!supported) return _unsupported();
    return _invoke('status');
  }

  static Future<Map<String, dynamic>> start(Map<String, dynamic> fix) async {
    if (!supported) return _unsupported();
    return _invoke('start', fix);
  }

  static Future<Map<String, dynamic>> update(Map<String, dynamic> fix) async {
    if (!supported) return <String, dynamic>{'ok': false, 'supported': false};
    return _invoke('update', fix);
  }

  static Future<Map<String, dynamic>> stop() async {
    if (!supported) return _unsupported();
    return _invoke('stop');
  }

  static Future<Map<String, dynamic>> openDeveloperSettings() async {
    if (!supported) return _unsupported();
    return _invoke('openDeveloperSettings');
  }

  static Future<Map<String, dynamic>> requestPermission() async {
    if (!supported) return _unsupported();
    return _invoke('requestPermission');
  }

  static Future<Map<String, dynamic>> _invoke(
      String method, [Map<String, dynamic>? args]) async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod<Map<dynamic, dynamic>>(method, args);
      if (result == null) {
        return <String, dynamic>{
          'ok': false,
          'supported': true,
          'error': '原生桥返回空结果',
        };
      }
      return result.map(
          (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v));
    } on MissingPluginException {
      return <String, dynamic>{
        'ok': false,
        'supported': false,
        'error': '当前构建未包含爱阳光跑原生模块',
      };
    } on PlatformException catch (e) {
      return <String, dynamic>{
        'ok': false,
        'supported': true,
        'error': '${e.code}: ${e.message}',
      };
    }
  }

  static Map<String, dynamic> _unsupported() => <String, dynamic>{
        'ok': false,
        'supported': false,
        'error': '系统位置注入仅 Android 可用',
      };
}
