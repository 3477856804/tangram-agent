// 约定面板：模型页。新增/替换面板只改本文件，不动主入口与路由表。

import 'package:flutter/material.dart';

import '../../ui/pages/tga_models_page.dart';
import '../panel.dart';

const MosaicPanel mosaicPanel = MosaicPanel(
  id: 'models',
  title: '模型',
  icon: 'model',
  order: 20,
  capabilities: <MosaicCapability>[MosaicCapability.model],
  core: true,
  builder: _build,
);

Widget _build(BuildContext context) => const TgaModelsPage();
