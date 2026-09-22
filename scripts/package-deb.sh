#!/usr/bin/env bash
# Build the validated relocatable Linux payload, then wrap it as a Debian
# package without changing host privileges in maintainer scripts.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-${GPTP_STUDIO_VERSION:-1.0.0}}"
TAG_LABEL="${2:-v$VERSION}"
ARCH="${GPTP_STUDIO_DEB_ARCH:-amd64}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid package version: $VERSION (expected x.y.z)" >&2
  exit 2
fi

# package-linux.sh is the canonical payload builder and already performs
# version/selfcheck/Doctor/license smoke tests. Reuse exactly that payload so
# the tarball and .deb cannot drift into two different products.
bash scripts/package-linux.sh "$VERSION" "$TAG_LABEL"

DIST_ROOT="dist/gptp-studio-distributed"
PKG_ROOT="dist/deb-root"
EXTRACT_ROOT="dist/deb-extracted"
DEB="gPTP-Studio-${TAG_LABEL}-linux-${ARCH}.deb"

rm -rf "$PKG_ROOT" "$EXTRACT_ROOT" "$DEB"
mkdir -p \
  "$PKG_ROOT/DEBIAN" \
  "$PKG_ROOT/opt/gptp-studio" \
  "$PKG_ROOT/usr/bin" \
  "$PKG_ROOT/usr/share/applications" \
  "$PKG_ROOT/usr/share/pixmaps" \
  "$PKG_ROOT/usr/share/doc/gptp-studio"

cp -a "$DIST_ROOT"/. "$PKG_ROOT/opt/gptp-studio/"
ln -s /opt/gptp-studio/bin/gptp-studio "$PKG_ROOT/usr/bin/gptp-studio"
cp assets/icon.png "$PKG_ROOT/usr/share/pixmaps/gptp-studio.png"
cp LICENSE NOTICE EULA.md THIRD_PARTY_NOTICES.md \
  "$PKG_ROOT/usr/share/doc/gptp-studio/"

cat > "$PKG_ROOT/usr/share/applications/gptp-studio.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=gPTP Studio
Comment=Professional IEEE 802.1AS / gPTP debugging workstation
Exec=gptp-studio
Icon=gptp-studio
Terminal=false
Categories=Development;Network;
Keywords=gPTP;PTP;IEEE 802.1AS;AUTOSAR;EthTSyn;TSN;
StartupNotify=true
DESKTOP

cat > "$PKG_ROOT/DEBIAN/control" <<CONTROL
Package: gptp-studio
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Maintainer: turinglambdaai
Homepage: https://github.com/turinglambdaai/gptp-studio
Depends: libgtk-3-0, libwebkit2gtk-4.1-0, libpcap0.8, linuxptp, ethtool, iproute2, libcap2-bin, openssl
Description: Professional gPTP / IEEE 802.1AS debugging workstation
 gPTP Studio is a Linux-native engineering workstation for Automotive
 Ethernet timing work. It combines linuxptp engine control, PHC and hardware
 timestamp qualification, packet capture/decode, live timing analysis and
 headless support diagnostics.
CONTROL

# Intentionally no postinst/prerm scripts: package installation must not grant
# CAP_NET_ADMIN/CAP_NET_RAW/CAP_SYS_TIME or change sudo policy behind the
# operator's back. Doctor/Preflight report the privilege path explicitly.

echo "== build deb =="
dpkg-deb --build --root-owner-group "$PKG_ROOT" "$DEB"
sha256sum "$DEB" > "$DEB.sha256"

echo "== deb metadata smoke =="
test "$(dpkg-deb --field "$DEB" Package)" = "gptp-studio"
test "$(dpkg-deb --field "$DEB" Version)" = "$VERSION"
test "$(dpkg-deb --field "$DEB" Architecture)" = "$ARCH"
dpkg-deb --field "$DEB" Depends | grep -q 'linuxptp'
dpkg-deb --field "$DEB" Depends | grep -q 'libwebkit2gtk-4.1-0'

mkdir -p "$EXTRACT_ROOT"
dpkg-deb -x "$DEB" "$EXTRACT_ROOT"

BINARY="$EXTRACT_ROOT/opt/gptp-studio/bin/gptp-studio"
test -x "$BINARY"
test -L "$EXTRACT_ROOT/usr/bin/gptp-studio"
test -s "$EXTRACT_ROOT/usr/share/applications/gptp-studio.desktop"
test -s "$EXTRACT_ROOT/usr/share/pixmaps/gptp-studio.png"
for notice in LICENSE NOTICE EULA.md THIRD_PARTY_NOTICES.md; do
  test -s "$EXTRACT_ROOT/usr/share/doc/gptp-studio/$notice"
done

test "$("$BINARY" --version)" = "$VERSION"
"$BINARY" --doctor-json > "dist/gptp-studio-deb-doctor-smoke.json"
python3 - "dist/gptp-studio-deb-doctor-smoke.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    report = json.load(f)
assert report["schema_version"] == 1
assert report["product"] == "gPTP Studio"
assert report["platform"] == "linux"
assert report["privacy"]["network_identifiers_redacted"] is True
assert report["accuracy_claim"] == "not-calibrated"
PY

GPTP_STUDIO_SELFCHECK_PORT="${GPTP_STUDIO_DEB_SELFCHECK_PORT:-18742}" \
  "$BINARY" --selfcheck --port "${GPTP_STUDIO_DEB_SELFCHECK_PORT:-18742}"

echo "packaged: $DEB"
