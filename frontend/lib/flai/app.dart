import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../design/tga_design.dart';
import '../harness/ui_customization.dart';
import '../services/persona_store.dart';
import '../ui/i18n/tga_strings.dart';
import '../ui/system_ui.dart';
import '../ui/update_gate.dart';
import 'core/secure_auth_storage.dart';
import 'core/theme/flai_theme.dart';
import 'core/theme/tangram_palette.dart';
import 'providers/persistent_storage_provider.dart';
import 'providers/storage_provider.dart';
import 'app_config.dart';
import 'providers.dart';
import 'routing/app_router.dart';

class FlaiApp extends StatefulWidget {
  final AppScaffoldConfig config;

  const FlaiApp({
    super.key,
    required this.config,
  });

  @override
  State<FlaiApp> createState() => _FlaiAppState();
}

class _FlaiAppState extends State<FlaiApp> {
  late final StorageProvider _storageProvider;
  late final GoRouter _router;
  late final SecureAuthStorage _authStorage;

  bool _isRestoringSession = true;
  StreamSubscription<({String? accessToken, String? refreshToken})>?
      _tokenSub;

  /// Provider 缺失（独立复用 / 测试）时的主题默认值。
  static final UiCustomizationConfig _fallbackUiConfig =
      UiCustomizationConfig.defaults();

  @override
  void initState() {
    super.initState();
    _storageProvider =
        widget.config.storageProvider ?? PersistentStorageProvider();
    _router = createAppRouter(config: widget.config);
    _authStorage = SecureAuthStorage();

    _listenToTokenChanges();
    _tryRestoreSession();
  }

  @override
  void dispose() {
    _tokenSub?.cancel();
    _router.dispose();
    super.dispose();
  }

  void _listenToTokenChanges() {
    _tokenSub = widget.config.authProvider.tokenChanges.listen((tokens) async {
      if (tokens.accessToken != null) {
        await _authStorage.saveTokens(
          accessToken: tokens.accessToken,
          refreshToken: tokens.refreshToken,
        );
        final user = widget.config.authProvider.currentUser;
        if (user != null) {
          await _authStorage.saveUser(user);
        }
      } else {
        await _authStorage.clear();
      }
    });
  }

  Future<void> _tryRestoreSession() async {
    try {
      final stored = await _authStorage.readTokens();
      if (stored != null) {
        final restored = await widget.config.authProvider.tryRestoreSession(
          stored.accessToken,
          stored.refreshToken,
        );
        if (!restored) {
          await _authStorage.clear();
        }
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() {
          _isRestoringSession = false;
        });
      }
    }
  }

  /// 依据 PersonaStore.themeMode + 系统 brightness 决定 FlaiThemeData 亮暗。
  /// config.theme 若显式提供则尊重它（用于测试 / 定制注入）。
  FlaiThemeData _resolveTheme(ThemeMode mode, Brightness platformBrightness) {
    if (widget.config.theme != null) return widget.config.theme!;
    final bool dark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system && platformBrightness == Brightness.dark);
    return dark ? TangramTheme.flaiThemeDark() : TangramTheme.flaiTheme();
  }

  /// 读取界面自定义配置（取**已保存**的当前作用域配置，草稿不直接生效）；
  /// 没有 Provider 时用默认值，绝不让主题装配抛错。
  UiCustomizationConfig _uiConfig(BuildContext context) {
    try {
      final UiCustomizationStore store =
          Provider.of<UiCustomizationStore>(context);
      return store.apply(store.scope);
    } on Object {
      return _fallbackUiConfig;
    }
  }

  /// 深/浅冲突规则（PersonaStore 始终是决定方）：
  /// 1. PersonaStore.themeMode 显式「深色 / 浅色」优先，UI 自定义不覆盖；
  /// 2. PersonaStore 为「跟随系统」时，surfacePreset 的 mist / midnight 才强制
  ///    浅 / 深，auto 继续跟随系统亮度；
  /// 3. 强调色 / 字号 / 信息密度 / 圆角在任何情况下都由 UI 自定义覆盖。
  ThemeMode _resolveThemeMode(String themePref, UiSurfacePreset surface) {
    final ThemeMode personaMode = switch (themePref) {
      '深色' => ThemeMode.dark,
      '跟随系统' => ThemeMode.system,
      _ => ThemeMode.light,
    };
    if (personaMode != ThemeMode.system) return personaMode;
    final Brightness? forced = uiForcedBrightness(surface);
    if (forced == null) return ThemeMode.system;
    return forced == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
  }

  @override
  Widget build(BuildContext context) {
    // 主题配置落到 PersonaStore 后，在这里真正驱动 MaterialApp 与 FlaiTheme。
    final PersonaStore persona = context.watch<PersonaStore>();
    final UiCustomizationConfig uiConfig = _uiConfig(context);
    final ThemeMode mode =
        _resolveThemeMode(persona.themeMode, uiConfig.surfacePreset);
    final Brightness platform = MediaQuery.platformBrightnessOf(context);
    final theme = _resolveTheme(mode, platform);
    // 主题监听集中处：系统栏图标亮度随深浅主题切换（问题 #10，
    // edgeToEdge + 透明栏在 main.dart 启动时已设置）。
    applyTgaSystemUi((mode == ThemeMode.dark ||
            (mode == ThemeMode.system && platform == Brightness.dark))
        ? Brightness.dark
        : Brightness.light);
    // 语言真实生效：简体中文/繁體中文/English → MaterialApp locale，
    // 系统组件（时间/日期选择器等弹窗）与内置词典同步切换。
    final Locale locale = TgaL10n.localeOf(persona.language);

    if (_isRestoringSession) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: locale,
        localizationsDelegates: TgaL10n.delegates,
        supportedLocales: TgaL10n.supported,
        home: Scaffold(
          backgroundColor: theme.colors.background,
          body: Center(
            child: CircularProgressIndicator(
              color: theme.colors.accent,
              strokeWidth: 1.5,
            ),
          ),
        ),
      );
    }

    return FlaiTheme(
      data: theme,
      child: FlaiProviders(
        authProvider: widget.config.authProvider,
        storageProvider: _storageProvider,
        aiProvider: widget.config.aiProvider,
        voiceProvider: widget.config.voiceProvider,
        child: MaterialApp.router(
          routerConfig: _router,
          title: widget.config.appTitle,
          debugShowCheckedModeBanner: false,
          // 界面自定义：强调色 / 信息密度 / 卡片与按钮圆角真实落到两套主题上；
          // 深浅仍由上面的 themeMode（PersonaStore 优先）决定。
          theme: applyUiCustomizationTheme(TangramTheme.light(), uiConfig),
          darkTheme: applyUiCustomizationTheme(TangramTheme.dark(), uiConfig),
          themeMode: mode,
          locale: locale,
          localizationsDelegates: TgaL10n.delegates,
          supportedLocales: TgaL10n.supported,
          // Tga.* 是全局静态色板，原先只在 TgaPage.build 同步；聊天页等
          // 不经 TgaPage 的路由会停留在浅色文字令牌，深色模式下 AI 正文
          // 与背景近同色而不可见。根层每帧按当前 Theme 亮度统一同步。
          // 启动 3 秒后静默检查一次更新，发现新版才弹窗（问题 #8）。
          builder: (BuildContext ctx, Widget? child) {
            Tga.syncFrom(ctx);
            // 字号缩放真实生效：系统缩放 × 配置缩放，整体 clamp 到 0.85–1.35，
            // 避免超大字号把既有布局撑破。
            final MediaQueryData media = MediaQuery.of(ctx);
            final double textScale = uiEffectiveTextScale(
              media.textScaler.scale(1),
              uiConfig.fontScale,
            );
            return MediaQuery(
              data: media.copyWith(
                textScaler: TextScaler.linear(textScale),
              ),
              child: TgaUpdateGate(
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
