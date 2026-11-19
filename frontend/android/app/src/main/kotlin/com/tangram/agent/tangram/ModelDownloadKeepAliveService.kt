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
import java.util.concurrent.ConcurrentHashMap

/**
 * 模型下载保活前台服务：不自己下载，只保证 Flutter 进程在后台不被挂起，
 * 让 Dart 的分片/断点下载能继续跑。
 *
 * 通知栏用 InboxStyle 列出所有并发下载任务，每个任务一行：
 *   Qwen3-8B-Q4   35%  1.9 GB / 5.4 GB
 * 不再用单一通知反复覆盖，避免多个模型下载时通知闪来闪去。
 */
class ModelDownloadKeepAliveService : Service() {

    data class Job(
        val name: String,
        var percent: Int,
        var downloaded: Long,
        var total: Long,
        var done: Boolean,
        var updatedAt: Long,
    )

    companion object {
        private const val CHANNEL_ID = "tga_model_download"
        private const val NOTIFICATION_ID = 0x5A18
        private const val MAX_LINES = 7

        private val jobs = ConcurrentHashMap<String, Job>()

        @Volatile
        private var instance: ModelDownloadKeepAliveService? = null

        /** Dart/Activity：按 jobId 更新单个任务；同一任务只占一行。 */
        @JvmStatic
        fun updateJobProgress(
            id: String?,
            name: String?,
            pct: Int,
            doneBytes: Long,
            totalBytes: Long,
            finished: Boolean,
        ) {
            val key = id?.takeIf { it.isNotBlank() } ?: "default"
            val label = name?.takeIf { it.isNotBlank() } ?: "模型"
            val job = jobs[key]
            if (job == null) {
                jobs[key] = Job(
                    label, pct.coerceIn(-1, 100),
                    doneBytes.coerceAtLeast(0), totalBytes.coerceAtLeast(0),
                    finished, System.currentTimeMillis()
                )
            } else {
                job.percent = pct.coerceIn(-1, 100)
                job.downloaded = doneBytes.coerceAtLeast(0)
                job.total = totalBytes.coerceAtLeast(0)
                job.done = finished
                job.updatedAt = System.currentTimeMillis()
            }
            // 已完成的任务保留 5 秒，让用户看到“完成”，然后清掉。
            if (finished) {
                val done = jobs[key]
                if (done != null && System.currentTimeMillis() - done.updatedAt > 5000) {
                    jobs.remove(key)
                }
            }
            instance?.refreshNotification()
        }

        /** 兼容旧调用：没有 jobId 时只更新 default 行。 */
        @JvmStatic
        fun updateProgress(
            name: String?,
            pct: Int,
            doneBytes: Long,
            totalBytes: Long,
            finished: Boolean,
        ) = updateJobProgress("default", name, pct, doneBytes, totalBytes, finished)

        fun stopAll(context: Context) {
            jobs.clear()
            context.stopService(
                Intent(context, ModelDownloadKeepAliveService::class.java)
            )
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

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

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

        val list = jobs.values.sortedByDescending { it.updatedAt }
        val anyActive = list.any { !it.done }
        val sumTotal = list.sumOf { it.total }
        val sumDone = list.sumOf { it.downloaded }

        val title: String
        val text: String
        if (list.isEmpty()) {
            title = "模型下载"
            text = "后台下载中，退出应用不会中断"
        } else {
            title = "模型下载 · ${list.size} 个"
            text = if (sumTotal > 0) {
                "${(sumDone * 100 / sumTotal)}%  ·  " +
                    "${formatSize(sumDone)} / ${formatSize(sumTotal)}"
            } else {
                "后台下载中，退出应用不会中断"
            }
        }

        builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pending)
            .setOngoing(anyActive)
            .setOnlyAlertOnce(true)

        if (list.isNotEmpty()) {
            val style = Notification.InboxStyle()
                .setBigContentTitle(title)
                .setSummaryText("${list.size} 个任务")
            for (job in list.take(MAX_LINES)) {
                val state = when {
                    job.done -> "完成"
                    job.percent >= 0 -> "${job.percent}%"
                    else -> "连接中"
                }
                val size = if (job.total > 0) {
                    "  ${formatSize(job.downloaded)} / ${formatSize(job.total)}"
                } else {
                    ""
                }
                style.addLine("${job.name}  $state$size")
            }
            if (list.size > MAX_LINES) {
                style.addLine("还有 ${list.size - MAX_LINES} 个任务…")
            }
            builder.setStyle(style)
        }

        if (anyActive) {
            val pct = if (sumTotal > 0) (sumDone * 100 / sumTotal).toInt() else 0
            builder.setProgress(100, pct, sumTotal <= 0)
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
