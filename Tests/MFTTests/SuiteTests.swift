import XCTest

/// Drives the built `mft` binary the way a caller would: arguments in, JSON
/// lines and an exit status out. Nothing here links against the tool's code,
/// so these tests hold the interface, not the implementation.
class SuiteTestCase: XCTestCase {
    struct Outcome {
        let status: Int32
        let out: String
        let err: String

        func parse(_ text: String) -> [[String: Any]] {
            text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        var records: [[String: Any]] { parse(out) }
        var failures: [[String: Any]] { parse(err) }
        var record: [String: Any] { records.first ?? [:] }
        var errorCode: String? { (failures.first?["error"] as? [String: Any])?["code"] as? String }
    }

    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let binary: URL = {
        let bundle = Bundle.allBundles.first { $0.bundlePath.hasSuffix(".xctest") }!
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("mft")
    }()

    var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mft-tests-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    @discardableResult
    func mft(_ arguments: String..., stdin: String? = nil, actor: String? = nil) -> Outcome {
        mft(arguments, stdin: stdin, actor: actor)
    }

    func mft(_ arguments: [String], stdin: String? = nil, actor: String? = nil) -> Outcome {
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = arguments
        process.currentDirectoryURL = scratch
        var environment = ProcessInfo.processInfo.environment
        environment["MFT_HOME"] = scratch.appendingPathComponent(".mft-home").path
        environment["MFT_ACTOR"] = actor
        process.environment = environment
        let (out, err, input) = (Pipe(), Pipe(), Pipe())
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try! process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        input.fileHandleForWriting.closeFile()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(
            status: process.terminationStatus,
            out: String(decoding: outData, as: UTF8.self),
            err: String(decoding: errData, as: UTF8.self))
    }

    /// Writes a file in the scratch folder and returns its name.
    @discardableResult
    func write(_ name: String, _ contents: String) -> String {
        try! contents.write(to: scratch.appendingPathComponent(name), atomically: false, encoding: .utf8)
        return name
    }

    func read(_ name: String) -> String {
        (try? String(contentsOf: scratch.appendingPathComponent(name), encoding: .utf8)) ?? "<missing>"
    }

    func versions(_ name: String) -> [[String: Any]] {
        mft("ver-ls", name).record["versions"] as? [[String: Any]] ?? []
    }

    func ids(_ name: String) -> [String] {
        versions(name).compactMap { $0["id"] as? String }
    }

    /// A file with one stored version per entry of `history`, then `current` as its contents.
    func file(_ name: String, history: [String], current: String) -> String {
        for contents in history {
            write(name, contents)
            XCTAssertEqual(mft("ver-add", name).status, 0)
        }
        return write(name, current)
    }
}

final class VersionTests: SuiteTestCase {
    func testAddStoresAVersionAndDescribesIt() {
        write("a.txt", "one\n")
        let record = mft("ver-add", "--note", "first", "--tag", "T", "a.txt", actor: "tester").record
        XCTAssertEqual(record["ok"] as? Bool, true)
        XCTAssertEqual(record["tool"] as? String, "ver-add")
        XCTAssertEqual(record["created"] as? Bool, true)
        XCTAssertEqual(record["dry_run"] as? Bool, false)
        XCTAssertTrue((record["path"] as? String ?? "").hasSuffix("/a.txt"))
        let version = record["version"] as? [String: Any] ?? [:]
        XCTAssertEqual(version["note"] as? String, "first")
        XCTAssertEqual(version["tag"] as? String, "T")
        XCTAssertEqual(version["by"] as? String, "tester")
        XCTAssertEqual(version["size"] as? Int, 4)
        // The contents are readable straight from the path in the record.
        XCTAssertEqual(try? String(contentsOfFile: version["contents_path"] as? String ?? ""), "one\n")
    }

    func testAddIsIdempotent() {
        write("a.txt", "one\n")
        let first = mft("ver-add", "a.txt").record
        let second = mft("ver-add", "a.txt").record
        XCTAssertEqual(second["created"] as? Bool, false)
        XCTAssertEqual((second["version"] as? [String: Any])?["id"] as? String,
                       (first["version"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(versions("a.txt").count, 1)
        XCTAssertEqual(mft("ver-add", "--force", "a.txt").record["created"] as? Bool, true)
        XCTAssertEqual(versions("a.txt").count, 2)
    }

    func testAutoVersionsAreDisposableAndNeverReusedForDeliberateOnes() {
        write("a.txt", "one\n")
        let auto = mft("ver-add", "--auto", "a.txt").record["version"] as? [String: Any]
        XCTAssertEqual(auto?["discardable"] as? Bool, true)
        let kept = mft("ver-add", "a.txt").record
        XCTAssertEqual(kept["created"] as? Bool, true)
        XCTAssertEqual((kept["version"] as? [String: Any])?["discardable"] as? Bool, false)
    }

    func testListIsNewestFirstAndEmptyIsNotAnError() {
        write("empty.txt", "x\n")
        let empty = mft("ver-ls", "empty.txt")
        XCTAssertEqual(empty.status, 0)
        XCTAssertEqual(empty.record["count"] as? Int, 0)
        XCTAssertEqual((empty.record["versions"] as? [Any])?.count, 0)

        _ = file("a.txt", history: ["one\n", "two\n", "three\n"], current: "four\n")
        let all = versions("a.txt")
        XCTAssertEqual(all.map { $0["index"] as? Int }, [1, 2, 3])
        XCTAssertEqual(all.compactMap { try? String(contentsOfFile: $0["contents_path"] as? String ?? "") },
                       ["three\n", "two\n", "one\n"])
        let limited = mft("ver-ls", "--limit", "1", "a.txt").record
        XCTAssertEqual((limited["versions"] as? [Any])?.count, 1)
        XCTAssertEqual(limited["count"] as? Int, 3)
    }

    func testSelectors() {
        write("a.txt", "one\n")
        mft("ver-add", "a.txt")
        write("a.txt", "two\n")
        mft("ver-add", "--tag", "mid", "a.txt")
        write("a.txt", "three\n")
        mft("ver-add", "a.txt")
        let all = ids("a.txt")

        XCTAssertEqual(mft("ver-cat", "--rev", "latest", "a.txt").out, "three\n")
        XCTAssertEqual(mft("ver-cat", "--rev", "oldest", "a.txt").out, "one\n")
        XCTAssertEqual(mft("ver-cat", "-r", "@2", "a.txt").out, "two\n")
        XCTAssertEqual(mft("ver-cat", "-r", "tag:mid", "a.txt").out, "two\n")
        XCTAssertEqual(mft("ver-cat", "-r", all[2], "a.txt").out, "one\n")
        XCTAssertEqual(mft("ver-cat", "-r", String(all[2].prefix(8)).uppercased(), "a.txt").out, "one\n")
        XCTAssertEqual(mft("ver-cat", "-r", "before:0s", "a.txt").out, "three\n")

        XCTAssertEqual(mft("ver-cat", "-r", "@9", "a.txt").errorCode, "no_such_version")
        XCTAssertEqual(mft("ver-cat", "-r", "tag:nope", "a.txt").errorCode, "no_such_version")
        XCTAssertEqual(mft("ver-cat", "-r", "before:2000-01-01", "a.txt").errorCode, "no_such_version")
        XCTAssertEqual(mft("ver-cat", "-r", "", "a.txt").errorCode, "ambiguous_version")
    }

    func testRestoreKeepsTheReplacedContentsAndVerifies() {
        _ = file("a.txt", history: ["one\n", "two\n"], current: "unsaved\n")
        let record = mft("ver-restore", "--rev", "oldest", "a.txt").record
        XCTAssertEqual(read("a.txt"), "one\n")
        XCTAssertEqual(record["verified"] as? Bool, true)
        let kept = record["kept_current_as"] as? String ?? ""
        XCTAssertEqual(mft("ver-cat", "-r", kept, "a.txt").out, "unsaved\n")
        XCTAssertEqual(versions("a.txt").count, 3)
    }

    func testRestoreWithoutKeepingStoresNothing() {
        _ = file("a.txt", history: ["one\n"], current: "unsaved\n")
        let record = mft("ver-restore", "-r", "latest", "--no-keep-current", "a.txt").record
        XCTAssertTrue(record["kept_current_as"] is NSNull)
        XCTAssertEqual(read("a.txt"), "one\n")
        XCTAssertEqual(versions("a.txt").count, 1)
    }

    func testRestoreByTagAcrossSeveralFiles() {
        for name in ["a.txt", "b.txt"] { write(name, "good \(name)\n") }
        XCTAssertEqual(mft("ver-add", "--tag", "checkpoint", "a.txt", "b.txt").records.count, 2)
        for name in ["a.txt", "b.txt"] { write(name, "broken\n") }
        let outcome = mft("ver-restore", "-r", "tag:checkpoint", "a.txt", "b.txt")
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.records.count, 2)
        XCTAssertEqual(read("a.txt"), "good a.txt\n")
        XCTAssertEqual(read("b.txt"), "good b.txt\n")
    }

    func testUndoThenUndoAgainIsRedo() {
        _ = file("a.txt", history: ["one\n"], current: "two\n")
        XCTAssertEqual(mft("ver-undo", "a.txt").status, 0)
        XCTAssertEqual(read("a.txt"), "one\n")
        XCTAssertEqual(mft("ver-undo", "a.txt").status, 0)
        XCTAssertEqual(read("a.txt"), "two\n")
    }

    func testUndoWithNothingToUndo() {
        write("a.txt", "one\n")
        XCTAssertEqual(mft("ver-undo", "a.txt").errorCode, "no_versions")
        mft("ver-add", "a.txt")
        let outcome = mft("ver-undo", "a.txt")
        XCTAssertEqual(outcome.errorCode, "no_such_version")
        XCTAssertEqual(outcome.status, 65)
    }

    func testDiff() {
        _ = file("a.txt", history: ["one\n", "two\n"], current: "three\n")
        let record = mft("ver-diff", "a.txt").record
        XCTAssertEqual(record["changed"] as? Bool, true)
        XCTAssertEqual(record["binary"] as? Bool, false)
        XCTAssertEqual(record["to"] as? String, "current")
        XCTAssertTrue((record["diff"] as? String ?? "").contains("-two\n+three\n"))

        let between = mft("ver-diff", "-r", "oldest", "--to", "latest", "a.txt").record
        XCTAssertTrue((between["diff"] as? String ?? "").contains("-one\n+two\n"))

        mft("ver-add", "a.txt")
        let same = mft("ver-diff", "a.txt").record
        XCTAssertEqual(same["changed"] as? Bool, false)
        XCTAssertEqual(same["diff"] as? String, "")
    }

    func testRemoveOneAndAll() {
        _ = file("a.txt", history: ["one\n", "two\n", "three\n"], current: "four\n")
        let before = ids("a.txt")
        let one = mft("ver-rm", "--rev", before[1], "a.txt").record
        XCTAssertEqual(one["removed"] as? [String], [before[1]])
        XCTAssertEqual(ids("a.txt"), [before[0], before[2]])
        XCTAssertEqual((mft("ver-rm", "--all", "a.txt").record["removed"] as? [String])?.count, 2)
        XCTAssertEqual(ids("a.txt"), [])
        XCTAssertEqual(read("a.txt"), "four\n")
    }

    func testPruneKeepsNewestAndSparesTags() {
        write("a.txt", "0\n")
        mft("ver-add", "--tag", "keep-me", "a.txt")
        for n in 1...4 {
            write("a.txt", "\(n)\n")
            mft("ver-add", "a.txt")
        }
        let record = mft("ver-prune", "--keep-last", "2", "a.txt").record
        XCTAssertEqual((record["removed"] as? [String])?.count, 2)
        XCTAssertEqual(record["kept"] as? Int, 3)
        XCTAssertEqual(versions("a.txt").last?["tag"] as? String, "keep-me")

        mft("ver-prune", "--keep-last", "0", "--include-tagged", "a.txt")
        XCTAssertEqual(versions("a.txt").count, 0)
    }

    func testPruneByAgeAndAutoOnly() {
        write("a.txt", "one\n")
        mft("ver-add", "--auto", "a.txt")
        write("a.txt", "two\n")
        mft("ver-add", "a.txt")
        // Nothing is older than a day.
        XCTAssertEqual((mft("ver-prune", "--older-than", "1d", "a.txt").record["removed"] as? [String])?.count, 0)
        let record = mft("ver-prune", "--keep-last", "0", "--auto-only", "a.txt").record
        XCTAssertEqual((record["removed"] as? [String])?.count, 1)
        XCTAssertEqual(versions("a.txt").first?["discardable"] as? Bool, false)
    }

    func testStatus() {
        write("a.txt", "one\n")
        let fresh = mft("ver-status", "a.txt").record
        XCTAssertEqual(fresh["kind"] as? String, "file")
        XCTAssertEqual(fresh["count"] as? Int, 0)
        XCTAssertTrue(fresh["latest"] is NSNull)
        XCTAssertTrue(fresh["changed_since_latest"] is NSNull)

        XCTAssertEqual(mft("ver-status", "--probe", "a.txt").record["versions_supported"] as? Bool, true)
        XCTAssertEqual(versions("a.txt").count, 0, "probing must leave nothing behind")

        mft("ver-add", "a.txt")
        XCTAssertEqual(mft("ver-status", "a.txt").record["changed_since_latest"] as? Bool, false)
        write("a.txt", "two\n")
        let changed = mft("ver-status", "a.txt").record
        XCTAssertEqual(changed["changed_since_latest"] as? Bool, true)
        XCTAssertEqual(changed["versions_supported"] as? Bool, true)
    }

    func testCopyCarriesVersions() {
        _ = file("a.txt", history: ["one\n", "two\n"], current: "three\n")
        let record = mft("ver-cp", "a.txt", "b.txt").record
        XCTAssertEqual(record["versions_copied"] as? Int, 2)
        XCTAssertEqual(read("b.txt"), "three\n")
        XCTAssertEqual(mft("ver-cat", "-r", "oldest", "b.txt").out, "one\n")
        XCTAssertEqual(mft("ver-cat", "-r", "latest", "b.txt").out, "two\n")
        XCTAssertEqual(mft("ver-cp", "a.txt", "b.txt").errorCode, "already_exists")
    }

    func testVersionsFollowRenameButNotCopy() throws {
        _ = file("a.txt", history: ["one\n"], current: "two\n")
        try FileManager.default.moveItem(
            at: scratch.appendingPathComponent("a.txt"), to: scratch.appendingPathComponent("renamed.txt"))
        XCTAssertEqual(versions("renamed.txt").count, 1)
        try FileManager.default.copyItem(
            at: scratch.appendingPathComponent("renamed.txt"), to: scratch.appendingPathComponent("copy.txt"))
        XCTAssertEqual(versions("copy.txt").count, 0)
    }

    func testExpectLatestGuardsAgainstConcurrentChanges() {
        _ = file("a.txt", history: ["one\n"], current: "two\n")
        let latest = ids("a.txt")[0]
        let stale = mft("ver-restore", "-r", "latest", "--expect-latest", "deadbeef", "a.txt")
        XCTAssertEqual(stale.errorCode, "precondition_failed")
        XCTAssertEqual(stale.status, 75)
        XCTAssertEqual(read("a.txt"), "two\n")
        XCTAssertEqual(mft("ver-restore", "-r", "latest", "--expect-latest", latest, "a.txt").status, 0)
        XCTAssertEqual(read("a.txt"), "one\n")
    }
}

final class WrapperTests: SuiteTestCase {
    func testGuardStoresAVersionThenRunsTheCommand() {
        write("a.txt", "one\n")
        let outcome = mft("ver-guard", "a.txt", "--", "/bin/sh", "-c", "echo two > a.txt; echo ran; exit 7")
        XCTAssertEqual(outcome.out, "ran\n", "stdout belongs to the command")
        XCTAssertEqual(outcome.status, 7, "the exit status is the command's")
        XCTAssertEqual(read("a.txt"), "two\n")
        let stored = versions("a.txt")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0]["discardable"] as? Bool, true)
        XCTAssertTrue((stored[0]["note"] as? String ?? "").hasPrefix("before: /bin/sh"))
    }

    func testGuardDoesNotRunTheCommandIfAFileCannotBeVersioned() {
        let outcome = mft("ver-guard", "missing.txt", "--", "/usr/bin/touch", "created-by-command")
        XCTAssertEqual(outcome.status, 66)
        XCTAssertEqual(outcome.errorCode, "no_such_file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("created-by-command").path))
    }

    func testHookStoresADisposableVersionAndNeverFails() {
        write("a.txt", "one\n")
        let event = """
            {"session_id":"abcdef123456","cwd":"\(scratch.path)","hook_event_name":"PreToolUse",
             "tool_name":"Edit","tool_input":{"file_path":"\(scratch.path)/a.txt","old_string":"a","new_string":"b"}}
            """
        let outcome = mft("hook", stdin: event)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertEqual(outcome.out + outcome.err, "")
        let stored = versions("a.txt")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0]["note"] as? String, "before Edit (session abcdef12)")
        XCTAssertEqual(stored[0]["by"] as? String, "agent")
        XCTAssertEqual(stored[0]["discardable"] as? Bool, true)

        // A file that does not exist yet, a relative path, and nonsense all pass quietly.
        for input in [
            "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"\(scratch.path)/new.txt\"}}",
            "{\"cwd\":\"\(scratch.path)\",\"tool_input\":{\"file_path\":\"a.txt\"}}",
            "not json", "",
        ] {
            let quiet = mft("hook", stdin: input)
            XCTAssertEqual(quiet.status, 0)
            XCTAssertEqual(quiet.out + quiet.err, "")
        }
    }

    func testFileTools() {
        write("a.txt", "A\n")
        write("b.txt", "B\n")
        XCTAssertEqual(mft("file-clone", "a.txt", "clone.txt").record["cloned"] as? Bool, true)
        XCTAssertEqual(read("clone.txt"), "A\n")
        XCTAssertEqual(mft("file-clone", "a.txt", "clone.txt").errorCode, "already_exists")

        XCTAssertEqual(mft("file-swap", "a.txt", "b.txt").status, 0)
        XCTAssertEqual(read("a.txt"), "B\n")
        XCTAssertEqual(read("b.txt"), "A\n")
        XCTAssertEqual(mft("file-swap", "a.txt", "missing.txt").errorCode, "no_such_file")

        let dry = mft("file-trash", "--dry-run", "a.txt").record
        XCTAssertEqual(dry["dry_run"] as? Bool, true)
        XCTAssertEqual(read("a.txt"), "B\n")
    }

    func testLinkMakesEachToolACommandOfItsOwn() throws {
        let bin = scratch.appendingPathComponent("bin")
        let linked = mft("link", "--dir", bin.path)
        XCTAssertEqual(linked.status, 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: bin.path).sorted()
        XCTAssertEqual(names.count, linked.records.count)
        XCTAssertTrue(names.contains("ver-ls") && names.contains("file-swap"))
        XCTAssertEqual(mft("link", "--dir", bin.path).records.compactMap { $0["created"] as? Bool }.contains(true), false)

        write("a.txt", "one\n")
        let process = Process()
        process.executableURL = bin.appendingPathComponent("ver-status")
        process.arguments = ["--text", scratch.appendingPathComponent("a.txt").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.hasPrefix("0 version(s)\tfile"))
    }

    func testSelftestPassesHere() {
        let outcome = mft("selftest", "--dir", scratch.path)
        XCTAssertEqual(outcome.status, 0, outcome.err)
        XCTAssertGreaterThanOrEqual(outcome.records.count, 10)
    }
}

/// The rules that make every tool predictable. A new tool that breaks one fails here.
final class ContractTests: SuiteTestCase {
    var interface: [String: Any] {
        let data = Data(mft("describe").out.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    var tools: [[String: Any]] { interface["tools"] as? [[String: Any]] ?? [] }

    /// One working invocation per tool, on a file that has two versions and unsaved changes.
    func invocation(_ tool: String) -> [String]? {
        switch tool {
        case "ver-ls", "ver-add", "ver-diff", "ver-undo", "ver-status": return [tool, "a.txt"]
        case "ver-restore": return [tool, "--rev", "latest", "a.txt"]
        case "ver-rm": return [tool, "--all", "a.txt"]
        case "ver-prune": return [tool, "--keep-last", "1", "a.txt"]
        case "ver-cp": return [tool, "a.txt", "copy.txt"]
        case "ver-guard": return [tool, "--dry-run", "a.txt", "--", "/usr/bin/true"]
        case "file-trash": return [tool, "--dry-run", "a.txt"]
        case "file-clone": return [tool, "a.txt", "clone.txt"]
        case "file-swap": return [tool, "a.txt", "other.txt"]
        default: return nil
        }
    }

    func testEveryRecordHasExactlyTheDocumentedFields() {
        XCTAssertGreaterThanOrEqual(tools.count, 14)
        for tool in tools {
            let name = tool["name"] as! String
            let documented = Set((tool["record_fields"] as! [[String: String]]).map { $0["name"]! })
            if name == "ver-cat" {
                XCTAssertTrue(documented.isEmpty)
                continue
            }
            guard let arguments = invocation(name) else {
                XCTFail("\(name) is documented but this test has no invocation for it")
                continue
            }
            _ = file("a.txt", history: ["one\n", "two\n"], current: "three\n")
            write("other.txt", "other\n")
            let outcome = mft(arguments)
            XCTAssertEqual(outcome.status, 0, "\(name): \(outcome.err)")
            XCTAssertEqual(outcome.records.count, 1, "\(name) must print one record per operand")
            XCTAssertEqual(
                Set(outcome.record.keys), documented.union(["ok", "tool", "path"]),
                "\(name) record fields differ from what `mft describe` documents")
            XCTAssertEqual(outcome.record["tool"] as? String, name)
            XCTAssertEqual(outcome.record["ok"] as? Bool, true)
            XCTAssertTrue((outcome.record["path"] as? String ?? "").hasPrefix("/"), "\(name): path must be absolute")
            tearDown()
            try! setUpWithError()
        }
    }

    func testVersionObjectsHaveExactlyTheDocumentedFields() {
        let documented = Set((interface["version_fields"] as! [[String: String]]).map { $0["name"]! })
        _ = file("a.txt", history: ["one\n"], current: "two\n")
        XCTAssertEqual(Set(versions("a.txt")[0].keys), documented)
    }

    func testSharedOptionsAreOnEveryToolThatShouldHaveThem() throws {
        let data = Data(mft("--experimental-dump-help").out.utf8)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let command = try XCTUnwrap(root["command"] as? [String: Any])
        let subcommands = try XCTUnwrap(command["subcommands"] as? [[String: Any]])
        let changes = Dictionary(uniqueKeysWithValues: tools.map {
            ($0["name"] as! String, $0["changes_files_or_versions"] as! Bool)
        })
        var checked = 0
        for subcommand in subcommands {
            let name = subcommand["commandName"] as! String
            guard let mutates = changes[name] else { continue }
            let options = Set((subcommand["arguments"] as? [[String: Any]] ?? []).flatMap { argument in
                (argument["names"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            })
            XCTAssertTrue(options.isSuperset(of: ["text", "quiet", "q", "help", "h"]), "\(name) lacks an output option")
            XCTAssertEqual(
                options.isSuperset(of: ["dry-run", "n", "timeout"]), mutates,
                "\(name): --dry-run and --timeout belong on exactly the tools that change something")
            checked += 1
        }
        XCTAssertEqual(checked, tools.count, "every documented tool must be a subcommand")
    }

    func testDryRunChangesNothing() {
        for tool in tools where tool["changes_files_or_versions"] as! Bool {
            let name = tool["name"] as! String
            _ = file("a.txt", history: ["one\n", "two\n"], current: "three\n")
            write("other.txt", "other\n")
            var arguments = invocation(name)!
            if !arguments.contains("--dry-run") { arguments.insert("--dry-run", at: 1) }
            let before = ids("a.txt")
            let outcome = mft(arguments)
            XCTAssertEqual(outcome.status, 0, "\(name): \(outcome.err)")
            XCTAssertEqual(outcome.record["dry_run"] as? Bool, true, name)
            XCTAssertEqual(ids("a.txt"), before, "\(name) --dry-run changed the versions")
            XCTAssertEqual(read("a.txt"), "three\n", "\(name) --dry-run changed the file")
            XCTAssertEqual(read("other.txt"), "other\n", "\(name) --dry-run changed the other file")
            for created in ["copy.txt", "clone.txt"] {
                XCTAssertEqual(read(created), "<missing>", "\(name) --dry-run created \(created)")
            }
            tearDown()
            try! setUpWithError()
        }
    }

    func testFailuresAreRecordsWithCodeMessageHintAndExitStatus() {
        let documented = Dictionary(uniqueKeysWithValues: (interface["errors"] as! [[String: Any]]).map {
            ($0["code"] as! String, $0["exit"] as! Int)
        })
        write("a.txt", "one\n")
        for (arguments, code) in [
            (["ver-ls", "missing.txt"], "no_such_file"),
            (["ver-cat", "-r", "latest", "a.txt"], "no_versions"),
            (["ver-restore", "-r", "latest", "a.txt"], "no_versions"),
            (["file-clone", "a.txt", "a.txt"], "already_exists"),
        ] {
            let outcome = mft(arguments)
            XCTAssertEqual(outcome.out, "", "a failure prints nothing on stdout")
            let failure = outcome.failures.first ?? [:]
            XCTAssertEqual(failure["ok"] as? Bool, false)
            XCTAssertEqual(failure["tool"] as? String, arguments[0])
            let error = failure["error"] as? [String: Any] ?? [:]
            XCTAssertEqual(error["code"] as? String, code)
            XCTAssertFalse((error["message"] as? String ?? "").isEmpty)
            XCTAssertFalse((error["hint"] as? String ?? "").isEmpty)
            XCTAssertEqual(Int(outcome.status), documented[code], "exit status for \(code)")
        }
    }

    func testOneBadOperandDoesNotStopTheRest() {
        write("a.txt", "one\n")
        write("b.txt", "two\n")
        let outcome = mft("ver-add", "a.txt", "missing.txt", "b.txt")
        XCTAssertEqual(outcome.records.count, 2)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.status, 66)
    }

    func testUsageErrorsExit64() {
        XCTAssertEqual(mft("ver-ls").status, 64)
        XCTAssertEqual(mft("ver-rm", "a.txt").status, 64)
        XCTAssertEqual(mft("ver-prune", "a.txt").status, 64)
        XCTAssertEqual(mft("ver-guard", "a.txt").status, 64)
        XCTAssertEqual(mft("ver-add", "--no-such-option", "a.txt").status, 64)
    }

    func testFileListsOnStandardInput() {
        write("a.txt", "one\n")
        write("b c.txt", "two\n")
        XCTAssertEqual(mft("ver-add", "-", stdin: "a.txt\nb c.txt\n").records.count, 2)
        XCTAssertEqual(mft("ver-ls", "-0", "-", stdin: "a.txt\0b c.txt\0").records.count, 2)
        XCTAssertEqual(mft("ver-ls", "-", stdin: "").status, 0)
    }

    func testTextAndQuietModes() {
        _ = file("a.txt", history: ["one\n"], current: "two\n")
        let text = mft("ver-ls", "--text", "a.txt").out
        XCTAssertTrue(text.hasPrefix("@1\t"))
        XCTAssertNil(try? JSONSerialization.jsonObject(with: Data(text.utf8)))
        XCTAssertEqual(mft("ver-add", "--quiet", "a.txt").out, "")
        let failure = mft("ver-ls", "--text", "missing.txt")
        XCTAssertTrue(failure.err.hasPrefix("ver-ls: "))
        XCTAssertEqual(failure.status, 66)
    }

    func testGuideMentionsEveryToolAndVersionMatches() {
        let guide = mft("guide").out
        for tool in tools { XCTAssertTrue(guide.contains(tool["name"] as! String)) }
        let version = mft("--version").out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(interface["version"] as? String, version)
        XCTAssertTrue(guide.contains("mft \(version)"))
    }
}

/// The plugins, the installer, the README and the release notes must agree with the program.
final class PackagingTests: SuiteTestCase {
    func text(_ path: String) -> String {
        (try? String(contentsOf: Self.repository.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }

    func json(_ path: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text(path).utf8))) as? [String: Any] ?? [:]
    }

    var version: String { mft("--version").out.trimmingCharacters(in: .whitespacesAndNewlines) }

    var toolNames: [String] {
        let data = Data(mft("describe").out.utf8)
        let interface = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (interface["tools"] as? [[String: Any]] ?? []).map { $0["name"] as! String }
    }

    func testVersionIsTheSameEverywhere() {
        XCTAssertEqual(json("plugins/claude-code/.claude-plugin/plugin.json")["version"] as? String, version)
        XCTAssertEqual(json("plugins/antigravity/plugin.json")["version"] as? String, version)
        XCTAssertTrue(text("plugins/iris/mft/plugin.md").contains("\nversion: \(version)\n"))
        XCTAssertTrue(text("plugins/shared/bin/mft-install").contains("MFT_VERSION:-\(version)}"))
        XCTAssertTrue(text("CHANGELOG.md").contains("\n## \(version)\n"))
        XCTAssertTrue(text("README.md").contains("releases/latest/download/install.sh"))
    }

    func testSharedPluginFilesAreInSync() throws {
        let process = Process()
        process.executableURL = Self.repository.appendingPathComponent("scripts/sync-plugins.sh")
        process.arguments = ["--check"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let complaints = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, complaints)
    }

    func testThereIsALauncherForEveryTool() throws {
        let bin = Self.repository.appendingPathComponent("plugins/shared/bin")
        let present = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        XCTAssertEqual(Set(present), Set(toolNames + ["mft", "mft-install"]))
        for plugin in ["shared", "claude-code", "antigravity"] {
            for name in present {
                let path = Self.repository.appendingPathComponent("plugins/\(plugin)/bin/\(name)").path
                XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "\(plugin)/bin/\(name)")
            }
        }
    }

    func testClaudeCodePluginFiles() {
        let plugin = json("plugins/claude-code/.claude-plugin/plugin.json")
        let listed = (json(".claude-plugin/marketplace.json")["plugins"] as? [[String: Any]])?.first
        XCTAssertEqual(listed?["name"] as? String, plugin["name"] as? String)
        XCTAssertEqual(listed?["source"] as? String, "./plugins/claude-code")
        let hooks = json("plugins/claude-code/hooks/hooks.json")["hooks"] as? [String: Any]
        let group = (hooks?["PreToolUse"] as? [[String: Any]])?.first
        XCTAssertEqual(group?["matcher"] as? String, "Edit|Write|MultiEdit|NotebookEdit")
    }

    func testAntigravityPluginFiles() {
        XCTAssertEqual(json("plugins/antigravity/plugin.json")["name"] as? String, "mft")
        // Named group, then event, then an array of matcher groups.
        let group = json("plugins/antigravity/hooks.json")["mft-checkpoint"] as? [String: Any]
        let entry = (group?["PreToolUse"] as? [[String: Any]])?.first
        XCTAssertEqual(entry?["matcher"] as? String, "write_to_file|replace_file_content|multi_replace_file_content")
        let command = ((entry?["hooks"] as? [[String: Any]])?.first)?["command"] as? String ?? ""
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: Self.repository.appendingPathComponent("plugins/antigravity").appendingPathComponent(command).path),
            "the hook command must exist inside the plugin: \(command)")
    }

    func testIrisPluginFiles() {
        let manifest = text("plugins/iris/mft/plugin.md")
        XCTAssertTrue(manifest.hasPrefix("---\nipf: \"1.0\"\nid: mft\n"), "the id must equal the folder name")
        XCTAssertTrue(manifest.contains("\n    - name: mft\n"))
        let hooks = json("plugins/iris/mft/settings-hooks.json")["hooks"] as? [String: Any]
        XCTAssertEqual(((hooks?["BeforeTool"] as? [[String: Any]])?.first)?["matcher"] as? String, "^write_file$")
        // Iris has no bin folder to offer and drops hidden files, so the plugin ships neither.
        let files = FileManager.default.enumerator(atPath: Self.repository.appendingPathComponent("plugins/iris/mft").path)?
            .allObjects as? [String] ?? []
        XCTAssertFalse(files.contains { $0.hasPrefix("bin") || $0.split(separator: "/").last!.hasPrefix(".") })
    }

    func testSkillMeetsEveryAgentsRules() {
        let skill = text("plugins/shared/SKILL.md")
        let lines = skill.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines[0], "---")
        // The name must equal the skill's folder name; the description must sit on one line.
        XCTAssertEqual(lines[1], "name: macos-file-versions")
        XCTAssertTrue(lines[2].hasPrefix("description: "))
        XCTAssertEqual(lines[3], "---")
        XCTAssertLessThanOrEqual(lines[2].count - "description: ".count, 1024)

        let known = Set(mft("guide").out.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init))
        let mentioned = Set(skill.split(whereSeparator: { !$0.isLetter && $0 != "-" }).map(String.init)
            .filter { $0.hasPrefix("ver-") || $0.hasPrefix("file-") })
        XCTAssertTrue(mentioned.isSubset(of: known), "unknown tools in SKILL.md: \(mentioned.subtracting(known))")
    }

    func testReadmeCoversEveryToolAndOption() throws {
        let readme = text("README.md")
        let data = Data(mft("--experimental-dump-help").out.utf8)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let subcommands = (root["command"] as? [String: Any])?["subcommands"] as? [[String: Any]] ?? []
        for subcommand in subcommands {
            let name = subcommand["commandName"] as! String
            if name == "help" { continue }
            let heading = toolNames.contains(name) ? "### `\(name)`" : "### `mft \(name)`"
            guard let start = readme.range(of: heading + "\n") else {
                XCTFail("README.md has no section headed \(heading)")
                continue
            }
            let rest = readme[start.upperBound...]
            let section = rest[..<(rest.range(of: "\n### ")?.lowerBound ?? rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)]
            for argument in subcommand["arguments"] as? [[String: Any]] ?? [] {
                for option in argument["names"] as? [[String: Any]] ?? [] where option["kind"] as? String == "long" {
                    let flag = "--" + (option["name"] as! String)
                    if ["--help", "--version", "--text", "--quiet", "--dry-run", "--timeout", "--null"].contains(flag) { continue }
                    XCTAssertTrue(section.contains(flag), "README.md section for \(name) does not mention \(flag)")
                }
            }
        }
    }

    func launcher(_ path: String, _ arguments: [String], environment: [String: String], stdin: String = "",
                  directory: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = Self.repository.appendingPathComponent(path)
        process.arguments = arguments
        process.environment = environment.merging(["PATH": "/usr/bin:/bin"]) { a, _ in a }
        if let directory { process.currentDirectoryURL = Self.repository.appendingPathComponent(directory) }
        let (output, input) = (Pipe(), Pipe())
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        try! process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        input.fileHandleForWriting.closeFile()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    func testPluginLaunchersRunTheInstalledProgram() {
        write("a.txt", "one\n")
        let environment = ["MFT_BIN": Self.binary.path, "HOME": scratch.path, "MFT_HOME": scratch.path]
        let (status, output) = launcher(
            "plugins/claude-code/bin/ver-status", ["--text", scratch.appendingPathComponent("a.txt").path],
            environment: environment)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(output.hasPrefix("0 version(s)\tfile"))
        XCTAssertEqual(launcher("plugins/antigravity/bin/mft", ["--version"], environment: environment).1, version + "\n")
    }

    func testPluginLaunchersSayWhenTheProgramIsMissing() throws {
        for systemWide in ["/usr/local/bin/mft", "/opt/homebrew/bin/mft"]
        where FileManager.default.fileExists(atPath: systemWide) {
            throw XCTSkip("mft is installed system-wide at \(systemWide)")
        }
        let nowhere = ["HOME": scratch.path]
        let (status, output) = launcher("plugins/claude-code/bin/ver-ls", ["a.txt"], environment: nowhere)
        XCTAssertEqual(status, 69)
        XCTAssertTrue(output.contains("\"code\":\"not_installed\""))
        // The hook must stay out of the way even then.
        let hook = launcher("plugins/claude-code/bin/mft", ["hook"], environment: nowhere, stdin: "{}")
        XCTAssertEqual(hook.0, 0)
        XCTAssertEqual(hook.1, "")
    }

    func testAntigravityHookStoresAVersionAndAlwaysAnswersAllow() throws {
        write("a.txt", "one\n")
        let event = """
            {"toolCall":{"name":"replace_file_content","args":{"TargetFile":"\(scratch.path)/a.txt"}},
             "conversationId":"ec33ebf9-0cba","workspacePaths":["\(scratch.path)"]}
            """
        let home = scratch.appendingPathComponent(".mft-home").path
        let installed = launcher(
            "plugins/antigravity/scripts/pre-edit-hook.sh", [],
            environment: ["MFT_BIN": Self.binary.path, "HOME": scratch.path, "MFT_HOME": home],
            stdin: event, directory: "plugins/antigravity")
        XCTAssertEqual(installed.0, 0)
        XCTAssertEqual(installed.1, "{\"decision\":\"allow\"}\n")
        let stored = versions("a.txt")
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0]["by"] as? String, "antigravity")
        XCTAssertEqual(stored[0]["note"] as? String, "before replace_file_content (session ec33ebf9)")

        for systemWide in ["/usr/local/bin/mft", "/opt/homebrew/bin/mft"]
        where FileManager.default.fileExists(atPath: systemWide) { return }
        let missing = launcher(
            "plugins/antigravity/scripts/pre-edit-hook.sh", [], environment: ["HOME": scratch.path],
            stdin: event, directory: "plugins/antigravity")
        XCTAssertEqual(missing.0, 0)
        XCTAssertEqual(missing.1, "{\"decision\":\"allow\"}\n")
    }

    func testHookReadsEachAgentsEventShape() {
        write("iris.txt", "one\n")
        write("reply.txt", "one\n")
        // Iris passes the bare arguments, with a path that may be relative.
        XCTAssertEqual(mft("hook", "--by", "iris", stdin: "{\"path\":\"iris.txt\",\"content\":\"x\"}").out, "")
        XCTAssertEqual(versions("iris.txt").first?["by"] as? String, "iris")
        // --reply is printed whether or not there was anything to store.
        let reply = "{\"decision\":\"allow\"}"
        XCTAssertEqual(mft("hook", "--reply", reply, stdin: "{\"path\":\"reply.txt\"}").out, reply + "\n")
        XCTAssertEqual(mft("hook", "--reply", reply, stdin: "nonsense").out, reply + "\n")
        XCTAssertEqual(versions("reply.txt").count, 1)
    }
}
