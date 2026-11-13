#!/usr/bin/env python3
"""Android 构建镜像注入（幂等，全平台单一代码库）。

背景：frontend/android/ 由 flutter create 生成且不入库；默认 Gradle 发行包来自
services.gradle.org（境内常超时并重定向到 github），Maven 依赖来自
google()/mavenCentral()/gradlePluginPortal()（maven.google.com 境内不可达）。
换机器重建 APK 会因此失败，故把镜像配置在生成运行器后幂等注入。

注入内容（全部幂等，带标记防重复）：
  1. gradle/wrapper/gradle-wrapper.properties
     distributionUrl -> 腾讯云镜像（保留版本号，仅换 host/前缀）
  2. settings.gradle.kts / build.gradle.kts 的 repositories
     在原有仓库之前插入阿里云 google / public / gradle-plugin 镜像

用法：
  python3 scripts/inject_android_mirrors.py <android_dir> [--check]
  python3 scripts/inject_android_mirrors.py --self-test

约定：仅标准库；找不到文件明确报错；重复执行不叠加。
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

MARKER = "tangram:build-mirrors"
MEM_MARKER = "tangram:gradle-memory"

GRADLE_MIRROR = "https://mirrors.cloud.tencent.com/gradle/"
MIRROR_BLOCK = """        // {marker} (generated)
        maven {{ url = uri("https://maven.aliyun.com/repository/google") }}
        maven {{ url = uri("https://maven.aliyun.com/repository/public") }}
        maven {{ url = uri("https://maven.aliyun.com/repository/gradle-plugin") }}
""".format(marker=MARKER)

# 受限内存（如 8GB cgroup）下，Flutter 模板默认 -Xmx8G + MaxMetaspaceSize=4G
# 会让 Gradle/Kotlin daemon 双双被 OOM kill。这里改成总占用 < 4GB 的保守配置，
# 并让 Kotlin 编译走 in-process，避免再起一个 JVM。
MEMORY_LINES = """# {marker} (generated, memory-safe for constrained build hosts)
org.gradle.jvmargs=-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m
org.gradle.parallel=false
org.gradle.workers.max=2
kotlin.compiler.execution.strategy=in-process
""".format(marker=MEM_MARKER)


def inject_wrapper(android_dir: Path) -> tuple[bool, str]:
    p = android_dir / "gradle/wrapper/gradle-wrapper.properties"
    if not p.is_file():
        return False, "未找到 gradle-wrapper.properties"
    text = p.read_text(encoding="utf-8")
    if MARKER in text:
        return True, "Gradle 镜像已注入（跳过）"
    m = re.search(r"distributionUrl=(https?\\?://[^\s]+/)([^/\s]+\.zip)", text)
    if not m:
        return False, "未找到 distributionUrl"
    filename = m.group(2)  # 保留版本号，如 gradle-9.3.1-all.zip
    # gradle-wrapper.properties 里 URL 的冒号需转义为 \:
    escaped = GRADLE_MIRROR.replace("https:", "https\\:")
    new_url = f"distributionUrl={escaped}{filename}"
    text = text[: m.start()] + new_url + text[m.end() :]
    text = text.rstrip("\n") + f"\n# {MARKER}\n"
    p.write_text(text, encoding="utf-8")
    return True, f"Gradle 发行包 -> {GRADLE_MIRROR}{filename}"


def inject_repos(android_dir: Path) -> tuple[bool, str]:
    results = []
    for rel in ("settings.gradle.kts", "build.gradle.kts"):
        p = android_dir / rel
        if not p.is_file():
            results.append((False, f"{rel} 不存在"))
            continue
        text = p.read_text(encoding="utf-8")
        if MARKER in text:
            results.append((True, f"{rel} 镜像已注入（跳过）"))
            continue
        # 在 repositories { 之后插入镜像块；匹配所有 repositories 块
        new_text, n = re.subn(
            r"(repositories\s*\{)",
            r"\1\n" + MIRROR_BLOCK,
            text,
        )
        if n == 0:
            results.append((True, f"{rel} 无 repositories 块（无需注入）"))
            continue
        new_text = new_text.rstrip("\n") + f"\n// {MARKER}\n"
        p.write_text(new_text, encoding="utf-8")
        results.append((True, f"{rel} 注入 {n} 处仓库镜像"))
    ok = all(o for o, _ in results)
    return ok, "; ".join(m for _, m in results)


def inject_memory(android_dir: Path) -> tuple[bool, str]:
    """幂等替换 gradle.properties 里的内存参数为受限环境安全值。"""
    p = android_dir / "gradle.properties"
    if not p.is_file():
        return False, "未找到 gradle.properties"
    text = p.read_text(encoding="utf-8")
    if MEM_MARKER in text:
        return True, "Gradle 内存参数已注入（跳过）"
    # 去掉模板/手写的内存相关行，统一由 MEMORY_LINES 提供，避免重复或 -Xmx8G 冲突
    _managed = (
        "org.gradle.jvmargs=",
        "org.gradle.parallel=",
        "org.gradle.workers.max=",
        "kotlin.compiler.execution.strategy=",
    )
    lines = [
        ln for ln in text.splitlines()
        if not ln.strip().startswith(_managed)
        and not (ln.strip().startswith("#") and "tangram:gradle-memory" in ln)
    ]
    new_text = MEMORY_LINES + "\n".join(lines).rstrip() + "\n"
    p.write_text(new_text, encoding="utf-8")
    return True, "Gradle 内存参数 -> -Xmx3G / in-process Kotlin"


def inject(android_dir: Path, *, check_only: bool = False) -> int:
    wrapper = android_dir / "gradle/wrapper/gradle-wrapper.properties"
    settings = android_dir / "settings.gradle.kts"
    build = android_dir / "build.gradle.kts"
    if not wrapper.is_file():
        print("  [FAIL] 未找到 gradle-wrapper.properties")
        return 1

    props = android_dir / "gradle.properties"

    if check_only:
        wt = wrapper.read_text(encoding="utf-8")
        st = settings.read_text(encoding="utf-8") if settings.is_file() else ""
        bt = build.read_text(encoding="utf-8") if build.is_file() else ""
        pt = props.read_text(encoding="utf-8") if props.is_file() else ""
        ok = (
            MARKER in wt and "mirrors.cloud.tencent.com" in wt
            and MARKER in st and "maven.aliyun.com" in st
            and "maven.aliyun.com" in bt
            and MEM_MARKER in pt and "-Xmx3G" in pt
        )
        print(f"  [{'OK ' if ok else 'FAIL'}] 构建镜像/内存校验：{android_dir}")
        return 0 if ok else 1

    results = [
        inject_wrapper(android_dir),
        inject_repos(android_dir),
        inject_memory(android_dir),
    ]
    for ok, msg in results:
        print(f"  [{'OK ' if ok else 'FAIL'}] {msg}")
    return 0 if all(ok for ok, _ in results) else 1


def _self_test() -> int:
    checks: list[tuple[str, bool]] = []
    with tempfile.TemporaryDirectory() as td:
        android = Path(td) / "android"
        (android / "gradle/wrapper").mkdir(parents=True)
        wrapper = android / "gradle/wrapper/gradle-wrapper.properties"
        wrapper.write_text(
            "distributionBase=GRADLE_USER_HOME\n"
            "distributionPath=wrapper/dists\n"
            "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.3.1-all.zip\n",
            encoding="utf-8",
        )
        (android / "settings.gradle.kts").write_text(
            "pluginManagement {\n    repositories {\n        google()\n        mavenCentral()\n    }\n}\n",
            encoding="utf-8",
        )
        (android / "build.gradle.kts").write_text(
            "allprojects {\n    repositories {\n        google()\n        mavenCentral()\n    }\n}\n",
            encoding="utf-8",
        )
        (android / "gradle.properties").write_text(
            "org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G\n"
            "android.useAndroidX=true\n",
            encoding="utf-8",
        )
        rc1 = inject(android)
        checks.append(("首次注入返回 0", rc1 == 0))
        wt = wrapper.read_text(encoding="utf-8")
        checks.append(("保留 gradle 版本号", "gradle-9.3.1-all.zip" in wt))
        checks.append(("指向腾讯云镜像", "mirrors.cloud.tencent.com" in wt))
        st = (android / "settings.gradle.kts").read_text(encoding="utf-8")
        bt = (android / "build.gradle.kts").read_text(encoding="utf-8")
        checks.append(("settings 含阿里云镜像", "maven.aliyun.com/repository/google" in st))
        checks.append(("build 含阿里云镜像", "maven.aliyun.com/repository/public" in bt))
        pt = (android / "gradle.properties").read_text(encoding="utf-8")
        checks.append(("内存参数降为 -Xmx3G", "-Xmx3G" in pt))
        checks.append(("移除模板 -Xmx8G", "-Xmx8G" not in pt))
        checks.append(("Kotlin 走 in-process", "in-process" in pt))
        rc2 = inject(android)
        checks.append(("二次注入返回 0", rc2 == 0))
        st2 = (android / "settings.gradle.kts").read_text(encoding="utf-8")
        checks.append(("镜像块不重复", st2.count("maven.aliyun.com/repository/google") == 1))
        wt2 = wrapper.read_text(encoding="utf-8")
        checks.append(("distributionUrl 不重复", wt2.count("distributionUrl=") == 1))
        pt2 = (android / "gradle.properties").read_text(encoding="utf-8")
        checks.append(("jvmargs 不重复", pt2.count("org.gradle.jvmargs=") == 1))
        rc3 = inject(android, check_only=True)
        checks.append(("--check 校验通过", rc3 == 0))

    for label, ok in checks:
        print(f"  [{'OK ' if ok else 'FAIL'}] {label}")
    return 0 if all(ok for _, ok in checks) else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Android 构建镜像注入（幂等）")
    p.add_argument("android_dir", nargs="?", help="frontend/android 目录")
    p.add_argument("--check", action="store_true")
    p.add_argument("--self-test", action="store_true")
    args = p.parse_args(argv)
    if args.self_test:
        return _self_test()
    if not args.android_dir:
        print("错误：需要提供 android_dir，或用 --self-test", file=sys.stderr)
        return 2
    return inject(Path(args.android_dir), check_only=args.check)


if __name__ == "__main__":
    raise SystemExit(main())
