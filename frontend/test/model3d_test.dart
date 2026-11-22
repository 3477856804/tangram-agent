/// 3D 建模核心测试：真实解析/统计/变换/导出往返。
///
/// 断言都基于几何事实（顶点数、面数、体积、闭合性、字节长度），
/// 不使用任何写死的「示例输出」。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tangram/harness/model3d.dart';

void main() {
  group('OBJ 解析', () {
    test('四边形按扇形三角化，负索引可用', () {
      const String obj = '''
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
f 1 2 3 4
''';
      final Mesh3D m = Mesh3D.fromObj(obj);
      expect(m.vertexCount, 4);
      expect(m.triangleCount, 2);
      final MeshStats s = m.stats();
      expect(s.width, 1);
      expect(s.height, 1);
      expect(s.watertight, isFalse); // 单个平面不是闭合体
    });

    test('负索引指向末尾顶点', () {
      const String obj = '''
v 0 0 0
v 1 0 0
v 1 1 0
f -3 -2 -1
''';
      final Mesh3D m = Mesh3D.fromObj(obj);
      expect(m.triangles.single.indices, <int>[0, 1, 2]);
    });

    test('没有面时报错，不返回空网格', () {
      expect(() => Mesh3D.fromObj('v 0 0 0\n'),
          throwsA(isA<MeshFormatException>()));
    });
  });

  group('STL', () {
    test('二进制 STL 往返一致', () {
      final Mesh3D box = Mesh3D.box();
      final Uint8List bytes = box.toStlBinary(name: 'box');
      // 80 字节头 + 4 字节面数 + 12 面 × 50 字节
      expect(bytes.length, 84 + 12 * 50);
      final MeshLoadResult r = Mesh3D.fromStl(bytes);
      expect(r.format, 'stl-binary');
      expect(r.mesh.triangleCount, 12);
      expect(r.mesh.stats().volume, closeTo(1.0, 1e-4));
      expect(r.mesh.stats().watertight, isTrue);
    });

    test('ASCII STL 每三个 vertex 组成一面', () {
      const String stl = '''
solid s
facet normal 0 0 1
outer loop
vertex 0 0 0
vertex 1 0 0
vertex 0 1 0
endloop
endfacet
endsolid s
''';
      final MeshLoadResult r =
          Mesh3D.fromStl(Uint8List.fromList(utf8.encode(stl)));
      expect(r.format, 'stl-ascii');
      expect(r.mesh.triangleCount, 1);
    });

    test('损坏的 STL 明确报错', () {
      expect(() => Mesh3D.fromStl(Uint8List.fromList(<int>[1, 2, 3])),
          throwsA(isA<MeshFormatException>()));
    });
  });

  group('PLY', () {
    test('ASCII PLY 读取 vertex 与 face 列表', () {
      const String ply = '''
ply
format ascii 1.0
element vertex 4
property float x
property float y
property float z
element face 1
property list uchar int vertex_indices
end_header
0 0 0
1 0 0
1 1 0
0 1 0
4 0 1 2 3
''';
      final Mesh3D m = Mesh3D.fromPly(ply);
      expect(m.vertexCount, 4);
      expect(m.triangleCount, 2);
    });

    test('binary PLY 如实拒绝', () {
      const String ply = '''
ply
format binary_little_endian 1.0
element vertex 0
end_header
''';
      expect(() => Mesh3D.fromPly(ply),
          throwsA(isA<MeshFormatException>()));
    });

    test('ASCII PLY 经 parseBytes 报告 ply-ascii', () {
      const String ply = '''
ply
format ascii 1.0
element vertex 4
property float x
property float y
property float z
element face 1
property list uchar int vertex_indices
end_header
0 0 0
1 0 0
1 1 0
0 1 0
4 0 1 2 3
''';
      final MeshLoadResult r =
          Mesh3D.parseBytes('m.ply', Uint8List.fromList(utf8.encode(ply)));
      expect(r.format, 'ply-ascii');
      expect(r.mesh.vertexCount, 4);
      expect(r.mesh.triangleCount, 2);
    });

    test('binary little-endian PLY 读取 vertex 与 face', () {
      const String header = '''
ply
format binary_little_endian 1.0
element vertex 4
property float x
property float y
property float z
element face 1
property list uchar int vertex_indices
end_header
''';
      final List<List<double>> verts = <List<double>>[
        <double>[0, 0, 0],
        <double>[1, 0, 0],
        <double>[1, 1, 0],
        <double>[0, 1, 0],
      ];
      final ByteData body = ByteData(4 * 12 + 1 + 4 * 4);
      int o = 0;
      for (final List<double> v in verts) {
        for (final double c in v) {
          body.setFloat32(o, c, Endian.little);
          o += 4;
        }
      }
      body.setUint8(o, 4);
      o += 1;
      for (final int i in <int>[0, 1, 2, 3]) {
        body.setInt32(o, i, Endian.little);
        o += 4;
      }
      final Uint8List bytes = _plyBytes(header, body.buffer.asUint8List());
      final MeshLoadResult r = Mesh3D.parseBytes('m.ply', bytes);
      expect(r.format, 'ply-binary');
      expect(r.mesh.vertexCount, 4);
      expect(r.mesh.triangleCount, 2);
      expect(r.mesh.vertices[1].x, 1);
      expect(r.mesh.vertices[2].y, 1);
    });

    test('binary big-endian PLY（double 坐标）读取正常', () {
      const String header = '''
ply
format binary_big_endian 1.0
element vertex 3
property double x
property double y
property double z
element face 1
property list uchar uint vertex_indices
end_header
''';
      final ByteData body = ByteData(3 * 24 + 1 + 3 * 4);
      int o = 0;
      for (final List<double> v in <List<double>>[
        <double>[0, 0, 0],
        <double>[2, 0, 0],
        <double>[0, 3, 0],
      ]) {
        for (final double c in v) {
          body.setFloat64(o, c, Endian.big);
          o += 8;
        }
      }
      body.setUint8(o, 3);
      o += 1;
      for (final int i in <int>[0, 1, 2]) {
        body.setUint32(o, i, Endian.big);
        o += 4;
      }
      final MeshLoadResult r = Mesh3D.parseBytes(
          'm.ply', _plyBytes(header, body.buffer.asUint8List()));
      expect(r.format, 'ply-binary');
      expect(r.mesh.vertices[1].x, 2);
      expect(r.mesh.vertices[2].y, 3);
      expect(r.mesh.triangleCount, 1);
    });

    test('binary PLY 带法向与颜色属性仍能读出 x/y/z', () {
      const String header = '''
ply
format binary_little_endian 1.0
element vertex 3
property float nx
property float ny
property float nz
property float x
property float y
property float z
property uchar red
property uchar green
property uchar blue
element face 1
property list uchar int vertex_indices
end_header
''';
      // 每顶点 27 字节：法向 12 + 坐标 12 + 颜色 3。
      final ByteData body = ByteData(3 * 27 + 1 + 3 * 4);
      int o = 0;
      for (final List<double> v in <List<double>>[
        <double>[0, 0, 0],
        <double>[1, 0, 0],
        <double>[0, 1, 0],
      ]) {
        for (int k = 0; k < 3; k++) {
          body.setFloat32(o, 0, Endian.little);
          o += 4;
        }
        for (final double c in v) {
          body.setFloat32(o, c, Endian.little);
          o += 4;
        }
        for (int k = 0; k < 3; k++) {
          body.setUint8(o, 255);
          o += 1;
        }
      }
      body.setUint8(o, 3);
      o += 1;
      for (final int i in <int>[0, 1, 2]) {
        body.setInt32(o, i, Endian.little);
        o += 4;
      }
      final MeshLoadResult r = Mesh3D.parseBytes(
          'm.ply', _plyBytes(header, body.buffer.asUint8List()));
      expect(r.mesh.vertexCount, 3);
      expect(r.mesh.vertices[1].x, 1);
      expect(r.mesh.vertices[2].y, 1);
    });

    test('截断的 binary PLY 明确报错', () {
      const String header = '''
ply
format binary_little_endian 1.0
element vertex 4
property float x
property float y
property float z
element face 1
property list uchar int vertex_indices
end_header
''';
      // 只给 2 个顶点的字节，声明了 4 个。
      final ByteData body = ByteData(2 * 12);
      expect(
          () => Mesh3D.parseBytes(
              'm.ply', _plyBytes(header, body.buffer.asUint8List())),
          throwsA(isA<MeshFormatException>()));
    });
  });

  group('网格能力', () {
    test('立方体统计：8 顶点、12 面、体积 1、闭合', () {
      final Mesh3D cube = Mesh3D.box();
      final MeshStats s = cube.stats();
      expect(s.vertexCount, 8);
      expect(s.triangleCount, 12);
      expect(s.volume, closeTo(1, 1e-9));
      expect(s.surfaceArea, closeTo(6, 1e-9));
      expect(s.watertight, isTrue);
      expect(s.width, 1);
    });

    test('低模鹿是真实网格并按比例缩放', () {
      final Mesh3D deer = Mesh3D.deer();
      final MeshStats s = deer.stats();
      expect(s.triangleCount, greaterThan(50));
      expect(s.height, greaterThan(1.5)); // 含鹿角
      final Mesh3D half = deer.transformed(scale: 0.5);
      expect(half.stats().height, closeTo(s.height / 2, 1e-6));
    });

    test('OBJ 导出后重新解析保持一致', () {
      final Mesh3D deer = Mesh3D.deer();
      final Mesh3D again = Mesh3D.fromObj(deer.toObj());
      expect(again.triangleCount, deer.triangleCount);
      expect(again.vertexCount, deer.vertexCount);
      expect(again.stats().volume, closeTo(deer.stats().volume, 1e-3));
    });

    test('渲染 JSON 截断时如实标记', () {
      final Mesh3D deer = Mesh3D.deer();
      final Map<String, dynamic> json = deer.toJson(maxTriangles: 5);
      expect(json['rendered_triangles'], 5);
      expect(json['truncated'], isTrue);
      expect((json['faces'] as List<int>).length, 15);
    });

    test('按扩展名分派未知格式报错', () {
      expect(() => Mesh3D.parseBytes('x.gltf', Uint8List(0)),
          throwsA(isA<MeshFormatException>()));
    });
  });

  group('归一化', () {
    test('毫米坐标盒子归一化后居中且最长边为 2', () {
      // 模拟 CAD 毫米导出：1×1×1 的盒子平移到 x∈[1000,1001]。
      final Mesh3D raw = Mesh3D.box().transformed(
        translate: const Vec3(1000.5, -500, 200),
      );
      final MeshStats before = raw.stats();
      expect(before.min.x, closeTo(1000, 1e-9));
      final Mesh3D n = raw.normalized();
      final MeshStats s = n.stats();
      expect(s.width, closeTo(2, 1e-9));
      expect(s.height, closeTo(2, 1e-9));
      expect(s.depth, closeTo(2, 1e-9));
      expect(s.min.x, closeTo(-1, 1e-9));
      expect(s.max.x, closeTo(1, 1e-9));
      expect(s.volume, closeTo(8, 1e-6));
      expect(n.triangleCount, raw.triangleCount);
      // 原网格不动：归一化不修改输入。
      expect(raw.stats().min.x, closeTo(1000, 1e-9));
    });

    test('长条模型按最长边缩放，比例不变', () {
      final Mesh3D bar = Mesh3D.box(width: 4, height: 1, depth: 2);
      final Mesh3D n = bar.normalized();
      final MeshStats s = n.stats();
      expect(s.width, closeTo(2, 1e-9));
      expect(s.height, closeTo(0.5, 1e-9));
      expect(s.depth, closeTo(1, 1e-9));
      expect(s.min.y, closeTo(-0.25, 1e-9));
    });

    test('size 参数生效', () {
      final Mesh3D n = Mesh3D.box().normalized(size: 1);
      expect(n.stats().width, closeTo(1, 1e-9));
    });

    test('空网格原样返回，不抛错', () {
      final Mesh3D empty = Mesh3D.empty();
      expect(identical(empty.normalized(), empty), isTrue);
    });

    test('非法 size 明确报错', () {
      expect(() => Mesh3D.box().normalized(size: 0),
          throwsA(isA<MeshFormatException>()));
      expect(() => Mesh3D.box().normalized(size: -1),
          throwsA(isA<MeshFormatException>()));
    });

    test('退化单点网格只居中不缩放', () {
      // 三顶点重合的退化三角面：包围盒长宽高均为 0。
      final Mesh3D dot = Mesh3D(
        vertices: <Vec3>[
          const Vec3(1000, 2000, 3000),
          const Vec3(1000, 2000, 3000),
          const Vec3(1000, 2000, 3000),
        ],
        triangles: const <Tri3>[Tri3(0, 1, 2)],
      );
      final Mesh3D n = dot.normalized();
      for (final Vec3 v in n.vertices) {
        expect(v.x, closeTo(0, 1e-9));
        expect(v.y, closeTo(0, 1e-9));
        expect(v.z, closeTo(0, 1e-9));
      }
      expect(n.triangleCount, 1);
    });
  });
  group('PLY 导出', () {
    test('立方体 PLY 头正确，往返后统计一致', () {
      final Mesh3D cube = Mesh3D.box();
      final String ply = cube.toPly();
      expect(ply.startsWith('ply\nformat ascii 1.0\n'), isTrue);
      expect(ply, contains('element vertex 8'));
      expect(ply, contains('element face 12'));
      expect(ply, contains('property list uchar int vertex_indices'));
      final MeshLoadResult r = Mesh3D.fromPlyBytes(
        Uint8List.fromList(utf8.encode(ply)),
      );
      expect(r.format, 'ply-ascii');
      expect(r.mesh.vertexCount, 8);
      expect(r.mesh.triangleCount, 12);
      expect(r.mesh.stats().volume, closeTo(1, 1e-6));
      expect(r.mesh.stats().watertight, isTrue);
    });

    test('低模鹿 PLY 导出后重新解析保持一致', () {
      final Mesh3D deer = Mesh3D.deer();
      final MeshLoadResult r = Mesh3D.fromPlyBytes(
        Uint8List.fromList(utf8.encode(deer.toPly())),
      );
      expect(r.mesh.triangleCount, deer.triangleCount);
      expect(r.mesh.vertexCount, deer.vertexCount);
      expect(r.mesh.stats().volume, closeTo(deer.stats().volume, 1e-3));
    });

    test('PLY 顶点与面行按 6 位小数与 0 基索引写出', () {
      final String ply = Mesh3D.box().toPly();
      expect(ply, contains('-0.500000 -0.500000 -0.500000'));
      expect(ply, contains('\n3 0 1 2\n'));
    });
  });

  group('STL ASCII 导出', () {
    test('立方体 ASCII STL 头尾与面数正确，往返后统计一致', () {
      final Mesh3D cube = Mesh3D.box();
      final String stl = cube.toStlAscii();
      expect(stl.startsWith('solid tangram-model\n'), isTrue);
      expect(stl.trimRight().endsWith('endsolid tangram-model'), isTrue);
      expect('facet normal'.allMatches(stl).length, 12);
      expect('vertex '.allMatches(stl).length, 36);
      final MeshLoadResult r =
          Mesh3D.fromStl(Uint8List.fromList(utf8.encode(stl)));
      expect(r.format, 'stl-ascii');
      expect(r.mesh.triangleCount, 12);
      expect(r.mesh.stats().volume, closeTo(1, 1e-6));
      expect(r.mesh.stats().watertight, isTrue);
    });

    test('低模鹿 ASCII STL 导出后重新解析保持一致', () {
      final Mesh3D deer = Mesh3D.deer();
      final MeshLoadResult r = Mesh3D.fromStl(
        Uint8List.fromList(utf8.encode(deer.toStlAscii())),
      );
      expect(r.format, 'stl-ascii');
      expect(r.mesh.triangleCount, deer.triangleCount);
      expect(r.mesh.vertexCount, deer.vertexCount);
      expect(r.mesh.stats().volume, closeTo(deer.stats().volume, 1e-3));
    });

    test('ASCII STL 法向与顶点按 6 位小数写出', () {
      final String stl = Mesh3D.box().toStlAscii();
      expect(
        RegExp(r'facet normal -?\d+\.\d{6} -?\d+\.\d{6} -?\d+\.\d{6}')
            .hasMatch(stl),
        isTrue,
      );
      expect(stl, contains('vertex -0.500000 -0.500000 -0.500000'));
      expect(stl, contains(' outer loop\n'));
    });
  });
}

/// 把 PLY 头文本与二进制体拼成完整文件字节（测试固件用）。
Uint8List _plyBytes(String header, Uint8List body) {
  final BytesBuilder b = BytesBuilder();
  b.add(utf8.encode(header));
  b.add(body);
  return b.toBytes();
}