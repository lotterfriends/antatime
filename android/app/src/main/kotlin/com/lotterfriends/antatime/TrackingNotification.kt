package com.lotterfriends.antatime

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.time.Instant

/**
 * Steuer-Benachrichtigung mit eigenem Layout:
 * - laufend: drehendes Uhr-Symbol in der Statusleiste, „Derzeit“ und „Heute“ als Live-Uhr
 * - pausiert: Stoppuhr mit Pause-Symbol, Pausendauer läuft mit
 * - Aktionen als Symbole: Start/Pause und Feierabend (Stop)
 */
object TrackingNotification {
    // Eigener Kanal mit Standard-Wichtigkeit (aber ohne Ton/Vibration): Nur so
    // erscheint das Symbol in der Statusleiste. Kanäle mit niedriger
    // Wichtigkeit landen unter „Lautlos“ und Android blendet deren Symbole
    // standardmäßig aus. Die Wichtigkeit eines bestehenden Kanals lässt sich
    // nicht ändern, daher eine neue ID; der alte Kanal wird entfernt.
    private const val CHANNEL_ID = "tracking_status"
    private const val OLD_CHANNEL_ID = "tracking"
    private const val NOTIFICATION_ID = 1

    fun refresh(context: Context) {
        val store = TrackingStore(context)
        val running = store.running()
        if (!store.showNotification() || (running == null && store.stoppedToday())) {
            cancel(context)
            return
        }
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureChannel(context)

        val now = Instant.now()
        val elapsedNow = SystemClock.elapsedRealtime()
        val workedToday = store.workedTodayMs(now)
        val isRunning = running != null

        fun views(layout: Int): RemoteViews {
            val v = RemoteViews(context.packageName, layout)
            if (running != null) {
                val current = now.toEpochMilli() - running.start.toEpochMilli()
                v.setViewVisibility(R.id.current_chrono, View.VISIBLE)
                v.setViewVisibility(R.id.current_text, View.GONE)
                v.setChronometer(R.id.current_chrono, elapsedNow - current, "Derzeit: %s", true)
            } else {
                val lastEnd = store.lastEndToday()
                if (lastEnd != null) {
                    val pause = now.toEpochMilli() - lastEnd.toEpochMilli()
                    v.setViewVisibility(R.id.current_chrono, View.VISIBLE)
                    v.setViewVisibility(R.id.current_text, View.GONE)
                    v.setChronometer(R.id.current_chrono, elapsedNow - pause, "Pause: %s", true)
                } else {
                    v.setViewVisibility(R.id.current_chrono, View.GONE)
                    v.setViewVisibility(R.id.current_text, View.VISIBLE)
                    v.setTextViewText(R.id.current_text, "Bereit")
                }
            }
            v.setChronometer(R.id.today_chrono, elapsedNow - workedToday, "Heute: %s", isRunning)

            v.setImageViewResource(
                R.id.btn_toggle,
                if (isRunning) R.drawable.ic_action_pause else R.drawable.ic_action_play,
            )
            v.setContentDescription(R.id.btn_toggle, if (isRunning) "Pause" else "Start")
            v.setOnClickPendingIntent(
                R.id.btn_toggle,
                actionIntent(context, NotificationActionReceiver.ACTION_TOGGLE, 1),
            )
            v.setOnClickPendingIntent(
                R.id.btn_stop,
                actionIntent(context, NotificationActionReceiver.ACTION_STOP, 2),
            )
            return v
        }

        val openApp = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(if (isRunning) R.drawable.ic_stat_running else R.drawable.ic_stat_paused)
            .setColor(ContextCompat.getColor(context, R.color.notification_accent))
            .setSubText(if (isRunning) "Arbeitszeit läuft" else "Pausiert")
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomContentView(views(R.layout.notification_tracking_small))
            .setCustomBigContentView(views(R.layout.notification_tracking_big))
            .setContentIntent(openApp)
            .setOngoing(isRunning)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_STOPWATCH)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .build()

        try {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        } catch (e: SecurityException) {
            // Berechtigung fehlt – nichts anzeigen.
        }
    }

    fun cancel(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    private fun actionIntent(context: Context, action: String, requestCode: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            requestCode,
            Intent(context, NotificationActionReceiver::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(OLD_CHANNEL_ID) != null) {
            manager.deleteNotificationChannel(OLD_CHANNEL_ID)
        }
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Zeiterfassung", NotificationManager.IMPORTANCE_DEFAULT)
                .apply {
                    description = "Start/Pause der Arbeitszeit"
                    setShowBadge(false)
                    setSound(null, null)
                    enableVibration(false)
                    enableLights(false)
                },
        )
    }
}
