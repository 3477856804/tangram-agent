/// AI 视频剪辑工作室：真实 ffmpeg / video_edit.py 命令生成与执行。
///
/// 设计红线：
///  * `buildAutoEditCommand` 生成的是**可直接执行**的参数（`argv` 不做任何
///    字符串拼接；`command` 对每个 argv 做 POSIX 单引号转义），素材名、输出
///    路径、字幕、配乐都作为独立参数传入，杜绝 shell 注入。
///  * 命令调用 `backend/app/runtime/video_edit.py` 的 `auto_edit`，因此
///    stdout 是该项目真实输出的 JSON（{ok, output, steps, info}）。
///  * `runJob` 通过注入的 shell 真实执行；退出码非 0、JSON 不可解析或
///    ok=false 一律如实记 failed 与错误，绝不伪造成功。
///  * 每次执行落盘 `video_jobs.json`，支持列表与删除。
///
/// 依赖：ffmpeg / ffprobe / python3（由页面展示 dependency_check 命令）。

import 'dart:convert';

import 'store.dart';

typedef VideoShell = Future<Map<String, dynamic>> Function(
    String command, String cwd);

class VideoStudio {
  VideoStudio(this.store, {required this.shell});

  final HarnessStore store;
  final VideoShell shell;

  static const String _jobsKey = 'video_jobs';

  static const String dependencyCheckCommand =
      'command -v ffmpeg >/dev/null 2>&1 && '
      'command -v ffprobe >/dev/null 2>&1 && '
      'command -v python3 >/dev/null 2>&1';

  /// 生成自动粗剪命令。
  ///
  /// 返回：
  ///  * `argv`：可直接交给 Process.run 的参数列表（无 shell 拼接）；
  ///  * `command`：安全单引号转义后的 shell 命令，供注入的 shell 回调使用；
  ///  * `dependency_check`：真实的 ffmpeg/ffprobe/python3 检查命令；
  ///  * `import_check`：确认 video_edit 模块可导入。
  Map<String, dynamic> buildAutoEditCommand(
    List<String> assets,
    String output, {
    String? subtitles,
    String? music,
    int width = 1280,
    int height = 720,
    int fps = 30,
    String python = 'python3',
    String module = 'backend.app.runtime.video_edit',
  }) {
    final List<String> cleaned = assets
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty)
        .toList();
    final String dst = output.trim();
    if (cleaned.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '至少需要一个素材路径'};
    }
    if (dst.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '输出路径不能为空'};
    }
    if (width <= 0 || height <= 0) {
      return <String, dynamic>{'ok': false, 'error': '宽高必须为正整数'};
    }
    if (fps <= 0) {
      return <String, dynamic>{'ok': false, 'error': '帧率必须为正整数'};
    }
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_.]*$').hasMatch(module)) {
      return <String, dynamic>{'ok': false, 'error': 'video_edit 模块名不合法'};
    }
    final String? subs =
        (subtitles ?? '').trim().isEmpty ? null : subtitles!.trim();
    final String? bgm = (music ?? '').trim().isEmpty ? null : music!.trim();
    final Map<String, dynamic> data = <String, dynamic>{
      'assets': cleaned,
      'dst': dst,
      'width': width,
      'height': height,
      'fps': fps,
      'subtitles': subs,
      'music': bgm,
    };
    // jsonEncode(jsonEncode(...)) 得到可被 Python 直接解析的双引号字符串，
    // 素材路径里的引号/反斜杠/换行都由 JSON 规则转义，不会成为代码。
    final String dataLiteral = jsonEncode(jsonEncode(data));
    final String code = <String>[
      'import json',
      'from $module import auto_edit',
      'DATA = json.loads($dataLiteral)',
      'try:',
      '    RESULT = auto_edit(DATA["assets"], DATA["dst"], '
          'width=DATA["width"], height=DATA["height"], fps=DATA["fps"], '
          'subtitles=DATA["subtitles"], music=DATA["music"])',
      '    print(json.dumps(RESULT, ensure_ascii=False))',
      'except Exception as exc:',
      '    print(json.dumps({"ok": False, "error": "%s: %s" % '
          '(type(exc).__name__, exc)}, ensure_ascii=False))',
      '    raise SystemExit(1)',
    ].join('\n');
    final List<String> argv = <String>[python, '-c', code];
    final String command = argv.map(_shellQuote).join(' ');
    final String dep = 'command -v ffmpeg >/dev/null 2>&1 && '
        'command -v ffprobe >/dev/null 2>&1 && '
        'command -v ${_shellQuote(python)} >/dev/null 2>&1';
    final String importCheck =
        '${_shellQuote(python)} -c ${_shellQuote('import $module')}';
    return <String, dynamic>{
      'ok': true,
      'engine': 'python-video-edit',
      'argv': argv,
      'command': command,
      'dependency_check': dep,
      'import_check': importCheck,
      'assets': cleaned,
      'output': dst,
      'subtitles': subs,
      'music': bgm,
      'width': width,
      'height': height,
      'fps': fps,
      'uses': <String>['ffmpeg', 'ffprobe', 'python3'],
    };
  }

  /// 真实执行一次自动剪辑并落盘任务记录。
  Future<Map<String, dynamic>> runJob({
    required List<String> assets,
    required String output,
    String? subtitles,
    String? music,
    int width = 1280,
    int height = 720,
    int fps = 30,
    String cwd = '.',
  }) async {
    final Map<String, dynamic> built = buildAutoEditCommand(
      assets,
      output,
      subtitles: subtitles,
      music: music,
      width: width,
      height: height,
      fps: fps,
    );
    if (built['ok'] != true) {
      return <String, dynamic>{
        'ok': false,
        'error': (built['error'] ?? '命令生成失败').toString(),
      };
    }
    final String startedAt = DateTime.now().toIso8601String();
    final Map<String, dynamic> raw;
    try {
      raw = await shell(built['command'] as String, cwd);
    } on Object catch (e) {
      final Map<String, dynamic> job = await _recordJob(
        built: built,
        cwd: cwd,
        startedAt: startedAt,
        raw: <String, dynamic>{},
        parsed: null,
        status: 'failed',
        error: 'shell 调用异常：$e',
      );
      return <String, dynamic>{'ok': false, 'error': job['error'], 'job': job};
    }

    final String stdout = (raw['stdout'] ?? '').toString();
    final String stderr = (raw['stderr'] ?? '').toString();
    final int exitCode = _exitCode(raw);
    final Map<String, dynamic>? parsed = _parseJsonObject(stdout);
    final bool processOk = raw['ok'] != false && exitCode == 0;
    String status;
    String error = '';
    if (!processOk) {
      status = 'failed';
      error = (raw['error'] ?? parsed?['error'] ?? '').toString().trim();
      if (error.isEmpty) {
        error = stderr.trim().isNotEmpty
            ? _shorten(stderr.trim(), 600)
            : '命令执行失败（exit $exitCode）';
      }
    } else if (parsed == null) {
      status = 'failed';
      error = '命令输出不是可解析的 JSON（期望 video_edit.py 的 {ok, output, ...}）';
    } else if (parsed['ok'] == false) {
      status = 'failed';
      error = (parsed['error'] ?? 'video_edit 返回 ok=false').toString();
    } else {
      status = 'done';
    }
    final Map<String, dynamic> job = await _recordJob(
      built: built,
      cwd: cwd,
      startedAt: startedAt,
      raw: raw,
      parsed: parsed,
      status: status,
      error: error,
      exitCode: exitCode,
    );
    return <String, dynamic>{
      'ok': status == 'done',
      'job': job,
      if (parsed != null) 'result': parsed,
      if (error.isNotEmpty) 'error': error,
    };
  }

  Future<Map<String, dynamic>> _recordJob({
    required Map<String, dynamic> built,
    required String cwd,
    required String startedAt,
    required Map<String, dynamic> raw,
    required Map<String, dynamic>? parsed,
    required String status,
    required String error,
    int exitCode = 0,
  }) async {
    final Map<String, dynamic> job = <String, dynamic>{
      'id': 'vjob-${DateTime.now().microsecondsSinceEpoch}',
      'status': status,
      'error': error,
      'exit_code': exitCode,
      'cwd': cwd,
      'assets': built['assets'],
      'output': built['output'],
      'subtitles': built['subtitles'],
      'music': built['music'],
      'width': built['width'],
      'height': built['height'],
      'fps': built['fps'],
      'command': built['command'],
      'dependency_check': built['dependency_check'],
      'result': parsed,
      'stdout': _shorten((raw['stdout'] ?? '').toString(), 4000),
      'stderr': _shorten((raw['stderr'] ?? '').toString(), 4000),
      'started_at': startedAt,
      'finished_at': DateTime.now().toIso8601String(),
    };
    await store.insert(_jobsKey, job);
    return job;
  }

  /// 任务历史（最新在前）。
  Future<List<Map<String, dynamic>>> listJobs() async {
    final List<Map<String, dynamic>> jobs =
        await store.readRecords(_jobsKey);
    final List<Map<String, dynamic>> out = jobs.reversed.take(50).toList();
    return out;
  }

  Future<Map<String, dynamic>> deleteJob(dynamic id) async {
    final String key = id.toString();
    final List<Map<String, dynamic>> jobs =
        await store.readRecords(_jobsKey);
    final int before = jobs.length;
    jobs.removeWhere((Map<String, dynamic> j) => j['id'].toString() == key);
    if (jobs.length == before) {
      return <String, dynamic>{'ok': false, 'error': '任务不存在'};
    }
    await store.writeRecords(_jobsKey, jobs);
    return <String, dynamic>{'ok': true, 'deleted': key};
  }

  Future<Map<String, dynamic>> describe() async {
    final List<Map<String, dynamic>> jobs = await listJobs();
    return <String, dynamic>{
      'ok': true,
      'jobs': jobs.length,
      'done': jobs.where((Map<String, dynamic> j) => j['status'] == 'done').length,
      'failed':
          jobs.where((Map<String, dynamic> j) => j['status'] == 'failed').length,
      'dependency_check': dependencyCheckCommand,
      'file': '$_jobsKey.json',
    };
  }

  Future<Map<String, dynamic>> handle(
      String action, Map<String, dynamic> p) async {
    switch (action) {
      case 'build':
        return buildAutoEditCommand(
          (p['assets'] is List)
              ? (p['assets'] as List).map((dynamic e) => e.toString()).toList()
              : <String>[],
          (p['output'] ?? '').toString(),
          subtitles: (p['subtitles'] ?? '').toString(),
          music: (p['music'] ?? '').toString(),
          width: (p['width'] is num) ? (p['width'] as num).toInt() : 1280,
          height: (p['height'] is num) ? (p['height'] as num).toInt() : 720,
          fps: (p['fps'] is num) ? (p['fps'] as num).toInt() : 30,
        );
      case 'run':
        return runJob(
          assets: (p['assets'] is List)
              ? (p['assets'] as List).map((dynamic e) => e.toString()).toList()
              : <String>[],
          output: (p['output'] ?? '').toString(),
          subtitles: (p['subtitles'] ?? '').toString(),
          music: (p['music'] ?? '').toString(),
          width: (p['width'] is num) ? (p['width'] as num).toInt() : 1280,
          height: (p['height'] is num) ? (p['height'] as num).toInt() : 720,
          fps: (p['fps'] is num) ? (p['fps'] as num).toInt() : 30,
          cwd: (p['cwd'] ?? '.').toString(),
        );
      case 'jobs':
        return <String, dynamic>{'ok': true, 'jobs': await listJobs()};
      case 'delete':
        return deleteJob(p['id']);
      case 'deps':
        return <String, dynamic>{
          'ok': true,
          'dependency_check': dependencyCheckCommand,
          'description': '沙箱需安装 ffmpeg（含 ffprobe）与 python3',
        };
      case 'describe':
        return describe();
      default:
        return <String, dynamic>{'ok': false, 'error': '未知视频工作室动作：$action'};
    }
  }

  int _exitCode(Map<String, dynamic> r) {
    final dynamic raw = r['exit_code'] ?? r['code'];
    if (raw is num) return raw.toInt();
    return r['ok'] == false ? 1 : 0;
  }

  Map<String, dynamic>? _parseJsonObject(String stdout) {
    final String text = stdout.trim();
    if (text.isEmpty) return null;
    Map<String, dynamic>? decode(String s) {
      try {
        final dynamic value = jsonDecode(s);
        if (value is Map) {
          return value.map(
              (dynamic k, dynamic v) => MapEntry(k.toString(), v));
        }
      } on Object {
        // 继续尝试截取最后一段 JSON。
      }
      return null;
    }

    final Map<String, dynamic>? direct = decode(text);
    if (direct != null) return direct;
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      return decode(text.substring(start, end + 1));
    }
    return null;
  }

  String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";

  String _shorten(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';
}
