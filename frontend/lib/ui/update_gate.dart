import 'dart:async';

import 'package:flutter/material.dart';

import '../services/update_service.dart';
import 'pages/tga_settings_page.dart' show TgaSettingsUpdateDialog;

/// 启动时静默检查更新一次（问题 #8：取代「自动检查更新」开关）。
/// 挂在 MaterialApp.router 的 builder 上，发现新版本才弹更新对话框；
/// 无更新/失败完全静默，不打扰用户。每次会话只检查一次。
class TgaUpdateGate extends StatefulWidget {
  const TgaUpdateGate({super.key, required this.child});
  final Widget child;

  @override
  State<TgaUpdateGate> createState() => _TgaUpdateGateState();
}

class _TgaUpdateGateState extends State<TgaUpdateGate> {
  static bool _checkedThisSession = false;

  @override
  void initState() {
    super.initState();
    // 等首帧渲染 + 网络就绪后再查，避免与启动初始化抢跑。
    Timer(const Duration(seconds: 3), _check);
  }

  Future<void> _check() async {
    if (_checkedThisSession || !mounted) return;
    _checkedThisSession = true;
    // 通知权限类本地状态无关；纯网络检查。
    final UpdateInfo info = await UpdateService().checkLatest();
    if (!mounted || !info.available || info.apkUrl == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => TgaSettingsUpdateDialog(info: info),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
