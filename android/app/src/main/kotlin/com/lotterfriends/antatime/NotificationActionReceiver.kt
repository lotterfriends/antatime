package com.lotterfriends.antatime

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Verarbeitet Start/Pause und Feierabend aus der Benachrichtigung – auch bei geschlossener App. */
class NotificationActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_TOGGLE = "com.lotterfriends.antatime.TOGGLE"
        const val ACTION_STOP = "com.lotterfriends.antatime.STOP"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val store = TrackingStore(context)
        when (intent.action) {
            ACTION_TOGGLE -> store.toggle()
            ACTION_STOP -> store.stop()
            else -> return
        }
        TrackingNotification.refresh(context)
        // Geöffnete App sofort aktualisieren.
        MainActivity.notifyDataChanged()
    }
}
