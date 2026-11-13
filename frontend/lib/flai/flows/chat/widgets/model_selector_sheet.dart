import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:tangram/ui/pages/tga_training_page.dart';

import '../../../core/theme/flai_theme.dart';
import '../chat_experience_config.dart';

Future<ModelOption?> showModelSelector({
  required BuildContext context,
  required List<ModelOption> models,
  String? currentModelId,
}) {
  return showModalBottomSheet<ModelOption>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ModelSelectorSheet(
      models: models,
      currentModelId: currentModelId,
    ),
  );
}

class _ModelSelectorSheet extends StatelessWidget {
  final List<ModelOption> models;
  final String? currentModelId;

  const _ModelSelectorSheet({
    required this.models,
    this.currentModelId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FlaiTheme.of(context);
    // 是否只剩内置兜底引擎（ModelRegistry 中除 kBuiltinEngine 外无任何
    // 用户模型：cloudEntries 与 localEntries 均空，用户项分组不为「内置」）。
    final bool onlyBuiltin = models.every((ModelOption m) => m.group == '内置');

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.only(top: theme.spacing.sm),
              child: Center(
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colors.muted,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.spacing.md,
                theme.spacing.md,
                theme.spacing.md,
                0,
              ),
              child: Text(
                '选择模型',
                style: theme.typography.lg.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colors.foreground,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.spacing.md,
                2,
                theme.spacing.md,
                theme.spacing.sm,
              ),
              child: Text(
                '只显示你已添加的模型 ·（云端）走 API ·（本地）用权重',
                style: theme.typography.sm.copyWith(
                  color: theme.colors.mutedForeground,
                  height: 1.4,
                ),
              ),
            ),
            if (onlyBuiltin)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  theme.spacing.md,
                  4,
                  theme.spacing.md,
                  theme.spacing.md,
                ),
                child: Container(
                  padding: EdgeInsets.all(theme.spacing.md),
                  decoration: BoxDecoration(
                    color: theme.colors.muted.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: theme.typography.sm.copyWith(
                        color: theme.colors.mutedForeground,
                        height: 1.6,
                      ),
                      children: <InlineSpan>[
                        const TextSpan(text: '暂未有模型，是否前往'),
                        TextSpan(
                          text: '添加',
                          style: TextStyle(
                            color: theme.colors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                          // 「添加」蓝色可点：整页 push 训练设置页，
                          // 在那里保存云端 API / 下载本地权重。
                          recognizer: TapGestureRecognizer()
                            ..onTap = () {
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const TgaTrainingPage(),
                                ),
                              );
                            },
                        ),
                        const TextSpan(text: '？'),
                      ],
                    ),
                  ),
                ),
              ),
            ..._buildGroups(theme, context),
            SizedBox(height: theme.spacing.md),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildGroups(FlaiThemeData theme, BuildContext context) {
    final out = <Widget>[];
    String? lastGroup;
    for (final model in models) {
      final g = model.group;
      if (g != null && g != lastGroup) {
        out.add(Padding(
          padding: EdgeInsets.fromLTRB(
            theme.spacing.md,
            theme.spacing.sm,
            theme.spacing.md,
            2,
          ),
          child: Text(
            g,
            style: theme.typography.sm.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colors.mutedForeground,
              letterSpacing: 0.4,
            ),
          ),
        ));
        lastGroup = g;
      }
      final isSelected = model.id == currentModelId;
      out.add(ListTile(
        dense: true,
        leading: model.icon != null
            ? Icon(model.icon, size: 20, color: theme.colors.foreground)
            : null,
        title: Text(
          model.name,
          style: theme.typography.base.copyWith(
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: theme.colors.foreground,
          ),
        ),
        subtitle: model.description != null
            ? Text(
                model.description!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.typography.sm.copyWith(
                  color: theme.colors.mutedForeground,
                ),
              )
            : null,
        trailing: isSelected
            ? Icon(Icons.check_circle_rounded,
                size: 20, color: theme.colors.primary)
            : null,
        onTap: () => Navigator.of(context).pop(model),
      ));
    }
    return out;
  }
}
