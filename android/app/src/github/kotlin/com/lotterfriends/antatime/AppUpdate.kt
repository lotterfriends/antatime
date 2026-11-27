package com.lotterfriends.antatime

import android.content.Context
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** Eigene Klasse, damit sich der Eintrag im Manifest mit keinem Plugin überschneidet. */
class UpdateFileProvider : FileProvider()

/**
 * Updates ohne Play Store: Die Flutter-Seite (lib/update/) lädt die APK in
 * den Cache der App und prüft sie; hier wird sie dem Paketinstaller des
 * Systems übergeben. Der fragt den Benutzer und lässt nur APKs zu, die mit
 * demselben Schlüssel signiert sind wie die installierte App.
 */
object AppUpdate {
    private const val CHANNEL = "antatime/update"
    private const val APK_TYPE = "application/vnd.android.package-archive"

    fun register(app: Context, engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "dir" -> result.success(dir(app).absolutePath)
                "install" -> {
                    val file = (call.arguments as? String)?.let { File(it).canonicalFile }
                    // Nur Dateien aus dem eigenen Update-Verzeichnis.
                    if (file == null || !file.isFile || file.parentFile != dir(app).canonicalFile) {
                        result.error("file", "Die heruntergeladene Datei fehlt", null)
                        return@setMethodCallHandler
                    }
                    try {
                        install(app, file)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("install", "Der Paketinstaller ließ sich nicht öffnen", e.message)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun dir(app: Context): File = File(app.cacheDir, "updates").apply { mkdirs() }

    private fun install(app: Context, file: File) {
        val uri = FileProvider.getUriForFile(app, "${app.packageName}.updates", file)
        app.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, APK_TYPE)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}
