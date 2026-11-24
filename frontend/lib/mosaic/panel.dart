// mosaic · UI 拼装层契约（约定优于配置）。
//
// 一个面板 = 一个 Dart 文件，导出顶层常量 `mosaicPanel`；
// `tool/gen_mosaic_registry.mjs` 扫描 `lib/mosaic/panels/**.dart` 生成注册表。
// 与内核 `widget_slots`（运行时数据驱动）并存：mosaic 负责**编译期可发现**的页面，
// 内核 slots 负责插件运行时注入的部件。两者不互相替代。

import 'package:flutter/widgets.dart';

/// 面板需要的设备能力（与 Python 侧 capability 令牌同名，避免两套口径）。
enum MosaicCapability {
  net('net:fetch'),
  files('fs:read'),
  filesWrite('fs:write'),
  secure('secret:read'),
  model('model:call'),
  channel('channel:send');

  const MosaicCapability(this.token);

  final String token;
}

/// UI 面板描述。id 全局唯一，builder 返回该面板的根 widget。
class MosaicPanel {
  const MosaicPanel({
    required this.id,
    required this.title,
    required this.icon,
    required this.builder,
    this.order = 100,
    this.capabilities = const <MosaicCapability>[],
    this.core = false,
  });

  final String id;
  final String title;
  final String icon;
  final WidgetBuilder builder;
  final int order;

  /// 缺失能力时面板不出现（不显示灰按钮，直接不给）。
  final List<MosaicCapability> capabilities;

  /// core = true 的面板在安全模式下仍加载：聊天、设置、关于。
  final bool core;
}
