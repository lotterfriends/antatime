#!/usr/bin/env bash
# Baut die Android-APK -> dist/antatime-<version>.apk
#
# Optionale Release-Signatur über Umgebungsvariablen (sonst Debug-Key):
#   ANDROID_KEYSTORE_BASE64   Keystore (.jks) base64-kodiert
#   ANDROID_KEYSTORE_PASSWORD
#   ANDROID_KEY_ALIAS
#   ANDROID_KEY_PASSWORD
# Alternativ eine eigene android/key.properties anlegen.
source "$(dirname "$0")/common.sh"

KEY_PROPS="$ROOT_DIR/android/key.properties"
if [[ -n "${ANDROID_KEYSTORE_BASE64:-}" ]]; then
  echo "Release-Keystore aus Umgebungsvariablen wird verwendet."
  KEYSTORE_FILE="$ROOT_DIR/android/app/release.jks"
  echo "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$KEYSTORE_FILE"
  cat > "$KEY_PROPS" <<PROPS
storePassword=${ANDROID_KEYSTORE_PASSWORD}
keyPassword=${ANDROID_KEY_PASSWORD}
keyAlias=${ANDROID_KEY_ALIAS}
storeFile=release.jks
PROPS
  trap 'rm -f "$KEY_PROPS" "$KEYSTORE_FILE"' EXIT
elif [[ ! -f "$KEY_PROPS" ]]; then
  echo "Hinweis: Keine Release-Signatur konfiguriert – APK wird mit dem Debug-Key signiert."
fi

flutter_prepare
"$FLUTTER" build apk --release "$@"

OUT="$DIST_DIR/antatime-$APP_VERSION.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$OUT"
echo "APK: $OUT"
