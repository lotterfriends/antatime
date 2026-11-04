#!/usr/bin/env bash
# Baut die Web-App -> build/web und dist/antatime-web-<version>.zip
#
#   BASE_HREF  Pfad, unter dem die App ausgeliefert wird (Standard: /),
#              für GitHub Pages z. B. /antatime/
source "$(dirname "$0")/common.sh"

BASE_HREF="${BASE_HREF:-/}"

flutter_prepare
"$FLUTTER" build web --release --base-href "$BASE_HREF" "$@"

OUT="$DIST_DIR/antatime-web-$APP_VERSION.zip"
rm -f "$OUT"
(cd build/web && zip -qr "$OUT" .)
echo "Web: $ROOT_DIR/build/web"
echo "Zip: $OUT"
