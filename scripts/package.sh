#!/bin/bash
# Builds the universal mft binary and packs it as dist/mft-macos-universal.zip.
#
#   scripts/package.sh                          ad hoc signature, for testing
#   scripts/package.sh --sign IDENTITY          sign with a Developer ID Application identity
#   scripts/package.sh --sign IDENTITY --notarize PROFILE
#                                               also notarize, using a notarytool keychain profile
#
# In CI, notarization can use NOTARY_APPLE_ID, NOTARY_TEAM_ID and NOTARY_PASSWORD
# instead of a keychain profile: pass --notarize env.
set -euo pipefail

identity="-"
notarize=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) identity="$2"; shift 2 ;;
    --notarize) notarize="$2"; shift 2 ;;
    *) echo "package.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
version="$(sed -n 's/^public let mftVersion = "\(.*\)"$/\1/p' Sources/MFTCore/Conventions.swift)"
[ -n "$version" ] || { echo "package.sh: cannot read the version from Conventions.swift" >&2; exit 1; }

scripts/sync-plugins.sh --check

echo "== Building mft $version (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
built="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/mft"

stage="dist/mft-$version"
rm -rf dist
mkdir -p "$stage/bin" "$stage/share/mft/completions"
cp "$built" "$stage/bin/mft"

echo "== Signing ($([ "$identity" = "-" ] && echo "ad hoc" || echo "Developer ID"))"
if [ "$identity" = "-" ]; then
  codesign --force --options runtime --identifier io.github.earchibald.mft --sign - "$stage/bin/mft"
else
  codesign --force --options runtime --timestamp --identifier io.github.earchibald.mft \
    --sign "$identity" "$stage/bin/mft"
fi
codesign --verify --strict "$stage/bin/mft"

echo "== Assembling $stage"
"$stage/bin/mft" link --dir "$stage/bin" --quiet
"$stage/bin/mft" guide > "$stage/share/mft/guide.txt"
"$stage/bin/mft" describe > "$stage/share/mft/interface.json"
"$stage/bin/mft" --generate-completion-script zsh > "$stage/share/mft/completions/_mft"
"$stage/bin/mft" --generate-completion-script bash > "$stage/share/mft/completions/mft.bash"
"$stage/bin/mft" --generate-completion-script fish > "$stage/share/mft/completions/mft.fish"
cp plugins/shared/SKILL.md "$stage/share/mft/SKILL.md"
# The plugins, so each agent can install its own from a stable local path.
mkdir -p "$stage/share/mft/plugins"
cp -R plugins/claude-code plugins/antigravity plugins/iris "$stage/share/mft/plugins/"
cp install.sh README.md "$stage/"

zip="dist/mft-macos-universal.zip"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$stage" "$zip"

if [ -n "$notarize" ]; then
  [ "$identity" != "-" ] || { echo "package.sh: --notarize needs --sign" >&2; exit 2; }
  echo "== Notarizing (this waits for Apple)"
  if [ "$notarize" = "env" ]; then
    xcrun notarytool submit "$zip" --wait \
      --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" \
      | tee dist/notary.log
  else
    xcrun notarytool submit "$zip" --wait --keychain-profile "$notarize" | tee dist/notary.log
  fi
  grep -q "status: Accepted" dist/notary.log || { echo "package.sh: notarization was not accepted" >&2; exit 1; }
  # A bare program cannot carry a stapled ticket, so there is nothing to
  # staple: macOS looks the ticket up online the first time the program runs.
fi

(cd dist && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")
echo "== Done"
ls -l "$zip" "$zip.sha256"
