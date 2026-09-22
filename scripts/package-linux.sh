#!/usr/bin/env bash
# Build the relocatable Linux distribution, smoke-test the distributed binary,
# verify license payloads, and produce a tarball + SHA-256 checksum.
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

DIST_ROOT="dist/gptp-studio-distributed"
BINARY="$DIST_ROOT/bin/gptp-studio"

# License/attribution material is part of the product artifact, not merely the
# source repository. Keep the filenames stable for procurement/compliance tools.
cp LICENSE NOTICE EULA.md THIRD_PARTY_NOTICES.md "$DIST_ROOT/"

echo "== packaged artifact smoke =="
ACTUAL_VERSION="$("$BINARY" --version)"
if [[ "$ACTUAL_VERSION" != "$VERSION" ]]; then
  echo "distributed/runtime version mismatch: expected=$VERSION runtime=$ACTUAL_VERSION" >&2
  exit 1
fi
"$BINARY" --selfcheck --port "$SELF_CHECK_PORT"

DOCTOR_JSON="dist/gptp-studio-doctor-smoke.json"
"$BINARY" --doctor-json > "$DOCTOR_JSON"
python3 - "$DOCTOR_JSON" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    report = json.load(f)
assert report["schema_version"] == 1
assert report["product"] == "gPTP Studio"
assert report["privacy"]["network_identifiers_redacted"] is True
assert isinstance(report["interfaces"], list)
assert report["accuracy_claim"] == "not-calibrated"
PY

for notice in LICENSE NOTICE EULA.md THIRD_PARTY_NOTICES.md; do
  test -s "$DIST_ROOT/$notice" || {
    echo "missing distribution license payload: $notice" >&2
    exit 1
  }
done

grep -q "Apache License" "$DIST_ROOT/LICENSE"
grep -q "Glaze" "$DIST_ROOT/THIRD_PARTY_NOTICES.md"
grep -q "Racket CS" "$DIST_ROOT/THIRD_PARTY_NOTICES.md"
grep -q "不会撤销、限制或缩小" "$DIST_ROOT/EULA.md"

echo "== archive =="
ARCHIVE="gPTP-Studio-${TAG_LABEL}-linux-x64.tar.gz"
tar -czf "$ARCHIVE" -C dist gptp-studio-distributed
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

echo "packaged: $ARCHIVE"
