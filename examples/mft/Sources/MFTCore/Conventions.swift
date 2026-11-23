import ArgumentParser
import Foundation

// MARK: Shared option groups
// Every tool includes these with @OptionGroup, so a flag is spelled once and
// means the same thing everywhere.

/// Options every tool accepts.
public struct OutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Print tab-separated text for people instead of JSON lines.")
    public var text = false

    @Flag(name: .shortAndLong, help: "Print nothing on success.")
    public var quiet = false

    public init() {}
}

/// Options every tool that changes something accepts.
public struct MutationOptions: ParsableArguments {
    @Flag(name: [.customShort("n"), .long], help: "Report what would change, and change nothing.")
    public var dryRun = false

    public init() {}
}

/// How a tool is told which version to act on.
public struct RevOption: ParsableArguments {
    @Option(
        name: [.customShort("r"), .long],
        help: ArgumentHelp(
            "Version to act on: an id (or unique prefix), latest, oldest, or @N (1 is newest).",
            valueName: "selector"))
    public var rev: String

    public init() {}
}

// MARK: Failures
// Each failure has a stable string code for programs to match on and an exit
// status from sysexits.h. Usage errors exit 64, which is ArgumentParser's own.

public struct ToolError: Error {
    public enum Code: String {
        case noSuchFile = "no_such_file"                   // operand does not exist
        case noVersions = "no_versions"                    // file has no stored versions
        case noSuchVersion = "no_such_version"             // selector matched nothing
        case ambiguousVersion = "ambiguous_version"        // id prefix matched several
        case versionsUnsupported = "versions_unsupported"  // volume cannot store versions
        case ioError = "io_error"                          // anything else from the file system

        public var exit: ExitCode {
            switch self {
            case .noSuchFile: return ExitCode(66)                                   // EX_NOINPUT
            case .noVersions, .noSuchVersion, .ambiguousVersion: return ExitCode(65) // EX_DATAERR
            case .versionsUnsupported: return ExitCode(69)                          // EX_UNAVAILABLE
            case .ioError: return ExitCode(74)                                      // EX_IOERR
            }
        }
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: Output
// One record per operand. Successes go to stdout, failures to stderr, both as
// JSON lines unless --text is given. Nothing depends on whether a terminal is
// attached, and no tool ever prompts.

public struct Emitter {
    public let tool: String
    public let options: OutputOptions

    public init(tool: String, options: OutputOptions) {
        self.tool = tool
        self.options = options
    }

    /// The record for one operand that succeeded.
    public func result(_ fields: [String: Any], text: @autoclosure () -> String) {
        if options.quiet { return }
        if options.text {
            let line = text()
            if !line.isEmpty { print(line) }
        } else {
            print(Self.jsonLine(fields.merging(["ok": true, "tool": tool]) { a, _ in a }))
        }
        // Flush per record so stdout and stderr interleave in order when a
        // caller captures both into one stream.
        fflush(stdout)
    }

    /// The record for one operand that failed.
    public func failure(_ path: String, _ error: ToolError) {
        let line = options.text
            ? "\(tool): \(path): \(error.message)"
            : Self.jsonLine([
                "ok": false, "tool": tool, "path": path,
                "error": ["code": error.code.rawValue, "message": error.message],
            ])
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Runs `body` once per operand and keeps going after a failure. Exits with
    /// the failure's status, or 1 when operands failed for different reasons.
    public func forEach(_ paths: [String], _ body: (URL) throws -> Void) throws {
        var statuses = Set<Int32>()
        for path in paths {
            // Records always carry absolute paths, whatever the caller typed.
            let url = URL(fileURLWithPath: path).standardizedFileURL
            do {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolError(.noSuchFile, "no such file or directory")
                }
                try body(url)
            } catch let error as ToolError {
                failure(url.path, error)
                statuses.insert(error.code.exit.rawValue)
            } catch {
                let wrapped = ToolError(.ioError, error.localizedDescription)
                failure(url.path, wrapped)
                statuses.insert(wrapped.code.exit.rawValue)
            }
        }
        if statuses.count == 1 { throw ExitCode(statuses.first!) }
        if statuses.count > 1 { throw ExitCode(1) }
    }

    static func jsonLine(_ record: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

public func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
