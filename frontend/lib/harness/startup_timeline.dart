/// 启动耗时可观测底座 —— 纯 Dart，不依赖 Flutter。
///
/// 在真实关键路径上按阶段打点（mark），记录「从上一个打点到当前」的耗时，
/// 并结合预算判定哪些阶段超时。数据只来自真实时钟，不采样、不编造。
library;

/// 一个启动阶段：名称、起始毫秒、耗时、预算与是否后台阶段。
class StartupStage {
  const StartupStage({
    required this.name,
    required this.startedAtMs,
    required this.durationMs,
    this.budgetMs = 0,
    this.background = false,
  });

  final String name;
  final int startedAtMs;
  final int durationMs;
  final int budgetMs;
  final bool background;

  /// 只有显式给了正预算且真实耗时超出才算超预算。
  bool get overBudget => budgetMs > 0 && durationMs > budgetMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'started_at_ms': startedAtMs,
        'duration_ms': durationMs,
        'budget_ms': budgetMs,
        'background': background,
      };
}

/// 启动时间线：可注入时钟，记录各阶段耗时并生成结构化报告。
class StartupTimeline {
  StartupTimeline({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// 进程内全局实例：Android 启动链路与 rpc perf 共用同一份打点。
  static final StartupTimeline global = StartupTimeline();

  final DateTime Function() _clock;
  final List<StartupStage> _stages = <StartupStage>[];
  int? _lastMarkMs;

  /// 记录一个阶段。耗时 = 本阶段打点时刻与上一个打点时刻的差值；
  /// 首个阶段没有前一个打点，耗时为 0。
  void mark(String name, {int budgetMs = 0, bool background = false}) {
    final int nowMs = _clock().millisecondsSinceEpoch;
    final int startedAtMs = _lastMarkMs ?? nowMs;
    final int durationMs = _lastMarkMs == null ? 0 : nowMs - _lastMarkMs!;
    _stages.add(StartupStage(
      name: name,
      startedAtMs: startedAtMs,
      durationMs: durationMs,
      budgetMs: budgetMs,
      background: background,
    ));
    _lastMarkMs = nowMs;
  }

  /// 结构化报告：阶段明细 + 总耗时 + 超预算阶段名。
  Map<String, dynamic> report() {
    final List<Map<String, dynamic>> stages =
        _stages.map((StartupStage s) => s.toJson()).toList();
    int totalMs = 0;
    for (final StartupStage s in _stages) {
      totalMs += s.durationMs;
    }
    final List<String> overBudget = _stages
        .where((StartupStage s) => s.overBudget)
        .map((StartupStage s) => s.name)
        .toList();
    return <String, dynamic>{
      'stages': stages,
      'total_ms': totalMs,
      'over_budget': overBudget,
    };
  }

  /// 清空打点，重新开始计时。
  void reset() {
    _stages.clear();
    _lastMarkMs = null;
  }
}
