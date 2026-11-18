/// 分层解释 / 因材施教 —— 按用户水平调整讲解深度的纯 Dart 层。
///
/// - [ExplanationLevelPref]：偏好真实落盘到 `prefs/explanation_level.json`，
///   文件缺失或损坏时回退 [AudienceLevel.auto]，绝不冒充已保存的配置。
/// - [AudienceDetector]：用户显式选择优先；自动模式下按提问关键词判断，
///   无信号时保持 auto（由模型自行判断，不硬套某一层级）。
/// - [ExplanationStyle]：为每一级给出真实的系统提示词片段；只描述讲解方式
///   与必须遵守的诚实边界，不承诺本模块做不到的事。

import 'store.dart';

/// 讲解层级：自动判断 / 新手 / 开发者 / 交易者 / 创作者。
enum AudienceLevel {
  auto('自动'),
  novice('新手'),
  developer('开发者'),
  trader('交易者'),
  creator('创作者');

  const AudienceLevel(this.label);
  final String label;

  static AudienceLevel? tryParse(String raw) {
    for (final AudienceLevel level in values) {
      if (level.name == raw) return level;
    }
    return null;
  }
}

/// 讲解层级偏好的持久化。
abstract final class ExplanationLevelPref {
  static const String _path = 'prefs/explanation_level.json';

  /// 读取偏好；文件缺失、损坏或取值未知时回退 [AudienceLevel.auto]。
  static Future<AudienceLevel> load(HarnessStore store) async {
    final Map<String, dynamic> doc = await store.readJson(_path);
    final String raw = (doc['level'] ?? '').toString();
    return AudienceLevel.tryParse(raw) ?? AudienceLevel.auto;
  }

  /// 写入偏好；真实落盘成功返回 true，失败返回 false（不抛异常）。
  static Future<bool> save(HarnessStore store, AudienceLevel level) async {
    try {
      await store.writeJson(_path, <String, dynamic>{'level': level.name});
      return true;
    } on Object {
      return false;
    }
  }
}

/// 用户水平识别：显式偏好优先，其次按文本关键词判定。
abstract final class AudienceDetector {
  static const List<String> _developer = <String>[
    '代码', '编译', 'api', 'dart', 'python',
  ];
  static const List<String> _trader = <String>[
    '回测', '仓位', '止损', '策略',
  ];
  static const List<String> _creator = <String>[
    '剪辑', '分镜', '文案', '账号',
  ];
  static const List<String> _novice = <String>[
    '怎么用', '新手', '入门', '是什么',
  ];

  /// [preferred] 不是 auto 时直接采纳用户选择；否则按关键词判定，
  /// 多类信号并存时按 开发者 → 交易者 → 创作者 → 新手 的优先级取首个，
  /// 完全没有信号则返回 auto。
  static AudienceLevel detect(
    String text, {
    AudienceLevel preferred = AudienceLevel.auto,
  }) {
    if (preferred != AudienceLevel.auto) return preferred;
    final String lower = text.toLowerCase();
    bool hit(List<String> words) =>
        words.any((String w) => lower.contains(w));
    if (hit(_developer)) return AudienceLevel.developer;
    if (hit(_trader)) return AudienceLevel.trader;
    if (hit(_creator)) return AudienceLevel.creator;
    if (hit(_novice)) return AudienceLevel.novice;
    return AudienceLevel.auto;
  }
}

/// 每一级的系统提示词片段（真实约束，注入 system 末尾）。
abstract final class ExplanationStyle {
  static String hint(AudienceLevel level) {
    switch (level) {
      case AudienceLevel.novice:
        return '【讲解层级·新手】先用生活类比说明「这是什么、为什么重要」，'
            '再给按顺序可执行的步骤；少用术语，必须使用时用一句话解释。'
            '不堆参数表和技术细节；不确定的事直接说不确定，禁止编造事实。';
      case AudienceLevel.developer:
        return '【讲解层级·开发者】给出可直接使用的细节：关键参数与默认值、'
            '涉及的文件路径、可执行的命令，以及源码位置（文件:行号）。'
            '注明版本与前置条件；无法核实的接口或路径明确说明未核实，'
            '禁止编造 API 与文件位置。';
      case AudienceLevel.trader:
        return '【讲解层级·交易者】围绕可量化指标展开：收益/风险指标、'
            '最大回撤、仓位与止损设置、样本区间与假设条件。'
            '说明策略失效场景与合规边界，明确这不构成投资建议；'
            '不编造行情或回测数据。';
      case AudienceLevel.creator:
        return '【讲解层级·创作者】按可直接拍摄/制作的粒度给方案：'
            '分镜或镜头顺序、节奏与时长、画面与文案要点、素材清单（含 BGM/字幕）。'
            '标注平台规则与版权风险；不编造平台数据或规则。';
      case AudienceLevel.auto:
        return '【讲解层级·自动】先根据用户的用词、提问方式与上下文判断其水平'
            '（新手/开发者/交易者/创作者），再调整解释深度与术语密度；'
            '信号不足时先给结论与最小可用步骤，并主动询问需要更简单还是更技术。'
            '切换深度时结论保持一致，禁止编造事实。';
    }
  }
}
