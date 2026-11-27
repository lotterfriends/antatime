# Play Console – Angaben für AnTaTime (`de.antatime`)

Vorlagen zum Übernehmen in die Play Console. Die Dateien daneben:

| Datei | Wohin in der Console |
| --- | --- |
| `de-DE/title.txt`, `short-description.txt`, `full-description.txt` | Mehr Nutzer gewinnen → Store-Präsenz → Hauptstore-Eintrag |
| `icon-512.png`, `feature-graphic-1024x500.png`, `screenshots/*.png` | ebenda, Abschnitt „Grafiken“ (Screenshots unter „Smartphone“) |
| `foreground-service-demo.mp4` | bei einem Videodienst hochladen (z. B. YouTube, „nicht gelistet“); die Console nimmt nur einen Link |
| `../../dist/antatime-<version>-play.aab` | Testen und veröffentlichen → Test → Interner/Geschlossener Test → Neuer Release |

## App-Inhalte

Zu finden unter **Richtlinien und Programme → App-Inhalte** (unten in der linken Leiste; alternativ über die Aufgabenliste „App einrichten“ im Dashboard).

| Erklärung | Angabe |
| --- | --- |
| Datenschutzerklärung | `https://antatime.de/datenschutz.html` |
| App-Zugriff | Alle Funktionen ohne besondere Zugriffsrechte verfügbar (kein Login) |
| Werbung | Nein, die App enthält keine Werbung |
| Altersfreigabe (Fragebogen) | Kategorie „Dienstprogramm, Produktivität, Kommunikation oder Sonstiges“; alle Fragen zu Gewalt, Sexualität, Sprache, Drogen, Glücksspiel: Nein; kein Austausch zwischen Nutzern, keine Standortfreigabe, keine Käufe |
| Zielgruppe | 18 Jahre und älter (Arbeitszeiterfassung; nicht an Kinder gerichtet) |
| Nachrichten-App | Nein |
| Gesundheits-Apps / Finanzfunktionen / Behörden-App | Nein / keine |
| Werbe-ID | Nein, die App verwendet keine Werbe-ID |

### Datensicherheit

- Erhebt oder teilt die App erforderliche Nutzerdatentypen? **Nein.**
  Begründung nach den Regeln von Google: Daten, die nur auf dem Gerät verarbeitet werden, zählen nicht als erhoben; Ende-zu-Ende-verschlüsselte Daten, die weder Entwickler noch Server lesen können, ebenfalls nicht. Die IP-Adresse wird nur kurzzeitig zum Schutz vor Überlastung verarbeitet.
- Falls die Console trotzdem Folgefragen stellt: Daten werden bei der Übertragung verschlüsselt: **Ja**. Nutzer können das Löschen ihrer Daten veranlassen: **Ja** (in der App: Einstellungen → Synchronisation → Synchronisation beenden → Auch auf dem Server löschen).
- Kontoerstellung: Die App hat **keine Konten**, die Frage zur Kontolöschung entfällt.

### Dienste im Vordergrund (`FOREGROUND_SERVICE_SPECIAL_USE`)

Typ: **Sonstiges / Special use**. Videolink: Link zu `foreground-service-demo.mp4`.

Beschreibung (Englisch, zum Einfügen):

> AnTaTime is a working-time tracker. While time tracking is active, the app shows an ongoing notification with Start/Pause/Stop controls. If the user has enabled the optional end-to-end encrypted sync between their own devices, the foreground service (SyncKeepAliveService, bound to exactly this notification) keeps the app process and its WebSocket sync connection alive, so that pressing Start or Pause on another device (desktop, browser, second phone) is reflected in the notification immediately – the user sees the correct tracking state and elapsed time without opening the app.
>
> The service runs only while that notification is visible and only if sync is set up. It is user-initiated (the user starts tracking and enables sync), user-perceptible (the ongoing notification), and can be stopped at any time by ending tracking or by switching off Settings → Synchronisation → "Im Hintergrund synchronisieren".
>
> No other foreground service type fits: the task is not a one-off data transfer (dataSync), it is an open-ended real-time connection without Firebase/push infrastructure, because the server only ever sees end-to-end encrypted data and cannot send meaningful push messages. Deferring the work with WorkManager (which the app additionally uses every 15 minutes as a fallback) would leave the notification showing a wrong state (e.g. "running" although the user paused on their desktop) for up to 15 minutes.

## Geschlossener Test (Pflicht für neue private Entwicklerkonten)

1. Interner Test: AAB hochladen, selbst installieren und prüfen.
2. Geschlossener Test: mindestens 12 Tester per E-Mail-Liste oder Google-Gruppe einladen; sie müssen dem Test beitreten und 14 Tage ununterbrochen angemeldet bleiben.
3. Danach im Dashboard „Produktionszugriff beantragen“ und die Fragen zum Test beantworten.

## App-Signatur

Beim ersten Release unter „App-Signatur“ → „Anderen Schlüssel verwenden“ → „Schlüssel aus Java-Keystore exportieren und hochladen“ wählen und den vorhandenen Release-Key (Zertifikat `O=lotterfriends, CN=AnTaTime`) hochladen. Die Console zeigt dazu den genauen Befehl für das PEPK-Werkzeug an. Derselbe Schlüssel bleibt dann Upload-Schlüssel, `scripts/build_android.sh` signiert das AAB bereits damit.
