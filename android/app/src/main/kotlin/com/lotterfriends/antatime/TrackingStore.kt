package com.lotterfriends.antatime

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.random.Random

/**
 * Zugriff auf die Daten der App aus dem nativen Teil (Benachrichtigungs-Aktionen).
 *
 * Die Flutter-Seite speichert über `shared_preferences` mit dem
 * SharedPreferences-Backend in derselben Datei (siehe lib/repository.dart),
 * Werte sind JSON-Strings.
 */
class TrackingStore(context: Context) {
    companion object {
        const val PREFS_FILE = "antatime"
        private const val KEY_SESSIONS = "sessions"
        private const val KEY_SETTINGS = "settings"
        const val KEY_STOPPED_DAY = "notificationStoppedDay"

        private val isoLocal: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS")
    }

    data class Session(val start: Instant, val end: Instant?)

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    private val zone: ZoneId get() = ZoneId.systemDefault()

    private fun sessionsJson(): JSONArray =
        try {
            JSONArray(prefs.getString(KEY_SESSIONS, null) ?: "[]")
        } catch (e: Exception) {
            JSONArray()
        }

    /** Dart schreibt lokale Zeiten ohne Zone (`DateTime.toIso8601String`). */
    private fun parse(value: String): Instant =
        try {
            LocalDateTime.parse(value).atZone(zone).toInstant()
        } catch (e: Exception) {
            OffsetDateTime.parse(value).toInstant()
        }

    private fun format(instant: Instant): String =
        LocalDateTime.ofInstant(instant, zone).format(isoLocal)

    fun sessions(): List<Session> {
        val arr = sessionsJson()
        val result = ArrayList<Session>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            val start = o.optString("start").takeIf { it.isNotEmpty() } ?: continue
            val end = if (o.has("end") && !o.isNull("end")) o.getString("end") else null
            try {
                result.add(Session(parse(start), end?.let { parse(it) }))
            } catch (e: Exception) {
                // Ungültigen Eintrag überspringen
            }
        }
        return result
    }

    fun showNotification(): Boolean =
        try {
            JSONObject(prefs.getString(KEY_SETTINGS, null) ?: "{}")
                .optBoolean("showNotification", true)
        } catch (e: Exception) {
            true
        }

    /** „Feierabend“ wurde heute gedrückt → Benachrichtigung bis zum nächsten Start ausblenden. */
    fun stoppedToday(): Boolean =
        prefs.getString(KEY_STOPPED_DAY, null) == LocalDate.now(zone).toString()

    /**
     * Start/Pause umschalten (wie `Repository.toggle` in Dart).
     * Gibt `true` zurück, wenn danach eine Arbeitszeit läuft.
     */
    fun toggle(now: Instant = Instant.now()): Boolean {
        val arr = sessionsJson()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (!o.has("end") || o.isNull("end")) {
                o.put("end", format(now))
                prefs.edit().putString(KEY_SESSIONS, arr.toString()).commit()
                return false
            }
        }
        val id = (now.toEpochMilli() * 1000).toString(36) +
            Random.nextLong(0, 1L shl 32).toString(36)
        arr.put(JSONObject().put("id", id).put("start", format(now)))
        prefs.edit()
            .putString(KEY_SESSIONS, arr.toString())
            .remove(KEY_STOPPED_DAY)
            .commit()
        return true
    }

    /** Laufende Arbeitszeit beenden und die Benachrichtigung für heute ausblenden. */
    fun stop(now: Instant = Instant.now()) {
        if (sessions().any { it.end == null }) toggle(now)
        prefs.edit().putString(KEY_STOPPED_DAY, LocalDate.now(zone).toString()).commit()
    }

    /** Heute gearbeitete Zeit in ms (Arbeitszeiten über Mitternacht anteilig). */
    fun workedTodayMs(now: Instant = Instant.now()): Long {
        val today = LocalDate.now(zone)
        val dayStart = today.atStartOfDay(zone).toInstant()
        val dayEnd = today.plusDays(1).atStartOfDay(zone).toInstant()
        var total = 0L
        for (s in sessions()) {
            val start = maxOf(s.start, dayStart)
            val end = minOf(s.end ?: now, dayEnd)
            if (end.isAfter(start)) total += end.toEpochMilli() - start.toEpochMilli()
        }
        return total
    }

    /** Ende der letzten Arbeitszeit von heute (für die Pausen-Anzeige). */
    fun lastEndToday(): Instant? {
        val dayStart = LocalDate.now(zone).atStartOfDay(zone).toInstant()
        return sessions().mapNotNull { it.end }.filter { !it.isBefore(dayStart) }.maxOrNull()
    }

    fun running(): Session? = sessions().firstOrNull { it.end == null }
}
