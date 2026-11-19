package com.tangram.agent.tangram

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 模型下载保活前台服务：不自己下载，只保证 Flutter 进程在后台不被挂起，
 * 让 Dart 的分片/断点下载能继续跑；同时把 Dart 上报的真实进度（模型名 +
 * 百分比 + 已下载/总量）刷新到通知栏。下载结束由 Dart 侧 stopKeepAlive。
 */
class ModelDownloadKeepAliveService : Service() {

    companion object {
        private const val CHANNEL_ID = "tga_model_download"
        private const val NOTIFICATION_ID = 0x5A18
        private const val ACTION_UPDATE = "tga.model_download.update"
        private const val EXTRA_NAME = "model_name"
        private const val EXTRA_PERCENT = "percent"
        private const val EXTRA_DOWNLOADED = "downloaded"
        private const val EXTRA_TOTAL = "total"
        private const val EXTRA_DONE = "done"

        @Volatile
        private var instance: ModelDownloadKeepAliveService? = null

        // 最新进度缓存：即使服务尚未 onCreate，也先存下来，onCreate 后应用。
        @Volatile
        private var modelName: String = ""
        @Volatile
        private var percent: Int = -1
        @Volatile
        private var downloaded: Long = 0L
        @Volatile
        private var total: Long = 0L
        @Volatile
        private var done: Boolean = false

        /** Dart/Activity 调用：更新通知栏进度（同进程静态缓存，线程安全）。 */
        @JvmStatic
        fun updateProgress(
            name: String?,
            pct: Int,
            doneBytes: Long,
            totalBytes: Long,
            finished: Boolean,
        ) {
            if (!name.isNullOrBlank()) modelName = name
            percent = pct.coerceIn(-1, 100)
            downloaded = doneBytes.coerceAtLeast(0)
            total = totalBytes.coerceAtLeast(0)
            done = finished
            instance?.refreshNotification()
        }

        /** 供 Activity 构造 startService 的 Intent（实例为空时也能更新进度）。 */
        fun updateIntent(
            context: Context,
            name: String?,
            pct: Int,
            doneBytes: Long,
            totalBytes: Long,
            finished: Boolean,
        ): Intent = Intent(context, ModelDownloadKeepAliveService::class.java).apply {
            action = ACTION_UPDATE
            putExtra(EXTRA_NAME, name)
            putExtra(EXTRA_PERCENT, pct)
            putExtra(EXTRA_DOWNLOADED, doneBytes)
            putExtra(EXTRA_TOTAL, totalBytes)
            putExtra(EXTRA_DONE, finished)
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "模型下载", NotificationManager.IMPORTANCE_LOW
            )
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
                .createNotificationChannel(channel)
        }
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_UPDATE) {
            updateProgress(
                intent.getStringExtra(EXTRA_NAME),
                intent.getIntExtra(EXTRA_PERCENT, percent),
                intent.getLongExtra(EXTRA_DOWNLOADED, downloaded),
                intent.getLongExtra(EXTRA_TOTAL, total),
                intent.getBooleanExtra(EXTRA_DONE, done),
            )
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun refreshNotification() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val label = modelName.ifBlank { "模型" }
        val title: String
        val text: String
        when {
            done && percent >= 0 -> {
                title = "模型下载完成"
                text = label
            }
            done -> {
                title = "模型下载已结束"
                text = label
            }
            percent < 0 -> {
                title = label
                text = "后台下载中，退出应用不会中断"
            }
            else -> {
                title = label
                text = "$percent%  ·  ${formatSize(downloaded)} / ${formatSize(total)}"
            }
        }
        builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pending)
            .setOngoing(!done)
            .setAutoCancel(done)
        if (!done) {
            builder.setProgress(100, if (percent < 0) 0 else percent, percent < 0)
        }
        return builder.build()
    }

    private fun formatSize(bytes: Long): String = when {
        bytes >= 1024L * 1024 * 1024 ->
            String.format("%.2f GB", bytes.toDouble() / (1024L * 1024 * 1024))
        bytes >= 1024L * 1024 ->
            String.format("%.1f MB", bytes.toDouble() / (1024L * 1024))
        bytes >= 1024L ->
            String.format("%.1f KB", bytes.toDouble() / 1024L)
        else -> "$bytes B"
    }
}
