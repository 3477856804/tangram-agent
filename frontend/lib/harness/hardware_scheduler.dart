/// 硬件自适应调度：真实探针 → 量化/后端/路由/并发推荐 → 轻/重任务队列。
///
/// 设计红线：
///  * [HardwareProbe] 的字段全部来自真实探测或调用方注入，探测失败一律置空 /
///    置 -1，绝不用编造的「高端 GPU」冒充硬件。
///  * [HardwareScheduler.recommend] 只做参数决策，不加载模型、不执行推理；
///    显存不足、过热、低电等降级都写进 reasons，调用方可核对。
///  * [HardwareScheduler.schedule] 只把任务放进轻 / 重队列并返回排队位置，
///    不假装已经开始执行。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// 一次硬件探测结果。未知字段用 0 / 空串 / -1 表示，不做猜测。
class HardwareProbe {
  const HardwareProbe({
    this.cores = 0,
    this.totalMemMb = 0,
    this.freeMemMb = 0,
    this.platform = '',
    this.gpuName = '',
    this.vramMb = 0,
    this.thermal = 'unknown',
    this.battery = -1,
  });

  final int cores;
  final int totalMemMb;
  final int freeMemMb;
  final String platform;
  final String gpuName;
  final int vramMb;

  /// nominal / fair / serious / critical / unknown（大小写不敏感）。
  final String thermal;

  /// 电量百分比 0-100；-1 表示不可读取。
  final int battery;

  bool get isMobile =>
      platform.toLowerCase() == 'android' || platform.toLowerCase() == 'ios';

  bool get hasGpu => gpuName.trim().isNotEmpty && vramMb > 0;

  String get thermalLevel {
    final String value = thermal.toLowerCase();
    if (value == 'nominal' ||
        value == 'fair' ||
        value == 'serious' ||
        value == 'critical') {
      return value;
    }
    return 'unknown';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'cores': cores,
        'total_mem_mb': totalMemMb,
        'free_mem_mb': freeMemMb,
        'platform': platform,
        'gpu_name': gpuName,
        'vram_mb': vramMb,
        'thermal': thermal,
        'battery': battery,
      };

  /// 真实默认探针：任何一步失败都只置空对应字段，绝不抛异常。
  static Future<HardwareProbe> detectDefault() async {
    int totalMemMb = 0;
    int freeMemMb = 0;
    try {
      final File meminfo = File('/proc/meminfo');
      if (await meminfo.exists()) {
        for (final String line in await meminfo.readAsLines()) {
          final List<String> parts = line.split(RegExp(r'\s+'));
          if (parts.length < 2) continue;
          final String key = parts.first.replaceAll(':', '');
          final int? kb = int.tryParse(parts[1]);
          if (kb == null) continue;
          if (key == 'MemTotal') totalMemMb = kb ~/ 1024;
          if (key == 'MemAvailable') freeMemMb = kb ~/ 1024;
        }
      }
    } on Object {
      // 非 Linux / 无权限：保持 0，如实表示未知。
    }

    final _GpuInfo gpu = await _probeGpu();
    return HardwareProbe(
      cores: Platform.numberOfProcessors,
      totalMemMb: totalMemMb,
      freeMemMb: freeMemMb,
      platform: Platform.operatingSystem,
      gpuName: gpu.name,
      vramMb: gpu.vramMb,
      thermal: await _probeThermal(),
      battery: await _probeBattery(),
    );
  }

  static Future<_GpuInfo> _probeGpu() async {
    try {
      final ProcessResult result = await Process.run(
        'nvidia-smi',
        <String>[
          '--query-gpu=name,memory.total',
          '--format=csv,noheader,nounits',
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) {
        final String text = result.stdout.toString().trim();
        if (text.isNotEmpty) {
          final List<String> fields = text.split('\n').first.split(',');
          if (fields.length >= 2) {
            final String name = fields[0].trim();
            final int vram =
                (double.tryParse(fields[1].trim()) ?? 0).round();
            if (name.isNotEmpty) return _GpuInfo(name, vram);
          }
        }
      }
    } on Object {
      // 无 nvidia-smi / 无 GPU：继续尝试 ROCm。
    }

    String name = '';
    int vramMb = 0;
    try {
      final ProcessResult result = await Process.run(
        'rocm-smi',
        <String>['--showproductname', '--json'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) {
        final dynamic decoded = jsonDecode(result.stdout.toString());
        if (decoded is Map) {
          for (final dynamic value in decoded.values) {
            if (value is Map) {
              name = (value['Card series'] ??
                      value['Card SKU'] ??
                      value['GPU'] ??
                      '')
                  .toString()
                  .trim();
              if (name.isNotEmpty) break;
            }
          }
        }
      }
    } on Object {
      // 同上。
    }
    try {
      final File vramFile =
          File('/sys/class/drm/card0/device/mem_info_vram_total');
      if (await vramFile.exists()) {
        final int? bytes =
            int.tryParse((await vramFile.readAsString()).trim());
        if (bytes != null && bytes > 0) vramMb = bytes ~/ (1024 * 1024);
      }
    } on Object {
      // 读不到显存即 0。
    }
    return _GpuInfo(name, vramMb);
  }

  static Future<String> _probeThermal() async {
    for (final String path in <String>[
      '/sys/class/thermal/thermal_zone0/temp',
      '/sys/class/thermal/thermal_zone1/temp',
    ]) {
      try {
        final File file = File(path);
        if (!await file.exists()) continue;
        final int? milli = int.tryParse((await file.readAsString()).trim());
        if (milli == null) continue;
        final double celsius = milli / 1000;
        if (celsius >= 80) return 'critical';
        if (celsius >= 70) return 'serious';
        if (celsius >= 60) return 'fair';
        return 'nominal';
      } on Object {
        // 尝试下一个真实温度节点。
      }
    }
    return 'unknown';
  }

  static Future<int> _probeBattery() async {
    for (final String path in <String>[
      '/sys/class/power_supply/BAT0/capacity',
      '/sys/class/power_supply/BAT1/capacity',
      '/sys/class/power_supply/battery/capacity',
    ]) {
      try {
        final File file = File(path);
        if (!await file.exists()) continue;
        final int? value = int.tryParse((await file.readAsString()).trim());
        if (value != null && value >= 0 && value <= 100) return value;
      } on Object {
        // 尝试下一个真实电池节点。
      }
    }
    return -1;
  }
}

class _GpuInfo {
  const _GpuInfo(this.name, this.vramMb);
  final String name;
  final int vramMb;
}

/// 一组可核对的调度建议。
class HardwareRecommendation {
  const HardwareRecommendation({
    required this.quantization,
    required this.backend,
    required this.route,
    required this.maxConcurrency,
    required this.degraded,
    required this.reasons,
  });

  final String quantization;
  final String backend;
  final String route;
  final int maxConcurrency;
  final bool degraded;
  final List<String> reasons;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'quantization': quantization,
        'backend': backend,
        'route': route,
        'max_concurrency': maxConcurrency,
        'degraded': degraded,
        'reasons': List<String>.of(reasons),
      };
}

/// 待调度任务：weight 只区分 light / heavy，不执行模型。
class HardwareTask {
  const HardwareTask({
    required this.id,
    this.weight = 'light',
    this.description = '',
  });

  final String id;
  final String weight;
  final String description;

  bool get heavy => weight.toLowerCase() == 'heavy';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'weight': heavy ? 'heavy' : 'light',
        'description': description,
      };
}

class ScheduleDecision {
  const ScheduleDecision({
    required this.status,
    required this.queue,
    required this.route,
    required this.reason,
    required this.position,
    required this.maxConcurrency,
    required this.degraded,
  });

  final String status;
  final String queue;
  final String route;
  final String reason;
  final int position;
  final int maxConcurrency;
  final bool degraded;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'status': status,
        'queue': queue,
        'route': route,
        'reason': reason,
        'position': position,
        'max_concurrency': maxConcurrency,
        'degraded': degraded,
      };
}

class HardwareScheduler {
  HardwareScheduler({HardwareProbe? probe}) : _probe = probe;

  HardwareProbe? _probe;

  final List<String> _lightQueue = <String>[];
  final List<String> _heavyQueue = <String>[];

  HardwareProbe get probe => _probe ?? const HardwareProbe();
  int get pendingLight => _lightQueue.length;
  int get pendingHeavy => _heavyQueue.length;

  /// 注入探针时直接返回注入值；否则运行真实默认探针并缓存。
  Future<HardwareProbe> detect() async {
    final HardwareProbe? injected = _probe;
    if (injected != null) return injected;
    final HardwareProbe detected = await HardwareProbe.detectDefault();
    _probe = detected;
    return detected;
  }

  HardwareRecommendation recommend() => _recommend(probe);

  ScheduleDecision schedule(HardwareTask task) {
    final HardwareRecommendation recommendation = recommend();
    final bool heavy = task.heavy;
    final List<String> queue = heavy ? _heavyQueue : _lightQueue;
    if (task.id.trim().isEmpty) {
      return ScheduleDecision(
        status: 'rejected',
        queue: heavy ? 'heavy' : 'light',
        route: recommendation.route,
        reason: '任务 id 为空，未入队',
        position: 0,
        maxConcurrency: recommendation.maxConcurrency,
        degraded: recommendation.degraded,
      );
    }
    queue.add(task.id);
    final int cap = recommendation.maxConcurrency;
    final String reason;
    if (heavy) {
      reason = cap <= 1
          ? '重量任务进入 heavy 队列，按 ${recommendation.route} 路由；'
              '当前设备限制单并发，将串行执行'
          : '重量任务进入 heavy 队列，按 ${recommendation.route} 路由，'
              '最多 $cap 并发';
    } else {
      reason = '轻量任务进入 light 队列，按 ${recommendation.route} 路由，'
          '与其他轻任务共享 $cap 并发上限';
    }
    return ScheduleDecision(
      status: 'queued',
      queue: heavy ? 'heavy' : 'light',
      route: recommendation.route,
      reason: reason,
      position: queue.length,
      maxConcurrency: cap,
      degraded: recommendation.degraded,
    );
  }

  HardwareRecommendation _recommend(HardwareProbe p) {
    final List<String> reasons = <String>[];
    bool degraded = false;
    final bool mobile = p.isMobile;
    final String route = mobile ? 'mobile-light' : 'pc-heavy';
    final String platform = p.platform.toLowerCase();
    final String gpuName = p.gpuName.toLowerCase();

    String backend;
    if (platform == 'ios' || platform == 'macos') {
      backend = 'metal';
    } else if (p.hasGpu) {
      backend = (gpuName.contains('nvidia') && platform != 'android')
          ? 'cuda'
          : 'vulkan';
    } else {
      backend = 'cpu';
    }

    // 显存不足：真实回退 CPU，而不是假装 GPU 可用。
    if (backend != 'cpu' && backend != 'metal' && p.vramMb < 2048) {
      reasons.add('显存不足（${p.vramMb}MB < 2048MB）：$backend 回退 CPU');
      backend = 'cpu';
      degraded = true;
    }

    String quant;
    if (backend == 'cpu') {
      if (p.totalMemMb <= 0) {
        quant = 'Q4_K_M';
        reasons.add('内存信息不可用：采用保守量化 Q4_K_M');
      } else if (p.totalMemMb >= 32768) {
        quant = 'Q8_0';
      } else if (p.totalMemMb >= 12288) {
        quant = 'Q5_K_S';
      } else {
        quant = 'Q4_K_M';
      }
    } else if (backend == 'metal') {
      // Apple Metal 使用统一内存，按物理内存分档。
      if (p.totalMemMb >= 24576) {
        quant = 'Q8_0';
      } else if (p.totalMemMb >= 12288) {
        quant = 'Q5_K_S';
      } else {
        quant = 'Q4_K_M';
      }
    } else if (p.vramMb >= 16384) {
      quant = 'F16';
    } else if (p.vramMb >= 8192) {
      quant = 'Q8_0';
    } else if (p.vramMb >= 4096) {
      quant = 'Q5_K_S';
    } else {
      quant = 'Q4_K_M';
    }

    final String thermal = p.thermalLevel;
    if (thermal == 'serious' || thermal == 'critical') {
      final int steps = thermal == 'critical' ? 2 : 1;
      final String before = quant;
      quant = _downgrade(quant, steps);
      degraded = true;
      reasons.add('设备$thermal（过热）：量化 $before → $quant');
      if (thermal == 'critical' && backend != 'cpu') {
        reasons.add('过热 critical：$backend 后端降为 CPU');
        backend = 'cpu';
        quant = _downgrade(quant, 1);
      }
    }

    if (p.battery >= 0 && p.battery < 20) {
      degraded = true;
      if (mobile && backend != 'cpu' && backend != 'metal') {
        reasons.add('电量低（${p.battery}%）：$backend 后端降为 CPU');
        backend = 'cpu';
      }
      final String before = quant;
      quant = _downgrade(quant, 99);
      reasons.add('电量低（${p.battery}%）：量化 $before → $quant，并发降为 1');
    }

    if (p.freeMemMb > 0 && p.freeMemMb < 1024) {
      degraded = true;
      reasons.add('可用内存偏低（${p.freeMemMb}MB）：限制并发为 1');
    }

    int cap;
    if (backend == 'cpu') {
      cap = mobile ? 1 : (p.cores >= 8 ? 2 : 1);
    } else {
      cap = ((p.vramMb ~/ 4096) + 1).clamp(1, 4).toInt();
    }
    if (p.cores > 0) cap = math.min(cap, math.max(1, p.cores ~/ 2));
    if (mobile) cap = math.min(cap, 2);
    if (thermal == 'serious') cap = math.min(cap, 2);
    if (thermal == 'critical') cap = 1;
    if (p.battery >= 0 && p.battery < 20) cap = 1;
    if (p.freeMemMb > 0 && p.freeMemMb < 1024) cap = 1;
    cap = math.max(1, cap);

    reasons.insert(0, 'route=$route（${p.platform.isEmpty ? '未知平台' : p.platform}）');
    reasons.insert(
      1,
      backend == 'cpu'
          ? 'backend=cpu（无可用 GPU 显存）'
          : 'backend=$backend（${p.gpuName} / ${p.vramMb}MB）',
    );
    reasons.add('量化 $quant，并发上限 $cap');

    return HardwareRecommendation(
      quantization: quant,
      backend: backend,
      route: route,
      maxConcurrency: cap,
      degraded: degraded,
      reasons: reasons,
    );
  }

  static const List<String> _quantOrder = <String>[
    'F16',
    'Q8_0',
    'Q5_K_S',
    'Q4_K_M',
  ];

  static String _downgrade(String quant, int steps) {
    final int index = _quantOrder.indexOf(quant);
    if (index < 0) return 'Q4_K_M';
    return _quantOrder[math.min(_quantOrder.length - 1, index + steps)];
  }
}
