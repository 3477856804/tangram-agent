import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// 一条官方公告（发布仓库 announcements.json 的真实内容）。
class TgaMessage {
  TgaMessage({
    required this.id,
    required this.title,
    required this.body,
    required this.time,
  });

  final String id;
  final String title;

  /// 正文，支持换行。
  final String body;
  final String time;

  factory TgaMessage.fromJson(Map<String, dynamic> m) => TgaMessage(
        id: (m['id'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        body: (m['body'] ?? '').toString(),
        time: (m['time'] ?? '').toString(),
      );
}

/// 消息中心数据源：
/// - 公告列表：GET 发布仓库 announcements.json（结构 {updated_at, messages:[...]}）；
/// - 已读记录：App 文档目录 read_messages.json（id 集合，真实落盘）。
class Announcements {
  Announcements._();

  static const String feedUrl =
      'https://raw.githubusercontent.com/3477856804/tangram-agent-releases/main/announcements.json';

  static const Duration _timeout = Duration(seconds: 15);

  /// 拉取公告；网络/解析失败抛异常，由 UI 如实展示重试入口。
  static Future<List<TgaMessage>> fetch() async {
    final http.Client client = http.Client();
    try {
      final http.Response res = await client
          .get(Uri.parse(feedUrl), headers: <String, String>{
        'Accept': 'application/json',
      }).timeout(_timeout);
      if (res.statusCode != 200) {
        throw StateError('HTTP ${res.statusCode}');
      }
      final dynamic raw = jsonDecode(utf8.decode(res.bodyBytes));
      if (raw is! Map) throw StateError('公告格式错误');
      final dynamic list = raw['messages'];
      if (list is! List) return <TgaMessage>[];
      return list
          .whereType<Map>()
          .map((Map<dynamic, dynamic> m) => TgaMessage.fromJson(
              m.map((dynamic k, dynamic v) =>
                  MapEntry<String, dynamic>(k.toString(), v))))
          .toList();
    } finally {
      client.close();
    }
  }

  static Future<File> _readFile() async {
    Directory base;
    try {
      base = await getApplicationDocumentsDirectory();
    } on Object {
      base = Directory.systemTemp;
    }
    return File('${base.path}/read_messages.json');
  }

  /// 已读 id 集合（文件缺失/损坏按全未读处理）。
  static Future<Set<String>> readIds() async {
    try {
      final File f = await _readFile();
      if (!await f.exists()) return <String>{};
      final dynamic raw = jsonDecode(await f.readAsString());
      if (raw is! List) return <String>{};
      return raw.map((dynamic e) => e.toString()).toSet();
    } on Object {
      return <String>{};
    }
  }

  /// 标记一条已读并落盘。
  static Future<void> markRead(String id) async {
    if (id.isEmpty) return;
    try {
      final File f = await _readFile();
      final Set<String> ids = await readIds();
      if (!ids.add(id)) return;
      await f.writeAsString(jsonEncode(ids.toList()), flush: true);
    } on Object {
      // 落盘失败下次进入仍会显示未读，不影响功能可用性。
    }
  }

  /// 未读条数；任何失败返回 0（个人页据此决定红点，宁缺毋假）。
  static Future<int> unreadCount() async {
    try {
      final List<TgaMessage> msgs = await fetch();
      final Set<String> read = await readIds();
      return msgs.where((TgaMessage m) => !read.contains(m.id)).length;
    } on Object {
      return 0;
    }
  }
}
