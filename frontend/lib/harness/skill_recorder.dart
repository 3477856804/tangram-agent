/// Skill 录制 —— “看一次就学会”（Rakazo 深度机制 #10 的 clean-room 实现）。
///
/// 设计来源：Rakazo 把用户演示一次的操作步骤存为可复用的 skill、挂进
/// 插件内核当插件用的产品机制（Apache-2.0，只借鉴设计，不复制源码，
/// 不搬 Rakazo 的商标与品牌文案）。本文件为自行实现：
///
///  * [SkillRecorder]：开始 / 停止录制，逐条记录用户演示的操作步骤；
///  * [Skill]：录好的 skill（id / 名称 / 描述 / 步骤 / 版本 / 来源），
///    可转成插件描述 [Skill.toPluginDescriptor] 供“万物皆插件”内核挂接；
///  * [SkillStore]：落盘 JSON 到应用私有目录（原子写、尽力 0600 权限，
///    损坏文件从空态开始并记警告）；
///  * [SkillReplay]：回放只做步骤校验与 dry-run 描述，**不执行任何真实
///    外部操作**，不发真实消息、不扫码；
///  * 安全边界：步骤参数含疑似密钥/令牌时拒绝记录该步，只记审计元数据
///    （动作类型 / 目标 / 参数名 / 原因），绝不记密钥内容本身；录制上限
///    （单 skill 最多 200 步、参数单值上限）防止滥用。
///
/// 本文件刻意只依赖 dart:convert / dart:io，不引 `store.dart` /
/// `audit_log.dart`（后者经 path_provider → dart:ui，纯 Dart VM 里加载
/// 不起来），因此 Dart VM 断言脚本可以直接 import 本文件验证核心语义。
/// 密钥扫描沿用 im/audit.py 与 harness/audit_log.dart 的同一设计思路
/// （认证头 + 敏感键值 + 已知令牌前缀 + 高熵长串），规则在本文件内
/// 重新实现，不跨文件复用。
library;

import 'dart:convert';
import 'dart:io';

// ---------------------------------------------------------------------------
// 上限与动作白名单
// ---------------------------------------------------------------------------

/// 单个 skill 最多步骤数。
const int kMaxStepsPerSkill = 200;

/// 步骤目标（target）最长字符数。
const int kMaxTargetChars = 512;

/// 步骤参数单个值最长字符数。
const int kMaxParamValueChars = 4096;

/// 步骤参数单个键最长字符数。
const int kMaxParamKeyChars = 128;

/// 单个步骤最多参数个数。
const int kMaxParamsPerStep = 32;

/// skill 名称最长字符数。
const int kMaxSkillNameChars = 120;

/// skill 描述最长字符数。
const int kMaxSkillDescriptionChars = 1000;

/// skill id 最长字符数。
const int kMaxSkillIdChars = 64;

/// 录制时允许的动作类型白名单。未知动作类型一律拒绝记录。
/// 取值覆盖演示中最常见的操作：点按 / 输入 / 打开 / 导航 / 选择 /
/// 滚动 / 沙箱命令 / 文件读写 / 外发消息 / 通话 / 搜索 / 等待 / 备注 /
/// 截屏。回放是 dry-run，不实际执行，因此 shell / file_write 等动作
/// 在录制时同样允许，只在回放时拒绝执行。
const Set<String> kRecordableActionTypes = <String>{
  'tap',
  'type',
  'open',
  'navigate',
  'select',
  'scroll',
  'shell',
  'file_read',
  'file_write',
  'send_message',
  'call',
  'search',
  'wait',
  'note',
  'screenshot',
};

// ---------------------------------------------------------------------------
// 密钥扫描（只做判定，不输出、不保存任何疑似密钥内容）
// ---------------------------------------------------------------------------

/// 一次密钥扫描的结果：是否疑似密钥 + 原因（只含类别，不含原文）。
class SecretScanResult {
  const SecretScanResult(this.isSecret, this.reason);
  final bool isSecret;

  /// 原因类别：'auth-scheme' / 'sensitive-key' / 'token-prefix' /
  /// 'jwt' / 'high-entropy' / 'url-credentials' / ''（无问题）。
  final String reason;
}

/// 疑似密钥检测器。只回答“像不像密钥”，调用方据此拒绝记录该步；
/// 检测器本身不返回、不保存任何原文。
abstract final class SkillSecretScanner {
  /// `Authorization: Bearer xxx` / `Basic xxx` 这类认证头。
  static final RegExp _authScheme = RegExp(
    r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=\-]{8,}',
    caseSensitive: false,
  );

  /// `key=value` / `"key": "value"` 形式的敏感键值。
  static final RegExp _secretKeyValue = RegExp(
    r'''(?<![A-Za-z0-9_])(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|pwd|secret|client[_-]?secret|authorization)(["']?\s*[:=]\s*["']?)(?!Bearer\b|Basic\b)([^"'\s,;&}\]]+)''',
    caseSensitive: false,
  );

  /// 参数名本身就是敏感键名时，值无论是什么都按密钥处理。
  static final RegExp _sensitiveKeyName = RegExp(
    r'^(api[_-]?key|access[_-]?token|refresh[_-]?token|token|password|passwd|pwd|secret|client[_-]?secret|authorization|private[_-]?key)$',
    caseSensitive: false,
  );

  /// 已知令牌前缀（OpenAI / GitHub / Slack / AWS / GitLab / HuggingFace
  /// 等常见形态，只认前缀，不校验、不联网验证）。
  static final RegExp _tokenPrefix = RegExp(
    r'(sk-proj-|sk-|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|xox[baprs]-|AKIA[0-9A-Z]{16}|glpat-|hf_|dapi|-----BEGIN [A-Z ]*PRIVATE KEY-----)',
  );

  /// JWT：三段 base64url，首段为 eyJ（{"alg":...} 的 base64）。
  static final RegExp _jwt = RegExp(
    r'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
  );

  /// URL 里嵌的凭据：`scheme://user:password@host`。
  static final RegExp _urlCredentials = RegExp(r'://[^/\s]*:[^/\s@]+@');

  /// 高熵长串：长度 >= 32、无空白、只含 token 常见字符、同时含大小写
  /// 字母与数字。普通句子含空格不命中；纯小写十六进制（如 sha256，
  /// 无大写字母）不命中；长路径含 `/` 不命中。
  static final RegExp _highEntropy = RegExp(r'^[A-Za-z0-9_\-+=.]{32,}$');

  static bool _isHighEntropy(String value) {
    if (!_highEntropy.hasMatch(value)) return false;
    bool hasUpper = false;
    bool hasLower = false;
    bool hasDigit = false;
    for (int i = 0; i < value.length; i++) {
      final int c = value.codeUnitAt(i);
      if (c >= 65 && c <= 90) {
        hasUpper = true;
      } else if (c >= 97 && c <= 122) {
        hasLower = true;
      } else if (c >= 48 && c <= 57) {
        hasDigit = true;
      }
    }
    return hasUpper && hasLower && hasDigit;
  }

  /// 扫描一段文本是否疑似含密钥。只返回类别，不返回原文。
  static SecretScanResult scanText(String text) {
    if (text.isEmpty) return const SecretScanResult(false, '');
    if (_authScheme.hasMatch(text)) {
      return const SecretScanResult(true, 'auth-scheme');
    }
    if (_secretKeyValue.hasMatch(text)) {
      return const SecretScanResult(true, 'sensitive-key-value');
    }
    if (_tokenPrefix.hasMatch(text)) {
      return const SecretScanResult(true, 'token-prefix');
    }
    if (_jwt.hasMatch(text)) {
      return const SecretScanResult(true, 'jwt');
    }
    if (_urlCredentials.hasMatch(text)) {
      return const SecretScanResult(true, 'url-credentials');
    }
    if (_isHighEntropy(text)) {
      return const SecretScanResult(true, 'high-entropy');
    }
    return const SecretScanResult(false, '');
  }

  /// 扫描一个参数（键 + 值）。键名敏感或值疑似密钥都算命中。
  static SecretScanResult scanParam(String key, String value) {
    if (_sensitiveKeyName.hasMatch(key.trim())) {
      return const SecretScanResult(true, 'sensitive-key-name');
    }
    return scanText(value);
  }

  /// 为审计元数据脱敏一段文本：只保留结构，不保留疑似密钥原文。
  /// 已知形态（认证头 / URL 凭据 / 令牌前缀 / JWT / 敏感键值）按形
  /// 式替换为 `***`；脱敏后仍命中扫描时，整段替换为占位符。
  static String redactForAudit(String text) {
    String out = text.replaceAllMapped(_authScheme, (Match m) => '${m[1]} ***');
    out = out.replaceAllMapped(_urlCredentials, (Match m) => '://***@');
    out = out.replaceAll(_tokenPrefix, '***');
    out = out.replaceAll(_jwt, '***');
    out = out.replaceAllMapped(
      _secretKeyValue,
      (Match m) => '${m[1]}${m[2]}***',
    );
    if (scanText(out).isSecret) return '[已脱敏目标]';
    return out.length > 200 ? '${out.substring(0, 200)}…' : out;
  }
}

// ---------------------------------------------------------------------------
// 录制步骤
// ---------------------------------------------------------------------------

/// 录制的一步操作：动作类型 + 目标 + 参数 + 时间戳。
class SkillStep {
  SkillStep({
    required this.actionType,
    required this.target,
    Map<String, String>? params,
    String? recordedAt,
  }) : params = Map<String, String>.unmodifiable(params ?? <String, String>{}),
       recordedAt = recordedAt ?? DateTime.now().toIso8601String();

  final String actionType;
  final String target;
  final Map<String, String> params;
  final String recordedAt;

  /// 校验一步：返回错误信息列表（为空 = 通过）。只做结构校验，
  /// 密钥扫描由 [SkillRecorder.recordStep] 另行处理并记审计。
  static List<String> validate({
    required String actionType,
    required String target,
    required Map<String, String> params,
  }) {
    final List<String> errors = <String>[];
    if (!kRecordableActionTypes.contains(actionType)) {
      errors.add('未知动作类型：$actionType');
    }
    final String t = target.trim();
    if (t.isEmpty) {
      errors.add('目标不能为空');
    } else if (t.length > kMaxTargetChars) {
      errors.add('目标过长（${t.length} 字符，上限 $kMaxTargetChars）');
    }
    if (params.length > kMaxParamsPerStep) {
      errors.add('参数过多（${params.length} 个，上限 $kMaxParamsPerStep）');
    }
    params.forEach((String k, String v) {
      if (k.trim().isEmpty) {
        errors.add('参数名不能为空');
      } else if (k.length > kMaxParamKeyChars) {
        errors.add('参数名过长：$k');
      }
      if (v.length > kMaxParamValueChars) {
        errors.add('参数 $k 的值过长（${v.length} 字符，上限 $kMaxParamValueChars）');
      }
    });
    return errors;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'action': actionType,
    'target': target,
    'params': Map<String, String>.from(params),
    'recorded_at': recordedAt,
  };

  factory SkillStep.fromJson(Map<String, dynamic> json) {
    final Map<String, String> p = <String, String>{};
    final Object? raw = json['params'];
    if (raw is Map) {
      raw.forEach((Object? k, Object? v) {
        p[k.toString()] = v?.toString() ?? '';
      });
    }
    return SkillStep(
      actionType: (json['action'] ?? '').toString(),
      target: (json['target'] ?? '').toString(),
      params: p,
      recordedAt: (json['recorded_at'] ?? '').toString(),
    );
  }
}

/// 一次被拒绝记录的步骤的审计元数据：只记“哪类动作 / 哪个目标 /
/// 哪个参数名 / 为什么拒绝”，绝不记参数值本身。
class RejectedStepAudit {
  RejectedStepAudit({
    required this.actionType,
    required this.target,
    required this.paramKey,
    required this.reason,
    required this.recordedAt,
  });

  final String actionType;
  final String target;

  /// 被拒绝的参数名；若命中在 target 里则为空串。
  final String paramKey;

  /// 拒绝原因类别（见 [SecretScanResult.reason] 或 'validation'）。
  final String reason;
  final String recordedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'action': actionType,
    'target': target,
    'param_key': paramKey,
    'reason': reason,
    'recorded_at': recordedAt,
  };
}

// ---------------------------------------------------------------------------
// Skill
// ---------------------------------------------------------------------------

/// 一个录好的 skill：可复用的操作步骤序列。
class Skill {
  Skill({
    required this.id,
    required this.name,
    this.description = '',
    List<SkillStep>? steps,
    this.version = 1,
    String? createdAt,
    this.source = 'recorded',
  }) : steps = List<SkillStep>.unmodifiable(steps ?? const <SkillStep>[]),
       createdAt = createdAt ?? DateTime.now().toIso8601String();

  final String id;
  final String name;
  final String description;
  final List<SkillStep> steps;
  final int version;
  final String createdAt;

  /// 来源：'recorded'（本次录制）/ 'imported'（外部导入）。
  final String source;

  /// 校验 skill 元数据：id / 名称 / 描述 / 步骤数。
  static List<String> validateMeta({
    required String id,
    required String name,
    required String description,
    required int stepCount,
  }) {
    final List<String> errors = <String>[];
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$').hasMatch(id)) {
      errors.add('skill id 非法：$id');
    }
    final String n = name.trim();
    if (n.isEmpty) {
      errors.add('skill 名称不能为空');
    } else if (n.length > kMaxSkillNameChars) {
      errors.add('skill 名称过长（${n.length} 字符，上限 $kMaxSkillNameChars）');
    }
    if (description.length > kMaxSkillDescriptionChars) {
      errors.add(
        'skill 描述过长（${description.length} 字符，上限 $kMaxSkillDescriptionChars）',
      );
    }
    if (stepCount < 0 || stepCount > kMaxStepsPerSkill) {
      errors.add('步骤数非法：$stepCount（上限 $kMaxStepsPerSkill）');
    }
    return errors;
  }

  /// 校验全部步骤（含结构校验，不含密钥扫描——密钥扫描只在录制时做，
  /// 落盘的 skill 不应再含密钥）。
  List<String> validateSteps() {
    final List<String> errors = <String>[];
    for (int i = 0; i < steps.length; i++) {
      final SkillStep s = steps[i];
      for (final String e in SkillStep.validate(
        actionType: s.actionType,
        target: s.target,
        params: s.params,
      )) {
        errors.add('第 ${i + 1} 步：$e');
      }
    }
    return errors;
  }

  /// 转成“万物皆插件”内核可挂接的插件描述：只含元数据与可执行入口，
  /// 不含任何步骤参数原文以外的敏感内容（步骤参数本身已在录制时过
  /// 滤，落盘 skill 不含密钥）。
  Map<String, dynamic> toPluginDescriptor() => <String, dynamic>{
    'plugin_id': 'skill.$id',
    'id': id,
    'name': name,
    'description': description,
    'version': version,
    'steps': steps.length,
    'entry': 'skill.replay',
    'source': source,
    'kind': 'recorded-skill',
    'dry_run_only': true,
    'created_at': createdAt,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'description': description,
    'version': version,
    'created_at': createdAt,
    'source': source,
    'steps': steps.map((SkillStep s) => s.toJson()).toList(),
  };

  factory Skill.fromJson(Map<String, dynamic> json) {
    final List<SkillStep> steps = <SkillStep>[];
    final Object? raw = json['steps'];
    if (raw is List) {
      for (final Object? e in raw) {
        if (e is Map) {
          steps.add(
            SkillStep.fromJson(
              e.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
    }
    return Skill(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      steps: steps,
      version: (json['version'] is num) ? (json['version'] as num).toInt() : 1,
      createdAt: (json['created_at'] ?? '').toString(),
      source: (json['source'] ?? 'recorded').toString(),
    );
  }
}

// ---------------------------------------------------------------------------
// 录制器
// ---------------------------------------------------------------------------

/// Skill 录制器：一次录制会话 = 一段用户演示。
///
/// 录制只做记录与校验，不执行、不外发。含密钥嫌疑的步骤直接拒绝，
/// 只把拒绝的元数据记进 [rejectedAudits]（内存，不落盘、不含原文）。
class SkillRecorder {
  bool _recording = false;
  String _name = '';
  String _description = '';
  final List<SkillStep> _steps = <SkillStep>[];
  final List<RejectedStepAudit> _rejected = <RejectedStepAudit>[];

  bool get isRecording => _recording;
  int get currentStepCount => _steps.length;

  /// 本次录制中被拒绝的步骤审计（只含元数据，绝不含参数值）。
  List<RejectedStepAudit> get rejectedAudits =>
      List<RejectedStepAudit>.unmodifiable(_rejected);

  /// 开始一次录制。已在录制中时返回 ok:false，不覆盖进行中的会话。
  Map<String, dynamic> startRecording(String name, {String description = ''}) {
    if (_recording) {
      return <String, dynamic>{'ok': false, 'error': '已在录制中，请先停止当前录制'};
    }
    final String n = name.trim();
    if (n.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '录制名称不能为空'};
    }
    if (n.length > kMaxSkillNameChars) {
      return <String, dynamic>{
        'ok': false,
        'error': '录制名称过长（${n.length} 字符，上限 $kMaxSkillNameChars）',
      };
    }
    if (description.length > kMaxSkillDescriptionChars) {
      return <String, dynamic>{'ok': false, 'error': '录制描述过长'};
    }
    _recording = true;
    _name = n;
    _description = description;
    _steps.clear();
    _rejected.clear();
    return <String, dynamic>{'ok': true, 'name': _name};
  }

  /// 记录一步演示操作。结构校验失败或疑似含密钥时拒绝该步并返回
  /// ok:false（其余已录步骤不受影响），密钥嫌疑同时记一条审计元数据。
  Map<String, dynamic> recordStep(
    String actionType,
    String target, {
    Map<String, String>? params,
  }) {
    if (!_recording) {
      return <String, dynamic>{'ok': false, 'error': '未开始录制'};
    }
    if (_steps.length >= kMaxStepsPerSkill) {
      return <String, dynamic>{
        'ok': false,
        'error': '步骤已达上限 $kMaxStepsPerSkill，拒绝继续记录',
      };
    }
    final Map<String, String> p = params ?? <String, String>{};
    final List<String> errors = SkillStep.validate(
      actionType: actionType,
      target: target,
      params: p,
    );
    if (errors.isNotEmpty) {
      return <String, dynamic>{'ok': false, 'error': errors.join('；')};
    }
    // 密钥扫描：先扫 target，再逐个扫参数。命中即拒绝整步。
    final SecretScanResult targetHit = SkillSecretScanner.scanText(
      target.trim(),
    );
    if (targetHit.isSecret) {
      _rejected.add(
        RejectedStepAudit(
          actionType: actionType,
          // 目标本身含疑似密钥：审计只存脱敏后的目标，绝不存原文。
          target: SkillSecretScanner.redactForAudit(target.trim()),
          paramKey: '',
          reason: targetHit.reason,
          recordedAt: DateTime.now().toIso8601String(),
        ),
      );
      return <String, dynamic>{
        'ok': false,
        'error': '该步目标疑似含密钥（${targetHit.reason}），已拒绝记录',
        'rejected_reason': targetHit.reason,
      };
    }
    for (final MapEntry<String, String> e in p.entries) {
      final SecretScanResult hit = SkillSecretScanner.scanParam(e.key, e.value);
      if (hit.isSecret) {
        _rejected.add(
          RejectedStepAudit(
            actionType: actionType,
            target: target.trim(),
            paramKey: e.key,
            reason: hit.reason,
            recordedAt: DateTime.now().toIso8601String(),
          ),
        );
        return <String, dynamic>{
          'ok': false,
          'error': '参数 ${e.key} 疑似含密钥（${hit.reason}），已拒绝记录该步',
          'rejected_reason': hit.reason,
        };
      }
    }
    _steps.add(
      SkillStep(
        actionType: actionType,
        target: target.trim(),
        params: Map<String, String>.from(p),
      ),
    );
    return <String, dynamic>{'ok': true, 'steps': _steps.length};
  }

  /// 停止录制并产出 skill。无步骤时返回 ok:false（不产出空 skill）。
  Map<String, dynamic> stopRecording() {
    if (!_recording) {
      return <String, dynamic>{'ok': false, 'error': '未开始录制'};
    }
    _recording = false;
    if (_steps.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '未录到任何步骤，不产出空 skill'};
    }
    final Skill skill = Skill(
      id: _newId(),
      name: _name,
      description: _description,
      steps: List<SkillStep>.from(_steps),
      version: 1,
      source: 'recorded',
    );
    _steps.clear();
    return <String, dynamic>{'ok': true, 'skill': skill};
  }

  /// 取消本次录制，丢弃已录步骤（不产出 skill）。
  Map<String, dynamic> cancelRecording() {
    if (!_recording) {
      return <String, dynamic>{'ok': false, 'error': '未开始录制'};
    }
    _recording = false;
    _steps.clear();
    _rejected.clear();
    return <String, dynamic>{'ok': true, 'cancelled': true};
  }

  static String _newId() => 'skill-${DateTime.now().microsecondsSinceEpoch}';
}

// ---------------------------------------------------------------------------
// 回放（只校验 + dry-run 描述，绝不执行）
// ---------------------------------------------------------------------------

/// 回放：对一个 skill 做步骤校验并产出 dry-run 描述。
/// **绝不执行任何真实外部操作**：不调 shell、不读写文件、不发消息、
/// 不扫码。`executed` 恒为 false，供调用方与测试断言。
abstract final class SkillReplay {
  /// 一步的人类可读 dry-run 描述（不含参数值原文以外的任何执行）。
  static String describeStep(int index, SkillStep step) {
    final String params = step.params.isEmpty
        ? ''
        : '（${step.params.keys.join('、')}）';
    return '第 ${index + 1} 步：${step.actionType} ${step.target}$params';
  }

  /// dry-run 回放：逐条校验步骤并产出描述。
  static Map<String, dynamic> dryRun(Skill skill) {
    final List<Map<String, dynamic>> steps = <Map<String, dynamic>>[];
    bool allValid = true;
    for (int i = 0; i < skill.steps.length; i++) {
      final SkillStep s = skill.steps[i];
      final List<String> errors = SkillStep.validate(
        actionType: s.actionType,
        target: s.target,
        params: s.params,
      );
      if (errors.isNotEmpty) allValid = false;
      steps.add(<String, dynamic>{
        'index': i,
        'action': s.actionType,
        'target': s.target,
        'params': Map<String, String>.from(s.params),
        'description': describeStep(i, s),
        'valid': errors.isEmpty,
        if (errors.isNotEmpty) 'errors': errors,
      });
    }
    return <String, dynamic>{
      'ok': allValid,
      'executed': false,
      'mode': 'dry-run',
      'skill_id': skill.id,
      'skill_name': skill.name,
      'steps': steps,
      'note': '回放仅做校验与 dry-run 描述，不执行任何真实操作，不发消息、不扫码',
    };
  }
}

// ---------------------------------------------------------------------------
// 落盘存储
// ---------------------------------------------------------------------------

/// Skill 落盘存储：单个 JSON 文件（应用私有目录），原子写、尽力 0600。
///
/// 文件损坏时从空态开始并把警告记在 [lastWarning]（同时把损坏文件
/// 移到 `skills.json.corrupt-<时间戳>` 旁证，不静默丢数据）。
class SkillStore {
  SkillStore(this.dir);

  final Directory dir;

  static const String fileName = 'skills.json';

  File get _file => File('${dir.path}/$fileName');

  /// 最近一次加载/保存产生的警告（如文件损坏），无警告时为空串。
  String lastWarning = '';

  final Map<String, Skill> _skills = <String, Skill>{};
  bool _loaded = false;

  List<Skill> get all => List<Skill>.unmodifiable(_skills.values);

  /// 从磁盘加载；文件不存在 = 空库；损坏 = 空库 + 警告。
  Future<List<Skill>> load() async {
    _skills.clear();
    lastWarning = '';
    final File f = _file;
    if (!await f.exists()) {
      _loaded = true;
      return all;
    }
    String raw;
    try {
      raw = await f.readAsString();
    } on Object catch (e) {
      lastWarning = 'skill 库读取失败（$e），从空态开始';
      _loaded = true;
      return all;
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('顶层不是对象');
      final Object? list = decoded['skills'];
      if (list is! List) throw const FormatException('缺少 skills 列表');
      for (final Object? e in list) {
        if (e is! Map) continue;
        try {
          final Skill s = Skill.fromJson(
            e.map((Object? k, Object? v) => MapEntry(k.toString(), v)),
          );
          if (s.id.isEmpty) continue;
          _skills[s.id] = s;
        } on Object {
          // 单条坏记录跳过，不冒充数据。
          continue;
        }
      }
    } on Object catch (e) {
      _skills.clear();
      lastWarning = 'skill 库文件损坏（$e），从空态开始';
      try {
        final File corrupt = File(
          '${f.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}',
        );
        await f.rename(corrupt.path);
      } on Object {
        // 移走失败也不阻断空态恢复。
      }
    }
    _loaded = true;
    return all;
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  /// 原子写：临时文件 + 改名；尽力 chmod 0600。
  Future<Map<String, dynamic>> _save() async {
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final Map<String, dynamic> doc = <String, dynamic>{
        'version': 1,
        'updated_at': DateTime.now().toIso8601String(),
        'skills': _skills.values.map((Skill s) => s.toJson()).toList(),
      };
      final File tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(doc), flush: true);
      try {
        await Process.run('chmod', <String>['600', tmp.path]);
      } on Object {
        // chmod 不可用（如非 POSIX 平台）时尽力而为，不阻断保存。
      }
      await tmp.rename(_file.path);
      return <String, dynamic>{'ok': true, 'count': _skills.length};
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'skill 库保存失败：$e'};
    }
  }

  /// 保存一个 skill（新增或覆盖同 id）。步骤非法时拒绝并返回 ok:false。
  Future<Map<String, dynamic>> put(Skill skill) async {
    await _ensureLoaded();
    final List<String> errors = Skill.validateMeta(
      id: skill.id,
      name: skill.name,
      description: skill.description,
      stepCount: skill.steps.length,
    )..addAll(skill.validateSteps());
    if (errors.isNotEmpty) {
      return <String, dynamic>{'ok': false, 'error': errors.join('；')};
    }
    _skills[skill.id] = skill;
    final Map<String, dynamic> saved = await _save();
    if (saved['ok'] != true) {
      _skills.remove(skill.id);
      return saved;
    }
    return <String, dynamic>{'ok': true, 'id': skill.id};
  }

  Future<Skill?> get(String id) async {
    await _ensureLoaded();
    return _skills[id];
  }

  Future<List<Skill>> list() async {
    await _ensureLoaded();
    return all;
  }

  Future<Map<String, dynamic>> delete(String id) async {
    await _ensureLoaded();
    if (!_skills.containsKey(id)) {
      return <String, dynamic>{'ok': false, 'error': 'skill 不存在：$id'};
    }
    final Skill removed = _skills.remove(id)!;
    final Map<String, dynamic> saved = await _save();
    if (saved['ok'] != true) {
      _skills[id] = removed;
      return saved;
    }
    return <String, dynamic>{'ok': true, 'deleted': id};
  }

  /// 重命名：名称非法或 skill 不存在时拒绝。
  Future<Map<String, dynamic>> rename(String id, String newName) async {
    await _ensureLoaded();
    final Skill? existing = _skills[id];
    if (existing == null) {
      return <String, dynamic>{'ok': false, 'error': 'skill 不存在：$id'};
    }
    final String n = newName.trim();
    if (n.isEmpty) {
      return <String, dynamic>{'ok': false, 'error': '新名称不能为空'};
    }
    if (n.length > kMaxSkillNameChars) {
      return <String, dynamic>{'ok': false, 'error': '新名称过长'};
    }
    final Skill renamed = Skill(
      id: existing.id,
      name: n,
      description: existing.description,
      steps: existing.steps,
      version: existing.version,
      createdAt: existing.createdAt,
      source: existing.source,
    );
    _skills[id] = renamed;
    final Map<String, dynamic> saved = await _save();
    if (saved['ok'] != true) {
      _skills[id] = existing;
      return saved;
    }
    return <String, dynamic>{'ok': true, 'id': id, 'name': n};
  }
}
