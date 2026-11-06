#!/usr/bin/env bash
# Baut die Linux-Desktop-App und verpackt sie als
#   dist/antatime-<version>-linux-<arch>.tar.gz   (entpacken und ./antatime starten)
#   dist/antatime_<version>_<debarch>.deb         (Debian/Ubuntu/Mint …)
#   dist/AnTaTime-<version>-<arch>.AppImage       (läuft auf fast allen Distributionen)
#
# Voraussetzungen (Debian/Ubuntu):
#   sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
#     libayatana-appindicator3-dev
#
#   SKIP_DEB=1       kein .deb bauen
#   SKIP_APPIMAGE=1  kein AppImage bauen (appimagetool wird sonst bei Bedarf
#                    nach build/tools heruntergeladen)
source "$(dirname "$0")/common.sh"

APP_ID="com.lotterfriends.antatime"
APP_NAME="AnTaTime"
BIN="antatime"

case "$(uname -m)" in
  x86_64) ARCH=x64; DEB_ARCH=amd64; AI_ARCH=x86_64 ;;
  aarch64 | arm64) ARCH=arm64; DEB_ARCH=arm64; AI_ARCH=aarch64 ;;
  *) echo "Nicht unterstützte Architektur: $(uname -m)" >&2; exit 1 ;;
esac

flutter_prepare
"$FLUTTER" build linux --release ${DART_DEFINES[@]+"${DART_DEFINES[@]}"} "$@"
BUNDLE="$ROOT_DIR/build/linux/$ARCH/release/bundle"
ICON="$ROOT_DIR/linux/assets/antatime.png"
DESKTOP="$ROOT_DIR/linux/assets/$APP_ID.desktop"
STAGE="$ROOT_DIR/build/linux-packages"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Tray-Symbol (tray_manager) braucht libayatana-appindicator3. Für tar.gz und
# AppImage wird sie samt Abhängigkeiten mitgeliefert, damit die App auch auf
# Systemen ohne diese Bibliothek startet; das .deb gibt sie als Abhängigkeit an.
bundle_tray_libs() {
  local lib_dir="$1"
  local plugin="$lib_dir/libtray_manager_plugin.so"
  [[ -f "$plugin" ]] || return 0
  ldd "$plugin" | awk '/ayatana|dbusmenu|libido/ { print $3 }' | while read -r so; do
    [[ -f "$so" ]] && cp -L "$so" "$lib_dir/"
  done
}

# --- tar.gz ------------------------------------------------------------------
TAR="$DIST_DIR/antatime-$APP_VERSION-linux-$ARCH.tar.gz"
rm -rf "$STAGE/antatime"
cp -r "$BUNDLE" "$STAGE/antatime"
cp "$DESKTOP" "$STAGE/antatime/"
bundle_tray_libs "$STAGE/antatime/lib"
tar -C "$STAGE" -czf "$TAR" antatime
echo "Tarball: $TAR"

# --- .deb --------------------------------------------------------------------
if [[ "${SKIP_DEB:-}" != "1" ]]; then
  if command -v dpkg-deb >/dev/null 2>&1; then
    PKG="$STAGE/deb"
    mkdir -p "$PKG/DEBIAN" "$PKG/opt/antatime" "$PKG/usr/bin" \
      "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/512x512/apps"
    cp -r "$BUNDLE/." "$PKG/opt/antatime/"
    ln -s /opt/antatime/$BIN "$PKG/usr/bin/$BIN"
    cp "$DESKTOP" "$PKG/usr/share/applications/"
    cp "$ICON" "$PKG/usr/share/icons/hicolor/512x512/apps/$APP_ID.png"
    chmod -R u=rwX,go=rX "$PKG"
    SIZE_KB="$(du -sk "$PKG" | cut -f1)"
    cat > "$PKG/DEBIAN/control" <<CONTROL
Package: antatime
Version: $APP_VERSION
Section: utils
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $SIZE_KB
Depends: libgtk-3-0t64 | libgtk-3-0, libayatana-appindicator3-1
Maintainer: lotterfriends
Homepage: https://github.com/lotterfriends/antatime
Description: $APP_NAME – Arbeitszeiterfassung
 Arbeitszeit per Start/Pause erfassen, Pausen und Überstunden im Blick,
 optionaler Abgleich zwischen Geräten.
CONTROL
    DEB="$DIST_DIR/antatime_${APP_VERSION}_$DEB_ARCH.deb"
    dpkg-deb --root-owner-group --build "$PKG" "$DEB" >/dev/null
    echo "Debian-Paket: $DEB"
  else
    echo "dpkg-deb nicht gefunden – .deb übersprungen."
  fi
fi

# --- AppImage ----------------------------------------------------------------
if [[ "${SKIP_APPIMAGE:-}" != "1" ]]; then
  TOOL="$(command -v appimagetool || true)"
  if [[ -z "$TOOL" ]]; then
    TOOL="$ROOT_DIR/build/tools/appimagetool-$AI_ARCH.AppImage"
    if [[ ! -x "$TOOL" ]]; then
      mkdir -p "$(dirname "$TOOL")"
      echo "Lade appimagetool …"
      curl -fsSL -o "$TOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$AI_ARCH.AppImage"
      chmod +x "$TOOL"
    fi
  fi
  APPDIR="$STAGE/$APP_NAME.AppDir"
  mkdir -p "$APPDIR/usr/share/icons/hicolor/512x512/apps"
  cp -r "$BUNDLE/." "$APPDIR/"
  bundle_tray_libs "$APPDIR/lib"
  cp "$DESKTOP" "$APPDIR/"
  cp "$ICON" "$APPDIR/$APP_ID.png"
  cp "$ICON" "$APPDIR/usr/share/icons/hicolor/512x512/apps/$APP_ID.png"
  cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/antatime" "$@"
APPRUN
  chmod +x "$APPDIR/AppRun"
  APPIMAGE="$DIST_DIR/$APP_NAME-$APP_VERSION-$AI_ARCH.AppImage"
  # Ohne FUSE (z. B. in Containern/CI) entpackt sich appimagetool selbst.
  APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$AI_ARCH" "$TOOL" --no-appstream \
    "$APPDIR" "$APPIMAGE" >/dev/null
  echo "AppImage: $APPIMAGE"
fi
