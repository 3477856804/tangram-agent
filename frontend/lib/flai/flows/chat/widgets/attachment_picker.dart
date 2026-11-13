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
}
