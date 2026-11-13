/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/ui/widgets/backend_status_banner.dart';

/// 全应用统一离线文案：只保留一份真源，禁止各面板硬写「未连接后端」。
const String kOfflineHint = kOfflineBannerHint;

/// 面板异步状态。
///
/// 诚实原则：内置沙箱未启动时统一交给 [BackendStatusBanner] 展示，
/// 既不用假数据填界面，也不显示一个转不完的「加载中…」。
mixin AsyncPanelMixin<T extends StatefulWidget> on State<T> {
  bool loading = false;
  String? error;
  bool offline = false;

  void setLoading(bool v) {
    loading = v;
    if (v) {
      error = null;
      offline = false;
    }
    if (mounted) setState(() {});
  }

  void setError(String? e) {
    error = e;
    if (mounted) setState(() {});
  }

  Future<void> runGuarded(Future<void> Function() action) async {
    setLoading(true);
    try {
      await action();
      error = null;
      offline = false;
    } on BackendNotConnected {
      offline = true;
      error = null;
    } on Object catch (e) {
      offline = false;
      error = e.toString();
    } finally {
      if (mounted) {
        loading = false;
        setState(() {});
      }
    }
  }

  Widget buildStatusBlock() {
    return BackendStatusBanner(
      loading: loading,
      error: error,
      offline: offline,
      onDismissError: () => setError(null),
    );
  }
}
