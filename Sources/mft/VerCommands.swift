import ArgumentParser
import Foundation
import MFTCore

// Every tool has the same shape:
//   options from the shared groups, then FILE operands last;
//   one record per operand; failures reported per operand.

/// Options for tools that store a version.
struct DescribeOptions: ParsableArguments {
    @Option(help: "Why this version is being stored.") var note: String?
    @Option(help: "A name shared by versions stored together; select it later with --rev tag:NAME.") var tag: String?
    @Option(help: "Who is storing it. Defaults to $MFT_ACTOR.") var by: String?
    @Flag(help: "Mark the version disposable: macOS may delete it to free space.") var auto = false

    var meta: Meta { Meta(note: note, tag: tag, by: by, auto: auto) }
}

struct VerLs: ParsableCommand {
    static let configuration = Catalog.doc("ver-ls").configuration

    @OptionGroup var output: OutputOptions
    @Option(help: "Show only the newest N versions.") var limit: Int?
    @OptionGroup var operands: FileOperands

    func run() throws {
        let emit = Emitter(tool: "ver-ls", output: output)
        try emit.forEach(operands.paths) { url in
            let all = Versions.list(url)
            let shown = limit.map { Array(all.prefix(max(0, $0))) } ?? all
            emit.result(
                ["path": url.path, "versions": shown.map(\.fields), "count": all.count],
                text: shown.map { $0.line(url.path) }.joined(separator: "\n"))
        }
    }
}

struct VerAdd: ParsableCommand {
    static let configuration = Catalog.doc("ver-add").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var describe: DescribeOptions
    @Option(help: "Store this file's contents instead (one FILE only).") var from: String?
    @Flag(help: "Store a version even if the newest one already holds these contents.") var force = false
    @OptionGroup var operands: FileOperands

    func validate() throws {
        if from != nil && operands.files.count != 1 {
            throw ValidationError("--from takes exactly one FILE.")
        }
    }

    func run() throws {
        let emit = Emitter(tool: "ver-add", output: output, mutation: mutation)
        try emit.forEach(operands.paths) { url in
            if mutation.dryRun {
                let latest = Versions.list(url).first
                let unchanged = !force && from == nil
                    && latest.map { Versions.sameContents($0.raw.url, url) } == true
                emit.result(
                    ["path": url.path, "version": unchanged ? latest!.fields : NSNull(),
                     "created": !unchanged, "dry_run": true],
                    text: "\(unchanged ? "unchanged" : "would add")\t\(url.path)")
                return
            }
            let (version, created) = try Versions.add(
                to: url, from: from.map { URL(fileURLWithPath: $0) }, meta: describe.meta, force: force)
            emit.result(
                ["path": url.path, "version": version.fields, "created": created, "dry_run": false],
                text: "\(created ? "added" : "unchanged")\t\(version.id)\t\(url.path)")
        }
    }
}

struct VerCat: ParsableCommand {
    static let configuration = Catalog.doc("ver-cat").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var rev: RevOption
    @Argument(help: "File whose version to read.") var file: String

    func run() throws {
        // The one tool whose stdout is not records: it is the version's bytes.
        let emit = Emitter(tool: "ver-cat", output: output)
        try emit.forEach([file]) { url in
            let version = try Versions.resolve(rev.rev, for: url)
            FileHandle.standardOutput.write(try Data(contentsOf: version.raw.url))
        }
    }
}

struct VerDiff: ParsableCommand {
    static let configuration = Catalog.doc("ver-diff").configuration

    @OptionGroup var output: OutputOptions
    @Option(
        name: [.customShort("r"), .long],
        help: ArgumentHelp("The older side. Default: latest.", valueName: "selector"))
    var rev: String = "latest"
    @Option(help: ArgumentHelp("The newer side. Default: the current file.", valueName: "selector"))
    var to: String?
    @Argument(help: "File to compare.") var file: String

    func run() throws {
        let emit = Emitter(tool: "ver-diff", output: output)
        try emit.forEach([file]) { url in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                throw ToolError(.unsupportedOperation, "cannot diff a folder",
                                hint: "Read contents_path from ver-ls and compare the folders yourself.")
            }
            let older = try Versions.resolve(rev, for: url)
            let newer = try to.map { try Versions.resolve($0, for: url) }
            let (changed, binary, diff) = try unifiedDiff(
                older.raw.url, newer?.raw.url ?? url,
                labels: ("\(url.path) (\(older.id))", "\(url.path) (\(newer?.id ?? "current"))"))
            emit.result(
                ["path": url.path, "from": older.id, "to": newer?.id ?? "current",
                 "changed": changed, "binary": binary, "diff": diff],
                text: binary ? "binary files differ\t\(url.path)" : diff.trimmingCharacters(in: .newlines))
        }
    }

    /// Runs diff(1), the same comparison a person would run by hand.
    func unifiedDiff(_ a: URL, _ b: URL, labels: (String, String)) throws -> (Bool, Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
        process.arguments = ["-u", "--label", labels.0, "--label", labels.1, a.path, b.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return (false, false, "")
        case 1: return text.hasPrefix("Binary files") ? (true, true, "") : (true, false, text)
        default: throw ToolError(.ioError, "diff could not compare the two versions")
        }
    }
}

struct VerRestore: ParsableCommand {
    static let configuration = Catalog.doc("ver-restore").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var rev: RevOption
    @Flag(help: "Do not store the contents being replaced as a version first.") var noKeepCurrent = false
    @Option(help: ArgumentHelp("Fail unless the newest version is this one (or 'none').", valueName: "id"))
    var expectLatest: String?
    @OptionGroup var operands: FileOperands

    func run() throws {
        let emit = Emitter(tool: "ver-restore", output: output, mutation: mutation)
        try emit.forEach(operands.paths) { url in
            try Versions.expectLatest(expectLatest, for: url)
            let version = try Versions.resolve(rev.rev, for: url)
            try restore(version, to: url, keepCurrent: !noKeepCurrent, dryRun: mutation.dryRun, emit: emit)
        }
    }
}

struct VerUndo: ParsableCommand {
    static let configuration = Catalog.doc("ver-undo").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var operands: FileOperands

    func run() throws {
        let emit = Emitter(tool: "ver-undo", output: output, mutation: mutation)
        try emit.forEach(operands.paths) { url in
            let all = Versions.list(url)
            guard !all.isEmpty else { throw ToolError(.noVersions, "file has no stored versions") }
            guard let version = all.first(where: { !Versions.sameContents($0.raw.url, url) }) else {
                throw ToolError(.noSuchVersion, "every stored version matches the current contents",
                                hint: "There is nothing to undo.")
            }
            try restore(version, to: url, keepCurrent: true, dryRun: mutation.dryRun, emit: emit)
        }
    }
}

/// Shared by ver-restore and ver-undo, so both keep the replaced contents and
/// both print the same record.
func restore(_ version: Version, to url: URL, keepCurrent: Bool, dryRun: Bool, emit: Emitter) throws {
    if dryRun {
        emit.result(
            ["path": url.path, "restored": version.id, "kept_current_as": NSNull(),
             "verified": false, "dry_run": true],
            text: "would restore\t\(version.id)\t\(url.path)")
        return
    }
    // Restoring overwrites the file and keeps nothing, so save first.
    let kept = keepCurrent
        ? try Versions.add(to: url, meta: Meta(note: "before restoring \(version.id.prefix(8))")).version
        : nil
    let verified = try Versions.restore(version, to: url)
    emit.result(
        ["path": url.path, "restored": version.id, "kept_current_as": orNull(kept?.id),
         "verified": verified, "dry_run": false],
        text: "restored\t\(version.id)\t\(url.path)")
}

struct VerRm: ParsableCommand {
    static let configuration = Catalog.doc("ver-rm").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option(
        name: [.customShort("r"), .long],
        help: ArgumentHelp("Version to delete (same selectors as the other tools).", valueName: "selector"))
    var rev: String?
    @Flag(help: "Delete every stored version.") var all = false
    @Option(help: ArgumentHelp("Fail unless the newest version is this one.", valueName: "id"))
    var expectLatest: String?
    @OptionGroup var operands: FileOperands

    func validate() throws {
        if (rev != nil) == all {
            throw ValidationError("Give exactly one of --rev or --all.")
        }
    }

    func run() throws {
        let emit = Emitter(tool: "ver-rm", output: output, mutation: mutation)
        try emit.forEach(operands.paths) { url in
            try Versions.expectLatest(expectLatest, for: url)
            let doomed = try rev.map { [try Versions.resolve($0, for: url)] } ?? Versions.list(url)
            if !mutation.dryRun { try Versions.remove(doomed, of: url) }
            let verb = mutation.dryRun ? "would remove" : "removed"
            emit.result(
                ["path": url.path, "removed": doomed.map(\.id), "dry_run": mutation.dryRun],
                text: doomed.map { "\(verb)\t\($0.id)\t\(url.path)" }.joined(separator: "\n"))
        }
    }
}

struct VerPrune: ParsableCommand {
    static let configuration = Catalog.doc("ver-prune").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option(help: "Always keep the newest N versions.") var keepLast: Int?
    @Option(help: ArgumentHelp("Delete only versions older than this (30d, 12h, 2w).", valueName: "age"))
    var olderThan: String?
    @Flag(help: "Delete only disposable versions (those stored with --auto).") var autoOnly = false
    @Flag(help: "Allow tagged versions to be deleted too.") var includeTagged = false
    @OptionGroup var operands: FileOperands

    func validate() throws {
        if keepLast == nil && olderThan == nil {
            throw ValidationError("Give --keep-last, --older-than, or both.")
        }
        if let keepLast, keepLast < 0 { throw ValidationError("--keep-last cannot be negative.") }
        if let olderThan, parseDuration(olderThan) == nil {
            throw ValidationError("Cannot read '\(olderThan)' as an age. Use forms like 30d, 12h or 2w.")
        }
    }

    func run() throws {
        let emit = Emitter(tool: "ver-prune", output: output, mutation: mutation)
        let cutoff = olderThan.flatMap(parseDuration).map { Date().addingTimeInterval(-$0) }
        try emit.forEach(operands.paths) { url in
            let all = Versions.list(url)
            let doomed = all.dropFirst(keepLast ?? 0).filter { version in
                (cutoff.map { version.date < $0 } ?? true)
                    && (!autoOnly || version.raw.isDiscardable)
                    && (includeTagged || version.meta.tag == nil)
            }
            if !mutation.dryRun && !doomed.isEmpty { try Versions.remove(doomed, of: url) }
            let verb = mutation.dryRun ? "would remove" : "removed"
            emit.result(
                ["path": url.path, "removed": doomed.map(\.id), "kept": all.count - doomed.count,
                 "dry_run": mutation.dryRun],
                text: doomed.map { "\(verb)\t\($0.id)\t\(url.path)" }.joined(separator: "\n"))
        }
    }
}

struct VerStatus: ParsableCommand {
    static let configuration = Catalog.doc("ver-status").configuration

    @OptionGroup var output: OutputOptions
    @Flag(help: "Find out for certain whether versions work here, by storing one and deleting it.")
    var probe = false
    @OptionGroup var operands: FileOperands

    func run() throws {
        let emit = Emitter(tool: "ver-status", output: output)
        try emit.forEach(operands.paths) { url in
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isPackageKey, .isUbiquitousItemKey,
                .volumeLocalizedFormatDescriptionKey, .volumeIsLocalKey,
            ])
            let all = Versions.list(url)
            let kind = values.isPackage == true ? "package" : values.isDirectory == true ? "folder" : "file"
            let format = values.volumeLocalizedFormatDescription ?? "unknown"
            let local = values.volumeIsLocal ?? true
            let inICloud = values.isUbiquitousItem ?? false

            var supported: Bool? = all.isEmpty ? nil : true
            if supported == nil && probe {
                do {
                    let stored = try Versions.add(to: url, meta: Meta(note: "probe", auto: true), force: true)
                    try Versions.remove([stored.version], of: url)
                    supported = true
                } catch let error as ToolError where error.code == .versionsUnsupported {
                    supported = false
                }
            }

            var warnings: [String] = []
            if supported == false { warnings.append("Versions cannot be stored on this volume.") }
            if supported == nil && !format.hasPrefix("APFS") {
                warnings.append("This volume is \(format), not APFS; versions may not work. Run with --probe to check.")
            }
            if !local { warnings.append("This is a network volume; versions are unlikely to work.") }
            if inICloud { warnings.append("This file is in iCloud Drive; versions stored here stay on this Mac.") }
            if kind != "file" { warnings.append("Versions of a \(kind) are less well tested than versions of a file.") }

            let changed: Bool? = all.first.map { !Versions.sameContents($0.raw.url, url) }
            emit.result(
                ["path": url.path, "kind": kind, "count": all.count,
                 "latest": orNull(all.first?.fields), "changed_since_latest": orNull(changed),
                 "versions_supported": orNull(supported), "volume_format": format,
                 "volume_local": local, "in_icloud": inICloud, "warnings": warnings],
                text: ([
                    "\(all.count) version(s)\t\(kind)\t\(format)\t\(url.path)",
                    changed.map { "\t" + ($0 ? "changed since the latest version" : "same as the latest version") },
                ].compactMap { $0 } + warnings.map { "\twarning: \($0)" }).joined(separator: "\n"))
        }
    }
}

struct VerCp: ParsableCommand {
    static let configuration = Catalog.doc("ver-cp").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Argument(help: "File to copy.") var source: String
    @Argument(help: "Where to put the copy. Must not exist.") var destination: String

    func run() throws {
        let emit = Emitter(tool: "ver-cp", output: output, mutation: mutation)
        try emit.forEach([source]) { url in
            let target = absoluteURL(destination)
            if FileManager.default.fileExists(atPath: target.path) {
                throw ToolError(.alreadyExists, "\(target.path) already exists")
            }
            // Oldest first, so the copy ends up with the same order.
            let versions = Versions.list(url).reversed()
            if mutation.dryRun {
                emit.result(
                    ["path": url.path, "destination": target.path, "versions_copied": versions.count, "dry_run": true],
                    text: "would copy\t\(versions.count) version(s)\t\(url.path)\t\(target.path)")
                return
            }
            try FileManager.default.copyItem(at: url, to: target)
            do {
                for version in versions {
                    var meta = version.meta
                    meta.added = nil
                    try Versions.add(to: target, from: version.raw.url, meta: meta, force: true)
                }
            } catch {
                // All or nothing: a copy that silently lacks its history is the
                // problem this tool exists to avoid.
                try? Versions.remove(Versions.list(target), of: target)
                try? FileManager.default.removeItem(at: target)
                throw error
            }
            emit.result(
                ["path": url.path, "destination": target.path, "versions_copied": versions.count, "dry_run": false],
                text: "copied\t\(versions.count) version(s)\t\(url.path)\t\(target.path)")
        }
    }
}

struct VerGuard: ParsableCommand {
    static let configuration = Catalog.doc("ver-guard").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option(help: "Why these versions are being stored. Defaults to the command.") var note: String?
    @Option(help: "A name shared by the versions stored; select it later with --rev tag:NAME.") var tag: String?
    @Option(help: "Who is storing them. Defaults to $MFT_ACTOR.") var by: String?
    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Files to store versions of, then --, then the command to run.", valueName: "files -- command"))
    var rest: [String] = []

    /// Everything before the first -- is a file; everything after is the command.
    var files: [String] { Array(rest.prefix { $0 != "--" }) }
    var command: [String] { Array(rest.drop { $0 != "--" }.dropFirst()) }

    func validate() throws {
        if files.isEmpty || command.isEmpty {
            throw ValidationError("Usage: ver-guard [options] FILE... -- COMMAND [ARGUMENT...]")
        }
    }

    func run() throws {
        let emit = Emitter(tool: "ver-guard", output: output, mutation: mutation)
        let command = self.command
        let reason = note ?? "before: " + command.joined(separator: " ")
        try emit.forEach(files) { url in
            if mutation.dryRun {
                emit.result(
                    ["path": url.path, "command": command, "dry_run": true],
                    text: "would add\t\(url.path)")
                return
            }
            // Untagged checkpoints are disposable; a tag means someone wants it kept.
            try Versions.add(to: url, meta: Meta(note: reason, tag: tag, by: by, auto: tag == nil))
        }
        if mutation.dryRun { return }

        fflush(stdout)
        var arguments = command.map { strdup($0) } + [nil]
        execvp(command[0], &arguments)
        // Only reached if the command could not be started.
        emit.failure(command[0], ToolError(.ioError, "cannot run command: \(String(cString: strerror(errno)))"))
        throw ExitCode(ToolError.Code.ioError.exit)
    }
}
