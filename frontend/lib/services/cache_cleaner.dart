/// 真实缓存清理（问题 #9）：统计并删除可再生临时数据，返回释放字节数。
///
/// 清理范围（全部真实存在、可再生，不碰用户数据）：
///  - 系统临时目录 getTemporaryDirectory（图片选择/网络缓存等）；
///  - OTA 目录里旧版本 APK 与下载分片残留（*.part*）；
///  - harness 模型/插件目录里的下载分片与 sidecar 临时文件（.part/.tmp/.download）；
///  - 沙箱 tmp 目录。
/// 保留：日记/知识图谱/API 配置/已完成的模型权重/已安装插件——这些不是缓存。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

class CacheCleanResult {
  const CacheCleanResult(this.freedBytes, this.fileCount);
  final int freedBytes;
  final int fileCount;
  String get freedText {
    if (freedBytes < 1024) return '$freedBytes B';
    if (freedBytes < 1024 * 1024) {
      return '${(freedBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(freedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class CacheCleaner {
  CacheCleaner._();

  static bool _isTempName(String name) {
    final String l = name.toLowerCase();
    return l.contains('.part') ||
        l.endsWith('.tmp') ||
        l.endsWith('.download') ||
        l.endsWith('.crdownload');
  }

  static Future<CacheCleanResult> clean() async {
    int freed = 0;
    int count = 0;
    final List<Directory> roots = <Directory>[];

    try {
      roots.add(await getTemporaryDirectory());
    } on Object {
      // 平台不支持则跳过。
    }
    final Directory? ext = await getExternalStorageDirectory();
    final Directory docs = await getApplicationDocumentsDirectory();
    for (final Directory? base in <Directory?>[ext, docs]) {
      if (base == null) continue;
      roots.add(Directory('${base.path}/ota'));
      roots.add(Directory('${base.path}/tangram_harness'));
      roots.add(Directory('${base.path}/tmp'));
    }

    for (final Directory root in roots) {
      if (!await root.exists()) continue;
      try {
        if (root.path.endsWith('tangram_harness')) {
          // harness 目录只删临时分片，不动正式数据。
          await for (final FileSystemEntity e
              in root.list(recursive: true, followLinks: false)) {
            if (e is File && _isTempName(e.uri.pathSegments.last)) {
              final int len = await e.length();
              await e.delete();
              freed += len;
              count++;
            }
          }
        } else if (root.path.endsWith('ota')) {
          final List<File> apks = <File>[];
          await for (final FileSystemEntity e in root.list()) {
            if (e is! File) continue;
            final String name = e.uri.pathSegments.last.toLowerCase();
            if (_isTempName(name)) {
              final int len = await e.length();
              await e.delete();
              freed += len;
              count++;
            } else if (name.endsWith('.apk')) {
              apks.add(e);
            }
          }
          // 只保留最新一个待安装 APK，旧版本安装包属于缓存。
          apks.sort((File a, File b) =>
              b.statSync().modified.compareTo(a.statSync().modified));
          for (final File old in apks.skip(1)) {
            try {
              final int len = await old.length();
              await old.delete();
              freed += len;
              count++;
            } on Object {
              // 占用中则跳过。
            }
          }
        } else {
          // 临时目录整体可清空（系统保证可再生）。
          await for (final FileSystemEntity e
              in root.list(recursive: true, followLinks: false)) {
            try {
              if (e is File) {
                final int len = await e.length();
                await e.delete();
                freed += len;
                count++;
              } else if (e is Directory) {
                await e.delete(recursive: true);
              }
            } on Object {
              // 被占用的文件跳过，如实不计入。
            }
          }
        }
      } on Object {
        // 单个根目录失败不影响其余。
      }
    }
    return CacheCleanResult(freed, count);
  }
}
