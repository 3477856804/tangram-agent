/// Team Computer + HTTP 浏览器测试。
///
/// 覆盖三层：
///   * `html_snapshot`：标题/正文/链接 ref/表单字段/实体解码/相对地址解析；
///   * `browser_session`：真实请求、Cookie 持久化、click / fill / submit / 历史；
///   * `TeamComputerService`：工作区文件、越界拒绝、检查点与恢复、活动日志。
///
/// 网络层用 `package:http/testing.dart` 的 MockClient，不访问真实站点。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tangram/harness/browser_session.dart';
import 'package:tangram/harness/embedded_backend.dart';
import 'package:tangram/harness/html_snapshot.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/team_computer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HTML 快照解析', () {
    test('标题、正文、链接与相对地址', () {
      final HtmlSnapshot snap = parseHtmlSnapshot(
        url: 'https://example.com/docs/index.html',
        html: '''
<!doctype html>
<html><head><title>示例 &amp; 文档</title>
<style>.x{color:red}</style><script>var a = "<a href='/evil'>x</a>";</script>
</head><body>
<h1>欢迎</h1><p>第一段&nbsp;文字</p>
<a href="../next.html">下一页</a>
<a href="javascript:void(0)">脚本</a>
<a href="#top">锚点</a>
</body></html>
''',
      );
      expect(snap.title, '示例 & 文档');
      expect(snap.text, contains('欢迎'));
      expect(snap.text, contains('第一段 文字'));
      expect(snap.text, isNot(contains('var a')));
      expect(snap.links.length, 1);
      expect(snap.links.first.ref, 'L1');
      expect(snap.links.first.text, '下一页');
      expect(snap.links.first.href, 'https://example.com/next.html');
      expect(snap.render(), contains('[L1] 下一页'));
    });

    test('表单字段、hidden 与密码值', () {
      final HtmlSnapshot snap = parseHtmlSnapshot(
        url: 'https://example.com/login',
        html: '''
<html><body>
<form action="/session" method="post">
  <input type="hidden" name="csrf" value="t1">
  <input name="user" placeholder="账号" value="ada">
  <input type="password" name="pass" value="secret">
  <select name="lang"><option value="zh" selected>中文</option></select>
  <button type="submit" name="go" value="1">登录</button>
</form>
</body></html>
''',
      );
      expect(snap.forms.length, 1);
      final HtmlForm form = snap.forms.first;
      expect(form.method, 'POST');
      expect(form.action, '/session');
      expect(form.fields.length, 5);
      expect(form.fields[0].hidden, isTrue);
      final HtmlField pass =
          form.fields.firstWhere((HtmlField f) => f.name == 'pass');
      expect(pass.isPassword, isTrue);
      expect(pass.toJson()['value'], '');
      expect(snap.render(), isNot(contains('secret')));
      expect(snap.form('F1'), isNotNull);
      expect(snap.field('I2')?.name, 'user');
    });
  });

  group('浏览器会话', () {
    late Directory tmp;
    late List<http.Request> requests;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangram_browser_');
      requests = <http.Request>[];
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    MockClient client() => MockClient((http.Request req) async {
          requests.add(req);
          final String path = req.url.path;
          if (path == '/' || path == '/page') {
            return http.Response(
              '''
<html><head><title>首页</title></head><body>
<p>你好</p>
<a href="/next">下一页</a>
<form action="/search" method="post">
  <input name="q" placeholder="搜索">
  <button type="submit">搜索</button>
</form>
</body></html>''',
              200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8',
                'set-cookie': 'sid=abc123; Path=/',
              },
            );
          }
          if (path == '/next') {
            return http.Response(
              '<html><head><title>第二页</title></head><body>内容</body></html>',
              200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8',
              },
            );
          }
          if (path == '/search') {
            return http.Response(
              '<html><head><title>搜索结果</title></head><body>找到</body></html>',
              200,
              headers: <String, String>{
                'content-type': 'text/html; charset=utf-8',
              },
            );
          }
          return http.Response('not found', 404,
              headers: <String, String>{'content-type': 'text/plain'});
        });

    test('打开页面、保存 Cookie 并在后续请求携带', () async {
      final BrowserSession session =
          BrowserSession(profileDir: tmp, client: client());
      final Map<String, dynamic> r =
          await session.navigate('https://example.com/');
      expect(r['ok'], isTrue, reason: '${r['error']}');
      expect(r['status'], 200);
      expect(r['js'], isFalse);
      expect(session.snapshot?.title, '首页');
      expect(requests.first.headers['cookie'], isNull);

      final File cookies = File('${tmp.path}/cookies.json');
      expect(await cookies.exists(), isTrue);
      expect(await cookies.readAsString(), contains('abc123'));

      await session.navigate('https://example.com/next');
      expect(requests.last.headers['cookie'], contains('sid=abc123'));
      session.close();
    });

    test('click 使用快照 ref 解析链接', () async {
      final BrowserSession session =
          BrowserSession(profileDir: tmp, client: client());
      await session.navigate('https://example.com/');
      final Map<String, dynamic> r =
          await session.act(action: 'click', ref: 'L1');
      expect(r['ok'], isTrue, reason: '${r['error']}');
      expect(requests.last.url.path, '/next');
      expect(session.snapshot?.title, '第二页');
      session.close();
    });

    test('fill + submit 发起真实 POST', () async {
      final BrowserSession session =
          BrowserSession(profileDir: tmp, client: client());
      await session.navigate('https://example.com/');
      final Map<String, dynamic> filled = await session.act(
        action: 'fill',
        ref: 'I1',
        value: '模板',
      );
      expect(filled['ok'], isTrue, reason: '${filled['error']}');
      final Map<String, dynamic> r =
          await session.act(action: 'submit', ref: 'F1');
      expect(r['ok'], isTrue, reason: '${r['error']}');
      expect(requests.last.method, 'POST');
      expect(Uri.decodeComponent(requests.last.body), contains('q=模板'));
      expect(session.snapshot?.title, '搜索结果');
      session.close();
    });

    test('后退 / 前进走真实历史', () async {
      final BrowserSession session =
          BrowserSession(profileDir: tmp, client: client());
      await session.navigate('https://example.com/');
      await session.navigate('https://example.com/next');
      expect(session.canBack, isTrue);
      final Map<String, dynamic> back = await session.act(action: 'back');
      expect(back['ok'], isTrue, reason: '${back['error']}');
      expect(session.snapshot?.title, '首页');
      final Map<String, dynamic> forward = await session.act(action: 'forward');
      expect(forward['ok'], isTrue);
      expect(session.snapshot?.title, '第二页');
      session.close();

      // 新实例能从磁盘恢复历史游标。
      final BrowserSession restored =
          BrowserSession(profileDir: tmp, client: client());
      await restored.load();
      expect(restored.currentUrl, 'https://example.com/next');
      restored.close();
    });

    test('非 http/https 地址被拒绝', () async {
      final BrowserSession session =
          BrowserSession(profileDir: tmp, client: client());
      final Map<String, dynamic> r =
          await session.navigate('file:///etc/passwd');
      expect(r['ok'], isFalse);
      expect(requests, isEmpty);
      session.close();
    });
  });

  group('Team Computer 服务', () {
    late Directory tmp;
    late TeamComputerService service;
    late String computerId;
    late String botId;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangram_computer_');
      service = TeamComputerService(tmp);
      final Map<String, dynamic> list =
          await service.handle('list', <String, dynamic>{});
      final Map<dynamic, dynamic> computer =
          (list['computers'] as List).first as Map;
      computerId = '${computer['id']}';
      final Map<String, dynamic> bots = await service.handle(
        'bots',
        <String, dynamic>{'computer_id': computerId},
      );
      botId = '${(bots['bots'] as List).first['id']}';
    });

    tearDown(() async {
      service.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('默认电脑自带智能体，添加共享 / 独立智能体', () async {
      final Map<String, dynamic> list =
          await service.handle('list', <String, dynamic>{});
      final List<dynamic> computers = list['computers'] as List;
      expect(computers.length, 1);
      expect(computers.first['bot_count'], 1);

      final Map<String, dynamic> shared = await service.handle(
        'add_bot',
        <String, dynamic>{'computer_id': computerId, 'name': '分析师'},
      );
      expect(shared['ok'], isTrue, reason: '${shared['error']}');

      final Map<String, dynamic> private = await service.handle(
        'add_bot',
        <String, dynamic>{
          'computer_id': computerId,
          'name': '私人助手',
          'private': true,
        },
      );
      expect(private['ok'], isTrue, reason: '${private['error']}');
      expect(private['computer']['kind'], 'private');

      final Map<String, dynamic> again =
          await service.handle('list', <String, dynamic>{});
      expect((again['computers'] as List).length, 2);
    });

    test('工作区写入 / 读取 / 越界拒绝', () async {
      final Map<String, dynamic> written = await service.handle(
        'write',
        <String, dynamic>{
          'computer_id': computerId,
          'path': 'shared/report.txt',
          'text': '真实内容',
        },
      );
      expect(written['ok'], isTrue, reason: '${written['error']}');
      expect(written['path'], 'shared/report.txt');

      final Map<String, dynamic> read = await service.handle(
        'read',
        <String, dynamic>{
          'computer_id': computerId,
          'path': 'shared/report.txt',
        },
      );
      expect(read['ok'], isTrue);
      expect(read['text'], '真实内容');

      final Map<String, dynamic> escape = await service.handle(
        'read',
        <String, dynamic>{
          'computer_id': computerId,
          'path': '../outside.txt',
        },
      );
      expect(escape['ok'], isFalse);
      expect('${escape['error']}', contains('越界'));

      final Map<String, dynamic> profile = await service.handle(
        'write',
        <String, dynamic>{
          'computer_id': computerId,
          'path': '.browser-profiles/$botId/cookies.json',
          'text': 'x',
        },
      );
      expect(profile['ok'], isFalse);

      final Map<String, dynamic> files = await service.handle(
        'files',
        <String, dynamic>{'computer_id': computerId},
      );
      expect((files['files'] as List).length, 1);
    });

    test('检查点创建、恢复与恢复前备份', () async {
      await service.handle('write', <String, dynamic>{
        'computer_id': computerId,
        'path': 'shared/a.txt',
        'text': 'v1',
      });
      final Map<String, dynamic> created = await service.handle(
        'checkpoint',
        <String, dynamic>{'computer_id': computerId, 'note': '初始'},
      );
      expect(created['ok'], isTrue, reason: '${created['error']}');
      final String rev = '${created['checkpoint']['rev']}';
      expect(created['checkpoint']['entries'], 1);

      await service.handle('write', <String, dynamic>{
        'computer_id': computerId,
        'path': 'shared/a.txt',
        'text': 'v2',
      });
      final Map<String, dynamic> listed = await service.handle(
        'checkpoints',
        <String, dynamic>{'computer_id': computerId},
      );
      expect((listed['checkpoints'] as List).length, 1);

      final Map<String, dynamic> restored = await service.handle(
        'restore',
        <String, dynamic>{'computer_id': computerId, 'rev': rev},
      );
      expect(restored['ok'], isTrue, reason: '${restored['error']}');
      final Map<String, dynamic> read = await service.handle(
        'read',
        <String, dynamic>{
          'computer_id': computerId,
          'path': 'shared/a.txt',
        },
      );
      expect(read['text'], 'v1');

      final Directory backups = Directory(
        '${tmp.path}/computer/checkpoints/$computerId',
      );
      final List<String> names = await backups
          .list()
          .map((FileSystemEntity e) => e.path.split('/').last)
          .toList();
      expect(names.any((String n) => n.startsWith('pre-restore-')), isTrue);
    });

    test('活动日志记录真实动作与失败', () async {
      await service.handle('write', <String, dynamic>{
        'computer_id': computerId,
        'path': 'shared/x.txt',
        'text': 'x',
      });
      await service.handle('read', <String, dynamic>{
        'computer_id': computerId,
        'path': '../nope.txt',
      });
      final Map<String, dynamic> activity = await service.handle(
        'activity',
        <String, dynamic>{'computer_id': computerId},
      );
      final List<dynamic> rows = activity['activity'] as List;
      expect(rows, isNotEmpty);
      expect(rows.any((dynamic r) => r['action'] == 'write_file'), isTrue);
      final File raw = File('${tmp.path}/computer/activity.jsonl');
      expect(await raw.exists(), isTrue);
      final dynamic first = jsonDecode((await raw.readAsLines()).first);
      expect(first['ts'], isNotEmpty);
    });

    test('删除智能体同时清理工作区与 profile', () async {
      final Directory botDir = Directory(
        '${tmp.path}/computer/homes/$computerId/bots/$botId',
      );
      expect(await botDir.exists(), isTrue);
      final Map<String, dynamic> removed = await service.handle(
        'remove_bot',
        <String, dynamic>{'bot_id': botId},
      );
      expect(removed['ok'], isTrue, reason: '${removed['error']}');
      expect(await botDir.exists(), isFalse);
    });
  });

  group('内嵌后端接线', () {
    late Directory tmp;
    late HarnessStore store;
    late EmbeddedBackend backend;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tangram_computer_backend_');
      for (final String sub in <String>[
        'models',
        'cards',
        'plugins',
        'work',
        'downloads',
        'sandbox',
      ]) {
        await Directory('${tmp.path}/$sub').create(recursive: true);
      }
      HarnessStore.overrideForTest(tmp);
      store = await HarnessStore.instance();
      backend = EmbeddedBackend.forTest(store);
    });

    tearDown(() async {
      await backend.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<Map<String, dynamic>> call(
      String topic, [
      Map<String, dynamic> payload = const <String, dynamic>{},
    ]) async {
      final reply = await backend.dispatch(topic, payload);
      return reply.payload;
    }

    test('能力声明包含 computer 与浏览器工具', () async {
      final Map<String, dynamic> caps =
          await call('capability_negotiation');
      expect(caps['ok'], isTrue);
      expect((caps['control_domains'] as List).contains('computer'), isTrue);
      expect(caps['computer'], isNotNull);
      expect(caps['computer']['js'], isFalse);
      final List<dynamic> tools = caps['tools'] as List;
      for (final String name in <String>[
        'computer_list',
        'computer_files',
        'computer_write',
        'browser_open',
        'browser_snapshot',
        'browser_act',
        'computer_checkpoint',
        'computer_restore',
      ]) {
        expect(tools, contains(name), reason: name);
      }
    });

    test('computer 控制域可列出默认电脑并写入工作区', () async {
      final Map<String, dynamic> list =
          await call('computer', <String, dynamic>{'action': 'list'});
      expect(list['ok'], isTrue);
      final Map<dynamic, dynamic> computer =
          (list['computers'] as List).first as Map;
      final String computerId = '${computer['id']}';
      expect(computer['bot_count'], 1);

      final Map<String, dynamic> bots = await call(
        'computer',
        <String, dynamic>{'action': 'bots', 'computer_id': computerId},
      );
      final Map<dynamic, dynamic> bot = (bots['bots'] as List).first as Map;

      final Map<String, dynamic> written = await call(
        'computer',
        <String, dynamic>{
          'action': 'write',
          'computer_id': computerId,
          'bot_id': '${bot['id']}',
          'path': 'notes.md',
          'text': 'hello',
        },
      );
      expect(written['ok'], isTrue, reason: '${written['error']}');

      final Map<String, dynamic> read = await call(
        'computer',
        <String, dynamic>{
          'action': 'read',
          'computer_id': computerId,
          'bot_id': '${bot['id']}',
          'path': 'notes.md',
        },
      );
      expect(read['ok'], isTrue);
      expect(read['text'], 'hello');
    });
  });
}
