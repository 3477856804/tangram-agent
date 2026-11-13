import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design/tga_design.dart';
import '../../services/announcements.dart';
import '../../services/persona_store.dart';
import '../../services/update_service.dart';
import '../i18n/tga_strings.dart';
import '../voice_sheet.dart';
import 'tga_agents_page.dart';
import 'tga_messages_page.dart';
import 'tga_persona_page.dart';
import 'tga_settings_page.dart';
import 'tga_works_page.dart';

/// 个人页：顶部身份卡 + 三功能入口（我的作品 / 智能体中心 / 消息中心）
/// + 偏好卡（外观 / 音色）+ 设置。
///
/// 真实化（2026-11-14，问题 #13/#14/#15/#17）：
/// - 我的作品 → TgaWorksPage（扫描工作区真实产物）；
/// - 智能体中心 → TgaAgentsPage（agents.json 落盘，启用即注入对话人设）；
/// - 消息中心 → TgaMessagesPage（发布仓库真实公告，未读持久化），
///   入口带未读红点（拉取失败无红点）；
/// - 音色设置 → showTgaVoiceSheet（真实 TTS 多音色）；
/// - 帮助与反馈入口移除（#17）；
/// - 底部版本读真实安装包（UpdateService.installedVersion）。
class TgaProfilePage extends StatefulWidget {
  const TgaProfilePage({super.key});

  @override
  State<TgaProfilePage> createState() => _TgaProfilePageState();
}

class _TgaProfilePageState extends State<TgaProfilePage> {
  bool _hasUnread = false;
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadUnread();
    _loadVersion();
  }

  /// 未读红点：真实拉公告 + 已读集合比对；任何失败保持无红点（宁缺毋假）。
  Future<void> _loadUnread() async {
    final int n = await Announcements.unreadCount();
    if (!mounted) return;
    setState(() => _hasUnread = n > 0);
  }

  Future<void> _loadVersion() async {
    final String v = await UpdateService.installedVersion();
    if (!mounted) return;
    setState(() => _version = v);
  }

  void _push(Widget page) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (BuildContext _) => page));
  }

  @override
  Widget build(BuildContext context) {
    final PersonaStore store = context.watch<PersonaStore>();
    return TgaPage(
      title: context.t('profile.title'),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Tga.pagePad, 8, Tga.pagePad, 40),
        children: <Widget>[
          // ---------- 顶部身份 ----------
          // 头像与 AI 名字与人格设置页同源：默认 TGA 鹿标 + aiName（默认 TGA），
          // 用户在人格页上传头像/改名后这里实时跟随。
          Builder(builder: (BuildContext context) {
            final String? avatar = store.avatarPath;
            final File? custom =
                (avatar != null && File(avatar).existsSync())
                    ? File(avatar)
                    : null;
            return TgaCard(
              // 整卡可点：头像 / AI 名字的真实编辑入口在人格设置页。
              onTap: () => _push(const TgaPersonaPage()),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[Tga.iconBlue, Tga.iconPurple],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: custom != null
                        ? Image.file(custom,
                            width: 58,
                            height: 58,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Image.asset(
                                'assets/logo/tangram_deer_192.png',
                                width: 58,
                                height: 58,
                                fit: BoxFit.cover))
                        : Image.asset('assets/logo/tangram_deer_192.png',
                            width: 58,
                            height: 58,
                            fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(store.aiName, style: Tga.h2),
                        const SizedBox(height: 4),
                        Text('本地 AI 使用者 · 模型与数据都归自己',
                            style: Tga.sub),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      color: Tga.textDim),
                ],
              ),
            );
          }),

          // ---------- 三功能入口（真实页面）----------
          const SizedBox(height: 14),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Row(
              children: <Widget>[
                _Entry(icon: Icons.folder_copy_outlined,
                    label: context.t('profile.works'),
                    bg: Tga.iconBlueBg, fg: Tga.iconBlue,
                    onTap: () => _push(const TgaWorksPage())),
                _Entry(icon: Icons.smart_toy_outlined, label: context.t('profile.agents'),
                    bg: Tga.iconPurpleBg, fg: Tga.iconPurple,
                    onTap: () => _push(const TgaAgentsPage())),
                _Entry(icon: Icons.mark_chat_unread_outlined, label: context.t('profile.messages'),
                    bg: Tga.iconCyanBg, fg: Tga.iconCyan,
                    badge: _hasUnread,
                    onTap: () => _push(const TgaMessagesPage())),
              ],
            ),
          ),

          // ---------- 偏好卡片 ----------
          const TgaGroupTitle('偏好'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.color_lens_outlined,
                  title: '外观设置',
                  subtitle: store.themeMode,
                  onTap: () => _pickTheme(context, store),
                ),
                TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.record_voice_over_outlined,
                  iconBg: Tga.iconPurpleBg,
                  iconColor: Tga.iconPurple,
                  title: context.t('settings.voice'),
                  subtitle: '标准女声',
                  onTap: () => showTgaVoiceSheet(context),
                ),
              ],
            ),
          ),

          // ---------- 设置（#17：帮助与反馈入口已移除）----------
          const TgaGroupTitle('其他'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: TgaIconTile(
              icon: Icons.settings_outlined,
              iconBg: Tga.iconBlueBg,
              iconColor: Tga.iconBlue,
              title: context.t('settings.title'),
              subtitle: '通用 / 模型与服务 / 数据 / 关于',
              onTap: () => _push(const TgaSettingsPage()),
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              _version.isEmpty
                  ? 'tangram-agent'
                  : 'tangram-agent · $_version',
              style: Tga.caption,
            ),
          ),
        ],
      ),
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry(
      {required this.icon,
      required this.label,
      required this.bg,
      required this.fg,
      required this.onTap,
      this.badge = false});
  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;

  /// 未读红点（消息中心）。
  final bool badge;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
                  child: Icon(icon, size: 22, color: fg),
                ),
                if (badge)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Tga.red,
                        shape: BoxShape.circle,
                        border: Border.all(color: Tga.card, width: 1.5),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 9),
            Text(label, style: Tga.sub.copyWith(color: Tga.text)),
          ],
        ),
      ),
    );
  }
}

/// 外观设置：主题三选真实落 PersonaStore.themeMode（全局即时生效 + 持久化）。
Future<void> _pickTheme(BuildContext context, PersonaStore store) async {
  final String? picked = await showDialog<String>(
    context: context,
    builder: (BuildContext ctx) => SimpleDialog(
      title: const Text('外观设置'),
      children: <Widget>[
        for (final String mode in const <String>['跟随系统', '浅色', '深色'])
          RadioMenuButton<String>(
            value: mode,
            groupValue: store.themeMode,
            onChanged: (String? v) => Navigator.of(ctx).pop(v),
            child: Text(mode),
          ),
      ],
    ),
  );
  if (picked != null && picked != store.themeMode) {
    store.setThemeMode(picked);
  }
}
