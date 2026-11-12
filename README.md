# AnTaTime

Arbeitszeiterfassung mit Stundenkonto – als Flutter-App für **Android**, **iPhone (iOS)**, den **Browser** und als **Desktop-App** für **Linux**, **Windows** und **macOS**.

## Funktionen

- **Start / Pause** der Arbeitszeit pro Tag – in der App und direkt im **Benachrichtigungsbereich** (Android & iOS) bzw. im **Infobereich (Tray)** der Desktop-Version
- Die Zeit zwischen zwei Arbeitszeiten an einem Tag wird als **Pause** gewertet
- **Erinnerung zum Start** (Android & iOS): In den Einstellungen eine Uhrzeit wählen – an Arbeitstagen (ohne Feiertage und Abwesenheiten) kommt dann eine Benachrichtigung, falls die Zeiterfassung noch nicht gestartet wurde, mit „Starten“-Aktion. Die Einstellung gilt je Gerät und wird nicht synchronisiert
- **Erinnerung bei Erreichen der Tagesstunden** (Android, iOS & Desktop, standardmäßig an): Sobald an einem Arbeitstag (ohne Feiertage und Abwesenheiten) die Tagesstunden erreicht sind, kommt eine Benachrichtigung mit „Feierabend“-Aktion. Pausen verschieben die Erinnerung entsprechend. Die Einstellung gilt je Gerät und wird nicht synchronisiert
- **Stundenkonto** mit frei wählbarem Startwert (Standard 0) und Erfassungsbeginn
- **Wochenstunden** und **Tagesstunden** (beide änderbar, sie werden über die Anzahl der Arbeitstage abgeglichen)
- **Arbeitstage** frei wählbar (z. B. Mo–Fr)
- **Abwesenheiten** (Krank, Urlaub, Andere Abwesenheit) für einzelne Tage oder Zeiträume – zählen an Arbeitstagen wie ein voll gearbeiteter Tag
- **Feiertage:** In den Einstellungen ein Bundesland wählen – die gesetzlichen Feiertage stehen dann automatisch in den Abwesenheiten (für jedes Jahr berechnet, auch rückwirkend) und zählen an Arbeitstagen wie ein voll gearbeiteter Tag. Nur landesweite Feiertage; regionale (z. B. Mariä Himmelfahrt in Teilen Bayerns) bei Bedarf als Abwesenheit eintragen
- **Nacherfassen** und **Bearbeiten/Löschen** von Arbeitszeiten (inkl. Prüfung auf Überschneidungen, über Mitternacht möglich)
- Verlauf pro Monat mit Tages- und Monatssaldo
- **Synchronisation** (optional) zwischen mehreren Geräten über einen eigenen [AnTaTime-Server](../antatime-server) – Ende-zu-Ende-verschlüsselt, Änderungen erscheinen sofort auf allen offenen Geräten (siehe unten). Nach Netzwerkwechseln oder Unterbrechungen verbindet sich die App selbst neu; im Browser hält nur ein Tab die Verbindung, die anderen übernehmen dessen Änderungen
- **Export / Import** aller Arbeitszeiten, Abwesenheiten und Einstellungen als JSON-Datei (Einstellungen → Daten). Der Import ersetzt alle vorhandenen Daten.

### Berechnung des Stundenkontos

```
Stundenkonto = Startwert + Σ (gearbeitet × Faktor + Abwesenheits-Gutschrift − Soll) je Tag ab Erfassungsbeginn
```

- Soll an Arbeitstagen = Tagesstunden, an freien Tagen = 0 (Arbeit dort zählt komplett als Plus)
- Arbeitstag ohne Eintrag → die Tagesstunden gehen ins Minus
- Arbeit an Feiertagen, im Urlaub oder bei anderer Abwesenheit zählt komplett als Überstunden – mit einstellbarem **Faktor** (Standard 1, z. B. 1,5 oder 2 = jede Stunde zählt anderthalb- bzw. doppelt). Bei Krankheit gilt immer Faktor 1
- Beispiel: 8 h Soll, 9 h gearbeitet → +1 h; 7 h gearbeitet → −1 h
- **Heute** zählt erst nach Tagesende negativ, Überstunden von heute werden sofort angerechnet
- Änderungen an Tages-/Wochenstunden oder Arbeitstagen gelten rückwirkend für den gesamten Zeitraum

Die Daten werden lokal auf dem Gerät gespeichert (im Browser im `localStorage`, unter Linux in `~/.local/share/com.lotterfriends.antatime/`).

## Icons

App- und Statusleisten-Icons werden mit `python3 scripts/generate_icons.py` erzeugt (benötigt ImageMagick). Das Logo kombiniert die Material Design Icons „timer-outline“ und „wrench“ (Apache License 2.0, [pictogrammers.com](https://pictogrammers.com)) auf der Akzentfarbe `#00796B`.

## Entwicklung

Voraussetzung: [Flutter](https://docs.flutter.dev/get-started/install) (getestet mit 3.47.9).

```bash
flutter pub get
flutter run            # Gerät/Emulator wählen
flutter run -d chrome  # Browser
flutter run -d linux   # Desktop (bzw. -d windows / -d macos)
```

Für Linux-Desktop-Builds werden zusätzlich benötigt (Debian/Ubuntu):

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libayatana-appindicator3-dev
```

### Lokal im Browser starten

Mit installiertem Chrome/Chromium öffnet `flutter run -d chrome` die App direkt.
Ohne Chrome (z. B. nur Firefox) startet ein lokaler Webserver:

```bash
flutter run -d web-server --web-port 8080 --web-hostname localhost
```

Danach im Browser **http://localhost:8080** öffnen, sobald
„lib/main.dart is being served at …“ erscheint. Im Terminal lädt `r` die App
nach Codeänderungen neu, `R` startet sie neu, `q` beendet den Server
(anschließend im Browser die Seite neu laden).

Hinweise:
- Die Daten liegen im `localStorage` des Browsers, getrennt von der
  Android-/iOS-App (Übertragung per Export/Import oder Synchronisation).
- Die Benachrichtigung mit Start/Pause gibt es im Browser nicht.

## Pakete bauen

Die Skripte in `scripts/` werden sowohl lokal als auch von GitHub Actions verwendet. Ergebnisse landen in `dist/`.

| Skript | Ergebnis | Voraussetzung |
| --- | --- | --- |
| `scripts/test.sh` | Analyse + Tests | Flutter |
| `scripts/build_android.sh` | `dist/antatime-<version>.apk` | Flutter, Android SDK, JDK 17 |
| `scripts/build_web.sh` | `build/web`, `dist/antatime-web-<version>.zip` | Flutter |
| `scripts/build_ios.sh` | `dist/antatime-<version>-unsigned.ipa` | macOS, Xcode |
| `scripts/build_linux.sh` | `dist/antatime-<version>-linux-x64.tar.gz`, `dist/antatime_<version>_amd64.deb`, `dist/AnTaTime-<version>-x86_64.AppImage` | Linux, Pakete s. o., `dpkg-deb`; appimagetool wird bei Bedarf geladen |
| `scripts/build_windows.sh` | `dist/antatime-<version>-windows-x64.zip`, `dist/AnTaTime-<version>-windows-x64-setup.exe` | Windows (Git Bash), Visual Studio 2022 (C++), optional Inno Setup 6 |
| `scripts/build_macos.sh` | `dist/AnTaTime-<version>-macos.dmg`, `dist/AnTaTime-<version>-macos.zip` | macOS, Xcode |
| `scripts/build_all.sh` | alles, was auf dem System möglich ist | |

Optionen über Umgebungsvariablen:

- `FLUTTER=/pfad/zu/flutter` – anderes Flutter-Binary verwenden
- `SYNC_URL=antatime.de` – Sync-Server, der beim Einrichten der Synchronisation vorausgefüllt ist (in GitHub Actions aus der Repository-Variable `SYNC_URL`)
- `BASE_HREF=/antatime/` – Unterpfad für die Web-App (z. B. GitHub Pages)
- `SKIP_DEB=1`, `SKIP_APPIMAGE=1` – einzelne Linux-Pakete auslassen
- `IOS_SIGN=1` – signiertes IPA über `flutter build ipa` (Apple-Developer-Account in Xcode nötig)
- Android-Release-Signatur: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (oder eigene `android/key.properties`). Ohne diese wird mit dem Debug-Key signiert.

Keystore erzeugen und für das Secret kodieren:

Ohne Java geht es auch mit OpenSSL (PKCS12, Alias `antatime`, Key-Passwort = Keystore-Passwort):

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 10950 -subj "/CN=AnTaTime"
openssl pkcs12 -export -inkey key.pem -in cert.pem -name antatime -out release.keystore
rm key.pem cert.pem
```

```bash
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias antatime
base64 -w0 release.jks   # Inhalt als Secret ANDROID_KEYSTORE_BASE64 hinterlegen
```

## GitHub Actions

`.github/workflows/build.yml` läuft bei Push auf `main`, Pull Requests, Tags `v*` und manuell:

1. **test** – `scripts/test.sh`
2. **android** – APK als Artefakt `android-apk`
3. **web** – Web-Build als Artefakt `web`
4. **ios** – unsigniertes IPA als Artefakt `ios-unsigned-ipa` (macOS-Runner). **Optional:** schlägt der Job fehl (z. B. weil GitHub keinen macOS-Runner bereitstellt), bleibt der Lauf grün und das Release wird ohne IPA erstellt. Mit der Repository-Variable `SKIP_IOS=true` wird iOS ganz übersprungen
5. **linux** – tar.gz, .deb und AppImage als Artefakt `linux`
6. **windows** – Installer und Zip als Artefakt `windows`
7. **macos** – DMG und Zip als Artefakt `macos` (unsigniert). Wie iOS **optional**; abschalten mit `SKIP_MACOS=true`
8. **release** – bei Tags `v*` ein GitHub-Release mit allen Paketen (Android, Web, Linux und Windows müssen erfolgreich sein)
9. **pages** (optional) – Web-App auf GitHub Pages: unter *Settings → Pages* die Quelle „GitHub Actions“ wählen und die Repository-Variable `DEPLOY_PAGES=true` setzen

Für signierte Android-Releases die vier `ANDROID_*`-Werte als Repository-Secrets anlegen. **Wichtig:** Ohne diese Secrets signiert jeder CI-Lauf mit einem neuen Debug-Key – eine bereits installierte App lässt sich dann nicht per Update überschreiben (nur deinstallieren und neu installieren, Daten vorher exportieren). Der `versionCode` wird in CI aus der Lauf-Nummer gesetzt.

## Plattform-Hinweise

- **Android:** Eigene Benachrichtigung (nativ, `android/app/src/main/kotlin/…`): „Derzeit“ und „Heute“ laufen live mit, Start/Pause und Feierabend (■) als Symbol-Schaltflächen. In der Statusleiste dreht sich bei laufender Zeit ein Pfeil um die Uhr, pausiert erscheint eine Stoppuhr mit Pause-Symbol. „Feierabend“ beendet die laufende Zeit und blendet die Benachrichtigung bis zum nächsten Start aus. Ab Android 13 fragt die App beim ersten Start nach der Benachrichtigungs-Berechtigung.
- **iOS:** Start/Pause über die Aktion der Benachrichtigung (lange drücken bzw. aufziehen). Eine Live-Uhr in der Benachrichtigung ist auf iOS nicht möglich. Für die Installation auf einem iPhone muss das IPA signiert werden.
- **Web:** Kein Benachrichtigungsbereich, die Steuerung erfolgt in der App.
- **Desktop (Linux, Windows, macOS):** Steuerung über ein Symbol im **Infobereich** (Tray, `lib/tray_service.dart`), ohne Animationen: laufend Uhr mit Pfeil (grün), pausiert Stoppuhr mit Pause (grau; macOS: Symbol passend zur Menüleiste). Das Menü zeigt „Derzeit“ bzw. „Pause“ und „Heute … von …“ (minutengenau) und bietet Start/Pause, Feierabend, Öffnen und Beenden. Unter Windows öffnet ein Linksklick das Fenster, ein Rechtsklick das Menü. Solange das Symbol aktiv ist, schließt das Fenster nur in den Infobereich; beendet wird über „Beenden“. Abschaltbar unter Einstellungen → Infobereich (dann beendet das Schließen die App).
- **Autostart (Desktop):** Einstellungen → Programmstart → „Mit dem System starten“ (`lib/desktop/autostart_io.dart`). Linux legt `~/.config/autostart/com.lotterfriends.antatime.desktop` an (beim AppImage mit Pfad zur AppImage-Datei), Windows einen Eintrag unter `HKCU\…\CurrentVersion\Run`, macOS (ab 13) ein Anmeldeobjekt. Beim Autostart startet die App nur im Infobereich (ohne Tray-Symbol mit Fenster) und fragt per Benachrichtigung „Zeiterfassung starten?“ – „Jetzt starten“ startet die Arbeitszeit direkt, ein Klick auf die Benachrichtigung öffnet das Fenster (`lib/desktop/start_prompt.dart`). macOS kann Anmeldeobjekten keine Argumente mitgeben; dort gilt ein Start in den ersten 5 Minuten nach dem Hochfahren als Autostart.
- **Zeiterfassung beim Start beginnen (Desktop, standardmäßig aus):** Einstellungen → Programmstart. Beim Öffnen der App startet die Arbeitszeit automatisch an Arbeitstagen (nicht an Feiertagen, bei Abwesenheit und nach Feierabend), mit „Immer beginnen“ bei jedem Start. Mit „Nur bis“ lässt sich eine Uhrzeit festlegen, nach der an Arbeitstagen nicht mehr automatisch gestartet wird; „Immer beginnen“ gilt unabhängig davon. Beim Einschalten von „Mit dem System starten“ fragt die App, ob die Zeiterfassung dann auch gleich beginnen soll; die Startfrage per Benachrichtigung entfällt in dem Fall. Gilt je Gerät und wird nicht synchronisiert (`lib/auto_track.dart`).
- **Einfarbige Tray-Symbole (Linux, Windows):** Einstellungen → Infobereich → „Darstellung des Symbols“: farbig (Standard), einfarbig hell für dunkle oder einfarbig dunkel für helle Leisten. Gilt je Gerät (`lib/tray_icon_style.dart`).
  - Linux nutzt AppIndicator (KDE, Xfce, Cinnamon, MATE, Ubuntu). Unter GNOME ohne Ubuntu-Anpassungen ist dafür die Erweiterung „AppIndicator and KStatusNotifierItem Support“ nötig. Ein erneuter Start der App holt das versteckte Fenster immer zurück.
  Installation:
  - **Linux:** `sudo apt install ./antatime_<version>_amd64.deb` (Debian/Ubuntu/Mint), oder auf jeder Distribution das AppImage ausführbar machen und starten (`chmod +x AnTaTime-*.AppImage`), oder das tar.gz entpacken und `antatime/antatime` starten.
  - **Windows:** `AnTaTime-<version>-windows-x64-setup.exe` ausführen (ohne Administratorrechte möglich) oder das Zip entpacken und `antatime.exe` starten. Da der Installer nicht signiert ist, warnt SmartScreen beim ersten Start („Weitere Informationen → Trotzdem ausführen“).
  - **macOS:** DMG öffnen und AnTaTime in „Programme“ ziehen. Die App ist nicht notarisiert: beim ersten Start Rechtsklick → „Öffnen“ oder `xattr -dr com.apple.quarantine /Applications/AnTaTime.app`.
