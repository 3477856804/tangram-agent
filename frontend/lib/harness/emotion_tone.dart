/// 拟人化交互 / 情绪感知与连贯 —— 纯 Dart 词库 + EMA 平滑的真实底座。
///
/// 参考 mem0 / LangMem 把「情绪」当作记忆元数据的思路：一条消息只提供一次
/// 弱证据，真实情绪由词库打分（valence / arousal / confidence）与 EMA
/// 连续状态共同决定，不因一句话突然反转。全部本地、零依赖，状态真实落盘
/// 到 `presence/emotion_state.json`，重启后可恢复。
///
/// 这里输出的是交互风格提示，不是心理诊断，也不推测病因。

import 'dart:async';

import 'store.dart';

/// 情绪标签：只用于调整交互风格，不构成心理诊断。
enum EmotionLabel {
  joy('愉快'),
  calm('平静'),
  sad('难过'),
  angry('生气'),
  anxious('焦虑'),
  tired('疲惫'),
  neutral('中性');

  const EmotionLabel(this.label);

  final String label;

  static EmotionLabel parse(String? raw) {
    for (final EmotionLabel e in values) {
      if (e.name == raw) return e;
    }
    return EmotionLabel.neutral;
  }
}

/// 一次词库分析的结果。
///
/// - [valence] 效价：-1（负面）..1（正面）。
/// - [arousal] 唤醒 / 能量：0..1。
/// - [confidence] 置信度：无任何命中时为 0，绝不编造。
class EmotionReading {
  const EmotionReading({
    required this.label,
    required this.valence,
    required this.arousal,
    required this.confidence,
    this.hits = const <String>[],
  });

  final EmotionLabel label;
  final double valence;
  final double arousal;
  final double confidence;

  /// 命中的词条（被否定的词条以 `不·xxx` 标记），便于如实解释来源。
  final List<String> hits;

  /// 空文本 / 无命中的基线：不猜测用户情绪。
  static const EmotionReading neutral = EmotionReading(
    label: EmotionLabel.neutral,
    valence: 0,
    arousal: 0.3,
    confidence: 0,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label.name,
        'valence': valence,
        'arousal': arousal,
        'confidence': confidence,
        'hits': List<String>.of(hits),
      };

  /// 解析失败或字段缺失时返回 null，由调用方决定回退，不伪造读数。
  static EmotionReading? fromJson(Map<String, dynamic>? raw) {
    if (raw == null || raw.isEmpty) return null;
    final String rawLabel = (raw['label'] ?? '').toString();
    if (!EmotionLabel.values.any((EmotionLabel e) => e.name == rawLabel)) {
      return null;
    }
    final dynamic rawHits = raw['hits'];
    final List<String> hits = <String>[];
    if (rawHits is List) {
      for (final dynamic h in rawHits) {
        final String text = h.toString().trim();
        if (text.isNotEmpty) hits.add(text);
      }
    }
    return EmotionReading(
      label: EmotionLabel.parse(rawLabel),
      valence: _clampSigned(_asDouble(raw['valence'], 0)),
      arousal: _clamp01(_asDouble(raw['arousal'], 0.3)),
      confidence: _clamp01(_asDouble(raw['confidence'], 0)),
      hits: hits,
    );
  }
}

/// 一个带强度权重的词条。
class _Term {
  const _Term(this.text, this.weight);

  final String text;
  final double weight;
}

/// 内置中英情绪词库与启发式分析。
abstract final class EmotionLexicon {
  /// 每个类别至少 6 个词条；权重 0.4..1.0 表示强度。
  static const Map<EmotionLabel, List<_Term>> _terms =
      <EmotionLabel, List<_Term>>{
    EmotionLabel.joy: <_Term>[
      _Term('开心', 1.0),
      _Term('高兴', 0.9),
      _Term('愉快', 0.8),
      _Term('兴奋', 0.8),
      _Term('太好了', 0.9),
      _Term('好棒', 0.8),
      _Term('喜欢', 0.7),
      _Term('满意', 0.6),
      _Term('哈哈', 0.6),
      _Term('谢谢', 0.5),
      _Term('happy', 0.9),
      _Term('great', 0.8),
      _Term('awesome', 0.9),
      _Term('love', 0.8),
      _Term('thanks', 0.5),
      _Term('good', 0.5),
    ],
    EmotionLabel.calm: <_Term>[
      _Term('平静', 0.9),
      _Term('放松', 0.8),
      _Term('安心', 0.8),
      _Term('踏实', 0.7),
      _Term('稳定', 0.6),
      _Term('淡定', 0.6),
      _Term('舒服', 0.6),
      _Term('还好', 0.4),
      _Term('没问题', 0.5),
      _Term('calm', 0.8),
      _Term('relaxed', 0.8),
      _Term('okay', 0.4),
      _Term('fine', 0.4),
      _Term('chill', 0.5),
    ],
    EmotionLabel.sad: <_Term>[
      _Term('难过', 1.0),
      _Term('伤心', 1.0),
      _Term('失落', 0.8),
      _Term('沮丧', 0.9),
      _Term('想哭', 0.9),
      _Term('委屈', 0.8),
      _Term('孤单', 0.7),
      _Term('失望', 0.8),
      _Term('低落', 0.7),
      _Term('郁闷', 0.7),
      _Term('sad', 0.9),
      _Term('upset', 0.8),
      _Term('lonely', 0.8),
      _Term('down', 0.6),
      _Term('cry', 0.7),
    ],
    EmotionLabel.angry: <_Term>[
      _Term('生气', 0.9),
      _Term('愤怒', 1.0),
      _Term('烦死', 0.9),
      _Term('火大', 0.9),
      _Term('气死', 0.9),
      _Term('受不了', 0.8),
      _Term('无语', 0.6),
      _Term('崩溃', 0.8),
      _Term('恼火', 0.8),
      _Term('好烦', 0.8),
      _Term('太烦', 0.8),
      _Term('难受', 0.5),
      _Term('angry', 0.9),
      _Term('mad', 0.8),
      _Term('furious', 1.0),
      _Term('annoyed', 0.8),
      _Term('hate', 0.8),
    ],
    EmotionLabel.anxious: <_Term>[
      _Term('焦虑', 1.0),
      _Term('紧张', 0.8),
      _Term('担心', 0.8),
      _Term('害怕', 0.8),
      _Term('不安', 0.7),
      _Term('压力', 0.7),
      _Term('心慌', 0.8),
      _Term('睡不着', 0.7),
      _Term('恐惧', 0.9),
      _Term('anxious', 0.9),
      _Term('nervous', 0.8),
      _Term('worried', 0.8),
      _Term('afraid', 0.8),
      _Term('panic', 0.9),
    ],
    EmotionLabel.tired: <_Term>[
      _Term('好累', 0.9),
      _Term('很累', 0.9),
      _Term('累死', 0.9),
      _Term('累', 0.7),
      _Term('疲惫', 0.8),
      _Term('困了', 0.7),
      _Term('好困', 0.8),
      _Term('很困', 0.8),
      _Term('想睡', 0.7),
      _Term('熬夜', 0.6),
      _Term('撑不住', 0.8),
      _Term('没力气', 0.7),
      _Term('头疼', 0.5),
      _Term('tired', 0.9),
      _Term('exhausted', 1.0),
      _Term('sleepy', 0.7),
      _Term('drained', 0.8),
    ],
  };

  static const Map<EmotionLabel, double> _baseArousal =
      <EmotionLabel, double>{
    EmotionLabel.joy: 0.65,
    EmotionLabel.calm: 0.25,
    EmotionLabel.sad: 0.35,
    EmotionLabel.angry: 0.8,
    EmotionLabel.anxious: 0.7,
    EmotionLabel.tired: 0.25,
    EmotionLabel.neutral: 0.3,
  };

  /// 否定词反转后，把原类别映射到语义上最近的类别，避免出现
  /// 「愉快 + 负效价」这种自相矛盾的标签。
  static const Map<EmotionLabel, EmotionLabel> _inverted =
      <EmotionLabel, EmotionLabel>{
    EmotionLabel.joy: EmotionLabel.sad,
    EmotionLabel.calm: EmotionLabel.anxious,
    EmotionLabel.sad: EmotionLabel.calm,
    EmotionLabel.angry: EmotionLabel.calm,
    EmotionLabel.anxious: EmotionLabel.calm,
    EmotionLabel.tired: EmotionLabel.calm,
  };

  static const List<String> _zhNegators = <String>['不', '没', '别', '无', '非'];

  static const Set<String> _enNegators = <String>{
    'not',
    'never',
    'no',
    'none',
    'nobody',
    'nothing',
    'dont',
    "don't",
    "didn't",
    "isn't",
    "aren't",
    "wasn't",
    "weren't",
    "can't",
    "won't",
    'cannot',
    'hardly',
  };

  /// 分析一条文本：命中词按权重累加，否定词翻转邻近词极性，
  /// 问号 / 感叹号只轻微抬高 arousal。空文本或无命中返回
  /// [EmotionReading.neutral]（confidence 0），不推测。
  static EmotionReading analyze(String text) {
    final String raw = text.trim();
    if (raw.isEmpty) return EmotionReading.neutral;
    final String lower = raw.toLowerCase();

    final Map<EmotionLabel, double> scores = <EmotionLabel, double>{};
    final List<String> hits = <String>[];
    for (final MapEntry<EmotionLabel, List<_Term>> entry in _terms.entries) {
      for (final _Term term in entry.value) {
        var from = 0;
        while (true) {
          final int at = lower.indexOf(term.text, from);
          if (at < 0) break;
          // 英文词条按单词边界匹配，避免 down 命中 download、mad 命中 made。
          if (!_wordBoundary(lower, term.text, at)) {
            from = at + term.text.length;
            continue;
          }
          final bool negated = _negatedAt(lower, at);
          final double delta = negated ? -term.weight : term.weight;
          scores.update(
            entry.key,
            (double v) => v + delta,
            ifAbsent: () => delta,
          );
          final String hit = negated ? '不·${term.text}' : term.text;
          if (!hits.contains(hit)) hits.add(hit);
          from = at + term.text.length;
        }
      }
    }
    if (scores.isEmpty) return EmotionReading.neutral;

    var bestAbs = 0.0;
    var bestSigned = 0.0;
    EmotionLabel best = EmotionLabel.neutral;
    for (final MapEntry<EmotionLabel, double> entry in scores.entries) {
      if (entry.value.abs() > bestAbs) {
        bestAbs = entry.value.abs();
        bestSigned = entry.value;
        best = entry.key;
      }
    }
    // 正负证据完全抵消：如实返回中性，不强行贴标签。
    if (bestAbs < 0.05) {
      return EmotionReading(
        label: EmotionLabel.neutral,
        valence: 0,
        arousal: _baseArousal[EmotionLabel.neutral]!,
        confidence: 0,
        hits: hits,
      );
    }

    // 只有「否定后的负分」才需要映射到语义相反类别；正常的负向情绪
    // （难过/生气/焦虑）分数为正，不能被误当成否定。
    final bool negatedLabel = bestSigned < 0;
    final EmotionLabel label =
        negatedLabel ? (_inverted[best] ?? best) : best;

    final int exclamations = _count(text, '!') + _count(text, '！');
    final int questions = _count(text, '?') + _count(text, '？');
    final double arousal = _clamp01(
      (_baseArousal[label] ?? 0.3) +
          exclamations.clamp(0, 3).toDouble() * 0.06 +
          questions.clamp(0, 3).toDouble() * 0.03,
    );

    final double magnitude = (bestAbs / 2.0).clamp(0.0, 1.0).toDouble();
    // 效价符号必须跟最终标签一致：难过/生气/焦虑/疲惫为负，愉快/平静为正。
    final bool negativeLabel = label == EmotionLabel.sad ||
        label == EmotionLabel.angry ||
        label == EmotionLabel.anxious ||
        label == EmotionLabel.tired;
    return EmotionReading(
      label: label,
      valence: _clampSigned(negativeLabel ? -magnitude : magnitude),
      arousal: arousal,
      confidence: _clamp01(
        0.3 + (bestAbs * 0.25).clamp(0.0, 0.65).toDouble(),
      ),
      hits: hits,
    );
  }

  /// 英文词条要求左右不是字母；中文词条按子串匹配。
  static bool _wordBoundary(String text, String term, int at) {
    if (!RegExp(r'^[a-z]+$').hasMatch(term)) return true;
    if (at > 0 && _isAsciiLetter(text.codeUnitAt(at - 1))) return false;
    final int end = at + term.length;
    if (end < text.length && _isAsciiLetter(text.codeUnitAt(end))) {
      return false;
    }
    return true;
  }

  static bool _isAsciiLetter(int code) =>
      (code >= 0x61 && code <= 0x7a) || (code >= 0x41 && code <= 0x5a);

  /// 判断 [index] 前的邻近窗口是否存在否定词；同句标点截断，避免跨句误判。
  static bool _negatedAt(String text, int index) {
    final int start = index - 16 < 0 ? 0 : index - 16;
    String window = text.substring(start, index);
    final int cut = window.lastIndexOf(RegExp(r'[，,。.;；!！?？、\n]'));
    if (cut >= 0) window = window.substring(cut + 1);

    var count = 0;
    for (final String negator in _zhNegators) {
      var from = 0;
      while (true) {
        final int at = window.indexOf(negator, from);
        if (at < 0) break;
        // 「特别」「不错」「不但」不是否定。
        if (negator == '别' && at > 0 && window[at - 1] == '特') {
          from = at + negator.length;
          continue;
        }
        if (negator == '不' &&
            at + 1 < window.length &&
            (window[at + 1] == '错' || window[at + 1] == '但')) {
          from = at + negator.length;
          continue;
        }
        count++;
        from = at + negator.length;
      }
    }
    final List<String> words = window.split(RegExp(r"[^a-z']+"));
    for (final String word in words) {
      if (_enNegators.contains(word)) count++;
    }
    return count.isOdd;
  }

  static int _count(String text, String char) {
    var n = 0;
    var from = 0;
    while (true) {
      final int at = text.indexOf(char, from);
      if (at < 0) return n;
      n++;
      from = at + char.length;
    }
  }
}

/// 情绪连续状态：EMA 平滑 + 最近 20 条历史 + 真实落盘。
///
/// 新读数权重 0.35、旧状态 0.65，使单条消息不会让情绪跳变；标签取本轮
/// 置信度更高者，低置信度的中性消息不改变状态（保持连贯）。状态写入
/// `presence/emotion_state.json`；文件损坏或缺失时回退中性，不伪造。
class EmotionContinuity {
  EmotionContinuity({HarnessStore? store, EmotionReading? initial})
      : _store = store,
        current = initial ?? EmotionReading.neutral;

  static const String filePath = 'presence/emotion_state.json';
  static const int maxHistory = 20;
  static const double newWeight = 0.35;
  static const double oldWeight = 0.65;

  final HarnessStore? _store;

  EmotionReading current;
  final List<EmotionReading> history = <EmotionReading>[];
  DateTime updatedAt = DateTime.now();

  Future<void> _pendingSave = Future<void>.value();

  /// 从磁盘恢复；任何异常都回退到中性状态，不阻断对话。
  static Future<EmotionContinuity> load(HarnessStore? store) async {
    final EmotionContinuity c = EmotionContinuity(store: store);
    if (store == null) return c;
    try {
      final Map<String, dynamic> doc = await store.readJson(filePath);
      if (doc.isEmpty) return c;
      final dynamic rawCurrent = doc['current'];
      if (rawCurrent is Map) {
        final EmotionReading? reading = EmotionReading.fromJson(
          rawCurrent.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        );
        if (reading != null) c.current = reading;
      }
      final dynamic rawHistory = doc['history'];
      if (rawHistory is List) {
        for (final dynamic item in rawHistory) {
          if (item is! Map) continue;
          final EmotionReading? reading = EmotionReading.fromJson(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          );
          if (reading != null) c.history.add(reading);
        }
        if (c.history.length > maxHistory) {
          c.history.removeRange(0, c.history.length - maxHistory);
        }
      }
      final DateTime? at =
          DateTime.tryParse((doc['updatedAt'] ?? '').toString());
      if (at != null) c.updatedAt = at;
    } on Object {
      // 损坏的状态不冒充数据，保持中性。
    }
    return c;
  }

  /// 用新读数更新连续状态：EMA 平滑 valence / arousal，
  /// 标签取置信度更高者；confidence 为 0 的读数视为无证据，直接忽略。
  EmotionReading update(EmotionReading reading) {
    if (reading.confidence <= 0) return current;
    final EmotionLabel label =
        reading.confidence >= current.confidence ? reading.label : current.label;
    current = EmotionReading(
      label: label,
      valence: _clampSigned(
        reading.valence * newWeight + current.valence * oldWeight,
      ),
      arousal: _clamp01(
        reading.arousal * newWeight + current.arousal * oldWeight,
      ),
      confidence: _clamp01(reading.confidence),
      hits: List<String>.of(reading.hits),
    );
    history.add(current);
    if (history.length > maxHistory) {
      history.removeRange(0, history.length - maxHistory);
    }
    updatedAt = DateTime.now();
    unawaited(_persist());
    return current;
  }

  /// 时间衰减：每次向中性回退 10%，长期没有新证据时情绪自然平复。
  EmotionReading decay() {
    final double valence = _clampSigned(current.valence * 0.9);
    final double confidence = _clamp01(current.confidence * 0.9);
    final EmotionLabel label =
        confidence < 0.15 || valence.abs() < 0.08
            ? EmotionLabel.neutral
            : current.label;
    current = EmotionReading(
      label: label,
      valence: valence,
      arousal: _clamp01(current.arousal + (0.3 - current.arousal) * 0.1),
      confidence: confidence,
      hits: const <String>[],
    );
    updatedAt = DateTime.now();
    unawaited(_persist());
    return current;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'current': current.toJson(),
        'history':
            history.map((EmotionReading r) => r.toJson()).toList(growable: false),
        'updatedAt': updatedAt.toIso8601String(),
      };

  Future<void> _persist() {
    final HarnessStore? store = _store;
    if (store == null) return _pendingSave;
    _pendingSave = _pendingSave.then((_) async {
      try {
        await store.writeJson(filePath, toJson());
      } on Object {
        // 落盘失败不阻断交互；内存态仍然正确。
      }
    });
    return _pendingSave;
  }

  /// 等待已排队的写入完成（测试与退出前使用）。
  Future<void> flush() => _pendingSave;

  /// 注入系统提示词的中文约束：当前情绪、能量与边界。
  String summaryBlock() {
    final int energy = (current.arousal * 100).round();
    final StringBuffer b = StringBuffer('【情绪连续】\n');
    b.writeln(
      '当前情绪：${current.label.label}'
      '（效价 ${_signed(current.valence)}，能量 $energy%，'
      '置信度 ${(current.confidence * 100).round()}%）。',
    );
    b.writeln('保持连贯：不要因一句话突然反转语气，情绪随对话逐步过渡。');
    b.writeln('能量约束：${_energyHint(current.arousal)}');
    b.writeln('可以简短承接感受，但避免过度共情、说教或替用户下结论；不推测病因。');
    b.write('注意：情绪判断来自关键词启发式，只是交互风格提示，不是心理诊断。');
    return b.toString();
  }

  static String _energyHint(double arousal) {
    if (arousal >= 0.65) {
      return '当前能量偏高，可适度展开，但保持节奏与边界。';
    }
    if (arousal >= 0.4) {
      return '当前能量中等，先回应要点，再补充必要细节。';
    }
    return '当前能量偏低，回复更短、分步给结论，必要时提醒用户休息。';
  }

  static String _signed(double v) {
    final String fixed = v.toStringAsFixed(2);
    return v > 0 ? '+$fixed' : fixed;
  }
}

double _clamp01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

double _clampSigned(double v) => v < -1 ? -1.0 : (v > 1 ? 1.0 : v);

double _asDouble(dynamic v, double fallback) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? fallback;
  return fallback;
}
