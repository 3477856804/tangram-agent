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
}