#!/usr/bin/env bash
# Install exactly the Glaze revision pinned by this repository.
# This keeps CI, release rebuilds and developer source builds reproducible.
#
# Bootstrap note: this script must run on machines where glaze (and therefore
# `raco glaze install`) is not yet available, so it performs the clone/link
# itself and then verifies the result with `raco glaze doctor` — the same
# check the CLI's own install path performs.
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

# --name registers the package under its canonical name. Without it raco
# names a link after its checkout directory (glaze-src, ...), which is how
# machines drift into duplicate conflicting owners of the glaze collection.
# A failed remove (nothing installed, fresh CI machine) is not an error.
raco pkg remove --force glaze >/dev/null 2>&1 || true
raco pkg install --auto --no-docs --link --name glaze "$DEST"

# Since the pin >= glaze 59ca209 the CLI ships its own hygiene check; use it
# so a broken machine fails here instead of mid-build with a module error.
raco glaze doctor
printf 'Glaze revision installed: %s\n' "$REV"
