/// 主界面 UI 精修回归（不生成截图、不访问网络）：
///   * 侧边栏按业务分组展示真实 NavItem 列表，搜索空态可清除，小屏可滚动；
///   * 空会话快捷指令可点击并带语义；
///   * 聊天气泡（思考 / 代码块 / 错误重试）在深色与浅色主题下渲染无 overflow。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:tangram/flai/components/message_bubble/message_bubble.dart';
import 'package:tangram/flai/core/models/message.dart';
import 'package:tangram/flai/core/theme/flai_theme.dart';
import 'package:tangram/flai/flows/chat/chat_experience_config.dart';
import 'package:tangram/flai/flows/chat/screens/empty_chat_state.dart';
import 'package:tangram/flai/flows/sidebar/screens/sidebar_drawer.dart';
import 'package:tangram/flai/flows/sidebar/sidebar_config.dart';
import 'package:tangram/flai/flows/workspace/workspace_sections.dart';
import 'package:tangram/services/persona_store.dart';

void _useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 收集并清空本帧异常，只把布局类问题视为失败。
void _expectNoOverflow(WidgetTester tester, String scene) {
  final List<String> layout = <String>[];
  Object? error;
  while ((error = tester.takeException()) != null) {
    final String text = error.toString();
    if (text.contains('overflowed') ||
        text.contains('RenderFlex') ||
        text.contains('unbounded')) {
      layout.add(text);
    }
  }
  expect(
    layout,
    isEmpty,
    reason: '$scene 出现布局 overflow：\n${layout.join('\n')}',
  );
}

Future<void> _pumpSidebar(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  List<ConversationItem> recents = const <ConversationItem>[],
}) async {
  _useViewport(tester, size);
  await tester.pumpWidget(
    ChangeNotifierProvider<PersonaStore>(
      create: (_) => PersonaStore(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.light),
        home: Scaffold(
          body: FlaiSidebarDrawer(
            config: SidebarConfig(
              appName: 'TGA',
              navItems: buildWorkspaceNavItems(),
              enableSearch: true,
            ),
            recents: recents,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpEmptyState(
  WidgetTester tester, {
  required bool dark,
  ValueChanged<String>? onSuggestion,
}) async {
  _useViewport(tester, const Size(360, 640));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: FlaiTheme(
        data: dark ? FlaiThemeData.dark() : FlaiThemeData.light(),
        child: Scaffold(
          body: FlaiEmptyChatState(
            config: const ChatExperienceConfig(greeting: '你好，TGA'),
            onSuggestion: onSuggestion,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Message _assistantMessage() {
  return Message(
    id: 'assistant-polish',
    role: MessageRole.assistant,
    content: '# 结论\n\n这是**加粗**结论。\n\n'
        '```dart\n'
        'final String url = "https://example.com/a/very/long/path/that/'
        'should/not/push/the/bubble/out/of/the/screen";\n'
        '```\n\n'
        '- 要点一\n'
        '- 要点二',
    timestamp: DateTime(2026, 1, 1),
    thinkingContent: '先核对用户意图，再调用真实工具。',
    citations: const <Citation>[
      Citation(title: '示例来源', snippet: '来源摘要'),
    ],
  );
}

Message _errorMessage() {
  return Message(
    id: 'error-polish',
    role: MessageRole.assistant,
    content: '网络异常，回答中断。',
    timestamp: DateTime(2026, 1, 1),
    status: MessageStatus.error,
  );
}

Future<void> _pumpBubbles(WidgetTester tester, {required bool dark}) async {
  _useViewport(tester, const Size(360, 640));
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
      home: FlaiTheme(
        data: dark ? FlaiThemeData.dark() : FlaiThemeData.light(),
        child: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                MessageBubble(message: _assistantMessage()),
                MessageBubble(
                  message: _errorMessage(),
                  onRetry: (Message _) {},
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('侧边栏分组', () {
    testWidgets('12+ 导航项按业务分组且全部可达', (WidgetTester tester) async {
      await _pumpSidebar(tester);

      for (final String group in <String>['报告与真实', '创作', '协作', '系统']) {
        expect(find.text(group), findsOneWidget, reason: '缺少分组「$group」');
      }
      for (final String label in <String>[
        '训练设置',
        '人格设置',
        '内置沙箱',
        '模型商店',
        '工作区域',
        '私有知识库',
        '自动化工作流',
        '快照备份',
        '应用市场',
        '3D 建模',
        '更多通信',
        '模型管理',
        '多模型群聊',
        '团队协作',
        '知识图谱',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺少导航项「$label」');
      }
      // 不再截断成「更多…」。
      expect(find.text('更多…'), findsNothing);
      _expectNoOverflow(tester, '侧边栏分组');
    });

    testWidgets('小屏侧边栏可滚动且不 overflow', (WidgetTester tester) async {
      await _pumpSidebar(tester, size: const Size(320, 560));
      expect(find.byType(SingleChildScrollView), findsWidgets);
      _expectNoOverflow(tester, '小屏侧边栏');
    });

    testWidgets('会话搜索过滤后的空态可清除', (WidgetTester tester) async {
      await _pumpSidebar(
        tester,
        recents: <ConversationItem>[
          ConversationItem(
            id: 'c1',
            title: '周报整理',
            preview: '本周进展',
            timestamp: DateTime(2026, 1, 1),
          ),
        ],
      );

      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '不存在的关键词');
      await tester.pumpAndSettle();

      expect(find.textContaining('没有匹配'), findsOneWidget);
      expect(find.text('清除搜索'), findsOneWidget);
      _expectNoOverflow(tester, '搜索空态');

      await tester.tap(find.text('清除搜索'));
      await tester.pumpAndSettle();
      expect(find.text('周报整理'), findsOneWidget);
    });
  });

  group('空会话快捷指令', () {
    for (final bool dark in <bool>[false, true]) {
      testWidgets('${dark ? '深色' : '浅色'}主题渲染无 overflow 且可点击',
          (WidgetTester tester) async {
        String? tapped;
        await _pumpEmptyState(
          tester,
          dark: dark,
          onSuggestion: (String value) => tapped = value,
        );

        expect(find.text('帮我梳理这段内容'), findsOneWidget);
        expect(find.text('用一句话解释这个概念'), findsOneWidget);
        expect(find.text('帮我起草一段文案'), findsOneWidget);
        _expectNoOverflow(tester, '空态（${dark ? '深色' : '浅色'}）');

        await tester.tap(find.text('帮我梳理这段内容'));
        await tester.pumpAndSettle();
        expect(tapped, '帮我梳理这段内容');
      });
    }
  });

  group('聊天气泡', () {
    for (final bool dark in <bool>[false, true]) {
      testWidgets('${dark ? '深色' : '浅色'}主题长消息 / 错误重试无 overflow',
          (WidgetTester tester) async {
        await _pumpBubbles(tester, dark: dark);

        // 思考块与折叠提示。
        expect(find.text('思考过程'), findsOneWidget);
        expect(find.text('收起'), findsOneWidget);

        // 长消息常驻操作：代码块复制 + 气泡复制 + 错误重试。
        expect(find.text('复制'), findsAtLeastNWidgets(2));
        expect(find.text('重试'), findsOneWidget);
        expect(find.text('消息发送失败'), findsOneWidget);

        _expectNoOverflow(tester, '聊天气泡（${dark ? '深色' : '浅色'}）');

        await tester.tap(find.text('思考过程'));
        await tester.pumpAndSettle();
        expect(find.text('展开'), findsOneWidget);
        _expectNoOverflow(
          tester,
          '思考块收起（${dark ? '深色' : '浅色'}）',
        );
      });
    }
  });
}
