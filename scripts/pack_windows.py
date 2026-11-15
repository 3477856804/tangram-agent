#!/usr/bin/env python3
"""把 Windows Release 目录打成「全量便携包」，并给出 SHA256。

为什么需要这个脚本（而不是直接 zip 整个 Release 目录）：
llamadart 的原生资产钩子会把 `frontend/tool/native/llamadart/v0.9.0/
android-arm64/extracted/*.so` 原样拷进 **Windows** 产物目录（本地预置包只有
android-arm64 一套）。这些是 ELF 共享库，Windows 永远加载不了，却让便携包从
约 25MB 膨胀到 150MB+。因此打包时按后缀排除 ELF（*.so），而**不删除**磁盘上
的产物文件（保留原目录可直接调试）。

用法:
    python pack_windows.py <release_dir> <out.zip> [--exclude-suffix .so]

输出：zip 路径、条目数、原始/压缩体积、SHA256。
"""

from __future__ import annotations

import hashlib
import os
import sys
import zipfile
from pathlib import Path

# Windows 上永远无法加载的 POSIX 共享库后缀。
_DEFAULT_EXCLUDED_SUFFIXES = (".so",)


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def pack(
    release_dir: Path,
    out_zip: Path,
    excluded_suffixes: tuple[str, ...] = _DEFAULT_EXCLUDED_SUFFIXES,
) -> dict:
    """把 release_dir 内容（不含自身层级）写入 out_zip。

    - 保持相对路径；空目录不写入（Windows 运行时不需要空目录）。
    - 只排除 **顶层** 的原生库（如 libllama.so）：`data/app.so` 是 Dart AOT
      快照，绝不能排除，否则解压后报 "Unable to start engine without AOT data"。
    - 排除项如实统计在返回值里。
    """
    if not release_dir.is_dir():
        raise SystemExit(f"错误：Release 目录不存在：{release_dir}")
    exe = release_dir / "tangram.exe"
    if not exe.is_file():
        raise SystemExit(f"错误：{release_dir} 下没有 tangram.exe，构建未成功？")

    out_zip.parent.mkdir(parents=True, exist_ok=True)
    included = 0
    excluded = 0
    excluded_bytes = 0
    total_bytes = 0

    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for root, _dirs, files in os.walk(release_dir):
            for name in sorted(files):
                src = Path(root) / name
                rel = src.relative_to(release_dir)
                top_level = len(rel.parts) == 1
                if top_level and name.lower().endswith(excluded_suffixes):
                    excluded += 1
                    excluded_bytes += src.stat().st_size
                    continue
                zf.write(src, rel.as_posix())
                included += 1
                total_bytes += src.stat().st_size
        written = set(zf.namelist())

    # 启动必需文件自检：缺 data/app.so 时引擎会直接拒绝启动（曾因把它当 ELF
    # 库排除而踩过），这里提前硬失败，别让坏包流到用户手里。
    required = ("tangram.exe", "data/app.so", "data/icudtl.dat")
    missing = [n for n in required if n not in written]
    if missing:
        out_zip.unlink(missing_ok=True)
        raise SystemExit(f"错误：便携包缺少启动必需文件 {missing}，已删除坏包")

    size = out_zip.stat().st_size
    return {
        "zip": out_zip,
        "included": included,
        "excluded": excluded,
        "source_bytes": total_bytes,
        "excluded_bytes": excluded_bytes,
        "zip_bytes": size,
        "sha256": _sha256(out_zip),
    }


def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        print(__doc__)
        return 2
    suffixes = _DEFAULT_EXCLUDED_SUFFIXES
    for a in argv[1:]:
        if a.startswith("--exclude-suffix="):
            suffixes = (a.split("=", 1)[1],)

    info = pack(Path(args[0]), Path(args[1]), suffixes)
    mb = 1024 * 1024
    print(f"  [OK ] 便携包: {info['zip']}")
    print(
        f"         条目 {info['included']} 个 / 源 {info['source_bytes'] / mb:.1f} MB"
        f" → 压缩后 {info['zip_bytes'] / mb:.1f} MB"
    )
    if info["excluded"]:
        print(
            f"  [SKIP] 已排除 {info['excluded']} 个 Windows 无法加载的 ELF 库"
            f"（{info['excluded_bytes'] / mb:.1f} MB，未删除原文件）"
        )
    print(f"         SHA256 {info['sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
