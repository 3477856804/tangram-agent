package com.tangram.agent.tangram

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 纯 Dart 应用入口：全部能力随 APK 内置、开箱即用。
 *
 * - 沙箱：Dart 侧 SandboxedShell，按 cube_schema.json 契约在受限 Isolate 执行；
 * - 后端控制域（chat / rpc / model_route 等）：进程内 EmbeddedBackend 真实执行。
 *
 * 唯一的原生桥：MethodChannel("tangram/update")，用于真实 OTA 覆盖安装——
 * Dart 把新 APK 下载到应用私有目录后，这里用 FileProvider 生成 content:// URI
 * 调起系统安装器（不卸载、保留数据；要求新旧 APK 同签名）。
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "tangram/update"
        private const val MIME_APK = "application/vnd.android.package-archive"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> installApk(call, result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * installApk 契约（Dart → 原生）：
     *   参数 { filePath: String, fileType: String? }
     *   返回 { ok: Boolean, pendingPermission: Boolean?, error: String? }
     * - ok=true：系统安装器已调起（用户确认后覆盖安装）；
     * - pendingPermission=true：未授予「安装未知应用」权限，已跳转系统授权页，
     *   授权后重新触发即可安装（APK 已在本地，不会重复下载）。
     */
    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("filePath")
        if (path.isNullOrBlank()) {
            result.success(mapOf("ok" to false, "error" to "filePath 参数缺失"))
            return
        }
        val file = File(path)
        if (!file.exists() || file.length() == 0L) {
            result.success(mapOf("ok" to false, "error" to "APK 文件不存在或为空：$path"))
            return
        }
        // Android 8+：调起安装器前必须授予「安装未知应用」权限。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            return try {
                val intent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                result.success(
                    mapOf("ok" to false, "pendingPermission" to true)
                )
            } catch (e: Exception) {
                result.success(
                    mapOf("ok" to false, "error" to "无法打开系统授权页：${e.message}")
                )
            }
        }
        try {
            val mime = call.argument<String>("fileType") ?: MIME_APK
            val uri = FileProvider.getUriForFile(
                this, "$packageName.update.fileprovider", file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK
                )
            }
            startActivity(intent)
            result.success(mapOf("ok" to true))
        } catch (e: Exception) {
            result.success(
                mapOf("ok" to false, "error" to "调起系统安装器失败：${e.message}")
            )
        }
    }
}
