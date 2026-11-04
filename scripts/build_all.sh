#!/usr/bin/env bash
# Baut alle auf diesem System möglichen Pakete.
set -euo pipefail
DIR="$(dirname "$0")"
"$DIR/test.sh"
"$DIR/build_android.sh"
"$DIR/build_web.sh"
if [[ "$(uname)" == "Darwin" ]]; then
  "$DIR/build_ios.sh"
else
  echo "iOS übersprungen (nur auf macOS möglich)."
fi
