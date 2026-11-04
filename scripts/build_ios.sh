#!/usr/bin/env bash
# Baut die iOS-App (nur auf macOS mit Xcode).
#
# Ohne Signatur entsteht dist/antatime-<version>-unsigned.ipa, die z. B. mit
# AltStore/Sideloadly signiert und installiert werden kann.
# Mit IOS_SIGN=1 wird stattdessen `flutter build ipa` mit der in Xcode
# eingerichteten Signatur ausgeführt (Apple-Developer-Account nötig).
source "$(dirname "$0")/common.sh"

if [[ "$(uname)" != "Darwin" ]]; then
  echo "iOS-Builds sind nur auf macOS mit Xcode möglich." >&2
  exit 1
fi

flutter_prepare

if [[ "${IOS_SIGN:-0}" == "1" ]]; then
  "$FLUTTER" build ipa --release "$@"
  cp build/ios/ipa/*.ipa "$DIST_DIR/antatime-$APP_VERSION.ipa"
  echo "IPA: $DIST_DIR/antatime-$APP_VERSION.ipa"
else
  "$FLUTTER" build ios --release --no-codesign "$@"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/Payload"
  cp -R build/ios/iphoneos/Runner.app "$TMP/Payload/"
  OUT="$DIST_DIR/antatime-$APP_VERSION-unsigned.ipa"
  rm -f "$OUT"
  (cd "$TMP" && zip -qr "$OUT" Payload)
  rm -rf "$TMP"
  echo "IPA (unsigniert): $OUT"
fi
