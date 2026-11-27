package com.lotterfriends.antatime

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine

/**
 * Play-Variante: Updates kommen aus dem Play Store. Die App lädt und
 * installiert nichts selbst (siehe src/github für die APK-Variante); die
 * Flutter-Seite blendet die Update-Einstellungen aus (UpdateService.supported).
 */
object AppUpdate {
    @Suppress("UNUSED_PARAMETER")
    fun register(app: Context, engine: FlutterEngine) = Unit
}
