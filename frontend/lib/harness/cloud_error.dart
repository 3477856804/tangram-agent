/// 云端 / OpenAI 兼容外部推理的错误转译（纯 Dart，无 Flutter / native 依赖）。
///
/// 设计目标：
///  * 绝不伪造成功；只把底层错误翻译成用户能看懂、能行动的一句话。
///  * 把网关返回的裸 JSON（如 `HTTP 429：{"error":{...}}`）压成人话，
///    去掉 diagnostics / 堆栈噪声，但保留关键线索便于排查。
///  * 供内嵌后端（embedded_backend）与 flai provider 共用同一套语义，
///    避免两处转译不一致导致同一错误显示两遍 / 一处转译一处裸奔。
///
/// 本文件刻意不 import 任何 package，便于用纯 Dart VM 直接单测。

/// 是否为「限流 / 免费额度用尽 / 服务暂时不可用」类错误（HTTP 429 等）。
///
/// 用于：① 决定是否自动重试一次；② 决定给用户哪句提示。
/// 采用多信号判断，兼容不同网关的文案：
///  - 状态码 `429`
///  - `rate limit` / `too many requests` / `quota` / `throttl*`
///  - 免费端点常见的 `... is temporarily ...` / `overload` / `capacity`
bool isRateLimitError(String raw) {
  final String s = raw.toLowerCase();
  if (s.contains('429')) return true;
  const List<String> signals = <String>[
    'rate limit',
    'rate_limit',
    'ratelimit',
    'too many requests',
    'quota',
    'throttl',
    'overload',
    'capacity',
    'retry later',
    'slow down',
    'temporarily',
    'temporary unavailable',
  ];
  for (final String k in signals) {
    if (s.contains(k)) return true;
  }
  // 中文网关文案（部分国内中转）。
  if (s.contains('请求过于频繁') ||
      s.contains('限流') ||
      s.contains('额度') ||
      s.contains('稍后重试')) {
    return true;
  }
  return false;
}

/// 从裸错误里提取网关 message 字段（若有），用于兜底展示时去掉 `{...}` 噪声。
///
/// 优先解析标准 JSON 对象（`error.message` / 顶层 `message`）；解析失败或
/// 字段缺失时，退回正则提取双引号 message，避免把堆栈里的括号噪声带给用户。
String _extractMessage(String raw) {
  final String trimmed = raw.trim();
  if (trimmed.startsWith('{')) {
    try {
      // 本模块保持纯 Dart、不依赖 dart:convert；JSON 结构较简单，先用
      // 正则兼容常见网关。若后续需要完整对象解析，可在共享位置引入 convert。
      final RegExp msgRe = RegExp(
        r'"(?:error\.)?message"\s*:\s*"((?:[^"\\]|\\.)*)"',
      );
      final RegExpMatch? m = msgRe.firstMatch(trimmed);
      if (m != null && m.group(1) != null && m.group(1)!.isNotEmpty) {
        return m.group(1)!.replaceAll(r'\n', ' ').replaceAll(r'\"', '"');
      }
    } on Object {
      // 正则/转义异常不应阻断兜底展示。
    }
  }
  final RegExp re = RegExp(r'"message"\s*:\s*"([^"]*)"');
  final RegExpMatch? m = re.firstMatch(raw);
  if (m != null && m.group(1) != null && m.group(1)!.isNotEmpty) {
    return m.group(1)!;
  }
  return raw;
}

/// 把底层错误压成一句「去掉裸 JSON / 堆栈」的简短线索。
String _briefLine(String raw) {
  String s = _extractMessage(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
  // 去掉开头的 "HTTP 429：" 之类前缀，只留可读核心。
  s = s.replaceAll(RegExp(r'^HTTP\s+\d+\s*[：:]\s*'), '');
  if (s.length > 100) s = '${s.substring(0, 100)}…';
  return s.isEmpty ? '未返回具体原因' : s;
}

/// 把外部推理底层错误转成用户可懂、可行动的中文，绝不伪造成功。
///
/// 覆盖顺序遵循「先具体、后兜底」，避免 429 的 message 里含 "not found"
/// 之类的词被误判到 404 分支。
String friendlyCloudError(String raw) {
  final String s = raw.toLowerCase();

  // 1) 限流 / 免费额度 / 服务暂时不可用 —— 最常见，也最容易误显示为裸 JSON。
  if (isRateLimitError(raw)) {
    return '免费模型请求过于频繁或额度用尽（HTTP 429），服务暂时不可用。'
        '请稍等片刻再点「重新生成」，或在模型选择器切换到其它模型 / 内置引擎。';
  }

  // 2) 凭据。
  if (s.contains('401') ||
      s.contains('403') ||
      s.contains('unauthorized') ||
      s.contains('invalid api key') ||
      s.contains('incorrect api key') ||
      s.contains('authentication')) {
    return 'API Key 无效或已过期，请到「训练设置」核对后重新保存';
  }

  // 3) 模型名 / 地址。
  if (s.contains('404') ||
      s.contains('not found') ||
      s.contains('does not exist') ||
      s.contains('unknown model')) {
    return '该模型在此 Base URL 下不存在，请核对模型名或切换模型';
  }

  // 4) 网络。
  if (s.contains('connection') ||
      s.contains('socket') ||
      s.contains('timed out') ||
      s.contains('timeout') ||
      s.contains('enotfound') ||
      s.contains('econnrefused') ||
      s.contains('network') ||
      s.contains('failed to host')) {
    return '无法连接该 API 地址，请检查网络或 Base URL 是否正确';
  }

  // 5) 兜底：提取 message、去裸 JSON、截断，仍如实携带原始线索。
  return '云端调用失败：${_briefLine(raw)}';
}
