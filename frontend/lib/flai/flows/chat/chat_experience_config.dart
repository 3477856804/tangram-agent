import 'package:flutter/material.dart';

import 'avatar_config.dart';

class AttachItem {
  final IconData icon;

  final String label;

  final VoidCallback? onTap;

  const AttachItem({
    required this.icon,
    required this.label,
    this.onTap,
  });

  const AttachItem.camera({this.onTap})
      : icon = Icons.camera_alt_rounded,
        label = '拍照';

  const AttachItem.photos({this.onTap})
      : icon = Icons.photo_library_rounded,
        label = '相册';

  const AttachItem.files({this.onTap})
      : icon = Icons.upload_file_rounded,
        label = '文件';
}

class ChipItem {
  final String label;

  final IconData? icon;

  final bool isDefault;

  const ChipItem({
    required this.label,
    this.icon,
    this.isDefault = false,
  });
}

sealed class AttachmentSection {
  const AttachmentSection();
}

class AttachSection extends AttachmentSection {
  final List<AttachItem> items;

  const AttachSection({required this.items});
}

class CustomSection extends AttachmentSection {
  final String title;

  final List<AttachItem> items;

  const CustomSection({required this.title, required this.items});
}

class ChipsSection extends AttachmentSection {
  final String title;

  final List<ChipItem> items;

  const ChipsSection({required this.title, required this.items});
}

class ModelOption {
  final String id;

  final String name;

  final String? description;

  final IconData? icon;

  /// 分组标题（如「云端模型」「本地模型」），选择器据此分节展示。
  final String? group;

  const ModelOption({
    required this.id,
    required this.name,
    this.description,
    this.icon,
    this.group,
  });
}

class ComposerConfig {
  final List<AttachmentSection> attachmentSections;

  const ComposerConfig({
    this.attachmentSections = defaultAttachmentSections,
  });

  static const defaultAttachmentSections = <AttachmentSection>[
    AttachSection(items: [
      AttachItem.camera(),
      AttachItem.photos(),
      AttachItem.files(),
    ]),
  ];
}

class ChatExperienceConfig {
  final String assistantName;

  final AvatarConfig? assistantAvatar;

  final String? greeting;

  final String? greetingSubtitle;

  final String? composerPlaceholder;

  final ComposerConfig composerConfig;

  final List<ModelOption> availableModels;

  final bool enableVoice;

  final bool enableGhostMode;

  final bool enablePerMessageModelSwitch;

  const ChatExperienceConfig({
    this.assistantName = 'Assistant',
    this.assistantAvatar,
    this.greeting,
    this.greetingSubtitle,
    this.composerPlaceholder,
    this.composerConfig = const ComposerConfig(),
    this.availableModels = const [],
    this.enableVoice = false,
    this.enableGhostMode = false,
    this.enablePerMessageModelSwitch = false,
  });

  String get resolvedGreeting => greeting ?? 'Hi, I\'m $assistantName';

  String get resolvedGreetingSubtitle =>
      greetingSubtitle ?? 'How can I help you today?';

  String get resolvedPlaceholder =>
      composerPlaceholder ?? 'Ask $assistantName anything...';
}
