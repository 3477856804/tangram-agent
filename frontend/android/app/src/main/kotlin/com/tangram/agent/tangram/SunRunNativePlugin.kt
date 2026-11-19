package com.tangram.agent.tangram

import android.Manifest
import android.app.Activity
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 爱阳光跑原生桥：Flutter ↔ Kotlin 系统位置注入。
 *
 * 通道：tga/sun_run
 * 方法：status / start / update / stop / openDeveloperSettings / requestPermission
 */
class SunRunNativePlugin(private val activity: Activity) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "tga/sun_run"
        private const val REQ_LOCATION = 7401
        private const val OP_MOCK_LOCATION = "android:mock_location"
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(status())
                "start" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    start(args)
                    result.success(status())
                }
                "update" -> {
                    val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                    update(args)
                    result.success(mapOf("ok" to true))
                }
                "stop" -> {
                    activity.stopService(Intent(activity, SunRunMockService::class.java))
                    result.success(mapOf("ok" to true, "running" to false))
                }
                "openDeveloperSettings" -> {
                    val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                    result.success(mapOf("ok" to true))
                }
                "requestPermission" -> {
                    ActivityCompat.requestPermissions(
                        activity,
                        arrayOf(
                            Manifest.permission.ACCESS_FINE_LOCATION,
                            Manifest.permission.ACCESS_COARSE_LOCATION
                        ),
                        REQ_LOCATION
                    )
                    result.success(mapOf("ok" to true, "requested" to true))
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.success(
                mapOf(
                    "ok" to false,
                    "error" to "${e.javaClass.simpleName}: ${e.message}"
                )
            )
        }
    }

    private fun status(): Map<String, Any?> = mapOf(
        "ok" to true,
        "platform" to "android",
        "sdk" to Build.VERSION.SDK_INT,
        "mock_allowed" to mockAllowed(),
        "location_granted" to locationGranted(),
        "running" to (SunRunMockService.instance != null),
        "last_error" to SunRunMockService.lastError
    )

    private fun start(args: Map<*, *>) {
        if (!locationGranted()) {
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION
                ),
                REQ_LOCATION
            )
        }
        val fix: Map<String, Any?> = args.entries.associate {
            it.key.toString() to it.value
        }
        SunRunMockService.pending = fix
        val intent = Intent(activity, SunRunMockService::class.java)
        fix["lat"]?.let { intent.putExtra("lat", (it as? Number)?.toDouble() ?: 0.0) }
        fix["lng"]?.let { intent.putExtra("lng", (it as? Number)?.toDouble() ?: 0.0) }
        fix["alt"]?.let { intent.putExtra("alt", (it as? Number)?.toDouble() ?: 55.0) }
        fix["speed"]?.let { intent.putExtra("speed", (it as? Number)?.toDouble() ?: 0.0) }
        fix["bearing"]?.let { intent.putExtra("bearing", (it as? Number)?.toDouble() ?: 0.0) }
        fix["accuracy"]?.let { intent.putExtra("accuracy", (it as? Number)?.toDouble() ?: 6.0) }
        fix["satellites"]?.let { intent.putExtra("satellites", (it as? Number)?.toInt() ?: 16) }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
    }

    private fun update(args: Map<*, *>) {
        val fix: Map<String, Any?> = args.entries.associate {
            it.key.toString() to it.value
        }
        SunRunMockService.pending = fix
        SunRunMockService.instance?.update(fix)
    }

    private fun locationGranted(): Boolean =
        ContextCompat.checkSelfPermission(
            activity, Manifest.permission.ACCESS_FINE_LOCATION
        ) == PackageManager.PERMISSION_GRANTED

    @Suppress("DEPRECATION")
    private fun mockAllowed(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val ops = activity.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
                ops.checkOpNoThrow(
                    OP_MOCK_LOCATION, Process.myUid(), activity.packageName
                ) == AppOpsManager.MODE_ALLOWED
            } else {
                Settings.Secure.getInt(
                    activity.contentResolver,
                    Settings.Secure.ALLOW_MOCK_LOCATION,
                    0
                ) == 1
            }
        } catch (_: Throwable) {
            false
        }
    }
}
