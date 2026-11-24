package com.lotterfriends.antatime

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.concurrent.futures.CallbackToFutureAdapter
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.google.common.util.concurrent.ListenableFuture

/**
 * Regelmäßiger Abgleich (siehe [BackgroundSync]): startet bei Bedarf die
 * Flutter-Engine und lässt sie den aktuellen Stand vom Server holen. Die
 * Benachrichtigung aktualisiert sich dabei über den normalen Weg.
 */
class BackgroundSyncWorker(context: Context, params: WorkerParameters) :
    ListenableWorker(context, params) {

    private companion object {
        /** Höchstens so lange auf den Abgleich warten. */
        const val TIMEOUT_MS = 45_000L
    }

    override fun startWork(): ListenableFuture<Result> =
        CallbackToFutureAdapter.getFuture { completer ->
            val app = applicationContext
            val main = Handler(Looper.getMainLooper())
            var finished = false
            fun finish() {
                if (finished) return
                finished = true
                // Zeiten aktualisieren und ggf. den Foreground-Service starten
                // (gelingt aus dem Hintergrund nicht immer, dann bleibt es so).
                TrackingNotification.refresh(app)
                completer.set(Result.success())
            }
            main.post {
                when {
                    !BackgroundSync.isActive(app) -> finish()
                    // Die Verbindung wird bereits gehalten.
                    SyncKeepAliveService.isRunning && AppEngine.isRunning -> finish()
                    else -> {
                        val fresh = !AppEngine.isRunning
                        AppEngine.obtain(app)
                        if (fresh) {
                            // Die frisch gestartete App verbindet sich selbst und
                            // meldet sich, sobald der Stand übernommen ist.
                            AppEngine.onSynced { finish() }
                        } else {
                            AppEngine.syncNow { finish() }
                        }
                        main.postDelayed({ finish() }, TIMEOUT_MS)
                    }
                }
            }
            "BackgroundSyncWorker"
        }
}
