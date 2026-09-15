#!/bin/zsh
# Package gPTP Studio as a macOS .app (+ DMG when run on a tag).
#
# Why hand-rolled: glaze's build-app assemble step silently breaks the
# merged launcher on Racket 9.3 CS (exits 0 without running the program);
# a straight copy of the raco-distribute layout into an .app works.
# Usage: scripts/package-macos.sh [racket-bin-dir]

set -e
cd "$(dirname "$0")/.."

RACKET_BIN="${1:-$HOME/.zcode/toolchains/racket-9.3/bin}"
export PATH="$RACKET_BIN:$PATH"

APP_NAME="gPTP Studio"
VERSION="1.0.0"
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
  sips -z 16 16     assets/icon.png --out assets/gptp-studio.iconset/icon_16x16.png     >/dev/null
  sips -z 32 32     assets/icon.png --out assets/gptp-studio.iconset/icon_16x16@2x.png  >/dev/null
  sips -z 32 32     assets/icon.png --out assets/gptp-studio.iconset/icon_32x32.png     >/dev/null
  sips -z 64 64     assets/icon.png --out assets/gptp-studio.iconset/icon_32x32@2x.png  >/dev/null
  sips -z 128 128   assets/icon.png --out assets/gptp-studio.iconset/icon_128x128.png   >/dev/null
  sips -z 256 256   assets/icon.png --out assets/gptp-studio.iconset/icon_128x128@2x.png >/dev/null
  sips -z 256 256   assets/icon.png --out assets/gptp-studio.iconset/icon_256x256.png   >/dev/null
  sips -z 512 512   assets/icon.png --out assets/gptp-studio.iconset/icon_256x256@2x.png >/dev/null
  sips -z 512 512   assets/icon.png --out assets/gptp-studio.iconset/icon_512x512.png   >/dev/null
  iconutil -c icns assets/gptp-studio.iconset -o assets/icon.icns
  rm -rf assets/gptp-studio.iconset
fi
cp assets/icon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"

echo "== codesign (adhoc) =="
codesign --force --deep -s - "$APP" 2>/dev/null || codesign --force -s - "$APP"

echo "== smoke =="
"$APP/Contents/MacOS/$APP_NAME" --version

echo "packaged: $APP"
