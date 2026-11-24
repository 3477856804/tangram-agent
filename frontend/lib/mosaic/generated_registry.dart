// 自动生成，请勿手改。重新生成：node tool/gen_mosaic_registry.mjs
import 'package:flutter/widgets.dart';

import '../panel.dart';
import 'panels/tga_channels_panel.dart' as tga_channels_panel;
import 'panels/tga_models_panel.dart' as tga_models_panel;

/// 约定加载：每个面板文件导出顶层常量 `mosaicPanel`，此处集中登记。
List<MosaicPanel> tgaPanels() => <MosaicPanel>[
      tga_channels_panel.mosaicPanel,
      tga_models_panel.mosaicPanel,
    ];
