#!/usr/bin/env bash
# Build the extra Linux distribution formats (rpm, AppImage, zip) from the
# exact payload scripts/package-linux.sh staged in dist/gptp-studio-distributed —
# the same bytes the deb wraps, so every format ships one product.
#
# Usage: scripts/package-extras.sh <version>
# Env:   GPTP_STUDIO_DEB_ARCH (amd64|arm64) — the same switch package-deb.sh
#        uses; it decides the asset arch spellings (deb arm64, rpm aarch64).
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: package-extras.sh <version>}"
ARCH="${GPTP_STUDIO_DEB_ARCH:-amd64}"
case "$ARCH" in
  amd64) FILE_ARCH="x64";  RPM_ARCH="x86_64"  ;;
  arm64) FILE_ARCH="arm64"; RPM_ARCH="aarch64" ;;
  *) echo "unknown GPTP_STUDIO_DEB_ARCH: $ARCH" >&2; exit 1 ;;
esac

DIST_ROOT="dist/gptp-studio-distributed"
test -d "$DIST_ROOT" || {
  echo "missing $DIST_ROOT — run scripts/package-linux.sh first" >&2
  exit 1
}

ZIP="gPTP-Studio-linux-${FILE_ARCH}.zip"
RPM="gPTP-Studio-linux-${FILE_ARCH}.rpm"
APPIMAGE="gPTP-Studio-linux-${FILE_ARCH}.AppImage"

echo "== zip =="
rm -f "$ZIP" "$ZIP.sha256"
( cd dist && zip -qry "../$ZIP" gptp-studio-distributed )
sha256sum "$ZIP" > "$ZIP.sha256"

echo "== rpm =="
# Hand-rolled rpmbuild, rivet-style: a generated spec, a STAGED tree copied
# into the buildroot in %install, no %dist tag, and the libtinfo exclusion
# that keeps the Ubuntu-built Racket runtime installable on Fedora.
# Requires names what the payload FFI/execs at runtime — the Fedora
# spellings of the deb's Depends.
STAGE="$PWD/dist/rpm-top/STAGED"
TOPDIR="$PWD/dist/rpm-top"
rm -rf "$TOPDIR"
mkdir -p "$STAGE/opt/gptp-studio" \
         "$STAGE/usr/bin" \
         "$STAGE/usr/share/applications" \
         "$STAGE/usr/share/pixmaps" \
         "$STAGE/usr/share/doc/gptp-studio" \
         "$TOPDIR/SPECS"
cp -a "$DIST_ROOT"/. "$STAGE/opt/gptp-studio/"
ln -s /opt/gptp-studio/bin/gptp-studio "$STAGE/usr/bin/gptp-studio"
cp assets/icon.png "$STAGE/usr/share/pixmaps/gptp-studio.png"
cp LICENSE NOTICE EULA.md THIRD_PARTY_NOTICES.md "$STAGE/usr/share/doc/gptp-studio/"
cp "$DIST_ROOT/BUILD-INFO.json" "$STAGE/usr/share/doc/gptp-studio/BUILD-INFO.json"

cat > "$STAGE/usr/share/applications/gptp-studio.desktop" <<'DESKTOP'
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

cat > "$TOPDIR/SPECS/gptp-studio.spec" <<'SPEC'
%global __requires_exclude ^libtinfo\\.so\\.6\\(NCURSES6_TINFO_.*$
Name:           gptp-studio
Version:        __GPTP_VERSION__
Release:        1
Summary:        Professional gPTP / IEEE 802.1AS debugging workstation
License:        EULA
URL:            https://github.com/turinglambdaai/gptp-studio
BuildArch:      __GPTP_RPM_ARCH__
Requires:       gtk4 >= 4.10.0
Requires:       libpcap
Requires:       linuxptp
Requires:       ethtool
Requires:       iproute
Requires:       libcap
Requires:       libsecret

%description
gPTP Studio is a Linux-native engineering workstation for Automotive
Ethernet timing work: linuxptp engine control, PHC and hardware timestamp
qualification, packet capture/decode, live timing analysis and headless
support diagnostics.

%prep

%build

%install
rm -rf "%{buildroot}"
mkdir -p "%{buildroot}"
cp -a "%{_topdir}/STAGED/." "%{buildroot}/"

%files
%dir "/opt/gptp-studio"
"/opt/gptp-studio/*"
"/usr/bin/gptp-studio"
"/usr/share/applications/gptp-studio.desktop"
"/usr/share/pixmaps/gptp-studio.png"
"/usr/share/doc/gptp-studio/*"
SPEC
sed -i "s/__GPTP_VERSION__/$VERSION/; s/__GPTP_RPM_ARCH__/$RPM_ARCH/" \
  "$TOPDIR/SPECS/gptp-studio.spec"

rpmbuild -bb --define="_topdir $TOPDIR" \
              --define="_rpmdir $PWD" \
              --define="_build_name_fmt %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm" \
              "$TOPDIR/SPECS/gptp-studio.spec"
mv "gptp-studio-$VERSION-1.$RPM_ARCH.rpm" "$RPM"
sha256sum "$RPM" > "$RPM.sha256"
rpm -qp --qf 'rpm metadata: %{NAME} %{VERSION} %{ARCH}\n' "$RPM"

echo "== AppImage =="
# appimagetool from its official continuous release, verified against the
# sha256 digest GitHub computes for the per-arch asset.
# APPIMAGE_EXTRACT_AND_RUN keeps everything working on FUSE-less machines.
tool="appimagetool-$RPM_ARCH.AppImage"
api_url="https://api.github.com/repos/AppImage/appimagetool/releases/tags/continuous"
expected="$(curl -fsSL "$api_url" | jq -r ".assets[] | select(.name == \"$tool\") | .digest" | sed 's/^sha256://')"
curl -fsSL -o "$tool" "https://github.com/AppImage/appimagetool/releases/download/continuous/$tool"
actual="$(sha256sum "$tool" | awk '{print $1}')"
if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
  echo "appimagetool checksum mismatch (expected ${expected:-none}, got $actual)" >&2
  exit 1
fi
chmod +x "$tool"
export APPIMAGE_EXTRACT_AND_RUN=1
./"$tool" --version | grep -q appimagetool || { echo "appimagetool does not run" >&2; exit 1; }

appdir="$(mktemp -d)/gptp-studio.AppDir"
mkdir -p "$appdir/usr/bin" \
         "$appdir/usr/share/applications" \
         "$appdir/usr/share/icons/hicolor/512x512/apps" \
         "$appdir/opt/gptp-studio"
cp -a "$DIST_ROOT"/. "$appdir/opt/gptp-studio/"
cat > "$appdir/usr/bin/gptp-studio" <<'LAUNCHER'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/../../opt/gptp-studio/bin/gptp-studio" "$@"
LAUNCHER
chmod 755 "$appdir/usr/bin/gptp-studio"
cat > "$appdir/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/gptp-studio" "$@"
APPRUN
chmod 755 "$appdir/AppRun"
cat > "$appdir/gptp-studio.desktop" <<DESKTOP
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
X-GPTP-Studio-Version=$VERSION
DESKTOP
cp "$appdir/gptp-studio.desktop" "$appdir/usr/share/applications/gptp-studio.desktop"
cp assets/icon.png "$appdir/gptp-studio.png"
cp "$appdir/gptp-studio.png" "$appdir/usr/share/icons/hicolor/512x512/apps/gptp-studio.png"
ln -s gptp-studio.png "$appdir/.DirIcon"
./"$tool" --no-appstream "$appdir" "$APPIMAGE"
sha256sum "$APPIMAGE" > "$APPIMAGE.sha256"

rm -rf "$TOPDIR" "$tool"
echo "packaged: $ZIP / $RPM / $APPIMAGE"
