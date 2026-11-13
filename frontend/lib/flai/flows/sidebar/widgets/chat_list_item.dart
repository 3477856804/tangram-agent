import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design/dsh_tokens.dart';
import '../../../../design/dsh_widgets.dart';
import '../../../../ui/i18n/tga_strings.dart';
import '../sidebar_config.dart';

/// 会话行：标题 + 相对时间 + 更多（长按或点“…”出菜单）。
/// 选中态用 dsh 的 sidebar-active 底色，圆角 12。
class ChatListItem extends StatelessWidget {
  final ConversationItem item;

  final bool isSelected;

  final VoidCallback? onTap;

  final VoidCallback? onStar;

  final VoidCallback? onRename;

  final VoidCallback? onShare;

  final VoidCallback? onDelete;

  const ChatListItem({
    super.key,
    required this.item,
    this.isSelected = false,
    this.onTap,
    this.onStar,
    this.onRename,
    this.onShare,
    this.onDelete,
  });

  String _formatTimestamp(BuildContext context, DateTime timestamp) {
    final Duration diff = DateTime.now().difference(timestamp);
    if (diff.inMinutes < 1) return context.t('sidebar.justNow', zh: '刚刚');
    if (diff.inMinutes < 60) {
      return '${diff.inMinutes}${context.t('sidebar.unitMinute', zh: '分钟')}';
    }
    if (diff.inHours < 24) {
      return '${diff.inHours}${context.t('sidebar.unitHour', zh: '小时')}';
    }
    if (diff.inDays < 30) {
      return '${diff.inDays}${context.t('sidebar.unitDay', zh: '天')}';
    }
    return '${timestamp.year}/${timestamp.month}';
  }

  Future<void> _showContextMenu(BuildContext context) async {
    HapticFeedback.selectionClick();
    final String? action = await showDshSheet<String>(
      context: context,
      builder: (BuildContext ctx) {
        final DshPalette c = DshPalette.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      item.title,
                      style: DshType.xs13.copyWith(color: c.labelTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            _MenuItem(
              icon: item.isStarred
                  ? Icons.star_rounded
                  : Icons.star_border_rounded,
              label: item.isStarred
                  ? ctx.t('sidebar.unstar', zh: '取消收藏')
                  : ctx.t('sidebar.star', zh: '收藏'),
              onTap: () => Navigator.of(ctx).pop('star'),
            ),
            _MenuItem(
              icon: Icons.drive_file_rename_outline_rounded,
              label: ctx.t('sidebar.rename', zh: '重命名'),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            _MenuItem(
              icon: Icons.ios_share_rounded,
              label: ctx.t('sidebar.share', zh: '分享'),
              onTap: () => Navigator.of(ctx).pop('share'),
            ),
            _MenuItem(
              icon: Icons.delete_outline_rounded,
              label: ctx.t('common.delete', zh: '删除'),
              danger: true,
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
            const SizedBox(height: 6),
          ],
        );
      },
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case 'star':
        onStar?.call();
      case 'rename':
        Scaffold.of(context).closeDrawer();
        onRename?.call();
      case 'share':
        onShare?.call();
      case 'delete':
        onDelete?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showContextMenu(context),
        borderRadius: BorderRadius.circular(DshR.md),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: DshSpace.x10),
          decoration: BoxDecoration(
            color: isSelected ? c.sidebarActive : Colors.transparent,
            borderRadius: BorderRadius.circular(DshR.md),
          ),
          child: Row(
            children: <Widget>[
              if (item.isStarred) ...<Widget>[
                Icon(
                  Icons.star_rounded,
                  size: 13,
                  color: c.warnLabel,
                ),
                const SizedBox(width: DshSpace.x4),
              ],
              Expanded(
                child: Text(
                  item.title,
                  style: DshType.s14.copyWith(color: c.labelPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: DshSpace.x8),
              Text(
                _formatTimestamp(context, item.timestamp),
                style: DshType.xxs12.copyWith(color: c.labelCaption),
              ),
              if (item.unreadCount > 0) ...<Widget>[
                const SizedBox(width: DshSpace.x6),
                DshDot(color: c.business, size: 6),
              ],
              DshIconButton(
                icon: Icons.more_horiz_rounded,
                size: 28,
                iconSize: 16,
                tint: c.labelCaption,
                onTap: () => _showContextMenu(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final DshPalette c = DshPalette.of(context);
    final Color fg = danger ? c.error : c.labelPrimary;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 17, color: danger ? c.error : c.labelSecondary),
            const SizedBox(width: DshSpace.x10),
            Text(label, style: DshType.s14.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}
