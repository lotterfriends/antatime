#!/usr/bin/env bash
# Baut die Android-APK -> dist/antatime-<version>.apk
#
# Optionale Release-Signatur über Umgebungsvariablen (sonst Debug-Key):
#   ANDROID_KEYSTORE_BASE64   Keystore (.jks) base64-kodiert (wie in CI)
#   ANDROID_KEYSTORE_FILE     … oder Pfad zur .jks-Datei (lokal bequemer)
#   ANDROID_KEYSTORE_PASSWORD
#   ANDROID_KEY_ALIAS
#   ANDROID_KEY_PASSWORD
# Lokal am einfachsten in signing.env (nicht eingecheckt, Vorlage:
# signing.env.example). Alternativ eine eigene android/key.properties.
source "$(dirname "$0")/common.sh"

SIGNING_ENV="$ROOT_DIR/signing.env"
if [[ -f "$SIGNING_ENV" ]]; then
  echo "Signatur-Einstellungen aus signing.env werden geladen."
  set -a
  # shellcheck source=/dev/null
  source "$SIGNING_ENV"
  set +a
fi

KEY_PROPS="$ROOT_DIR/android/key.properties"
if [[ -f "$KEY_PROPS" ]]; then
  # Eine eigene key.properties nie überschreiben (und nicht löschen).
  echo "Release-Signatur aus android/key.properties wird verwendet."
elif [[ -n "${ANDROID_KEYSTORE_BASE64:-}" || -n "${ANDROID_KEYSTORE_FILE:-}" ]]; then
  for v in ANDROID_KEYSTORE_PASSWORD ANDROID_KEY_ALIAS ANDROID_KEY_PASSWORD; do
    if [[ -z "${!v:-}" ]]; then
      echo "Release-Signatur: $v fehlt." >&2
      exit 1
    fi
  done
  if [[ -n "${ANDROID_KEYSTORE_FILE:-}" ]]; then
    KEYSTORE_FILE="$(realpath "$ANDROID_KEYSTORE_FILE")"
    if [[ ! -f "$KEYSTORE_FILE" ]]; then
      echo "Release-Signatur: Keystore $ANDROID_KEYSTORE_FILE nicht gefunden." >&2
      exit 1
    fi
    echo "Release-Keystore $KEYSTORE_FILE wird verwendet."
    trap 'rm -f "$KEY_PROPS"' EXIT
  else
    echo "Release-Keystore aus Umgebungsvariablen wird verwendet."
    KEYSTORE_FILE="$ROOT_DIR/android/app/release.jks"
    echo "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$KEYSTORE_FILE"
    trap 'rm -f "$KEY_PROPS" "$KEYSTORE_FILE"' EXIT
  fi
  # Nur für diesen Build; wird am Ende wieder entfernt.
  (umask 077; cat > "$KEY_PROPS" <<PROPS
storePassword=${ANDROID_KEYSTORE_PASSWORD}
keyPassword=${ANDROID_KEY_PASSWORD}
keyAlias=${ANDROID_KEY_ALIAS}
storeFile=${KEYSTORE_FILE}
PROPS
  )
else
  MSG="Keine Release-Signatur konfiguriert – APK wird mit dem Debug-Key signiert. Updates über eine bestehende Installation schlagen fehl, wenn der Debug-Key wechselt (in CI bei jedem Lauf)."
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::warning title=Android-Signatur fehlt::$MSG Repository-Secrets ANDROID_* anlegen (siehe README)."
  else
    echo "Hinweis: $MSG"
  fi
fi

# Fortlaufende Build-Nummer (versionCode), damit sich jede APK über die
# vorige installieren lässt – lokal wie in CI nach demselben Schema: Sekunden
# seit 2025-01-01 (UTC). Das liegt über den früheren CI-Nummern (Lauf-Nummer)
# und reicht bis etwa 2091 (Android erlaubt höchstens 2100000000).
# Eigene Nummer weiterhin mit --build-number=… möglich.
BUILD_ARGS=()
if [[ " $* " != *" --build-number"* ]]; then
  BUILD_NUMBER=$(( $(date -u +%s) - 1735689600 ))
  echo "Build-Nummer (versionCode): $BUILD_NUMBER"
  BUILD_ARGS+=(--build-number="$BUILD_NUMBER")
fi

flutter_prepare
"$FLUTTER" build apk --release ${DART_DEFINES[@]+"${DART_DEFINES[@]}"} ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} "$@"

OUT="$DIST_DIR/antatime-$APP_VERSION.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$OUT"
echo "APK: $OUT"
