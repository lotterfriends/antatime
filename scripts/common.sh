#!/usr/bin/env bash
# Gemeinsame Helfer für die Build-Skripte. Wird per `source` eingebunden.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
# Eigenes Flutter-Binary über FLUTTER=/pfad/zu/flutter möglich.
FLUTTER="${FLUTTER:-flutter}"

if ! command -v "$FLUTTER" >/dev/null 2>&1; then
  echo "Flutter nicht gefunden. Installieren (https://docs.flutter.dev/get-started/install)" >&2
  echo "oder FLUTTER=/pfad/zu/flutter setzen." >&2
  exit 1
fi

# Version aus pubspec.yaml, z. B. 1.0.0+1 -> 1.0.0
APP_VERSION="$(grep -E '^version:' "$ROOT_DIR/pubspec.yaml" | sed -E 's/version:[[:space:]]*([^+]+).*/\1/')"

mkdir -p "$DIST_DIR"
cd "$ROOT_DIR"

flutter_prepare() {
  "$FLUTTER" --version
  "$FLUTTER" pub get
}
