/// 3D 建模核心：OBJ / STL / PLY 的真实解析、网格统计、变换与导出。
///
/// 不依赖任何 3D 引擎或图形库：纯 Dart 处理顶点/三角形，端侧与桌面端行为
/// 一致，可直接在单元测试里跑。UI 只负责投影绘制（见 `tga_3d_page.dart`）。
///
/// 支持范围（如实声明，不假装支持未实现的格式）：
///  * OBJ：`v` 顶点、`f` 面（支持 `v` / `v/vt` / `v/vt/vn` 与多边形扇形三角化）。
///  * STL：ASCII 与二进制两种（50 字节/面，float32 小端）。
///  * PLY：ASCII 与二进制（little/big endian）的 vertex/face 元素
///    （常见标量属性；x/y/z 之外的颜色、法向等属性按类型跳过）。
///  * 导出：OBJ 文本、二进制 STL、ASCII PLY。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// 三维向量（不可变值对象）。
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  static const Vec3 zero = Vec3(0, 0, 0);

  final double x;
  final double y;
  final double z;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);

  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);

  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) => Vec3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  double get length => math.sqrt(x * x + y * y + z * z);

  Vec3 get normalized {
    final double l = length;
    return l == 0 ? zero : Vec3(x / l, y / l, z / l);
  }

  double get distanceToZero => length;

  Map<String, dynamic> toJson() => <String, dynamic>{'x': x, 'y': y, 'z': z};

  @override
  String toString() =>
      '${x.toStringAsFixed(3)},${y.toStringAsFixed(3)},${z.toStringAsFixed(3)}';
}

/// 三角形（三个顶点索引，逆时针为正面）。
class Tri3 {
  const Tri3(this.a, this.b, this.c);
  final int a;
  final int b;
  final int c;

  List<int> get indices => <int>[a, b, c];
}

/// 一次 3D 解析的结果：网格 + 如实记录的格式信息。
class MeshLoadResult {
  const MeshLoadResult({required this.mesh, required this.format, this.note = ''});
  final Mesh3D mesh;
  final String format;
  final String note;
}

/// 解析失败时的可读错误（不静默产出空网格）。
class MeshFormatException implements Exception {
  const MeshFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 网格统计快照（全部由真实顶点/面计算）。
class MeshStats {
  const MeshStats({
    required this.vertexCount,
    required this.triangleCount,
    required this.min,
    required this.max,
    required this.surfaceArea,
    required this.volume,
    required this.watertight,
  });

  final int vertexCount;
  final int triangleCount;
  final Vec3 min;
  final Vec3 max;
  final double surfaceArea;

  /// 有符号体积（闭合网格才有物理意义；非闭合网格如实返回近似值）。
  final double volume;

  /// 每条边都恰好被两个三角形共享 → 闭合（可打印）。
  final bool watertight;

  double get width => max.x - min.x;
  double get height => max.y - min.y;
  double get depth => max.z - min.z;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'vertices': vertexCount,
        'triangles': triangleCount,
        'bounds': <String, dynamic>{
          'min': min.toJson(),
          'max': max.toJson(),
          'size': <String, dynamic>{
            'x': width,
            'y': height,
            'z': depth,
          },
        },
        'surface_area': surfaceArea,
        'volume': volume,
        'watertight': watertight,
      };
}

/// 三角网格。顶点与面分离存储，便于高效变换与导出。
class Mesh3D {
  Mesh3D({required List<Vec3> vertices, required List<Tri3> triangles})
      : vertices = List<Vec3>.unmodifiable(vertices),
        triangles = List<Tri3>.unmodifiable(triangles);

  Mesh3D.empty()
      : vertices = const <Vec3>[],
        triangles = const <Tri3>[];

  final List<Vec3> vertices;
  final List<Tri3> triangles;

  int get vertexCount => vertices.length;
  int get triangleCount => triangles.length;
  bool get isEmpty => vertices.isEmpty || triangles.isEmpty;

  // ---------------------------------------------------------------------------
  // 构造
  // ---------------------------------------------------------------------------

  /// 轴对齐立方体（单位尺寸按参数缩放，中心在原点）。
  static Mesh3D box({double width = 1, double height = 1, double depth = 1}) {
    final double hx = width / 2;
    final double hy = height / 2;
    final double hz = depth / 2;
    final List<Vec3> v = <Vec3>[
      Vec3(-hx, -hy, -hz), Vec3(hx, -hy, -hz), Vec3(hx, hy, -hz), Vec3(-hx, hy, -hz),
      Vec3(-hx, -hy, hz), Vec3(hx, -hy, hz), Vec3(hx, hy, hz), Vec3(-hx, hy, hz),
    ];
    const List<List<int>> f = <List<int>>[
      <int>[0, 1, 2], <int>[0, 2, 3], // -Z
      <int>[4, 6, 5], <int>[4, 7, 6], // +Z
      <int>[0, 4, 5], <int>[0, 5, 1], // -Y
      <int>[3, 2, 6], <int>[3, 6, 7], // +Y
      <int>[0, 3, 7], <int>[0, 7, 4], // -X
      <int>[1, 5, 6], <int>[1, 6, 2], // +X
    ];
    return Mesh3D(
      vertices: v,
      triangles: f.map((e) => Tri3(e[0], e[1], e[2])).toList(growable: false),
    );
  }

  /// 程序化低模鹿：项目鹿 logo 的 3D 化（身体/脖子/头/四肢/鹿角）。
  ///
  /// 全部由立方体拼装并做刚体变换，顶点/面数可控，
  /// 作为 3D 页面的默认示例模型（真实网格，不是贴图占位）。
  static Mesh3D deer({double scale = 1}) {
    Mesh3D part(double w, double h, double d, Vec3 offset,
        {double rotX = 0, double rotZ = 0}) {
      final Mesh3D base = Mesh3D.box(width: w, height: h, depth: d);
      return base.transformed(
        rotateXDeg: rotX,
        rotateZDeg: rotZ,
        translate: offset,
      );
    }

    final List<Mesh3D> parts = <Mesh3D>[
      part(1.0, 0.62, 0.52, Vec3(0, 0.15, 0)), // 身体
      part(0.34, 0.62, 0.34, Vec3(0.58, 0.55, 0), rotZ: -28), // 脖子
      part(0.46, 0.34, 0.32, Vec3(0.86, 0.86, 0), rotZ: -12), // 头
      part(0.18, 0.16, 0.2, Vec3(1.06, 0.78, 0)), // 吻部
      // 四条腿（前后 × 左右）
      part(0.16, 0.78, 0.16, Vec3(0.34, -0.5, 0.17)),
      part(0.16, 0.78, 0.16, Vec3(0.34, -0.5, -0.17)),
      part(0.16, 0.78, 0.16, Vec3(-0.36, -0.5, 0.17)),
      part(0.16, 0.78, 0.16, Vec3(-0.36, -0.5, -0.17)),
      // 鹿角（左右各两支，细长立方体）
      part(0.08, 0.46, 0.08, Vec3(0.94, 1.2, 0.11), rotZ: 18),
      part(0.08, 0.3, 0.08, Vec3(1.02, 1.42, 0.2), rotZ: 36),
      part(0.08, 0.46, 0.08, Vec3(0.94, 1.2, -0.11), rotZ: 18),
      part(0.08, 0.3, 0.08, Vec3(1.02, 1.42, -0.2), rotZ: 36),
      // 尾巴
      part(0.12, 0.22, 0.12, Vec3(-0.55, 0.34, 0), rotZ: 32),
    ];
    return Mesh3D.merge(parts).transformed(scale: scale);
  }

  /// 合并多个网格（索引整体平移，不做布尔运算）。
  static Mesh3D merge(List<Mesh3D> meshes) {
    final List<Vec3> vs = <Vec3>[];
    final List<Tri3> ts = <Tri3>[];
    for (final Mesh3D m in meshes) {
      final int offset = vs.length;
      vs.addAll(m.vertices);
      for (final Tri3 t in m.triangles) {
        ts.add(Tri3(t.a + offset, t.b + offset, t.c + offset));
      }
    }
    return Mesh3D(vertices: vs, triangles: ts);
  }

  // ---------------------------------------------------------------------------
  // 解析
  // ---------------------------------------------------------------------------

  /// 按扩展名分派。未知扩展名抛 [MeshFormatException]，不猜格式。
  static MeshLoadResult parseBytes(String fileName, Uint8List bytes) {
    final String lower = fileName.toLowerCase();
    if (lower.endsWith('.obj')) {
      return MeshLoadResult(
        mesh: fromObj(utf8.decode(bytes, allowMalformed: true)),
        format: 'obj',
      );
    }
    if (lower.endsWith('.stl')) {
      return fromStl(bytes);
    }
    if (lower.endsWith('.ply')) {
      return fromPlyBytes(bytes);
    }
    throw MeshFormatException('不支持的模型格式：$fileName（仅支持 .obj/.stl/.ply）');
  }

  /// 按坐标焊接顶点（1e-6 量化）：STL 每个三角自带 3 个顶点，不焊接就
  /// 无法按共享边判定封闭性；OBJ 导出也借此去掉重复顶点、保留共享拓扑。
  static int _weld(Vec3 v, Map<String, int> index, List<Vec3> out) {
    final String key = '${(v.x * 1e6).round()},'
        '${(v.y * 1e6).round()},${(v.z * 1e6).round()}';
    final int? found = index[key];
    if (found != null) return found;
    final int i = out.length;
    out.add(v);
    index[key] = i;
    return i;
  }

  /// OBJ 解析：只取 `v` 与 `f`，`f` 支持三种引用写法和多边形扇形三角化。
  static Mesh3D fromObj(String text) {
    final List<Vec3> vs = <Vec3>[];
    final List<Tri3> ts = <Tri3>[];
    for (final String rawLine in const LineSplitter().convert(text)) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final List<String> parts = line.split(RegExp(r'\s+'));
      if (parts.first == 'v' && parts.length >= 4) {
        vs.add(Vec3(
          double.tryParse(parts[1]) ?? 0,
          double.tryParse(parts[2]) ?? 0,
          double.tryParse(parts[3]) ?? 0,
        ));
      } else if (parts.first == 'f' && parts.length >= 4) {
        final List<int> idx = <int>[];
        for (final String token in parts.skip(1)) {
          final String head = token.split('/').first;
          final int? parsed = int.tryParse(head);
          if (parsed == null) continue;
          // OBJ 支持负索引（相对末尾）；统一转成 0 基。
          final int v = parsed < 0 ? vs.length + parsed : parsed - 1;
          if (v >= 0 && v < vs.length) idx.add(v);
        }
        for (int i = 1; i + 1 < idx.length; i++) {
          ts.add(Tri3(idx[0], idx[i], idx[i + 1]));
        }
      }
    }
    if (vs.isEmpty || ts.isEmpty) {
      throw const MeshFormatException('OBJ 里没有可用的顶点/面（需要 v + f 记录）');
    }
    return Mesh3D(vertices: vs, triangles: ts);
  }

  /// STL 解析：先按二进制长度校验，失败再按 ASCII 解析，两种都失败则报错。
  static MeshLoadResult fromStl(Uint8List bytes) {
    final ByteData data = ByteData.sublistView(bytes);
    if (bytes.length >= 84) {
      final int count = data.getUint32(80, Endian.little);
      if (count > 0 && 84 + count * 50 == bytes.length) {
        final List<Vec3> vs = <Vec3>[];
        final List<Tri3> ts = <Tri3>[];
        final Map<String, int> weld = <String, int>{};
        int offset = 84;
        for (int i = 0; i < count; i++) {
          // 前 12 字节是法向，跳过；随后 9 个 float32 是三个顶点。
          offset += 12;
          final List<int> tri = <int>[];
          for (int v = 0; v < 3; v++) {
            tri.add(_weld(
              Vec3(
                data.getFloat32(offset + v * 12, Endian.little),
                data.getFloat32(offset + v * 12 + 4, Endian.little),
                data.getFloat32(offset + v * 12 + 8, Endian.little),
              ),
              weld,
              vs,
            ));
          }
          ts.add(Tri3(tri[0], tri[1], tri[2]));
          offset += 36 + 2; // 3 顶点 + 属性字节数
        }
        return MeshLoadResult(
          mesh: Mesh3D(vertices: vs, triangles: ts),
          format: 'stl-binary',
        );
      }
    }
    final String text = utf8.decode(bytes, allowMalformed: true);
    if (text.contains('vertex')) {
      final List<Vec3> vs = <Vec3>[];
      final List<Tri3> ts = <Tri3>[];
      final Map<String, int> weld = <String, int>{};
      final List<Vec3> current = <Vec3>[];
      for (final String rawLine in const LineSplitter().convert(text)) {
        final String line = rawLine.trim();
        if (!line.startsWith('vertex')) continue;
        final List<String> parts = line.split(RegExp(r'\s+'));
        if (parts.length < 4) continue;
        current.add(Vec3(
          double.tryParse(parts[1]) ?? 0,
          double.tryParse(parts[2]) ?? 0,
          double.tryParse(parts[3]) ?? 0,
        ));
        if (current.length == 3) {
          ts.add(Tri3(
            _weld(current[0], weld, vs),
            _weld(current[1], weld, vs),
            _weld(current[2], weld, vs),
          ));
          current.clear();
        }
      }
      if (vs.isNotEmpty && ts.isNotEmpty) {
        return MeshLoadResult(
          mesh: Mesh3D(vertices: vs, triangles: ts),
          format: 'stl-ascii',
        );
      }
    }
    throw const MeshFormatException('STL 解析失败：既不是合法二进制 STL，也没有 vertex 记录');
  }

  /// PLY 解析（仅 ASCII）：读取 vertex 的 x/y/z 与 face 的顶点索引列表。
  /// 二进制 PLY 请走 [fromPlyBytes]，本方法遇到 binary 头会明确报错。
  static Mesh3D fromPly(String text) {
    final List<String> lines = const LineSplitter().convert(text);
    int vertexCount = 0;
    int faceCount = 0;
    bool ascii = false;
    int headerEnd = -1;
    final List<String> vertexProps = <String>[];
    bool inVertexElement = false;
    int faceListCount = 0;

    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].trim();
      if (line == 'format ascii 1.0') ascii = true;
      if (line.startsWith('element vertex')) {
        vertexCount = int.tryParse(line.split(RegExp(r'\s+')).last) ?? 0;
        inVertexElement = true;
      } else if (line.startsWith('element face')) {
        faceCount = int.tryParse(line.split(RegExp(r'\s+')).last) ?? 0;
        inVertexElement = false;
      } else if (line.startsWith('property') && inVertexElement) {
        vertexProps.add(line.split(RegExp(r'\s+')).last);
      } else if (line.startsWith('property list') && !inVertexElement) {
        faceListCount = 1;
      } else if (line == 'end_header') {
        headerEnd = i;
        break;
      }
    }
    if (!ascii) {
      throw const MeshFormatException('PLY 仅支持 ASCII 格式（binary 暂未实现）');
    }
    if (headerEnd < 0 || vertexCount <= 0) {
      throw const MeshFormatException('PLY 头不完整：缺少 end_header 或 vertex 元素');
    }
    final int xi = vertexProps.indexOf('x');
    final int yi = vertexProps.indexOf('y');
    final int zi = vertexProps.indexOf('z');
    if (xi < 0 || yi < 0 || zi < 0) {
      throw const MeshFormatException('PLY 顶点缺少 x/y/z 属性');
    }

    final List<Vec3> vs = <Vec3>[];
    int cursor = headerEnd + 1;
    for (int i = 0; i < vertexCount && cursor < lines.length; i++, cursor++) {
      final List<String> p = lines[cursor].trim().split(RegExp(r'\s+'));
      if (p.length <= math.max(xi, math.max(yi, zi))) continue;
      vs.add(Vec3(
        double.tryParse(p[xi]) ?? 0,
        double.tryParse(p[yi]) ?? 0,
        double.tryParse(p[zi]) ?? 0,
      ));
    }
    final List<Tri3> ts = <Tri3>[];
    for (int i = 0; i < faceCount && cursor < lines.length; i++, cursor++) {
      final List<String> p = lines[cursor].trim().split(RegExp(r'\s+'));
      if (p.isEmpty || faceListCount == 0) continue;
      final int n = int.tryParse(p.first) ?? 0;
      final List<int> idx = <int>[];
      for (int k = 0; k < n && 1 + k < p.length; k++) {
        final int? v = int.tryParse(p[1 + k]);
        if (v != null && v >= 0 && v < vs.length) idx.add(v);
      }
      for (int k = 1; k + 1 < idx.length; k++) {
        ts.add(Tri3(idx[0], idx[k], idx[k + 1]));
      }
    }
    if (vs.isEmpty || ts.isEmpty) {
      throw const MeshFormatException('PLY 没有解析出可用面');
    }
    return Mesh3D(vertices: vs, triangles: ts);
  }

  /// 按字节解析 PLY：ASCII 与二进制（little/big endian）都支持。
  ///
  /// 头部是 ASCII 文本，以 `end_header` 行结束；二进制体紧跟其后。
  /// vertex 只取 x/y/z（按属性名定位，颜色、法向等其他属性按类型跳过），
  /// face 只取顶点索引列表（`property list <count> <item> ...`）。
  /// 顶点元素含 list 属性、未知标量类型、体截断时明确报错，不猜格式。
  static MeshLoadResult fromPlyBytes(Uint8List bytes) {
    final int headerEnd = _plyHeaderEnd(bytes);
    if (headerEnd < 0) {
      throw const MeshFormatException('PLY 头不完整：缺少 end_header');
    }
    final String headerText =
        ascii.decode(bytes.sublist(0, headerEnd), allowInvalid: true);
    final List<String> headerLines =
        const LineSplitter().convert(headerText);
    String format = '';
    Endian endian = Endian.little;
    final List<_PlyElement> elements = <_PlyElement>[];
    _PlyElement? current;
    for (final String rawLine in headerLines) {
      final String line = rawLine.trim();
      if (line.isEmpty ||
          line.startsWith('comment') ||
          line.startsWith('obj_info')) {
        continue;
      }
      final List<String> p = line.split(RegExp(r'\s+'));
      if (p.first == 'format' && p.length >= 2) {
        format = p[1];
        if (format == 'binary_big_endian') endian = Endian.big;
      } else if (p.first == 'element' && p.length >= 3) {
        current = _PlyElement(p[1], int.tryParse(p[2]) ?? 0);
        elements.add(current);
      } else if (p.first == 'property' && current != null) {
        if (p.length >= 5 && p[1] == 'list') {
          current.properties.add(_PlyProperty.list(p[2], p[3], p[4]));
        } else if (p.length >= 3) {
          current.properties.add(_PlyProperty.scalar(p[1], p[2]));
        }
      }
    }
    if (format == 'ascii') {
      // ASCII 体仍是文本：复用 fromPly 的行解析。
      return MeshLoadResult(
        mesh: fromPly(ascii.decode(bytes, allowInvalid: true)),
        format: 'ply-ascii',
      );
    }
    if (format != 'binary_little_endian' &&
        format != 'binary_big_endian') {
      throw MeshFormatException(
          'PLY 格式不支持：$format（仅支持 ascii / binary 1.0）');
    }
    _PlyElement? vertexEl;
    _PlyElement? faceEl;
    for (final _PlyElement e in elements) {
      if (e.name == 'vertex' && vertexEl == null) vertexEl = e;
      if (e.name == 'face' && faceEl == null) faceEl = e;
    }
    if (vertexEl == null || vertexEl.count <= 0) {
      throw const MeshFormatException('PLY 头不完整：缺少 vertex 元素');
    }
    if (vertexEl.properties.any((_PlyProperty p) => p.isList)) {
      throw const MeshFormatException('PLY 二进制 vertex 元素不支持 list 属性');
    }
    final int xi =
        vertexEl.properties.indexWhere((_PlyProperty p) => p.name == 'x');
    final int yi =
        vertexEl.properties.indexWhere((_PlyProperty p) => p.name == 'y');
    final int zi =
        vertexEl.properties.indexWhere((_PlyProperty p) => p.name == 'z');
    if (xi < 0 || yi < 0 || zi < 0) {
      throw const MeshFormatException('PLY 顶点缺少 x/y/z 属性');
    }

    final ByteData data = ByteData.sublistView(bytes);
    int offset = headerEnd;
    double readScalar(String type) {
      final int size = _plyScalarSize(type);
      if (size <= 0) {
        throw MeshFormatException('PLY 标量类型不支持：$type');
      }
      if (offset + size > bytes.length) {
        throw const MeshFormatException('PLY 二进制体截断：顶点/面数据不完整');
      }
      final double v = _plyReadScalar(data, offset, type, endian);
      offset += size;
      return v;
    }

    final List<Vec3> vs = <Vec3>[];
    for (int i = 0; i < vertexEl.count; i++) {
      double x = 0, y = 0, z = 0;
      for (int k = 0; k < vertexEl.properties.length; k++) {
        final double v = readScalar(vertexEl.properties[k].type);
        if (k == xi) x = v;
        if (k == yi) y = v;
        if (k == zi) z = v;
      }
      vs.add(Vec3(x, y, z));
    }
    final List<Tri3> ts = <Tri3>[];
    if (faceEl != null) {
      for (int i = 0; i < faceEl.count; i++) {
        // 先跳过 face 的前置标量属性，再读 list 属性；list 之后的属性
        // （极少见）同样按类型跳过。
        List<int>? idx;
        for (final _PlyProperty prop in faceEl.properties) {
          if (!prop.isList) {
            readScalar(prop.type);
            continue;
          }
          final int n = readScalar(prop.countType!).toInt();
          if (n < 0 || n > 1 << 20) {
            throw const MeshFormatException('PLY 面顶点数异常');
          }
          idx = <int>[];
          for (int k = 0; k < n; k++) {
            final int v = readScalar(prop.itemType!).toInt();
            if (v >= 0 && v < vs.length) idx.add(v);
          }
        }
        if (idx != null) {
          for (int k = 1; k + 1 < idx.length; k++) {
            ts.add(Tri3(idx[0], idx[k], idx[k + 1]));
          }
        }
      }
    }
    if (vs.isEmpty || ts.isEmpty) {
      throw const MeshFormatException('PLY 没有解析出可用面');
    }
    return MeshLoadResult(
        mesh: Mesh3D(vertices: vs, triangles: ts), format: 'ply-binary');
  }

  /// 在字节流里找 `end_header` 行尾（含换行）的偏移；找不到返回 -1。
  static int _plyHeaderEnd(Uint8List bytes) {
    const List<int> marker = <int>[
      101, 110, 100, 95, 104, 101, 97, 100, 101, 114
    ]; // end_header
    for (int i = 0; i + marker.length <= bytes.length; i++) {
      bool match = true;
      for (int k = 0; k < marker.length; k++) {
        if (bytes[i + k] != marker[k]) {
          match = false;
          break;
        }
      }
      if (!match) continue;
      // 行尾：下一个 '\n'（含）即体开始；允许 '\r\n' 与行尾空格。
      for (int j = i + marker.length; j < bytes.length; j++) {
        if (bytes[j] == 10) return j + 1;
        if (bytes[j] != 13 && bytes[j] != 32 && bytes[j] != 9) break;
      }
      return -1;
    }
    return -1;
  }

  /// PLY 标量类型字节数；未知类型返回 -1。
  static int _plyScalarSize(String type) {
    switch (type) {
      case 'char':
      case 'int8':
      case 'uchar':
      case 'uint8':
        return 1;
      case 'short':
      case 'int16':
      case 'ushort':
      case 'uint16':
        return 2;
      case 'int':
      case 'int32':
      case 'uint':
      case 'uint32':
      case 'float':
      case 'float32':
        return 4;
      case 'double':
      case 'float64':
        return 8;
    }
    return -1;
  }

  /// 按 PLY 标量类型从 ByteData 读一个值，统一转 double。
  static double _plyReadScalar(
      ByteData data, int offset, String type, Endian endian) {
    switch (type) {
      case 'char':
      case 'int8':
        return data.getInt8(offset).toDouble();
      case 'uchar':
      case 'uint8':
        return data.getUint8(offset).toDouble();
      case 'short':
      case 'int16':
        return data.getInt16(offset, endian).toDouble();
      case 'ushort':
      case 'uint16':
        return data.getUint16(offset, endian).toDouble();
      case 'int':
      case 'int32':
        return data.getInt32(offset, endian).toDouble();
      case 'uint':
      case 'uint32':
        return data.getUint32(offset, endian).toDouble();
      case 'float':
      case 'float32':
        return data.getFloat32(offset, endian);
      case 'double':
      case 'float64':
        return data.getFloat64(offset, endian);
    }
    throw MeshFormatException('PLY 标量类型不支持：$type');
  }

  // ---------------------------------------------------------------------------
  // 变换
  // ---------------------------------------------------------------------------

  /// 绕 X/Y/Z 轴旋转（角度制）+ 缩放 + 平移，顺序：缩放 → 旋转 → 平移。
  Mesh3D transformed({
    double scale = 1,
    Vec3 translate = Vec3.zero,
    double rotateXDeg = 0,
    double rotateYDeg = 0,
    double rotateZDeg = 0,
  }) {
    final double rx = rotateXDeg * math.pi / 180;
    final double ry = rotateYDeg * math.pi / 180;
    final double rz = rotateZDeg * math.pi / 180;
    final double cx = math.cos(rx), sx = math.sin(rx);
    final double cy = math.cos(ry), sy = math.sin(ry);
    final double cz = math.cos(rz), sz = math.sin(rz);

    Vec3 apply(Vec3 p) {
      double x = p.x * scale, y = p.y * scale, z = p.z * scale;
      // X
      double y1 = y * cx - z * sx;
      double z1 = y * sx + z * cx;
      // Y
      double x2 = x * cy + z1 * sy;
      double z2 = -x * sy + z1 * cy;
      // Z
      double x3 = x2 * cz - y1 * sz;
      double y3 = x2 * sz + y1 * cz;
      return Vec3(x3 + translate.x, y3 + translate.y, z2 + translate.z);
    }

    return Mesh3D(
      vertices: vertices.map(apply).toList(growable: false),
      triangles: triangles,
    );
  }

  /// 归一化到单位盒：包围盒中心移到原点，最长边等比缩放到 [size]。
  ///
  /// 导入的模型常带任意原点与单位（例如毫米坐标 x∈[1000, 1100]）：
  /// 渲染层按原点半径定缩放时，这类模型会缩成一点或偏出画面。
  /// 归一化只用于返回给渲染的顶点；统计仍按原始网格计算。
  /// 空网格原样返回；退化为单点的网格只做居中，不缩放；
  /// [size] 必须大于 0，否则抛 [MeshFormatException]。
  Mesh3D normalized({double size = 2}) {
    if (isEmpty) return this;
    if (size <= 0 || size.isNaN || size.isInfinite) {
      throw const MeshFormatException('归一化尺寸需为有限正数');
    }
    final MeshStats s = stats();
    final double cx = (s.min.x + s.max.x) / 2;
    final double cy = (s.min.y + s.max.y) / 2;
    final double cz = (s.min.z + s.max.z) / 2;
    final double longest = math.max(s.width, math.max(s.height, s.depth));
    final double k = longest > 0 ? size / longest : 1;
    return Mesh3D(
      vertices: vertices
          .map((Vec3 p) =>
              Vec3((p.x - cx) * k, (p.y - cy) * k, (p.z - cz) * k))
          .toList(growable: false),
      triangles: triangles,
    );
  }

  // ---------------------------------------------------------------------------
  // 统计
  // ---------------------------------------------------------------------------

  MeshStats stats() {
    if (isEmpty) {
      return const MeshStats(
        vertexCount: 0,
        triangleCount: 0,
        min: Vec3.zero,
        max: Vec3.zero,
        surfaceArea: 0,
        volume: 0,
        watertight: false,
      );
    }
    double minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    double maxX = -double.infinity, maxY = -double.infinity, maxZ = -double.infinity;
    for (final Vec3 v in vertices) {
      minX = math.min(minX, v.x);
      minY = math.min(minY, v.y);
      minZ = math.min(minZ, v.z);
      maxX = math.max(maxX, v.x);
      maxY = math.max(maxY, v.y);
      maxZ = math.max(maxZ, v.z);
    }

    double area = 0;
    double volume = 0;
    final Map<String, int> edgeUse = <String, int>{};
    for (final Tri3 t in triangles) {
      final Vec3 a = vertices[t.a];
      final Vec3 b = vertices[t.b];
      final Vec3 c = vertices[t.c];
      area += (b - a).cross(c - a).length / 2;
      volume += a.dot(b.cross(c)) / 6;
      for (final List<int> e in <List<int>>[
        <int>[t.a, t.b],
        <int>[t.b, t.c],
        <int>[t.c, t.a],
      ]) {
        final String key = e[0] < e[1] ? '${e[0]}-${e[1]}' : '${e[1]}-${e[0]}';
        edgeUse[key] = (edgeUse[key] ?? 0) + 1;
      }
    }
    final bool watertight =
        edgeUse.isNotEmpty && edgeUse.values.every((int n) => n == 2);

    return MeshStats(
      vertexCount: vertices.length,
      triangleCount: triangles.length,
      min: Vec3(minX, minY, minZ),
      max: Vec3(maxX, maxY, maxZ),
      surfaceArea: area,
      volume: volume.abs(),
      watertight: watertight,
    );
  }

  // ---------------------------------------------------------------------------
  // 导出
  // ---------------------------------------------------------------------------

  /// OBJ 文本：`# TGA 3D Studio` 头 + 顶点 + 面（1 基索引）。
  String toObj({String name = 'tangram-model'}) {
    // 按坐标焊接后写盘：立方体这类共享拓扑模型导出的是 8 个唯一顶点而非
    // 每面重复的 24 个，重新导入后 stats/封闭性判定与原始网格一致。
    final Map<String, int> weld = <String, int>{};
    final List<Vec3> unique = <Vec3>[];
    final List<Tri3> faces = <Tri3>[];
    for (final Tri3 t in triangles) {
      faces.add(Tri3(
        _weld(vertices[t.a], weld, unique),
        _weld(vertices[t.b], weld, unique),
        _weld(vertices[t.c], weld, unique),
      ));
    }
    final StringBuffer sb = StringBuffer()
      ..writeln('# TGA 3D Studio')
      ..writeln('# exported ${DateTime.now().toIso8601String()}')
      ..writeln('o $name');
    for (final Vec3 v in unique) {
      sb.writeln('v ${v.x.toStringAsFixed(6)} ${v.y.toStringAsFixed(6)} '
          '${v.z.toStringAsFixed(6)}');
    }
    for (final Tri3 t in faces) {
      sb.writeln('f ${t.a + 1} ${t.b + 1} ${t.c + 1}');
    }
    return sb.toString();
  }

  /// 二进制 STL：80 字节头 + uint32 面数 + 每面 50 字节（法向 + 3 顶点 + 属性）。
  Uint8List toStlBinary({String name = 'tangram-model'}) {
    final ByteData header = ByteData(80);
    final Uint8List nameBytes =
        Uint8List.fromList(utf8.encode('TGA 3D Studio $name'));
    header.buffer.asUint8List().setRange(0, math.min(80, nameBytes.length), nameBytes);
    final ByteData out = ByteData(84 + triangles.length * 50);
    out.buffer.asUint8List().setRange(0, 80, header.buffer.asUint8List());
    out.setUint32(80, triangles.length, Endian.little);
    for (int i = 0; i < triangles.length; i++) {
      // 每条记录严格 50 字节：法向 12 + 3 顶点 36 + 属性 2。
      final int base = 84 + i * 50;
      final Tri3 t = triangles[i];
      final Vec3 a = vertices[t.a];
      final Vec3 b = vertices[t.b];
      final Vec3 c = vertices[t.c];
      final Vec3 n = (b - a).cross(c - a).normalized;
      out.setFloat32(base, n.x, Endian.little);
      out.setFloat32(base + 4, n.y, Endian.little);
      out.setFloat32(base + 8, n.z, Endian.little);
      final List<Vec3> vs = <Vec3>[a, b, c];
      for (int v = 0; v < 3; v++) {
        out.setFloat32(base + 12 + v * 12, vs[v].x, Endian.little);
        out.setFloat32(base + 16 + v * 12, vs[v].y, Endian.little);
        out.setFloat32(base + 20 + v * 12, vs[v].z, Endian.little);
      }
      out.setUint16(base + 48, 0, Endian.little); // 属性字节数
    }
    return out.buffer.asUint8List();
  }

  /// ASCII STL 导出：`solid <name>` + 每面 `facet normal` / `outer loop` /
  /// 3 行 `vertex` / `endloop` / `endfacet` + `endsolid <name>`。
  /// 与二进制 STL 用同一套面法向计算，6 位小数写出；导出的文本用
  /// [fromStl] 重新解析后统计与原网格一致（STL 本身不存共享顶点，
  /// 往返后顶点数按焊接后的唯一顶点计，与二进制 STL 往返一致）。
  String toStlAscii({String name = 'tangram-model'}) {
    final StringBuffer sb = StringBuffer()..writeln('solid $name');
    for (final Tri3 t in triangles) {
      final Vec3 a = vertices[t.a];
      final Vec3 b = vertices[t.b];
      final Vec3 c = vertices[t.c];
      final Vec3 n = (b - a).cross(c - a).normalized;
      sb
        ..writeln(' facet normal ${n.x.toStringAsFixed(6)} '
            '${n.y.toStringAsFixed(6)} ${n.z.toStringAsFixed(6)}')
        ..writeln('  outer loop');
      for (final Vec3 v in <Vec3>[a, b, c]) {
        sb.writeln('   vertex ${v.x.toStringAsFixed(6)} '
            '${v.y.toStringAsFixed(6)} ${v.z.toStringAsFixed(6)}');
      }
      sb
        ..writeln('  endloop')
        ..writeln(' endfacet');
    }
    sb.writeln('endsolid $name');
    return sb.toString();
  }

  /// ASCII PLY 导出：`ply` 魔数 + `format ascii 1.0` 头 + 顶点 x/y/z
  /// + 面顶点索引列表。顶点同样先按坐标焊接，与 OBJ 导出一致，
  /// 因此导出的 PLY 用 [fromPlyBytes] 重新解析后统计与原网格一致。
  String toPly({String name = 'tangram-model'}) {
    final Map<String, int> weld = <String, int>{};
    final List<Vec3> unique = <Vec3>[];
    final List<Tri3> faces = <Tri3>[];
    for (final Tri3 t in triangles) {
      faces.add(Tri3(
        _weld(vertices[t.a], weld, unique),
        _weld(vertices[t.b], weld, unique),
        _weld(vertices[t.c], weld, unique),
      ));
    }
    final StringBuffer sb = StringBuffer()
      ..writeln('ply')
      ..writeln('format ascii 1.0')
      ..writeln('comment TGA 3D Studio $name')
      ..writeln('element vertex ${unique.length}')
      ..writeln('property float x')
      ..writeln('property float y')
      ..writeln('property float z')
      ..writeln('element face ${faces.length}')
      ..writeln('property list uchar int vertex_indices')
      ..writeln('end_header');
    for (final Vec3 v in unique) {
      sb.writeln('${v.x.toStringAsFixed(6)} ${v.y.toStringAsFixed(6)} '
          '${v.z.toStringAsFixed(6)}');
    }
    for (final Tri3 t in faces) {
      sb.writeln('3 ${t.a} ${t.b} ${t.c}');
    }
    return sb.toString();
  }

  /// UI 渲染用的轻量 JSON（顶点扁平数组 + 面索引扁平数组）。
  Map<String, dynamic> toJson({int maxTriangles = 20000}) {
    final List<double> v = <double>[];
    for (final Vec3 p in vertices) {
      v
        ..add(p.x)
        ..add(p.y)
        ..add(p.z);
    }
    final int tri = math.min(triangles.length, maxTriangles);
    final List<int> f = <int>[];
    for (int i = 0; i < tri; i++) {
      f
        ..add(triangles[i].a)
        ..add(triangles[i].b)
        ..add(triangles[i].c);
    }
    return <String, dynamic>{
      'vertices': v,
      'faces': f,
      'triangle_count': triangles.length,
      'rendered_triangles': tri,
      'truncated': tri < triangles.length,
    };
  }
}

/// PLY 头部里的一个 element（vertex / face / 其他）。
class _PlyElement {
  _PlyElement(this.name, this.count);
  final String name;
  final int count;
  final List<_PlyProperty> properties = <_PlyProperty>[];
}

/// PLY 头部里的一条 property：标量，或 list（count 类型 + item 类型）。
class _PlyProperty {
  _PlyProperty.scalar(this.type, this.name)
      : isList = false,
        countType = null,
        itemType = null;
  _PlyProperty.list(this.countType, this.itemType, this.name)
      : isList = true,
        type = '';
  final String type;
  final String name;
  final bool isList;
  final String? countType;
  final String? itemType;
}