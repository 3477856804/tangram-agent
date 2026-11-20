/// 本地快照 / 备份 / 恢复。
///
/// 覆盖：人格之外的 Harness 数据（模型注册表、智能体、Super Agent 工单与
/// 事件流、知识库、工作流、运行记录、日记 / 记忆、规则、插件与沙箱策略），
/// 可选把工作区（sandbox/）一起打包。
///
/// 真实性约束：
///  * 每个快照都是磁盘上的真实目录与文件副本，manifest 记录逐文件字节数与
///    SHA256，恢复前重新校验，绝不把损坏文件当成恢复成功。
///  * 恢复前自动生成一份「恢复前备份」快照，避免误操作不可逆。
///  * 不做假的「加密云同步」：未配置云端时如实返回 `cloud_enabled=false`。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'store.dart';

class SnapshotService {
  SnapshotService(this.store);

  final HarnessStore store;

  static const int _maxTotalBytes = 300 * 1024 * 1024;
  static const int _maxFiles = 8000;

  /// 根目录下允许纳入快照的 JSON 文档（白名单，避免把大模型权重打进去）。
  static const Set<String> _rootJsonWhitelist = <String>{
    'model_registry.json',
    'agents.json',
    'super_config.json',
    'super_tickets.json',
    'super_triggers.json',
    'super_decisions.json',
    'super_events.json',
    'super_sources.json',
    'super_router_context.json',
    'knowledge_base.json',
    'workflows.json',
    'workflow_runs.json',
    'pages.json',
    'turns.json',
    'proactive_rules.json',
    'proactive_tasks.json',
    'sandbox_policy.json',
    'plugin_catalog.json',
    'plugin_config.json',
    'kernel_events.jsonl',
    'mcp_servers.json',
    'persona.json',
    'settings.json',
  };

  static const Set<String> _dirWhitelist = <String>{
    'knowledge_snapshots',
    'cards',
    'work',
    'pages',
  };

  Directory get _snapshotsDir => Directory('${store.root.path}/snapshots');

  String _id() {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'snap-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}-'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    switch (action) {
      case 'list':
        return <String, dynamic>{
          'ok': true,
          'snapshots': await _list(),
          'root': store.root.path,
          'cloud_enabled': false,
          'note': '本地快照真实落盘；加密云端同步尚未配置，不提供假开关。',
        };
      case 'create':
        return await _create(p);
      case 'restore':
        return await _restore(p);
      case 'delete':
        return await _delete(p);
      case 'status':
        return <String, dynamic>{
          'ok': true,
          'snapshots': (await _list()).length,
          'root': store.root.path,
          'cloud_enabled': false,
        };
      default:
        return <String, dynamic>{'ok': false, 'error': '未知快照动作：$action'};
    }
  }

  Future<List<Map<String, dynamic>>> _list() async {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    if (!await _snapshotsDir.exists()) return out;
    await for (final FileSystemEntity e in _snapshotsDir.list()) {
      if (e is! Directory) continue;
      final File manifest = File('${e.path}/manifest.json');
      if (!await manifest.exists()) continue;
      try {
        final dynamic decoded = jsonDecode(await manifest.readAsString());
        if (decoded is Map) {
          out.add(decoded.map(
              (dynamic k, dynamic v) => MapEntry(k.toString(), v)));
        }
      } on Object {
        // 损坏的 manifest 不冒充可用快照。
      }
    }
    out.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
        (b['created_at'] ?? '').toString().compareTo(
            (a['created_at'] ?? '').toString()));
    return out;
  }

  Future<Map<String, dynamic>> _create(Map<String, dynamic> p) async {
    final String label = (p['label'] ?? '').toString().trim();
    final bool includeWorkspace = p['include_workspace'] == true;
    final String id = _id();
    final Directory dir = Directory('${_snapshotsDir.path}/$id');
    await dir.create(recursive: true);
    final List<Map<String, dynamic>> files = <Map<String, dynamic>>[];
    int total = 0;
    bool tooLarge = false;

    Future<void> addFile(File f, String relative) async {
      if (tooLarge || files.length >= _maxFiles) return;
      final int size = await f.length();
      if (total + size > _maxTotalBytes) {
        tooLarge = true;
        return;
      }
      final List<int> bytes = await f.readAsBytes();
      final String digest = sha256.convert(bytes).toString();
      final File dst = File('${dir.path}/files/$relative');
      await dst.parent.create(recursive: true);
      await dst.writeAsBytes(bytes, flush: true);
      files.add(<String, dynamic>{
        'path': relative,
        'size': size,
        'sha256': digest,
      });
      total += size;
    }

    for (final String name in _rootJsonWhitelist) {
      final File f = File('${store.root.path}/$name');
      if (await f.exists()) await addFile(f, name);
    }
    for (final String d in _dirWhitelist) {
      final Directory source = Directory('${store.root.path}/$d');
      if (!await source.exists()) continue;
      await for (final FileSystemEntity e in source.list(recursive: true)) {
        if (e is File) {
          await addFile(e, '$d/${e.path.substring(source.path.length + 1)}');
        }
        if (tooLarge || files.length >= _maxFiles) break;
      }
      if (tooLarge || files.length >= _maxFiles) break;
    }
    if (includeWorkspace) {
      final Directory sandboxDir = Directory('${store.root.path}/sandbox');
      if (await sandboxDir.exists()) {
        await for (final FileSystemEntity e
            in sandboxDir.list(recursive: true, followLinks: false)) {
          if (e is File) {
            await addFile(
                e, 'sandbox/${e.path.substring(sandboxDir.path.length + 1)}');
          }
          if (tooLarge || files.length >= _maxFiles) break;
        }
      }
    }

    final Map<String, dynamic> manifest = <String, dynamic>{
      'id': id,
      'label': label.isEmpty ? '手动快照' : label,
      'created_at': DateTime.now().toIso8601String(),
      'include_workspace': includeWorkspace,
      'file_count': files.length,
      'total_bytes': total,
      'files': files,
      'truncated': tooLarge || files.length >= _maxFiles,
      'cloud': false,
    };
    await File('${dir.path}/manifest.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    if (files.isEmpty) {
      await dir.delete(recursive: true);
      return <String, dynamic>{
        'ok': false,
        'error': '没有可备份的数据文件（harness 数据目录为空）',
      };
    }
    return <String, dynamic>{
      'ok': true,
      'snapshot': manifest,
      if (manifest['truncated'] == true)
        'warning': '数据量超过上限，快照已截断；可在 manifest 中查看已备份文件。',
    };
  }

  Future<Map<String, dynamic>> _restore(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final Directory dir = Directory('${_snapshotsDir.path}/$id');
    final File manifestFile = File('${dir.path}/manifest.json');
    if (!await manifestFile.exists()) {
      return <String, dynamic>{'ok': false, 'error': '快照不存在：$id'};
    }
    final Map<String, dynamic> manifest =
        Map<String, dynamic>.from(jsonDecode(await manifestFile.readAsString()) as Map);
    final List<dynamic> files = manifest['files'] is List
        ? manifest['files'] as List
        : <dynamic>[];

    // 恢复前自动备份当前状态，失败可回滚；备份失败则中止恢复。
    final Map<String, dynamic> before = await _create(<String, dynamic>{
      'label': '恢复前自动备份（$id）',
      'include_workspace': manifest['include_workspace'] == true,
    });
    if (before['ok'] != true) {
      return <String, dynamic>{
        'ok': false,
        'error': '恢复前备份失败，已中止：${before['error']}',
      };
    }

    int restored = 0;
    final List<String> errors = <String>[];
    for (final dynamic raw in files) {
      if (raw is! Map) continue;
      final String relative = (raw['path'] ?? '').toString();
      if (relative.isEmpty || relative.contains('..')) continue;
      final File src = File('${dir.path}/files/$relative');
      if (!await src.exists()) {
        errors.add('$relative：快照文件缺失');
        continue;
      }
      final List<int> bytes = await src.readAsBytes();
      final String digest = sha256.convert(bytes).toString();
      if (digest != raw['sha256']) {
        errors.add('$relative：SHA256 校验失败，拒绝覆盖');
        continue;
      }
      final File dst = File('${store.root.path}/$relative');
      await dst.parent.create(recursive: true);
      await dst.writeAsBytes(bytes, flush: true);
      restored += 1;
    }
    return <String, dynamic>{
      'ok': errors.isEmpty,
      'restored': restored,
      'errors': errors,
      'backup_snapshot': before['snapshot'] is Map
          ? (before['snapshot'] as Map)['id']
          : null,
      'restart_hint': '恢复完成；界面可重新进入页面读取最新数据。',
    };
  }

  Future<Map<String, dynamic>> _delete(Map<String, dynamic> p) async {
    final String id = (p['id'] ?? '').toString();
    final Directory dir = Directory('${_snapshotsDir.path}/$id');
    if (!await dir.exists()) {
      return <String, dynamic>{'ok': false, 'error': '快照不存在：$id'};
    }
    await dir.delete(recursive: true);
    return <String, dynamic>{'ok': true, 'deleted': id};
  }
}
