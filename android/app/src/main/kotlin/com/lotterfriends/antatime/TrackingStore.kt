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
        private const val KEY_ANIMATED_ICON = "animatedStatusIcon"

        /**
         * Wann eine Arbeitszeit hier (nativ) geändert wurde: `{id: ms}`. Der
         * Sync übernimmt diese Zeitpunkte, statt die Änderung erst beim
         * nächsten Öffnen der App zu datieren (sonst könnte sie eine
         * inzwischen auf einem anderen Gerät gemachte Änderung überschreiben).
         */
        const val KEY_NATIVE_CHANGES = "nativeChanges"

        /** Kürzere Unterbrechungen gelten nicht als Pause (wie `minBreak` in Dart). */
        private const val MIN_BREAK_MS = 60_000L

        private val isoLocal: DateTimeFormatter =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS")

        /** Lesen-Ändern-Schreiben der Arbeitszeiten (native Aktionen und Dart). */
        private val LOCK = Any()
    }

    /**
     * Ersetzt die Arbeitszeiten durch [value], aber nur, wenn sie noch dem von
     * Dart geladenen Stand [expected] entsprechen (`null` = nicht vorhanden).
     * Sonst hat eine Benachrichtigungs-Aktion sie inzwischen geändert, und
     * Dart führt beides zusammen, statt diese Änderung zu überschreiben.
     */
    /** Liefert die gemerkten nativen Änderungen (ID → ms) und vergisst sie. */
    fun takeNativeChanges(): Map<String, Long> {
        synchronized(LOCK) {
            val raw = prefs.getString(KEY_NATIVE_CHANGES, null) ?: return emptyMap()
            prefs.edit().remove(KEY_NATIVE_CHANGES).commit()
            return try {
                val o = JSONObject(raw)
                o.keys().asSequence().associateWith { o.optLong(it) }
            } catch (e: Exception) {
                emptyMap()
            }
        }
    }

    fun compareAndSetSessions(expected: String?, value: String): Boolean {
        synchronized(LOCK) {
            if (prefs.getString(KEY_SESSIONS, null) != expected) return false
            return prefs.edit().putString(KEY_SESSIONS, value).commit()
        }
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

    /**
     * Zeitpunkt aus `<name>Utc` (exakt, siehe WorkSession.toJson in Dart) oder
     * sonst aus der Ortszeit `<name>`; `null`, wenn keins von beiden da ist.
     */
    private fun time(o: JSONObject, name: String): Instant? {
        val utc = o.optString("${name}Utc").takeIf { it.isNotEmpty() && !o.isNull("${name}Utc") }
        if (utc != null) {
            try { return Instant.parse(utc) } catch (e: Exception) { /* Ortszeit versuchen */ }
        }
        val local = if (o.has(name) && !o.isNull(name)) o.getString(name) else return null
        return parse(local)
    }

    private fun isRunning(o: JSONObject) = !o.has("end") || o.isNull("end")

    private fun setEnd(o: JSONObject, end: Instant?) {
        if (end == null) {
            o.remove("end")
            o.remove("endUtc")
        } else {
            o.put("end", format(end))
            o.put("endUtc", end.toString())
        }
    }

    /** Merkt sich, wann [id] hier geändert wurde (siehe [KEY_NATIVE_CHANGES]). */
    private fun changed(edit: SharedPreferences.Editor, id: String, now: Instant) {
        val map = try {
            JSONObject(prefs.getString(KEY_NATIVE_CHANGES, null) ?: "{}")
        } catch (e: Exception) {
            JSONObject()
        }
        map.put(id, now.toEpochMilli())
        edit.putString(KEY_NATIVE_CHANGES, map.toString())
    }

    fun sessions(): List<Session> {
        val arr = sessionsJson()
        val result = ArrayList<Session>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            try {
                val start = time(o, "start") ?: continue
                result.add(Session(start, if (isRunning(o)) null else time(o, "end")))
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

    /**
     * Drehendes Symbol in der Statusleiste gewünscht (Einstellung „Animiertes
     * Symbol“, Standard: aus – die Animation lässt die Systemoberfläche
     * dauerhaft neu zeichnen).
     */
    fun animatedIcon(): Boolean = prefs.getString(KEY_ANIMATED_ICON, null) == "on"

    /** „Feierabend“ wurde heute gedrückt → Benachrichtigung bis zum nächsten Start ausblenden. */
    fun stoppedToday(): Boolean =
        prefs.getString(KEY_STOPPED_DAY, null) == LocalDate.now(zone).toString()

    /**
     * Start/Pause umschalten (wie `Repository.toggle` in Dart).
     * Gibt `true` zurück, wenn danach eine Arbeitszeit läuft.
     */
    fun toggle(now: Instant = Instant.now()): Boolean {
        synchronized(LOCK) { return toggleLocked(now) }
    }

    private fun toggleLocked(now: Instant): Boolean {
        val arr = sessionsJson()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (isRunning(o)) {
                setEnd(o, now)
                val edit = prefs.edit().putString(KEY_SESSIONS, arr.toString())
                changed(edit, o.optString("id"), now)
                edit.commit()
                return false
            }
        }
        // Pausen unter einer Minute ignorieren (wie in Dart): den zuletzt
        // beendeten Abschnitt fortsetzen statt einen neuen zu beginnen.
        var last: JSONObject? = null
        var lastEnd: Instant? = null
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            if (isRunning(o)) continue
            val end = try { time(o, "end") } catch (e: Exception) { null } ?: continue
            if (lastEnd == null || end.isAfter(lastEnd)) { last = o; lastEnd = end }
        }
        if (last != null && lastEnd != null) {
            val gap = now.toEpochMilli() - lastEnd.toEpochMilli()
            if (gap in 0 until MIN_BREAK_MS) {
                setEnd(last, null)
                val edit = prefs.edit()
                    .putString(KEY_SESSIONS, arr.toString())
                    .remove(KEY_STOPPED_DAY)
                changed(edit, last.optString("id"), now)
                edit.commit()
                return true
            }
        }
        val id = (now.toEpochMilli() * 1000).toString(36) +
            Random.nextLong(0, 1L shl 32).toString(36)
        arr.put(
            JSONObject().put("id", id)
                .put("start", format(now))
                .put("startUtc", now.toString())
        )
        val edit = prefs.edit()
            .putString(KEY_SESSIONS, arr.toString())
            .remove(KEY_STOPPED_DAY)
        changed(edit, id, now)
        edit.commit()
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

    /** Wurde heute schon gestartet (oder läuft eine Arbeitszeit)? Wie `startedOn` in Dart. */
    fun startedToday(): Boolean {
        val today = LocalDate.now(zone)
        return sessions().any { it.end == null || it.start.atZone(zone).toLocalDate() == today }
    }

    /** Arbeitszeit starten, falls keine läuft. */
    fun start(now: Instant = Instant.now()) {
        if (running() == null) toggle(now)
    }
}
