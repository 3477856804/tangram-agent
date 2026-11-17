"""TGA 3D 参数化建模（build123d / OCCT 真实内核）。

与端侧 mesh 查看器（OBJ/STL/PLY）互补：这里生成**精确 B-rep 几何**并导出
STEP / STL。build123d 是可选依赖（pip install build123d），未安装时明确报错，
绝不返回假模型或空文件。

支持：
  * box / cylinder / sphere / cone 参数化图元
  * 布尔并/差/交
  * 导出 STEP（精确 CAD）与 STL（网格）
  * 基础几何校验（体积、包围盒、面数）
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class CadError(RuntimeError):
    """build123d 缺失或建模失败；错误信息可直接展示给用户。"""


def _build123d():
    try:
        import build123d as bd  # type: ignore
    except Exception as exc:  # pragma: no cover - 依赖缺失路径
        raise CadError(
            "未安装 build123d/OCCT。请在沙箱执行 `pip install build123d` 后重试；"
            f"原始错误：{exc}"
        ) from exc
    return bd


def available() -> dict[str, Any]:
    """真实探测 build123d 是否可用，不导入失败时抛错。"""
    try:
        bd = _build123d()
    except CadError as exc:
        return {"ok": False, "available": False, "error": str(exc)}
    return {
        "ok": True,
        "available": True,
        "version": getattr(bd, "__version__", "unknown"),
    }


def _shape_from_spec(bd, spec: dict[str, Any]):
    kind = (spec.get("type") or "box").lower()
    if kind == "box":
        return bd.Box(
            float(spec.get("length", 10)),
            float(spec.get("width", 10)),
            float(spec.get("height", 10)),
        )
    if kind == "cylinder":
        return bd.Cylinder(
            float(spec.get("radius", 5)),
            float(spec.get("height", 10)),
        )
    if kind == "cone":
        return bd.Cone(
            float(spec.get("bottom_radius", 5)),
            float(spec.get("top_radius", 0)),
            float(spec.get("height", 10)),
        )
    if kind == "sphere":
        return bd.Sphere(float(spec.get("radius", 5)))
    raise CadError(f"未知图元类型：{kind}（box/cylinder/cone/sphere）")


def build(spec: dict[str, Any]):
    """按声明式 spec 构建真实 shape；支持 children + boolean 组合。"""
    bd = _build123d()
    base = _shape_from_spec(bd, spec)
    for child in spec.get("children") or []:
        if not isinstance(child, dict):
            raise CadError("children 必须是对象数组")
        child_shape = build(child)
        op = (child.get("boolean") or "union").lower()
        if op == "union":
            base = base + child_shape
        elif op == "subtract":
            base = base - child_shape
        elif op == "intersect":
            base = base & child_shape
        else:
            raise CadError(f"未知布尔操作：{op}（union/subtract/intersect）")
    return base


def inspect_shape(shape) -> dict[str, Any]:
    """真实读取体积、包围盒与面/边数量。"""
    bb = shape.bounding_box()
    return {
        "volume": round(float(shape.volume), 6),
        "area": round(float(shape.area), 6),
        "faces": len(shape.faces()),
        "edges": len(shape.edges()),
        "bbox": {
            "min": [round(v, 6) for v in (bb.min.X, bb.min.Y, bb.min.Z)],
            "max": [round(v, 6) for v in (bb.max.X, bb.max.Y, bb.max.Z)],
            "size": [round(v, 6) for v in (bb.size.X, bb.size.Y, bb.size.Z)],
        },
    }


def export(shape, dst: str | Path, fmt: str = "stl") -> dict[str, Any]:
    """真实导出 STL 或 STEP；格式不支持时明确拒绝。"""
    bd = _build123d()
    out = Path(dst)
    out.parent.mkdir(parents=True, exist_ok=True)
    f = fmt.lower().strip()
    try:
        if f in ("step", "stp"):
            bd.export_step(shape, str(out))
        elif f == "stl":
            bd.export_stl(shape, str(out))
        else:
            raise CadError(f"不支持的导出格式：{fmt}（stl/step）")
    except CadError:
        raise
    except Exception as exc:
        raise CadError(f"导出失败：{exc}") from exc
    if not out.is_file() or out.stat().st_size <= 0:
        raise CadError("导出后文件为空，拒绝当作成功")
    return {
        "ok": True,
        "output": str(out.resolve()),
        "format": f,
        "size": out.stat().st_size,
        "info": inspect_shape(shape),
    }


def model(spec: dict[str, Any], dst: str | Path, fmt: str = "stl") -> dict[str, Any]:
    """一步建模 + 校验 + 导出。"""
    if not isinstance(spec, dict) or not spec:
        raise CadError("建模 spec 为空")
    shape = build(spec)
    info = inspect_shape(shape)
    if info["volume"] <= 0:
        raise CadError("几何体积为 0，模型无效")
    result = export(shape, dst, fmt)
    result["spec"] = spec
    return result


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="TGA build123d 参数化建模")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    p_build = sub.add_parser("build")
    p_build.add_argument("spec", help="spec JSON 文件或 JSON 字符串")
    p_build.add_argument("-o", "--output", required=True)
    p_build.add_argument("--format", default="stl", choices=["stl", "step", "stp"])
    args = parser.parse_args()
    try:
        if args.cmd == "check":
            result = available()
        else:
            raw = args.spec
            path = Path(raw)
            if path.is_file():
                raw = path.read_text(encoding="utf-8")
            spec = json.loads(raw)
            result = model(spec, args.output, args.format)
    except (CadError, json.JSONDecodeError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
