---
ipf: "1.0"
id: mft
name: macOS File Versions
version: 0.0.1
description: Checkpoint, compare, undo and restore file versions on macOS.
author: earchibald
homepage: https://github.com/earchibald/macos-file-tools
components:
  skills: skills/
requires:
  binaries:
    - name: mft
      install_hint: "curl -fsSL https://github.com/earchibald/macos-file-tools/releases/latest/download/install.sh | sh"
---

# macOS File Versions

Teaches the agent to use the `mft` tools: small commands that read and write
the version store macOS keeps for every file, the one behind "Browse All
Versions" in document apps. The agent can checkpoint a file before changing
it, show what changed, and take a change back.

## Setup

1. Install the tools. This puts `mft` and a command per tool in `~/.local/bin`:

   `curl -fsSL https://github.com/earchibald/macos-file-tools/releases/latest/download/install.sh | sh`

2. Make sure `~/.local/bin` is on the PATH of your login shell. The plugin
   stays orange (needs configuration) until `mft` can be found there.
3. Enable the plugin.

## Optional: store a version before every file write

Iris plugins cannot add hooks, so this step is yours to take. Merge the
`hooks` entry from `settings-hooks.json`, in this plugin's folder, into
`~/.iris/config/settings.json`. It runs `mft hook` before each `write_file`
call. The hook prints nothing and always exits 0, so it cannot block a write.
It does nothing in sandboxed conversations, where `mft` is not available.

## More

Run `mft guide` in a terminal for a one-page reference, or see the homepage.
