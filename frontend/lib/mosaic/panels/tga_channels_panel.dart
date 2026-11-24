// 约定面板：IM 通道（微信 / QQ / 飞书）。

import 'package:flutter/material.dart';

import '../../ui/pages/tga_channels_page.dart';
import '../panel.dart';

const MosaicPanel mosaicPanel = MosaicPanel(
  id: 'channels',
  title: '通道',
  icon: 'channel',
  order: 30,
  capabilities: <MosaicCapability>[MosaicCapability.channel],
  builder: _build,
);

Widget _build(BuildContext context) => const TgaChannelsPage();
