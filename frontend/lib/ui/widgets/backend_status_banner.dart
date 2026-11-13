/// 旧版面板:当前 App 无入口引用,保留备查。

library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:tangram/flai/core/theme/tangram_palette.dart';
import 'package:tangram/flai/widgets/tangram_surfaces.dart';
import 'package:tangram/services/sandbox_runtime.dart';

/// 全应用统一的离线诚实组件。
///
/// 所有面板只允许通过它表达「后端未就绪」，禁止再硬写「未连接后端」静态文本。
/// 离线态提供「启动内置沙箱」可点击按钮与沙箱环境切换；仅外部桥模式
/// 且缺 python3 时展示 [kNoPythonHint]，不谎称已连接、不填充假数据。
const String kOfflineBannerHint =
    '内置沙箱未启动，暂无真实数据。启动内置沙箱后将在此显示实际内容。';

class BackendStatusBanner extends StatelessWidget {
  const BackendStatusBanner({
    super.key,
    this.loading = false,
    this.error,
    this.offline = true,
    this.onDismissError,
  });

  final bool loading;
  final String? error;
  final bool offline;
  final VoidCallback? onDismissError;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.only(top: TangramSpacing.md),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: TangramSpacing.md),
            Text(
              '正在连接内置沙箱…',
              style: TextStyle(
                color: TangramColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }

    if (error != null && error!.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: TangramSpacing.md),
        child: GlassCard(
          padding: const EdgeInsets.symmetric(
            horizontal: TangramSpacing.md,
            vertical: TangramSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.error_outline,
                  color: TangramColors.danger, size: 20),
              const SizedBox(width: TangramSpacing.md),
              Expanded(
                child: Text(
                  error!,
                  style: const TextStyle(
                    color: TangramColors.textPrimary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
              if (onDismissError != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '关闭',
                  onPressed: onDismissError,
                ),
            ],
          ),
        ),
      );
    }

    if (!offline) return const SizedBox.shrink();
    return _OfflineCard();
  }
}

class _OfflineCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final SandboxRuntime runtime = context.watch<SandboxRuntime>();
    final bool needsPythonHint = runtime.needsPythonHint;

    return Padding(
      padding: const EdgeInsets.only(top: TangramSpacing.md),
      child: GlassCard(
        padding: const EdgeInsets.all(TangramSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.cloud_off_outlined,
                    color: TangramColors.textMuted, size: 20),
                const SizedBox(width: TangramSpacing.md),
                const Expanded(
                  child: Text(
                    '内置沙箱未启动',
                    style: TextStyle(
                      color: TangramColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                StatusPill(
                  label: runtime.online ? '已连接' : '离线',
                  color: runtime.online
                      ? TangramColors.success
                      : TangramColors.textMuted,
                  dense: true,
                ),
              ],
            ),
            const SizedBox(height: TangramSpacing.sm),
            const Text(
              kOfflineBannerHint,
              style: TextStyle(
                color: TangramColors.textSecondary,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            if (needsPythonHint) ...<Widget>[
              const SizedBox(height: TangramSpacing.sm),
              const Text(
                kNoPythonHint,
                style: TextStyle(
                  color: TangramColors.danger,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
            if (runtime.notice != null && runtime.notice!.isNotEmpty) ...<Widget>[
              const SizedBox(height: TangramSpacing.sm),
              Text(
                runtime.notice!,
                style: const TextStyle(
                  color: TangramColors.textSecondary,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
            ],
            const SizedBox(height: TangramSpacing.md),
            Wrap(
              spacing: TangramSpacing.md,
              runSpacing: TangramSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: runtime.starting ? null : () => runtime.launch(),
                  icon: runtime.starting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow, size: 16),
                  label: Text(runtime.starting ? '启动中…' : '启动内置沙箱'),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text(
                      '沙箱环境',
                      style: TextStyle(
                          color: TangramColors.textMuted, fontSize: 12),
                    ),
                    const SizedBox(width: TangramSpacing.sm),
                    DropdownButton<String>(
                      value: SandboxRuntime.environments.contains(
                              runtime.environment)
                          ? runtime.environment
                          : SandboxRuntime.environments.first,
                      underline: const SizedBox.shrink(),
                      style: const TextStyle(
                        color: TangramColors.textPrimary,
                        fontSize: 12,
                      ),
                      dropdownColor: TangramColors.surface,
                      items: SandboxRuntime.environments
                          .map(
                            (String e) => DropdownMenuItem<String>(
                              value: e,
                              child: Text(e),
                            ),
                          )
                          .toList(),
                      onChanged: (String? v) {
                        if (v != null) runtime.setEnvironment(v);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
