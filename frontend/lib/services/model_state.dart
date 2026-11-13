
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tangram/bridge/backend_client.dart';

class ModelState extends ChangeNotifier {
  ModelState({
    String base = '',
    String chat = '',
    String adapter = '',
    String quantization = 'Q4_K_M',
    String routeBackend = 'local_gguf',
    Map<String, String> multimodal = const <String, String>{},
    String vrmPool = '',
    String vrmaPool = '',
    String routerStrategy = 'complexity_cost_latency_privacy',
  }) : _base = base,
       _chat = chat,
       _adapter = adapter,
       _quantization = quantization,
       _routeBackend = routeBackend,
       _multimodal = Map<String, String>.from(multimodal),
       _vrmPool = vrmPool,
       _vrmaPool = vrmaPool,
       _routerStrategy = routerStrategy;

  String _base;
  String _chat;
  String _adapter;
  String _quantization;
  String _routeBackend;
  Map<String, String> _multimodal;
  String _vrmPool;
  String _vrmaPool;
  String _routerStrategy;

  String get base => _base;

  String get chat => _chat;

  String get adapter => _adapter;

  String get quantization => _quantization;

  String get routeBackend => _routeBackend;

  Map<String, String> get multimodal =>
      Map<String, String>.unmodifiable(_multimodal);

  String get vrmPool => _vrmPool;

  String get vrmaPool => _vrmaPool;

  String get routerStrategy => _routerStrategy;

  bool get hasActive => _base.isNotEmpty || _chat.isNotEmpty;

  String get summary {
    final target = _chat.isNotEmpty ? _chat : _base;
    final name = target.split('/').last;
    final lora = _adapter.isEmpty
        ? '无 adapter'
        : 'adapter ${_adapter.split('/').last}';
    return '$name · $_quantization · $lora · 路由 $_routeBackend';
  }

  void loadFromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;
    loadFromJson(decoded.map((k, v) => MapEntry(k.toString(), v)));
  }

  void loadFromJson(Map<String, dynamic> json) {
    final active = json['active'];
    final a = active is Map
        ? active.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};
    final router = json['router'];
    final r = router is Map
        ? router.map((k, v) => MapEntry(k.toString(), v))
        : const <String, dynamic>{};

    _base = (a['base'] ?? '').toString();
    _chat = (a['chat'] ?? '').toString();
    _adapter = (a['adapter'] ?? '').toString();
    _vrmPool = (a['vrm_pool'] ?? '').toString();
    _vrmaPool = (a['vrma_pool'] ?? '').toString();

    final mm = a['multimodal'];
    if (mm is Map) {
      _multimodal = mm.map((k, v) => MapEntry(k.toString(), v.toString()));
    }

    _routerStrategy = (r['strategy'] ?? _routerStrategy).toString();
    _quantization = _quantizationFromPath(_chat.isNotEmpty ? _chat : _base);
    notifyListeners();
  }

  void setRouteBackend(String backend) {
    if (_routeBackend == backend) return;
    _routeBackend = backend;
    notifyListeners();
  }

  void setAdapter(String path) {
    if (_adapter == path) return;
    _adapter = path;
    notifyListeners();
  }

  static String _quantizationFromPath(String path) {
    final name = path.split('/').last;
    final m = RegExp(r'(Q\d+_K_[SM]|Q\d+_0|F16|F32|BF16)')
        .firstMatch(name.toUpperCase());
    return m?.group(1) ?? 'Q4_K_M';
  }

  Future<void> load(BackendClient client) async {
    try {
      final env = await client.sendControl('rpc', <String, dynamic>{
        'action': 'active',
        'file': 'active.json',
      });
      final payload = env.payload;
      if (payload is Map) {
        loadFromJson(payload.map((k, v) => MapEntry(k.toString(), v)));
      }
    } on Object {
    }
  }

  @override
  String toString() => 'ModelState($summary)';
}
