#!/usr/bin/env python3
"""Android 平台运行器：幂等注入「所有文件访问」权限与原生授权通道。

背景（为什么是脚本而不是直接改 android/ 目录）：
  frontend/android/ 被 .gitignore 忽略，由 scripts/build_frontend.sh 的
  `flutter create --platforms=android` 现场生成，不入库。因此权限声明与原生
  MethodChannel 实现必须在每次生成后由本脚本注入，保证换台机器 clone 下来
  重建的 APK 一样带「所有文件访问」能力；对非 android 平台完全不执行。

注入内容（全部幂等，用标记注释 + 存在性检测防重复）：
  1. app/src/main/AndroidManifest.xml
     - READ_EXTERNAL_STORAGE (maxSdkVersion=32)
     - WRITE_EXTERNAL_STORAGE (maxSdkVersion=32)
     - MANAGE_EXTERNAL_STORAGE (Android 11+ 所有文件访问)
     - <application android:requestLegacyExternalStorage="true"> (Android 10 兼容)
  2. app/src/main/kotlin/<pkg>/DeviceFileAccessPlugin.kt
     - MethodChannel "tangram/device_files"：checkAccess / requestAccess / storageRoots
     - checkAccess: Environment.isExternalStorageManager() (R+) 或 legacy 权限判定
     - requestAccess: 拉起 ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION 设置页
     - storageRoots: 真实共享存储根 + Download/DCIM/Documents
  3. MainActivity.kt：注入 configureFlutterEngine 注册插件（幂等）

用法：
  python3 scripts/inject_android_permissions.py <android_dir> [--check]
  python3 scripts/inject_android_permissions.py --self-test

约定：仅标准库；不写死密钥；找不到文件时给出明确错误而非静默放行。
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

MARKER = "tangram:device_file_access"
CHANNEL = "tangram/device_files"

PERMISSIONS: list[tuple[str, str | None]] = [
    ("android.permission.READ_EXTERNAL_STORAGE", "32"),
    ("android.permission.WRITE_EXTERNAL_STORAGE", "32"),
    ("android.permission.MANAGE_EXTERNAL_STORAGE", None),
]

PLUGIN_TEMPLATE = """// {marker} (generated, do not edit by hand)
package {pkg}

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 设备文件访问授权通道：与 Dart 侧 device_file_platform.dart 约定一致。 */
class DeviceFileAccessPlugin(private val activity: Activity) {{
    companion object {{
        const val CHANNEL = "{channel}"
    }}

    fun register(flutterEngine: FlutterEngine) {{
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler {{ call, result ->
                when (call.method) {{
                    "checkAccess" -> result.success(hasAllFilesAccess())
                    "requestAccess" -> {{ openAllFilesSettings(); result.success(hasAllFilesAccess()) }}
                    "storageRoots" -> result.success(storageRoots())
                    else -> result.notImplemented()
                }}
            }}
    }}

    /** Android 11+ 判定「所有文件访问」；旧版本回落到 READ/WRITE 权限。 */
    private fun hasAllFilesAccess(): Boolean {{
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {{
            Environment.isExternalStorageManager()
        }} else {{
            ContextCompat.checkSelfPermission(activity,
                android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }}
    }}

    /** 引导用户到系统「所有文件访问」设置页；返回 App 后由 Dart 侧重新 check。 */
    private fun openAllFilesSettings() {{
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {{
            try {{
                val intent = Intent(
                    android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:" + activity.packageName))
                activity.startActivity(intent)
            }} catch (_: Exception) {{
                val fallback = Intent(
                    android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                activity.startActivity(fallback)
            }}
        }}
    }}

    /** 真实共享存储根目录，授权后供 Dart 侧作为可访问根。 */
    private fun storageRoots(): List<Map<String, Any>> {{
        val base = Environment.getExternalStorageDirectory().absolutePath
        return listOf(
            mapOf("path" to base, "label" to "设备共享存储", "writable" to true),
            mapOf("path" to "$base/Download", "label" to "下载", "writable" to true),
            mapOf("path" to "$base/DCIM", "label" to "相册", "writable" to true),
            mapOf("path" to "$base/Documents", "label" to "文档", "writable" to true),
            mapOf("path" to activity.filesDir.absolutePath,
                  "label" to "App 私有目录", "writable" to true)
        )
    }}
}}
"""

REGISTER_SNIPPET_TEMPLATE = """    // {marker} (generated)
    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        DeviceFileAccessPlugin(this).register(flutterEngine)
    }}
"""


def _find_manifest(android_dir: Path) -> Path | None:
    candidates = list(android_dir.rglob("app/src/main/AndroidManifest.xml"))
    return candidates[0] if candidates else None


def _find_main_activity(android_dir: Path) -> Path | None:
    for pattern in ("MainActivity.kt", "MainActivity.java"):
        found = [p for p in android_dir.rglob(pattern) if "generated" not in str(p)]
        if found:
            return found[0]
    return None


def _package_of(main_activity: Path) -> str | None:
    text = main_activity.read_text(encoding="utf-8")
    m = re.search(r"^package\s+([\w.]+)", text, re.MULTILINE)
    return m.group(1) if m else None


def inject_manifest(manifest: Path) -> tuple[bool, str]:
    text = manifest.read_text(encoding="utf-8")
    if MARKER in text:
        return True, "manifest 已注入（跳过）"

    add_lines: list[str] = []
    for name, max_sdk in PERMISSIONS:
        if f'android:name="{name}"' in text:
            continue
        if max_sdk:
            add_lines.append(
                f'    <uses-permission android:name="{name}" '
                f'android:maxSdkVersion="{max_sdk}" />'
            )
        else:
            add_lines.append(f'    <uses-permission android:name="{name}" />')
    if add_lines:
        block = f"    <!-- {MARKER} -->\n" + "\n".join(add_lines) + "\n"
        # 插到 <manifest ...> 开标签之后（第一个 > 之后）
        m = re.search(r"(<manifest\b[^>]*>)", text)
        if not m:
            return False, "未找到 <manifest> 开标签"
        text = text[: m.end()] + "\n" + block + text[m.end() :]

    # application 的 requestLegacyExternalStorage（Android 10 兼容）
    if "requestLegacyExternalStorage" not in text:
        m = re.search(r"<application\b([^>]*)>", text)
        if m and "requestLegacyExternalStorage" not in m.group(1):
            attrs = m.group(1)
            new_open = f'<application{attrs} android:requestLegacyExternalStorage="true">'
            text = text[: m.start()] + new_open + text[m.end() :]

    if MARKER not in text and not any(
        f'android:name="{n}"' in text for n, _ in PERMISSIONS
    ):
        return False, "权限注入未生效"
    manifest.write_text(text, encoding="utf-8")
    return True, "manifest 权限已注入"


def _plugin_dir_for(main_activity: Path, pkg: str) -> Path:
    # MainActivity.kt 位于 .../kotlin/<pkg/path>/MainActivity.kt
    return main_activity.parent


def inject_plugin(main_activity: Path, pkg: str) -> tuple[bool, str]:
    target = _plugin_dir_for(main_activity, pkg) / "DeviceFileAccessPlugin.kt"
    if target.exists() and MARKER in target.read_text(encoding="utf-8"):
        return True, "Kotlin 插件已存在（跳过）"
    content = PLUGIN_TEMPLATE.format(marker=MARKER, pkg=pkg, channel=CHANNEL)
    target.write_text(content, encoding="utf-8")
    return True, f"Kotlin 插件已写入 {target.name}"


def inject_main_activity(main_activity: Path) -> tuple[bool, str]:
    if main_activity.suffix != ".kt":
        return False, "MainActivity 非 Kotlin（.java），需手工注册 DeviceFileAccessPlugin"
    text = main_activity.read_text(encoding="utf-8")
    if MARKER in text:
        return True, "MainActivity 已注册（跳过）"
    snippet = REGISTER_SNIPPET_TEMPLATE.format(marker=MARKER)

    # 情形 C：MainActivity 已有 configureFlutterEngine override（如 OTA 安装桥）
    # —— 不能再加第二个 override（Kotlin 报 Conflicting overloads），
    # 改为把插件注册调用插进现有 override 的 super 调用之后。
    m3 = re.search(
        r"(super\.configureFlutterEngine\s*\(\s*flutterEngine\s*\)\s*\n)", text
    )
    if m3:
        ins = (
            f"        // {MARKER} (generated)\n"
            "        DeviceFileAccessPlugin(this).register(flutterEngine)\n"
        )
        text = text[: m3.end()] + ins + text[m3.end():]
        main_activity.write_text(text, encoding="utf-8")
        return True, "MainActivity 已在现有 override 中注册插件"

    # 情形 A：已有类体 {...} —— 在开括号后插入 override
    m = re.search(r"(class\s+MainActivity[^{]*\{)", text)
    if m:
        text = text[: m.end()] + "\n" + snippet + text[m.end() :]
        main_activity.write_text(text, encoding="utf-8")
        return True, "MainActivity 已注册插件（已有类体）"

    # 情形 B：flutter create 默认模板，无类体：class MainActivity: FlutterActivity()
    # 需要把它改写成带 { ... } 的形式再放入 override。
    m2 = re.search(r"(class\s+MainActivity\s*:\s*FlutterActivity\s*\(\s*\))", text)
    if m2:
        head = m2.group(1)
        text = (
            text[: m2.start()]
            + head
            + " {\n"
            + snippet
            + "}\n"
            + text[m2.end() :]
        )
        main_activity.write_text(text, encoding="utf-8")
        return True, "MainActivity 已注册插件（补齐类体）"

    return False, "未找到 MainActivity 类声明（模板可能变化，需人工确认）"


def inject(android_dir: Path, *, check_only: bool = False) -> int:
    manifest = _find_manifest(android_dir)
    main_activity = _find_main_activity(android_dir)
    problems: list[str] = []
    if manifest is None:
        problems.append("未找到 app/src/main/AndroidManifest.xml")
    if main_activity is None:
        problems.append("未找到 MainActivity.kt/.java")
    if problems:
        for p in problems:
            print(f"  [FAIL] {p}")
        return 1

    pkg = _package_of(main_activity)
    if not pkg:
        print("  [FAIL] 无法从 MainActivity 解析 package")
        return 1

    if check_only:
        text = manifest.read_text(encoding="utf-8")
        plugin = main_activity.parent / "DeviceFileAccessPlugin.kt"
        ok = (
            MARKER in text
            and all(f'android:name="{n}"' in text for n, _ in PERMISSIONS)
            and plugin.exists()
            and MARKER in main_activity.read_text(encoding="utf-8")
        )
        print("  [{}] 注入校验：{}".format("OK " if ok else "FAIL", android_dir))
        return 0 if ok else 1

    results = [
        inject_manifest(manifest),
        inject_plugin(main_activity, pkg),
        inject_main_activity(main_activity),
    ]
    for ok, msg in results:
        print(f"  [{'OK ' if ok else 'WARN'}] {msg}")
    return 0 if all(ok for ok, _ in results) else 1


def _self_test() -> int:
    """用临时目录模拟 flutter create 产物，验证注入内容与幂等性（不依赖 Android SDK）。"""
    checks: list[tuple[str, bool]] = []
    with tempfile.TemporaryDirectory() as td:
        android = Path(td) / "android"
        pkg = "com.example.tangram"
        src = android / "app/src/main"
        kotlin = src / "kotlin" / Path(pkg.replace(".", "/"))
        kotlin.mkdir(parents=True)
        manifest = src / "AndroidManifest.xml"
        manifest.write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.example.tangram">\n'
            '    <application android:label="tangram" android:name="${applicationName}">\n'
            '        <activity android:name=".MainActivity" />\n'
            '    </application>\n'
            '</manifest>\n',
            encoding="utf-8",
        )
        main_activity = kotlin / "MainActivity.kt"
        main_activity.write_text(
            f"package {pkg}\n\n"
            "import io.flutter.embedding.android.FlutterActivity\n\n"
            "class MainActivity: FlutterActivity()\n",
            encoding="utf-8",
        )

        rc1 = inject(android)
        text = manifest.read_text(encoding="utf-8")
        checks.append(("首次注入返回 0", rc1 == 0))
        checks.append(("含 MANAGE_EXTERNAL_STORAGE",
                       'android:name="android.permission.MANAGE_EXTERNAL_STORAGE"' in text))
        checks.append(("含 READ/WRITE maxSdk",
                       'android:maxSdkVersion="32"' in text))
        checks.append(("含 requestLegacyExternalStorage",
                       'requestLegacyExternalStorage="true"' in text))
        plugin = kotlin / "DeviceFileAccessPlugin.kt"
        checks.append(("Kotlin 插件生成", plugin.exists()))
        if plugin.exists():
            pt = plugin.read_text(encoding="utf-8")
            checks.append(("插件含 channel 约定", CHANNEL in pt))
            checks.append(("插件含 isExternalStorageManager",
                           "isExternalStorageManager" in pt))
        checks.append(("MainActivity 含注册",
                       "configureFlutterEngine" in main_activity.read_text(encoding="utf-8")))
        checks.append(("--check 通过", inject(android, check_only=True) == 0))

        # 幂等：再跑一次，内容不得重复
        mt1 = main_activity.read_text(encoding="utf-8")
        count_before = mt1.count("configureFlutterEngine")
        rc2 = inject(android)
        text2 = manifest.read_text(encoding="utf-8")
        mt2 = main_activity.read_text(encoding="utf-8")
        checks.append(("二次注入返回 0", rc2 == 0))
        checks.append(("权限不重复",
                       text2.count("MANAGE_EXTERNAL_STORAGE") == 1))
        checks.append(("注册不重复（二次注入计数不变）",
                       mt2.count("configureFlutterEngine") == count_before))

    passed = sum(1 for _, v in checks if v)
    for name, v in checks:
        print(f"  [{'OK ' if v else 'FAIL'}] {name}")
    print(f"InjectAndroidPermissions self-test: {passed}/{len(checks)} passed")
    return 0 if passed == len(checks) else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="幂等注入 Android 所有文件访问能力")
    ap.add_argument("android_dir", nargs="?", help="frontend/android 目录")
    ap.add_argument("--check", action="store_true", help="仅校验是否已注入")
    ap.add_argument("--self-test", action="store_true", help="临时目录自测注入与幂等")
    args = ap.parse_args(argv)
    if args.self_test:
        return _self_test()
    if not args.android_dir:
        ap.error("需要 android_dir 或 --self-test")
    android = Path(args.android_dir)
    if not android.is_dir():
        print(f"  [FAIL] 目录不存在：{android}")
        return 1
    return inject(android, check_only=args.check)


if __name__ == "__main__":
    sys.exit(main())
