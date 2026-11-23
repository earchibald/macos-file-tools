# Small macOS file tools with one interface

A design study for a suite of small, single-purpose command-line tools that wrap macOS file operations behind one consistent set of arguments, options and output. Versioning comes first. The intended callers are mostly programs and AI agents, with people second.

Everything marked **tested** below was run on macOS 27.3 (APFS, Apple silicon, Swift 6.4) on 2026-11-23. Everything marked **source** comes from a page listed under [Sources](#sources). The [`examples/`](examples/) folder holds a working six-tool sketch that the snippets are taken from; `examples/smoke.sh` builds it and exercises every tool.

## Summary

- macOS already keeps per-file versions in a system-wide store, the one behind "Browse All Versions" in TextEdit, Preview and Pages. The public API for it is `NSFileVersion`, and it works from a plain unsandboxed command-line tool with no entitlements. **tested**
- That makes a thin CLI a way for agents to read, add, restore and delete versions in the same store that document apps use, without inventing a second versioning scheme.
- Adding a version is nearly free on APFS: a 300 MB file took 0.01 s and no extra disk space. **tested**
- Versions follow a file through rename, move, in-place edits and rename-over saves. They do not follow copies, and deleting the file drops them. **tested**
- Restoring a version overwrites the file and keeps nothing, so a restore tool should store the current contents as a version first, by default. **tested**
- Positional version numbers shift whenever a version is added or removed. Tools should hand out stable ids and accept positions only as a convenience.
- For agent callers the interface should be JSON lines by default, one record per file operand, with failures as structured records carrying a stable code, and no prompts, colours or terminal-dependent behaviour.
- One multi-call binary plus one symlink per tool gives small dedicated tools with a single shared implementation. It works when signed with the hardened runtime and placed in an app bundle. **tested** with an ad-hoc signature.
- The tools must not be sandboxed if they are to be run from a terminal, which means Developer ID distribution with notarization, not the Mac App Store. **source**

## Which "versioning" to wrap

macOS has three unrelated mechanisms that people call versioning.

| Mechanism | Scope | Who creates entries | Reachable from a CLI | Fit for this suite |
|---|---|---|---|---|
| Document versions (`NSFileVersion`) | One file | Document apps on save, or any program through the API | Yes, no privileges | The core: `ver-*` tools |
| APFS snapshots (`tmutil`, `diskutil apfs`) | Whole volume | Time Machine, OS updates, `tmutil localsnapshot` | Listing works unprivileged; mounting and deleting need more | Read-only `snap-*` tools later |
| Clones (`clonefile`, `cp -c`) | One file | Whoever copies | Yes | A building block, e.g. `file-clone` |

Document versions are the only one that is per-file, shared with apps, and fully usable without root, so the rest of this document concentrates on them.

## How document versions behave

Each version is a read-only file inside `/System/Volumes/Data/.DocumentRevisions-V100/`, managed by a system daemon. The folder cannot be listed without root, but a version's file can be read directly by anyone who is handed its path, and `NSFileVersion` hands it out as `url`.

### Tested here

| Action on a file that has versions | Result |
|---|---|
| Overwrite in place (`printf … > file`) | Versions kept |
| Rename or move within the volume (`mv a b`, `mv a dir/`) | Versions kept |
| Rename-over save (`mv tmp file`, `sed -i`) | Versions kept |
| Foundation atomic write | Versions kept |
| `cp`, `cp -p`, `cp -c` | The copy has no versions |
| `rm`, then create a new file with the same name | Versions gone |
| Restore an old version | File overwritten; the previous contents are lost unless stored first; the restored version stays in the list |
| Add a version from another file | Works; with `.byMoving` the source file is consumed |
| Add a version of a 300 MB file | 0.01 s, free space unchanged |
| List versions of a path that does not exist | Returns an empty list, not an error |
| Add a version on a scratch ExFAT disk image | Fails with Cocoa error 512 and no detail |
| Add a version on a scratch HFS+ disk image | Also failed with error 512 (see open questions) |
| Add a version of a plain folder | Succeeded (not explored further) |

A version's date is the modification date of the contents it holds, not the time it was stored: a file last modified in 2020 and added today yields a version dated 2020.

### From sources, not tested here

- Apple says to add, replace and remove versions inside a coordinated write (`NSFileCoordinator`), so apps that have the file open are notified. The example code does this.
- Moving a file to another volume loses its versions, and moving it back does not recover them.
- Versions are not included in Time Machine backups. A file restored from backup has none.
- For iCloud Drive files, each Mac sees only the versions made on that Mac; other versions are conflict copies fetched separately.
- macOS has no built-in way to prune the version store as a whole.
- `addOfItem`, the call that stores a version, is macOS-only. Reading, replacing and removing exist on other Apple platforms too.

## The interface contract

The point of the suite is that learning one tool teaches all of them. These rules are what "consistent" means here; the example code enforces each of them in one shared place.

**Names.** `<domain>-<verb>`, lower case, hyphenated. Domains: `ver` (document versions), `file` (single-file operations), `snap` (snapshots). Verbs come from one short list and mean the same thing in every domain: `ls`, `add`, `cat`, `restore`, `rm`.

**Argument order.** `tool [options] FILE...`. Options first, file operands last, `--` ends options. A tool takes many files when the operation makes sense per file, and exactly one when it does not (`ver-cat`, `ver-restore`).

**Shared options.** Spelled once, identical everywhere:

| Option | Tools | Meaning |
|---|---|---|
| `--text` | all | Tab-separated text for people instead of JSON lines |
| `-q`, `--quiet` | all | Print nothing on success |
| `-n`, `--dry-run` | every tool that changes something | Report what would change; change nothing |
| `-r`, `--rev <selector>` | every tool that acts on one version | Which version |
| `-h`, `--help`, `--version` | all | Provided by the argument parser |

**Version selectors.** One grammar for `--rev`: a version id or any unique prefix of it, `latest`, `oldest`, or `@N` where `@1` is the newest. Ids are stable for the life of the version. `@N` positions shift as versions come and go, so they suit a person at a prompt and should be avoided by programs.

**Output.** One record per file operand. Successes go to standard output and failures to standard error, both as one JSON object per line. Every record carries `ok`, `tool` and the absolute `path`. The single exception is `ver-cat`, whose standard output is the version's bytes.

**Failures.** A failure record has `error.code`, a stable string to match on, and `error.message` for people. The exit status says the same thing more coarsely:

| Exit | `error.code` | Meaning |
|---|---|---|
| 0 | | Every operand succeeded |
| 1 | | Operands failed for different reasons; read the records |
| 64 | | Bad usage (the argument parser's own status) |
| 65 | `no_versions`, `no_such_version`, `ambiguous_version` | The selector matched nothing usable |
| 66 | `no_such_file` | The operand does not exist |
| 69 | `versions_unsupported` | The volume cannot store versions |
| 74 | `io_error` | Any other file-system failure |

The numbers follow `sysexits.h`. A tool keeps going after one operand fails, so a batch always produces a record for every file.

**Safe defaults.** Nothing prompts. Nothing destructive happens without being asked for by name: `ver-rm` requires `--rev` or `--all`, and `ver-restore` stores the current contents first unless told `--no-keep-current`.

## Designing for agent callers

An agent reads output literally, cannot answer a prompt, often sees standard output and standard error merged, and may be one of several programs touching the same file. That leads to these rules, all of which the example follows unless marked proposed.

1. **JSON by default, text by request.** The reverse of the usual convention, because the usual convention assumes a person. Output never depends on whether a terminal is attached.
2. **One operand in, one record out.** A file with no versions yields `"versions":[]`, not silence, so "nothing there" and "something went wrong" cannot be confused.
3. **Stable ids, absolute paths.** Records can be passed between tools and between agents without reinterpretation.
4. **Failures are data.** A stable `error.code` means an agent never has to parse prose to decide what to do next.
5. **Hand out the contents path.** Every version record includes `contents_path`, the read-only file holding that version. An agent can read or diff it with whatever file tools it already has, without another call.
6. **Dry runs everywhere.** `--dry-run` returns the same record shape with `"dry_run":true`, so an agent can show a plan before acting.
7. **Self-description.** `--help` is short and uniform. `mft --experimental-dump-help` emits the whole command tree as JSON (**tested**), which is enough to generate tool definitions for an agent framework or a Model Context Protocol server without writing them by hand.
8. **Flush per record.** So that merged output streams stay in order.
9. **Proposed: bounded output.** A `--limit N` on `ver-ls`, since a file edited in an autosaving app can accumulate hundreds of versions.
10. **Proposed: preconditions.** An `--expect-latest <id>` on `ver-restore` and `ver-rm` that fails if another program added a version in the meantime.

## Implementation

Swift with [swift-argument-parser](https://github.com/apple/swift-argument-parser), because `NSFileVersion` is a Foundation API and the parser's option groups are exactly the mechanism for sharing options. The package has two targets: `MFTCore`, a library with everything shared, and `mft`, one executable containing every tool.

### Shared options are declared once

```swift
public struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Print tab-separated text for people instead of JSON lines.")
    public var text = false

    @Flag(name: .shortAndLong, help: "Print nothing on success.")
    public var quiet = false

    public init() {}
}

public struct MutationOptions: ParsableArguments {
    @Flag(name: [.customShort("n"), .long], help: "Report what would change, and change nothing.")
    public var dryRun = false

    public init() {}
}
```

### A tool is options, operands and one loop

```swift
struct VerAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ver-add", abstract: "Store the current contents of files as a new version.")

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option(help: "Store this file's contents instead (one FILE only).") var from: String?
    @Argument(help: "Files to add a version to.") var files: [String]

    // validate(), which rejects --from with more than one FILE, is omitted here.

    func run() throws {
        let emit = Emitter(tool: "ver-add", options: output)
        try emit.forEach(files) { url in
            if mutation.dryRun {
                emit.result(["path": url.path, "dry_run": true], text: "would add\t\(url.path)")
                return
            }
            let version = try Versions.add(to: url, from: from.map { URL(fileURLWithPath: $0) })
            emit.result(
                ["path": url.path, "added": version.fields, "dry_run": false],
                text: "added\t\(version.id)\t\(url.path)")
        }
    }
}
```

`Emitter.forEach` is where the per-operand rules live: it resolves the path, checks the file exists, runs the body, turns any error into a failure record, carries on, and picks the exit status at the end. No tool repeats that logic. See [`Conventions.swift`](examples/mft/Sources/MFTCore/Conventions.swift).

### One file talks to the version store

```swift
public static func list(_ url: URL) -> [Version] {
    let stored = NSFileVersion.otherVersionsOfItem(at: url) ?? []
    // … sort newest first, number from 1, derive the id from the store's file name
}

@discardableResult
public static func add(to url: URL, from source: URL? = nil) throws -> Version {
    do {
        var added: NSFileVersion!
        try coordinated(url) {
            added = try NSFileVersion.addOfItem(at: $0, withContentsOf: source ?? $0, options: [])
        }
        return list(url).first { $0.raw.url == added.url }!
    } catch {
        throw ToolError(.versionsUnsupported, "cannot store a version here: \(error.localizedDescription)")
    }
}

public static func restore(_ version: Version, to url: URL) throws {
    try coordinated(url) { _ = try version.raw.replaceItem(at: $0, options: []) }
}

/// Runs `body` inside a coordinated write, so apps that have the file open
/// are told it changed instead of discovering it later.
static func coordinated(_ url: URL, _ body: (URL) throws -> Void) throws {
    var coordinationError: NSError?
    var bodyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
        writingItemAt: url, options: [], error: &coordinationError
    ) { actualURL in
        do { try body(actualURL) } catch { bodyError = error }
    }
    if let error = coordinationError ?? bodyError { throw error }
}
```

The version id is the UUID that the store uses as the version's file name. That is observed behaviour, not a documented guarantee. The documented stable handle is `persistentIdentifier`; on this system it contains the same UUID. Full file: [`Versions.swift`](examples/mft/Sources/MFTCore/Versions.swift).

### One binary, many tool names

```swift
@main
enum Entry {
    static func main() {
        var arguments = CommandLine.arguments
        let invokedAs = URL(fileURLWithPath: arguments.removeFirst()).lastPathComponent
        if invokedAs != "mft" { arguments.insert(invokedAs, at: 0) }
        Mft.main(arguments)
    }
}
```

`mft ver-ls FILE` and a symlink named `ver-ls` that points at `mft` run the same code. Each tool is small and dedicated from the caller's side, and there is one binary to build, sign and update.

## Example session

Real output from `examples/smoke.sh`, with the scratch folder shown as `/tmp/demo` and long records wrapped for reading.

```console
$ ver-add notes.txt
{"added":{"contents_path":"/System/Volumes/Data/.DocumentRevisions-V100/PerUID/501/4315/com.apple.documentVersions/84DC26AE-F144-4204-8177-4C0ABC085EFC.txt",
          "date":"2026-11-23T22:43:46Z","discardable":false,"id":"84dc26ae-f144-4204-8177-4c0abc085efc","index":1,"size":12},
 "dry_run":false,"ok":true,"path":"/tmp/demo/notes.txt","tool":"ver-add"}

$ ver-ls --text notes.txt
@1	d3b0c81b-fe22-46ce-9183-48e9ca0e139d	2026-11-23T22:43:48Z	/tmp/demo/notes.txt
@2	84dc26ae-f144-4204-8177-4c0abc085efc	2026-11-23T22:43:46Z	/tmp/demo/notes.txt

$ ver-cat --rev oldest notes.txt
first draft

$ ver-restore --dry-run --rev oldest notes.txt
{"dry_run":true,"ok":true,"path":"/tmp/demo/notes.txt","restored":"84dc26ae-f144-4204-8177-4c0abc085efc","tool":"ver-restore"}

$ ver-restore --rev oldest notes.txt
{"dry_run":false,"kept_current_as":"a5b545e7-73e5-4b80-89f5-7cbbb89139c6","ok":true,"path":"/tmp/demo/notes.txt",
 "restored":"84dc26ae-f144-4204-8177-4c0abc085efc","tool":"ver-restore"}

$ ver-rm --rev @1 notes.txt
{"dry_run":false,"ok":true,"path":"/tmp/demo/notes.txt","removed":["a5b545e7-73e5-4b80-89f5-7cbbb89139c6"],"tool":"ver-rm"}
```

Failures:

```console
$ ver-ls missing.txt
{"error":{"code":"no_such_file","message":"no such file or directory"},"ok":false,"path":"/tmp/demo/missing.txt","tool":"ver-ls"}
[exit 66]

$ ver-ls --text missing.txt
ver-ls: /tmp/demo/missing.txt: no such file or directory
[exit 66]

$ ver-cat --rev @9 notes.txt
{"error":{"code":"no_such_version","message":"no version @9; have @1 to @2"},"ok":false,"path":"/tmp/demo/notes.txt","tool":"ver-cat"}
[exit 65]

$ ver-rm notes.txt
Error: Give exactly one of --rev or --all.
Usage: mft ver-rm [--text] [--quiet] [--dry-run] [--rev <selector>] [--all] <files> ...
[exit 64]
```

Usage errors are the one place output is not JSON: they come from the argument parser before any tool code runs.

## The rest of the suite

The same contract extends to other single-file operations. `file-trash` is implemented in the example; the others are proposals, each built on a primitive that was tested here.

| Tool | Status | Built on | Notes from testing |
|---|---|---|---|
| `ver-ls`, `ver-add`, `ver-cat`, `ver-restore`, `ver-rm` | Implemented | `NSFileVersion` | See above |
| `file-trash` | Implemented | `FileManager.trashItem` | Returns where the item landed, which may be a renamed path |
| `file-clone` | Proposed | `clonefile(2)` | Fails with "File exists" if the destination exists. `cp -c` instead falls back to a full copy without saying so on ExFAT and HFS+ images, so the tool should report which happened |
| `file-swap` | Proposed | `renamex_np` with `RENAME_SWAP` | Exchanges two files atomically |
| `file-replace` | Proposed | `FileManager.replaceItemAt` | Replaces a file and can leave the old one as a named backup; the replacement file is consumed |
| `snap-ls` | Proposed | `tmutil listlocalsnapshots` | Listing worked without root here |

Why wrap the built-in `/usr/bin/trash` (macOS 15 and later) at all: it prints its failures as an unstructured log line, exits 5 for a missing file, prints nothing on success, and reports the destination only in verbose mode as prose. **tested**

The primitives, as tested:

```swift
// Exchange two files atomically.
renamex_np(a.path, b.path, UInt32(RENAME_SWAP))            // 0 on success

// Rename without overwriting: fails with EEXIST if b exists.
renamex_np(a.path, b.path, UInt32(RENAME_EXCL))

// Copy-on-write clone: fails with EEXIST if the destination exists.
clonefile(source.path, destination.path, 0)

// Replace `original` with `new`, keeping the old contents as a named backup.
try FileManager.default.replaceItemAt(
    original, withItemAt: new, backupItemName: "original.bak", options: [.withoutDeletingBackupItem])

// Move to the Trash and learn where it went.
var landed: NSURL?
try FileManager.default.trashItem(at: url, resultingItemURL: &landed)

// Ask the volume what it supports before relying on it.
let caps = try url.resourceValues(forKeys: [
    .volumeSupportsFileCloningKey, .volumeSupportsSwapRenamingKey, .volumeSupportsExclusiveRenamingKey])
```

There is no equivalent capability key for document versions; the only test is to try `addOfItem` and handle the failure.

## Packaging as a signed app with a CLI

The multi-call layout was chosen with this in mind: the app bundle carries one helper binary, and installing the command-line tools means creating symlinks.

```
FileTools.app/
  Contents/
    MacOS/FileTools          the app
    Helpers/mft              the multi-call binary
/usr/local/bin/ver-ls   ->   /Applications/FileTools.app/Contents/Helpers/mft
/usr/local/bin/ver-add  ->   /Applications/FileTools.app/Contents/Helpers/mft
…
```

What the sources say, and what follows from it:

- **Location.** Apple lists `Contents/MacOS/` and `Contents/Helpers/` as the places for helper tools. BBEdit ships its tool in `Contents/Helpers` with a symlink in `/usr/local/bin`.
- **Do not sandbox the tools.** A sandboxed tool run from a terminal is likely to be blocked from opening paths passed as arguments, and a tool that inherits the app's sandbox cannot be run from a terminal at all. Tools meant for terminals and agents have to be unsandboxed, which rules out the Mac App Store and points to Developer ID distribution.
- **Signing.** Sign the tool with the hardened runtime, a secure timestamp and an explicit identifier, then sign the app; sign from the inside out and do not use `--deep`.
- **Notarization.** The notary service accepts zip archives, disk images and installer packages. A ticket can be stapled to an app, disk image or package, but not to a bare executable, so ship the tool inside the app rather than alone.
- **Privacy permissions.** When a tool runs from a terminal, macOS attributes its file access to the terminal app, not the tool, so access to Documents, Desktop or the whole disk depends on what the terminal has been granted. The tool's own signature matters when the app itself launches the tool; then a stable signing identity is what keeps a grant from being asked for again after each update.
- **Symlinks.** A symlink on the search path to a tool inside an app bundle works. Inside the tool, `Bundle.main` will not be the app's bundle.

Tested here with an ad-hoc signature only: the binary signed with `--options runtime` and an identifier, placed in `Demo.app/Contents/Helpers/`, ran correctly through symlinks named `ver-ls` and `ver-add`, and still passed `codesign --verify --strict` afterwards.

The commands for a real build, not run here:

```sh
codesign --force --timestamp --options runtime \
  --identifier com.example.filetools.mft \
  --sign "Developer ID Application: NAME (TEAMID)" \
  FileTools.app/Contents/Helpers/mft
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: NAME (TEAMID)" FileTools.app

ditto -c -k --keepParent FileTools.app FileTools.zip
xcrun notarytool submit FileTools.zip --keychain-profile PROFILE --wait
xcrun stapler staple FileTools.app
```

## Open questions

- **Versions made by apps.** Document apps and this API use the same store, so versions saved by TextEdit should appear in `ver-ls`, and versions added by `ver-add` should appear in an app's "Browse All Versions". Not confirmed first-hand: the test needed permission to script TextEdit and was abandoned. To check by hand: edit and save a file a few times in TextEdit, then run `ver-ls --text` on it.
- **Effect of coordinated writes.** The example coordinates every change as Apple advises. Whether an app with the file open then reloads after `ver-restore` was not observed, for the same reason.
- **HFS+.** A published source says versions work on HFS+ and APFS. Adding a version failed on a freshly made HFS+ disk image here. The image may be the cause; a real HFS+ volume was not tried.
- **Network and iCloud Drive locations.** Not tested.
- **Folders and document packages.** Adding a version of a plain folder succeeded once. Listing, restoring and the on-disk cost were not examined.
- **Multi-call binaries and notarization.** No source reports a problem with one signed binary reached through several symlink names, and none endorses it. Only the ad-hoc case was tested.
- **The id.** It rests on the store's file naming. A stricter implementation would derive it from `persistentIdentifier`.
- **Snapshots.** Only listing was tried. Creating, mounting and deleting were left alone.

## Running the example

```sh
examples/smoke.sh                                   # build, then drive every tool in a scratch folder

swift build -c release --package-path examples/mft  # or build and use it directly
examples/mft/.build/release/mft ver-ls --text SOMEFILE
```

Requires Xcode's Swift toolchain. The example is a sketch for the document, not a release.

## Sources

Apple documentation

- [NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion), including `addOfItem(at:withContentsOf:options:)`, `replaceItem(at:options:)`, `remove()` and `persistentIdentifier`
- [FileManager.replaceItemAt](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:)) and [trashItem](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:))
- [Placing content in a bundle](https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle)
- [Embedding a helper tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Creating distribution-signed code for the Mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) and [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
- [TN3127: Inside code signing: requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

Apple Developer Forums

- [A sandboxed tool is either spawnable by the app or runnable from Terminal, not both](https://developer.apple.com/forums/thread/770419)
- [Which program is held responsible for a tool's file access](https://developer.apple.com/forums/thread/756510)
- [A tool in an app bundle with a symlink in /usr/local/bin](https://developer.apple.com/forums/thread/782554)
- [Document identifiers survive a safe save](https://developer.apple.com/forums/thread/831339)

Manual pages

- [trash(8)](https://keith.github.io/xcode-man-pages/trash.8.html), [tmutil(8)](https://keith.github.io/xcode-man-pages/tmutil.8.html), [clonefile(2)](https://keith.github.io/xcode-man-pages/clonefile.2.html), [rename(2)](https://keith.github.io/xcode-man-pages/rename.2.html), [cp(1)](https://keith.github.io/xcode-man-pages/cp.1.html)

Howard Oakley, The Eclectic Light Company

- [Explainer: the macOS versioning system](https://eclecticlight.co/2021/09/04/explainer-the-macos-versioning-system/)
- [Document versioning: unused power in macOS](https://eclecticlight.co/2025/04/29/document-versioning-unused-power-in-macos/)
- [How to keep or lose a document's previous versions](https://eclecticlight.co/2020/02/14/how-to-keep-or-lose-a-documents-previous-versions/)
- [How to preserve a document's versions no matter what](https://eclecticlight.co/2025/09/12/how-to-preserve-a-documents-versions-no-matter-what/)

Prior art

- [jcfieldsdev/versions](https://github.com/jcfieldsdev/versions): the one existing `NSFileVersion` command-line tool found. Its version ids are positions that renumber after a delete.
- [sindresorhus/macos-trash](https://github.com/sindresorhus/macos-trash) and [ali-rantakari/trash](https://github.com/ali-rantakari/trash)
- [BBEdit's command-line tool as a symlink into the app bundle](https://groups.google.com/g/bbedit/c/ZeW57B6AIKs)

Interface conventions

- [Command Line Interface Guidelines](https://clig.dev/)
- [POSIX Utility Syntax Guidelines](https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap12.html)
- [sysexits(3)](https://man.freebsd.org/cgi/man.cgi?query=sysexits&sektion=3)
- [JSON Lines](https://jsonlines.org/)
- [swift-argument-parser](https://github.com/apple/swift-argument-parser)
