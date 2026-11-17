/// 安全策略与审计日志的真实行为测试。
///
/// 覆盖：规则匹配 / 兜底决策 / 非法正则 / 默认策略 / 序列化容错 / 策略合并，
/// 以及审计日志的追加落盘、查询、统计、导出、导入与脱敏。
/// 所有落盘都写到临时目录，测试结束即删除，不使用内存伪造。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/audit_log.dart';
import 'package:tangram/harness/security_policy.dart';
import 'package:tangram/harness/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PolicyDecision 解析', () {
    test('识别 allow / ask / deny，未知值回落 ask', () {
      expect(parsePolicyDecision('allow'), PolicyDecision.allow);
      expect(parsePolicyDecision('ask'), PolicyDecision.ask);
      expect(parsePolicyDecision('deny'), PolicyDecision.deny);
      expect(parsePolicyDecision(' ALLOW '), PolicyDecision.allow);
      expect(parsePolicyDecision('maybe'), PolicyDecision.ask);
      expect(parsePolicyDecision(''), PolicyDecision.ask);
    });
  });

  group('PermissionRule 匹配', () {
    test('三维正则同时生效，空串表示不限制', () {
      final PermissionRule rule = PermissionRule(
        id: 'r1',
        tool: r'^shell$',
        path: r'/etc/',
        args: r'\brm\b',
        decision: PolicyDecision.deny,
      );
      expect(
        rule.matches(tool: 'shell', path: '/etc/hosts', args: 'rm -f x'),
        true,
      );
      expect(
        rule.matches(tool: 'file_read', path: '/etc/hosts', args: 'rm'),
        false,
      );
      expect(
        rule.matches(tool: 'shell', path: '/workspace/a', args: 'rm'),
        false,
      );
      expect(
        rule.matches(tool: 'shell', path: '/etc/hosts', args: 'ls'),
        false,
      );

      final PermissionRule any = PermissionRule(id: 'any', tool: '');
      expect(any.matches(tool: '任意工具', path: '/a/b', args: 'x=1'), true);
    });

    test('enabled=false 的规则永不匹配', () {
      final PermissionRule rule = PermissionRule(
        id: 'off',
        tool: '.*',
        decision: PolicyDecision.allow,
        enabled: false,
      );
      expect(rule.matches(tool: 'shell'), false);
    });

    test('非法正则安全捕获并视为不匹配', () {
      final PermissionRule bad = PermissionRule(
        id: 'bad',
        tool: '([',
        decision: PolicyDecision.deny,
      );
      expect(bad.matches(tool: 'shell'), false);

      final PermissionPolicy policy = PermissionPolicy(
        rules: <PermissionRule>[
          bad,
          PermissionRule(
            id: 'ok',
            tool: r'^shell$',
            decision: PolicyDecision.allow,
          ),
        ],
        fallback: PolicyDecision.deny,
      );
      expect(policy.evaluate(tool: 'shell'), PolicyDecision.allow);
    });

    test('toJson / fromJson 往返，缺失字段用默认值', () {
      final PermissionRule rule = PermissionRule(
        id: 'r1',
        tool: r'^shell$',
        path: r'/tmp',
        args: r'ls',
        decision: PolicyDecision.deny,
        enabled: false,
        note: '说明',
      );
      final PermissionRule back = PermissionRule.fromJson(rule.toJson());
      expect(back.id, 'r1');
      expect(back.tool, r'^shell$');
      expect(back.path, r'/tmp');
      expect(back.args, 'ls');
      expect(back.decision, PolicyDecision.deny);
      expect(back.enabled, false);
      expect(back.note, '说明');

      final PermissionRule empty =
          PermissionRule.fromJson(<String, dynamic>{});
      expect(empty.id, '');
      expect(empty.tool, '');
      expect(empty.path, '');
      expect(empty.args, '');
      expect(empty.decision, PolicyDecision.ask);
      expect(empty.enabled, true);
      expect(empty.note, '');

      final PermissionRule weird = PermissionRule.fromJson(<String, dynamic>{
        'tool': 123,
        'decision': 'ALLOW',
        'enabled': 'yes',
        'note': null,
      });
      expect(weird.tool, '123');
      expect(weird.decision, PolicyDecision.allow);
      expect(weird.enabled, true);
      expect(weird.note, '');
    });
  });

  group('PermissionPolicy', () {
    test('按顺序首个匹配生效，否则 fallback', () {
      final PermissionPolicy policy = PermissionPolicy(
        rules: <PermissionRule>[
          PermissionRule(
            id: 'deny-shell',
            tool: r'^shell$',
            args: r'curl',
            decision: PolicyDecision.deny,
          ),
          PermissionRule(
            id: 'ask-shell',
            tool: r'^shell$',
            decision: PolicyDecision.ask,
          ),
          PermissionRule(
            id: 'allow-read',
            tool: r'^file_read$',
            decision: PolicyDecision.allow,
          ),
        ],
        fallback: PolicyDecision.deny,
      );
      expect(
        policy.evaluate(tool: 'shell', args: 'curl https://x'),
        PolicyDecision.deny,
      );
      expect(policy.evaluate(tool: 'shell', args: 'ls'), PolicyDecision.ask);
      expect(policy.evaluate(tool: 'file_read'), PolicyDecision.allow);
      expect(policy.evaluate(tool: 'unknown_tool'), PolicyDecision.deny);
    });

    test('withDefaults 覆盖私钥 / 破坏性命令 / 系统写 / 普通读', () {
      final PermissionPolicy policy = PermissionPolicy.withDefaults();
      expect(policy.rules.length >= 4, true);
      expect(
        policy.evaluate(tool: 'file_read', path: '/home/u/.ssh/id_rsa'),
        PolicyDecision.deny,
      );
      expect(
        policy.evaluate(tool: 'file_read', path: '/home/u/server.pem'),
        PolicyDecision.deny,
      );
      expect(
        policy.evaluate(tool: 'shell', args: 'rm -rf /tmp/build'),
        PolicyDecision.deny,
      );
      expect(
        policy.evaluate(tool: 'file_write', path: '/etc/hosts'),
        PolicyDecision.ask,
      );
      expect(
        policy.evaluate(tool: 'file_read', path: '/workspace/readme.md'),
        PolicyDecision.allow,
      );
      // 未命中任何规则且未显式放行的工具，默认仍然要问。
      expect(policy.evaluate(tool: 'unknown_tool'), PolicyDecision.ask);
    });

    test('workspace.read 普通路径直接放行', () {
      final PermissionPolicy policy = PermissionPolicy.withDefaults();
      expect(
        policy.evaluate(tool: 'workspace.read', path: '/workspace/notes.md'),
        PolicyDecision.allow,
      );
    });

    test('workspace.read 命中私钥路径仍然拒绝', () {
      final PermissionPolicy policy = PermissionPolicy.withDefaults();
      expect(
        policy.evaluate(tool: 'workspace.read', path: '/root/.ssh/id_rsa'),
        PolicyDecision.deny,
      );
    });

    test('workspace.delete 未被放行规则覆盖，落到 ask', () {
      final PermissionPolicy policy = PermissionPolicy.withDefaults();
      expect(
        policy.evaluate(tool: 'workspace.delete', path: '/workspace/notes.md'),
        PolicyDecision.ask,
      );
    });

    test('toJson / fromJson 容错', () {
      final PermissionPolicy policy = PermissionPolicy.withDefaults();
      final PermissionPolicy back = PermissionPolicy.fromJson(policy.toJson());
      expect(back.rules.length, policy.rules.length);
      expect(back.fallback, PolicyDecision.ask);
      expect(
        back.evaluate(tool: 'file_read', path: '/root/.ssh/id_rsa'),
        PolicyDecision.deny,
      );

      final PermissionPolicy broken = PermissionPolicy.fromJson(
        <String, dynamic>{
          'rules': <dynamic>[
            'not-a-map',
            42,
            <String, dynamic>{'id': 'r1', 'tool': 'shell'},
          ],
          'fallback': 'unknown',
        },
      );
      expect(broken.rules.length, 1);
      expect(broken.rules.first.id, 'r1');
      expect(broken.fallback, PolicyDecision.ask);
    });

    test('merge：other 规则与 fallback 优先，同 id 覆盖', () {
      final PermissionPolicy base = PermissionPolicy.withDefaults();
      final PermissionPolicy other = PermissionPolicy(
        rules: <PermissionRule>[
          PermissionRule(
            id: 'team-deny-curl',
            tool: r'^shell$',
            args: r'curl',
            decision: PolicyDecision.deny,
          ),
          PermissionRule(
            id: 'default-allow-read',
            tool: r'^file_read$',
            decision: PolicyDecision.ask,
            note: '团队策略收紧',
          ),
        ],
        fallback: PolicyDecision.allow,
      );
      final PermissionPolicy merged = base.merge(other);
      expect(
        merged.evaluate(tool: 'shell', args: 'curl https://x'),
        PolicyDecision.deny,
      );
      expect(merged.evaluate(tool: 'file_read'), PolicyDecision.ask);
      expect(
        merged.evaluate(tool: 'file_read', path: '/root/.ssh/id_rsa'),
        PolicyDecision.deny,
      );
      expect(merged.evaluate(tool: 'unknown_tool'), PolicyDecision.allow);
      final int sameId = merged.rules
          .where((PermissionRule r) => r.id == 'default-allow-read')
          .length;
      expect(sameId, 1);
    });
  });

  group('SecretRedactor 脱敏', () {
    test('键值形式只替换值', () {
      expect(SecretRedactor.redact('api_key=sk-live-123456'), 'api_key=***');
      expect(
        SecretRedactor.redact('{"password":"hunter2","user":"bob"}'),
        '{"password":"***","user":"bob"}',
      );
      expect(
        SecretRedactor.redact('start token=abc end'),
        'start token=*** end',
      );
    });

    test('Authorization / Bearer 整体脱敏', () {
      expect(
        SecretRedactor.redact('Authorization: Bearer eyJhbGciOi.abc-123'),
        'Authorization: Bearer ***',
      );
      expect(
        SecretRedactor.redact('curl -H "Authorization: Bearer abc.def" https://x'),
        'curl -H "Authorization: Bearer ***" https://x',
      );
    });

    test('普通文本原样保留，空串不变', () {
      const String plain = '构建成功，耗时 12s，无敏感信息。';
      expect(SecretRedactor.redact(plain), plain);
      expect(SecretRedactor.redact(''), '');
    });
  });

  group('AuditLog 真实落盘', () {
    late Directory tmp;
    late HarnessStore store;
    late AuditLog log;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tangram_audit_test_');
      HarnessStore.overrideForTest(tmp);
      store = await HarnessStore.instance();
      log = AuditLog(store: store);
    });

    tearDown(() async {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('append 追加到 audit/audit.jsonl 且 detail 已脱敏', () async {
      await log.append(
        category: 'policy',
        action: 'evaluate',
        decision: 'deny',
        actor: 'agent',
        detail: 'blocked api_key=sk-1',
      );
      final File file = File('${tmp.path}/audit/audit.jsonl');
      expect(file.existsSync(), true);
      final List<String> lines = const LineSplitter()
          .convert(file.readAsStringSync())
          .where((String l) => l.trim().isNotEmpty)
          .toList();
      expect(lines.length, 1);
      expect(file.readAsStringSync().contains('sk-1'), false);

      final Map<String, dynamic> decoded =
          jsonDecode(lines.first) as Map<String, dynamic>;
      expect(decoded['category'], 'policy');
      expect(decoded['action'], 'evaluate');
      expect(decoded['decision'], 'deny');
      expect(decoded['actor'], 'agent');
      expect(decoded['detail'], 'blocked api_key=***');
      expect(decoded['id'].toString().isNotEmpty, true);
      expect(decoded['ts'] is num, true);
    });

    test('all 保序读取；query 支持分类 / since / limit', () async {
      await log.append(
        category: 'policy',
        action: 'evaluate',
        decision: 'deny',
      );
      await log.append(
        category: 'tool',
        action: 'shell',
        decision: 'ask',
        detail: 'rm -rf?',
      );
      await log.append(
        category: 'policy',
        action: 'evaluate',
        decision: 'allow',
      );

      final List<AuditEvent> events = await log.all();
      expect(events.length, 3);
      expect(events.map((AuditEvent e) => e.action).toList(),
          <String>['evaluate', 'shell', 'evaluate']);
      expect(events[1].detail, 'rm -rf?');
      for (final AuditEvent e in events) {
        expect(e.ts > 0, true);
      }

      final List<AuditEvent> policyEvents = await log.query(category: 'policy');
      expect(policyEvents.length, 2);

      final List<AuditEvent> sinceLast =
          await log.query(since: events[2].ts);
      expect(sinceLast.length, 1);
      expect(sinceLast.first.decision, 'allow');

      final List<AuditEvent> lastOne = await log.query(limit: 1);
      expect(lastOne.length, 1);
      expect(lastOne.first.decision, 'allow');

      expect((await log.query(limit: 0)).isEmpty, true);
      expect((await log.query(category: 'nope')).isEmpty, true);
    });

    test('stats 统计总数与分类 / 决策计数', () async {
      expect((await log.stats())['total'], 0);

      await log.append(category: 'policy', action: 'evaluate', decision: 'deny');
      await log.append(category: 'tool', action: 'shell', decision: 'ask');
      await log.append(category: 'policy', action: 'evaluate', decision: 'allow');

      final Map<String, dynamic> stats = await log.stats();
      expect(stats['total'], 3);
      final Map<String, dynamic> byCategory =
          stats['by_category'] as Map<String, dynamic>;
      expect(byCategory['policy'], 2);
      expect(byCategory['tool'], 1);
      final Map<String, dynamic> byDecision =
          stats['by_decision'] as Map<String, dynamic>;
      expect(byDecision['deny'], 1);
      expect(byDecision['ask'], 1);
      expect(byDecision['allow'], 1);
    });

    test('export / import 往返，坏行跳过并计数', () async {
      await log.append(category: 'policy', action: 'evaluate', decision: 'deny');
      await log.append(category: 'tool', action: 'shell', decision: 'ask');
      final String exported = await log.exportJsonl();
      expect(exported.contains('"category":"policy"'), true);

      final Directory tmp2 =
          Directory.systemTemp.createTempSync('tangram_audit_import_');
      HarnessStore.overrideForTest(tmp2);
      final HarnessStore store2 = await HarnessStore.instance();
      final AuditLog log2 = AuditLog(store: store2);

      const String badLines = 'not json\n[]\n{"id":"partial"}\n\n';
      const String dirty =
          '{"id":"x1","category":"net","action":"http","decision":"info",'
          '"actor":"agent","detail":"password=p1","ts":1.5}\n';
      final int imported =
          await log2.importJsonl('$badLines$exported$dirty');
      expect(imported, 3);

      final List<AuditEvent> restored = await log2.all();
      expect(restored.length, 3);
      expect(restored.first.action, 'evaluate');
      expect(restored.last.category, 'net');
      expect(restored.last.detail, 'password=***');
      expect(restored.last.ts, 1.5);
      expect(
        File('${tmp2.path}/audit/audit.jsonl').readAsStringSync().contains('p1'),
        false,
      );

      tmp2.deleteSync(recursive: true);
    });
  });

  group('AuditEvent 序列化', () {
    test('往返与容错', () {
      final AuditEvent event = AuditEvent(
        id: 'a1',
        category: 'tool',
        action: 'shell',
        decision: 'ask',
        actor: 'user',
        detail: 'x',
        ts: 12.5,
      );
      final AuditEvent back = AuditEvent.fromJson(event.toJson());
      expect(back.id, 'a1');
      expect(back.category, 'tool');
      expect(back.action, 'shell');
      expect(back.decision, 'ask');
      expect(back.actor, 'user');
      expect(back.detail, 'x');
      expect(back.ts, 12.5);

      final AuditEvent empty = AuditEvent.fromJson(<String, dynamic>{});
      expect(empty.id, '');
      expect(empty.decision, 'info');
      expect(empty.actor, 'system');
      expect(empty.ts, 0);

      final AuditEvent parsedTs =
          AuditEvent.fromJson(<String, dynamic>{'ts': '7.25'});
      expect(parsedTs.ts, 7.25);
    });

    test('空 hash 不落 JSON 字段，旧数据读回为空 hash', () {
      final AuditEvent plain = AuditEvent(
        id: 'a2',
        category: 'tool',
        action: 'shell',
        ts: 1.5,
      );
      expect(plain.toJson().containsKey('prevHash'), false);
      expect(plain.toJson().containsKey('hash'), false);

      final AuditEvent legacy = AuditEvent.fromJson(<String, dynamic>{
        'id': 'old',
        'category': 'tool',
        'action': 'shell',
        'ts': 1.0,
      });
      expect(legacy.prevHash, '');
      expect(legacy.hash, '');
      expect(legacy.computeHash().length, 64);
    });
  });

  group('AuditLog 防篡改哈希链', () {
    late Directory tmp;
    late HarnessStore store;
    late AuditLog log;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('tangram_audit_chain_');
      HarnessStore.overrideForTest(tmp);
      store = await HarnessStore.instance();
      log = AuditLog(store: store);
    });

    tearDown(() async {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File auditFile() => File('${tmp.path}/audit/audit.jsonl');

    List<Map<String, dynamic>> readLines() => const LineSplitter()
        .convert(auditFile().readAsStringSync())
        .where((String l) => l.trim().isNotEmpty)
        .map((String l) => jsonDecode(l) as Map<String, dynamic>)
        .toList();

    test('追加 3 条后哈希链校验通过且前后串联', () async {
      await log.append(category: 'policy', action: 'evaluate', decision: 'deny');
      await log.append(
        category: 'tool',
        action: 'shell',
        decision: 'ask',
        detail: 'rm -rf?',
      );
      await log.append(category: 'policy', action: 'evaluate', decision: 'allow');

      final List<Map<String, dynamic>> lines = readLines();
      expect(lines.length, 3);
      expect(lines[0].containsKey('prevHash'), false);
      expect(lines[0]['hash'].toString().length, 64);
      expect(lines[1]['prevHash'], lines[0]['hash']);
      expect(lines[2]['prevHash'], lines[1]['hash']);

      final Map<String, dynamic> result = await log.verifyChain();
      expect(result['ok'], true);
      expect(result['total'], 3);
      expect(result['broken_at'], null);
      expect(result['legacy'], 0);
      expect(result['reason'].toString().isNotEmpty, true);
    });

    test('改写第二条 detail 后校验失败且 broken_at=1', () async {
      await log.append(category: 'policy', action: 'evaluate', decision: 'deny');
      await log.append(
        category: 'tool',
        action: 'shell',
        decision: 'ask',
        detail: 'ok',
      );
      await log.append(category: 'policy', action: 'evaluate', decision: 'allow');
      expect((await log.verifyChain())['ok'], true);

      final List<Map<String, dynamic>> lines = readLines();
      lines[1]['detail'] = 'tampered';
      auditFile().writeAsStringSync(
        lines.map((Map<String, dynamic> l) => jsonEncode(l)).join('\n') + '\n',
      );

      final Map<String, dynamic> result = await log.verifyChain();
      expect(result['ok'], false);
      expect(result['broken_at'], 1);
      expect(result['total'], 3);
      expect(result['reason'].toString().contains('hash'), true);
    });

    test('旧格式无 hash 行跳过校验并计入 legacy', () async {
      await log.append(category: 'policy', action: 'evaluate', decision: 'deny');
      // 直接追加一行历史格式（无 prevHash/hash）的事件。
      auditFile().writeAsStringSync(
        '{"id":"legacy-1","category":"tool","action":"shell",'
        '"decision":"info","actor":"system","detail":"old","ts":1.5}\n',
        mode: FileMode.append,
      );

      final Map<String, dynamic> result = await log.verifyChain();
      expect(result['ok'], true);
      expect(result['total'], 2);
      expect(result['broken_at'], null);
      expect(result['legacy'], 1);

      final List<AuditEvent> events = await log.all();
      expect(events.length, 2);
      expect(events.last.hash, '');
      expect((await log.exportJsonl()).contains('"hash"'), true);
    });
  });
}
