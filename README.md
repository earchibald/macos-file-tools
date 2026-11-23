# mft: small macOS file tools with one interface

macOS keeps per-file versions in a system store, the one behind "Browse All Versions" in document apps. `mft` is a set of small command-line tools that read and write that store, so a script or an AI agent can checkpoint a file before changing it, see what changed, and take a change back.

Every tool takes its arguments the same way and prints the same kind of output: one JSON record per file, with failures as records too. Learn one and you know them all.

```console
$ ver-add --note "before cleanup" notes.txt        # store a version
$ ver-diff --text notes.txt                        # what changed since?
--- /Users/me/notes.txt (94f57a17-2e24-43d8-a2cb-91a41d9f23ba)
+++ /Users/me/notes.txt (current)
@@ -1 +1 @@
-second draft
+third draft
$ ver-undo --text notes.txt                        # take the change back
restored	94f57a17-2e24-43d8-a2cb-91a41d9f23ba	/Users/me/notes.txt
```

## Contents

- [Install](#install)
- [A five-minute tour](#a-five-minute-tour)
- [How macOS versions behave](#how-macos-versions-behave)
- [The interface every tool shares](#the-interface-every-tool-shares)
- [Tool reference](#tool-reference)
- [The `mft` command](#the-mft-command)
- [Recipes](#recipes)
- [Using it from an agent](#using-it-from-an-agent): [Claude Code](#claude-code), [Antigravity](#antigravity), [Iris](#iris), [any other agent](#any-other-agent)
- [Settings and files](#settings-and-files)
- [Troubleshooting](#troubleshooting)
- [Limits](#limits)
- [Building, testing and releasing](#building-testing-and-releasing)

## Install

Requires macOS 13 or later. The release is one universal program (Apple silicon and Intel), signed with a Developer ID and notarized by Apple.

```sh
curl -fsSL https://github.com/earchibald/macos-file-tools/releases/latest/download/install.sh | sh
```

This checks the download against its published checksum, then puts `mft` and a command for each tool in `~/.local/bin`, and supporting files (the agent plugins, shell completions, a copy of the guide) in `~/.local/share/mft`.

| To do this | Do this |
|---|---|
| Install somewhere else | `MFT_PREFIX=/usr/local sh install.sh` (programs go in `$MFT_PREFIX/bin`) |
| Install a particular release | `MFT_VERSION=0.0.1 sh install.sh` |
| Install by hand | Download `mft-macos-universal.zip` from the [releases page](https://github.com/earchibald/macos-file-tools/releases), unpack it, run `./install.sh` inside |
| Check it works on this Mac | `mft selftest --text` |
| Update | Run the installer again |
| Uninstall | `cd ~/.local/bin && rm mft ver-* file-trash file-clone file-swap`, then `rm -r ~/.local/share/mft` |

If `mft` is not found afterwards, add the folder to your PATH: `export PATH="$HOME/.local/bin:$PATH"`.

## A five-minute tour

Make a file and store a version of it. The record tells you the version's id and where its contents live.

```console
$ echo "first draft" > notes.txt
$ ver-add --note "before cleanup" notes.txt
{"created":true,"dry_run":false,"ok":true,"path":"/Users/me/notes.txt","tool":"ver-add","version":{"by":null,"contents_path":"/System/Volumes/Data/.DocumentRevisions-V100/PerUID/501/1a2b/com.apple.documentVersions/02382E9C-E5FD-4FA4-9BD9-3D7A053D91E2.txt","date":"2026-11-23T23:35:23Z","discardable":false,"id":"02382e9c-e5fd-4fa4-9bd9-3d7a053d91e2","index":1,"note":"before cleanup","size":12,"tag":null}}
```

Change the file, store another version with a tag, change it again, and list what is stored. `--text` is the same information for reading by eye.

```console
$ echo "second draft" > notes.txt
$ ver-add --tag v2 notes.txt
$ echo "third draft" > notes.txt
$ ver-ls --text notes.txt
@1	94f57a17-2e24-43d8-a2cb-91a41d9f23ba	2026-11-23T23:35:23Z	v2	-	/Users/me/notes.txt
@2	02382e9c-e5fd-4fa4-9bd9-3d7a053d91e2	2026-11-23T23:35:23Z	-	before cleanup	/Users/me/notes.txt
```

See what changed since the last stored version, then take it back. The undo stores the contents it replaces, so nothing is lost and a second `ver-undo` is a redo.

```console
$ ver-diff --text notes.txt
--- /Users/me/notes.txt (94f57a17-2e24-43d8-a2cb-91a41d9f23ba)
+++ /Users/me/notes.txt (current)
@@ -1 +1 @@
-second draft
+third draft
$ ver-undo notes.txt
{"dry_run":false,"kept_current_as":"793761e4-057a-41e4-bad5-191af9474476","ok":true,"path":"/Users/me/notes.txt","restored":"94f57a17-2e24-43d8-a2cb-91a41d9f23ba","tool":"ver-undo","verified":true}
$ cat notes.txt
second draft
```

Go back to any version by id, tag, position or time. Try it with `--dry-run` first.

```console
$ ver-restore --rev oldest --dry-run notes.txt
{"dry_run":true,"kept_current_as":null,"ok":true,"path":"/Users/me/notes.txt","restored":"02382e9c-e5fd-4fa4-9bd9-3d7a053d91e2","tool":"ver-restore","verified":false}
$ ver-restore --rev tag:v2 notes.txt
$ ver-restore --rev before:30m notes.txt
```

When something goes wrong you get a record on standard error and a meaningful exit status.

```console
$ ver-ls missing.txt
{"error":{"code":"no_such_file","hint":"Check the path. Relative paths are resolved against the current folder.","message":"no such file or directory"},"ok":false,"path":"/Users/me/missing.txt","tool":"ver-ls"}
$ echo $?
66
```

## How macOS versions behave

A version is a full copy of a file's contents at one moment, held in a system store that every app on the Mac shares. Knowing a few facts about it avoids most surprises. Each was tested on macOS 27; `mft selftest` re-checks them on your Mac.

**What keeps a file's versions**

- Editing the file in place.
- Renaming it, or moving it within the same volume.
- A save that writes a new file and renames it over the old one, which is how many editors and `sed -i` save.
- `git checkout` and `git stash` of a tracked file that exists on both sides.

**What loses them**

- Deleting the file. Creating a new file with the same name does not bring them back.
- Copying: the copy starts with none. Use `ver-cp` to carry them over.
- Moving the file to another volume.
- Restoring the file from a Time Machine backup. Versions are not backed up.

**What they cost.** On APFS a new version shares storage with the file until one of them changes, so storing one is nearly instant and takes almost no space: a 300 MB file took 0.01 seconds and no measurable disk space.

**Where they work.** APFS volumes. Not ExFAT, and not reliably on network volumes. `ver-status --probe FILE` tells you for certain.

**What a version's date means.** It is the modification date of the contents the version holds, not the moment it was stored.

**What `mft` adds.** The system store has no place for a reason, an author or a tag, so `mft` keeps those beside it, in `~/Library/Application Support/mft`, keyed by version id. They follow the file through renames. Other apps see the versions but not these labels.

**Disposable versions.** A version stored with `--auto` is marked as one macOS may delete when disk space runs low. Automatic checkpoints use this; deliberate ones do not.

**Versions are a safety net, not a history.** They are local to one Mac and one file each. They complement git and backups; they do not replace them.

## The interface every tool shares

### Calling

```
tool [options] FILE...
```

Options come first, files last, and `--` ends the options. Most tools take any number of files and treat each one independently. A lone `-` reads the list of files from standard input, one path per line, or separated by NUL with `-0`:

```sh
git ls-files '*.md' | ver-add --tag pre-edit -
find . -name '*.txt' -print0 | ver-ls -0 -
```

Each tool is also a subcommand of `mft`: `ver-ls FILE` and `mft ver-ls FILE` are the same.

### Options

| Option | On | Meaning |
|---|---|---|
| `--text` | every tool | Print tab-separated text for people instead of JSON |
| `-q`, `--quiet` | every tool | Print nothing on success |
| `-h`, `--help` | every tool | Show the tool's options and examples |
| `-n`, `--dry-run` | every tool that changes something | Report what would happen; change nothing |
| `--timeout SECONDS` | every tool that changes something | Give up if another program holds the file this long. Default 10 |
| `-r`, `--rev SELECTOR` | every tool that acts on one version | Which version |
| `-0`, `--null` | every tool that takes a file list | With `-`, paths on standard input end in NUL |

### Choosing a version

`--rev` accepts the same selectors everywhere:

| Selector | Meaning |
|---|---|
| an id, or a unique prefix of one | The version with that id, as printed by `ver-ls`. Case does not matter |
| `latest` | The newest stored version |
| `oldest` | The oldest stored version |
| `@N` | The Nth newest; `@1` is `latest` |
| `tag:NAME` | The newest version stored with `--tag NAME` |
| `before:WHEN` | The newest version whose contents date from WHEN or earlier |

`WHEN` is a duration back from now (`90s`, `15m`, `2h`, `3d`, `1w`) or an ISO 8601 date or date-time (`2026-11-23`, `2026-11-23T10:00:00Z`).

Programs should use ids. `@N` positions shift every time a version is added or removed, so they suit a person at a prompt and are a trap in a script.

### Output

One JSON object per line, one per file. Keys are in alphabetical order.

- A file that succeeded gives a record on **standard output** with `"ok": true`.
- A file that failed gives a record on **standard error** with `"ok": false`.
- Every record has `tool` and the absolute `path` of the file.
- A value that does not apply is `null`; a key is never missing.

A version appears as an object with these fields, wherever it turns up:

| Field | Meaning |
|---|---|
| `id` | Stable identifier. Pass it to `--rev` |
| `index` | Position, 1 is the newest. Changes as versions come and go |
| `date` | Modification date of the contents, ISO 8601 |
| `size` | Bytes |
| `discardable` | `true` if macOS may delete it to free space |
| `contents_path` | A read-only file holding the version's contents. Read it directly |
| `note` | Why it was stored, or `null` |
| `tag` | A name shared by versions stored together, or `null` |
| `by` | Who stored it, or `null` |

Two tools print something else, because their output belongs to something else: `ver-cat` prints the version's bytes, and `ver-guard` prints only what the command it runs prints.

Output never depends on whether a terminal is attached. Nothing is coloured and nothing prompts.

### Failures

A failure record has an `error` object with three fields: `code`, a stable string for programs to match; `message`, for people; and `hint`, the next thing to try.

A tool carries on after one file fails, so a batch always yields exactly one record per file. The exit status summarises:

| Exit | `error.code` | Meaning |
|---|---|---|
| 0 | | Every file succeeded |
| 1 | | Files failed for different reasons; read the records |
| 64 | | Bad usage. The message is plain text from the argument parser |
| 65 | `no_versions` | The file has no stored versions |
| 65 | `no_such_version` | The selector matched no version |
| 65 | `ambiguous_version` | An id prefix matched more than one version |
| 66 | `no_such_file` | The file does not exist |
| 69 | `versions_unsupported` | This volume cannot store versions |
| 69 | `unsupported_operation` | This volume or kind of item cannot do the operation |
| 73 | `already_exists` | The destination already exists |
| 74 | `io_error` | Any other file-system failure |
| 75 | `busy` | Another program held the file longer than `--timeout`. Retry |
| 75 | `precondition_failed` | The versions changed since you last looked. Look again and retry |
| 77 | `permission_denied` | macOS refused access to the file |

### Safe by default

- Nothing prompts, so nothing can hang waiting for an answer.
- `ver-restore` and `ver-undo` store the contents they are about to replace, so either can be undone.
- `ver-add` does not store the same contents twice in a row, so calling it often is harmless.
- `ver-rm` requires `--rev` or `--all` to be spelled out, and `ver-prune` leaves tagged versions alone.
- Every change is coordinated with other programs through the system, so an app that has the file open is told about it.

## Tool reference

Each section lists the options beyond the shared ones above, and the fields the tool's record adds to `ok`, `tool` and `path`.

### `ver-ls`

List the stored versions of files, newest first.

```
ver-ls [--limit N] FILE...
```

| Option | Meaning |
|---|---|
| `--limit N` | Show only the newest N versions |

| Field | Meaning |
|---|---|
| `versions` | Array of version objects |
| `count` | How many versions are stored, before `--limit` |

A file with no versions gives `"versions":[]` and exit 0. That is an answer, not a failure.

```console
$ ver-ls --limit 1 notes.txt
{"count":2,"ok":true,"path":"/Users/me/notes.txt","tool":"ver-ls","versions":[{"by":null,"contents_path":"/System/…/94F57A17-2E24-43D8-A2CB-91A41D9F23BA.txt","date":"2026-11-23T23:35:23Z","discardable":false,"id":"94f57a17-2e24-43d8-a2cb-91a41d9f23ba","index":1,"note":null,"size":13,"tag":"v2"}]}
```

In text mode each version is one line: position, id, date, tag, note, path.

### `ver-add`

Store the current contents of files as a new version.

```
ver-add [--note TEXT] [--tag NAME] [--by WHO] [--auto] [--from PATH] [--force] FILE...
```

| Option | Meaning |
|---|---|
| `--note TEXT` | Why this version is being stored |
| `--tag NAME` | A name shared by versions stored together; select it later with `--rev tag:NAME` |
| `--by WHO` | Who is storing it. Defaults to `$MFT_ACTOR` |
| `--auto` | Mark the version disposable: macOS may delete it to free space |
| `--from PATH` | Store this other file's contents as the version (one FILE only) |
| `--force` | Store a version even if the newest one already holds these contents |

| Field | Meaning |
|---|---|
| `version` | The version that now holds the current contents. `null` on a dry run that would create one |
| `created` | `false` when the newest version already held exactly these contents |
| `dry_run` | `true` if nothing was changed |

If the file has not changed since its newest version, nothing new is stored and `created` is `false`. Giving `--tag` then tags that existing version. A deliberate `ver-add` never reuses a disposable version, because a disposable version cannot be made permanent.

### `ver-cat`

Write one stored version's bytes to standard output.

```
ver-cat --rev SELECTOR FILE
```

| Option | Meaning |
|---|---|
| `--rev SELECTOR` | The version to read. Required |

Standard output is the version's bytes, not a record. To avoid copying, read `contents_path` from `ver-ls` instead.

```sh
ver-cat --rev before:2h notes.txt > notes.two-hours-ago.txt
```

### `ver-diff`

Compare a stored version with the current file, or with another version.

```
ver-diff [--rev SELECTOR] [--to SELECTOR] FILE
```

| Option | Meaning |
|---|---|
| `--rev SELECTOR` | The older side. Default `latest` |
| `--to SELECTOR` | The newer side. Default: the current file |

| Field | Meaning |
|---|---|
| `from` | Id of the older side |
| `to` | Id of the newer side, or `"current"` |
| `changed` | `true` if the two sides differ |
| `binary` | `true` if the contents are not text; `diff` is then empty |
| `diff` | A unified diff, empty when nothing changed |

Exit status is 0 whether or not the sides differ; read `changed`. In text mode the output is the diff itself. Folders cannot be compared.

### `ver-restore`

Replace a file's contents with a stored version.

```
ver-restore --rev SELECTOR [--no-keep-current] [--expect-latest ID] FILE...
```

| Option | Meaning |
|---|---|
| `--rev SELECTOR` | The version to restore. Required. Applied to each file in turn |
| `--no-keep-current` | Do not store the contents being replaced as a version first |
| `--expect-latest ID` | Fail with `precondition_failed` unless the file's newest version is this one. Use `none` to require that it has no versions |

| Field | Meaning |
|---|---|
| `restored` | Id of the version now in the file |
| `kept_current_as` | Id of the version holding the contents that were replaced; `null` with `--no-keep-current` |
| `verified` | `true` if the file's bytes match the version after restoring |
| `dry_run` | `true` if nothing was changed |

The restored version stays in the list. With several files and `--rev tag:NAME`, this is how a group of files goes back to a checkpoint together.

### `ver-undo`

Go back to the most recent stored contents that differ from the file.

```
ver-undo FILE...
```

It has no options of its own. The record is the same as `ver-restore`'s. Because it stores the contents it replaces, running it twice returns the file to where it started: undo, then redo.

It fails with `no_versions` if the file has none, and with `no_such_version` if every stored version matches the current contents, which means there is nothing to undo.

### `ver-rm`

Delete stored versions. The file itself is not touched.

```
ver-rm (--rev SELECTOR | --all) [--expect-latest ID] FILE...
```

| Option | Meaning |
|---|---|
| `--rev SELECTOR` | Delete this one version |
| `--all` | Delete every stored version |
| `--expect-latest ID` | Fail with `precondition_failed` unless the file's newest version is this one |

| Field | Meaning |
|---|---|
| `removed` | Ids of the versions deleted |
| `dry_run` | `true` if nothing was changed |

Exactly one of `--rev` and `--all` is required. Deletion is permanent.

### `ver-prune`

Delete old versions by rule. The file itself is not touched.

```
ver-prune [--keep-last N] [--older-than AGE] [--auto-only] [--include-tagged] FILE...
```

| Option | Meaning |
|---|---|
| `--keep-last N` | Always keep the newest N versions |
| `--older-than AGE` | Delete only versions older than this: `30d`, `12h`, `2w` |
| `--auto-only` | Delete only disposable versions, those stored with `--auto` |
| `--include-tagged` | Allow tagged versions to be deleted too |

| Field | Meaning |
|---|---|
| `removed` | Ids of the versions deleted |
| `kept` | How many versions remain |
| `dry_run` | `true` if nothing was changed |

At least one of `--keep-last` and `--older-than` is required. With both, a version goes only if it is beyond the newest N and also older than AGE. Tagged versions are kept unless `--include-tagged` is given.

### `ver-status`

Report whether and how a file is versioned.

```
ver-status [--probe] FILE...
```

| Option | Meaning |
|---|---|
| `--probe` | Find out for certain whether versions work here, by storing one and deleting it again |

| Field | Meaning |
|---|---|
| `kind` | `file`, `folder` or `package` |
| `count` | How many versions are stored |
| `latest` | The newest version object, or `null` |
| `changed_since_latest` | `true` if the file differs from its newest version; `null` if it has none |
| `versions_supported` | `true`, `false`, or `null` when unknown without `--probe` |
| `volume_format` | The volume's file system, as macOS names it |
| `volume_local` | `false` for network volumes |
| `in_icloud` | `true` if the file is in iCloud Drive |
| `warnings` | Sentences about anything likely to surprise |

```console
$ ver-status --text notes.txt
2 version(s)	file	APFS (Encrypted)	/Users/me/notes.txt
	changed since the latest version
```

### `ver-cp`

Copy a file together with its stored versions.

```
ver-cp SOURCE DESTINATION
```

| Field | Meaning |
|---|---|
| `destination` | Absolute path of the copy |
| `versions_copied` | How many versions the copy now has |
| `dry_run` | `true` if nothing was changed |

A plain copy has no versions; this one replays them onto the copy, oldest first, with their notes and tags. The copies get new ids. The destination must not exist. If the versions cannot be stored at the destination, the copy is removed and the tool fails: a copy that silently lacks its history is the problem this tool exists to avoid.

### `ver-guard`

Store versions of files, then run a command.

```
ver-guard [--note TEXT] [--tag NAME] [--by WHO] FILE... -- COMMAND [ARGUMENT...]
```

| Option | Meaning |
|---|---|
| `--note TEXT` | Why the versions are being stored. Defaults to the command line |
| `--tag NAME` | A name shared by the versions stored |
| `--by WHO` | Who is storing them. Defaults to `$MFT_ACTOR` |

It prints nothing of its own on success: standard output and the exit status are the command's. If any file cannot be versioned, the command is not run. Versions stored without `--tag` are disposable.

```sh
ver-guard config.yml -- sed -i '' 's/old/new/' config.yml
ver-guard --tag pre-format src/*.swift -- swift-format -i src/*.swift
```

With `--dry-run` it prints one record per file, with `command` and `dry_run`, and runs nothing.

### `file-trash`

Move files to the Trash and report where they went.

```
file-trash FILE...
```

| Field | Meaning |
|---|---|
| `trashed_to` | Absolute path of the item in the Trash, which may have been renamed to avoid a clash |
| `dry_run` | `true` if nothing was changed |

### `file-clone`

Make a copy that shares storage with the original until one of them changes.

```
file-clone [--allow-copy] SOURCE DESTINATION
```

| Option | Meaning |
|---|---|
| `--allow-copy` | Where the volume cannot clone, make a full copy instead of failing |

| Field | Meaning |
|---|---|
| `destination` | Absolute path of the copy |
| `cloned` | `true` for a storage-sharing clone, `false` for a full copy made with `--allow-copy` |
| `dry_run` | `true` if nothing was changed |

`cp -c` falls back to a full copy without saying so. This tool fails with `unsupported_operation` unless you allow the fallback, and tells you which happened. The destination must not exist.

### `file-swap`

Exchange two files in one atomic step.

```
file-swap FIRST SECOND
```

| Field | Meaning |
|---|---|
| `other` | Absolute path of the second file |
| `dry_run` | `true` if nothing was changed |

Afterwards each path holds what the other held, and no other program can observe a moment when either is missing. Both files must be on the same volume.

## The `mft` command

Besides running any tool as `mft TOOL`, `mft` has commands about the suite itself.

### `mft guide`

Print a one-page orientation: the tools, the calling convention, the selectors, common tasks and the exit statuses. It is written to be read once by an agent, or by a person.

### `mft describe`

Print the whole interface as one JSON document: every tool with its record fields, examples and help text, the version fields, the selectors, the error codes with their exit statuses and hints, and the environment variables. Use it to generate tool definitions for an agent framework, or to check a program's assumptions.

For the options of every tool in machine-readable form, use `mft --experimental-dump-help`.

### `mft selftest`

Check that macOS versioning behaves on this Mac the way these tools assume. It works in a scratch folder and removes it afterwards.

```
mft selftest [--dir FOLDER]
```

| Option | Meaning |
|---|---|
| `--dir FOLDER` | Make the scratch folder here, to check another volume. Default: the system temporary folder |

It prints one record per check and exits 1 if any fails. Run it after a macOS update.

```console
$ mft selftest --text
pass	store	a version can be stored and listed
pass	idempotent	storing unchanged contents again adds nothing
pass	rename-over	versions survive a save that renames a new file over the old one
…
```

### `mft link`

Create a command for each tool in a folder, as links to the `mft` program.

```
mft link --dir FOLDER [--force]
```

| Option | Meaning |
|---|---|
| `--dir FOLDER` | Where to create the links. It must be on your PATH to be useful |
| `--force` | Replace existing files of the same names |

The installer runs this for you. Links that already point to the program are left alone.

### `mft hook`

Store a disposable version of the file an agent is about to edit. See [any other agent](#any-other-agent).

```
mft hook [--by WHO] [--reply TEXT]
```

| Option | Meaning |
|---|---|
| `--by WHO` | Who to record as storing the version. Default `agent` |
| `--reply TEXT` | Text to print on standard output, for agents that require a hook to answer |

## Recipes

**Checkpoint before a risky change, and roll back if it goes wrong.**

```sh
ver-add --tag before-migration config/*.yml
./migrate.sh || ver-restore --rev tag:before-migration config/*.yml
```

**Wrap any command that rewrites files.**

```sh
ver-guard package.json -- npm pkg set version=2.0.0
```

**See what a file looked like before today's work.**

```sh
ver-cat --rev before:8h report.md | less
```

**Find which files in a project have versions.**

```sh
git ls-files | ver-ls - | jq -r 'select(.count > 0) | "\(.count)\t\(.path)"'
```

**Read a version without copying it.**

```sh
path=$(ver-ls notes.txt | jq -r '.versions[0].contents_path')
grep -n TODO "$path"
```

**Act only if another program has not changed things meanwhile.**

```sh
latest=$(ver-ls notes.txt | jq -r '.versions[0].id')
# … decide what to do …
ver-restore --rev oldest --expect-latest "$latest" notes.txt
```

**Keep automatic checkpoints from piling up.**

```sh
git ls-files | ver-prune --keep-last 20 --older-than 14d --auto-only -
```

**Handle failures in a script.** Match on the code, not the message.

```sh
if ! out=$(ver-restore --rev tag:good app.conf 2>err.json); then
  case "$(jq -r .error.code err.json)" in
    no_such_version) echo "no checkpoint to return to" ;;
    busy)            sleep 2; ver-restore --rev tag:good app.conf ;;
    *)               jq -r .error.hint err.json ;;
  esac
fi
```

## Using it from an agent

There are two parts to wiring an agent up, and each plugin below does both:

1. **A skill** that teaches the agent when and how to use the tools. It is one file, [`SKILL.md`](plugins/shared/SKILL.md), in the Agent Skills format, and is the same for every agent.
2. **A pre-edit hook** that stores a disposable version of a file just before the agent edits it, so every edit can be undone with `ver-undo` whether or not the agent thought to checkpoint.

The installer puts all three plugins in `~/.local/share/mft/plugins`, so the paths below work after a normal install.

### Claude Code

```
/plugin marketplace add earchibald/macos-file-tools
/plugin install mft@macos-file-tools
```

The plugin puts the tools on the agent's command path, adds the skill, and adds the hook for the `Edit`, `Write`, `MultiEdit` and `NotebookEdit` tools. If the `mft` program is not installed, the tools say so and name the fix: run `mft-install`, which downloads the signed release.

Tested end to end: in a real session the hook stored a version before an edit, and `ver-undo`, run by the agent from the plugin's command path, put the original back.

### Antigravity

For the Antigravity CLI, `agy`:

```sh
agy plugin install ~/.local/share/mft/plugins/antigravity
```

Or straight from GitHub, which `agy plugin validate` accepts and `agy plugin install` should too: `agy plugin install https://github.com/earchibald/macos-file-tools/tree/main/plugins/antigravity`.

The plugin adds the skill, launchers for the tools, and a `PreToolUse` hook for `write_to_file`, `replace_file_content` and `multi_replace_file_content`. The hook answers `{"decision":"allow"}`, which Antigravity documents as handing the decision on to your normal permission settings: it never approves or blocks an edit itself.

The plugin passes `agy plugin validate --strict`, and the hook script is tested against Antigravity's documented event format. It has not been watched firing inside a live `agy` session. To check on your Mac, edit a file with `agy`, then run `ver-ls --text` on that file and look for a version noted "before write_to_file" or similar.

### Iris

For [Iris](https://github.com/sackheads/iris):

```sh
cp -R ~/.local/share/mft/plugins/iris/mft ~/.iris/plugins/mft
```

Or, in Iris, choose Settings → Plugins → + → From Folder… and pick that `mft` folder. Then restart Iris.

The plugin adds the skill and declares that it needs `mft`: Iris shows the plugin as needing configuration until `mft` is on your login shell's PATH.

Iris plugins cannot add hooks, so the pre-edit hook is a step for you. Merge the `hooks` entry from [`settings-hooks.json`](plugins/iris/mft/settings-hooks.json) into `~/.iris/config/settings.json`. It runs `mft hook` before each `write_file` call.

This plugin was written from the Iris plugin format specification in its repository and has not been loaded in Iris.

### Any other agent

Give the agent [`SKILL.md`](plugins/shared/SKILL.md) or the output of `mft guide`. Then, if the agent can run a command before it edits a file, have it run `mft hook` with the edit event as JSON on standard input.

`mft hook` looks for the file's path in whichever of these the event has:

| Event shape | Used by |
|---|---|
| `{"tool_name": …, "tool_input": {"file_path": …}, "cwd": …, "session_id": …}` | Claude Code |
| `{"toolCall": {"name": …, "args": {"TargetFile": …}}, "workspacePaths": […], "conversationId": …}` | Antigravity |
| `{"path": …}` | Iris |

A relative path is resolved against `cwd`, then the first workspace path, then the hook's own working directory.

It is built never to get in the way:

- It always exits 0.
- It prints nothing, unless you pass `--reply TEXT` for an agent that requires an answer.
- A file that does not exist yet, an event it cannot read, or a volume without versions are all silently ignored.
- It waits at most 5 seconds for a busy file.

## Settings and files

| Name | Purpose |
|---|---|
| `MFT_ACTOR` | Default for `--by`: who is storing versions, such as an agent or session name |
| `MFT_HOME` | Folder for notes and tags. Default `~/Library/Application Support/mft` |
| `MFT_PREFIX` | Installer only: where to install. Default `~/.local` |
| `MFT_VERSION` | Installer only: which release to download. Default: the latest |
| `MFT_BIN` | Plugin launchers only: the full path of the `mft` program, if it is somewhere unusual |

| Path | Contents |
|---|---|
| `~/.local/bin/mft` | The program. The other commands beside it are links to it |
| `~/.local/share/mft/plugins/` | The Claude Code, Antigravity and Iris plugins |
| `~/.local/share/mft/completions/` | Shell completions for `mft` (zsh, bash, fish) |
| `~/.local/share/mft/guide.txt`, `interface.json` | The output of `mft guide` and `mft describe` |
| `~/Library/Application Support/mft/meta/` | One small JSON file per version: its note, tag and author |

## Troubleshooting

**`versions_unsupported` when storing a version.** The file is on a volume that cannot hold versions, such as an ExFAT USB stick. Run `ver-status --probe FILE` to confirm. Work on a copy on an APFS volume, and use `ver-cp` if history has to travel.

**`permission_denied`.** macOS decides file access by the app that started the command: your terminal, or the agent's app. Grant that app access under System Settings → Privacy & Security → Files and Folders (or Full Disk Access).

**`busy`.** An app held the file for longer than `--timeout`. Retry, or raise `--timeout`.

**A file's versions have gone.** The file was probably deleted and recreated, copied, or moved to another volume. See [what loses them](#how-macos-versions-behave).

**`ver-undo` says there is nothing to undo.** Every stored version matches the current contents. Nothing was stored before the change you want to take back.

**The plugin tools report `not_installed`.** The plugin carries launchers only. Run `mft-install`, or the install command above.

**Notes and tags are missing on another Mac or account.** They are kept per user, per Mac, as are the versions themselves.

**After a macOS update something behaves differently.** Run `mft selftest --text`. Each line is one assumption these tools make; a `FAIL` line tells you which one no longer holds.

## Limits

- Not tested on network volumes or in iCloud Drive. For iCloud files, versions stored on one Mac stay on that Mac.
- Versions of folders and document packages work in simple cases but are not covered by the tests.
- Whether versions stored here appear in an app's "Browse All Versions" window, and the reverse, has not been confirmed first-hand. Both use the same system store.
- There is no listing of every versioned file on a volume: the system store can only be asked about one file at a time.
- A version's id comes from the name the system store gives its file. That has been stable in testing but is not a documented guarantee.

The research behind these tools, including how each claim above was tested, is in [docs/design.md](docs/design.md).

## Building, testing and releasing

```sh
swift build                    # debug build at .build/debug/mft
swift test                     # drives the built program; includes the interface contract tests
scripts/sync-plugins.sh        # after editing plugins/shared/ or install.sh
scripts/package.sh             # universal build, ad hoc signed, packed into dist/
```

The tests hold the interface, not the implementation. They fail if a tool's record differs from what `mft describe` documents, if a tool that changes something lacks `--dry-run`, if a dry run changes anything, if the plugins drift from their shared source, or if this README stops mentioning a tool or one of its options.

CI builds and tests on macOS 15 and macOS 26, runs `mft selftest` on each runner, and installs from the packaged zip.

To release:

1. Set the version in `Sources/MFTCore/Conventions.swift`, the three plugin manifests and `plugins/shared/bin/mft-install`; run `scripts/sync-plugins.sh`; add a section to `CHANGELOG.md`. A test checks they agree.
2. Tag and push: `git tag v0.0.1 && git push origin v0.0.1`. The Release workflow builds and tests at the tag.
3. Publish the signed build from a Mac that holds the certificate: `scripts/release.sh --notarize PROFILE`, where PROFILE is a `notarytool` keychain profile. It signs with the Developer ID, has Apple notarize the zip, and creates the GitHub release.

If the repository has signing secrets, the workflow does step 3 itself. They are listed at the top of [`.github/workflows/release.yml`](.github/workflows/release.yml).
