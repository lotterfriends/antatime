#!/usr/bin/env bash
# Baut alle auf diesem System möglichen Pakete.
set -euo pipefail
DIR="$(dirname "$0")"
"$DIR/test.sh"
"$DIR/build_android.sh"
"$DIR/build_web.sh"
case "$(uname -s)" in
  Linux)
    "$DIR/build_linux.sh"
    echo "iOS/macOS/Windows übersprungen (nur auf dem jeweiligen System möglich)."
    ;;
  Darwin)
    "$DIR/build_ios.sh"
    "$DIR/build_macos.sh"
    ;;
  MINGW* | MSYS* | CYGWIN*)
    "$DIR/build_windows.sh"
    ;;
esac
