#!/usr/bin/env bash
# Build macOS release artefacts for the Magenta Jam AUv3 host app:
#   - .dmg disk image (drag Magenta Jam (AU).app to Applications)
#   - .pkg installer (installs to /Applications and registers the AU extension)
#
# Run from repo root after:
#   cmake --build build --target package_jam_au
#
# Uses a single app copy (build/dist by default). DMG is built before PKG and
# uses an explicitly sized read-write image — hdiutil -srcfolder often creates
# a volume that is too small for signed .appex bundles (mlx.metallib copied last).
#
# Usage:
#   ./scripts/build-installer-pkg.sh [--version 0.1.0] [--app path/to/Magenta\ Jam\ \(AU\).app]
#   ./scripts/build-installer-pkg.sh --sign-app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_BUNDLE_NAME="Magenta Jam (AU).app"
VOL_NAME="Magenta Jam AU3"
PKG_ID="com.audiohacking.jam-au3"
OUT_DIR="${OUT_DIR:-release-artifacts}"
SIGN_APP=false
PKG_VERSION=""
APP_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sign-app)  SIGN_APP=true; shift ;;
    --version)   PKG_VERSION="$2"; shift 2 ;;
    --app)       APP_PATH="$2"; shift 2 ;;
    --out-dir)   OUT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '1,22p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PKG_VERSION" ]; then
  if git describe --tags --abbrev=0 >/dev/null 2>&1; then
    PKG_VERSION="$(git describe --tags --abbrev=0)"
  else
    PKG_VERSION="0.0.0-dev"
  fi
fi
PKG_VERSION="${PKG_VERSION#v}"

if [ -z "$APP_PATH" ]; then
  APP_PATH="${REPO_ROOT}/build/dist/${APP_BUNDLE_NAME}"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Error: app bundle not found at: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
PKG_FILE="${OUT_DIR}/Jam-AU3-${PKG_VERSION}-macOS-Installer.pkg"
DMG_FILE="${OUT_DIR}/Jam-AU3-${PKG_VERSION}-macOS.dmg"

disk_free() { df -h . | awk 'NR==2 {print $4}'; }

create_dmg_from_app() {
  local app_path="$1"
  local dmg_path="$2"
  local volname="$3"

  local src_mb dmg_mb tmp_rw mount_point dev
  src_mb=$(du -sm "$app_path" | awk '{print $1}')
  # Signed bundles + HFS+ metadata need headroom beyond du(1).
  dmg_mb=$(( src_mb + src_mb / 2 + 256 ))
  if [ "$dmg_mb" -lt 512 ]; then dmg_mb=512; fi

  tmp_rw="${dmg_path%.dmg}.rw.dmg"
  mount_point="/Volumes/${volname}"
  rm -f "$tmp_rw" "$dmg_path"

  echo "Creating ${dmg_mb}MB DMG for ${src_mb}MB app (free: $(disk_free))..."
  # Blank read-write image: do not pass -format without -srcfolder (macOS rejects it).
  hdiutil create \
    -size "${dmg_mb}m" \
    -volname "$volname" \
    -fs HFS+ \
    -layout SPUD \
    -ov \
    "$tmp_rw"

  dev=""
  cleanup_dmg() {
    if [ -n "$dev" ]; then
      hdiutil detach "$dev" -quiet 2>/dev/null || hdiutil detach "$dev" -force 2>/dev/null || true
    fi
    rm -f "$tmp_rw"
  }
  trap cleanup_dmg RETURN

  dev=$(hdiutil attach -readwrite -noverify -noautoopen "$tmp_rw" | awk '/^\/dev\// {print $1; exit}')
  ditto "$app_path" "${mount_point}/$(basename "$app_path")"
  sync
  hdiutil detach "$dev" -quiet
  dev=""

  hdiutil convert "$tmp_rw" -format UDZO -imagekey zlib-level=9 -o "$dmg_path"
  rm -f "$tmp_rw"
  trap - RETURN
}

echo "=== Packaging from single app copy ==="
echo "App:  $APP_PATH"
echo "Free: $(disk_free)"
du -sh "$APP_PATH"

if [ "$SIGN_APP" = true ]; then
  echo "Ad-hoc signing app bundle in place..."
  METALLIB="$(find "$APP_PATH" -name mlx.metallib -print -quit || true)"
  if [ -n "$METALLIB" ]; then
    xcrun codesign --force --sign - "$METALLIB"
  fi
  APPEX="${APP_PATH}/Contents/PlugIns/Jam_AU.appex"
  if [ -d "$APPEX" ]; then
    xcrun codesign --force --sign - --entitlements "${REPO_ROOT}/Entitlements.plist" --generate-entitlement-der "$APPEX"
  fi
  xcrun codesign --force --sign - "$APP_PATH"
fi

echo "Building .dmg: $DMG_FILE"
create_dmg_from_app "$APP_PATH" "$DMG_FILE" "$VOL_NAME"

echo "Building .pkg: $PKG_FILE (free: $(disk_free))"
PAYLOAD_DIR="$(mktemp -d)"
SCRIPTS_DIR="$(mktemp -d)"
cleanup_pkg_temps() { rm -rf "$PAYLOAD_DIR" "$SCRIPTS_DIR"; }
trap cleanup_pkg_temps EXIT

mkdir -p "${PAYLOAD_DIR}/Applications"
ditto "$APP_PATH" "${PAYLOAD_DIR}/Applications/${APP_BUNDLE_NAME}"
cp "${SCRIPT_DIR}/pkg-postinstall" "${SCRIPTS_DIR}/postinstall"
chmod +x "${SCRIPTS_DIR}/postinstall"

pkgbuild \
  --root "$PAYLOAD_DIR" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "$PKG_ID" \
  --version "$PKG_VERSION" \
  --install-location / \
  "$PKG_FILE"

echo ""
echo "Created:"
echo "  ${DMG_FILE} ($(du -h "$DMG_FILE" | awk '{print $1}'))"
echo "  ${PKG_FILE} ($(du -h "$PKG_FILE" | awk '{print $1}'))"
