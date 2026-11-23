#!/bin/bash
# Publishes a signed, notarized release from this Mac.
#
#   scripts/release.sh --notarize PROFILE [--sign IDENTITY]
#
# PROFILE is a notarytool keychain profile (see `xcrun notarytool store-credentials`).
# IDENTITY defaults to the only "Developer ID Application" identity in the keychain.
#
# The tag v<version> must already exist on GitHub: push it first, and let the
# Release workflow check the build and tests at that tag.
set -euo pipefail

identity=""
profile=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) identity="$2"; shift 2 ;;
    --notarize) profile="$2"; shift 2 ;;
    *) echo "release.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$profile" ] || { echo "release.sh: --notarize PROFILE is required" >&2; exit 2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(sed -n 's/^public let mftVersion = "\(.*\)"$/\1/p' Sources/MFTCore/Conventions.swift)"
tag="v$version"

if [ -z "$identity" ]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)"
  [ -n "$identity" ] || { echo "release.sh: no Developer ID Application identity in the keychain" >&2; exit 1; }
fi

[ -z "$(git status --porcelain)" ] || { echo "release.sh: commit or stash your changes first" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse "$tag^{commit}" 2>/dev/null)" ] || {
  echo "release.sh: check out the commit tagged $tag first (git tag $tag && git push origin $tag)" >&2
  exit 1
}

scripts/package.sh --sign "$identity" --notarize "$profile"

# The release notes are the section of CHANGELOG.md for this version.
notes="$(awk -v v="$version" '$0 ~ "^## " v { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md)"
gh release create "$tag" --verify-tag --title "mft $version" --notes "$notes" \
  dist/mft-macos-universal.zip dist/mft-macos-universal.zip.sha256 install.sh
