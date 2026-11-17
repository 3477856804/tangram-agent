import 'dart:async';

import 'package:flutter/foundation.dart';

import '../harness/store.dart';

/// 对话场景模式：决定主动性、寒暄密度与是否允许主动打扰。
enum PresenceMode {
  /// 专注：少寒暄，优先推进任务；只有高优先级事件才主动开口。
  focus('专注', '少寒暄，直接给结论与下一步'),
  /// 闲聊：可自然承接情绪，先回应感受再给建议。
  chat('闲聊', '可自然承接情绪，允许适度展开'),
  /// 安静：不主动打扰，只在用户开口后回应。
  quiet('安静', '不主动打扰，只在被叫到时回应');

  const PresenceMode(this.label, this.strategy);

  final String label;
  final String strategy;

  static PresenceMode parse(String? raw) {
    for (final PresenceMode m in PresenceMode.values) {
      if (m.name == raw) return m;
    }
    return PresenceMode.chat;
  }
}

/// 情绪标签：只用于调整交互风格，不是心理诊断。
enum Mood {
  neutral('平静'),
  focused('专注'),
  tired('疲惫'),
  cheerful('愉快'),
  frustrated('烦躁');

  const Mood(this.label);

  final String label;

  static Mood parse(String? raw) {
    for (final Mood m in Mood.values) {
      if (m.name == raw) return m;
    }
    return Mood.neutral;
  }
}

/// 一条被摘要过的近期交互（只保留判断语气所需的最少信息）。
class RecentInteraction {
  const RecentInteraction({
    required this.text,
    required this.tone,
    required this.ts,
  });

  final String text;
  final String tone;
  final DateTime ts;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'tone': tone,
        'ts': ts.toIso8601String(),
      };

  static RecentInteraction? fromJson(Map<String, dynamic> m) {
    final String text = (m['text'] ?? '').toString();
    final DateTime? ts = DateTime.tryParse((m['ts'] ?? '').toString());
    if (text.isEmpty || ts == null) return null;
    return RecentInteraction(
      text: text,
      tone: Mood.parse(m['tone']?.toString()).name,
      ts: ts,
    );
  }
}

/// 场景感知 / 情绪连贯 / 打断恢复 / 合理遗忘的真实状态。
///
/// 全部字段落到 HarnessStore 的 `presence_state.json`，重启后可恢复；
/// 组装出的 [summaryBlock] 会被注入系统提示词，真实影响对话风格。
/// 情绪只根据用户消息的关键词、标点与长度做启发式判断，
/// 是交互风格提示，不是心理诊断。
class PresenceStore extends ChangeNotifier {
  PresenceStore._(this._store);

  final HarnessStore _store;

  static const String fileName = 'presence_state.json';
  static const int maxRecentInteractions = 60;
  static const int _summaryMaxChars = 80;

  PresenceMode mode = PresenceMode.chat;
  Mood mood = Mood.neutral;

  /// 0-1 的粗略能量值，用于决定回复长度与主动性，不做任何医学含义解释。
  double energy = 0.6;

  /// 最近一条用户消息的语气标签（[Mood] 的 name）。
  String lastUserTone = Mood.neutral.name;

  List<RecentInteraction> recentInteractions = <RecentInteraction>[];

  /// 被中断、尚可恢复的任务描述；null 表示没有。
  String? interruptedTask;

  /// 任务被中断的时间。
  DateTime? pausedAt;

  /// 最近一次「遗忘」的时间界线；早于它的交互已被删除。
  DateTime? forgetBefore;

  DateTime updatedAt = DateTime.now();

  /// 用户明确要求保留的交互摘要；遗忘与淘汰都不会删除它们。
  final List<String> pinned = <String>[];

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> _pendingSave = Future<void>.value();

  static Future<PresenceStore> load(HarnessStore store) async {
    final PresenceStore s = PresenceStore._(store);
    try {
      final Map<String, dynamic> m = await store.readJson(fileName);
      if (m.isNotEmpty) {
        s.mode = PresenceMode.parse(m['mode']?.toString());
        s.mood = Mood.parse(m['mood']?.toString());
        s.energy = _clamp(_asDouble(m['energy'], s.energy));
        s.lastUserTone = Mood.parse(m['lastUserTone']?.toString()).name;
        final dynamic rawPinned = m['pinned'];
        if (rawPinned is List) {
          for (final dynamic p in rawPinned) {
            final String text = p.toString().trim();
            if (text.isNotEmpty && !s.pinned.contains(text)) s.pinned.add(text);
          }
        }
        final dynamic rawRecent = m['recentInteractions'];
        if (rawRecent is List) {
          for (final dynamic item in rawRecent) {
            if (item is! Map) continue;
            final RecentInteraction? r = RecentInteraction.fromJson(
              item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
            );
            if (r != null) s.recentInteractions.add(r);
          }
          s._trimRecent();
        }
        final String task = (m['interruptedTask'] ?? '').toString().trim();
        s.interruptedTask = task.isEmpty ? null : task;
        s.pausedAt = DateTime.tryParse((m['pausedAt'] ?? '').toString());
        s.forgetBefore = DateTime.tryParse((m['forgetBefore'] ?? '').toString());
        s.updatedAt =
            DateTime.tryParse((m['updatedAt'] ?? '').toString()) ?? s.updatedAt;
      }
    } on Object {
      // 存储损坏时保持默认内存态；后续写入会重建真实文件。
    }
    s._loaded = true;
    return s;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'mode': mode.name,
        'mood': mood.name,
        'energy': energy,
        'lastUserTone': lastUserTone,
        'recentInteractions':
            recentInteractions.map((RecentInteraction r) => r.toJson()).toList(),
        'interruptedTask': interruptedTask,
        'pausedAt': pausedAt?.toIso8601String(),
        'forgetBefore': forgetBefore?.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'pinned': List<String>.of(pinned),
      };

  /// 串行落盘：任何时刻方法调用都无需 await，且最后一次快照一定写到最后。
  Future<void> _persist() {
    _pendingSave = _pendingSave.then((_) async {
      try {
        await _store.writeJson(fileName, toJson());
      } on Object {
        // 落盘失败不阻断对话；内存态仍然正确。
      }
    });
    return _pendingSave;
  }

  /// 等待已排队的写入完成（测试与退出前使用）。
  Future<void> flush() => _pendingSave;

  void _update(void Function() mutate) {
    mutate();
    updatedAt = DateTime.now();
    notifyListeners();
    unawaited(_persist());
  }

  // ---- 模式 ----

  void setMode(PresenceMode value) {
    if (mode == value) return;
    _update(() => mode = value);
  }

  // ---- 情绪 / 能量 ----

  void setMood(Mood value) {
    if (mood == value) return;
    _update(() => mood = value);
  }

  void setEnergy(double value) {
    final double next = _clamp(value);
    if ((energy - next).abs() < 0.0001) return;
    _update(() => energy = next);
  }

  // ---- 打断 / 恢复 ----

  void interruptTask(String task) {
    final String trimmed = task.trim();
    if (trimmed.isEmpty) return;
    _update(() {
      interruptedTask = trimmed;
      pausedAt = DateTime.now();
    });
  }

  void resumeTask() {
    if (interruptedTask == null && pausedAt == null) return;
    _update(() {
      interruptedTask = null;
      pausedAt = null;
    });
  }

  void clearInterrupted() => resumeTask();

  // ---- 对话记录 ----

  /// 记录用户消息：真实启发式判断语气、追加摘要、同步情绪与能量。
  /// 同一轮对话只应由对话入口调用一次。
  void recordUserMessage(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final Mood tone = _detectTone(trimmed);
    final String summary = _summarize(trimmed);
    _update(() {
      recentInteractions.add(RecentInteraction(
        text: summary,
        tone: tone.name,
        ts: DateTime.now(),
      ));
      lastUserTone = tone.name;
      // 明确的语气才改变情绪；中性消息保持情绪连贯，不来回跳。
      if (tone != Mood.neutral) mood = tone;
      switch (tone) {
        case Mood.frustrated:
          energy = _clamp(energy - 0.05);
        case Mood.tired:
          energy = _clamp(energy - 0.04);
        case Mood.cheerful:
          energy = _clamp(energy + 0.03);
        case Mood.focused:
          energy = _clamp(energy + 0.01);
        case Mood.neutral:
          break;
      }
      _trimRecent();
    });
  }

  /// 记录助手完成的一轮回复：长回复略耗能、极短回复略回能，
  /// 让后续提示词里的能量变化来自真实对话而非凭空生成。
  void recordAssistantReply(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final int chars = trimmed.runes.length;
    _update(() {
      if (chars > 480) {
        energy = _clamp(energy - 0.03);
      } else if (chars < 40) {
        energy = _clamp(energy + 0.01);
      }
    });
  }

  // ---- 合理遗忘 ----

  /// 删除 [days] 天前的交互；[pinned] 中的内容永远保留。
  /// 同时记录遗忘界线，便于 UI 如实展示。
  void forgetOlderThan(int days) {
    final int safeDays = days < 0 ? 0 : days;
    final DateTime cutoff = DateTime.now().subtract(Duration(days: safeDays));
    _update(() {
      forgetBefore = cutoff;
      recentInteractions.removeWhere(
        (RecentInteraction r) => r.ts.isBefore(cutoff) && !isPinned(r.text),
      );
    });
  }

  /// 固定一条交互摘要（用户明确要求保留）。
  void pin(String text) {
    final String summary = _summarize(text);
    if (summary.isEmpty || pinned.contains(summary)) return;
    _update(() => pinned.add(summary));
  }

  void unpin(String text) {
    final String summary = _summarize(text);
    if (!pinned.contains(summary)) return;
    _update(() => pinned.remove(summary));
  }

  bool isPinned(String text) {
    for (final String p in pinned) {
      if (p == text || p.contains(text) || text.contains(p)) return true;
    }
    return false;
  }

  void _trimRecent() {
    while (recentInteractions.length > maxRecentInteractions) {
      final int index =
          recentInteractions.indexWhere((RecentInteraction r) => !isPinned(r.text));
      if (index < 0) break; // 全部被固定：宁可超限也不删用户要求保留的内容。
      recentInteractions.removeAt(index);
    }
  }

  // ---- 策略 ----

  /// 当前模式是否允许主动开口。
  bool get shouldProactivelySpeak {
    switch (mode) {
      case PresenceMode.quiet:
        return false;
      case PresenceMode.focus:
        // 专注模式只在高优先级事件（有被打断任务 / 明显负面情绪且尚有能量）时开口。
        return (interruptedTask != null ||
                mood == Mood.frustrated ||
                (mood == Mood.tired && energy < 0.3)) &&
            energy >= 0.15;
      case PresenceMode.chat:
        return true;
    }
  }

  /// 可选的「继续上次任务」提示；没有中断任务时为 null。
  String? get resumeHint {
    final String? task = interruptedTask;
    if (task == null) return null;
    final DateTime? at = pausedAt;
    final String elapsed = at == null ? '' : '（已暂停${_elapsedLabel(at)}）';
    return '上次任务「$task」还没做完$elapsed，可以在合适时机问一句是否继续。';
  }

  /// 注入系统提示词的简短在场状态块；不含任何诊断性结论。
  String summaryBlock() {
    final StringBuffer b = StringBuffer('【在场状态】\n');
    b.writeln('当前模式：${mode.label}（${mode.strategy}）。');
    b.writeln(
      '情绪：${mood.label}；最近用户语气：${Mood.parse(lastUserTone).label}。',
    );
    b.writeln('能量：${(energy * 100).round()}%。');
    final String? task = interruptedTask;
    if (task != null) {
      b.writeln('有一个被打断的任务：「$task」，可在合适时机询问是否继续。');
    } else {
      b.writeln('当前没有被打断的任务。');
    }
    switch (mode) {
      case PresenceMode.quiet:
        b.writeln('安静模式：除非用户主动开口，否则禁止主动打扰；回复保持简短。');
      case PresenceMode.focus:
        b.writeln('专注模式：少寒暄，优先推进任务，不主动切换话题。');
      case PresenceMode.chat:
        b.writeln('闲聊模式：可自然承接情绪，先回应感受，再给可执行的建议。');
    }
    if (mood == Mood.tired) {
      b.writeln('用户可能疲惫：回复更短、分步给结论，必要时建议先休息。');
    } else if (mood == Mood.frustrated) {
      b.writeln('用户可能烦躁：先承认卡点，再给最小可验证的下一步，不堆解释。');
    }
    b.write('注意：情绪与能量只是交互风格提示，不是心理诊断。');
    return b.toString();
  }

  // ---- 启发式工具 ----

  /// 真实关键词 / 标点 / 长度启发式；只用于选择回复风格。
  static Mood _detectTone(String text) {
    final String s = text.toLowerCase();
    const List<String> frustrated = <String>[
      '烦死', '烦', '崩溃', '无语', '气死', '受不了', '搞不定', '又错',
      '还是不行', '怎么又', '为什么还', '垃圾', '难用', '卡住', '麻了',
      '服了', '绝望', 'damn', 'shit', 'fuck',
    ];
    const List<String> cheerful = <String>[
      '哈哈', '开心', '太好了', '太好', '好棒', '棒', '谢谢', '感谢', '喜欢',
      '太强', '牛', '赞', '爽', '嘿嘿', '真好', '搞定了', '成功了', '有了',
      'great', 'thanks', 'good', '🎉', '😀', '😄', '🥳',
    ];
    const List<String> tired = <String>[
      '好累', '累', '困', '熬夜', '撑不住', '疲惫', '头疼', '想睡', '休息',
      '明天再说', '没力气', '不想动', '先睡',
    ];
    const List<String> focused = <String>[
      '实现', '修复', '重构', '编译', '测试', '部署', '代码', '报错', '分析',
      '设计', '需求', '继续', '检查', '优化', '任务', '排查', '接入', '跑一下',
      '写一个', '改一下',
    ];
    if (frustrated.any(s.contains)) return Mood.frustrated;
    if (cheerful.any(s.contains)) return Mood.cheerful;
    if (tired.any(s.contains)) return Mood.tired;
    if (focused.any(s.contains)) return Mood.focused;

    // 标点：连续问号常表达急躁；单问号不判负面。
    final int questionMarks =
        text.split('?').length - 1 + text.split('？').length - 1;
    if (questionMarks >= 3) return Mood.frustrated;

    // 长度：极短消息多为应答，按中性处理；成段说明多是在交代任务。
    final int chars = text.runes.length;
    if (chars > 160) return Mood.focused;
    return Mood.neutral;
  }

  static String _summarize(String text) {
    final String collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final List<int> runes = collapsed.runes.toList();
    if (runes.length <= _summaryMaxChars) return collapsed;
    return '${String.fromCharCodes(runes.take(_summaryMaxChars))}…';
  }

  static String _elapsedLabel(DateTime since) {
    final Duration d = DateTime.now().difference(since);
    if (d.inMinutes < 1) return '不到 1 分钟';
    if (d.inHours < 1) return ' ${d.inMinutes} 分钟';
    if (d.inDays < 1) return ' ${d.inHours} 小时';
    return ' ${d.inDays} 天';
  }

  static double _clamp(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

  static double _asDouble(dynamic v, double fallback) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }
}
