# AnTaTime

Arbeitszeiterfassung mit Stundenkonto – als Flutter-App für **Android**, **iPhone (iOS)** und den **Browser**.

## Funktionen

- **Start / Pause** der Arbeitszeit pro Tag – in der App und direkt im **Benachrichtigungsbereich** (Android & iOS)
- Die Zeit zwischen zwei Arbeitszeiten an einem Tag wird als **Pause** gewertet
- **Stundenkonto** mit frei wählbarem Startwert (Standard 0) und Erfassungsbeginn
- **Wochenstunden** und **Tagesstunden** (beide änderbar, sie werden über die Anzahl der Arbeitstage abgeglichen)
- **Arbeitstage** frei wählbar (z. B. Mo–Fr)
- **Abwesenheiten** (Krank, Urlaub, Andere Abwesenheit) für einzelne Tage oder Zeiträume – zählen an Arbeitstagen wie ein voll gearbeiteter Tag
- **Nacherfassen** und **Bearbeiten/Löschen** von Arbeitszeiten (inkl. Prüfung auf Überschneidungen, über Mitternacht möglich)
- Verlauf pro Monat mit Tages- und Monatssaldo

### Berechnung des Stundenkontos

```
Stundenkonto = Startwert + Σ (gearbeitet + Abwesenheits-Gutschrift − Soll) je Tag ab Erfassungsbeginn
```

- Soll an Arbeitstagen = Tagesstunden, an freien Tagen = 0 (Arbeit dort zählt komplett als Plus)
- Arbeitstag ohne Eintrag → die Tagesstunden gehen ins Minus
- Beispiel: 8 h Soll, 9 h gearbeitet → +1 h; 7 h gearbeitet → −1 h
- **Heute** zählt erst nach Tagesende negativ, Überstunden von heute werden sofort angerechnet
- Änderungen an Tages-/Wochenstunden oder Arbeitstagen gelten rückwirkend für den gesamten Zeitraum

Die Daten werden lokal auf dem Gerät gespeichert (im Browser im `localStorage`).

## Entwicklung

Voraussetzung: [Flutter](https://docs.flutter.dev/get-started/install) (getestet mit 3.47.9).

```bash
flutter pub get
flutter run            # Gerät/Emulator wählen
flutter run -d chrome  # Browser
```

## Pakete bauen

Die Skripte in `scripts/` werden sowohl lokal als auch von GitHub Actions verwendet. Ergebnisse landen in `dist/`.

| Skript | Ergebnis | Voraussetzung |
| --- | --- | --- |
| `scripts/test.sh` | Analyse + Tests | Flutter |
| `scripts/build_android.sh` | `dist/antatime-<version>.apk` | Flutter, Android SDK, JDK 17 |
| `scripts/build_web.sh` | `build/web`, `dist/antatime-web-<version>.zip` | Flutter |
| `scripts/build_ios.sh` | `dist/antatime-<version>-unsigned.ipa` | macOS, Xcode |
| `scripts/build_all.sh` | alles, was auf dem System möglich ist | |

Optionen über Umgebungsvariablen:

- `FLUTTER=/pfad/zu/flutter` – anderes Flutter-Binary verwenden
- `BASE_HREF=/antatime/` – Unterpfad für die Web-App (z. B. GitHub Pages)
- `IOS_SIGN=1` – signiertes IPA über `flutter build ipa` (Apple-Developer-Account in Xcode nötig)
- Android-Release-Signatur: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` (oder eigene `android/key.properties`). Ohne diese wird mit dem Debug-Key signiert.

Keystore erzeugen und für das Secret kodieren:

```bash
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias antatime
base64 -w0 release.jks   # Inhalt als Secret ANDROID_KEYSTORE_BASE64 hinterlegen
```

## GitHub Actions

`.github/workflows/build.yml` läuft bei Push auf `main`, Pull Requests, Tags `v*` und manuell:

1. **test** – `scripts/test.sh`
2. **android** – APK als Artefakt `android-apk`
3. **web** – Web-Build als Artefakt `web`
4. **ios** – unsigniertes IPA als Artefakt `ios-unsigned-ipa` (macOS-Runner)
5. **release** – bei Tags `v*` ein GitHub-Release mit allen Paketen
6. **pages** (optional) – Web-App auf GitHub Pages: unter *Settings → Pages* die Quelle „GitHub Actions“ wählen und die Repository-Variable `DEPLOY_PAGES=true` setzen

Für signierte Android-Releases die vier `ANDROID_*`-Werte als Repository-Secrets anlegen.

## Plattform-Hinweise

- **Android:** Die Benachrichtigung zeigt bei laufender Zeit die heutige Gesamtarbeitszeit live an. Ab Android 13 fragt die App beim ersten Start nach der Benachrichtigungs-Berechtigung.
- **iOS:** Start/Pause über die Aktion der Benachrichtigung (lange drücken bzw. aufziehen). Eine Live-Uhr in der Benachrichtigung ist auf iOS nicht möglich. Für die Installation auf einem iPhone muss das IPA signiert werden.
- **Web:** Kein Benachrichtigungsbereich, die Steuerung erfolgt in der App.
