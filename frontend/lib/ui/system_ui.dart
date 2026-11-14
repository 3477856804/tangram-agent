import 'dart:ui' show Brightness;

import 'package:flutter/services.dart';

/// 沉浸式系统栏统一样式（问题 #10：App 上下边缘黑带）。
///
/// 配合 [SystemUiMode.edgeToEdge] 使用：状态栏 / 导航栏背景全透明，
/// 页面背景（Scaffold/AppBar 主题色）自然延伸到系统栏底下；图标亮度
/// 按当前主题深浅切换，保证浅底深图标、深底浅图标始终可读。
/// 桌面平台该调用为无害 no-op。
void applyTgaSystemUi(Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: const Color(0x00000000),
    systemNavigationBarColor: const Color(0x00000000),
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarIconBrightness: dark ? Brightness.light : Brightness.dark,
  ));
}
