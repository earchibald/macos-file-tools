# mft: small macOS file tools with one interface

macOS keeps per-file versions in a system store, the one behind "Browse All Versions" in document apps. `mft` is a set of small command-line tools that read and write that store, so a script or an AI agent can checkpoint a file before changing it, see what changed, and take a change back.

Every tool takes its arguments the same way and prints the same kind of output: one JSON record per file, with failures as records too. Learn one and you know them all.

```console
$ ver-add --note "before cleanup" notes.txt
{"created":true,"dry_run":false,"ok":true,"path":"/Users/me/notes.txt","tool":"ver-add","version":{"id":"8f8b11b2-…","note":"before cleanup",…}}

$ ver-diff --text notes.txt
--- /Users/me/notes.txt (8f8b11b2-…)
+++ /Users/me/notes.txt (current)
@@ -1 +1 @@
-first draft
+second draft

$ ver-undo --text notes.txt
restored	8f8b11b2-…	/Users/me/notes.txt
```

## Install

Requires macOS 13 or later. The release is a universal binary, signed with a Developer ID and notarized by Apple.

```sh
curl -fsSL https://raw.githubusercontent.com/earchibald/macos-file-tools/v0.0.1/install.sh | sh
```

This puts `mft` and a command for each tool in `~/.local/bin`. Set `MFT_PREFIX` to install elsewhere. To install by hand, download `mft-macos-universal.zip` from the [releases page](https://github.com/earchibald/macos-file-tools/releases), unpack it and run `./install.sh` inside.

Then run `mft guide` for a one-page orientation, or `mft selftest` to check that versioning behaves as expected on your Mac.

### As a Claude Code plugin

```
/plugin marketplace add earchibald/macos-file-tools
/plugin install mft@macos-file-tools
```

The plugin adds three things:

- the tools on the agent's command path (run `mft-install` once to fetch the signed program);
- a skill, [`macos-file-versions`](plugin/skills/macos-file-versions/SKILL.md), that teaches the agent when and how to use them;
- a hook that stores a disposable version of a file just before each edit, so any edit can be undone with `ver-undo`.

For another agent, give it [`SKILL.md`](plugin/skills/macos-file-versions/SKILL.md) or the output of `mft guide`, and wire `mft hook` to whatever runs before a file edit. It reads the edit event as JSON on standard input, never prints, and always exits 0.

## The tools

| Tool | What it does |
|---|---|
| `ver-ls` | List the stored versions of files |
| `ver-add` | Store the current contents as a new version (skipped if unchanged) |
| `ver-cat` | Write one version's bytes to standard output |
| `ver-diff` | Compare a version with the current file or another version |
| `ver-restore` | Replace a file's contents with a stored version |
| `ver-undo` | Go back to the most recent contents that differ; run again to redo |
| `ver-rm` | Delete chosen versions |
| `ver-prune` | Delete old versions by rule |
| `ver-status` | Report whether and how a file is versioned |
| `ver-cp` | Copy a file together with its versions |
| `ver-guard` | Store versions of files, then run a command |
| `file-trash` | Move files to the Trash and report where they went |
| `file-clone` | Make a copy that shares storage with the original |
| `file-swap` | Exchange two files in one atomic step |

Each is also a subcommand: `mft ver-ls FILE` and `ver-ls FILE` are the same.

`mft` itself adds `guide` (orientation), `describe` (the whole interface as JSON), `selftest` (check this Mac), `link` (create the per-tool commands) and `hook` (pre-edit checkpoint for agents).

## The interface

**Calling.** `tool [options] FILE...`. Options first, files last, `--` ends options. A lone `-` reads the file list from standard input, one path per line (`-0` for NUL-separated).

**Options every tool has.** `--text` prints tab-separated text for people. `-q`/`--quiet` prints nothing on success. `-h`/`--help` shows options and examples.

**Options every changing tool has.** `-n`/`--dry-run` reports what would happen and changes nothing. `--timeout SECONDS` gives up if another program holds the file that long (default 10).

**Choosing a version.** `-r`/`--rev` takes:

| Selector | Meaning |
|---|---|
| an id, or a unique prefix | The version with that id, as printed by `ver-ls` |
| `latest`, `oldest` | The newest or oldest stored version |
| `@N` | The Nth newest; `@1` is latest. Handy by hand, but positions shift as versions are added |
| `tag:NAME` | The newest version stored with `--tag NAME` |
| `before:WHEN` | The newest version dating from WHEN or earlier: `15m`, `2h`, `3d`, or an ISO 8601 date-time |

**Output.** One JSON object per line, one per file operand. Successes go to standard output with `"ok": true`; failures go to standard error with `"ok": false`. Every record has `tool` and the absolute `path`. Two exceptions: `ver-cat` prints the version's bytes, and `ver-guard` prints nothing of its own.

**Failures.** A failure record carries `error.code` (stable, for programs), `error.message` (for people) and `error.hint` (what to try next). A tool carries on after one file fails, so a batch always yields a record per file.

| Exit | `error.code` | Meaning |
|---|---|---|
| 0 | | Every file succeeded |
| 1 | | Files failed for different reasons; read the records |
| 64 | | Bad usage (plain text from the argument parser) |
| 65 | `no_versions`, `no_such_version`, `ambiguous_version` | The selector matched nothing usable |
| 66 | `no_such_file` | The file does not exist |
| 69 | `versions_unsupported`, `unsupported_operation` | The volume cannot do this |
| 73 | `already_exists` | The destination already exists |
| 74 | `io_error` | Any other file-system failure |
| 75 | `busy`, `precondition_failed` | Try again: the file was held, or its versions changed |
| 77 | `permission_denied` | macOS refused access |

**Safe defaults.** Nothing prompts. `ver-restore` and `ver-undo` store the contents they replace first, so either can be undone. `ver-rm` needs `--rev` or `--all` spelled out. `ver-prune` leaves tagged versions alone.

## Things to know about macOS versions

- Versions follow a file through rename, move, in-place edits and saves that replace the file. A plain copy starts with none; `ver-cp` carries them over.
- Deleting a file deletes its versions. Moving it to another volume loses them.
- Storing a version is nearly free on APFS: it shares storage with the file until one of them changes.
- Versions are local to one Mac and are not included in Time Machine backups. They complement git and backups; they do not replace them.
- Versions need an APFS volume. `ver-status --probe FILE` tells you for certain.
- Notes, tags and authors are kept by `mft` beside the system store, in `~/Library/Application Support/mft`. Other apps see the versions but not those labels.

How these were established, and what is still untested, is in [docs/design.md](docs/design.md).

## Building and testing

```sh
swift build                 # debug build at .build/debug/mft
swift test                  # drives the built binary; includes the interface contract tests
scripts/package.sh          # universal build, ad hoc signed, packed into dist/
```

The contract tests fail if a tool's output differs from what `mft describe` documents, if a changing tool lacks `--dry-run`, or if a dry run changes anything.

## Releasing

1. Set the version in `Sources/MFTCore/Conventions.swift`, `plugin/.claude-plugin/plugin.json` and `plugin/bin/mft-install`, and add a section to `CHANGELOG.md`. A test checks the three agree.
2. Tag and push: `git tag v0.0.1 && git push origin v0.0.1`. The Release workflow builds and tests at the tag.
3. Publish the signed build: `scripts/release.sh --notarize PROFILE`, where PROFILE is a `notarytool` keychain profile. It signs with your Developer ID, has Apple notarize the zip, and creates the GitHub release.

If the repository has signing secrets, the workflow does step 3 itself. See the comments at the top of [`.github/workflows/release.yml`](.github/workflows/release.yml).
