#!/bin/bash
# Copies the files every plugin shares from their one source into each plugin.
#
#   scripts/sync-plugins.sh           update the copies
#   scripts/sync-plugins.sh --check   change nothing; fail if any copy is out of date
#
# Sources:  plugins/shared/SKILL.md, plugins/shared/bin/, install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

check=0
[ "${1:-}" = "--check" ] && check=1
stale=0

# sync SOURCE DESTINATION: one file.
sync() {
  if [ "$check" = 1 ]; then
    cmp -s "$1" "$2" || { echo "out of date: $2 (source: $1)" >&2; stale=1; }
  else
    mkdir -p "$(dirname "$2")"
    cp -p "$1" "$2"
  fi
}

for plugin in plugins/claude-code plugins/antigravity plugins/iris/mft; do
  sync plugins/shared/SKILL.md "$plugin/skills/macos-file-versions/SKILL.md"
done

# Iris copies plugins without keeping executable bits and cannot add to PATH,
# so it gets no launchers: it requires mft to be installed instead.
for plugin in plugins/claude-code plugins/antigravity; do
  for launcher in plugins/shared/bin/*; do
    sync "$launcher" "$plugin/bin/$(basename "$launcher")"
  done
  sync install.sh "$plugin/scripts/install.sh"
  # A launcher removed from the source must not linger in a copy.
  for copy in "$plugin"/bin/*; do
    [ -e "plugins/shared/bin/$(basename "$copy")" ] && continue
    if [ "$check" = 1 ]; then echo "stale launcher: $copy" >&2; stale=1; else rm "$copy"; fi
  done
done

[ "$stale" = 0 ] || { echo "Run scripts/sync-plugins.sh" >&2; exit 1; }
