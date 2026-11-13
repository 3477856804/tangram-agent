import 'package:flutter/material.dart';

import '../../core/theme/flai_theme.dart';

class AvatarConfig {
  final IconData? icon;

  final List<Color>? gradient;

  final Color? backgroundColor;

  final double size;

  final double borderRadius;

  final ImageProvider? image;

  final Widget? child;

  const AvatarConfig({
    this.icon,
    this.gradient,
    this.backgroundColor,
    this.size = 40,
    this.borderRadius = 20,
    this.image,
    this.child,
  });
}

class FlaiAvatar extends StatelessWidget {
  final AvatarConfig config;

  final double? sizeOverride;

  const FlaiAvatar({
    super.key,
    required this.config,
    this.sizeOverride,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FlaiTheme.of(context);
    final size = sizeOverride ?? config.size;

    if (config.child != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(config.borderRadius),
        child: SizedBox(width: size, height: size, child: config.child),
      );
    }

    if (config.image != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(config.borderRadius),
        child: Image(
          image: config.image!,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }

    final icon = config.icon ?? Icons.auto_awesome;
    final iconSize = size * 0.5;

    final Widget iconWidget = Icon(
      icon,
      size: iconSize,
      color: config.gradient != null
          ? Colors.white
          : config.backgroundColor != null
              ? Colors.white
              : theme.colors.primaryForeground,
    );

    Widget background;

    if (config.gradient != null) {
      background = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: config.gradient!,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(config.borderRadius),
        ),
        child: Center(child: iconWidget),
      );
    } else {
      background = Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: config.backgroundColor ?? theme.colors.primary,
          borderRadius: BorderRadius.circular(config.borderRadius),
        ),
        child: Center(child: iconWidget),
      );
    }

    return background;
  }
}
