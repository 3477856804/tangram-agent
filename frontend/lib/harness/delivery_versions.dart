/// 迭代式渐进交付 —— 交付物版本化底座。
///
/// 每一次交付都以真实文件落盘到 `work/deliverables/<slug>/v<N>.<ext>`，
/// 同目录的 `index.json` 记录全部版本的元数据（状态、SHA-256、父版本、时间）。
/// 状态机只有 `draft → review → final` 两条边，非法跳转一律抛 StateError，
/// 绝不静默改写状态。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'store.dart';

/// 交付物版本状态。
///
/// `final` 是 Dart 保留字，不能作为枚举值，故写作 `final_`；
/// 序列化到 JSON 时仍然是 `"final"`。
enum VersionStatus { draft, review, final_ }

String _statusName(VersionStatus status) => switch (status) {
      VersionStatus.draft => 'draft',
      VersionStatus.review => 'review',
      VersionStatus.final_ => 'final',
    };

VersionStatus _statusFrom(Object? raw) => switch (raw?.toString()) {
      'review' => VersionStatus.review,
      'final' => VersionStatus.final_,
      _ => VersionStatus.draft,
    };

int _asInt(Object? raw) {
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

/// 单个交付物版本的元数据。
class DeliverableVersion {
  DeliverableVersion({
    required this.id,
    required this.name,
    required this.version,
    required this.status,
    required this.filePath,
    required this.sha256,
    required this.note,
    required this.createdAt,
    this.parentVersion,
  });

  /// 唯一标识，形如 `<slug>-v<N>`。
  final String id;

  /// 交付物原名（未 slug 化）。
  final String name;

  /// 从 1 开始递增的版本号。
  final int version;

  final VersionStatus status;

  /// 真实文件相对 store 根目录的路径。
  final String filePath;

  /// 文件内容的 SHA-256（小写 hex）。
  final String sha256;

  final String note;

  final DateTime createdAt;

  /// 修订来源版本；初版为 null。
  final int? parentVersion;

  DeliverableVersion copyWith({VersionStatus? status}) => DeliverableVersion(
        id: id,
        name: name,
        version: version,
        status: status ?? this.status,
        filePath: filePath,
        sha256: sha256,
        note: note,
        createdAt: createdAt,
        parentVersion: parentVersion,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'version': version,
        'status': _statusName(status),
        'file_path': filePath,
        'sha256': sha256,
        'note': note,
        'created_at': createdAt.toIso8601String(),
        'parent_version': parentVersion,
      };

  static DeliverableVersion fromJson(Map<String, dynamic> json) {
    return DeliverableVersion(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      version: _asInt(json['version']),
      status: _statusFrom(json['status']),
      filePath: (json['file_path'] ?? '').toString(),
      sha256: (json['sha256'] ?? '').toString(),
      note: (json['note'] ?? '').toString(),
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0),
      parentVersion:
          json['parent_version'] == null ? null : _asInt(json['parent_version']),
    );
  }
}

/// 交付物版本仓库。所有数据都经 [HarnessStore] 真实落盘。
class DeliveryVersions {
  DeliveryVersions(this.store);

  final HarnessStore store;

  static final RegExp _allowed = RegExp(r'[\u4e00-\u9fa5A-Za-z0-9]');

  /// 把交付物名称转成安全的目录名：保留中文/字母/数字，其他字符替换为 `-`。
  ///
  /// 由于 `/`、`\`、`.` 都会被替换，结果不可能包含目录分隔符或 `..`；
  /// 空名称回退为 `untitled`。
  static String slug(String name) {
    final StringBuffer out = StringBuffer();
    for (final int rune in name.runes) {
      final String ch = String.fromCharCode(rune);
      out.write(_allowed.hasMatch(ch) ? ch : '-');
    }
    final String result = out.toString();
    return result.isEmpty ? 'untitled' : result;
  }

  static String _extension(String extension) {
    String ext = extension.trim().toLowerCase();
    while (ext.startsWith('.')) {
      ext = ext.substring(1);
    }
    ext = ext.replaceAll(RegExp('[^a-z0-9]'), '');
    return ext.isEmpty ? 'txt' : ext;
  }

  String _dir(String slug) => 'work/deliverables/$slug';

  String _indexPath(String slug) => '${_dir(slug)}/index.json';

  String _versionPath(String slug, int version, String extension) =>
      '${_dir(slug)}/v$version.$extension';

  Future<List<DeliverableVersion>> _read(String slug) async {
    final Map<String, dynamic> index = await store.readJson(_indexPath(slug));
    final Object? raw = index['versions'];
    if (raw is! List) return <DeliverableVersion>[];
    final List<DeliverableVersion> versions = <DeliverableVersion>[];
    for (final Object? item in raw) {
      if (item is Map) {
        versions.add(
          DeliverableVersion.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }
    versions.sort((DeliverableVersion a, DeliverableVersion b) =>
        a.version.compareTo(b.version));
    return versions;
  }

  Future<void> _write(
    String slug,
    String name,
    List<DeliverableVersion> versions,
  ) async {
    versions.sort((DeliverableVersion a, DeliverableVersion b) =>
        a.version.compareTo(b.version));
    await store.writeJson(_indexPath(slug), <String, dynamic>{
      'name': name,
      'slug': slug,
      'versions':
          versions.map((DeliverableVersion v) => v.toJson()).toList(),
    });
  }

  Future<DeliverableVersion> _createDraft(
    String name,
    List<int> bytes, {
    required String extension,
    required String note,
    required int? parentVersion,
  }) async {
    final String slug = DeliveryVersions.slug(name);
    final List<DeliverableVersion> versions = await _read(slug);
    final int next = versions.isEmpty ? 1 : versions.last.version + 1;
    final String ext = _extension(extension);
    final String relative = _versionPath(slug, next, ext);
    final File target = store.file(relative);

    // 双保险：即使 slug / extension 规则被放宽，也不允许写出交付物目录。
    final String rootPath =
        '${store.file(_dir(slug)).absolute.path}${Platform.pathSeparator}';
    if (!target.absolute.path.startsWith(rootPath)) {
      throw StateError('非法交付物路径：$relative');
    }

    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);

    final DeliverableVersion version = DeliverableVersion(
      id: '$slug-v$next',
      name: name,
      version: next,
      status: VersionStatus.draft,
      filePath: relative,
      sha256: sha256.convert(bytes).toString(),
      note: note,
      createdAt: DateTime.now(),
      parentVersion: parentVersion,
    );
    versions.add(version);
    await _write(slug, name, versions);
    return version;
  }

  /// 保存一版草稿。N 从 1 递增，内容真实写入磁盘并计算 SHA-256。
  Future<DeliverableVersion> saveDraft(
    String name,
    List<int> bytes, {
    String extension = 'txt',
    String note = '',
  }) {
    return _createDraft(
      name,
      bytes,
      extension: extension,
      note: note,
      parentVersion: null,
    );
  }

  /// 按版本号升序列出全部版本；交付物不存在时返回空列表。
  Future<List<DeliverableVersion>> list(String name) {
    return _read(DeliveryVersions.slug(name));
  }

  /// 读取指定版本的真实文件内容；版本不存在时抛 [StateError]。
  Future<String> readText(String name, int version) async {
    final DeliverableVersion found = await _find(name, version);
    final File file = store.file(found.filePath);
    if (!await file.exists()) {
      throw StateError('交付物「$name」版本 $version 的文件缺失：${found.filePath}');
    }
    return utf8.decode(await file.readAsBytes());
  }

  /// draft → review。
  Future<DeliverableVersion> submit(String name, int version) {
    return _transition(
      name,
      version,
      from: VersionStatus.draft,
      to: VersionStatus.review,
    );
  }

  /// review → final；draft 直接 final 会被拒绝。
  Future<DeliverableVersion> finalize(String name, int version) {
    return _transition(
      name,
      version,
      from: VersionStatus.review,
      to: VersionStatus.final_,
    );
  }

  /// 基于 [fromVersion] 生成新的 draft，并记录 parentVersion。
  Future<DeliverableVersion> revise(
    String name,
    int fromVersion,
    List<int> bytes, {
    String extension = 'txt',
    String note = '',
  }) async {
    await _find(name, fromVersion);
    return _createDraft(
      name,
      bytes,
      extension: extension,
      note: note,
      parentVersion: fromVersion,
    );
  }

  Future<DeliverableVersion> _find(String name, int version) async {
    final List<DeliverableVersion> versions = await list(name);
    for (final DeliverableVersion v in versions) {
      if (v.version == version) return v;
    }
    throw StateError('交付物「$name」不存在版本 $version');
  }

  Future<DeliverableVersion> _transition(
    String name,
    int version, {
    required VersionStatus from,
    required VersionStatus to,
  }) async {
    final String slug = DeliveryVersions.slug(name);
    final List<DeliverableVersion> versions = await _read(slug);
    int index = -1;
    for (int i = 0; i < versions.length; i++) {
      if (versions[i].version == version) {
        index = i;
        break;
      }
    }
    if (index == -1) {
      throw StateError('交付物「$name」不存在版本 $version');
    }
    final VersionStatus current = versions[index].status;
    if (current != from) {
      throw StateError(
        '非法状态转换：${_statusName(current)} → ${_statusName(to)}'
        '（交付物「$name」版本 $version）',
      );
    }
    final DeliverableVersion updated = versions[index].copyWith(status: to);
    versions[index] = updated;
    await _write(slug, name, versions);
    return updated;
  }
}
