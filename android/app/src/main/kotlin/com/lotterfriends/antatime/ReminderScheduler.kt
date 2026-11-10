package com.lotterfriends.antatime

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/**
 * Erinnerung an den Start der Zeiterfassung.
 *
 * Die Flutter-Seite berechnet die nächsten Zeitpunkte (Arbeitstage ohne
 * Feiertag/Abwesenheit, siehe lib/reminder.dart) und übergibt sie hier. Es
 * ist immer nur der nächste Zeitpunkt beim AlarmManager eingeplant; beim
 * Auslösen wird geprüft, ob heute schon gestartet wurde – so entfällt die
 * Erinnerung auch nach einem Start über die Benachrichtigung bei
 * geschlossener App.
 */
object ReminderScheduler {
    private const val PREFS_FILE = "antatime_reminder"
    private const val KEY_TIMES = "times"
    private const val CHANNEL_ID = "reminder"
    const val NOTIFICATION_ID = 2
    const val ACTION_FIRE = "com.lotterfriends.antatime.REMINDER"

    /** Zeitpunkte (ms seit Epoche) speichern und den nächsten einplanen. */
    fun setTimes(context: Context, times: List<Long>) {
        prefs(context).edit().putString(KEY_TIMES, times.sorted().joinToString(",")).apply()
        scheduleNext(context)
        if (TrackingStore(context).startedToday()) cancelShown(context)
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    private fun times(context: Context): List<Long> =
        prefs(context).getString(KEY_TIMES, null)
            ?.split(",")
            ?.mapNotNull { it.trim().toLongOrNull() }
            ?: emptyList()

    /** Nächsten zukünftigen Zeitpunkt beim AlarmManager einplanen (oder keinen). */
    fun scheduleNext(context: Context) {
        val alarm = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = fireIntent(context)
        alarm.cancel(pending)
        val now = System.currentTimeMillis()
        val next = times(context).firstOrNull { it > now } ?: return
        // Ohne Berechtigung für exakte Alarme kann Android die Erinnerung im
        // Ruhemodus um einige Minuten verzögern.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarm.canScheduleExactAlarms()) {
            alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pending)
        } else {
            alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pending)
        }
    }

    private fun fireIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            10,
            Intent(context, ReminderReceiver::class.java).setAction(ACTION_FIRE),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /** Wird zum geplanten Zeitpunkt ausgelöst. */
    fun fire(context: Context) {
        val store = TrackingStore(context)
        if (!store.startedToday() && !store.stoppedToday()) show(context)
        scheduleNext(context)
    }

    fun cancelShown(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    private fun show(context: Context) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        ensureChannel(context)
        val openApp = PendingIntent.getActivity(
            context,
            11,
            Intent(context, MainActivity::class.java)
                .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val start = PendingIntent.getBroadcast(
            context,
            12,
            Intent(context, NotificationActionReceiver::class.java)
                .setAction(NotificationActionReceiver.ACTION_START),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_paused)
            .setColor(ContextCompat.getColor(context, R.color.notification_accent))
            .setContentTitle("Zeiterfassung starten?")
            .setContentText("Die Arbeitszeit wurde heute noch nicht gestartet.")
            .setContentIntent(openApp)
            .addAction(R.drawable.ic_action_play, "Starten", start)
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
                .apply { description = "Erinnerung an den Start der Zeiterfassung" },
        )
    }
}

/** Auslösen der Erinnerung sowie Neuplanung nach Neustart/Update/Zeitänderung. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ReminderScheduler.ACTION_FIRE -> ReminderScheduler.fire(context)
            else -> ReminderScheduler.scheduleNext(context)
        }
    }
}
