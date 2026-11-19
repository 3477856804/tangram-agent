package com.tangram.agent.tangram

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.location.Criteria
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import kotlin.math.cos
import kotlin.random.Random

/**
 * 爱阳光跑：系统级位置注入前台服务（Kotlin 原生层）。
 *
 * 与 Flutter 的 SunRunRuntime 分工：
 * - Dart 负责真实感轨迹/速度/GNSS 数据；
 * - 本服务把最新 fix 通过 LocationManager 测试 Provider 注入 GPS/Network/Fused，
 *   让其它 App 也能读到模拟位置（需在开发者选项里把本应用设为模拟位置应用）。
 *
 * 目标 SDK 为 28，保留 addTestProvider 的旧签名；Android 12+ 额外尝试 fused。
 */
class SunRunMockService : Service() {

    companion object {
        private const val TAG = "SunRunMockService"
        private const val CHANNEL_ID = "tga_sun_run"
        private const val CHANNEL_NAME = "爱阳光跑位置模拟"
        private const val NOTIFICATION_ID = 0x5A17
        private const val INTERVAL_MS = 200L

        @Volatile
        var instance: SunRunMockService? = null
            private set

        /** 服务尚未创建时先缓存最近一次 fix。 */
        @Volatile
        var pending: Map<String, Any?>? = null

        @Volatile
        var lastError: String = ""
            private set
    }

    private lateinit var locationManager: LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private val random = Random(SystemClock.elapsedRealtimeNanos())

    private var lat = 0.0
    private var lng = 0.0
    private var alt = 55.0
    private var speed = 0.0
    private var bearing = 0.0
    private var accuracy = 6.0
    private var satellites = 16
    private var hasFix = false
    private var providersReady = false

    private val providers = mutableListOf<String>()

    private val tick = object : Runnable {
        override fun run() {
            if (hasFix) {
                try {
                    injectAll()
                } catch (e: Throwable) {
                    lastError = "注入失败：${e.javaClass.simpleName}: ${e.message}"
                    Log.e(TAG, lastError)
                }
            }
            handler.postDelayed(this, INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        locationManager =
            getSystemService(Context.LOCATION_SERVICE) as LocationManager
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification("等待轨迹数据"))
        ensureProviders()
        pending?.let { update(it) }
        handler.post(tick)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let {
            val map = HashMap<String, Any?>()
            map["lat"] = it.getDoubleExtra("lat", 0.0)
            map["lng"] = it.getDoubleExtra("lng", 0.0)
            map["alt"] = it.getDoubleExtra("alt", 55.0)
            map["speed"] = it.getDoubleExtra("speed", 0.0)
            map["bearing"] = it.getDoubleExtra("bearing", 0.0)
            map["accuracy"] = it.getDoubleExtra("accuracy", 6.0)
            map["satellites"] = it.getIntExtra("satellites", 16)
            update(map)
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        removeProviders()
        instance = null
        super.onDestroy()
    }

    /** Flutter 每秒推送一次最新轨迹点；这里只做 200ms 级的注入与微小抖动。 */
    fun update(fix: Map<String, Any?>) {
        val newLat = (fix["lat"] as? Number)?.toDouble() ?: return
        val newLng = (fix["lng"] as? Number)?.toDouble() ?: return
        if (newLat == 0.0 && newLng == 0.0) return
        lat = newLat
        lng = newLng
        alt = (fix["alt"] as? Number)?.toDouble() ?: alt
        speed = (fix["speed"] as? Number)?.toDouble() ?: 0.0
        bearing = (fix["bearing"] as? Number)?.toDouble() ?: 0.0
        accuracy = (fix["accuracy"] as? Number)?.toDouble() ?: 6.0
        satellites = (fix["satellites"] as? Number)?.toInt() ?: 16
        hasFix = true
        pending = fix
        if (providersReady) {
            updateNotification(
                "注入中 ${"%.5f".format(lat)}, ${"%.5f".format(lng)}  " +
                    "${"%.1f".format(speed)}m/s"
            )
        }
    }

    private fun ensureProviders() {
        if (providersReady) return
        try {
            addProvider(LocationManager.GPS_PROVIDER, false, Criteria.ACCURACY_FINE)
            addProvider(
                LocationManager.NETWORK_PROVIDER, true, Criteria.ACCURACY_COARSE
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                addProvider("fused", false, Criteria.ACCURACY_FINE)
            }
            providersReady = true
        } catch (e: SecurityException) {
            lastError = "缺少位置权限或未选择模拟位置应用：${e.message}"
            Log.e(TAG, lastError)
        } catch (e: Throwable) {
            lastError = "创建测试 Provider 失败：${e.message}"
            Log.e(TAG, lastError)
        }
    }

    @Suppress("DEPRECATION")
    private fun addProvider(name: String, network: Boolean, accuracy: Int) {
        try {
            locationManager.addTestProvider(
                name,
                network,
                true,
                false,
                false,
                true,
                true,
                true,
                Criteria.POWER_HIGH,
                accuracy
            )
        } catch (e: IllegalArgumentException) {
            // 已存在时直接复用。
        }
        try {
            locationManager.setTestProviderEnabled(name, true)
            providers.add(name)
        } catch (e: SecurityException) {
            lastError = "未授权模拟位置：${e.message}"
        }
    }

    private fun removeProviders() {
        for (name in providers) {
            try {
                locationManager.setTestProviderEnabled(name, false)
                locationManager.removeTestProvider(name)
            } catch (_: Throwable) {
                // 清理失败不影响退出。
            }
        }
        providers.clear()
        providersReady = false
    }

    @Suppress("DEPRECATION")
    private fun injectAll() {
        if (!providersReady) {
            ensureProviders()
            if (!providersReady) return
        }
        for (name in providers) {
            val isNetwork = name == LocationManager.NETWORK_PROVIDER
            val loc = Location(name)
            // 多径级微抖动：约 0.15m，避免同一坐标每 200ms 完全一致。
            val jitter = 0.15
            val dLat = (random.nextDouble() - 0.5) * jitter / 111320.0
            val dLng = (random.nextDouble() - 0.5) * jitter /
                (111320.0 * cos(Math.toRadians(lat)).coerceAtLeast(0.05))
            loc.latitude = lat + dLat
            loc.longitude = lng + dLng
            loc.altitude = alt
            loc.accuracy = if (isNetwork) (accuracy * 4.0 + 12.0).toFloat() else accuracy.toFloat()
            loc.time = System.currentTimeMillis()
            loc.elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
            loc.speed = speed.toFloat()
            loc.bearing = if (speed > 0.3) bearing.toFloat() else 0f
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                loc.verticalAccuracyMeters = 2.5f
                loc.speedAccuracyMetersPerSecond = 0.25f
                loc.bearingAccuracyDegrees = 6f
            }
            val extras = Bundle()
            extras.putInt("satellites", satellites)
            extras.putInt("satellitesUsedInFix", satellites)
            extras.putString("gnssConstellations", "BEIDOU,GPS,GLONASS,GALILEO")
            loc.extras = extras
            locationManager.setTestProviderLocation(name, loc)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW
        )
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this, 0, launch, PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentTitle("爱阳光跑")
            .setContentText(text)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification(text))
        } catch (_: Throwable) {
            // 通知更新失败不影响注入。
        }
    }
}
