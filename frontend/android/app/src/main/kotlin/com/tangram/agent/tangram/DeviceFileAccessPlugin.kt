// tangram:device_file_access (generated, do not edit by hand)
package com.tangram.agent.tangram

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
class DeviceFileAccessPlugin(private val activity: Activity) {
    companion object {
        const val CHANNEL = "tangram/device_files"
    }

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "checkAccess" -> result.success(hasAllFilesAccess())
                    "requestAccess" -> { openAllFilesSettings(); result.success(hasAllFilesAccess()) }
                    "storageRoots" -> result.success(storageRoots())
                    else -> result.notImplemented()
                }
            }
    }

    /** Android 11+ 判定「所有文件访问」；旧版本回落到 READ/WRITE 权限。 */
    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            ContextCompat.checkSelfPermission(activity,
                android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    /** 引导用户到系统「所有文件访问」设置页；返回 App 后由 Dart 侧重新 check。 */
    private fun openAllFilesSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val intent = Intent(
                    android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:" + activity.packageName))
                activity.startActivity(intent)
            } catch (_: Exception) {
                val fallback = Intent(
                    android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                activity.startActivity(fallback)
            }
        }
    }

    /** 真实共享存储根目录，授权后供 Dart 侧作为可访问根。 */
    private fun storageRoots(): List<Map<String, Any>> {
        val base = Environment.getExternalStorageDirectory().absolutePath
        return listOf(
            mapOf("path" to base, "label" to "设备共享存储", "writable" to true),
            mapOf("path" to "$base/Download", "label" to "下载", "writable" to true),
            mapOf("path" to "$base/DCIM", "label" to "相册", "writable" to true),
            mapOf("path" to "$base/Documents", "label" to "文档", "writable" to true),
            mapOf("path" to activity.filesDir.absolutePath,
                  "label" to "App 私有目录", "writable" to true)
        )
    }
}
