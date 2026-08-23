package app.netcatty.mobile

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class SshKeepAliveService : Service() {
    companion object {
        private const val CHANNEL_ID = "netcatty_ssh_sessions"
        private const val NOTIFICATION_ID = 701
    }

    private var cpuWakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        acquireConnectionLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        acquireConnectionLocks()
        // The SSH sockets live in the Flutter process. Restarting only this
        // service after that process was killed cannot restore them and would
        // leave an orphan notification holding locks indefinitely.
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        releaseConnectionLocks()
        super.onDestroy()
    }

    @SuppressLint("WakelockTimeout")
    private fun acquireConnectionLocks() {
        if (cpuWakeLock?.isHeld != true) {
            cpuWakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "$packageName:ssh-cpu",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        if (wifiLock?.isHeld != true) {
            @Suppress("DEPRECATION")
            wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "$packageName:ssh-wifi",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }

    private fun releaseConnectionLocks() {
        cpuWakeLock?.let { if (it.isHeld) it.release() }
        cpuWakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "SSH 会话",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "保持正在使用的 SSH 连接"
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Netcatty SSH 会话正在运行")
            .setContentText("点击返回终端；关闭全部会话后服务会自动停止")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }
}
