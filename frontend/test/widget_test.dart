/// APP 启动 smoke test：验证根 widget 能真实构建，不引用模板里的 MyApp。

library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangram/main.dart';

void main() {
  testWidgets('TangramServices 可构建且首帧显示加载态', (WidgetTester tester) async {
    await tester.pumpWidget(const TangramServices());
    // 首帧在异步初始化完成前展示一个居中的加载指示器。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // 不允许出现任何红色错误屏（未捕获异常）。
    expect(find.byType(ErrorWidget), findsNothing);
  });
}
