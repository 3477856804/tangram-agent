import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../design/tga_design.dart';
import '../../services/persona_store.dart';
import 'tga_persona_page.dart';
import 'tga_settings_page.dart';

/// 个人页（设计稿 2026-11-12）：沿用对方版式结构。
/// 顶部头像 + 用户名 + 身份说明；三功能入口：我的作品 / 智能体中心 / 消息中心；
/// 偏好卡片：外观设置（跟随系统）、音色设置（标准女声）；帮助与反馈、设置。
///
/// 假交互清扫（2026-11-13）：
/// - 顶部身份卡 → 整卡可点，push 人格设置页（头像 / AI 名字的真实编辑处）；
/// - 外观设置 → 弹主题三选（跟随系统 / 浅色 / 深色），落 PersonaStore.themeMode，
///   全局主题即时生效并持久化；
/// - 设置 → push TgaSettingsPage；
/// - 我的作品 / 智能体中心 / 消息中心 / 音色设置 / 帮助与反馈：后端暂无对应
///   能力，点击如实 toast「当前版本不支持」，不再静默无响应。
class TgaProfilePage extends StatelessWidget {
  const TgaProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final PersonaStore store = context.watch<PersonaStore>();
    return TgaPage(
      title: '个人',
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
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (BuildContext _) => const TgaPersonaPage(),
                ),
              ),
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

          // ---------- 三功能入口 ----------
          const SizedBox(height: 14),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Row(
              children: <Widget>[
                _Entry(icon: Icons.folder_copy_outlined, label: '我的作品',
                    bg: Tga.iconBlueBg, fg: Tga.iconBlue,
                    onTap: () => _toast(context, '当前版本不支持：我的作品（暂无作品库）')),
                _Entry(icon: Icons.smart_toy_outlined, label: '智能体中心',
                    bg: Tga.iconPurpleBg, fg: Tga.iconPurple,
                    onTap: () => _toast(context, '当前版本不支持：智能体中心（暂无智能体市场）')),
                _Entry(icon: Icons.mark_chat_unread_outlined, label: '消息中心',
                    bg: Tga.iconCyanBg, fg: Tga.iconCyan,
                    onTap: () => _toast(context, '当前版本不支持：消息中心（暂无站内消息服务）')),
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
                  title: '音色设置',
                  subtitle: '标准女声',
                  onTap: () => _toast(context, '当前版本不支持：音色设置（未接入 TTS 引擎）'),
                ),
              ],
            ),
          ),

          // ---------- 帮助与反馈、设置 ----------
          const TgaGroupTitle('其他'),
          TgaCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: <Widget>[
                TgaIconTile(
                  icon: Icons.help_outline_rounded,
                  iconBg: Tga.iconGoldBg,
                  iconColor: Tga.iconGold,
                  title: '帮助与反馈',
                  subtitle: '使用指南与问题反馈',
                  onTap: () => _toast(context, '当前版本不支持：帮助与反馈（未接入反馈通道）'),
                ),
                TgaTileDivider(),
                TgaIconTile(
                  icon: Icons.settings_outlined,
                  iconBg: Tga.iconBlueBg,
                  iconColor: Tga.iconBlue,
                  title: '设置',
                  subtitle: '通用 / 模型与服务 / 数据 / 关于',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext _) => const TgaSettingsPage(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Center(child: Text('tangram-agent · 0.0.1', style: Tga.caption)),
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
      required this.onTap});
  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(icon, size: 22, color: fg),
            ),
            const SizedBox(height: 9),
            Text(label, style: Tga.sub.copyWith(color: Tga.text)),
          ],
        ),
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
