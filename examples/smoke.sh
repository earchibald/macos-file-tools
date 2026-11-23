#!/bin/bash
# Builds the example suite and drives every tool in a scratch folder.
# Usage: examples/smoke.sh        (run from anywhere; needs Xcode's Swift)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
swift build -c release --package-path "$here/mft" >/dev/null 2>&1 || { echo "build failed" >&2; exit 1; }
mft="$here/mft/.build/release/mft"

work="$(mktemp -d "${TMPDIR:-/tmp}/mft-smoke.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1

# One binary, one symlink per tool.
mkdir bin
for tool in ver-ls ver-add ver-cat ver-restore ver-rm file-trash; do ln -s "$mft" "bin/$tool"; done
PATH="$work/bin:$PATH"

run() { echo "\$ $*"; "$@"; echo "[exit $?]"; echo; }

printf 'first draft\n'  > notes.txt; run ver-add notes.txt
sleep 1
printf 'second draft\n' > notes.txt; run ver-add notes.txt
printf 'third draft, not saved as a version\n' > notes.txt

run ver-ls notes.txt
run ver-ls --text notes.txt
run ver-cat --rev oldest notes.txt
run ver-restore --dry-run --rev oldest notes.txt
run ver-restore --rev oldest notes.txt
run cat notes.txt
run ver-ls --text notes.txt
run ver-rm --rev @1 notes.txt
run ver-rm --all --dry-run notes.txt

echo "# failures"
run ver-ls missing.txt
run ver-ls --text missing.txt
run ver-cat --rev @9 notes.txt
run ver-ls notes.txt missing.txt
run ver-rm notes.txt

echo "# same code through the multi-call binary"
run "$mft" ver-rm --all notes.txt
run "$mft" file-trash --dry-run notes.txt
