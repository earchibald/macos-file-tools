import ArgumentParser
import Foundation

/// What a tool is for, what it prints and how to call it. Help text, the
/// `mft describe` document and `mft guide` are all generated from these
/// entries, and the test suite checks real output against them.
public struct ToolDoc {
    public let name: String
    public let summary: String
    public let changes: Bool                      // does it modify anything?
    public let fields: [(name: String, meaning: String)]
    public let examples: [String]
    public let notes: String

    public var configuration: CommandConfiguration {
        var discussion = notes.isEmpty ? "" : notes + "\n\n"
        discussion += "EXAMPLES:\n" + examples.map { "  " + $0 }.joined(separator: "\n")
        return CommandConfiguration(commandName: name, abstract: summary, discussion: discussion)
    }
}

public enum Catalog {
    public static func doc(_ name: String) -> ToolDoc {
        tools.first { $0.name == name }!
    }

    /// Fields present in every record, whichever tool printed it.
    public static let commonFields: [(name: String, meaning: String)] = [
        ("ok", "true on standard output, false on standard error"),
        ("tool", "name of the tool that printed the record"),
        ("path", "absolute path of the file operand"),
        ("error", "failures only: an object with code, message and hint"),
    ]

    /// Fields of a version object, wherever one appears.
    public static let versionFields: [(name: String, meaning: String)] = [
        ("id", "stable identifier; pass it to --rev"),
        ("index", "position, 1 is the newest; changes as versions come and go"),
        ("date", "modification date of the contents this version holds, ISO 8601"),
        ("size", "bytes"),
        ("discardable", "true if macOS may delete it to free space"),
        ("contents_path", "read-only file holding the version's contents; read it directly"),
        ("note", "why it was stored, or null"),
        ("tag", "name shared by versions stored together, or null"),
        ("by", "who stored it, or null"),
    ]

    public static let selectors: [(form: String, meaning: String)] = [
        ("<id>", "a version id, or any prefix of one that matches a single version"),
        ("latest", "the newest stored version"),
        ("oldest", "the oldest stored version"),
        ("@N", "the Nth newest, @1 is latest; convenient by hand, unstable for programs"),
        ("tag:NAME", "the newest version carrying that tag"),
        ("before:WHEN", "the newest version whose contents date from WHEN or earlier; "
            + "WHEN is a duration back from now (15m, 2h, 3d) or an ISO 8601 date-time"),
    ]

    public static let environment: [(name: String, meaning: String)] = [
        ("MFT_ACTOR", "default for --by: who is storing versions (an agent or session name)"),
        ("MFT_HOME", "folder for notes and tags; default ~/Library/Application Support/mft"),
    ]

    public static let tools: [ToolDoc] = [
        ToolDoc(
            name: "ver-ls", summary: "List the stored versions of files.", changes: false,
            fields: [
                ("versions", "array of version objects, newest first"),
                ("count", "how many versions are stored, before --limit"),
            ],
            examples: ["ver-ls notes.txt", "ver-ls --limit 5 --text notes.txt", "git ls-files | ver-ls -"],
            notes: "A file with no versions gives an empty list, not an error."),
        ToolDoc(
            name: "ver-add", summary: "Store the current contents of files as a new version.", changes: true,
            fields: [
                ("version", "the version that now holds the current contents; null on a dry run that would create one"),
                ("created", "false when the newest version already held exactly these contents"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: [
                "ver-add notes.txt",
                "ver-add --note 'before refactor' --tag pre-refactor src/a.swift src/b.swift",
                "ver-add --auto notes.txt",
            ],
            notes: "Safe to call as often as you like: unchanged contents are not stored twice. "
                + "--auto marks the version disposable, so macOS may reclaim it when space runs low."),
        ToolDoc(
            name: "ver-cat", summary: "Write one stored version's bytes to standard output.", changes: false,
            fields: [],
            examples: ["ver-cat --rev latest notes.txt", "ver-cat -r before:2h notes.txt > notes.2h-ago.txt"],
            notes: "Standard output is the version's bytes, not a record. "
                + "To avoid a copy, read contents_path from ver-ls instead."),
        ToolDoc(
            name: "ver-diff", summary: "Compare a stored version with the current file or another version.",
            changes: false,
            fields: [
                ("from", "id of the older side"),
                ("to", "id of the newer side, or \"current\""),
                ("changed", "true if the two sides differ"),
                ("binary", "true if the contents are not text; diff is then empty"),
                ("diff", "unified diff, empty when unchanged"),
            ],
            examples: ["ver-diff notes.txt", "ver-diff --rev oldest --to latest --text notes.txt"],
            notes: "Without --rev, compares the latest version with the current file."),
        ToolDoc(
            name: "ver-restore", summary: "Replace a file's contents with a stored version.", changes: true,
            fields: [
                ("restored", "id of the version now in the file"),
                ("kept_current_as", "id of the version holding the contents that were replaced; null with --no-keep-current"),
                ("verified", "true if the file's bytes match the version after restoring"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: [
                "ver-restore --rev latest notes.txt",
                "ver-restore --rev tag:pre-refactor src/a.swift src/b.swift",
                "ver-restore --rev before:30m --dry-run notes.txt",
            ],
            notes: "The contents being replaced are stored as a version first, so a restore can itself be undone."),
        ToolDoc(
            name: "ver-undo", summary: "Go back to the most recent stored contents that differ from the file.",
            changes: true,
            fields: [
                ("restored", "id of the version now in the file"),
                ("kept_current_as", "id of the version holding the contents that were replaced"),
                ("verified", "true if the file's bytes match the version after restoring"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: ["ver-undo notes.txt", "ver-undo notes.txt && ver-undo notes.txt   # undo, then redo"],
            notes: "Running it twice returns the file to where it started."),
        ToolDoc(
            name: "ver-rm", summary: "Delete stored versions. The file itself is not touched.", changes: true,
            fields: [
                ("removed", "ids of the versions deleted"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: ["ver-rm --rev 3f2a notes.txt", "ver-rm --all --dry-run notes.txt"],
            notes: "Exactly one of --rev or --all is required."),
        ToolDoc(
            name: "ver-prune", summary: "Delete old versions by rule. The file itself is not touched.",
            changes: true,
            fields: [
                ("removed", "ids of the versions deleted"),
                ("kept", "how many versions remain"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: [
                "ver-prune --keep-last 20 notes.txt",
                "ver-prune --older-than 30d --auto-only notes.txt",
                "git ls-files | ver-prune --keep-last 10 --dry-run -",
            ],
            notes: "Tagged versions are kept unless --include-tagged is given. "
                + "With both rules, a version goes only if it is beyond --keep-last and older than --older-than."),
        ToolDoc(
            name: "ver-status", summary: "Report whether and how a file is versioned.", changes: false,
            fields: [
                ("kind", "file, folder or package"),
                ("count", "how many versions are stored"),
                ("latest", "the newest version object, or null"),
                ("changed_since_latest", "true if the file differs from its newest version; null with no versions"),
                ("versions_supported", "true, false, or null when unknown without --probe"),
                ("volume_format", "file system of the volume, as macOS names it"),
                ("volume_local", "false for network volumes"),
                ("in_icloud", "true if the file is in iCloud Drive"),
                ("warnings", "array of sentences about anything likely to surprise"),
            ],
            examples: ["ver-status notes.txt", "ver-status --probe /Volumes/USB/notes.txt"],
            notes: "--probe stores a version and deletes it again to find out for certain."),
        ToolDoc(
            name: "ver-cp", summary: "Copy a file together with its stored versions.", changes: true,
            fields: [
                ("destination", "absolute path of the copy"),
                ("versions_copied", "how many versions the copy now has"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: ["ver-cp notes.txt notes-copy.txt", "ver-cp notes.txt /Volumes/Other/notes.txt"],
            notes: "A plain copy has no versions; this one replays them onto the copy. "
                + "The copies get new ids. The destination must not exist."),
        ToolDoc(
            name: "ver-guard", summary: "Store versions of files, then run a command.", changes: true,
            fields: [
                ("command", "the command that would run"),
                ("dry_run", "always true: a record is printed only on a dry run"),
            ],
            examples: [
                "ver-guard config.yml -- sed -i '' 's/old/new/' config.yml",
                "ver-guard --tag pre-format src/*.swift -- swift-format -i src/*.swift",
            ],
            notes: "Silent on success: standard output and the exit status are the command's. "
                + "If any file cannot be versioned, the command is not run."),
        ToolDoc(
            name: "file-trash", summary: "Move files to the Trash and report where they went.", changes: true,
            fields: [
                ("trashed_to", "absolute path of the item in the Trash, which may be renamed"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: ["file-trash old-notes.txt", "file-trash --dry-run build/"],
            notes: ""),
        ToolDoc(
            name: "file-clone", summary: "Make a copy that shares storage with the original.", changes: true,
            fields: [
                ("destination", "absolute path of the copy"),
                ("cloned", "true for a storage-sharing clone, false for a full copy made with --allow-copy"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: ["file-clone big.mov big-copy.mov", "file-clone --allow-copy a.txt /Volumes/USB/a.txt"],
            notes: "Fails where the volume cannot clone, unless --allow-copy is given. The destination must not exist."),
        ToolDoc(
            name: "file-swap", summary: "Exchange two files in one atomic step.", changes: true,
            fields: [
                ("other", "absolute path of the second file"),
                ("dry_run", "true if nothing was changed"),
            ],
            examples: ["file-swap config.yml config.new.yml"],
            notes: "Afterwards each path holds what the other held. Both must be on the same volume."),
    ]

    // MARK: Generated documents

    /// A short orientation an agent can read once.
    public static var guide: String {
        var lines = [
            "mft \(mftVersion): small macOS file tools with one interface.",
            "",
            "WHAT THIS IS",
            "macOS keeps per-file versions in a system store, the one behind \"Browse All Versions\"",
            "in document apps. These tools read and write that store. A version is a full copy of a",
            "file's contents at one moment; storing one is nearly free on APFS.",
            "",
            "TOOLS",
        ]
        lines += tools.map { "  \($0.name.padding(toLength: 12, withPad: " ", startingAt: 0)) \($0.summary)" }
        lines += [
            "",
            "CALLING CONVENTION",
            "  tool [options] FILE...        options first, files last, -- ends options",
            "  A lone '-' reads the file list from standard input (-0 for NUL-separated).",
            "  Every tool: --text (for people), -q/--quiet, -h/--help.",
            "  Every tool that changes something: -n/--dry-run, --timeout SECONDS.",
            "",
            "OUTPUT",
            "  One JSON object per line, one per file. Successes on standard output with \"ok\":true,",
            "  failures on standard error with \"ok\":false and error.code, error.message, error.hint.",
            "  Exceptions: ver-cat prints the version's bytes; ver-guard prints nothing of its own.",
            "",
            "CHOOSING A VERSION (--rev)",
        ]
        lines += selectors.map { "  \($0.form.padding(toLength: 12, withPad: " ", startingAt: 0)) \($0.meaning)" }
        lines += [
            "",
            "COMMON TASKS",
            "  Checkpoint before editing      ver-add --note 'why' FILE",
            "  Checkpoint several as one      ver-add --tag NAME FILE...   then   ver-restore -r tag:NAME FILE...",
            "  Take back the last change      ver-undo FILE                (again to redo)",
            "  See what changed               ver-diff FILE",
            "  Read an old version            ver-ls FILE, then read contents_path",
            "  Check a location works         ver-status --probe FILE",
            "",
            "THINGS TO KNOW",
            "  Versions follow a file through rename, move and edits. A plain copy has none: use ver-cp.",
            "  Deleting a file deletes its versions. Moving it to another volume loses them.",
            "  Versions are not in Time Machine backups and are local to this Mac.",
            "  ver-restore and ver-undo store the replaced contents first, so they can be undone.",
            "  Use ids from ver-ls in programs; @N positions shift as versions are added.",
            "",
            "EXIT STATUS",
            "  0 all files succeeded   1 files failed for different reasons   64 bad usage",
        ]
        let byExit = Dictionary(grouping: ToolError.Code.allCases, by: \.exit)
        lines += byExit.keys.sorted().map { status in
            "  \(status) " + byExit[status]!.map(\.rawValue).joined(separator: ", ")
        }
        lines += ["", "MORE", "  mft describe      everything above as JSON, with every record field",
                  "  TOOL --help       options and examples for one tool",
                  "  mft selftest      check that versioning behaves as expected on this Mac"]
        return lines.joined(separator: "\n")
    }

    /// The whole interface as one JSON document. `help` maps tool names to their help text.
    public static func describe(help: [String: String]) -> [String: Any] {
        func table(_ rows: [(name: String, meaning: String)]) -> [[String: String]] {
            rows.map { ["name": $0.name, "meaning": $0.meaning] }
        }
        return [
            "name": "mft",
            "version": mftVersion,
            "summary": "Small macOS file tools with one interface. Each tool is also a subcommand of mft.",
            "calling_convention": "tool [options] FILE...; a lone '-' reads the file list from standard input",
            "output": "JSON lines: one record per file operand; successes on stdout, failures on stderr",
            "common_fields": table(commonFields),
            "version_fields": table(versionFields),
            "selectors": selectors.map { ["form": $0.form, "meaning": $0.meaning] },
            "environment": table(environment),
            "errors": ToolError.Code.allCases.map {
                ["code": $0.rawValue, "exit": Int($0.exit), "meaning": $0.meaning, "hint": $0.hint] as [String: Any]
            },
            "exit_status": [
                ["exit": 0, "meaning": "Every operand succeeded."],
                ["exit": 1, "meaning": "Operands failed for different reasons; read the records."],
                ["exit": 64, "meaning": "Bad usage. The message is plain text from the argument parser."],
            ],
            "tools": tools.map { tool in
                [
                    "name": tool.name,
                    "summary": tool.summary,
                    "changes_files_or_versions": tool.changes,
                    "record_fields": table(tool.fields),
                    "examples": tool.examples,
                    "notes": tool.notes,
                    "help": help[tool.name] ?? "",
                ] as [String: Any]
            },
        ]
    }
}
