#!/usr/bin/env python3
"""Android compileSdk 统一注入（幂等，全平台单一代码库）。

背景：frontend/android/ 由 flutter create 生成且不入库。当前 Flutter SDK 的
FlutterExtension.compileSdkVersion = 36，flutter_plugin_android_lifecycle 等插件
按 36 编译，其 AAR metadata 声明 minCompileSdk=36；但 file_picker / share_plus /
flutter_secure_storage / sign_in_with_apple 等老插件在自身 build.gradle 里把
compileSdk 写死成 34，于是 :<plugin>:checkDebugAarMetadata 报：

    Dependency ':flutter_plugin_android_lifecycle' requires ... version 36 or later
    :file_picker is currently compiled against android-34.
    Recommended action: Update this project to use a newer compileSdk of at least 36.

app 模块本身用 flutter.compileSdkVersion（=36）没有问题，冲突发生在插件子模块，
因此必须在根 build.gradle.kts 对 subprojects 强制覆盖。

注入内容（全部幂等，带标记防重复）：
  1. app/build.gradle.kts
     compileSdk = flutter.compileSdkVersion -> compileSdk = 36
     targetSdk  = flutter.targetSdkVersion  -> targetSdk  = 36
     显式固定，不随 Flutter SDK 默认版本漂移。
  2. build.gradle.kts（根）
     在文件开头前置 gradle.beforeProject { proj.afterEvaluate { ... } } 块，
     用反射把每个 Android 子模块（插件）的 compileSdk 提升为 36。必须在评估前
     注册：模板根构建里的 evaluationDependsOn(":app") 会提前评估部分项目，
     直接 subprojects.afterEvaluate 会报 already evaluated。反射同时兼容旧
     BaseExtension（compileSdkVersion(int)）与新 CommonExtension
     （setCompileSdk(Integer)），因为插件 build.gradle 有 Groovy / Kotlin DSL 两种。

用法：
  python3 scripts/inject_android_compile_sdk.py <android_dir> [--check]
  python3 scripts/inject_android_compile_sdk.py --self-test

约定：仅标准库；找不到文件明确报错；重复执行不叠加。
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

APP_MARKER = "tangram:compile-sdk-app"
ROOT_MARKER = "tangram:compile-sdk-plugins"
COMPILE_SDK = 36

# 根 build.gradle.kts 前置块。{} 用 str.format 转义为字面花括号。
# 关键：Flutter 模板根构建里有 subprojects { project.evaluationDependsOn(":app") }，
# 它会提前评估部分子项目；若把 afterEvaluate 追加在文件末尾，会报
# "Cannot run Project.afterEvaluate(Action) when the project is already evaluated"。
# 因此用 Gradle 级 beforeProject 钩子，在每个项目评估之前注册 afterEvaluate，
# 并把整块置于文件最开头，保证监听器先于 evaluationDependsOn 生效。
PLUGIN_BLOCK = """// {marker} (generated)
// 统一所有 Flutter 插件子模块的 compileSdk：部分老插件把 compileSdk 写死为 34，
// 与 flutter_plugin_android_lifecycle(36) 的 AAR metadata 要求冲突。
// 反射同时覆盖旧 DSL (BaseExtension) 与新 DSL (CommonExtension)。
gradle.beforeProject(org.gradle.api.Action<org.gradle.api.Project> {{
    afterEvaluate(org.gradle.api.Action<org.gradle.api.Project> {{
        val androidExt = extensions.findByName("android")
        if (androidExt != null) {{
            val cls = androidExt.javaClass
            for (sig in listOf(
                "setCompileSdk|int",
                "setCompileSdk|java.lang.Integer",
                "compileSdkVersion|int",
                "compileSdkVersion|java.lang.Integer",
                "setCompileSdkVersion|int"
            )) {{
                val parts = sig.split("|")
                val param: Class<*> =
                    if (parts[1] == "int") java.lang.Integer.TYPE
                    else java.lang.Integer::class.java
                try {{
                    cls.getMethod(parts[0], param).invoke(androidExt, {sdk})
                }} catch (_: Throwable) {{
                }}
            }}
        }}
    }})
}})
""".format(marker=ROOT_MARKER, sdk=COMPILE_SDK)


def inject_app(android_dir: Path) -> tuple[bool, str]:
    """把 app 模块 compileSdk/targetSdk 显式固定为 36。"""
    p = android_dir / "app/build.gradle.kts"
    if not p.is_file():
        return False, "未找到 app/build.gradle.kts"
    text = p.read_text(encoding="utf-8")
    if APP_MARKER in text:
        return True, "app compileSdk/targetSdk 已固定（跳过）"
    new, n1 = re.subn(
        r"compileSdk\s*=\s*flutter\.compileSdkVersion",
        f"compileSdk = {COMPILE_SDK} // {APP_MARKER}",
        text,
    )
    if n1 == 0:
        return False, "未找到 compileSdk = flutter.compileSdkVersion（模板可能已变更）"
    new, n2 = re.subn(
        r"targetSdk\s*=\s*flutter\.targetSdkVersion",
        f"targetSdk = {COMPILE_SDK} // {APP_MARKER}",
        new,
    )
    p.write_text(new, encoding="utf-8")
    return True, f"app compileSdk/targetSdk -> {COMPILE_SDK}（替换 {n1}+{n2} 处）"


def inject_root(android_dir: Path) -> tuple[bool, str]:
    """在根 build.gradle.kts 开头注入 beforeProject compileSdk 覆盖块。

    自愈：早期版本把块追加在文件末尾且用 subprojects.afterEvaluate（会因
    evaluationDependsOn 报 already evaluated）。检测到旧写法时先移除再重注入。
    """
    p = android_dir / "build.gradle.kts"
    if not p.is_file():
        return False, "未找到根 build.gradle.kts"
    text = p.read_text(encoding="utf-8")
    marker_line = "// " + ROOT_MARKER
    if marker_line in text:
        idx = text.find(marker_line)
        tail = text[idx:]
        if ("gradle.beforeProject" in tail and "org.gradle.api.Action" in tail
                and "val androidExt = extensions.findByName" in tail):
            return True, "插件 compileSdk 覆盖已注入（跳过）"
        # 旧版块（追加在末尾）：从标记行起全部删除
        text = text[:idx].rstrip("\n") + "\n"
    new = PLUGIN_BLOCK + "\n" + text.lstrip("\n")
    p.write_text(new, encoding="utf-8")
    return True, f"根构建注入 beforeProject compileSdk={COMPILE_SDK} 覆盖"


def inject(android_dir: Path, *, check_only: bool = False) -> int:
    app = android_dir / "app/build.gradle.kts"
    root = android_dir / "build.gradle.kts"
    if not app.is_file() or not root.is_file():
        print("  [FAIL] 未找到 app/build.gradle.kts 或 build.gradle.kts")
        return 1

    if check_only:
        at = app.read_text(encoding="utf-8")
        rt = root.read_text(encoding="utf-8")
        ok = (
            APP_MARKER in at
            and re.search(rf"compileSdk\s*=\s*{COMPILE_SDK}\b", at) is not None
            and re.search(rf"targetSdk\s*=\s*{COMPILE_SDK}\b", at) is not None
            and "flutter.compileSdkVersion" not in at
            and ROOT_MARKER in rt
            and "gradle.beforeProject" in rt
            and "org.gradle.api.Action" in rt
            and "afterEvaluate" in rt
            and "val androidExt = extensions.findByName" in rt
            and f"invoke(androidExt, {COMPILE_SDK})" in rt
        )
        print(f"  [{'OK ' if ok else 'FAIL'}] compileSdk 统一校验：{android_dir}")
        return 0 if ok else 1

    results = [inject_app(android_dir), inject_root(android_dir)]
    for ok, msg in results:
        print(f"  [{'OK ' if ok else 'FAIL'}] {msg}")
    return 0 if all(ok for ok, _ in results) else 1


def _self_test() -> int:
    checks: list[tuple[str, bool]] = []
    with tempfile.TemporaryDirectory() as td:
        android = Path(td) / "android"
        (android / "app").mkdir(parents=True)
        app = android / "app/build.gradle.kts"
        app.write_text(
            "android {\n"
            "    namespace = \"com.tangram.agent.tangram\"\n"
            "    compileSdk = flutter.compileSdkVersion\n"
            "    ndkVersion = flutter.ndkVersion\n"
            "    defaultConfig {\n"
            "        minSdk = flutter.minSdkVersion\n"
            "        targetSdk = flutter.targetSdkVersion\n"
            "    }\n"
            "}\n",
            encoding="utf-8",
        )
        root = android / "build.gradle.kts"
        root.write_text(
            "allprojects {\n    repositories { mavenCentral() }\n}\n",
            encoding="utf-8",
        )

        rc1 = inject(android)
        checks.append(("首次注入返回 0", rc1 == 0))
        at = app.read_text(encoding="utf-8")
        checks.append(("app compileSdk 固定为 36", f"compileSdk = {COMPILE_SDK}" in at))
        checks.append(("app targetSdk 固定为 36", f"targetSdk = {COMPILE_SDK}" in at))
        checks.append(("移除 flutter.compileSdkVersion", "flutter.compileSdkVersion" not in at))
        checks.append(("保留 minSdk 跟随 Flutter", "flutter.minSdkVersion" in at))
        rt = root.read_text(encoding="utf-8")
        checks.append(("根构建含 gradle.beforeProject", "gradle.beforeProject" in rt))
        checks.append(("根构建用显式 Action 避免 Closure 歧义", "org.gradle.api.Action" in rt))
        checks.append(("根构建含 afterEvaluate", "afterEvaluate" in rt))
        checks.append(("根构建用 receiver 形式 lambda",
                       "val androidExt = extensions.findByName" in rt))
        checks.append(("根构建含反射 setCompileSdk", "setCompileSdk|int" in rt))
        checks.append(("根构建含反射 compileSdkVersion", "compileSdkVersion|int" in rt))
        checks.append(("根构建写入 36", f"invoke(androidExt, {COMPILE_SDK})" in rt))

        rc2 = inject(android)
        checks.append(("二次注入返回 0", rc2 == 0))
        at2 = app.read_text(encoding="utf-8")
        rt2 = root.read_text(encoding="utf-8")
        checks.append(("app 标记不重复", at2.count(APP_MARKER) == 2))  # compileSdk + targetSdk 各一处
        checks.append(("根构建块不重复", rt2.count(ROOT_MARKER) == 1))
        checks.append(("原有 allprojects 保留", "allprojects" in rt2))

        rc3 = inject(android, check_only=True)
        checks.append(("--check 校验通过", rc3 == 0))

    for label, ok in checks:
        print(f"  [{'OK ' if ok else 'FAIL'}] {label}")
    return 0 if all(ok for _, ok in checks) else 1


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Android compileSdk 统一注入（幂等）")
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
