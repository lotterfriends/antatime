package com.lotterfriends.antatime

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground-Service mit der Steuer-Benachrichtigung als Service-
 * Benachrichtigung: Er tut selbst nichts, hält aber den Prozess am Leben,
 * damit die Sync-Verbindung der Flutter-Engine ([AppEngine]) bestehen bleibt
 * und Änderungen anderer Geräte die Benachrichtigung sofort aktualisieren.
 *
 * Läuft nur, solange die Benachrichtigung angezeigt wird und
 * [BackgroundSync] aktiv ist (siehe [TrackingNotification.refresh]).
 */
class SyncKeepAliveService : Service() {
    companion object {
        private val main = Handler(Looper.getMainLooper())

        @Volatile
        private var instance: SyncKeepAliveService? = null

        val isRunning: Boolean get() = instance != null

        /**
         * Startet den Service. `false`, wenn Android das gerade nicht erlaubt
         * (Start aus dem Hintergrund) – dann bleibt es bei der normalen
         * Benachrichtigung, bis die App wieder geöffnet wird.
         */
        fun start(context: Context): Boolean =
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, SyncKeepAliveService::class.java),
                )
                true
            } catch (e: Exception) {
                // ForegroundServiceStartNotAllowedException (Android 12+)
                false
            }

        /**
         * Beendet den Service. Mit [removeNotification] `false` bleibt die
         * Benachrichtigung als normale Benachrichtigung stehen.
         */
        fun stop(removeNotification: Boolean) {
            main.post {
                val service = instance ?: return@post
                ServiceCompat.stopForeground(
                    service,
                    if (removeNotification) ServiceCompat.STOP_FOREGROUND_REMOVE
                    else ServiceCompat.STOP_FOREGROUND_DETACH,
                )
                service.stopSelf()
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = TrackingNotification.build(this)
        if (notification == null || !BackgroundSync.isActive(this)) {
            // startForegroundService verlangt trotzdem startForeground – sonst
            // beendet Android die App. Danach gleich wieder aufräumen.
            foreground(notification ?: TrackingNotification.placeholder(this))
            instance = this
            stop(removeNotification = notification == null)
            return START_NOT_STICKY
        }
        if (!foreground(notification)) {
            stopSelf()
            return START_NOT_STICKY
        }
        instance = this
        // Sync starten, falls der Prozess gerade erst (neu) gestartet wurde.
        AppEngine.obtain(this)
        return START_STICKY
    }

    private fun foreground(notification: android.app.Notification): Boolean =
        try {
            ServiceCompat.startForeground(
                this,
                TrackingNotification.NOTIFICATION_ID,
                notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                } else {
                    0
                },
            )
            true
        } catch (e: Exception) {
            false
        }

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }
}
