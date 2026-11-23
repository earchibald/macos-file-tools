import ArgumentParser
import Foundation
import MFTCore

// Every tool has the same shape:
//   options from the shared groups, then FILE operands last;
//   one record per operand; failures reported per operand.

struct VerLs: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ver-ls", abstract: "List the stored versions of files.")

    @OptionGroup var output: OutputOptions
    @Argument(help: "Files to inspect.") var files: [String]

    func run() throws {
        let emit = Emitter(tool: "ver-ls", options: output)
        try emit.forEach(files) { url in
            let versions = Versions.list(url)
            emit.result(
                ["path": url.path, "versions": versions.map(\.fields)],
                text: versions
                    .map { "@\($0.index)\t\($0.id)\t\(iso8601($0.date))\t\(url.path)" }
                    .joined(separator: "\n"))
        }
    }
}

struct VerAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ver-add", abstract: "Store the current contents of files as a new version.")

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option(help: "Store this file's contents instead (one FILE only).") var from: String?
    @Argument(help: "Files to add a version to.") var files: [String]

    func validate() throws {
        if from != nil && files.count != 1 {
            throw ValidationError("--from takes exactly one FILE.")
        }
    }

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

struct VerCat: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ver-cat", abstract: "Write one stored version's bytes to standard output.")

    @OptionGroup var output: OutputOptions
    @OptionGroup var rev: RevOption
    @Argument(help: "File whose version to read.") var file: String

    func run() throws {
        // The one tool whose stdout is not records: it is the version's bytes.
        let emit = Emitter(tool: "ver-cat", options: output)
        try emit.forEach([file]) { url in
            let version = try Versions.resolve(rev.rev, for: url)
            FileHandle.standardOutput.write(try Data(contentsOf: version.raw.url))
        }
    }
}

struct VerRestore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ver-restore", abstract: "Replace a file's contents with a stored version.")

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var rev: RevOption
    @Flag(help: "Do not store the current contents as a version first.") var noKeepCurrent = false
    @Argument(help: "File to restore.") var file: String

    func run() throws {
        let emit = Emitter(tool: "ver-restore", options: output)
        try emit.forEach([file]) { url in
            let version = try Versions.resolve(rev.rev, for: url)
            if mutation.dryRun {
                emit.result(
                    ["path": url.path, "restored": version.id, "dry_run": true],
                    text: "would restore\t\(version.id)\t\(url.path)")
                return
            }
            // replaceItem overwrites the file and keeps nothing, so save first.
            let kept = noKeepCurrent ? nil : try Versions.add(to: url)
            try Versions.restore(version, to: url)
            emit.result(
                ["path": url.path, "restored": version.id, "kept_current_as": kept?.id ?? NSNull(),
                 "dry_run": false],
                text: "restored\t\(version.id)\t\(url.path)")
        }
    }
}

struct VerRm: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ver-rm", abstract: "Delete stored versions. The file itself is not touched.")

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option(
        name: [.customShort("r"), .long],
        help: ArgumentHelp("Version to delete (same selectors as the other tools).", valueName: "selector"))
    var rev: String?
    @Flag(help: "Delete every stored version.") var all = false
    @Argument(help: "Files whose versions to delete.") var files: [String]

    func validate() throws {
        if (rev != nil) == all {
            throw ValidationError("Give exactly one of --rev or --all.")
        }
    }

    func run() throws {
        let emit = Emitter(tool: "ver-rm", options: output)
        try emit.forEach(files) { url in
            let doomed = try rev.map { [try Versions.resolve($0, for: url)] } ?? Versions.list(url)
            if !mutation.dryRun { try Versions.remove(doomed, of: url) }
            let verb = mutation.dryRun ? "would remove" : "removed"
            emit.result(
                ["path": url.path, "removed": doomed.map(\.id), "dry_run": mutation.dryRun],
                text: doomed.map { "\(verb)\t\($0.id)\t\(url.path)" }.joined(separator: "\n"))
        }
    }
}

struct FileTrash: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "file-trash", abstract: "Move files to the Trash and report where they went.")

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Argument(help: "Files to move to the Trash.") var files: [String]

    func run() throws {
        let emit = Emitter(tool: "file-trash", options: output)
        try emit.forEach(files) { url in
            if mutation.dryRun {
                emit.result(["path": url.path, "dry_run": true], text: "would trash\t\(url.path)")
                return
            }
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            let landed = destination?.path ?? ""
            emit.result(["path": url.path, "trashed_to": landed, "dry_run": false], text: "trashed\t\(url.path)\t\(landed)")
        }
    }
}
