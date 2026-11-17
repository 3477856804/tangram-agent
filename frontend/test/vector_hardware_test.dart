/// 向量存储 / 混合检索 / 硬件自适应调度的真实行为测试。
///
/// 本地向量真实落盘并重新加载；远程未配置时明确报错；知识库降级时
/// 如实标注 degraded；硬件探针失败不抛异常。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/hardware_scheduler.dart';
import 'package:tangram/harness/knowledge_base.dart';
import 'package:tangram/harness/store.dart';
import 'package:tangram/harness/vector_store.dart';

class _FailingVectorStore implements VectorStore {
  @override
  String get backendName => 'failing';

  @override
  bool get available => false;

  @override
  Future<void> upsert(
    String collection,
    String id,
    List<double> vector, [
    Map<String, dynamic> metadata = const <String, dynamic>{},
  ]) async {
    throw VectorStoreException('测试用向量库不可用', code: 'not_configured');
  }

  @override
  Future<List<VectorMatch>> query(
    String collection,
    List<double> vector, [
    int topK = 8,
  ]) async {
    throw VectorStoreException('测试用向量库不可用', code: 'not_configured');
  }

  @override
  Future<void> delete(String collection, String id) async {
    throw VectorStoreException('测试用向量库不可用', code: 'not_configured');
  }

  @override
  Future<Map<String, dynamic>> stats(String collection) async {
    throw VectorStoreException('测试用向量库不可用', code: 'not_configured');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late HarnessStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tangram_vec_hw_');
    HarnessStore.overrideForTest(tmp);
    store = await HarnessStore.instance();
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    try {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    } on FileSystemException {
      // 后台落盘竞态不影响断言。
    }
  });

  group('LocalHashedVectorStore：真实落盘 / 余弦排序 / 维度校验', () {
    test('upsert 后重新实例化仍可查询（落盘可恢复）', () async {
      final LocalHashedVectorStore first = LocalHashedVectorStore(store);
      await first.upsert(
        'demo',
        'a',
        HashingTrick.embed('苹果 香蕉 水果'),
        <String, dynamic>{'kind': 'fruit'},
      );
      final File file = store.file('vectors/demo.json');
      expect(await file.exists(), true);

      final LocalHashedVectorStore second = LocalHashedVectorStore(store);
      final Map<String, dynamic> stats = await second.stats('demo');
      expect(stats['count'], 1);
      expect(stats['dimensions'], 256);
      expect(stats['backend'], 'local');

      final List<VectorMatch> matches =
          await second.query('demo', HashingTrick.embed('苹果'), 3);
      expect(matches.length, 1);
      expect(matches.first.id, 'a');
      expect(matches.first.metadata['kind'], 'fruit');
      expect(matches.first.score, greaterThan(0));
    });

    test('余弦相似度按相关度排序', () async {
      final LocalHashedVectorStore local = LocalHashedVectorStore(store);
      await local.upsert(
          'demo', 'apple', HashingTrick.embed('苹果 苹果 香蕉 水果'));
      await local.upsert(
          'demo', 'car', HashingTrick.embed('汽车 轮胎 发动机 底盘'));
      await local.upsert(
          'demo', 'mixed', HashingTrick.embed('苹果 汽车 水果 轮胎'));

      final List<VectorMatch> matches =
          await local.query('demo', HashingTrick.embed('苹果'), 3);
      expect(matches.first.id, 'apple');
      expect(matches.first.score >= matches[1].score, true);
      expect(matches[1].score >= matches[2].score, true);
      expect(matches.map((VectorMatch m) => m.id).toSet(), <String>{
        'apple',
        'car',
        'mixed',
      });
    });

    test('空向量 / 维度不符被明确拒绝', () async {
      final LocalHashedVectorStore local = LocalHashedVectorStore(store);
      await expectLater(
        local.upsert('demo', 'bad', List<double>.filled(10, 1)),
        throwsA(isA<VectorStoreException>()),
      );
      await expectLater(
        local.upsert('demo', 'zero', List<double>.filled(256, 0)),
        throwsA(isA<VectorStoreException>()),
      );
      await expectLater(
        local.upsert('demo', 'empty', <double>[]),
        throwsA(isA<VectorStoreException>()),
      );
      await local.upsert('demo', 'ok', HashingTrick.embed('正常文本'));
      await expectLater(
        local.query('demo', List<double>.filled(128, 1), 1),
        throwsA(isA<VectorStoreException>()),
      );
      expect(() => HashingTrick.embed(''), throwsA(isA<VectorStoreException>()));
    });
  });

  group('RemoteVectorStore：未配置明确不可用', () {
    test('空 baseUrl 时 available=false 且所有操作如实报错', () async {
      final RemoteVectorStore remote = RemoteVectorStore(
        style: 'qdrant',
        baseUrl: '',
        collection: 'kb',
      );
      expect(remote.available, false);
      await expectLater(
        remote.upsert('kb', 'a', HashingTrick.embed('文本')),
        throwsA(predicate((Object e) =>
            e is VectorStoreException && e.code == 'not_configured')),
      );
      await expectLater(
        remote.query('kb', HashingTrick.embed('文本'), 3),
        throwsA(predicate((Object e) =>
            e is VectorStoreException && e.code == 'not_configured')),
      );
      await expectLater(
        remote.stats('kb'),
        throwsA(predicate((Object e) =>
            e is VectorStoreException && e.code == 'not_configured')),
      );

      final VectorStore factory = VectorStoreFactory.create(
        VectorStoreConfig.chroma(baseUrl: '', collection: 'kb'),
        store,
      );
      expect(factory.backendName, 'chroma');
      await expectLater(factory.query('kb', HashingTrick.embed('x'), 2),
          throwsA(isA<VectorStoreException>()));
    });

    test('非法 style 在构造期拒绝', () {
      expect(
        () => RemoteVectorStore(style: 'milvus', baseUrl: 'http://x'),
        throwsA(isA<VectorStoreException>()),
      );
    });
  });

  group('KnowledgeBase：混合检索 / 降级 / 重建', () {
    test('入库生成向量，混合检索返回 vector_score 与 backend', () async {
      final KnowledgeBase kb = KnowledgeBase(store);
      final Map<String, dynamic> lib =
          await kb.handle('create', <String, dynamic>{'name': '混合库'});
      final String libraryId = ((lib['library'] as Map)['id']).toString();
      final Map<String, dynamic> ingest = await kb.handle(
        'ingest_text',
        <String, dynamic>{
          'library_id': libraryId,
          'name': '部署说明',
          'text': 'TGA 的登录入口在侧边栏底部。忘记密码请使用邮箱验证码重置。\n\n'
              '沙箱默认目录是 /workspace，所有工作区文件都放在这里。',
        },
      );
      expect(ingest['ok'], true);
      expect(ingest['vectors'], ingest['chunks']);
      expect(ingest['degraded'], false);

      final Map<String, dynamic> stats =
          await kb.handle('vector_stats', <String, dynamic>{});
      expect(stats['ok'], true);
      expect((stats['stats'] as Map)['count'], ingest['chunks']);
      expect(stats['backend'], 'local');

      final Map<String, dynamic> hit = await kb.handle(
        'search',
        <String, dynamic>{'query': '登录入口在哪里', 'top_k': 5},
      );
      expect(hit['ok'], true);
      expect(hit['degraded'], false);
      expect(hit['backend'], 'local');
      final List<dynamic> results = hit['results'] as List<dynamic>;
      expect(results.isNotEmpty, true);
      final Map<String, dynamic> first =
          Map<String, dynamic>.from(results.first as Map);
      expect(first['vector_score'], greaterThan(0));
      expect(first['bm25_score'], greaterThan(0));
      expect(first['backend'], 'local');
      expect(first['degraded'], false);

      final Map<String, dynamic> miss = await kb.handle(
        'search',
        <String, dynamic>{'query': '量子纠缠 光谱 实验室', 'top_k': 5},
      );
      expect(miss['results'], isEmpty);
    });

    test('重建向量后检索结果与统计一致', () async {
      final KnowledgeBase kb = KnowledgeBase(store);
      final Map<String, dynamic> lib =
          await kb.handle('create', <String, dynamic>{'name': '重建库'});
      final String libraryId = ((lib['library'] as Map)['id']).toString();
      final Map<String, dynamic> ingest = await kb.handle(
        'ingest_text',
        <String, dynamic>{
          'library_id': libraryId,
          'name': '说明',
          'text': '向量重建测试：苹果与香蕉属于水果。\n\n汽车与轮胎属于交通工具。',
        },
      );
      final Map<String, dynamic> before = await kb.handle(
        'search',
        <String, dynamic>{'query': '水果 苹果', 'top_k': 5},
      );
      expect((before['results'] as List<dynamic>).isNotEmpty, true);

      final Map<String, dynamic> rebuilt =
          await kb.handle('rebuild_vectors', <String, dynamic>{});
      expect(rebuilt['ok'], true);
      expect(rebuilt['vectors'], ingest['chunks']);
      expect(rebuilt['deleted'], ingest['chunks']);

      final Map<String, dynamic> after = await kb.handle(
        'search',
        <String, dynamic>{'query': '水果 苹果', 'top_k': 5},
      );
      expect(after['results'], before['results']);

      final Map<String, dynamic> stats =
          await kb.handle('vector_stats', <String, dynamic>{});
      expect((stats['stats'] as Map)['count'], ingest['chunks']);
    });

    test('向量库失败时降级 BM25，并如实标注 degraded', () async {
      final KnowledgeBase kb =
          KnowledgeBase(store, vectorStore: _FailingVectorStore());
      final Map<String, dynamic> lib =
          await kb.handle('create', <String, dynamic>{'name': '降级库'});
      final String libraryId = ((lib['library'] as Map)['id']).toString();
      final Map<String, dynamic> ingest = await kb.handle(
        'ingest_text',
        <String, dynamic>{
          'library_id': libraryId,
          'name': '降级说明',
          'text': '降级路径测试：当向量库不可用时，仍然可以用 BM25 检索到这句话。',
        },
      );
      expect(ingest['ok'], true);
      expect(ingest['vectors'], 0);
      expect(ingest['degraded'], true);
      expect((ingest['vector_error'] ?? '').toString().isNotEmpty, true);

      final Map<String, dynamic> hit = await kb.handle(
        'search',
        <String, dynamic>{'query': '降级路径 BM25', 'top_k': 5},
      );
      expect(hit['ok'], true);
      expect(hit['degraded'], true);
      expect((hit['vector_error'] ?? '').toString().isNotEmpty, true);
      final List<dynamic> results = hit['results'] as List<dynamic>;
      expect(results.isNotEmpty, true);
      final Map<String, dynamic> first =
          Map<String, dynamic>.from(results.first as Map);
      expect(first['degraded'], true);
      expect(first['vector_score'], 0.0);
      expect(first['bm25_score'], greaterThan(0));

      final Map<String, dynamic> stats =
          await kb.handle('vector_stats', <String, dynamic>{});
      expect(stats['ok'], false);
      expect(stats['code'], 'not_configured');
    });
  });

  group('HardwareScheduler：硬件推荐与任务队列', () {
    const HardwareProbe phone = HardwareProbe(
      cores: 8,
      totalMemMb: 4096,
      freeMemMb: 1024,
      platform: 'android',
      gpuName: '',
      vramMb: 0,
      thermal: 'nominal',
      battery: 80,
    );
    const HardwareProbe desktop = HardwareProbe(
      cores: 32,
      totalMemMb: 65536,
      freeMemMb: 32768,
      platform: 'linux',
      gpuName: 'NVIDIA GeForce RTX 4090',
      vramMb: 24576,
      thermal: 'nominal',
      battery: -1,
    );

    test('手机走 mobile-light / CPU / Q4_K_M / 单并发', () {
      final HardwareRecommendation rec =
          HardwareScheduler(probe: phone).recommend();
      expect(rec.route, 'mobile-light');
      expect(rec.backend, 'cpu');
      expect(rec.quantization, 'Q4_K_M');
      expect(rec.maxConcurrency, 1);
      expect(rec.degraded, false);
      expect(rec.reasons.isNotEmpty, true);
    });

    test('PC 高端显卡走 pc-heavy / cuda / F16 / 并发上限 4', () {
      final HardwareRecommendation rec =
          HardwareScheduler(probe: desktop).recommend();
      expect(rec.route, 'pc-heavy');
      expect(rec.backend, 'cuda');
      expect(rec.quantization, 'F16');
      expect(rec.maxConcurrency, 4);
      expect(rec.degraded, false);
    });

    test('低显存真实回退 CPU 并记录原因', () {
      const HardwareProbe lowVram = HardwareProbe(
        cores: 8,
        totalMemMb: 16384,
        freeMemMb: 8192,
        platform: 'linux',
        gpuName: 'NVIDIA GTX 1050',
        vramMb: 1024,
        thermal: 'nominal',
        battery: -1,
      );
      final HardwareRecommendation rec =
          HardwareScheduler(probe: lowVram).recommend();
      expect(rec.backend, 'cpu');
      expect(rec.degraded, true);
      expect(rec.reasons.any((String r) => r.contains('显存不足')), true);
    });

    test('过热降档量化并限制并发', () {
      const HardwareProbe hot = HardwareProbe(
        cores: 32,
        totalMemMb: 65536,
        freeMemMb: 32768,
        platform: 'linux',
        gpuName: 'NVIDIA GeForce RTX 4090',
        vramMb: 24576,
        thermal: 'serious',
        battery: -1,
      );
      final HardwareRecommendation rec =
          HardwareScheduler(probe: hot).recommend();
      expect(rec.degraded, true);
      expect(rec.quantization, 'Q8_0');
      expect(rec.maxConcurrency <= 2, true);
      expect(rec.reasons.any((String r) => r.contains('过热')), true);

      const HardwareProbe critical = HardwareProbe(
        cores: 32,
        totalMemMb: 65536,
        freeMemMb: 32768,
        platform: 'linux',
        gpuName: 'NVIDIA GeForce RTX 4090',
        vramMb: 24576,
        thermal: 'critical',
        battery: -1,
      );
      final HardwareRecommendation second =
          HardwareScheduler(probe: critical).recommend();
      expect(second.backend, 'cpu');
      expect(second.quantization, 'Q4_K_M');
      expect(second.maxConcurrency, 1);
    });

    test('低电量真实降级为 CPU / 单并发', () {
      const HardwareProbe lowBattery = HardwareProbe(
        cores: 8,
        totalMemMb: 8192,
        freeMemMb: 2048,
        platform: 'android',
        gpuName: 'Adreno 740',
        vramMb: 2048,
        thermal: 'nominal',
        battery: 10,
      );
      final HardwareRecommendation rec =
          HardwareScheduler(probe: lowBattery).recommend();
      expect(rec.degraded, true);
      expect(rec.backend, 'cpu');
      expect(rec.quantization, 'Q4_K_M');
      expect(rec.maxConcurrency, 1);
      expect(rec.reasons.any((String r) => r.contains('电量低')), true);
    });

    test('轻 / 重任务分别入队并返回路由与原因', () {
      final HardwareScheduler scheduler = HardwareScheduler(probe: desktop);
      final ScheduleDecision light =
          scheduler.schedule(const HardwareTask(id: 'light-1'));
      expect(light.status, 'queued');
      expect(light.queue, 'light');
      expect(light.route, 'pc-heavy');
      expect(light.reason.isNotEmpty, true);
      expect(light.position, 1);

      final ScheduleDecision heavy = scheduler
          .schedule(const HardwareTask(id: 'heavy-1', weight: 'heavy'));
      expect(heavy.status, 'queued');
      expect(heavy.queue, 'heavy');
      expect(heavy.position, 1);
      expect(scheduler.pendingLight, 1);
      expect(scheduler.pendingHeavy, 1);

      final ScheduleDecision mobileHeavy =
          HardwareScheduler(probe: phone).schedule(
              const HardwareTask(id: 'mobile-heavy', weight: 'heavy'));
      expect(mobileHeavy.route, 'mobile-light');
      expect(mobileHeavy.reason.contains('单并发'), true);
    });

    test('真实探针失败不抛异常，注入探针原样返回', () async {
      const HardwareProbe injected = HardwareProbe(
        cores: 4,
        totalMemMb: 8192,
        platform: 'linux',
      );
      final HardwareScheduler injectedScheduler =
          HardwareScheduler(probe: injected);
      expect(await injectedScheduler.detect(), same(injected));

      final HardwareScheduler scheduler = HardwareScheduler();
      final HardwareProbe detected = await scheduler.detect();
      expect(detected.cores, greaterThan(0));
      expect(detected.platform.isNotEmpty, true);
      expect(detected.vramMb >= 0, true);
      expect(detected.thermal.isNotEmpty, true);
      final HardwareRecommendation rec = scheduler.recommend();
      expect(rec.reasons.isNotEmpty, true);
      expect(rec.maxConcurrency >= 1, true);
    });
  });
}
