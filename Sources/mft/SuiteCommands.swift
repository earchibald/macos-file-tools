import ArgumentParser
import Foundation
import MFTCore

// Commands about the suite itself: documentation, installation, self-checks
// and the hook that lets an agent's edits checkpoint themselves.

struct Guide: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guide", abstract: "Print a one-page orientation, written for agents and people alike.")

    func run() {
        print(Catalog.guide)
    }
}

struct Describe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe",
        abstract: "Print the whole interface as JSON: tools, record fields, selectors, error codes.")

    func run() throws {
        let help = Dictionary(uniqueKeysWithValues: toolCommands.map {
            ($0.configuration.commandName ?? "", Mft.helpMessage(for: $0))
        })
        let data = try JSONSerialization.data(
            withJSONObject: Catalog.describe(help: help),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
    }
}

struct Link: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Create a command for each tool in a folder, as links to this program.",
        discussion: "EXAMPLES:\n  mft link --dir ~/.local/bin\n  mft link --dir /usr/local/bin --force")

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Option(help: "Folder to create the links in. It must be on your PATH to be useful.") var dir: String
    @Flag(help: "Replace existing files of the same names.") var force = false

    func run() throws {
        let emit = Emitter(tool: "link", output: output, mutation: mutation)
        let folder = URL(fileURLWithPath: dir).standardizedFileURL
        let program = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        // A link beside the program stays valid if the folder is moved.
        let target = program.deletingLastPathComponent().path == folder.resolvingSymlinksInPath().path
            ? program.lastPathComponent : program.path
        let manager = FileManager.default
        var statuses = Set<Int32>()

        for name in toolNames {
            let link = folder.appendingPathComponent(name)
            do {
                let existing = try? manager.destinationOfSymbolicLink(atPath: link.path)
                var created = false
                if existing != target {
                    let occupied = existing != nil || manager.fileExists(atPath: link.path)
                    if occupied && !force {
                        throw ToolError(.alreadyExists, "something else is already at this path",
                                        hint: "Pass --force to replace it.")
                    }
                    if !mutation.dryRun {
                        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                        if occupied { try manager.removeItem(at: link) }
                        try manager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                    }
                    created = true
                }
                emit.result(
                    ["path": link.path, "target": target, "created": created, "dry_run": mutation.dryRun],
                    text: "\(created ? (mutation.dryRun ? "would link" : "linked") : "present")\t\(link.path)\t\(target)")
            } catch {
                let wrapped = ToolError.wrap(error)
                emit.failure(link.path, wrapped)
                statuses.insert(wrapped.code.exit)
            }
        }
        if statuses.count == 1 { throw ExitCode(statuses.first!) }
        if statuses.count > 1 { throw ExitCode(1) }
    }
}

struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Store a version of the file an agent is about to edit.",
        discussion: """
            Reads an agent's pre-edit hook JSON on standard input and stores a
            disposable version of the file named in tool_input.file_path. It prints
            nothing and always exits 0, so it can never block or slow an edit.

            EXAMPLE (Claude Code, in hooks.json):
              {"hooks": {"PreToolUse": [{"matcher": "Edit|Write|MultiEdit|NotebookEdit",
                "hooks": [{"type": "command", "command": "mft hook", "timeout": 10}]}]}}
            """)

    @Option(help: "Who to record as storing the version.") var by: String = "agent"

    func run() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let input = event["tool_input"] as? [String: Any] ?? event
        guard let path = ["file_path", "notebook_path", "path"].compactMap({ input[$0] as? String }).first
        else { return }

        let base = (event["cwd"] as? String).map { URL(fileURLWithPath: $0) }
        let url = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        // A file that does not exist yet has nothing to save.
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        var note = "before " + (event["tool_name"] as? String ?? "edit")
        if let session = event["session_id"] as? String { note += " (session \(session.prefix(8)))" }
        Versions.timeout = 5
        _ = try? Versions.add(to: url, meta: Meta(note: note, by: by, auto: true))
    }
}

struct Selftest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selftest",
        abstract: "Check that macOS versioning behaves on this Mac the way these tools assume.",
        discussion: """
            Works in a scratch folder that is removed afterwards. Run it after a
            macOS update, or with --dir to check another volume.

            EXAMPLES:
              mft selftest
              mft selftest --dir /Volumes/External --text
            """)

    @OptionGroup var output: OutputOptions
    @Option(help: "Folder to make the scratch folder in. Default: the system temporary folder.") var dir: String?

    func run() throws {
        let emit = Emitter(tool: "selftest", output: output)
        let manager = FileManager.default
        let parent = dir.map { URL(fileURLWithPath: $0) } ?? manager.temporaryDirectory
        let scratch = parent.appendingPathComponent("mft-selftest-\(UUID().uuidString.prefix(8))")
        try manager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: scratch) }

        var failed = false
        func check(_ name: String, _ expectation: String, _ body: () throws -> Bool) {
            var passed = false
            var detail = ""
            do { passed = try body() } catch { detail = ToolError.wrap(error).message }
            if !passed { failed = true }
            let record: [String: Any] = [
                "path": scratch.path, "check": name, "expected": expectation, "passed": passed, "detail": detail,
            ]
            if passed {
                emit.result(record, text: "pass\t\(name)\t\(expectation)")
            } else if emit.text {
                FileHandle.standardError.write(Data("FAIL\t\(name)\t\(expectation)\t\(detail)\n".utf8))
            } else {
                FileHandle.standardError.write(Data((Emitter.jsonLine(
                    record.merging(["ok": false, "tool": "selftest"]) { a, _ in a }) + "\n").utf8))
            }
        }
        func file(_ name: String, _ contents: String) throws -> URL {
            let url = scratch.appendingPathComponent(name)
            try contents.write(to: url, atomically: false, encoding: .utf8)
            return url
        }
        func count(_ url: URL) -> Int { Versions.list(url).count }

        check("store", "a version can be stored and listed") {
            let url = try file("store.txt", "one\n")
            return try Versions.add(to: url).created && count(url) == 1
        }
        check("idempotent", "storing unchanged contents again adds nothing") {
            let url = try file("same.txt", "one\n")
            _ = try Versions.add(to: url)
            return try !Versions.add(to: url).created && count(url) == 1
        }
        check("read", "a stored version's contents can be read from its path") {
            let url = try file("read.txt", "one\n")
            let version = try Versions.add(to: url).version
            try "two\n".write(to: url, atomically: false, encoding: .utf8)
            return try String(contentsOf: version.raw.url, encoding: .utf8) == "one\n"
        }
        check("date", "a version's date is the modification date of its contents") {
            let url = try file("date.txt", "one\n")
            let old = Date(timeIntervalSince1970: 1_600_000_000)
            try manager.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            return try abs(Versions.add(to: url).version.date.timeIntervalSince(old)) < 2
        }
        check("overwrite", "versions survive the file being overwritten in place") {
            let url = try file("over.txt", "one\n")
            _ = try Versions.add(to: url)
            try "two\n".write(to: url, atomically: false, encoding: .utf8)
            return count(url) == 1
        }
        check("rename", "versions follow a rename") {
            let url = try file("before.txt", "one\n")
            _ = try Versions.add(to: url)
            let moved = scratch.appendingPathComponent("after.txt")
            try manager.moveItem(at: url, to: moved)
            return count(moved) == 1
        }
        check("rename-over", "versions survive a save that renames a new file over the old one") {
            let url = try file("target.txt", "one\n")
            _ = try Versions.add(to: url)
            let fresh = try file("fresh.txt", "two\n")
            guard rename(fresh.path, url.path) == 0 else { return false }
            return count(url) == 1
        }
        check("copy", "a plain copy starts with no versions") {
            let url = try file("orig.txt", "one\n")
            _ = try Versions.add(to: url)
            let copy = scratch.appendingPathComponent("copy.txt")
            try manager.copyItem(at: url, to: copy)
            return count(copy) == 0
        }
        check("restore", "restoring a version puts its exact contents back") {
            let url = try file("restore.txt", "one\n")
            let version = try Versions.add(to: url).version
            try "two\n".write(to: url, atomically: false, encoding: .utf8)
            return try Versions.restore(version, to: url)
                && String(contentsOf: url, encoding: .utf8) == "one\n"
        }
        check("remove", "a version can be deleted without touching the file") {
            let url = try file("remove.txt", "one\n")
            let version = try Versions.add(to: url).version
            try Versions.remove([version], of: url)
            return try count(url) == 0 && String(contentsOf: url, encoding: .utf8) == "one\n"
        }
        check("disposable", "a version can be marked disposable and stays marked") {
            let url = try file("auto.txt", "one\n")
            _ = try Versions.add(to: url, meta: Meta(auto: true))
            return Versions.list(url).first?.raw.isDiscardable == true
        }
        check("clone", "the volume can make storage-sharing clones") {
            let url = try file("clone-src.txt", "one\n")
            return clonefile(url.path, scratch.appendingPathComponent("clone-dst.txt").path, 0) == 0
        }

        if failed { throw ExitCode(1) }
    }
}
