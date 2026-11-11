package com.lotterfriends.antatime

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import java.time.LocalDate
import java.time.ZoneId

/**
 * Benachrichtigung, sobald heute die Tagesstunden erreicht sind.
 *
 * Die Flutter-Seite übergibt die Soll-Zeiten der nächsten Arbeitstage (ohne
 * Feiertag/Abwesenheit, siehe `targetReminderDays` in lib/reminder.dart).
 * Nach jedem Start/Pause – auch über die Benachrichtigung bei geschlossener
 * App – wird hier neu geplant: Läuft die Arbeitszeit, ist der Alarm auf den
 * Zeitpunkt gestellt, zu dem das Soll erreicht wird; bei Pause entfällt er.
 */
object TargetReminder {
    private const val PREFS_FILE = "antatime_target_reminder"
    private const val KEY_TARGETS = "targets"
    private const val CHANNEL_ID = "reminder"
    const val NOTIFICATION_ID = 3
    const val ACTION_FIRE = "com.lotterfriends.antatime.TARGET_REMINDER"

    /** Soll-Zeiten als `yyyy-MM-dd=ms` speichern und neu planen. */
    fun setTargets(context: Context, targets: List<String>) {
        prefs(context).edit().putString(KEY_TARGETS, targets.joinToString(",")).apply()
        schedule(context)
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /** Soll-Zeit von heute in ms, falls heute erinnert werden soll. */
    private fun targetTodayMs(context: Context): Long? {
        val today = LocalDate.now(ZoneId.systemDefault()).toString()
        return prefs(context).getString(KEY_TARGETS, null)
            ?.split(",")
            ?.map { it.split("=") }
            ?.firstOrNull { it.size == 2 && it[0] == today }
            ?.get(1)?.toLongOrNull()
            ?.takeIf { it > 0 }
    }

    /** Alarm passend zum aktuellen Zustand stellen (oder entfernen). */
    fun schedule(context: Context) {
        val alarm = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = fireIntent(context)
        alarm.cancel(pending)
        val target = targetTodayMs(context) ?: return
        val store = TrackingStore(context)
        if (store.running() == null) return
        val now = System.currentTimeMillis()
        val remaining = target - store.workedTodayMs()
        if (remaining <= 0) return
        val at = now + remaining
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarm.canScheduleExactAlarms()) {
            alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        } else {
            alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }

    private fun fireIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            20,
            Intent(context, ReminderReceiver::class.java).setAction(ACTION_FIRE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /** Wird zum geplanten Zeitpunkt ausgelöst. */
    fun fire(context: Context) {
        val target = targetTodayMs(context)
        val store = TrackingStore(context)
        // Kleine Toleranz, falls der Alarm minimal zu früh kommt.
        if (target != null && store.running() != null &&
            store.workedTodayMs() >= target - 5_000
        ) {
            show(context, target)
        } else {
            schedule(context)
        }
    }

    fun cancelShown(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    private fun show(context: Context, targetMs: Long) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureChannel(context)
        val openApp = PendingIntent.getActivity(
            context,
            21,
            Intent(context, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val stop = PendingIntent.getBroadcast(
            context,
            22,
            Intent(context, NotificationActionReceiver::class.java)
                .setAction(NotificationActionReceiver.ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val minutes = targetMs / 60_000
        val hours = "%d:%02d".format(minutes / 60, minutes % 60)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_running)
            .setColor(ContextCompat.getColor(context, R.color.notification_accent))
            .setContentTitle("Tagesstunden erreicht")
            .setContentText("Heute $hours h gearbeitet – Feierabend?")
            .setContentIntent(openApp)
            .addAction(R.drawable.ic_action_stop, "Feierabend", stop)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .build()
        try {
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        } catch (e: SecurityException) {
            // Berechtigung fehlt – nichts anzeigen.
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Erinnerung", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "Erinnerungen zur Zeiterfassung" },
        )
    }
}
