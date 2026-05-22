package com.magoremote.mago_remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service of type `mediaProjection`, required on Android 10+
 * (and strictly enforced on Android 14+/targetSdk 34+) so that
 * `MediaProjectionManager.getMediaProjection()` is allowed to bind.
 *
 * IMPORTANT: This service may only be started AFTER the user has accepted
 * the MediaProjection consent dialog (i.e. after
 * `Helper.requestCapturePermission()` returns true). Starting it before
 * the system has granted the per-app `android:project_media` token throws
 * SecurityException on Android 14+.
 */
class ScreenCaptureService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        // Notify any waiters (MagoRemotePlugin's startScreenCaptureService
        // handler) that the FGS is now actually in the foreground state and
        // it is safe to call MediaProjectionManager.getMediaProjection().
        synchronized(lock) {
            isRunning = true
            val cbs = startedCallbacks.toList()
            startedCallbacks.clear()
            for (cb in cbs) {
                try { cb() } catch (_: Throwable) {}
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        synchronized(lock) { isRunning = false }
        super.onDestroy()
    }

    private fun startForegroundCompat() {
        val channelId = "remote_desk_screen_capture"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(
                    channelId,
                    "Remote Desk screen sharing",
                    NotificationManager.IMPORTANCE_LOW,
                )
                ch.description = "Active while your screen is being shared."
                nm.createNotificationChannel(ch)
            }
        }

        val notif: Notification =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, channelId)
                    .setContentTitle("Remote Desk")
                    .setContentText("Screen is being shared.")
                    .setSmallIcon(android.R.drawable.ic_menu_view)
                    .setOngoing(true)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
                    .setContentTitle("Remote Desk")
                    .setContentText("Screen is being shared.")
                    .setSmallIcon(android.R.drawable.ic_menu_view)
                    .setOngoing(true)
                    .build()
            }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notif)
        }
    }

    companion object {
        const val NOTIFICATION_ID = 0xC0DE

        private val lock = Any()
        private var isRunning = false
        private val startedCallbacks = mutableListOf<() -> Unit>()

        /**
         * Invokes [cb] immediately if the FGS is already running, otherwise
         * queues it to be called the next time [onStartCommand] fires and
         * [startForeground] completes.
         */
        fun awaitStarted(cb: () -> Unit) {
            synchronized(lock) {
                if (isRunning) {
                    cb()
                } else {
                    startedCallbacks.add(cb)
                }
            }
        }
    }
}
