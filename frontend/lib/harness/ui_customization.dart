/// Tangram 全栈 UI 自定义 —— 可持久化的主题 / 布局配置层。
///
/// 只提供**配置数据 + 纯函数映射**，不直接改 MaterialApp：调用方读取 [apply]
/// 的返回值 / [applyUiCustomizationTheme] 的结果自行消费；本模块绝不覆盖现有
/// Tga 设计系统，也不注入全局主题单例。
///
/// 持久化：`ui_customization.json`（经 [HarnessStore] 原子写盘），结构为
/// `{version, active_scope, global, project}`。project 未保存时 [apply]
/// 回退到 global，绝不返回半个配置。
///
/// 校验原则：类型错误、未知枚举、空可见导航项一律拒绝（import 返回
/// `ok=false` 且不改状态）；数值越界（fontScale / radius）真实 clamp。

import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:tangram/harness/store.dart';

/// 主色预设（蓝 / 青 / 紫 / 金 / 绿）。
enum UiAccentPreset {
  blue('蓝'),
  cyan('青'),
  purple('紫'),
  gold('金'),
  green('绿');

  const UiAccentPreset(this.label);
  final String label;

  static UiAccentPreset? tryParse(String raw) {
    for (final UiAccentPreset p in values) {
      if (p.name == raw) return p;
    }
    return null;
  }
}

/// 表面预设：云雾白 / 极夜黑 / 自动（跟随系统亮度）。
enum UiSurfacePreset {
  mist('云雾白'),
  midnight('极夜黑'),
  auto('自动');

  const UiSurfacePreset(this.label);
  final String label;

  static UiSurfacePreset? tryParse(String raw) {
    for (final UiSurfacePreset p in values) {
      if (p.name == raw) return p;
    }
    return null;
  }
}

/// 信息密度：紧凑 / 舒适 / 宽松。
enum UiDensity {
  compact('紧凑'),
  comfortable('舒适'),
  spacious('宽松');

  const UiDensity(this.label);
  final String label;

  static UiDensity? tryParse(String raw) {
    for (final UiDensity d in values) {
      if (d.name == raw) return d;
    }
    return null;
  }
}

/// 配置作用域：全局 / 当前项目。
enum UiScope {
  global('全局'),
  project('项目');

  const UiScope(this.label);
  final String label;

  static UiScope? tryParse(String raw) {
    for (final UiScope s in values) {
      if (s.name == raw) return s;
    }
    return null;
  }
}

/// 一份完整的界面配置。字段全部为纯数据，可直接 JSON 往返。
class UiCustomizationConfig {
  const UiCustomizationConfig({
    required this.accentPreset,
    required this.surfacePreset,
    required this.fontScale,
    required this.density,
    required this.radius,
    required this.sidebarGrouping,
    required this.visibleNavKeys,
    required this.composerFloating,
    required this.scope,
    required this.themePackVersion,
  });

  static const double minFontScale = 0.85;
  static const double maxFontScale = 1.4;
  static const double minRadius = 4;
  static const double maxRadius = 24;
  static const int defaultThemePackVersion = 1;

  /// 与侧栏真实导航基线（workspace_sections.dart）一一对应的 key。
  /// 本模块只做配置，不新增/删除导航；未知 key 在导入时被过滤。
  /// 顺序与 [buildWorkspaceNavItems] 的声明顺序保持一致。
  static const List<String> knownNavKeys = <String>[
    'sidebar.training',
    'sidebar.persona',
    'sidebar.sandbox',
    'sidebar.sunRun',
    'sidebar.store',
    'sidebar.workspace',
    'sidebar.knowledge',
    'sidebar.workflow',
    'sidebar.pages',
    'sidebar.snapshot',
    'sidebar.experience',
    'sidebar.appMarket',
    'sidebar.creator',
    'sidebar.customize',
    'sidebar.uiPlugins',
    'sidebar.imageStudio',
    'sidebar.videoStudio',
    'sidebar.model3d',
    'sidebar.channels',
    'sidebar.models',
    'sidebar.groupChat',
    'sidebar.team',
    'sidebar.computer',
    'sidebar.integration',
    'sidebar.accountOps',
    'sidebar.graph',
    'sidebar.mapping',
    'sidebar.cognition',
    'sidebar.compute',
    'sidebar.security',
    'sidebar.performance',
  ];

  static const Map<String, String> navLabels = <String, String>{
    'sidebar.training': '训练设置',
    'sidebar.persona': '人格设置',
    'sidebar.sandbox': '内置沙箱',
    'sidebar.sunRun': '爱阳光跑',
    'sidebar.store': '模型商店',
    'sidebar.workspace': '工作区域',
    'sidebar.mapping': '目录映射',
    'sidebar.knowledge': '私有知识库',
    'sidebar.workflow': '自动化工作流',
    'sidebar.pages': 'Agent Pages',
    'sidebar.snapshot': '快照备份',
    'sidebar.experience': '经验库',
    'sidebar.cognition': '认知决策',
    'sidebar.compute': '算力调度',
    'sidebar.security': '安全中心',
    'sidebar.performance': '性能诊断',
    'sidebar.appMarket': '应用市场',
    'sidebar.creator': 'Creator 创造',
    'sidebar.customize': '界面自定义',
    'sidebar.uiPlugins': 'UI 插件槽',
    'sidebar.imageStudio': '画图',
    'sidebar.videoStudio': '视频工作室',
    'sidebar.model3d': '3D 建模',
    'sidebar.channels': '更多通信',
    'sidebar.models': '模型管理',
    'sidebar.groupChat': '多模型群聊',
    'sidebar.team': '团队协作',
    'sidebar.computer': '团队电脑',
    'sidebar.integration': '集成接入',
    'sidebar.accountOps': '账号运营',
    'sidebar.graph': '知识图谱',
  };

  final UiAccentPreset accentPreset;
  final UiSurfacePreset surfacePreset;
  final double fontScale;
  final UiDensity density;
  final double radius;
  final bool sidebarGrouping;
  final List<String> visibleNavKeys;
  final bool composerFloating;
  final UiScope scope;
  final int themePackVersion;

  factory UiCustomizationConfig.defaults({UiScope scope = UiScope.global}) =>
      UiCustomizationConfig(
        accentPreset: UiAccentPreset.blue,
        surfacePreset: UiSurfacePreset.auto,
        fontScale: 1,
        density: UiDensity.comfortable,
        radius: 16,
        // 默认沿用「按业务分组」的既有侧栏形态；用户可显式切到平铺。
        sidebarGrouping: true,
        visibleNavKeys: knownNavKeys,
        composerFloating: false,
        scope: scope,
        themePackVersion: defaultThemePackVersion,
      );

  static double clampFontScale(num value) {
    if (value.isNaN) return 1;
    return value.toDouble().clamp(minFontScale, maxFontScale).toDouble();
  }

  static double clampRadius(num value) {
    if (value.isNaN) return 16;
    return value.toDouble().clamp(minRadius, maxRadius).toDouble();
  }

  UiCustomizationConfig copyWith({
    UiAccentPreset? accentPreset,
    UiSurfacePreset? surfacePreset,
    double? fontScale,
    UiDensity? density,
    double? radius,
    bool? sidebarGrouping,
    List<String>? visibleNavKeys,
    bool? composerFloating,
    UiScope? scope,
    int? themePackVersion,
  }) => UiCustomizationConfig(
    accentPreset: accentPreset ?? this.accentPreset,
    surfacePreset: surfacePreset ?? this.surfacePreset,
    fontScale: fontScale == null ? this.fontScale : clampFontScale(fontScale),
    density: density ?? this.density,
    radius: radius == null ? this.radius : clampRadius(radius),
    sidebarGrouping: sidebarGrouping ?? this.sidebarGrouping,
    visibleNavKeys: visibleNavKeys == null
        ? this.visibleNavKeys
        : List<String>.unmodifiable(visibleNavKeys),
    composerFloating: composerFloating ?? this.composerFloating,
    scope: scope ?? this.scope,
    themePackVersion: themePackVersion ?? this.themePackVersion,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'accentPreset': accentPreset.name,
    'surfacePreset': surfacePreset.name,
    'fontScale': fontScale,
    'density': density.name,
    'radius': radius,
    'sidebarGrouping': sidebarGrouping,
    'visibleNavKeys': List<String>.of(visibleNavKeys),
    'composerFloating': composerFloating,
    'scope': scope.name,
    'themePackVersion': themePackVersion,
  };

  /// 严格解析：类型错误 / 未知枚举 / 空导航抛 [FormatException]。
  /// 数值型 fontScale / radius 越界按 clamp 处理，不视为非法。
  static UiCustomizationConfig fromJson(Map<String, dynamic> json) {
    UiAccentPreset accent = UiAccentPreset.blue;
    final Object? accentRaw = json['accentPreset'];
    if (accentRaw != null) {
      if (accentRaw is! String) {
        throw const FormatException('accentPreset 必须是字符串');
      }
      final UiAccentPreset? parsed = UiAccentPreset.tryParse(accentRaw);
      if (parsed == null) {
        throw FormatException('未知 accentPreset：$accentRaw');
      }
      accent = parsed;
    }

    UiSurfacePreset surface = UiSurfacePreset.auto;
    final Object? surfaceRaw = json['surfacePreset'];
    if (surfaceRaw != null) {
      if (surfaceRaw is! String) {
        throw const FormatException('surfacePreset 必须是字符串');
      }
      final UiSurfacePreset? parsed = UiSurfacePreset.tryParse(surfaceRaw);
      if (parsed == null) {
        throw FormatException('未知 surfacePreset：$surfaceRaw');
      }
      surface = parsed;
    }

    double fontScale = 1;
    final Object? fontRaw = json['fontScale'];
    if (fontRaw != null) {
      if (fontRaw is! num) throw const FormatException('fontScale 必须是数字');
      fontScale = clampFontScale(fontRaw);
    }

    UiDensity density = UiDensity.comfortable;
    final Object? densityRaw = json['density'];
    if (densityRaw != null) {
      if (densityRaw is! String) {
        throw const FormatException('density 必须是字符串');
      }
      final UiDensity? parsed = UiDensity.tryParse(densityRaw);
      if (parsed == null) throw FormatException('未知 density：$densityRaw');
      density = parsed;
    }

    double radius = 16;
    final Object? radiusRaw = json['radius'];
    if (radiusRaw != null) {
      if (radiusRaw is! num) throw const FormatException('radius 必须是数字');
      radius = clampRadius(radiusRaw);
    }

    bool sidebarGrouping = true;
    final Object? groupingRaw = json['sidebarGrouping'];
    if (groupingRaw != null) {
      if (groupingRaw is! bool) {
        throw const FormatException('sidebarGrouping 必须是布尔值');
      }
      sidebarGrouping = groupingRaw;
    }

    bool composerFloating = false;
    final Object? composerRaw = json['composerFloating'];
    if (composerRaw != null) {
      if (composerRaw is! bool) {
        throw const FormatException('composerFloating 必须是布尔值');
      }
      composerFloating = composerRaw;
    }

    List<String> visibleNavKeys = knownNavKeys;
    final Object? navRaw = json['visibleNavKeys'];
    if (navRaw != null) {
      if (navRaw is! List) {
        throw const FormatException('visibleNavKeys 必须是字符串数组');
      }
      final List<String> filtered = <String>[];
      for (final Object? item in navRaw) {
        if (item is! String) {
          throw const FormatException('visibleNavKeys 只能包含字符串');
        }
        if (knownNavKeys.contains(item) && !filtered.contains(item)) {
          filtered.add(item);
        }
      }
      if (filtered.isEmpty) {
        throw const FormatException('可见导航项不能为空，且必须包含已知导航 key');
      }
      visibleNavKeys = List<String>.unmodifiable(filtered);
    }

    UiScope scope = UiScope.global;
    final Object? scopeRaw = json['scope'];
    if (scopeRaw != null) {
      if (scopeRaw is! String) throw const FormatException('scope 必须是字符串');
      final UiScope? parsed = UiScope.tryParse(scopeRaw);
      if (parsed == null) throw FormatException('未知 scope：$scopeRaw');
      scope = parsed;
    }

    int themePackVersion = defaultThemePackVersion;
    final Object? versionRaw = json['themePackVersion'];
    if (versionRaw != null) {
      if (versionRaw is! num || versionRaw < 1) {
        throw const FormatException('themePackVersion 必须是 >=1 的整数');
      }
      themePackVersion = versionRaw.toInt();
    }

    return UiCustomizationConfig(
      accentPreset: accent,
      surfacePreset: surface,
      fontScale: fontScale,
      density: density,
      radius: radius,
      sidebarGrouping: sidebarGrouping,
      visibleNavKeys: visibleNavKeys,
      composerFloating: composerFloating,
      scope: scope,
      themePackVersion: themePackVersion,
    );
  }
}

// ---------------------------------------------------------------------------
// 主题应用（纯函数：无 IO、无全局副作用，便于单测）
// ---------------------------------------------------------------------------

/// 展示层字号缩放的硬边界（配置允许到 1.4，应用时收敛到 1.35 更稳）。
const double minAppliedFontScale = 0.85;
const double maxAppliedFontScale = 1.35;

/// 主色预设 → 真实色值（与产品约定的主色一致）。
Color uiAccentColor(UiAccentPreset preset) => switch (preset) {
  UiAccentPreset.blue => const Color(0xFF4A90D9),
  UiAccentPreset.cyan => const Color(0xFF2FB3AE),
  UiAccentPreset.purple => const Color(0xFF8B5CF6),
  UiAccentPreset.gold => const Color(0xFFD97706),
  UiAccentPreset.green => const Color(0xFF059669),
};

/// 配置字体缩放 → 实际应用值（0.85–1.35）。
double uiAppliedFontScale(num value) {
  if (value.isNaN) return 1;
  return value
      .toDouble()
      .clamp(minAppliedFontScale, maxAppliedFontScale)
      .toDouble();
}

/// 系统缩放 × 配置缩放，再做整体 clamp，避免超大字号把布局撑破。
double uiEffectiveTextScale(num systemScale, num fontScale) {
  final double system = (systemScale.isFinite && systemScale > 0)
      ? systemScale.toDouble()
      : 1;
  return (system * uiAppliedFontScale(fontScale))
      .clamp(minAppliedFontScale, maxAppliedFontScale)
      .toDouble();
}

/// 配置圆角 → 实际应用值（4–24）。
double uiAppliedRadius(num value) {
  if (value.isNaN) return 16;
  return value
      .toDouble()
      .clamp(UiCustomizationConfig.minRadius, UiCustomizationConfig.maxRadius)
      .toDouble();
}

/// 信息密度 → VisualDensity 数值：compact 2 / comfortable 0 / spacious -1。
double uiVisualDensityValue(UiDensity density) => switch (density) {
  UiDensity.compact => 2.0,
  UiDensity.comfortable => 0.0,
  UiDensity.spacious => -1.0,
};

/// 表面预设 → 强制亮度；null 表示跟随系统（由 PersonaStore / 系统决定）。
Brightness? uiForcedBrightness(UiSurfacePreset preset) => switch (preset) {
  UiSurfacePreset.mist => Brightness.light,
  UiSurfacePreset.midnight => Brightness.dark,
  UiSurfacePreset.auto => null,
};

/// 把 UI 自定义真实落到一份 [ThemeData] 上：强调色 / 信息密度 / 卡片与按钮圆角。
///
/// 只覆盖强调色与几何尺寸，不改底色与文字色板——深浅仍由 PersonaStore
/// 决定（冲突规则见 app.dart 顶部注释），因此不会破坏既有主题。
ThemeData applyUiCustomizationTheme(
  ThemeData base,
  UiCustomizationConfig config,
) {
  final Color accent = uiAccentColor(config.accentPreset);
  final Color onAccent =
      ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
      ? Colors.white
      : Colors.black;
  final RoundedRectangleBorder shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(uiAppliedRadius(config.radius)),
  );
  final double density = uiVisualDensityValue(config.density);
  return base.copyWith(
    colorScheme: base.colorScheme.copyWith(
      primary: accent,
      onPrimary: onAccent,
      secondary: accent,
      onSecondary: onAccent,
      tertiary: accent,
    ),
    visualDensity: VisualDensity(horizontal: density, vertical: density),
    // 用 copyWith 保留既有卡片/按钮主题的其它属性，只替换圆角。
    cardTheme: base.cardTheme.copyWith(shape: shape),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: shape),
    ),
  );
}

class _ParsedDocument {
  _ParsedDocument(this.scope, this.global, this.project, this.draft);
  final UiScope scope;
  final UiCustomizationConfig global;
  final UiCustomizationConfig? project;
  final UiCustomizationConfig draft;
}

/// UI 自定义配置仓库：加载 / 编辑 / 保存 / 导入导出 / 作用域生效。
class UiCustomizationStore extends ChangeNotifier {
  UiCustomizationStore._(
    this.store,
    this._currentScope,
    this._globalConfig,
    this._projectConfig,
    this._draft,
    this.loadError,
  );

  static const String fileName = 'ui_customization.json';

  final HarnessStore store;
  final String loadError;

  UiScope _currentScope;
  UiCustomizationConfig _globalConfig;
  UiCustomizationConfig? _projectConfig;
  UiCustomizationConfig _draft;

  /// 最近一次被拒绝的操作原因（空 = 无错误），供页面如实展示。
  String lastError = '';

  /// 不读盘的默认内存态：加载失败 / 超时时立即返回可用配置，绝不阻塞启动。
  /// [loadError] 会在界面自定义页顶部如实展示，不谎称「加载成功」。
  factory UiCustomizationStore.defaults(
    HarnessStore store, {
    String loadError = '',
  }) {
    final UiCustomizationConfig fallback = UiCustomizationConfig.defaults();
    return UiCustomizationStore._(
      store,
      UiScope.global,
      fallback,
      null,
      fallback,
      loadError,
    );
  }

  /// 真实加载；文件不存在用默认值，损坏则回退默认值并在 [loadError] 说明。
  static Future<UiCustomizationStore> load(HarnessStore store) async {
    final UiCustomizationConfig fallback = UiCustomizationConfig.defaults();
    final File file = store.file(fileName);
    if (!await file.exists()) {
      return UiCustomizationStore._(
        store,
        UiScope.global,
        fallback,
        null,
        fallback,
        '',
      );
    }
    try {
      final String raw = await file.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('根节点必须是 JSON 对象');
      }
      final Map<String, dynamic> map = decoded.map(
        (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v),
      );
      final Object? versionRaw = map['version'];
      final int version = versionRaw is num ? versionRaw.toInt() : 1;
      final _ParsedDocument migrated = _migrateDocument(
        _parseDocument(map),
        version,
      );
      // version<3 的旧文档补齐新入口；新文档尊重用户显式隐藏。
      final _ParsedDocument parsed = version >= 3
          ? migrated
          : _appendNewNavKeys(migrated);
      return UiCustomizationStore._(
        store,
        parsed.scope,
        parsed.global,
        parsed.project,
        parsed.draft,
        '',
      );
    } on Object catch (e) {
      return UiCustomizationStore._(
        store,
        UiScope.global,
        fallback,
        null,
        fallback,
        '配置文件损坏，已回退默认值：$e',
      );
    }
  }

  static _ParsedDocument _parseDocument(Map<String, dynamic> raw) {
    final Object? globalRaw = raw['global'];
    if (globalRaw is Map) {
      final UiCustomizationConfig global = UiCustomizationConfig.fromJson(
        globalRaw.map(
          (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v),
        ),
      ).copyWith(scope: UiScope.global);
      UiCustomizationConfig? project;
      final Object? projectRaw = raw['project'];
      if (projectRaw is Map) {
        project = UiCustomizationConfig.fromJson(
          projectRaw.map(
            (dynamic k, dynamic v) =>
                MapEntry<String, dynamic>(k.toString(), v),
          ),
        ).copyWith(scope: UiScope.project);
      }
      final UiScope scope =
          UiScope.tryParse((raw['active_scope'] ?? 'global').toString()) ??
          UiScope.global;
      final UiCustomizationConfig draft = scope == UiScope.project
          ? (project ?? global.copyWith(scope: UiScope.project))
          : global;
      return _ParsedDocument(scope, global, project, draft);
    }
    // 单配置文档：视为全局配置。
    final UiCustomizationConfig single = UiCustomizationConfig.fromJson(
      raw,
    ).copyWith(scope: UiScope.global);
    return _ParsedDocument(UiScope.global, single, null, single);
  }

  /// 旧文档（version<2）的一次性导航迁移：只追加新增入口，保留原有顺序与
  /// 去重，不删除任何项。仅在 [load] 读盘时执行；导入 JSON 是用户显式行为，
  /// 不做隐式补键，避免覆盖导入内容。
  static _ParsedDocument _migrateDocument(_ParsedDocument parsed, int version) {
    if (version >= 2) return parsed;
    final UiCustomizationConfig global = _migrateNavKeys(parsed.global);
    final UiCustomizationConfig? project = parsed.project == null
        ? null
        : _migrateNavKeys(parsed.project!);
    final UiCustomizationConfig draft = parsed.scope == UiScope.project
        ? (project ?? global.copyWith(scope: UiScope.project))
        : global;
    return _ParsedDocument(parsed.scope, global, project, draft);
  }

  /// 读盘时补齐新增入口：老用户升级后仍能看到「爱阳光跑」。
  /// 只在 [load] 生效；显式导入 JSON 不会被隐式补键（导入是用户明确行为）。
  static _ParsedDocument _appendNewNavKeys(_ParsedDocument parsed) {
    final UiCustomizationConfig global = _appendNavKey(
      parsed.global,
      'sidebar.sunRun',
    );
    final UiCustomizationConfig? project = parsed.project == null
        ? null
        : _appendNavKey(parsed.project!, 'sidebar.sunRun');
    final UiCustomizationConfig draft = parsed.scope == UiScope.project
        ? (project ?? global.copyWith(scope: UiScope.project))
        : global;
    return _ParsedDocument(parsed.scope, global, project, draft);
  }

  static UiCustomizationConfig _appendNavKey(
    UiCustomizationConfig config,
    String key,
  ) {
    if (config.visibleNavKeys.isEmpty || config.visibleNavKeys.contains(key)) {
      return config;
    }
    return config.copyWith(
      visibleNavKeys: <String>[...config.visibleNavKeys, key],
    );
  }

  /// 旧版文档迁移：只追加新增入口，保留用户原有顺序与去重，不删除任何项。
  static UiCustomizationConfig _migrateNavKeys(UiCustomizationConfig config) {
    final List<String> keys = List<String>.of(config.visibleNavKeys);
    for (final String key in const <String>[
      'sidebar.security',
      'sidebar.performance',
    ]) {
      if (!keys.contains(key)) keys.add(key);
    }
    if (keys.length == config.visibleNavKeys.length) return config;
    return config.copyWith(visibleNavKeys: keys);
  }

  UiCustomizationConfig get config => _draft;
  UiCustomizationConfig get globalConfig => _globalConfig;
  UiCustomizationConfig? get projectConfig => _projectConfig;
  UiScope get scope => _currentScope;

  /// 生效配置：project 已保存则返回 project，否则真实回退 global。
  UiCustomizationConfig apply(UiScope scope) => scope == UiScope.project
      ? (_projectConfig ?? _globalConfig)
      : _globalConfig;

  void setScope(UiScope scope) {
    if (scope == _currentScope) return;
    _currentScope = scope;
    _draft = scope == UiScope.project
        ? (_projectConfig ?? _globalConfig.copyWith(scope: UiScope.project))
        : _globalConfig;
    lastError = '';
    notifyListeners();
  }

  void setAccent(UiAccentPreset value) {
    _draft = _draft.copyWith(accentPreset: value);
    lastError = '';
    notifyListeners();
  }

  void setSurface(UiSurfacePreset value) {
    _draft = _draft.copyWith(surfacePreset: value);
    lastError = '';
    notifyListeners();
  }

  void setFontScale(double value) {
    _draft = _draft.copyWith(fontScale: value);
    lastError = '';
    notifyListeners();
  }

  void setDensity(UiDensity value) {
    _draft = _draft.copyWith(density: value);
    lastError = '';
    notifyListeners();
  }

  void setRadius(double value) {
    _draft = _draft.copyWith(radius: value);
    lastError = '';
    notifyListeners();
  }

  void setSidebarGrouping(bool value) {
    _draft = _draft.copyWith(sidebarGrouping: value);
    lastError = '';
    notifyListeners();
  }

  void setComposerFloating(bool value) {
    _draft = _draft.copyWith(composerFloating: value);
    lastError = '';
    notifyListeners();
  }

  void setThemePackVersion(int value) {
    _draft = _draft.copyWith(
      themePackVersion: value < 1
          ? UiCustomizationConfig.defaultThemePackVersion
          : value,
    );
    lastError = '';
    notifyListeners();
  }

  /// 批量设置可见导航项。空集合 / 全未知 key 被拒绝且不改状态。
  bool setVisibleNavKeys(List<String> keys) {
    final List<String> filtered = <String>[];
    for (final String key in keys) {
      if (UiCustomizationConfig.knownNavKeys.contains(key) &&
          !filtered.contains(key)) {
        filtered.add(key);
      }
    }
    if (filtered.isEmpty) {
      lastError = '可见导航项不能为空';
      notifyListeners();
      return false;
    }
    _draft = _draft.copyWith(visibleNavKeys: filtered);
    lastError = '';
    notifyListeners();
    return true;
  }

  /// 拖拽调整可见导航顺序；只重排，不增加/删除项。
  bool reorderVisibleNav(int oldIndex, int newIndex) {
    final List<String> next = List<String>.of(_draft.visibleNavKeys);
    if (oldIndex < 0 || oldIndex >= next.length) return false;
    int target = newIndex;
    if (target > oldIndex) target -= 1;
    if (target < 0) target = 0;
    if (target >= next.length) target = next.length - 1;
    if (target == oldIndex) return true;
    final String key = next.removeAt(oldIndex);
    next.insert(target, key);
    _draft = _draft.copyWith(visibleNavKeys: next);
    lastError = '';
    notifyListeners();
    return true;
  }

  /// 切换单个导航项；最后一个可见项不允许关闭（实测反馈不能把侧栏清空）。
  bool toggleNavKey(String key) {
    if (!UiCustomizationConfig.knownNavKeys.contains(key)) {
      lastError = '未知导航 key：$key';
      notifyListeners();
      return false;
    }
    final List<String> next = List<String>.of(_draft.visibleNavKeys);
    if (next.contains(key)) {
      if (next.length == 1) {
        lastError = '至少保留一个可见导航项';
        notifyListeners();
        return false;
      }
      next.remove(key);
    } else {
      next.add(key);
    }
    _draft = _draft.copyWith(visibleNavKeys: next);
    lastError = '';
    notifyListeners();
    return true;
  }

  /// 保存当前作用域的草稿到磁盘。写盘失败会被真实抛出（由调用方提示）。
  Future<bool> save() async {
    final UiCustomizationConfig normalized = _draft.copyWith(
      scope: _currentScope,
    );
    if (normalized.visibleNavKeys.isEmpty) {
      lastError = '可见导航项不能为空';
      notifyListeners();
      return false;
    }
    if (_currentScope == UiScope.global) {
      _globalConfig = normalized;
    } else {
      _projectConfig = normalized;
    }
    _draft = normalized;
    await store.writeJson(fileName, _document());
    lastError = '';
    notifyListeners();
    return true;
  }

  Map<String, dynamic> _document() {
    final UiCustomizationConfig global = _currentScope == UiScope.global
        ? _draft
        : _globalConfig;
    final UiCustomizationConfig? project = _currentScope == UiScope.project
        ? _draft
        : _projectConfig;
    return <String, dynamic>{
      'version': 3,
      'active_scope': _currentScope.name,
      'global': global.toJson(),
      if (project != null) 'project': project.toJson(),
    };
  }

  /// 导出当前文档（含当前作用域草稿），格式化 JSON。
  String exportJson() =>
      const JsonEncoder.withIndent('  ').convert(_document());

  /// 导入 JSON（支持完整文档或单份配置）。校验失败不改任何状态。
  Future<Map<String, dynamic>> importJson(String json) async {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': 'JSON 解析失败：$e'};
    }
    if (decoded is! Map) {
      return <String, dynamic>{'ok': false, 'error': '导入内容必须是 JSON 对象'};
    }
    final Map<String, dynamic> map = decoded.map(
      (dynamic k, dynamic v) => MapEntry<String, dynamic>(k.toString(), v),
    );
    try {
      final _ParsedDocument parsed = _parseDocument(map);
      _globalConfig = parsed.global;
      _projectConfig = parsed.project;
      _currentScope = parsed.scope;
      _draft = parsed.draft;
      await store.writeJson(fileName, _document());
      lastError = '';
      notifyListeners();
      return <String, dynamic>{
        'ok': true,
        'scope': _currentScope.name,
        'visibleNavKeys': List<String>.of(_draft.visibleNavKeys),
      };
    } on FormatException catch (e) {
      return <String, dynamic>{'ok': false, 'error': '导入被拒绝：${e.message}'};
    } on Object catch (e) {
      return <String, dynamic>{'ok': false, 'error': '导入失败：$e'};
    }
  }
}
