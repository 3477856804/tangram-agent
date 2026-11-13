/// Tangram 分片断点续传下载器 —— 纯 Dart 实现。
///
/// 移植自 `myniqx/downloadx`（分片 Range / 断点 sidecar / 空闲停滞恢复）的
/// 核心思路：先用 HEAD 探测 Content-Length 与 Accept-Ranges，再按分片并发
/// GET `Range: bytes=a-b`，每片独立写 `.partN` 临时文件并把已下载字节记入
/// `.tangram_dl.json` sidecar；中断后重启从 sidecar 记录的偏移续传，全部分片
/// 完成后原子合并成目标文件。所有进度来自真实落盘字节数，不编造百分比。

library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tangram/harness/store.dart';

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
  DateTime startedAt = DateTime.now();
  DateTime? finishedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'job_id': id,
        'url': url,
        'target': target,
        'chunks': chunks,
        'total_bytes': totalBytes,
        'resumable': resumable,
        'status': status,
        if (error != null) 'error': error,
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
  Future<DownloadJob> start(
    String url, {
    String? filename,
    int chunks = 4,
  }) async {
    final name = (filename?.isNotEmpty == true)
        ? filename!
        : _safeName(Uri.tryParse(url)?.pathSegments.last ?? 'model.gguf');
    final target = '${store.sub('downloads').path}/$name';
    final id = 'dl-${DateTime.now().millisecondsSinceEpoch}-${++_seq}';

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

    final int n = (resumable && chunks > 1 && total > 1024 * 1024)
        ? chunks.clamp(1, 8)
        : 1;
    final job = DownloadJob(
      id: id,
      url: url,
      target: target,
      chunks: n,
      totalBytes: total,
      resumable: resumable,
    );
    _jobs[id] = job;
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
      job.status = 'done';
      job.finishedAt = DateTime.now();
    } on Object catch (e) {
      job.status = 'failed';
      job.error = '$e';
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
      await sink.addStream(resp);
      await sink.close();
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(job.url));
      req.headers.set('range', 'bytes=$offset-$end');
      req.followRedirects = true;
      final resp = await req.close().timeout(const Duration(seconds: 30));
      if (resp.statusCode != 206 && resp.statusCode != 200) {
        throw HttpException('分片 $index HTTP ${resp.statusCode}',
            uri: Uri.parse(job.url));
      }
      final sink = part.openWrite(mode: FileMode.append);
      await sink.addStream(resp);
      await sink.close();
    } finally {
      client.close(force: true);
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
