#!/usr/bin/env bash
# Gemeinsame Helfer für die Build-Skripte. Wird per `source` eingebunden.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
# Eigenes Flutter-Binary über FLUTTER=/pfad/zu/flutter möglich. Sonst
# `flutter` aus dem PATH oder das SDK aus android/local.properties
# (flutter.sdk, schreibt Flutter selbst beim ersten Android-Build).
if [[ -z "${FLUTTER:-}" ]]; then
  FLUTTER=flutter
  if ! command -v flutter >/dev/null 2>&1 && [[ -f "$ROOT_DIR/android/local.properties" ]]; then
    SDK="$(sed -n 's/^flutter\.sdk=//p' "$ROOT_DIR/android/local.properties" | tail -n1)"
    [[ -n "$SDK" && -x "$SDK/bin/flutter" ]] && FLUTTER="$SDK/bin/flutter"
  fi
fi

if ! command -v "$FLUTTER" >/dev/null 2>&1; then
  echo "Flutter nicht gefunden. Installieren (https://docs.flutter.dev/get-started/install)" >&2
  echo "oder FLUTTER=/pfad/zu/flutter setzen." >&2
  exit 1
fi

# Version aus pubspec.yaml, z. B. 1.0.0+1 -> 1.0.0
APP_VERSION="$(grep -E '^version:' "$ROOT_DIR/pubspec.yaml" | sed -E 's/version:[[:space:]]*([^+]+).*/\1/')"

# Standard-Sync-Server, der in der App vorausgefüllt ist (z. B. antatime.de).
# In GitHub Actions aus der Repository-Variable SYNC_URL.
DART_DEFINES=()
if [[ -n "${SYNC_URL:-}" ]]; then
  DART_DEFINES+=("--dart-define=SYNC_URL=$SYNC_URL")
fi

mkdir -p "$DIST_DIR"
cd "$ROOT_DIR"

flutter_prepare() {
  "$FLUTTER" --version
  "$FLUTTER" pub get
}
