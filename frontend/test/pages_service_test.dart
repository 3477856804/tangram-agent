/// Pages 版本化服务：真实 HTML 落盘、版本追加、置顶排序与边界校验。

import 'dart:io';

import 'package:test/test.dart';
import 'package:tangram/harness/pages_repository.dart';

void main() {
  late Directory tmp;
  late PagesRepository pages;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_pages_');
    pages = PagesRepository(tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('创建页面：真实写 v1 文件与 pages.json', () async {
    final Map<String, dynamic> r = await pages.create(
      title: '增长看板',
      html: '<h1>增长</h1>',
      botId: 'bot-1',
    );
    expect(r['ok'], isTrue);
    final String id = '${r['page']['id']}';
    expect(File('${tmp.path}/pages/$id/v1.html').existsSync(), isTrue);
    expect(
      await File('${tmp.path}/pages/$id/v1.html').readAsString(),
      '<h1>增长</h1>',
    );
    final File index = File('${tmp.path}/pages.json');
    expect(index.existsSync(), isTrue);
    expect(index.readAsStringSync(), contains('增长看板'));

    final Map<String, dynamic> detail = await pages.get(id);
    expect(detail['ok'], isTrue);
    expect(detail['html'], '<h1>增长</h1>');
    expect(detail['versions'], <int>[1]);
  });

  test('保存追加版本，旧版本仍可读', () async {
    final String id =
        '${(await pages.create(title: '周报', html: 'v1'))['page']['id']}';
    final Map<String, dynamic> saved = await pages.save(id, 'v2');
    expect(saved['ok'], isTrue);
    expect(saved['page']['current_version'], 2);

    expect((await pages.get(id))['html'], 'v2');
    expect((await pages.get(id, version: 1))['html'], 'v1');
    expect((await pages.get(id))['versions'], <int>[2, 1]);
    expect(await pages.readVersion(id, 1), 'v1');
  });

  test('置顶优先，其余按更新时间倒序', () async {
    final String a =
        '${(await pages.create(title: 'A', html: 'a'))['page']['id']}';
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final String b =
        '${(await pages.create(title: 'B', html: 'b'))['page']['id']}';
    await pages.updateMeta(a, pinned: true);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await pages.updateMeta(b, pinned: false);

    final List<dynamic> listed = (await pages.list())['pages'] as List<dynamic>;
    expect(listed.first['id'], a);
    expect(listed[1]['id'], b);
  });

  test('标题搜索与可见性更新', () async {
    final String id =
        '${(await pages.create(title: '销售日报', html: 'x'))['page']['id']}';
    await pages.create(title: '库存周报', html: 'y');
    final Map<String, dynamic> hit = await pages.list(query: '销售');
    expect((hit['pages'] as List<dynamic>).length, 1);
    expect(hit['pages'][0]['title'], '销售日报');

    final Map<String, dynamic> meta = await pages.updateMeta(
      id,
      visibility: PageVisibility.link,
      title: '销售日报 2',
    );
    expect(meta['page']['visibility'], 'link');
    expect(meta['page']['title'], '销售日报 2');
  });

  test('删除页面同时移除版本目录', () async {
    final String id =
        '${(await pages.create(title: '临时', html: 'x'))['page']['id']}';
    expect((await pages.delete(id))['ok'], isTrue);
    expect(Directory('${tmp.path}/pages/$id').existsSync(), isFalse);
    expect((await pages.get(id))['ok'], isFalse);
    expect((await pages.delete(id))['ok'], isFalse);
  });

  test('空标题、空内容、超大内容被拒绝', () async {
    expect((await pages.create(title: '  ', html: 'x'))['ok'], isFalse);
    expect((await pages.create(title: 'x', html: ''))['ok'], isFalse);
    final String huge = 'x' * (PagesRepository.maxHtmlBytes + 1);
    expect((await pages.create(title: 'x', html: huge))['ok'], isFalse);
  });

  test('导出真实 HTML 副本', () async {
    final String id =
        '${(await pages.create(title: '分享页', html: '<p>hi</p>'))['page']['id']}';
    final Map<String, dynamic> r = await pages.export(id);
    expect(r['ok'], isTrue);
    final File f = File('${r['path']}');
    expect(f.existsSync(), isTrue);
    expect(await f.readAsString(), '<p>hi</p>');
    expect(r['filename'], '分享页.html');
  });

  test('并发保存不会丢版本', () async {
    final String id =
        '${(await pages.create(title: '并发', html: 'v1'))['page']['id']}';
    await Future.wait(<Future<Map<String, dynamic>>>[
      pages.save(id, 'v2'),
      pages.save(id, 'v3'),
      pages.save(id, 'v4'),
    ]);
    expect((await pages.get(id))['page']['current_version'], 4);
    expect((await pages.get(id))['versions'], <int>[4, 3, 2, 1]);
  });
}
