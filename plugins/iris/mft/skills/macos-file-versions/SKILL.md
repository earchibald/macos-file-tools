---
name: macos-file-versions
description: Checkpoint, list, compare, undo and restore versions of files on macOS with the mft tools (ver-add, ver-ls, ver-diff, ver-undo, ver-restore and others). Use before a risky or multi-file edit, when the user asks to undo or roll back a change to a file, to see what a file looked like earlier or what changed, to copy a file with its history, or when asked about macOS file versions or "Browse All Versions".
---

# macOS file versions

macOS keeps per-file versions in a system store, the one behind "Browse All Versions" in document apps. The `mft` tools read and write that store from the command line. A version is a full copy of a file's contents at one moment. Storing one costs almost nothing on APFS, so store them freely.

Versions are a safety net for work in progress. They are not a replacement for git: they are local to this Mac, are not in backups, and belong to one file each.

## First check the tools are there

Run `mft --version`. If the command is missing or fails with `not_installed`, ask the user before installing. Run `mft-install` if that command exists; otherwise run `curl -fsSL https://github.com/earchibald/macos-file-tools/releases/latest/download/install.sh | sh`. Either downloads the signed release from GitHub into `~/.local/bin`.

Run `mft guide` once for a one-page reference. `mft describe` gives the same as JSON with every record field, and `TOOL --help` shows one tool's options and examples.

## How every tool behaves

- `tool [options] FILE...`: options first, files last. A lone `-` reads the file list from standard input.
- Output is one JSON object per line, one per file. Successes are on standard output with `"ok": true`.
- Failures are on standard error with `"ok": false` and `error.code`, `error.message` and `error.hint`. Match on `error.code`; follow `error.hint`.
- Every tool that changes something takes `--dry-run`. No tool ever prompts.
- `--text` gives tab-separated output for showing to a person.

## Common tasks

Checkpoint before an edit (safe to repeat; unchanged contents are not stored twice):

```sh
ver-add --note "before renaming the config keys" config.yml
```

Checkpoint several files as one named point, and return to it later:

```sh
ver-add --tag pre-refactor src/a.swift src/b.swift
ver-restore --rev tag:pre-refactor src/a.swift src/b.swift
```

Take back the last change to a file. Run it again to redo:

```sh
ver-undo notes.txt
```

See what changed since the last stored version, or between two versions:

```sh
ver-diff notes.txt
ver-diff --rev oldest --to latest notes.txt
```

List versions, then read one. Each version record has `contents_path`, a read-only file you can read directly:

```sh
ver-ls notes.txt
```

Go back to how a file was at some earlier time:

```sh
ver-restore --rev before:30m --dry-run notes.txt   # check which version first
ver-restore --rev before:30m notes.txt
```

Run a command that rewrites files, with a checkpoint first:

```sh
ver-guard config.yml -- sed -i '' 's/old/new/' config.yml
```

Copy a file and keep its versions (a plain copy has none):

```sh
ver-cp report.md report-copy.md
```

## Choosing a version

`--rev` takes an id from `ver-ls` (or a unique prefix), `latest`, `oldest`, `tag:NAME`, `before:WHEN` (a duration such as `15m`, `2h`, `3d`, or an ISO 8601 date-time), or `@N` where `@1` is the newest. Prefer ids: `@N` positions shift whenever a version is added.

## What to tell the user, and what to watch for

- `ver-restore` and `ver-undo` store the contents they replace first, so either can be undone. Say which version you restored and where the replaced contents were kept (`kept_current_as`).
- Deleting a file deletes its versions. Moving it to another volume loses them. Use `ver-cp` when history must travel.
- Versions need an APFS volume. If a tool fails with `versions_unsupported`, run `ver-status --probe FILE` and tell the user; do not invent another backup scheme silently.
- `ver-rm` and `ver-prune` delete history permanently. Use `--dry-run` first and confirm with the user unless they asked for the deletion.
- If a pre-edit hook is active, a disposable version is stored before each of your edits, with a note beginning "before" and the name of your editing tool. `ver-ls` shows whether that is happening. You then do not need to checkpoint again for single edits; add a tagged checkpoint for multi-file changes you may want to roll back together.
- A failure with `busy` means another program held the file; retry once, then report it.
