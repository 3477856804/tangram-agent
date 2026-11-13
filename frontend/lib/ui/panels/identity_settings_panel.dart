/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/design/dsh_tokens.dart';
import 'package:tangram/design/dsh_widgets.dart';
import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/services/persona_store.dart';

/// 打开独立的「个人」身份设置页。
void openIdentitySettings(BuildContext context) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext ctx) {
        final DshPalette c = DshPalette.of(ctx);
        return Scaffold(
          backgroundColor: c.bgBase,
          body: SafeArea(
            bottom: false,
            child: Column(
              children: <Widget>[
                DshTopBar(
                  title: '个人',
                  onBack: () => Navigator.of(ctx).maybePop(),
                ),
                const Expanded(child: IdentitySettingsPanel()),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 个人身份：仅保存在本机，不伪造登录态。
class IdentitySettingsPanel extends StatefulWidget {
  const IdentitySettingsPanel({super.key});

  @override
  State<IdentitySettingsPanel> createState() => _IdentitySettingsPanelState();
}

class _IdentitySettingsPanelState extends State<IdentitySettingsPanel> {
  late final TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
      text: context.read<PersonaStore>().displayName,
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PersonaStore persona = context.watch<PersonaStore>();
    return PanelPage(
      children: <Widget>[
        const SectionTitle(
          title: '个人',
          subtitle: '身份设置 · 仅保存在本机',
          icon: Icons.person_outline,
          accent: TangramColors.jade,
        ),
        GlassCard(
          padding: const EdgeInsets.all(TangramSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '称呼',
                  hintText: '个人',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (String v) => persona.setDisplayName(
                  v.trim().isEmpty ? '个人' : v.trim(),
                ),
              ),
              const SizedBox(height: TangramSpacing.md),
              const Text(
                '没有账号体系，设置只保存在这台设备。',
                style: TextStyle(
                  color: TangramColors.textMuted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
