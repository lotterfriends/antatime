#!/usr/bin/env bash
# Baut die macOS-Desktop-App (nur auf macOS) ->
#   dist/AnTaTime-<version>-macos.dmg   (App in den Programme-Ordner ziehen)
#   dist/AnTaTime-<version>-macos.zip
#
# Die App ist nicht notarisiert. Beim ersten Start: Rechtsklick → Öffnen,
# oder: xattr -dr com.apple.quarantine /Applications/AnTaTime.app
source "$(dirname "$0")/common.sh"

flutter_prepare
"$FLUTTER" build macos --release ${DART_DEFINES[@]+"${DART_DEFINES[@]}"} "$@"
APP="$ROOT_DIR/build/macos/Build/Products/Release/AnTaTime.app"

ZIP="$DIST_DIR/AnTaTime-$APP_VERSION-macos.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Zip: $ZIP"

STAGE="$ROOT_DIR/build/macos-dmg"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
DMG="$DIST_DIR/AnTaTime-$APP_VERSION-macos.dmg"
rm -f "$DMG"
hdiutil create -volname "AnTaTime" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "DMG: $DMG"
