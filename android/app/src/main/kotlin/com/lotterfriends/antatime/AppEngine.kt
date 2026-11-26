package com.lotterfriends.antatime

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Die eine Flutter-Engine der App – geteilt zwischen [MainActivity],
 * [SyncKeepAliveService] und [BackgroundSyncWorker].
 *
 * Der Sync läuft im Dart-Teil. Damit Änderungen anderer Geräte auch bei
 * geschlossenem Fenster ankommen (und die Benachrichtigung aktualisieren),
 * darf die Engine nicht mit der Activity enden. Es gibt immer nur eine
 * Engine (also nur einen Sync-Client); die Activity hängt sich beim Öffnen
 * an die bereits laufende an.
 */
object AppEngine {
    private const val ENGINE_ID = "main"
    private const val CHANNEL = "antatime/notification"

    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var channel: MethodChannel? = null

    /** Liefert die laufende Engine oder startet sie (nur im Main-Thread). */
    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result -> handle(app, call.method, call.arguments, result) }
        }
        AppUpdate.register(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }

    /** Läuft die Engine (und damit der Sync) in diesem Prozess bereits? */
    val isRunning: Boolean get() = FlutterEngineCache.getInstance().contains(ENGINE_ID)

    /** Teilt der Flutter-Seite mit, dass die Daten außerhalb geändert wurden. */
    fun notifyDataChanged() {
        main.post { channel?.invokeMethod("dataChanged", null) }
    }

    /**
     * Bittet die Flutter-Seite, sich neu mit dem Server zu verbinden und den
     * aktuellen Stand zu holen. [done] wird im Main-Thread aufgerufen, sobald
     * das erledigt ist (oder es fehlschlug).
     */
    fun syncNow(done: () -> Unit) {
        main.post {
            val ch = channel
            if (ch == null) {
                done()
                return@post
            }
            ch.invokeMethod("syncNow", null, object : MethodChannel.Result {
                override fun success(result: Any?) = done()
                override fun error(code: String, message: String?, details: Any?) = done()
                override fun notImplemented() = done()
            })
        }
    }

    /** Warten auf den ersten Abgleich nach dem Start der Engine (Main-Thread). */
    private val syncedWaiters = mutableListOf<() -> Unit>()
    private var syncedOnce = false

    /**
     * [done] läuft im Main-Thread, sobald die Flutter-Seite nach dem Start
     * den Stand des Servers übernommen hat (oder aufgegeben hat).
     */
    fun onSynced(done: () -> Unit) {
        main.post {
            if (syncedOnce) done() else syncedWaiters.add(done)
        }
    }

    private fun handle(app: Context, method: String, args: Any?, result: MethodChannel.Result) {
        when (method) {
            "synced" -> {
                syncedOnce = true
                val waiters = syncedWaiters.toList()
                syncedWaiters.clear()
                waiters.forEach { it() }
                result.success(null)
            }
            "refresh" -> {
                TrackingNotification.refresh(app)
                result.success(null)
            }
            "scheduleReminders" -> {
                val times = (args as? List<*>)
                    ?.mapNotNull { (it as? Number)?.toLong() }
                    ?: emptyList()
                ReminderScheduler.setTimes(app, times)
                result.success(null)
            }
            "scheduleTargetReminder" -> {
                val targets = (args as? List<*>)
                    ?.mapNotNull { it as? String }
                    ?: emptyList()
                TargetReminder.setTargets(app, targets)
                result.success(null)
            }
            "casSessions" -> {
                val list = args as? List<*>
                val value = list?.getOrNull(1) as? String
                if (value == null) {
                    result.error("args", "Erwartet [expected, value]", null)
                } else {
                    result.success(
                        TrackingStore(app).compareAndSetSessions(list[0] as? String, value)
                    )
                }
            }
            "takeNativeChanges" -> {
                result.success(TrackingStore(app).takeNativeChanges())
            }
            "setBackgroundSync" -> {
                BackgroundSync.setActive(app, args as? Boolean ?: false)
                result.success(null)
            }
            "cancel" -> {
                TrackingNotification.cancel(app)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
