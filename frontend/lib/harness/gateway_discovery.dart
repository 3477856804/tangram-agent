import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 局域网网关自动发现（与 Python 网关 `im/discovery.py` 协议对齐）。
///
/// APP 广播 `TANGRAM_DISCOVER` 到 UDP 50433，网关单播回
/// `TANGRAM_GW|<version>|<http_port>`；取第一个合法响应拼成
/// `http://<网关IP>:<port>`。全程只发现地址，二维码仍由网关真下发。
///
/// 失败（无网关 / 平台禁广播 / 不同网段）返回 null，由调用方降级到
/// 高级设置手填，绝不编造地址或谎称已连接。
class GatewayDiscovery {
  static const int discoveryPort = 50433;
  static const String _magic = 'TANGRAM_DISCOVER';
  static const String _respPrefix = 'TANGRAM_GW|';

  /// 探测局域网内的网关地址。
  ///
  /// [timeout] 总超时；[localPort] 为 0 时由系统分配临时端口。
  static Future<String?> discover({
    Duration timeout = const Duration(seconds: 3),
    List<String> broadcastHosts = const <String>['255.255.255.255', '192.168.1.255'],
  }) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final List<InternetAddress> targets = <InternetAddress>[];
      for (final host in broadcastHosts) {
        try {
          targets.add(InternetAddress(host));
        } on Object {
          // 跳过无法解析的广播地址
        }
      }
      final Completer<String?> done = Completer<String?>();
      Timer? timer;
      StreamSubscription<RawSocketEvent>? sub;

      void finish(String? url) {
        timer?.cancel();
        sub?.cancel();
        if (!done.isCompleted) done.complete(url);
      }

      sub = socket.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final Datagram? dg = socket!.receive();
        if (dg == null) return;
        final String text = utf8.decode(dg.data, allowMalformed: true).trim();
        if (!text.startsWith(_respPrefix)) return;
        final List<String> parts = text.substring(_respPrefix.length).split('|');
        if (parts.length < 2) return;
        final int? port = int.tryParse(parts[1]);
        if (port == null || port <= 0 || port > 65535) return;
        finish('http://${dg.address.address}:$port');
      });

      final List<int> payload = utf8.encode(_magic);
      for (final target in targets) {
        try {
          socket.send(payload, target, discoveryPort);
        } on SocketException {
          // 部分网络禁广播：继续尝试下一个目标
        }
      }
      // 双保险：向回环也发一次（网关与 APP 同设备 / 桌面调试时可用）
      try {
        socket.send(payload, InternetAddress.loopbackIPv4, discoveryPort);
      } on SocketException {
        // 忽略
      }

      timer = Timer(timeout, () => finish(null));
      return await done.future;
    } on SocketException {
      return null;
    } on Object {
      return null;
    } finally {
      socket?.close();
    }
  }
}
