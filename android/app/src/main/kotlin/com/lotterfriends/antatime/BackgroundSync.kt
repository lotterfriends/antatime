package com.lotterfriends.antatime

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * Sync im Hintergrund (Einstellung „Im Hintergrund synchronisieren“, nur mit
 * eingerichtetem Sync):
 *
 * - Solange die Benachrichtigung sichtbar ist, hält [SyncKeepAliveService]
 *   den Prozess und damit die Sync-Verbindung am Leben – Änderungen anderer
 *   Geräte erscheinen sofort in der Benachrichtigung.
 * - Zusätzlich gleicht [BackgroundSyncWorker] etwa alle 15 Minuten ab, falls
 *   Android den Prozess trotzdem beendet hat (oder die Benachrichtigung
 *   gerade nicht angezeigt wird).
 */
object BackgroundSync {
    private const val PREFS_FILE = "antatime_background_sync"
    private const val KEY_ACTIVE = "active"
    private const val WORK_NAME = "background-sync"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    /** Sync eingerichtet und Hintergrund-Sync eingeschaltet (von Dart gemeldet). */
    fun isActive(context: Context): Boolean = prefs(context).getBoolean(KEY_ACTIVE, false)

    fun setActive(context: Context, active: Boolean) {
        val changed = isActive(context) != active
        if (changed) prefs(context).edit().putBoolean(KEY_ACTIVE, active).apply()
        val work = WorkManager.getInstance(context.applicationContext)
        if (active) {
            val request = PeriodicWorkRequestBuilder<BackgroundSyncWorker>(15, TimeUnit.MINUTES)
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
                )
                .build()
            work.enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        } else {
            work.cancelUniqueWork(WORK_NAME)
        }
        // Foreground-Service passend starten bzw. beenden.
        if (changed) TrackingNotification.refresh(context)
    }
}
