package io.github.mazengomaa.attendance_host

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service whose only job is to keep this process alive and awake while
 * a session runs: the Dart HTTP server and the cloudflared child processes live
 * in the app process, and Android freezes or kills background processes that
 * have no foreground service. Holds a partial CPU wake lock and a Wi-Fi lock so
 * the screen can be off for the whole lecture.
 */
class HostService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Attendance session running"
        val notification = buildNotification(this, text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireLocks()
        running = true
        // Not sticky: if Android kills the process, the Dart server is gone too,
        // so a restarted empty service would only show a misleading notification.
        return START_NOT_STICKY
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,
                "AttendanceHost::session").apply {
                setReferenceCounted(false)
                acquire(12 * 60 * 60 * 1000L)   // safety cap: 12 h
            }
        }
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY else WifiManager.WIFI_MODE_FULL_HIGH_PERF
            wifiLock = wm.createWifiLock(mode, "AttendanceHost::wifi").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
        running = false
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "session"
        const val NOTIFICATION_ID = 1
        const val EXTRA_TEXT = "text"

        @Volatile
        var running = false

        fun buildNotification(context: Context, text: String): Notification {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(NotificationChannel(
                    CHANNEL_ID, "Attendance session", NotificationManager.IMPORTANCE_LOW))
            }
            val open = PendingIntent.getActivity(context, 0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(context, CHANNEL_ID) else
                @Suppress("DEPRECATION") Notification.Builder(context)
            return builder
                .setContentTitle("Attendance Host")
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_upload_done)
                .setOngoing(true)
                .setContentIntent(open)
                .build()
        }

        const val ALERT_CHANNEL_ID = "alerts"
        const val ALERT_ID = 2

        /** A heads-up alert (sound/vibration) for things the professor must act
         *  on now, e.g. a student link that changed. */
        fun alert(context: Context, title: String, text: String) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                nm.getNotificationChannel(ALERT_CHANNEL_ID) == null) {
                nm.createNotificationChannel(NotificationChannel(
                    ALERT_CHANNEL_ID, "Session alerts", NotificationManager.IMPORTANCE_HIGH))
            }
            val open = PendingIntent.getActivity(context, 1,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                Notification.Builder(context, ALERT_CHANNEL_ID) else
                @Suppress("DEPRECATION") Notification.Builder(context)
                    .setPriority(Notification.PRIORITY_HIGH)
            nm.notify(ALERT_ID, builder
                .setContentTitle(title)
                .setContentText(text)
                .setStyle(Notification.BigTextStyle().bigText(text))
                .setSmallIcon(android.R.drawable.stat_notify_error)
                .setAutoCancel(true)
                .setContentIntent(open)
                .build())
        }

        fun update(context: Context, text: String) {
            if (!running) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(context, text))
        }
    }
}
