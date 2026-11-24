// mosaic · 注册表：登记、查找、按能力过滤、热替换（不重建整个 App）。

import 'package:flutter/widgets.dart';

import 'panel.dart';

class MosaicRegistry {
  MosaicRegistry({List<MosaicPanel>? panels}) {
    for (final MosaicPanel p in panels ?? const <MosaicPanel>[]) {
      register(p);
    }
  }

  final Map<String, MosaicPanel> _byId = <String, MosaicPanel>{};
  final List<String> order = <String>[];

  void register(MosaicPanel panel) {
    if (_byId.containsKey(panel.id)) {
      throw StateError('面板 id 重复: ${panel.id}（一个能力只能有一处实现）');
    }
    _byId[panel.id] = panel;
    order.add(panel.id);
    order.sort((String a, String b) {
      final MosaicPanel pa = _byId[a]!;
      final MosaicPanel pb = _byId[b]!;
      return pa.order == pb.order ? a.compareTo(b) : pa.order.compareTo(pb.order);
    });
  }

  /// 热替换：移除不满足条件的面板（插件卸载用），不重建 App。
  void replaceWhere(bool Function(MosaicPanel) keep) {
    final List<String> removed =
        _byId.keys.where((String id) => !keep(_byId[id]!)).toList();
    for (final String id in removed) {
      _byId.remove(id);
      order.remove(id);
    }
  }

  MosaicPanel? find(String id) => _byId[id];

  /// 按设备实际拥有的能力过滤；core 面板不受限（安全模式仍可进）。
  List<MosaicPanel> visible(Set<MosaicCapability> available,
      {bool safeMode = false}) {
    final List<MosaicPanel> out = <MosaicPanel>[];
    for (final String id in order) {
      final MosaicPanel p = _byId[id]!;
      if (safeMode) {
        if (p.core) out.add(p);
        continue;
      }
      if (p.capabilities.every(available.contains)) out.add(p);
    }
    return out;
  }

  List<String> describe() =>
      order.map((String id) => '$id(${_byId[id]!.title})').toList();
}
