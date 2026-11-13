
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/bridge/bridge_protocol.dart';

class ImageItem {
  ImageItem({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class ImageController extends ChangeNotifier {
  ImageController(this._backend);

  final BackendClient _backend;

  final List<ImageItem> items = <ImageItem>[];

  bool _loading = false;
  bool get loading => _loading;

  String? _error;
  String? get error => _error;

  Future<void> pickFromGallery() => _acquire(false);

  Future<void> captureFromCamera() => _acquire(true);

  Future<void> _acquire(bool fromCamera) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final file = res?.files.isNotEmpty == true ? res!.files.first : null;
      final bytes = file?.bytes;
      if (bytes != null) {
        items.add(ImageItem(name: file!.name, bytes: bytes));
        _backend.pushHotPath(
          BridgeEnvelope(BridgeChannel.multimodal, 'image_binary', bytes),
        );
      }
    } on Object catch (e) {
      _error = '采集图片失败（${fromCamera ? '相机' : '图库'}）：$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void removeAt(int index) {
    if (index >= 0 && index < items.length) {
      items.removeAt(index);
      notifyListeners();
    }
  }

  void clear() {
    items.clear();
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }
}
