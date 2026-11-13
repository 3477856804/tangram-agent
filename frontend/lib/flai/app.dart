import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../services/persona_store.dart';
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

  @override
  Widget build(BuildContext context) {
    // 主题配置落到 PersonaStore 后，在这里真正驱动 MaterialApp 与 FlaiTheme。
    final String themePref = context.watch<PersonaStore>().themeMode;
    final ThemeMode mode = switch (themePref) {
      '深色' => ThemeMode.dark,
      '跟随系统' => ThemeMode.system,
      _ => ThemeMode.light,
    };
    final Brightness platform = MediaQuery.platformBrightnessOf(context);
    final theme = _resolveTheme(mode, platform);

    if (_isRestoringSession) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
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
          theme: TangramTheme.light(),
          darkTheme: TangramTheme.dark(),
          themeMode: mode,
        ),
      ),
    );
  }
}
