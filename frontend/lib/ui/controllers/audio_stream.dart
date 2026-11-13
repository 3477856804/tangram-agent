
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:tangram/bridge/backend_client.dart';
import 'package:tangram/bridge/bridge_protocol.dart';

enum AudioDuplexState { idle, recording, playing, duplex, bargeIn }

class AudioStreamController extends ChangeNotifier {
  AudioStreamController(this._backend);

  final BackendClient _backend;

  bool _recording = false;
  bool get recording => _recording;

  bool _playing = false;
  bool get playing => _playing;

  bool _fullDuplex = true;
  bool get fullDuplex => _fullDuplex;

  String? _error;
  String? get error => _error;

  AudioDuplexState get state {
    if (_recording && _playing) return AudioDuplexState.duplex;
    if (_recording) return AudioDuplexState.recording;
    if (_playing) return AudioDuplexState.playing;
    return AudioDuplexState.idle;
  }

  final List<Uint8List> pcmQueue = <Uint8List>[];

  void init() {
    _backend.onHotPath
        .where(
          (e) =>
              e.channel == BridgeChannel.hotPath && e.topic == 'stream_audio',
        )
        .listen((e) {
          final p = e.payload;
          if (p is Uint8List) {
            enqueuePcm(p);
          } else if (p is List<int>) {
            enqueuePcm(Uint8List.fromList(p));
          }
        });
  }

  Future<void> startRecording() async {
    try {
      _recording = true;
      if (!_fullDuplex) {
        _playing = false;
        pcmQueue.clear();
      }
      _error = null;
      notifyListeners();
    } on Object catch (e) {
      _error = 'startRecording 失败：$e';
      notifyListeners();
    }
  }

  Future<void> stopRecording() async {
    try {
      _recording = false;
      _error = null;
      notifyListeners();
    } on Object catch (e) {
      _error = 'stopRecording 失败：$e';
      notifyListeners();
    }
  }

  void pushCapture(Uint8List pcm) {
    _backend.pushHotPath(
      BridgeEnvelope(BridgeChannel.multimodal, 'audio_pcm', pcm),
    );
  }

  void enqueuePcm(Uint8List pcm) {
    if (pcm.isEmpty) return;
    pcmQueue.add(pcm);
    notifyListeners();
    if (!_playing && pcmQueue.isNotEmpty) {
      unawaited(playNext());
    }
  }

  Future<void> playNext() async {
    if (pcmQueue.isEmpty) {
      _playing = false;
      notifyListeners();
      return;
    }
    _playing = true;
    notifyListeners();
    pcmQueue.removeAt(0);
    if (pcmQueue.isEmpty) {
      _playing = false;
    }
    notifyListeners();
  }

  void toggleFullDuplex() {
    _fullDuplex = !_fullDuplex;
    if (!_fullDuplex && _recording) {
      _playing = false;
      pcmQueue.clear();
    }
    notifyListeners();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    pcmQueue.clear();
    super.dispose();
  }
}
