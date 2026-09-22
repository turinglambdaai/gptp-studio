#!/usr/bin/env bash
# Build the relocatable Linux distribution, smoke-test the distributed binary,
# verify license payloads, record build provenance, and produce a tarball +
# SHA-256 checksum.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-${GPTP_STUDIO_VERSION:-1.0.0}}"
TAG_LABEL="${2:-v$VERSION}"
SELF_CHECK_PORT="${GPTP_STUDIO_SELFCHECK_PORT:-18732}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid package version: $VERSION (expected x.y.z)" >&2
  exit 2
fi

GLAZE_REVISION="$(tr -d '[:space:]' < GLAZE_REVISION)"
if [[ ! "$GLAZE_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "invalid pinned Glaze revision: $GLAZE_REVISION" >&2
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

# Record enough provenance to identify the exact source/framework/runtime used
# for an official binary without embedding machine-specific identifiers.
# Do not `source /etc/os-release`: it defines VERSION and can silently overwrite
# the product version used by the rest of this release script.
SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null || printf 'unknown')"
RACKET_VERSION="$(racket --version 2>&1 | head -n 1)"
BUILD_ARCH="$(uname -m)"
python3 - "$DIST_ROOT/BUILD-INFO.json" \
  "$VERSION" "$TAG_LABEL" "$SOURCE_COMMIT" "$GLAZE_REVISION" \
  "$RACKET_VERSION" "$BUILD_ARCH" <<'PY'
import json
import os
import sys

out, version, tag, source_commit, glaze_revision, racket_version, arch = sys.argv[1:]

def os_release():
    values = {}
    path = "/etc/os-release"
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                raw = raw.strip()
                if not raw or raw.startswith("#") or "=" not in raw:
                    continue
                key, value = raw.split("=", 1)
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                values[key] = value
    except OSError:
        pass
    return values

osr = os_release()
payload = {
    "schema_version": 1,
    "product": "gPTP Studio",
    "platform": "linux",
    "version": version,
    "tag": tag,
    "source_commit": source_commit,
    "glaze_revision": glaze_revision,
    "racket_version": racket_version,
    "build_arch": arch,
    "build_distro": {
        "id": osr.get("ID", "unknown"),
        "version_id": osr.get("VERSION_ID", "unknown"),
    },
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
PY

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
assert report["platform"] == "linux"
assert report["privacy"]["network_identifiers_redacted"] is True
assert report["privacy"]["host_identifiers_redacted"] is True
host = report["host"]
assert host["fingerprint_schema_version"] == 1
assert host["privacy"]["hostname_omitted"] is True
assert host["privacy"]["machine_id_omitted"] is True
assert host["privacy"]["hardware_serials_omitted"] is True
assert isinstance(host["kernel"]["release"], str)
assert isinstance(host["kernel"]["architecture"], str)
assert isinstance(report["interfaces"], list)
for entry in report["interfaces"]:
    nic = entry["nic"]
    assert "mac" not in nic and "ips" not in nic
    assert "driver_version" in nic
    assert "firmware_version" in nic
    assert "bus_info" in nic
    assert "phc_clock_name" in nic
assert report["accuracy_claim"] == "not-calibrated"
PY

for notice in LICENSE NOTICE EULA.md THIRD_PARTY_NOTICES.md; do
  test -s "$DIST_ROOT/$notice" || {
    echo "missing distribution license payload: $notice" >&2
    exit 1
  }
done

test -s "$DIST_ROOT/BUILD-INFO.json"
python3 - "$DIST_ROOT/BUILD-INFO.json" "$VERSION" "$GLAZE_REVISION" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    info = json.load(f)
assert info["schema_version"] == 1
assert info["product"] == "gPTP Studio"
assert info["platform"] == "linux"
assert info["version"] == sys.argv[2]
assert info["glaze_revision"] == sys.argv[3]
assert len(info["source_commit"]) in (7, 40) or info["source_commit"] == "unknown"
assert info["racket_version"]
assert info["build_arch"]
assert info["build_distro"]["id"]
assert info["build_distro"]["version_id"]
PY

grep -q "Apache License" "$DIST_ROOT/LICENSE"
grep -q "Glaze" "$DIST_ROOT/THIRD_PARTY_NOTICES.md"
grep -q "Racket CS" "$DIST_ROOT/THIRD_PARTY_NOTICES.md"
grep -q "不会撤销、限制或缩小" "$DIST_ROOT/EULA.md"

echo "== archive =="
ARCHIVE="gPTP-Studio-${TAG_LABEL}-linux-x64.tar.gz"
tar -czf "$ARCHIVE" -C dist gptp-studio-distributed
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

echo "packaged: $ARCHIVE"
