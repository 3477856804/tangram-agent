#!/usr/bin/env python3
"""品牌资产生成：从唯一真源 logo/tangram.svg 派生 App 内使用的「鹿」标。

背景：用户给的 tangram.svg 是完整品牌标（七巧板鹿 + "Tangram" 字样）。
App 内空会话页 / 侧边栏 / 设置页需要的是**纯鹿图形**（对应 dsh 的鲸鱼标），
桌面启动图标也应是纯鹿而非带文字的全标；过去用 CustomPaint 画的四个方块
不是品牌 logo，属于占位，已弃用。

本脚本把「鹿」的矢量路径从真源中裁出（按坐标分离：鹿 y<860，字样 y>=860），
生成透明背景 PNG，供 Flutter 以 colorBlendMode.srcIn 随主题染色。
资产入库且可复现：任意机器 clone 后跑一次本脚本即得同一份文件。

产物：
  logo/tangram_deer.svg                     纯鹿矢量（真源派生）
  frontend/assets/logo/tangram_deer.png    透明 RGBA，512px（App 内染色用）
  frontend/assets/logo/tangram_deer_192.png 透明 RGBA，192px

用法：
  python3 scripts/gen_brand_assets.py
  python3 scripts/gen_brand_assets.py --check      # 只校验不写入
  python3 scripts/gen_brand_assets.py --self-test  # 自测（含幂等与透明通道）

依赖：cairosvg（渲染）、Pillow（校验）。二者均为构建机已有依赖。
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_SVG = ROOT / "logo" / "tangram.svg"
DEER_SVG = ROOT / "logo" / "tangram_deer.svg"
OUT_DIR = ROOT / "frontend" / "assets" / "logo"
OUT_PNG = OUT_DIR / "tangram_deer.png"
OUT_PNG_192 = OUT_DIR / "tangram_deer_192.png"

# 鹿与字样的分界：真源里鹿的 path 最大 y=825，字样最小 y=863。
DEER_MAX_Y = 860.0
# 收紧后的视框：鹿实际范围 x[289,850] y[233,825]，四周留白。
VIEW_BOX = "240 190 670 670"
SIZES = ((OUT_PNG, 512), (OUT_PNG_192, 192))


def _num_y(path_d: str) -> float:
    """取 path 中所有坐标对里 y 的最小值（SVG path 以 M/L/Q 交替 x y）。"""
    nums = [float(x) for x in re.findall(r"-?\d+\.?\d*", path_d)]
    if len(nums) < 2:
        return float("inf")
    return min(nums[1::2])


def build_deer_svg() -> str:
    """从真源裁出鹿：保留 min(y) < DEER_MAX_Y 的 path，重设 viewBox。"""
    src = SRC_SVG.read_text(encoding="utf-8")
    paths = re.findall(r'<path d="([^"]+)"[^>]*/>', src)
    if not paths:
        raise RuntimeError("真源 SVG 未找到任何 <path>，无法派生鹿标")
    deer = [p for p in paths if _num_y(p) < DEER_MAX_Y]
    if len(deer) < 5:
        raise RuntimeError(f"鹿路径过少（{len(deer)}），真源结构可能已变")
    body = "\n".join(f'  <path d="{p}"/>' for p in deer)
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" '
        f'viewBox="{VIEW_BOX}" width="670" height="670">\n'
        '<g fill="#000000" stroke="#000000" stroke-width="1">\n'
        f"{body}\n</g>\n</svg>\n"
    )


def render(svg_text: str, target: Path, size: int) -> None:
    import cairosvg

    target.parent.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(
        bytestring=svg_text.encode("utf-8"),
        write_to=str(target),
        output_width=size,
        output_height=size,
    )


def generate() -> int:
    svg_text = build_deer_svg()
    DEER_SVG.write_text(svg_text, encoding="utf-8")
    for target, size in SIZES:
        render(svg_text, target, size)
    print(f"  [OK ] 鹿矢量已生成：{DEER_SVG}")
    for target, size in SIZES:
        print(f"  [OK ] 透明 PNG {size}px：{target}")
    return 0


def check() -> int:
    from PIL import Image

    problems: list[str] = []
    src_present = SRC_SVG.is_file()
    if not src_present:
        # 精简仓库未保留根目录 logo/ 真源，无法做派生校验；降级为只校验入库 PNG。
        print("  [SKIP] 真源 logo/tangram.svg 不在仓库，跳过 SVG 派生校验，仅校验入库 PNG")
    elif not DEER_SVG.is_file():
        problems.append("缺少 logo/tangram_deer.svg")
    elif "Tangram" in DEER_SVG.read_text(encoding="utf-8"):
        problems.append("鹿 SVG 仍含字样文本")
    for target, size in SIZES:
        if not target.is_file():
            problems.append(f"缺少 {target.name}")
            continue
        with Image.open(target) as im:
            if im.mode != "RGBA":
                problems.append(f"{target.name} 非 RGBA（无法染色）")
            if im.size != (size, size):
                problems.append(f"{target.name} 尺寸不是 {size}")
            alpha = im.getchannel("A").getextrema()
            if not (alpha[0] == 0 and alpha[1] > 0):
                problems.append(f"{target.name} 不是透明背景（alpha 极值 {alpha}）")
    # 幂等：重新构建 SVG 与落盘内容一致
    if DEER_SVG.is_file() and SRC_SVG.is_file():
        if build_deer_svg() != DEER_SVG.read_text(encoding="utf-8"):
            problems.append("鹿 SVG 与真源不一致（需重新生成）")
    for p in problems:
        print(f"  [FAIL] {p}")
    print(f"  [{'OK ' if not problems else 'FAIL'}] 品牌资产校验：{len(problems)} 个问题")
    return 0 if not problems else 1


def self_test() -> int:
    from PIL import Image

    checks: list[tuple[str, bool]] = []
    checks.append(("真源 SVG 存在", SRC_SVG.is_file()))
    svg_text = build_deer_svg()
    checks.append(("鹿 SVG 只含鹿（无字样）", "Tangram" not in svg_text))
    checks.append(("鹿路径数量 >= 5", svg_text.count("<path") >= 5))
    checks.append(("viewBox 收紧为正方形", f'viewBox="{VIEW_BOX}"' in svg_text))

    with tempfile.TemporaryDirectory() as td:
        p = Path(td) / "deer.png"
        render(svg_text, p, 128)
        with Image.open(p) as im:
            checks.append(("渲染为 RGBA", im.mode == "RGBA"))
            a = im.getchannel("A")
            lo, hi = a.getextrema()
            checks.append(("背景透明", lo == 0))
            checks.append(("鹿主体不透明", hi > 0))
            hist = a.histogram()
            opaque = sum(hist[200:])
            checks.append(("鹿占据合理面积", 0 < opaque < 128 * 128 * 0.6))
        # 幂等：同一输入两次渲染字节一致
        p2 = Path(td) / "deer2.png"
        render(svg_text, p2, 128)
        checks.append(("重复生成字节一致", p.read_bytes() == p2.read_bytes()))

    checks.append(("--check 自检通过", check() == 0))
    for label, ok in checks:
        print(f"  [{'OK ' if ok else 'FAIL'}] {label}")
    return 0 if all(ok for _, ok in checks) else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="从 tangram.svg 派生纯鹿品牌资产")
    ap.add_argument("--check", action="store_true", help="只校验不写入")
    ap.add_argument("--self-test", action="store_true", help="运行自测")
    args = ap.parse_args(argv)
    if args.self_test:
        return self_test()
    if args.check:
        return check()
    return generate()


if __name__ == "__main__":
    raise SystemExit(main())
