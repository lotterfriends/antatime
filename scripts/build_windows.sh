#!/usr/bin/env bash
# Baut die Windows-Desktop-App (nur unter Windows, z. B. in Git Bash) ->
#   dist/antatime-<version>-windows-x64.zip              (portabel, antatime.exe starten)
#   dist/AnTaTime-<version>-windows-x64-setup.exe        (Installer, falls Inno Setup vorhanden)
#
# Voraussetzungen: Visual Studio 2022 mit „Desktopentwicklung mit C++“,
# optional Inno Setup 6 (https://jrsoftware.org/isinfo.php) für den Installer.
source "$(dirname "$0")/common.sh"

flutter_prepare
"$FLUTTER" build windows --release "$@"
RELEASE_DIR="$ROOT_DIR/build/windows/x64/runner/Release"

ZIP="$DIST_DIR/antatime-$APP_VERSION-windows-x64.zip"
rm -f "$ZIP"
# Zip-Archiv mit Ordner „AnTaTime“ (PowerShell ist auf Windows immer vorhanden)
STAGE="$ROOT_DIR/build/windows-package/AnTaTime"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp -r "$RELEASE_DIR/." "$STAGE/"
powershell.exe -NoProfile -Command \
  "Compress-Archive -Path '$(cygpath -w "$STAGE")' -DestinationPath '$(cygpath -w "$ZIP")' -Force"
echo "Zip: $ZIP"

ISCC="$(command -v iscc || command -v ISCC || true)"
for p in "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe"; do
  [[ -z "$ISCC" && -x "$p" ]] && ISCC="$p"
done
if [[ -n "$ISCC" ]]; then
  "$ISCC" /Q "/DAppVersion=$APP_VERSION" \
    "/DSourceDir=$(cygpath -w "$RELEASE_DIR")" \
    "/DOutputDir=$(cygpath -w "$DIST_DIR")" \
    "$(cygpath -w "$ROOT_DIR/windows/installer/antatime.iss")"
  echo "Installer: $DIST_DIR/AnTaTime-$APP_VERSION-windows-x64-setup.exe"
else
  echo "Inno Setup nicht gefunden – Installer übersprungen (nur Zip)."
fi
