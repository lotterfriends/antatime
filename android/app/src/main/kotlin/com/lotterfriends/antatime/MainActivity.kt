package com.lotterfriends.antatime

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "antatime/notification"
        private var channel: MethodChannel? = null

        /** Teilt der Flutter-Seite mit, dass die Daten außerhalb geändert wurden. */
        fun notifyDataChanged() {
            channel?.invokeMethod("dataChanged", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "refresh" -> {
                        TrackingNotification.refresh(applicationContext)
                        result.success(null)
                    }
                    "scheduleReminders" -> {
                        val times = (call.arguments as? List<*>)
                            ?.mapNotNull { (it as? Number)?.toLong() }
                            ?: emptyList()
                        ReminderScheduler.setTimes(applicationContext, times)
                        result.success(null)
                    }
                    "scheduleTargetReminder" -> {
                        val targets = (call.arguments as? List<*>)
                            ?.mapNotNull { it as? String }
                            ?: emptyList()
                        TargetReminder.setTargets(applicationContext, targets)
                        result.success(null)
                    }
                    "cancel" -> {
                        TrackingNotification.cancel(applicationContext)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
