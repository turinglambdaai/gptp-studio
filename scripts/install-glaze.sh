#!/usr/bin/env bash
# Install exactly the Glaze revision pinned by this repository.
# This keeps CI, release rebuilds and developer source builds reproducible.
set -euo pipefail

cd "$(dirname "$0")/.."

REV_FILE="GLAZE_REVISION"
DEST="${1:-${GPTP_STUDIO_GLAZE_DIR:-$HOME/glaze-src}}"

if [[ ! -s "$REV_FILE" ]]; then
  echo "error: missing $REV_FILE" >&2
  exit 2
fi

REV="$(tr -d '[:space:]' < "$REV_FILE")"
if [[ ! "$REV" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: invalid Glaze revision in $REV_FILE: $REV" >&2
  exit 2
fi

rm -rf "$DEST"
mkdir -p "$DEST"
git -C "$DEST" init -q
git -C "$DEST" remote add origin https://github.com/turinglambdaai/glaze.git
git -C "$DEST" fetch -q --depth 1 origin "$REV"
git -C "$DEST" checkout -q --detach FETCH_HEAD

ACTUAL="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$ACTUAL" != "$REV" ]]; then
  echo "error: Glaze checkout mismatch: expected=$REV actual=$ACTUAL" >&2
  exit 1
fi

raco pkg install --auto --no-docs --link "$DEST"
printf 'Glaze revision installed: %s\n' "$REV"
