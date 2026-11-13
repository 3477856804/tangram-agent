#!/usr/bin/env python3
"""Android 品牌注入：应用显示名 + 纯鹿启动图标（幂等，全平台单一代码库）。

背景：frontend/android/ 由 flutter create 生成且不入库（.gitignore 忽略），
因此品牌资产必须在每次生成 android 运行器后由本脚本注入，保证任意机器
重建的 APK 桌面显示名都是 TGA、都用同一品牌 logo 作启动图标。

产品名是 tangram-agent；桌面 / 启动器显示名用其简称 TGA（三字符，避免
Android 启动器把长名字截断），App 内标题与侧边栏名同样为 TGA。产品名
本身不变，仍是 tangram-agent。

品牌图形是用户提供的 logo/tangram.svg 里的**七巧板鹿**，不是方块。
scripts/gen_brand_assets.py 从真源裁出纯鹿并渲染为透明 PNG；启动图标 =
透明背景 + 纯鹿（无白底方块、无 "Tangram" 字样、无四块占位方片）。

注入内容：
  1. app/src/main/AndroidManifest.xml：android:label 统一为 "TGA"
  2. app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
     —— 从 frontend/assets/logo/tangram_deer.png（纯鹿，真源派生）按密度缩放，
        透明背景、四周留白，图标里只有鹿。
  3. 删除 mipmap-anydpi-v26/ic_launcher.xml：Flutter 模板的自适应图标引用
     默认 Flutter 前景（方块），会盖掉纯鹿 PNG；删掉后系统回退到上面的 PNG。
  4. 记录标记 tangram:branding，重复执行不覆盖、不重复。

用法：
  python3 scripts/inject_android_branding.py <android_dir> [--check]
  python3 scripts/inject_android_branding.py --self-test

约定：源 PNG 缺失时明确报错而非静默放行；仅依赖 Pillow（构建机已装）。
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

MARKER = "tangram:branding"
# 桌面 / 启动器显示名：产品 tangram-agent 的简称，短到启动器不会截断。
APP_LABEL = "TGA"

# Android 启动图标各密度像素尺寸
DENSITIES: dict[str, int] = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

# 纯鹿在图标画布里的四周留白比例：避免启动器裁掉鹿角与鹿腿。
INSET_RATIO = 0.10


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _source_png() -> Path:
    return _repo_root() / "frontend" / "assets" / "logo" / "tangram_deer.png"


def _find_manifest(android_dir: Path) -> Path | None:
    found = list(android_dir.rglob("app/src/main/AndroidManifest.xml"))
    return found[0] if found else None


def inject_label(manifest: Path) -> tuple[bool, str]:
    """把 <application android:label="..."> 统一为 TGA（幂等）。"""
    text = manifest.read_text(encoding="utf-8")
    m = re.search(r"<application\b([^>]*)>", text)
    if not m:
        return False, "未找到 <application> 标签"
    attrs = m.group(1)
    if re.search(r'android:label="[^"]*"', attrs):
        new_attrs = re.sub(
            r'android:label="[^"]*"', f'android:label="{APP_LABEL}"', attrs
        )
    else:
        new_attrs = attrs + f' android:label="{APP_LABEL}"'
    new_open = f"<application{new_attrs}>"

    # 先按「是否已打标记」决定是否插注释，再一次性重建整段，避免索引偏移
    if MARKER not in text:
        marker_line = f"    <!-- {MARKER} -->\n"
        new_text = text[: m.start()] + marker_line + new_open + text[m.end() :]
    else:
        new_text = text[: m.start()] + new_open + text[m.end() :]
    manifest.write_text(new_text, encoding="utf-8")
    return True, f"应用名已设为 {APP_LABEL}"


def _adaptive_icon_xml(res: Path) -> Path:
    return res / "mipmap-anydpi-v26" / "ic_launcher.xml"


def inject_icons(android_dir: Path, src_png: Path) -> tuple[bool, str]:
    """按密度生成「透明背景 + 纯鹿」ic_launcher.png（真实 PNG 缩放，无白底）。"""
    try:
        from PIL import Image
    except ImportError:
        return False, "缺少 Pillow，无法生成启动图标（pip install Pillow）"
    if not src_png.is_file():
        return False, f"品牌源 PNG 不存在：{src_png}"

    res = android_dir / "app" / "src" / "main" / "res"
    if not res.is_dir():
        return False, f"未找到 res 目录：{res}"

    with Image.open(src_png) as im:
        deer = im.convert("RGBA")
        written = 0
        for folder, size in DENSITIES.items():
            target_dir = res / folder
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / "ic_launcher.png"
            # 只有鹿：透明画布 + 居中缩放的鹿，不合成任何底色方块。
            canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            inset = int(size * INSET_RATIO)
            inner = size - 2 * inset
            scaled = deer.resize((inner, inner), Image.LANCZOS)
            canvas.alpha_composite(scaled, (inset, inset))
            canvas.save(target, "PNG")
            written += 1

    # Flutter 模板在 Android 8+ 可能带自适应图标 XML，它引用默认 Flutter 前景
    # （方块），会盖掉纯鹿 PNG；删掉后系统回退到上面生成的纯鹿 PNG。
    adaptive = _adaptive_icon_xml(res)
    if adaptive.is_file():
        adaptive.unlink()
    return True, f"生成 {written} 个密度纯鹿透明图标（无白底方块）"


def _icons_are_pure_deer(android_dir: Path) -> bool:
    """校验每个密度图标都是 RGBA、含透明背景、且鹿主体不透明。"""
    try:
        from PIL import Image
    except ImportError:
        return False
    res = android_dir / "app" / "src" / "main" / "res"
    for folder, size in DENSITIES.items():
        p = res / folder / "ic_launcher.png"
        if not p.is_file():
            return False
        with Image.open(p) as im:
            if im.mode != "RGBA" or im.size != (size, size):
                return False
            lo, hi = im.getchannel("A").getextrema()
            if lo != 0 or hi == 0:  # 必须透明背景 + 有实心鹿
                return False
    return True


def inject(android_dir: Path, *, check_only: bool = False) -> int:
    manifest = _find_manifest(android_dir)
    if manifest is None:
        print("  [FAIL] 未找到 app/src/main/AndroidManifest.xml")
        return 1
    src = _source_png()

    if check_only:
        text = manifest.read_text(encoding="utf-8")
        res = android_dir / "app" / "src" / "main" / "res"
        ok = (
            MARKER in text
            and f'android:label="{APP_LABEL}"' in text
            and src.is_file()
            and _icons_are_pure_deer(android_dir)
            and not _adaptive_icon_xml(res).is_file()
        )
        print(f"  [{'OK ' if ok else 'FAIL'}] 品牌注入校验：{android_dir}")
        return 0 if ok else 1

    results = [inject_label(manifest), inject_icons(android_dir, src)]
    for ok, msg in results:
        print(f"  [{'OK ' if ok else 'FAIL'}] {msg}")
    return 0 if all(ok for ok, _ in results) else 1


def _self_test() -> int:
    """用临时 flutter create 产物模拟，验证图标为透明纯鹿 / 应用名 / 幂等。"""
    checks: list[tuple[str, bool]] = []
    src = _source_png()
    checks.append(("品牌源 PNG 存在", src.is_file()))
    if not src.is_file():
        for label, ok in checks:
            print(f"  [{'OK ' if ok else 'FAIL'}] {label}")
        return 1

    with tempfile.TemporaryDirectory() as td:
        android = Path(td) / "android"
        app_main = android / "app/src/main"
        res = app_main / "res"
        for folder in DENSITIES:
            (res / folder).mkdir(parents=True, exist_ok=True)
        # 模拟 Flutter 默认自适应图标（方块前景），验证会被删除
        adaptive = _adaptive_icon_xml(res)
        adaptive.parent.mkdir(parents=True, exist_ok=True)
        adaptive.write_text("<adaptive-icon/>", encoding="utf-8")
        manifest = app_main / "AndroidManifest.xml"
        manifest.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
            '    <application android:label="tangram" android:name="${applicationName}">\n'
            '        <activity android:name=".MainActivity" />\n'
            '    </application>\n'
            '</manifest>\n',
            encoding="utf-8",
        )
        rc1 = inject(android)
        checks.append(("首次注入返回 0", rc1 == 0))
        text = manifest.read_text(encoding="utf-8")
        checks.append(("应用名改为 TGA", f'android:label="{APP_LABEL}"' in text))
        checks.append(("品牌标记写入", MARKER in text))
        from PIL import Image
        for folder, size in DENSITIES.items():
            p = res / folder / "ic_launcher.png"
            checks.append((f"{folder} 图标生成", p.is_file()))
            if p.is_file():
                with Image.open(p) as im:
                    checks.append((f"{folder} 尺寸 {size}", im.size == (size, size)))
                    checks.append((f"{folder} 为 RGBA 纯鹿", im.mode == "RGBA"))
                    lo, hi = im.getchannel("A").getextrema()
                    checks.append((f"{folder} 透明底且鹿可见", lo == 0 and hi == 255))
        checks.append(("自适应方块图标已删除", not adaptive.is_file()))
        # 二次注入：应用名不重复、仍幂等
        rc2 = inject(android)
        text2 = manifest.read_text(encoding="utf-8")
        checks.append(("二次注入返回 0", rc2 == 0))
        checks.append(("应用名不重复", text2.count(f'android:label="{APP_LABEL}"') == 1))
        checks.append(("标记不重复", text2.count(MARKER) == 1))
        checks.append(("二次注入后仍是透明纯鹿", _icons_are_pure_deer(android)))
        rc3 = inject(android, check_only=True)
        checks.append(("--check 校验通过", rc3 == 0))

    for label, ok in checks:
        print(f"  [{'OK ' if ok else 'FAIL'}] {label}")
    return 0 if all(ok for _, ok in checks) else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Android 品牌注入（TGA 显示名 + 纯鹿启动图标）")
    p.add_argument("android_dir", nargs="?", help="frontend/android 目录")
    p.add_argument("--check", action="store_true", help="只校验不写入")
    p.add_argument("--self-test", action="store_true", help="运行自测")
    args = p.parse_args(argv)
    if args.self_test:
        return _self_test()
    if not args.android_dir:
        print("错误：需要提供 android_dir，或用 --self-test", file=sys.stderr)
        return 2
    return inject(Path(args.android_dir), check_only=args.check)


if __name__ == "__main__":
    raise SystemExit(main())
