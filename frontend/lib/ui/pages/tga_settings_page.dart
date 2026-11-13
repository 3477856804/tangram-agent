import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../design/tga_design.dart';
import '../../services/cache_cleaner.dart';
import '../../services/persona_store.dart';
import '../../services/update_service.dart';
import '../i18n/tga_strings.dart';
import '../voice_sheet.dart';
import 'tga_models_page.dart';
import 'tga_sphere_graph_page.dart';
import 'tga_training_page.dart';

/// 设置（0.0.3 改版）：
/// - 通知开关走全局 SwitchTheme（白球始终可见，问题 #5）；
/// - 语言真实切换三语（flutter_localizations + 内置词典，问题 #11）；
/// - 颜色模式即时全页深浅切换（Tga 组件已注册主题依赖，问题 #6）；
/// - 音色设置 → 真实 edge-tts 多音色选择（问题 #12）；
/// - 检查更新：当前版本读真实安装包（问题 #7）；「自动检查更新」开关
///   移除，改为启动时静默检查一次（问题 #8，见 main.dart OtaLaunchCheck）；
/// - 清理缓存真实执行并显示释放量（问题 #9）；
/// - 关于区收敛为「版本 + 赞助」两项：版本弹品牌卡片，赞助出真码
///   并可跳转微信识别 wxp 链接（问题 #10）。
class TgaSettingsPage extends StatefulWidget {
  const TgaSettingsPage({super.key});

  @override
  State<TgaSettingsPage> createState() => _TgaSettingsPageState();
}

class _TgaSettingsPageState extends State<TgaSettingsPage> {
  /// 真实安装包版本（问题 #7：读 PackageInfo，OTA 后即时反映）。
  String _version = UpdateService.currentVersion;

  @override
  void initState() {
    super.initState();
    UpdateService.installedVersion().then((String v) {
      if (mounted) setState(() => _version = v);
    });
  }

  /// 检查更新：真实调用 GitHub Releases API（当前版本=真实安装包版本）。
  Future<void> _checkUpdate() async {
    _toast(context, context.t('settings.checkUpdate') + '…');
    final UpdateInfo info = await UpdateService().checkLatest();
    if (!mounted) return;
    if (info.error != null) {
      _toast(context, '检查更新失败：${info.error}');
      return;
    }
    if (!info.available) {
      _toast(context, '${context.t('settings.latest')} v${info.current}');
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => TgaSettingsUpdateDialog(info: info),
    );
  }

  /// 清理缓存：真实删除可再生临时数据，如实显示释放量（问题 #9）。
  Future<void> _clearCache() async {
    _toast(context, '正在清理…');
    final CacheCleanResult r = await CacheCleaner.clean();
    if (!mounted) return;
    _toast(context, r.fileCount == 0
        ? '没有可清理的缓存'
        : '已清理 ${r.fileCount} 个临时文件，释放 ${r.freedText}');
  }

  @override
  Widget build(BuildContext context) {
    final PersonaStore store = context.watch<PersonaStore>();
    return TgaPage(
      title: context.t('settings.title'),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          // ---------- 通用设置 ----------
          TgaGroupTitle(context.t('settings.general')),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.notifications_none_rounded,
                  title: context.t('settings.notifications'),
                  subtitle: context.t('settings.notificationsSub'),
                  trailing: Switch(
                    value: store.permissionNotifications,
                    onChanged: (bool v) => store.setPermissionNotifications(v),
                  ),
                  showArrow: false,
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.language_rounded,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: context.t('settings.language'),
                  subtitle: store.language,
                  onTap: () => _pickLanguage(context, store),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.volume_up_outlined,
                  iconBg: Tga.iconCyanBg,
                  iconColor: Tga.iconCyan,
                  title: context.t('settings.voice'),
                  subtitle: store.voiceName.isEmpty
                      ? '晓伊（微软 neural）'
                      : store.voiceName,
                  onTap: () => showTgaVoiceSheet(context),
                ),
              ],
            ),
          ),
          // 颜色模式三胶囊：真实落 store.themeMode，全局主题即时生效。
          const SizedBox(height: 12),
          TgaCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                          color: Tga.iconBlueBg, shape: BoxShape.circle),
                      child: Icon(Icons.palette_outlined,
                          size: 18, color: Tga.iconBlue),
                    ),
                    const SizedBox(width: 12),
                    Text(context.t('settings.theme'), style: Tga.body),
                  ],
                ),
                const SizedBox(height: 14),
                TgaSegmented<String>(
                  items: const <String>['跟随系统', '浅色', '深色'],
                  value: store.themeMode,
                  labelOf: (String s) => switch (s) {
                    '跟随系统' => context.t('settings.themeSystem'),
                    '浅色' => context.t('settings.themeLight'),
                    _ => context.t('settings.themeDark'),
                  },
                  onChanged: (String v) => store.setThemeMode(v),
                ),
              ],
            ),
          ),

          // ---------- 模型与服务 ----------
          TgaGroupTitle(context.t('settings.modelService')),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.hub_outlined,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: context.t('settings.defaultModel'),
                  subtitle: 'agent = model + harness',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext _) => const TgaModelsPage(),
                    ),
                  ),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.api_outlined,
                  title: context.t('settings.apiService'),
                  subtitle: '本地加密存储，不落盘明文',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext _) => const TgaTrainingPage(),
                    ),
                  ),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.memory_outlined,
                  iconBg: Tga.iconCyanBg,
                  iconColor: Tga.iconCyan,
                  title: context.t('settings.onDevice'),
                  subtitle: 'GGUF · llamadart',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext _) => const TgaModelsPage(),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ---------- 数据设置 ----------
          TgaGroupTitle(context.t('settings.data')),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.storage_outlined,
                  iconBg: Tga.iconGoldBg,
                  iconColor: Tga.iconGold,
                  title: context.t('settings.localData'),
                  subtitle: '记忆 / 图谱 / 日记存于本机',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext _) => const TgaSphereGraphPage(),
                    ),
                  ),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.system_update_outlined,
                  title: context.t('settings.checkUpdate'),
                  subtitle: '更新源 GitHub Releases · 启动时自动检查一次',
                  onTap: _checkUpdate,
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.cleaning_services_outlined,
                  iconBg: Tga.iconPinkBg,
                  iconColor: Tga.iconPink,
                  title: context.t('settings.clearCache'),
                  subtitle: '清理临时文件，不动用户数据',
                  onTap: _clearCache,
                ),
              ],
            ),
          ),

          // ---------- 关于：版本 + 赞助 两项（问题 #10）----------
          TgaGroupTitle(context.t('settings.about')),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.tag_rounded,
                  iconBg: Tga.iconCyanBg,
                  iconColor: Tga.iconCyan,
                  title: context.t('settings.version'),
                  subtitle: 'v$_version',
                  onTap: _showAboutCard,
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.favorite_rounded,
                  iconBg: Tga.iconPinkBg,
                  iconColor: Tga.iconPink,
                  title: context.t('settings.sponsor'),
                  subtitle: '赞助 TGA，让鹿跑得更快',
                  onTap: _showSponsorSheet,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(context.t('settings.tagline'), style: Tga.caption),
          ),
        ],
      ),
    );
  }

  /// 品牌版本卡片：TGA 鹿标 + 产品/内核/版本/能力 详细数据（问题 #10）。
  void _showAboutCard() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (BuildContext ctx) => const _AboutBrandCard(),
    );
  }

  /// 赞助：真实二维码（wxp 收款码内容）+ 尝试跳转微信识别。
  void _showSponsorSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) => const _SponsorSheet(),
    );
  }
}

/// 官方赞助收款码内容（用户 2026-11-14 提供，微信识别即达收款页）。
const String kSponsorWxLink =
    'wxp://f2f0XhTuzRTVM8i1MTxPMMzXkFYr08Zp5CHTPbjV1LNvQyY';

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12)));
}

/// 语言：三选对话框，真实落 PersonaStore.language（持久化 + 全局 locale）。
Future<void> _pickLanguage(BuildContext context, PersonaStore store) async {
  final String? picked = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => SimpleDialog(
      title: const Text('语言 / Language'),
      backgroundColor: Tga.card,
      children: <Widget>[
        for (final String lang in const <String>['简体中文', '繁體中文', 'English'])
          RadioMenuButton<String>(
            value: lang,
            groupValue: store.language,
            onChanged: (String? v) => Navigator.of(ctx).pop(v),
            child: Text(lang),
          ),
      ],
    ),
  );
  if (picked != null && picked != store.language) {
    store.setLanguage(picked);
  }
}

/// 品牌版本卡片：鹿标 logo + 名称 + 四项详细数据。
class _AboutBrandCard extends StatelessWidget {
  const _AboutBrandCard();

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        decoration: BoxDecoration(
          color: Tga.card,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Image.asset('assets/logo/tangram_deer.png',
                width: 84, height: 84, fit: BoxFit.contain),
            const SizedBox(height: 12),
            Text('TGA · Tangram Agent', style: Tga.h1),
            Text('檀阁瑞木 · 让每个人拥有自己的模型', style: Tga.sub),
            const SizedBox(height: 18),
            FutureBuilder<String>(
              future: UpdateService.installedVersion(),
              builder: (BuildContext _, AsyncSnapshot<String> s) => _kvGrid(
                context,
                <(String, String)>[
                  ('产品', 'tangram-agent（TGA）'),
                  ('内核', 'agent = model + harness'),
                  ('版本', 'v${s.data ?? UpdateService.currentVersion}'),
                  ('能力', '工作蒸馏 · 产出私人模型'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(context.t('common.close'))),
          ],
        ),
      ),
    );
  }

  Widget _kvGrid(BuildContext context, List<(String, String)> rows) {
    return Column(
      children: <Widget>[
        for (final (String k, String v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: <Widget>[
                SizedBox(
                    width: 56, child: Text(k, style: Tga.caption)),
                Expanded(child: Text(v, style: Tga.body)),
              ],
            ),
          ),
      ],
    );
  }
}

/// 赞助弹层：真码 + 「打开微信识别」+ 保存图片指引。
class _SponsorSheet extends StatelessWidget {
  const _SponsorSheet();

  Future<void> _openWeChat(BuildContext context) async {
    final Uri uri = Uri.parse(kSponsorWxLink);
    bool ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      ok = false;
    }
    if (!ok && context.mounted) {
      _toast(context, '本机未能直接拉起微信识别，请截图后用微信扫一扫');
    }
  }

  @override
  Widget build(BuildContext context) {
    Tga.syncFrom(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.5,
        maxChildSize: 0.92,
        builder: (BuildContext ctx, ScrollController ctrl) => Container(
          decoration: BoxDecoration(
              color: Tga.card, borderRadius: BorderRadius.circular(20)),
          child: ListView(
            controller: ctrl,
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                      child: Text('赞助 TGA',
                          style: Tga.h2, textAlign: TextAlign.center)),
                  IconButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      icon: Icon(Icons.close_rounded, color: Tga.textSub)),
                ],
              ),
              const SizedBox(height: 8),
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14)),
                  child: QrImageView(
                    data: kSponsorWxLink,
                    size: 220,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('微信「扫一扫」识别上方二维码即可赞助；'
                  '或点击下方按钮尝试直接拉起微信。',
                  style: Tga.sub, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: Tga.green,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(46)),
                icon: const Icon(Icons.wechat_rounded),
                label: const Text('打开微信识别'),
                onPressed: () => _openWeChat(ctx),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// OTA 更新对话框：当前→最新 版本 + 真实大小 / Release 说明 + 「立即下载」。
/// 下载中显示真实字节进度与实时速度；分片并行+镜像回退见 UpdateService。
/// 失败显示真实错误并可重试；未授予「安装未知应用」权限时如实引导去授权。
class TgaSettingsUpdateDialog extends StatefulWidget {
  const TgaSettingsUpdateDialog({super.key, required this.info});

  final UpdateInfo info;

  @override
  State<TgaSettingsUpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<TgaSettingsUpdateDialog> {
  bool _downloading = false;
  bool _installerStarted = false;
  bool _pendingPermission = false;
  int _received = 0;
  int _total = 0;
  String? _error;
  final Stopwatch _watch = Stopwatch();

  String get _speed {
    if (!_watch.isRunning || _watch.elapsedMilliseconds < 500) return '';
    final double mbps =
        _received / 1048576.0 / (_watch.elapsedMilliseconds / 1000.0);
    return ' · ${mbps.toStringAsFixed(1)} MB/s';
  }

  Future<void> _startDownload() async {
    setState(() {
      _downloading = true;
      _error = null;
      _pendingPermission = false;
      _received = 0;
      _total = widget.info.size ?? 0;
      _watch
        ..reset()
        ..start();
    });
    final InstallOutcome outcome = await UpdateService().downloadAndInstall(
      widget.info,
      onProgress: (int received, int total) {
        if (mounted) {
          setState(() {
            _received = received;
            if (total > 0) _total = total;
          });
        }
      },
    );
    _watch.stop();
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _installerStarted = outcome.ok;
      _pendingPermission = outcome.pendingPermission;
      _error = outcome.ok ? null : (outcome.error ?? '未知错误');
    });
    if (outcome.ok) {
      // 安装器已调起，稍候自动关闭对话框。
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (mounted) Navigator.of(context).pop();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final UpdateInfo info = widget.info;
    final List<Widget> content;
    final List<Widget> actions;
    if (_downloading) {
      content = <Widget>[
        Text('正在下载 v${info.latest}…'),
        const SizedBox(height: 12),
        LinearProgressIndicator(
            value: _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null),
        const SizedBox(height: 8),
        Text(
            '${UpdateService.formatSize(_received)} / '
            '${_total > 0 ? UpdateService.formatSize(_total) : '大小未知'}$_speed',
            style: Tga.caption),
      ];
      actions = const <Widget>[]; // 下载中不提供假取消
    } else if (_installerStarted) {
      content = <Widget>[
        Text('下载完成，已调起系统安装器：请在弹窗中确认覆盖安装（不卸载、数据保留）。'),
      ];
      actions = <Widget>[
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭')),
      ];
    } else if (_pendingPermission) {
      content = <Widget>[
        Text('APK 已下载完成。系统尚未允许本应用「安装未知应用」，'
            '已跳转到授权页——请开启后回到设置页再点「检查更新 → 立即下载」，'
            '已下载的 APK 会直接复用，不会重复下载。'),
      ];
      actions = <Widget>[
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了')),
      ];
    } else if (_error != null) {
      content = <Widget>[
        Text('下载 / 安装失败：$_error'),
      ];
      actions = <Widget>[
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('以后再说')),
        FilledButton(onPressed: _startDownload, child: const Text('重试')),
      ];
    } else {
      content = <Widget>[
        Text('v${info.current} → v${info.latest} · '
            '安装包 ${UpdateService.formatSize(info.size)}'),
        if (info.notes != null && info.notes!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Text('更新说明', style: Tga.body),
          const SizedBox(height: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(
              child: Text(info.notes!, style: Tga.caption),
            ),
          ),
        ],
      ];
      actions = <Widget>[
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('以后再说')),
        FilledButton(
            onPressed: _startDownload, child: const Text('立即下载')),
      ];
    }
    return AlertDialog(
      backgroundColor: Tga.card,
      title: Text(_downloading
          ? '下载更新'
          : (_installerStarted || _pendingPermission
              ? '更新'
              : '发现新版本 v${info.latest}')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: content,
      ),
      actions: actions,
    );
  }
}
