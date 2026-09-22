#!/bin/zsh
# Package gPTP Studio as a macOS .app.
#
# Why hand-rolled: glaze's build-app assemble step silently breaks the
# merged launcher on Racket 9.3 CS (exits 0 without running the program);
# a straight copy of the raco-distribute layout into an .app works.
#
# Usage:
#   scripts/package-macos.sh [racket-bin-dir] [version]
#
# VERSION may also be supplied through GPTP_STUDIO_VERSION. The release
# workflow passes the tag-derived version explicitly so Info.plist can never
# silently stay at an old hard-coded release number.

set -euo pipefail
cd "$(dirname "$0")/.."

RACKET_BIN="${1:-$HOME/.zcode/toolchains/racket-9.3/bin}"
VERSION="${2:-${GPTP_STUDIO_VERSION:-1.0.0}}"
export PATH="$RACKET_BIN:$PATH"

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "invalid bundle version: $VERSION (expected x.y.z)" >&2
  exit 2
fi

APP_NAME="gPTP Studio"
rm -rf dist dist-test
mkdir -p dist-test

echo "== raco exe =="
raco exe -o dist-test/gptp-studio main.rkt

echo "== raco distribute =="
raco distribute dist-test/gptp-studio-distributed dist-test/gptp-studio

echo "== assemble .app =="
APP="dist/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/lib" "$APP/Contents/Resources"
cp -R dist-test/gptp-studio-distributed/bin/gptp-studio "$APP/Contents/MacOS/$APP_NAME"
cp -R dist-test/gptp-studio-distributed/lib/* "$APP/Contents/lib/"
cp -R public "$APP/Contents/Resources/public"

LICENSE_DIR="$APP/Contents/Resources/licenses"
mkdir -p "$LICENSE_DIR"
cp LICENSE NOTICE EULA.md THIRD_PARTY_NOTICES.md "$LICENSE_DIR/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>site.jrtx.gptpstudio</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "== icon =="
if [ ! -f assets/icon.icns ]; then
  mkdir -p assets/gptp-studio.iconset
  sips -z 16 16     assets/icon.png --out assets/gptp-studio.iconset/icon_16x16.png       >/dev/null
  sips -z 32 32     assets/icon.png --out assets/gptp-studio.iconset/icon_16x16@2x.png    >/dev/null
  sips -z 32 32     assets/icon.png --out assets/gptp-studio.iconset/icon_32x32.png       >/dev/null
  sips -z 64 64     assets/icon.png --out assets/gptp-studio.iconset/icon_32x32@2x.png    >/dev/null
  sips -z 128 128   assets/icon.png --out assets/gptp-studio.iconset/icon_128x128.png     >/dev/null
  sips -z 256 256   assets/icon.png --out assets/gptp-studio.iconset/icon_128x128@2x.png  >/dev/null
  sips -z 256 256   assets/icon.png --out assets/gptp-studio.iconset/icon_256x256.png     >/dev/null
  sips -z 512 512   assets/icon.png --out assets/gptp-studio.iconset/icon_256x256@2x.png  >/dev/null
  sips -z 512 512   assets/icon.png --out assets/gptp-studio.iconset/icon_512x512.png     >/dev/null
  iconutil -c icns assets/gptp-studio.iconset -o assets/icon.icns
  rm -rf assets/gptp-studio.iconset
fi
cp assets/icon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"

echo "== codesign (ad-hoc development signature) =="
codesign --force --deep -s - "$APP" 2>/dev/null || codesign --force -s - "$APP"

echo "== packaged artifact smoke =="
BINARY="$APP/Contents/MacOS/$APP_NAME"
ACTUAL_VERSION="$("$BINARY" --version)"
if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
  echo "bundle/runtime version mismatch: plist=$VERSION runtime=$ACTUAL_VERSION" >&2
  exit 1
fi
"$BINARY" --selfcheck --port 18731

DOCTOR_JSON="dist/gptp-studio-doctor-smoke.json"
"$BINARY" --doctor-json > "$DOCTOR_JSON"
python3 - "$DOCTOR_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    report = json.load(f)
assert report["schema_version"] == 1
assert report["product"] == "gPTP Studio"
assert report["platform"] == "macos"
assert report["privacy"]["network_identifiers_redacted"] is True
assert report["accuracy_claim"] == "not-calibrated"
PY

for notice in LICENSE NOTICE EULA.md THIRD_PARTY_NOTICES.md; do
  test -s "$LICENSE_DIR/$notice" || {
    echo "missing bundle license payload: $notice" >&2
    exit 1
  }
done

grep -q "Apache License" "$LICENSE_DIR/LICENSE"
grep -q "Glaze" "$LICENSE_DIR/THIRD_PARTY_NOTICES.md"
grep -q "Racket CS" "$LICENSE_DIR/THIRD_PARTY_NOTICES.md"
grep -q "不会撤销、限制或缩小" "$LICENSE_DIR/EULA.md"

echo "packaged: $APP ($VERSION)"
