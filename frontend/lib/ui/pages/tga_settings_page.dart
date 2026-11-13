import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design/tga_design.dart';
import '../../services/persona_store.dart';
import '../../services/update_service.dart';
import 'tga_models_page.dart';
import 'tga_sphere_graph_page.dart';
import 'tga_training_page.dart';

/// 设置（设计稿 2026-11-12）：浅蓝灰底 + 白色圆角卡片，蓝色分组标题，
/// 四分组：通用设置 / 模型与服务 / 数据设置 / 关于。
/// 圆形浅蓝/浅紫图标底 + 线性图标，标题 + 副标题条目式排列。
/// 颜色模式三胶囊：跟随系统 / 浅色（默认选中）/ 深色。
/// 「关于」里保留 TGA 身份信息（产品 / 内核 / 版本 / 能力）。
///
/// 假交互清扫（2026-11-13）：
/// - 通知开关 → 真实落 PersonaStore.permissionNotifications（持久化）；
/// - 语言 → 弹三选对话框（简体中文 / 繁体中文 / English），落 PersonaStore.language；
/// - 颜色模式 → 真实落 PersonaStore.themeMode（全局主题即时生效 + 持久化）；
/// - 默认模型 / 端侧推理 → push TgaModelsPage（真实蒸馏 / 本地权重管理）；
/// - API 服务 → push TgaTrainingPage（真实云端模型表单）；
/// - 本地数据 → push TgaSphereGraphPage（真实对话词共现图谱）；
/// - 检查更新 → 真实 GitHub Releases OTA（见 services/update_service.dart）：
///   检查 → 下载 APK（真实字节进度）→ FileProvider 调起系统安装器覆盖安装，
///   不卸载、保留数据；无更新 / 失败如实提示，不假装有更新；
/// - 自动检查更新 → 开关真实持久化（FlutterSecureStorage），开启后
///   打开设置页时自动检查一次；
/// - 清理缓存 → 后端无缓存管理接口，如实 toast「当前版本不支持」；
/// - 音色设置 → 后端未接入 TTS，如实 toast「当前版本不支持」。
class TgaSettingsPage extends StatefulWidget {
  const TgaSettingsPage({super.key});

  @override
  State<TgaSettingsPage> createState() => _TgaSettingsPageState();
}

class _TgaSettingsPageState extends State<TgaSettingsPage> {
  /// 「自动检查更新」开关状态（FlutterSecureStorage 持久化）。
  bool _autoCheck = false;

  @override
  void initState() {
    super.initState();
    _initUpdatePrefs();
  }

  Future<void> _initUpdatePrefs() async {
    final bool saved = await UpdateService().loadAutoCheck();
    if (!mounted) return;
    setState(() => _autoCheck = saved);
    // 开关开启：打开设置页时自动真实检查一次更新。
    if (saved) await _autoCheckOnce();
  }

  Future<void> _autoCheckOnce() async {
    final UpdateInfo info = await UpdateService().checkLatest();
    if (!mounted) return;
    if (info.error != null) {
      _toast(context, '自动检查更新失败：${info.error}');
      return;
    }
    if (info.available) await _showUpdateDialog(info);
  }

  Future<void> _setAutoCheck(bool v) async {
    setState(() => _autoCheck = v);
    try {
      await UpdateService().saveAutoCheck(v);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _autoCheck = !v);
      _toast(context, '自动检查更新开关持久化失败，已回滚：$e');
    }
  }

  /// 检查更新：真实调用 GitHub Releases API。
  /// 有更新 → 对话框（当前→最新 + 更新说明 + 立即下载）；
  /// 无更新 → 如实提示「已是最新版本」；失败 → 显示真实错误。
  Future<void> _checkUpdate() async {
    _toast(context, '正在检查更新…');
    final UpdateInfo info = await UpdateService().checkLatest();
    if (!mounted) return;
    if (info.error != null) {
      _toast(context, '检查更新失败：${info.error}');
      return;
    }
    if (!info.available) {
      _toast(context, '已是最新版本 v${info.latest ?? info.current}');
      return;
    }
    await _showUpdateDialog(info);
  }

  Future<void> _showUpdateDialog(UpdateInfo info) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => _UpdateDialog(info: info),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PersonaStore store = context.watch<PersonaStore>();
    return TgaPage(
      title: '设置',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 4, Tga.pagePad, 40),
        children: <Widget>[
          // ---------- 通用设置 ----------
          const TgaGroupTitle('通用设置'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.notifications_none_rounded,
                  title: '消息通知',
                  subtitle: '接收 Agent 任务完成提醒',
                  trailing: Switch(
                    value: store.permissionNotifications,
                    activeThumbColor: Tga.primary,
                    onChanged: (bool v) => store.setPermissionNotifications(v),
                  ),
                  showArrow: false,
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.language_rounded,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: '语言',
                  subtitle: store.language,
                  onTap: () => _pickLanguage(context, store),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.volume_up_outlined,
                  iconBg: Tga.iconCyanBg,
                  iconColor: Tga.iconCyan,
                  title: '音色设置',
                  subtitle: '标准女声',
                  onTap: () => _toast(context, '当前版本不支持：音色设置（未接入 TTS 引擎）'),
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
                    Text('颜色模式', style: Tga.body),
                  ],
                ),
                const SizedBox(height: 14),
                TgaSegmented<String>(
                  items: const <String>['跟随系统', '浅色', '深色'],
                  value: store.themeMode,
                  labelOf: (String s) => s,
                  onChanged: (String v) => store.setThemeMode(v),
                ),
              ],
            ),
          ),

          // ---------- 模型与服务 ----------
          const TgaGroupTitle('模型与服务'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.hub_outlined,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: '默认模型',
                  subtitle: 'agent = model + harness',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext _) => const TgaModelsPage(),
                    ),
                  ),
                ),
                TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.api_outlined,
                  title: 'API 服务',
                  subtitle: '本地加密存储，不落盘明文',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext _) => const TgaTrainingPage(),
                    ),
                  ),
                ),
                TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.memory_outlined,
                  iconBg: Tga.iconCyanBg,
                  iconColor: Tga.iconCyan,
                  title: '端侧推理',
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
          const TgaGroupTitle('数据设置'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.storage_outlined,
                  iconBg: Tga.iconGoldBg,
                  iconColor: Tga.iconGold,
                  title: '本地数据',
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
                  title: '检查更新',
                  subtitle:
                      '当前 v${UpdateService.currentVersion} · 更新源 GitHub Releases',
                  onTap: () => _checkUpdate(),
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.access_time_outlined,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: '自动检查更新',
                  subtitle: '开启后，打开设置页时自动检查一次',
                  trailing: Switch(
                    value: _autoCheck,
                    activeThumbColor: Tga.primary,
                    onChanged: _setAutoCheck,
                  ),
                  showArrow: false,
                ),
                const TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.cleaning_services_outlined,
                  iconBg: Tga.iconPinkBg,
                  iconColor: Tga.iconPink,
                  title: '清理缓存',
                  subtitle: '释放临时文件占用空间',
                  onTap: () => _toast(context, '当前版本不支持：清理缓存（无缓存管理接口）'),
                ),
              ],
            ),
          ),

          // ---------- 关于（保留 TGA 身份信息）----------
          const TgaGroupTitle('关于'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.info_outline_rounded,
                  title: '产品',
                  subtitle: 'tangram-agent（TGA）',
                  showArrow: false,
                ),
                TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.account_tree_outlined,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: '内核',
                  subtitle: 'agent = model + harness',
                  showArrow: false,
                ),
                TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.tag_rounded,
                  iconBg: Tga.iconCyanBg,
                  iconColor: Tga.iconCyan,
                  title: '版本',
                  subtitle: 'v${UpdateService.currentVersion}',
                  showArrow: false,
                ),
                TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.auto_awesome_outlined,
                  iconBg: Tga.iconGoldBg,
                  iconColor: Tga.iconGold,
                  title: '能力',
                  subtitle: '工作蒸馏 · 产出私人模型',
                  showArrow: false,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text('Tangram Agent · 让每个人拥有自己的模型',
                style: Tga.caption),
          ),
        ],
      ),
    );
  }
}

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(12)));
}

/// 语言：三选对话框，真实落 PersonaStore.language（持久化）。
Future<void> _pickLanguage(BuildContext context, PersonaStore store) async {
  final String? picked = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => SimpleDialog(
      title: const Text('语言'),
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

/// OTA 更新对话框：当前→最新 版本 + 真实大小 / Release 说明 + 「立即下载」。
/// 下载中显示真实字节进度条；下载完成自动经 MethodChannel 调起系统安装器。
/// 失败显示真实错误并可重试；未授予「安装未知应用」权限时如实引导去授权。
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  bool _installerStarted = false;
  bool _pendingPermission = false;
  int _received = 0;
  int _total = 0;
  String? _error;

  Future<void> _startDownload() async {
    setState(() {
      _downloading = true;
      _error = null;
      _pendingPermission = false;
      _received = 0;
      _total = widget.info.size ?? 0;
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
            '${_total > 0 ? UpdateService.formatSize(_total) : '大小未知'}',
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
        FilledButton(
            onPressed: _startDownload, child: const Text('重试')),
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
      title: Text(_downloading
          ? '下载更新'
          : (_installerStarted || _pendingPermission ? '更新' : '发现新版本 v${info.latest}')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: content,
      ),
      actions: actions,
    );
  }
}
