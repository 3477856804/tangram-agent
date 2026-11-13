import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// 内置沙箱能力契约。
///
/// 对齐参考项目 flutter_agent_harness 的 `schema/cube_schema.json`：
/// 用一份契约声明应用可执行的操作（cube）及其所需能力（capabilities），
/// 沙箱启动时按此契约做能力校验。缺失即进入 `_refusal` 状态——零执行、
/// 零暂存写入，并返回命名稳定错误，绝不静默降级。
///
/// `allowDegrade` 严格布尔解析：缺省为 false；只有契约显式写为 `true`
/// 才允许降级（且降级时大声告警）。字符串 `"false"` / `0` 一律视为 false。
class CubeContract {
  CubeContract._({
    required this.schemaVersion,
    required this.name,
    required this.allowDegrade,
    required this.backends,
    required this.cubes,
    required this.capabilities,
  });

  final String schemaVersion;
  final String name;
  final bool allowDegrade;
  final Map<String, BackendSpec> backends;
  final Map<String, CubeSpec> cubes;
  final Map<String, String> capabilities;

  /// 从内置资产加载并校验契约。资产缺失即抛错，不静默放过。
  static Future<CubeContract> load() async {
    final raw = await rootBundle.loadString('assets/schema/cube_schema.json');
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const CubeContractError('cube_schema.json 根节点不是对象');
    }
    return CubeContract._fromJson(decoded);
  }

  factory CubeContract._fromJson(Map<String, dynamic> json) {
    final bool allowDegrade = _strictBool(json['allowDegrade'], 'allowDegrade');

    final backends = <String, BackendSpec>{};
    final rawBackends = json['backends'];
    if (rawBackends is Map) {
      rawBackends.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          backends[k.toString()] = BackendSpec._fromJson(k.toString(), v);
        }
      });
    }

    final cubes = <String, CubeSpec>{};
    final rawCubes = json['cubes'];
    if (rawCubes is Map) {
      rawCubes.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          cubes[k.toString()] = CubeSpec._fromJson(k.toString(), v);
        }
      });
    }

    final caps = <String, String>{};
    final rawCaps = json['capabilities'];
    if (rawCaps is Map) {
      rawCaps.forEach((k, v) => caps[k.toString()] = v.toString());
    }

    return CubeContract._(
      schemaVersion: (json['schemaVersion'] ?? '0').toString(),
      name: (json['name'] ?? 'unnamed').toString(),
      allowDegrade: allowDegrade,
      backends: backends,
      cubes: cubes,
      capabilities: caps,
    );
  }

  /// 解析一个 cube 所需的运行时能力集合（去重，保持顺序）。
  List<String> requiredCapabilities(String cubeName) {
    final cube = cubes[cubeName];
    if (cube == null) return const <String>[];
    return cube.requires;
  }

  bool hasCube(String cubeName) => cubes.containsKey(cubeName);

  static bool _strictBool(dynamic v, String key) {
    if (v is bool) return v;
    if (v == null) return false;
    // 严格解析：只有显式 true 才为真；"false"/0/其他一律 false。
    throw CubeContractError('契约字段 "$key" 必须是严格布尔值，收到: ${v.runtimeType}');
  }
}

class BackendSpec {
  BackendSpec._({
    required this.name,
    required this.kind,
    required this.isolate,
    this.note,
  });

  final String name;
  final String kind;
  final bool isolate;
  final String? note;

  factory BackendSpec._fromJson(String name, Map<String, dynamic> json) {
    return BackendSpec._(
      name: name,
      kind: (json['kind'] ?? 'unknown').toString(),
      isolate: json['isolate'] == true,
      note: json['note']?.toString(),
    );
  }
}

class CubeSpec {
  CubeSpec._({
    required this.name,
    required this.description,
    required this.backend,
    required this.requires,
    required this.allowDegrade,
  });

  final String name;
  final String description;
  final String backend;
  final List<String> requires;
  final bool allowDegrade;

  factory CubeSpec._fromJson(String name, Map<String, dynamic> json) {
    final requires = <String>[];
    final rawReq = json['requires'];
    if (rawReq is List) {
      for (final e in rawReq) {
        requires.add(e.toString());
      }
    }
    return CubeSpec._(
      name: name,
      description: (json['description'] ?? '').toString(),
      backend: (json['backend'] ?? 'dart').toString(),
      requires: requires,
      allowDegrade: CubeContract._strictBool(json['allowDegrade'], '$name.allowDegrade'),
    );
  }
}

class CubeContractError implements Exception {
  const CubeContractError(this.message);
  final String message;
  @override
  String toString() => 'CubeContractError: $message';
}
