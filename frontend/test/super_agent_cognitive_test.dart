/// Super Agent L3 认知闭环测试。
///
/// 只依赖 SuperAgent + HarnessStore，不加载 embedded_backend、不访问网络。
/// fake chat 对 clarify / implicit_goal / risk_scan / options / 复盘 请求返回
/// 严格 JSON，其它请求返回逐步变化的文本；所有断言都基于真实调用与真实落盘。

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/super_agent.dart';

Map<String, dynamic> _reply(String text) => <String, dynamic>{
      'ok': true,
      'engine': 'remote-http',
      'reply': text,
    };

/// 等待工单进入终态且 Worker 真正退出（避免 finally 尚未清理的竞态）；
/// 返回前最多轮询约 4 秒。
Future<void> _waitDone(SuperAgent sa, String id) async {
  for (int i = 0; i < 80; i++) {
    final Map<String, dynamic> r =
        await sa.handle('ticket', <String, dynamic>{'id': id});
    if (r['ok'] == true && r['ticket'] is Map) {
      final String status = ((r['ticket'] as Map)['status'] ?? '').toString();
      final bool terminal =
          status == 'done' || status == 'failed' || status == 'stopped';
      if (terminal && sa.runningCount == 0) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory tmp;
  late HarnessStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_sa_cognitive_');
    for (final String sub in <String>[
      'models',
      'cards',
      'plugins',
      'work',
      'downloads',
      'sandbox',
    ]) {
      await Directory('${tmp.path}/$sub').create(recursive: true);
    }
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
  });

  tearDown(() async {
    for (int i = 0; i < 6; i++) {
      try {
        if (await tmp.exists()) await tmp.delete(recursive: true);
        return;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }
  });

  SuperAgent buildAgent({List<String>? prompts}) {
    int step = 0;
    return SuperAgent(
      store: store,
      chat: (Map<String, dynamic> p) async {
        final String text = (p['text'] ?? '').toString();
        prompts?.add(text);
        // 澄清：clarity 优先于 implicit_goal（澄清 prompt 也列出该字段名）。
        if (text.contains('clarify')) {
          return _reply(jsonEncode(<String, dynamic>{
            'questions': <String>[
              '在哪个平台/版本上复现？',
              '期望的验收标准是什么？',
            ],
            'implicit_goal': '让登录流程在弱网下稳定可用',
            'missing_conditions': <String>['目标平台', '可接受延迟阈值'],
            'acceptance_criteria': <String>['弱网登录成功率 ≥ 99%'],
          }));
        }
        if (text.contains('implicit_goal')) {
          return _reply(jsonEncode(<String, dynamic>{
            'surface_instruction': '修一下登录',
            'implicit_goal': '降低登录失败率并保证可回滚',
            'confirm_points': <String>['是否允许改动认证服务配置'],
          }));
        }
        if (text.contains('risk_scan')) {
          return _reply(jsonEncode(<String, dynamic>{
            'risks': <Map<String, dynamic>>[
              <String, dynamic>{
                'level': 'medium',
                'type': 'data_loss',
                'detail': '模型补充：备份窗口内可能丢失增量数据',
                'mitigation': '先确认快照与备份窗口',
              },
            ],
          }));
        }
        if (text.contains('options')) {
          return _reply(jsonEncode(<String, dynamic>{
            'options': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': '热修复认证层',
                'benefits': <String>['见效快'],
                'costs': <String>['改动面集中'],
                'risks': <String>['可能引入回归'],
                'fit': '紧急上线',
                'tradeoff': '速度优先',
              },
              <String, dynamic>{
                'name': '重构会话管理',
                'benefits': <String>['长期稳定'],
                'costs': <String>['工期长'],
                'risks': <String>['范围大'],
                'fit': '季度规划',
                'tradeoff': '稳定优先',
              },
              <String, dynamic>{
                'name': '增加降级重试',
                'benefits': <String>['风险最低'],
                'costs': <String>['收益有限'],
                'risks': <String>['可能掩盖根因'],
                'fit': '小步验证',
                'tradeoff': '成本优先',
              },
            ],
            'recommendation': '先加降级重试，再排期热修复',
          }));
        }
        if (text.contains('复盘')) {
          return _reply(jsonEncode(<String, dynamic>{
            'goal_match': true,
            'drift': false,
            'constraint_violation': false,
            'errors': <String>[],
            'better_path': '保持当前路径',
            'confidence': 0.9,
          }));
        }
        step += 1;
        return _reply('第 $step 步真实结果');
      },
    );
  }

  group('SuperAgent L3 认知闭环', () {
    test('clarify：结构化产出问题/隐性目标/缺失条件/验收标准并真实落盘', () async {
      final SuperAgent sa = buildAgent();
      final Map<String, dynamic> r =
          await sa.handle('clarify', <String, dynamic>{'goal': '修好登录'});
      expect(r['ok'], true);
      expect(r['structured'], true);
      expect(r['engine'], 'remote-http');
      expect(r['implicit_goal'].toString(), contains('弱网'));
      expect((r['questions'] as List).length, 2);
      expect((r['missing_conditions'] as List), isNotEmpty);
      expect((r['acceptance_criteria'] as List), isNotEmpty);

      final List<Map<String, dynamic>> saved =
          await store.readRecords('super_clarifications');
      expect(saved.length, 1);
      expect(saved.single['goal'], '修好登录');
      expect(saved.single['structured'], true);
      expect(saved.single['engine'], 'remote-http');
    });

    test('clarify：JSON 解析失败如实标记 unstructured，不编造结论', () async {
      final SuperAgent sa = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async => _reply('抱歉，我无法判断。'),
      );
      final Map<String, dynamic> r =
          await sa.handle('clarify', <String, dynamic>{'goal': '一个模糊目标'});
      expect(r['ok'], true);
      expect(r['structured'], false);
      expect(r['questions'], isEmpty);
      expect(r['implicit_goal'], '');
      final List<Map<String, dynamic>> saved =
          await store.readRecords('super_clarifications');
      expect(saved.single['structured'], false);
      expect(saved.single['raw'], '抱歉，我无法判断。');
    });

    test('implicit_goal：表层指令/隐性目标/确认点写入决策日志', () async {
      final SuperAgent sa = buildAgent();
      final Map<String, dynamic> r = await sa.handle(
          'implicit_goal', <String, dynamic>{'goal': '修一下登录'});
      expect(r['ok'], true);
      expect(r['structured'], true);
      expect(r['surface_instruction'], '修一下登录');
      expect(r['implicit_goal'].toString(), contains('登录失败率'));
      expect((r['confirm_points'] as List), isNotEmpty);

      final List<Map<String, dynamic>> log =
          await store.readRecords('super_decision_log');
      final Map<String, dynamic> entry = log.firstWhere(
          (Map<String, dynamic> e) => e['kind'] == 'implicit_goal');
      expect(entry['implicit_goal'].toString(), contains('登录失败率'));
      expect(entry['confirm_points'], isA<List>());
    });

    test('risk_scan：规则命中高危 + Mandate 越界 + 模型补充 + 自动审计', () async {
      final SuperAgent sa = buildAgent();
      final Map<String, dynamic> mandate = <String, dynamic>{
        'scope': 'source=manual',
        'allowed_tools': <String>['chat'],
      };
      final Map<String, dynamic> r = await sa.handle(
          'risk_scan', <String, dynamic>{
        'goal': '批量删除生产环境数据库并覆盖密钥，再部署上线',
        'mandate': mandate,
        'tools': <String>['shell', 'chat'],
      });
      expect(r['ok'], true);
      expect(r['high_risk'], true);
      expect(r['mandate_unchanged'], true);
      expect(mandate['allowed_tools'], <String>['chat']);

      final List<dynamic> risks = r['risks'] as List;
      expect(risks, isNotEmpty);
      for (final dynamic raw in risks) {
        final Map<String, dynamic> risk = Map<String, dynamic>.from(raw as Map);
        expect(risk.containsKey('level'), true);
        expect(risk.containsKey('type'), true);
        expect(risk.containsKey('detail'), true);
        expect(risk.containsKey('mitigation'), true);
      }
      expect(
          risks.any((dynamic raw) =>
              (raw as Map)['type'] == 'destructive' &&
              raw['level'] == 'high'),
          true);
      expect(
          risks.any((dynamic raw) => (raw as Map)['type'] == 'mandate'),
          true,
          reason: '请求 shell 超出 Mandate 应如实报越界');
      expect(
          risks.any((dynamic raw) => (raw as Map)['source'] == 'model'),
          true,
          reason: '模型补充的风险应被合并');

      expect(r['audit_logged'], true);
      expect(r['audit_count'], greaterThan(0));
      final List<Map<String, dynamic>> audits =
          await store.readRecords('super_audit_events');
      expect(audits, isNotEmpty);
      expect(audits.first['goal'], contains('批量删除'));
    });

    test('options：给出 2-3 条路线，字段齐全并持久化', () async {
      final SuperAgent sa = buildAgent();
      final Map<String, dynamic> r = await sa.handle(
          'options', <String, dynamic>{
        'goal': '选择登录修复路线',
        'constraints': <String>['不得改动生产配置'],
      });
      expect(r['ok'], true);
      expect(r['structured'], true);
      expect(r['meets_route_range'], true);
      final List<dynamic> options = r['options'] as List;
      expect(options.length, greaterThanOrEqualTo(2));
      expect(options.length, lessThanOrEqualTo(3));
      for (final dynamic raw in options) {
        final Map<String, dynamic> o = Map<String, dynamic>.from(raw as Map);
        expect(o['name'].toString(), isNotEmpty);
        expect(o['benefits'], isA<List>());
        expect(o['costs'], isA<List>());
        expect(o['risks'], isA<List>());
        expect(o['fit'].toString(), isNotEmpty);
        expect(o['tradeoff'].toString(), isNotEmpty);
      }
      expect(r['recommendation'].toString(), contains('降级重试'));

      final List<Map<String, dynamic>> saved =
          await store.readRecords('super_options');
      expect(saved.length, 1);
      expect((saved.single['options'] as List).length, 3);
    });

    test('decision_log：追加式记录，汇总 decisions/reviews/options/clarifications',
        () async {
      final SuperAgent sa = buildAgent();
      await sa.handle('clarify', <String, dynamic>{'goal': '澄清登录目标'});
      await sa.handle('options', <String, dynamic>{'goal': '选择登录修复路线'});
      final Map<String, dynamic> created = await sa.handle(
          'create_direct', <String, dynamic>{
        'goal': '两步任务',
        'mandate': <String, dynamic>{'max_steps': 2},
      });
      expect(created['ok'], true);
      final String ticketId = created['id'].toString();
      await _waitDone(sa, ticketId);

      final Map<String, dynamic> first =
          await sa.handle('log_decision', <String, dynamic>{
        'choice': '先加降级重试',
        'options_considered': <String>['热修复', '重构会话', '降级重试'],
        'reason': '风险最低且可快速验证',
        'constraints': <String>['不得改动生产配置'],
        'rejected': <String>['直接改生产配置'],
        'ticket_id': ticketId,
      });
      expect(first['ok'], true);
      await sa.handle('log_decision', <String, dynamic>{
        'choice': '方案B',
        'reason': '后续排期',
      });

      final Map<String, dynamic> agg = await sa.handle(
          'decision_log', <String, dynamic>{'limit': 10});
      expect(agg['ok'], true);
      final List<dynamic> decisionsLogged = agg['decision_log'] as List;
      expect(decisionsLogged.length, 2);
      expect((decisionsLogged.first as Map)['choice'], '方案B');
      expect((agg['clarifications'] as List), isNotEmpty);
      expect((agg['options'] as List), isNotEmpty);
      expect((agg['reviews'] as List), isNotEmpty,
          reason: '两步工单收尾应触发阶段复盘并进入汇总');
      expect(agg['decisions'], isA<List>());

      final List<Map<String, dynamic>> stored =
          await store.readRecords('super_decision_log');
      expect(stored.length, 2);
      expect(stored.first['choice'], '先加降级重试');
      expect(stored.first['ticket_id'], ticketId);
    });

    test('revise：追加反馈并重新入队；running 工单拒绝改动', () async {
      final SuperAgent sa = buildAgent();
      final Map<String, dynamic> created = await sa.handle(
          'create_direct', <String, dynamic>{
        'goal': '需要修订的任务',
        'mandate': <String, dynamic>{'max_steps': 1},
      });
      final String id = created['id'].toString();
      await _waitDone(sa, id);
      final Map<String, dynamic> before =
          await sa.handle('ticket', <String, dynamic>{'id': id});
      expect((before['ticket'] as Map)['status'], 'done');

      final Map<String, dynamic> revised = await sa.handle(
          'revise', <String, dynamic>{
        'id': id,
        'feedback': '补充验收标准：必须可回滚',
      });
      expect(revised['ok'], true);
      expect(revised['requeued'], true);
      expect(<String>['running', 'queued'], contains(revised['status']));
      final Map<String, dynamic> revisedTicket =
          Map<String, dynamic>.from(revised['ticket'] as Map);
      expect((revisedTicket['history'] as List).join('\n'),
          contains('补充验收标准：必须可回滚'));
      await _waitDone(sa, id);

      // 运行中的工单不允许修订，避免破坏步数账本。
      final SuperAgent slow = SuperAgent(
        store: store,
        chat: (Map<String, dynamic> p) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return _reply('慢速真实结果');
        },
      );
      final Map<String, dynamic> running = await slow.handle(
          'create_direct', <String, dynamic>{
        'goal': '运行中的任务',
        'mandate': <String, dynamic>{'max_steps': 2},
      });
      final String runningId = running['id'].toString();
      final Map<String, dynamic> rejected = await slow.handle(
          'revise', <String, dynamic>{
        'id': runningId,
        'feedback': '运行中改动',
      });
      expect(rejected['ok'], false);
      expect(rejected['error'].toString(), contains('运行中'));
      await _waitDone(slow, runningId);
    });

    test('subagent：persona/role 注入 Worker prompt，Mandate 不扩张', () async {
      final List<String> prompts = <String>[];
      final SuperAgent sa = buildAgent(prompts: prompts);
      final Map<String, dynamic> parent = await sa.handle(
          'create_direct', <String, dynamic>{
        'goal': '父级任务',
        'mandate': <String, dynamic>{
          'max_steps': 2,
          'deadline_seconds': 120,
        },
      });
      final String parentId = parent['id'].toString();
      final Map<String, dynamic> child = await sa.handle(
          'subagent', <String, dynamic>{
        'id': parentId,
        'goal': '独立安全审查',
        'role': '安全审计员',
        'persona': <String, dynamic>{
          'name': '林舟',
          'identity': '安全审计员',
          'personality': '严谨克制',
          'audience': '开发团队',
        },
      });
      expect(child['ok'], true);
      final Map<String, dynamic> ct =
          Map<String, dynamic>.from(child['ticket'] as Map);
      expect(ct['role'], '安全审计员');
      expect((ct['persona'] as Map)['name'], '林舟');
      final Map<String, dynamic> mandate =
          Map<String, dynamic>.from(ct['mandate'] as Map);
      expect(mandate['scope'].toString(), contains('沿用不扩张'));
      expect((mandate['max_steps'] as num) <= 2, true);

      await _waitDone(sa, ct['id'].toString());
      final List<String> rolePrompts =
          prompts.where((String t) => t.contains('安全审计员')).toList();
      expect(rolePrompts, isNotEmpty,
          reason: '子工单 Worker prompt 应包含角色设定');
      final String joined = rolePrompts.join('\n');
      expect(joined, contains('人格设定'));
      expect(joined, contains('林舟'));
      expect(joined, contains('严谨克制'));
      expect(joined, contains('受众=开发团队'));
    });
  });
}
