#!/usr/bin/env bash
# Build the relocatable Linux distribution, smoke-test the distributed binary,
# and produce a tarball + SHA-256 checksum.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-${GPTP_STUDIO_VERSION:-1.0.0}}"
TAG_LABEL="${2:-v$VERSION}"
SELF_CHECK_PORT="${GPTP_STUDIO_SELFCHECK_PORT:-18732}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid package version: $VERSION (expected x.y.z)" >&2
  exit 2
fi

rm -rf dist
mkdir -p dist

echo "== raco exe =="
raco exe -o dist/gptp-studio main.rkt

echo "== raco distribute =="
raco distribute dist/gptp-studio-distributed dist/gptp-studio
cp -r public dist/gptp-studio-distributed/

BINARY="dist/gptp-studio-distributed/bin/gptp-studio"

echo "== packaged artifact smoke =="
ACTUAL_VERSION="$("$BINARY" --version)"
if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
  echo "distributed/runtime version mismatch: expected=$VERSION runtime=$ACTUAL_VERSION" >&2
  exit 1
fi
"$BINARY" --selfcheck --port "$SELF_CHECK_PORT"

echo "== archive =="
ARCHIVE="gPTP-Studio-${TAG_LABEL}-linux-x64.tar.gz"
tar -czf "$ARCHIVE" -C dist gptp-studio-distributed
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

echo "packaged: $ARCHIVE"
