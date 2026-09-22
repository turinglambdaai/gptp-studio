#!/usr/bin/env bash
# Fail a release before packaging if the git tag and product metadata disagree.
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${1:-${GITHUB_REF_NAME:-}}"
if [[ -z "$TAG" ]]; then
  echo "error: release tag is required (example: v1.0.0)" >&2
  exit 2
fi
if [[ "$TAG" != v* ]]; then
  echo "error: release tag must start with v: $TAG" >&2
  exit 2
fi

VERSION="${TAG#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: release version must be x.y.z for desktop bundle metadata: $VERSION" >&2
  exit 2
fi

extract_define_string() {
  local file="$1"
  local name="$2"
  sed -nE "s/^\(define[[:space:]]+$name[[:space:]]+\"([^\"]+)\"\).*$/\1/p" "$file" | head -n 1
}

INFO_VERSION="$(extract_define_string info.rkt version)"
APP_VERSION="$(extract_define_string app/state.rkt app-version)"

fail=0
if [[ "$INFO_VERSION" != "$VERSION" ]]; then
  echo "error: info.rkt version=$INFO_VERSION but tag=$TAG" >&2
  fail=1
fi
if [[ "$APP_VERSION" != "$VERSION" ]]; then
  echo "error: app/state.rkt app-version=$APP_VERSION but tag=$TAG" >&2
  fail=1
fi
if ! grep -Eq "^##[[:space:]]+$VERSION([[:space:]]|$)" CHANGELOG.md; then
  echo "error: CHANGELOG.md has no release heading for $VERSION" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "release metadata is inconsistent; update versions/changelog before tagging" >&2
  exit 1
fi

printf 'release version verified: %s\n' "$VERSION"
printf '%s\n' "$VERSION"
