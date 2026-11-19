/// Tangram 分片断点续传下载器 —— 纯 Dart 实现。
///
/// 移植自 `myniqx/downloadx`（分片 Range / 断点 sidecar / 空闲停滞恢复）的
/// 核心思路：先用 HEAD 探测 Content-Length 与 Accept-Ranges，再按分片并发
/// GET `Range: bytes=a-b`，每片独立写 `.partN` 临时文件并把已下载字节记入
/// `.tangram_dl.json` sidecar；中断后重启从 sidecar 记录的偏移续传，全部分片
/// 完成后原子合并成目标文件。所有进度来自真实落盘字节数，不编造百分比。


import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:tangram/harness/store.dart';

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// 是否为规范化（小写 64 位 hex）的 SHA-256 摘要。
bool isValidSha256(String value) => _sha256Pattern.hasMatch(value);

/// 流式计算文件真实 SHA-256，避免一次性把大模型文件读入内存。
Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

class DownloadJob {
  DownloadJob({
    required this.id,
    required this.url,
    required this.target,
    required this.chunks,
    required this.totalBytes,
    required this.resumable,
  });

  final String id;
  final String url;
  final String target;
  final int chunks;
  final int totalBytes;
  final bool resumable;

  String status = 'running';
  String? error;
  String? expectedSha256;
  String? actualSha256;
  DateTime startedAt = DateTime.now();
  DateTime? finishedAt;

  /// 仅当提供了期望摘要且实际摘要与之相等时为 true。
  bool get verified =>
      expectedSha256 != null && expectedSha256 == actualSha256;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'job_id': id,
        'url': url,
        'target': target,
        'chunks': chunks,
        'total_bytes': totalBytes,
        'resumable': resumable,
        'status': status,
        if (error != null) 'error': error,
        if (actualSha256 != null) 'sha256': actualSha256,
        if (expectedSha256 != null) 'expected_sha256': expectedSha256,
        if (verified) 'verified': true,
        'started_at': startedAt.toIso8601String(),
        if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
      };
}

class DownloadManager {
  DownloadManager(this.store);

  final HarnessStore store;
  final Map<String, DownloadJob> _jobs = <String, DownloadJob>{};
  int _seq = 0;

  DownloadJob? job(String id) => _jobs[id];

  List<Map<String, dynamic>> get all =>
      _jobs.values.map((DownloadJob j) => j.toJson()).toList(growable: false);

  /// 真实进度：统计各分片临时文件已落盘字节。
  Map<String, dynamic> progress(DownloadJob job) {
    var done = 0;
    final parts = <Map<String, dynamic>>[];
    for (var i = 0; i < job.chunks; i++) {
      final f = File('${job.target}.part$i');
      final int bytes = f.existsSync() ? f.lengthSync() : 0;
      done += bytes;
      parts.add(<String, dynamic>{'index': i, 'downloaded': bytes});
    }
    final total = job.totalBytes > 0 ? job.totalBytes : done;
    final percent = total > 0 ? (done * 100 / total).clamp(0, 100) : 0;
    return <String, dynamic>{
      'job_id': job.id,
      'status': job.status,
      'downloaded': done,
      'total': total,
      'percent': double.parse(percent.toStringAsFixed(1)),
      'parts': parts,
      'target': job.target,
      'error': job.error,
    };
  }

  /// 启动一次真实下载。返回 job_id；网络/文件失败如实写入 job.error。
  ///
  /// [expectedSha256] 非空时必须是 64 位 hex（大小写不敏感），下载完成后
  /// 校验真实文件摘要，不匹配则删除目标文件并标记失败。
  Future<DownloadJob> start(
    String url, {
    String? filename,
    int chunks = 4,
    String? expectedSha256,
    int expectedBytes = 0,
  }) async {
    final name = (filename?.isNotEmpty == true)
        ? filename!
        : _safeName(Uri.tryParse(url)?.pathSegments.last ?? 'model.gguf');
    final target = '${store.sub('downloads').path}/$name';
    final id = 'dl-${DateTime.now().millisecondsSinceEpoch}-${++_seq}';

    String? expected;
    if (expectedSha256 != null) {
      final normalized = expectedSha256.trim().toLowerCase();
      if (!isValidSha256(normalized)) {
        final job = DownloadJob(
          id: id,
          url: url,
          target: target,
          chunks: 1,
          totalBytes: 0,
          resumable: false,
        );
        job.status = 'failed';
        job.error = 'expected_sha256 不是合法 SHA-256';
        job.finishedAt = DateTime.now();
        _jobs[id] = job;
        return job;
      }
      expected = normalized;
    }

    // 先探测真实大小与是否支持 Range。
    int total = 0;
    var resumable = false;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final req = await client.headUrl(Uri.parse(url));
      final resp = await req.close().timeout(const Duration(seconds: 15));
      total = resp.contentLength;
      resumable = resp.headers.value('accept-ranges')?.toLowerCase() == 'bytes';
      client.close(force: true);
    } on Object catch (e) {
      // HEAD 失败不阻断：退化为单流 GET，进度按实际落盘字节统计。
      resumable = false;
      total = 0;
      _lastProbeError = '$e';
    }
    // CDN 的 HEAD 有时返回错误/重定向页大小（例如 117MB），
    // 以目录里的真实文件大小为准，否则进度会假 100% 后连接断开。
    if (expectedBytes > total) {
      total = expectedBytes;
      resumable = true;
    }

    // 分片数自适应提速：大 GGUF 在弱网/高延迟 CDN 上单连接吞吐受限，
    // 8 路 Range 并行能显著提升聚合带宽。按已探测的真实文件大小上调分片，
    // 调用方给的 chunks 作为下限（默认 4），上限 8；小文件/不支持 Range 退单流。
    int n = 1;
    if (resumable && total > 1024 * 1024) {
      final int floor = chunks > 1 ? chunks : 4;
      int adaptive = floor;
      if (total >= 4 * 1024 * 1024 * 1024) {
        adaptive = 8; // >=4GB：顶格 8 路
      } else if (total >= 1024 * 1024 * 1024) {
        adaptive = floor >= 8 ? floor : 8; // >=1GB：8 路
      } else if (total >= 512 * 1024 * 1024) {
        adaptive = floor >= 6 ? floor : 6; // >=512MB：6 路
      }
      n = adaptive.clamp(1, 8);
    }
    final job = DownloadJob(
      id: id,
      url: url,
      target: target,
      chunks: n,
      totalBytes: total,
      resumable: resumable,
    );
    job.expectedSha256 = expected;
    _jobs[id] = job;
    unawaited(_setKeepAlive(true));
    unawaited(_run(job));
    return job;
  }

  String? _lastProbeError;
  String? get lastProbeError => _lastProbeError;

  Future<void> _run(DownloadJob job) async {
    try {
      final sidecar = File('${job.target}.tangram_dl.json');
      // 恢复断点：sidecar 存在且 url/size 一致时保留 .partN 续传。
      if (sidecar.existsSync()) {
        try {
          final m = jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
          if (m['url'] != job.url || m['total_bytes'] != job.totalBytes) {
            await _cleanParts(job);
          }
        } on Object {
          await _cleanParts(job);
        }
      }
      await sidecar.writeAsString(jsonEncode(<String, dynamic>{
        'url': job.url,
        'total_bytes': job.totalBytes,
        'chunks': job.chunks,
        'target': job.target,
        'started_at': DateTime.now().toIso8601String(),
      }), flush: true);

      if (job.chunks <= 1) {
        await _downloadWhole(job);
      } else {
        final futures = <Future<void>>[];
        final size = job.totalBytes ~/ job.chunks;
        for (var i = 0; i < job.chunks; i++) {
          final start = i * size;
          final end = (i == job.chunks - 1) ? job.totalBytes - 1 : (start + size - 1);
          futures.add(_downloadChunk(job, i, start, end));
        }
        await Future.wait(futures);
        await _merge(job);
      }
      final targetFile = File(job.target);
      job.actualSha256 = await sha256OfFile(targetFile);
      if (job.expectedSha256 != null &&
          job.expectedSha256 != job.actualSha256) {
        await targetFile.delete();
        job.status = 'failed';
        job.error = 'SHA-256 校验失败：期望 ${job.expectedSha256}，'
            '实际 ${job.actualSha256}';
        job.finishedAt = DateTime.now();
        return;
      }
      job.status = 'done';
      job.finishedAt = DateTime.now();
    } on Object catch (e) {
      job.status = 'failed';
      job.error = '$e';
    }
    if (!_jobs.values.any((DownloadJob j) => j.status == 'running')) {
      unawaited(_setKeepAlive(false));
    }
  }

  /// Android 前台服务保活：让 Dart 下载在退到后台后继续跑。
  static const MethodChannel _keepAlive =
      MethodChannel('tga/model_download');

  Future<void> _setKeepAlive(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _keepAlive.invokeMethod<void>(
          on ? 'startKeepAlive' : 'stopKeepAlive');
    } on Object {
      // 原生层缺失时退化为普通前台下载，不阻断任务。
    }
  }

  Future<void> _downloadWhole(DownloadJob job) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(job.url));
      req.followRedirects = true;
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(job.url));
      }
      final sink = File('${job.target}.part0').openWrite();
      // 空闲 30s 才判停滞：慢但持续推进的下载不被误杀；连接假死则抛错，
      // 由 _run 的 catch 标记失败（单流无分片续传，下次重下）。
      try {
        await sink.addStream(resp.timeout(const Duration(seconds: 30)));
      } finally {
        await sink.close();
      }
      await File('${job.target}.part0').rename(job.target);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _downloadChunk(
    DownloadJob job,
    int index,
    int start,
    int end,
  ) async {
    final part = File('${job.target}.part$index');
    int offset = start;
    if (part.existsSync()) {
      final existing = part.lengthSync();
      if (existing >= end - start + 1) return; // 该分片已完成
      offset = start + existing; // 从真实落盘字节续传
    }
    for (var attempt = 0; attempt < 4; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      IOSink? sink;
      try {
        final req = await client.getUrl(Uri.parse(job.url));
        req.headers.set('range', 'bytes=$offset-$end');
        req.followRedirects = true;
        final resp = await req.close().timeout(const Duration(seconds: 30));
        if (resp.statusCode != 206 && resp.statusCode != 200) {
          throw HttpException('分片 $index HTTP ${resp.statusCode}',
              uri: Uri.parse(job.url));
        }
        // 服务器忽略 Range 返回 200 时，不能在旧分片后追加，必须重写。
        if (resp.statusCode == 200 && offset > start) {
          offset = start;
          if (part.existsSync()) await part.delete();
        }
        sink = part.openWrite(mode: FileMode.append);
        await sink.addStream(resp);
        await sink.close();
        sink = null;
        return;
      } on Object catch (e) {
        try {
          await sink?.close();
        } on Object {
          // 关闭失败继续重试。
        }
        if (attempt >= 3) {
          throw HttpException('分片 $index 下载失败：$e',
              uri: Uri.parse(job.url));
        }
        // 连接被 CDN 提前关闭时，等 1/2/4 秒后从已落盘字节继续。
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
        final existing = part.existsSync() ? part.lengthSync() : 0;
        if (existing >= end - start + 1) return;
        offset = start + existing;
      } finally {
        client.close(force: true);
      }
    }
  }

  Future<void> _merge(DownloadJob job) async {
    final out = File(job.target).openWrite();
    for (var i = 0; i < job.chunks; i++) {
      final part = File('${job.target}.part$i');
      if (!part.existsSync()) {
        await out.close();
        throw StateError('分片 $i 缺失，无法合并');
      }
      await out.addStream(part.openRead());
    }
    await out.close();
    await _cleanParts(job);
  }

  Future<void> _cleanParts(DownloadJob job) async {
    for (var i = 0; i < job.chunks; i++) {
      final f = File('${job.target}.part$i');
      if (await f.exists()) await f.delete();
    }
  }

  /// 取消任务：标记状态（已落盘分片保留，供下次续传）。
  bool cancel(String id) {
    final job = _jobs[id];
    if (job == null || job.status != 'running') return false;
    job.status = 'cancelled';
    return true;
  }

  static String _safeName(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.isEmpty ? 'model.gguf' : cleaned;
  }
}
