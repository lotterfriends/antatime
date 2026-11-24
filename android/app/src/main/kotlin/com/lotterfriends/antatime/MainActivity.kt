package com.lotterfriends.antatime

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    companion object {
        /** Teilt der Flutter-Seite mit, dass die Daten außerhalb geändert wurden. */
        fun notifyDataChanged() = AppEngine.notifyDataChanged()
    }

    /** Die gemeinsame Engine (siehe [AppEngine]), läuft womöglich schon. */
    override fun provideFlutterEngine(context: Context): FlutterEngine = AppEngine.obtain(context)

    /** Der Sync soll weiterlaufen, wenn das Fenster geschlossen wird. */
    override fun shouldDestroyEngineWithHost(): Boolean = false
}
