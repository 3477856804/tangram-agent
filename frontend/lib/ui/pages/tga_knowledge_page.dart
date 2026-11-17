import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../bridge/backend_client.dart';
import '../../design/tga_design.dart';

/// 私有知识库（多库隔离 RAG）。
///
/// 真实数据源：内嵌后端 `knowledge_base` 控制域。文档、片段、快照全部落在
/// App 私有目录；检索为本地 BM25，命中结果带分数与出处；未支持的二进制格式
/// 如实提示先在沙箱解析，不伪造已入库。
class TgaKnowledgePage extends StatefulWidget {
  const TgaKnowledgePage({super.key});

  @override
  State<TgaKnowledgePage> createState() => _TgaKnowledgePageState();
}

class _TgaKnowledgePageState extends State<TgaKnowledgePage> {
  final TextEditingController _search = TextEditingController();
  List<Map<String, dynamic>> _libraries = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _documents = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _results = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _snapshots = <Map<String, dynamic>>[];
  Map<String, dynamic> _vector = <String, dynamic>{};
  String? _selectedId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
      String action, [Map<String, dynamic> payload = const <String, dynamic>{}]) async {
    final BackendClient backend = context.read<BackendClient>();
    final envelope =
        await backend.sendControl('knowledge_base', <String, dynamic>{
      'action': action,
      ...payload,
    });
    final dynamic raw = envelope.payload;
    return raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
        : <String, dynamic>{'ok': false, 'error': '后端返回格式异常'};
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> r = await _call('list');
      final Map<String, dynamic> v = await _call('vector_stats');
      if (!mounted) return;
      final List<dynamic> libs =
          r['libraries'] is List ? r['libraries'] as List : <dynamic>[];
      setState(() {
        _libraries = libs
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _vector = v;
        _loading = false;
        if (_selectedId != null &&
            !_libraries.any((Map<String, dynamic> l) => l['id'] == _selectedId)) {
          _selectedId = null;
        }
      });
      if (_selectedId != null) await _loadDocs(_selectedId!);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('知识库读取失败：$e');
    }
  }

  Future<void> _loadDocs(String libraryId) async {
    try {
      final Map<String, dynamic> r =
          await _call('docs', <String, dynamic>{'library_id': libraryId});
      final Map<String, dynamic> s =
          await _call('snapshots', <String, dynamic>{'library_id': libraryId});
      if (!mounted) return;
      setState(() {
        _selectedId = libraryId;
        _documents = (r['documents'] is List ? r['documents'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
        _snapshots = (s['snapshots'] is List ? s['snapshots'] as List : <dynamic>[])
            .whereType<Map>()
            .map((Map e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } on Object catch (e) {
      _toast('读取文档失败：$e');
    }
  }

  Future<void> _createLibrary() async {
    final TextEditingController name = TextEditingController();
    final TextEditingController desc = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('新建知识库', style: Tga.h2),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: name,
              autofocus: true,
              style: TextStyle(color: Tga.text),
              decoration: const InputDecoration(hintText: '名称，例如：产品手册'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: desc,
              style: TextStyle(color: Tga.text),
              decoration: const InputDecoration(hintText: '用途说明（可选）'),
            ),
            const SizedBox(height: 8),
            Text('每个库独立存储、独立检索；可绑定人格或为不同项目隔离。',
                style: Tga.caption),
          ],
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('创建')),
        ],
      ),
    );
    if (ok != true) {
      name.dispose();
      desc.dispose();
      return;
    }
    final Map<String, dynamic> r = await _call('create', <String, dynamic>{
      'name': name.text.trim(),
      'description': desc.text.trim(),
    });
    name.dispose();
    desc.dispose();
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '创建失败').toString());
      return;
    }
    await _load();
  }

  Future<void> _toggle(Map<String, dynamic> lib, bool value) async {
    final Map<String, dynamic> r = await _call('update', <String, dynamic>{
      'id': lib['id'],
      'enabled': value,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '更新失败').toString());
      return;
    }
    await _load();
  }

  Future<void> _deleteLibrary(Map<String, dynamic> lib) async {
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('删除知识库「${lib['name']}」？', style: Tga.h2),
            content: Text('将删除该库的全部文档与检索片段；已做过的快照文件保留在本地。',
                style: Tga.body),
            actions: <Widget>[
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text('取消', style: TextStyle(color: Tga.textSub))),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text('删除', style: TextStyle(color: Tga.red))),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    final Map<String, dynamic> r =
        await _call('delete', <String, dynamic>{'id': lib['id']});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '删除失败').toString());
      return;
    }
    if (_selectedId == lib['id']) {
      _selectedId = null;
      _documents = <Map<String, dynamic>>[];
      _snapshots = <Map<String, dynamic>>[];
      _results = <Map<String, dynamic>>[];
    }
    await _load();
  }

  Future<void> _ingestFiles() async {
    final String? libraryId = _selectedId;
    if (libraryId == null) return;
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
    );
    if (picked == null) return;
    int ok = 0;
    final List<String> errors = <String>[];
    for (final PlatformFile f in picked.files) {
      final String? path = f.path;
      if (path == null) {
        errors.add('${f.name}：无法读取路径');
        continue;
      }
      final Map<String, dynamic> r = await _call('ingest_file', <String, dynamic>{
        'library_id': libraryId,
        'path': path,
        'name': f.name,
      });
      if (r['ok'] == true) {
        ok += 1;
      } else {
        errors.add('${f.name}：${r['error'] ?? '入库失败'}');
      }
    }
    if (!mounted) return;
    await _loadDocs(libraryId);
    _toast(errors.isEmpty
        ? '已入库 $ok 个文件'
        : '入库 $ok 个；${errors.length} 个失败：${errors.first}');
  }

  Future<void> _ingestText() async {
    final String? libraryId = _selectedId;
    if (libraryId == null) return;
    final TextEditingController name = TextEditingController();
    final TextEditingController text = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('粘贴文本入库', style: Tga.h2),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: name,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(hintText: '文档标题'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: text,
                minLines: 6,
                maxLines: 12,
                style: TextStyle(color: Tga.text),
                decoration: const InputDecoration(
                    hintText: '粘贴 Markdown / 纯文本 / 代码片段…'),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('入库')),
        ],
      ),
    );
    if (ok != true) {
      name.dispose();
      text.dispose();
      return;
    }
    final Map<String, dynamic> r = await _call('ingest_text', <String, dynamic>{
      'library_id': libraryId,
      'name': name.text.trim().isEmpty ? '粘贴文本' : name.text.trim(),
      'text': text.text,
    });
    name.dispose();
    text.dispose();
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '入库失败').toString());
      return;
    }
    await _loadDocs(libraryId);
    _toast(r['duplicate'] == true ? '内容相同，已跳过' : '已入库');
  }

  Future<void> _ingestUrl() async {
    final String? libraryId = _selectedId;
    if (libraryId == null) return;
    final TextEditingController url = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: Tga.card,
        title: Text('抓取网页入库', style: Tga.h2),
        content: TextField(
          controller: url,
          autofocus: true,
          style: TextStyle(color: Tga.text),
          decoration: const InputDecoration(hintText: 'https://example.com/article'),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: Tga.textSub))),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true), child: const Text('抓取')),
        ],
      ),
    );
    if (ok != true) {
      url.dispose();
      return;
    }
    final String target = url.text.trim();
    url.dispose();
    _toast('正在抓取…');
    final Map<String, dynamic> r = await _call('ingest_url', <String, dynamic>{
      'library_id': libraryId,
      'url': target,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '抓取失败').toString());
      return;
    }
    await _loadDocs(libraryId);
    _toast('网页正文已入库');
  }

  Future<void> _snapshot() async {
    final String? libraryId = _selectedId;
    if (libraryId == null) return;
    final Map<String, dynamic> r = await _call('snapshot', <String, dynamic>{
      'library_id': libraryId,
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '快照失败').toString());
      return;
    }
    await _loadDocs(libraryId);
    _toast('快照已保存');
  }

  Future<void> _restore(Map<String, dynamic> snap) async {
    final String? libraryId = _selectedId;
    if (libraryId == null) return;
    final bool ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            backgroundColor: Tga.card,
            title: Text('恢复快照？', style: Tga.h2),
            content: Text(
                '将把当前库的文档与片段替换为 ${snap['created_at']} 的版本'
                '（${snap['documents']} 篇 / ${snap['chunks']} 片段）。',
                style: Tga.body),
            actions: <Widget>[
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text('取消', style: TextStyle(color: Tga.textSub))),
              FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('恢复')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    final Map<String, dynamic> r = await _call('restore', <String, dynamic>{
      'library_id': libraryId,
      'snapshot_id': snap['id'],
    });
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '恢复失败').toString());
      return;
    }
    await _loadDocs(libraryId);
    _toast('已恢复到快照版本');
  }

  Future<void> _deleteDoc(Map<String, dynamic> doc) async {
    final Map<String, dynamic> r =
        await _call('delete_doc', <String, dynamic>{'document_id': doc['id']});
    if (!mounted) return;
    if (r['ok'] != true) {
      _toast((r['error'] ?? '删除失败').toString());
      return;
    }
    if (_selectedId != null) await _loadDocs(_selectedId!);
  }

  Future<void> _searchRun() async {
    final String q = _search.text.trim();
    if (q.isEmpty) return;
    final Map<String, dynamic> r = await _call('search', <String, dynamic>{
      'query': q,
      'top_k': 8,
      if (_selectedId != null)
        'library_ids': <String>[_selectedId!],
    });
    if (!mounted) return;
    final List<dynamic> list =
        r['results'] is List ? r['results'] as List : <dynamic>[];
    setState(() {
      _results = list
          .whereType<Map>()
          .map((Map e) => Map<String, dynamic>.from(e))
          .toList();
    });
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic>? selected = _selectedId == null
        ? null
        : _libraries.cast<Map<String, dynamic>?>().firstWhere(
            (Map<String, dynamic>? l) => l?['id'] == _selectedId,
            orElse: () => null);
    return TgaPage(
      title: '私有知识库',
      actions: <Widget>[
        IconButton(
          onPressed: _loading ? null : _createLibrary,
          tooltip: '新建知识库',
          icon: Icon(Icons.add_rounded, color: Tga.primary),
        ),
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: '刷新',
          icon: Icon(Icons.refresh_rounded, color: Tga.primary),
        ),
      ],
      child: _loading
          ? Center(
              child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Tga.primary)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
              children: <Widget>[
                TgaCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      TextField(
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _searchRun(),
                        style: TextStyle(color: Tga.text),
                        decoration: InputDecoration(
                          hintText: '检索知识库（本地 BM25，返回真实命中与出处）',
                          hintStyle: Tga.sub,
                          border: InputBorder.none,
                          suffixIcon: IconButton(
                            icon: Icon(Icons.search_rounded, color: Tga.primary),
                            onPressed: _searchRun,
                          ),
                        ),
                      ),
                      if (_results.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 6),
                        Text('命中 ${_results.length} 条', style: Tga.caption),
                        for (final Map<String, dynamic> r in _results)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  '「${r['library_name']}」/ ${r['document_name']} '
                                  '#${r['ordinal']} · ${r['score']}',
                                  style: Tga.sub.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(r['snippet'].toString(), style: Tga.body),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                TgaCard(
                  child: Row(
                    children: <Widget>[
                      Icon(Icons.hub_outlined, size: 17, color: Tga.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '向量后端：${_vector['backend'] ?? 'local'} · '
                          '${_vector['count'] ?? 0} 个向量 · '
                          '${_vector['dimensions'] ?? 256} 维'
                          '${_vector['ok'] == true ? '' : '（不可用：${_vector['error'] ?? '未知'}）'}',
                          style: Tga.sub,
                        ),
                      ),
                      TextButton(
                        onPressed: () async {
                          final Map<String, dynamic> r =
                              await _call('rebuild_vectors');
                          if (!mounted) return;
                          _toast(r['ok'] == true
                              ? '向量已重建：${r['upserted'] ?? 0} 个'
                              : (r['error'] ?? '重建失败').toString());
                          await _load();
                        },
                        child: Text('重建索引',
                            style: TextStyle(color: Tga.primary, fontSize: 12)),
                      ),
                    ],
                  ),
                ),
                TgaGroupTitle('知识库（${_libraries.length}）'),
                if (_libraries.isEmpty)
                  TgaCard(
                    child: TgaEmpty(
                      '还没有知识库\n点右上角 + 新建，再导入文档 / 网页 / 粘贴文本',
                      icon: Icons.menu_book_outlined,
                    ),
                  )
                else
                  for (final Map<String, dynamic> lib in _libraries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TgaCard(
                        onTap: () => _loadDocs(lib['id'].toString()),
                        child: Row(
                          children: <Widget>[
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                color: Tga.iconBlueBg,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(Icons.menu_book_rounded,
                                  size: 19, color: Tga.iconBlue),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(lib['name'].toString(), style: Tga.h2),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${lib['doc_count'] ?? 0} 篇文档 · '
                                    '${lib['chunk_count'] ?? 0} 片段'
                                    '${(lib['description'] ?? '').toString().isEmpty ? '' : ' · ${lib['description']}'}',
                                    style: Tga.caption,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: lib['enabled'] != false,
                              onChanged: (bool v) => _toggle(lib, v),
                            ),
                            PopupMenuButton<String>(
                              color: Tga.card,
                              onSelected: (String v) {
                                if (v == 'delete') _deleteLibrary(lib);
                                if (v == 'open') _loadDocs(lib['id'].toString());
                              },
                              itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
                                PopupMenuItem<String>(
                                    value: 'open', child: Text('打开', style: TextStyle(color: Tga.text))),
                                PopupMenuItem<String>(
                                    value: 'delete', child: Text('删除', style: TextStyle(color: Tga.red))),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                if (selected != null) ...<Widget>[
                  TgaGroupTitle(
                    '「${selected['name']}」文档',
                    trailing: TextButton(
                      onPressed: _snapshot,
                      child: Text('保存快照', style: TextStyle(color: Tga.primary, fontSize: 12)),
                    ),
                  ),
                  TgaCard(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        TgaButton(
                            label: '选择文件',
                            icon: Icons.upload_file_rounded,
                            onTap: _ingestFiles),
                        TgaButton(
                            label: '粘贴文本',
                            icon: Icons.content_paste_rounded,
                            filled: false,
                            onTap: _ingestText),
                        TgaButton(
                            label: '抓取网页',
                            icon: Icons.language_rounded,
                            filled: false,
                            onTap: _ingestUrl),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_documents.isEmpty)
                    TgaCard(
                        child: TgaEmpty('这个库还没有文档',
                            icon: Icons.description_outlined))
                  else
                    for (final Map<String, dynamic> d in _documents)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TgaCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.insert_drive_file_outlined,
                                  size: 17, color: Tga.textSub),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(d['name'].toString(), style: Tga.body),
                                    Text(
                                      '${d['chars']} 字符 · ${d['chunks']} 片段'
                                      ' · ${(d['ingested_at'] ?? '').toString().replaceFirst('T', ' ').split('.').first}',
                                      style: Tga.caption,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_outline_rounded,
                                    size: 18, color: Tga.red),
                                onPressed: () => _deleteDoc(d),
                              ),
                            ],
                          ),
                        ),
                      ),
                  if (_snapshots.isNotEmpty) ...<Widget>[
                    TgaGroupTitle('版本快照'),
                    for (final Map<String, dynamic> s in _snapshots.reversed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TgaCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Row(
                            children: <Widget>[
                              Icon(Icons.history_rounded,
                                  size: 17, color: Tga.textSub),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${(s['created_at'] ?? '').toString().replaceFirst('T', ' ').split('.').first}'
                                  ' · ${s['documents']} 篇 / ${s['chunks']} 片段',
                                  style: Tga.sub,
                                ),
                              ),
                              TextButton(
                                onPressed: () => _restore(s),
                                child: Text('恢复',
                                    style: TextStyle(color: Tga.primary, fontSize: 12)),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ],
            ),
    );
  }
}
