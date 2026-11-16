import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

class PickedAttachment {
  final String path;

  final String name;

  final String? mimeType;

  final int? sizeBytes;

  const PickedAttachment({
    required this.path,
    required this.name,
    this.mimeType,
    this.sizeBytes,
  });

  File get file => File(path);
}

/// 附件选择入口：中文文案由菜单统一使用，避免出现英文标签。
class FlaiAttachmentPicker {
  FlaiAttachmentPicker._();

  static const String cameraLabel = '拍照';
  static const String photosLabel = '相册';
  static const String filesLabel = '文件';
  static const String audioLabel = '录音文件';

  /// 常见录音容器：m4a（微信/QQ 默认）、mp3、wav、aac、ogg、flac、webm。
  static const List<String> audioExtensions = <String>[
    'm4a', 'mp3', 'wav', 'aac', 'ogg', 'flac', 'webm', 'amr', 'opus',
  ];

  static final _imagePicker = ImagePicker();

  static Future<PickedAttachment?> openCamera() async {
    final image = await _imagePicker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (image == null) return null;
    return PickedAttachment(
      path: image.path,
      name: image.name,
      mimeType: image.mimeType,
      sizeBytes: await image.length(),
    );
  }

  static Future<PickedAttachment?> openPhotos() async {
    final image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
    );
    if (image == null) return null;
    return PickedAttachment(
      path: image.path,
      name: image.name,
      mimeType: image.mimeType,
      sizeBytes: await image.length(),
    );
  }

  static Future<PickedAttachment?> openFiles() async {
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    if (file.path == null) return null;
    return PickedAttachment(
      path: file.path!,
      name: file.name,
      sizeBytes: file.size,
    );
  }

  /// 选择录音文件（真实文件），仅过滤扩展名，不做任何内容伪造。
  static Future<PickedAttachment?> openAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: audioExtensions,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    if (file.path == null) return null;
    return PickedAttachment(
      path: file.path!,
      name: file.name,
      mimeType: _mimeOf(file.name),
      sizeBytes: file.size,
    );
  }

  static String _mimeOf(String name) {
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'm4a':
        return 'audio/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      case 'flac':
        return 'audio/flac';
      case 'webm':
        return 'audio/webm';
      default:
        return 'audio/*';
    }
  }
}
