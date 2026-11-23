# Changelog

## 0.0.1

First release.

**Tools**

- `ver-ls`, `ver-add`, `ver-cat`, `ver-diff`, `ver-restore`, `ver-undo`, `ver-rm`, `ver-prune`, `ver-status`, `ver-cp` and `ver-guard` for macOS document versions.
- `file-trash`, `file-clone` and `file-swap` for single-file operations.
- `mft guide`, `mft describe`, `mft selftest`, `mft link` and `mft hook`.

**Interface**

- One JSON record per file on standard output; failures as records on standard error with a stable code, a message and a hint.
- `--text`, `--quiet` and `--help` on every tool; `--dry-run` and `--timeout` on every tool that changes something.
- Version selectors: id or prefix, `latest`, `oldest`, `@N`, `tag:NAME`, `before:WHEN`.
- File lists on standard input with `-`.

**Behaviour**

- `ver-add` does not store unchanged contents twice.
- `ver-restore` and `ver-undo` store the contents they replace, and confirm the restored bytes match.
- Notes, tags and authors on versions; `--auto` versions are disposable.
- Every change is coordinated with other programs and gives up with `busy` instead of hanging.

**Packaging**

- Universal binary (Apple silicon and Intel), signed with a Developer ID and notarized.
- Claude Code plugin with a skill, a pre-edit checkpoint hook and launchers for every tool.

**Known gaps**

- Not tested on network volumes or iCloud Drive.
- Versions of folders and document packages work in simple cases but are not covered by tests.
- Whether versions stored here appear in an app's "Browse All Versions", and the reverse, has not been confirmed first-hand.
