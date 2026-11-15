/// APP 启动 smoke test：验证根 widget 能真实构建，不引用模板里的 MyApp。


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tangram/flai/components/message_bubble/message_bubble.dart';
import 'package:tangram/flai/core/models/message.dart';
import 'package:tangram/flai/core/theme/flai_theme.dart';
import 'package:tangram/main.dart';

void main() {
  testWidgets('TangramServices 可构建且首帧显示加载态', (WidgetTester tester) async {
    await tester.pumpWidget(const TangramServices());
    // 首帧在异步初始化完成前展示一个居中的加载指示器。
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // 不允许出现任何红色错误屏（未捕获异常）。
    expect(find.byType(ErrorWidget), findsNothing);
  });

  testWidgets('思考过程默认直接显示，点击可收起再展开', (WidgetTester tester) async {
    const String thought = '先核对用户意图，再调用真实工具';
    final Message msg = Message(
      id: 'thinking-1',
      role: MessageRole.assistant,
      content: '这是最终回答',
      timestamp: DateTime(2026, 1, 1),
      thinkingContent: thought,
    );
    await tester.pumpWidget(MaterialApp(
      home: FlaiTheme(
        data: FlaiThemeData.light(),
        child: Scaffold(body: MessageBubble(message: msg)),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('思考过程'), findsOneWidget);
    expect(find.text(thought), findsOneWidget);

    final Finder body = find.byType(SizeTransition);
    expect(tester.getSize(body).height, greaterThan(10));

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(tester.getSize(body).height, lessThan(1));

    await tester.tap(find.text('思考过程'));
    await tester.pumpAndSettle();
    expect(tester.getSize(body).height, greaterThan(10));
  });
}
