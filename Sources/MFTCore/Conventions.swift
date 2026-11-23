import ArgumentParser
import Foundation

public let mftVersion = "0.0.1"

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

    @Option(
        name: .long,
        help: ArgumentHelp("Give up if another program holds the file for this long.", valueName: "seconds"))
    public var timeout: Double = 10

    public init() {}
}

/// How a tool is told which version to act on.
public struct RevOption: ParsableArguments {
    @Option(
        name: [.customShort("r"), .long],
        help: ArgumentHelp(
            "Version to act on: an id or unique prefix, latest, oldest, @N (1 is newest), tag:NAME, or before:WHEN.",
            valueName: "selector"))
    public var rev: String

    public init() {}
}

/// File operands for tools that act on each file independently.
public struct FileOperands: ParsableArguments {
    @Argument(help: "Files to act on. A lone '-' reads the list from standard input, one path per line.")
    public var files: [String] = []

    @Flag(name: [.customShort("0"), .long], help: "With '-', paths on standard input end in NUL instead of newline.")
    public var null = false

    public init() {}

    public func validate() throws {
        if files.isEmpty {
            throw ValidationError("Give at least one FILE, or '-' to read the list from standard input.")
        }
    }

    /// The operands, with a lone '-' replaced by the paths read from standard input.
    public var paths: [String] {
        guard files == ["-"] else { return files }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        return input.split(separator: null ? "\0" : "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

// MARK: Failures
// Each failure has a stable string code for programs to match on, an exit
// status from sysexits.h, and a hint naming what to try next. Usage errors
// exit 64, which is ArgumentParser's own status.

public struct ToolError: Error {
    public enum Code: String, CaseIterable {
        case noSuchFile = "no_such_file"
        case noVersions = "no_versions"
        case noSuchVersion = "no_such_version"
        case ambiguousVersion = "ambiguous_version"
        case versionsUnsupported = "versions_unsupported"
        case unsupportedOperation = "unsupported_operation"
        case alreadyExists = "already_exists"
        case preconditionFailed = "precondition_failed"
        case busy = "busy"
        case permissionDenied = "permission_denied"
        case ioError = "io_error"

        public var exit: Int32 {
            switch self {
            case .noVersions, .noSuchVersion, .ambiguousVersion: return 65  // EX_DATAERR
            case .noSuchFile: return 66                                     // EX_NOINPUT
            case .versionsUnsupported, .unsupportedOperation: return 69     // EX_UNAVAILABLE
            case .alreadyExists: return 73                                  // EX_CANTCREAT
            case .ioError: return 74                                        // EX_IOERR
            case .preconditionFailed, .busy: return 75                      // EX_TEMPFAIL
            case .permissionDenied: return 77                               // EX_NOPERM
            }
        }

        public var meaning: String {
            switch self {
            case .noSuchFile: return "The operand does not exist."
            case .noVersions: return "The file has no stored versions."
            case .noSuchVersion: return "The selector matched no version."
            case .ambiguousVersion: return "The id prefix matched more than one version."
            case .versionsUnsupported: return "This volume cannot store versions."
            case .unsupportedOperation: return "This volume or kind of item does not support the operation."
            case .alreadyExists: return "The destination already exists."
            case .preconditionFailed: return "The file's versions changed since the caller last looked."
            case .busy: return "Another program held the file for longer than --timeout."
            case .permissionDenied: return "macOS refused access to the file."
            case .ioError: return "Any other file-system failure."
            }
        }

        public var hint: String {
            switch self {
            case .noSuchFile: return "Check the path. Relative paths are resolved against the current folder."
            case .noVersions: return "Store one with ver-add, then try again."
            case .noSuchVersion, .ambiguousVersion: return "Run ver-ls on the file and pass a full id with --rev."
            case .versionsUnsupported:
                return "Versions need an APFS volume. Run ver-status --probe to check a location."
            case .unsupportedOperation: return "Run ver-status on the file to see what its volume supports."
            case .alreadyExists: return "Choose another destination, or remove the existing item first."
            case .preconditionFailed: return "Run ver-ls again and retry with the current latest id."
            case .busy: return "Retry, or raise --timeout. An app may have the file open."
            case .permissionDenied:
                return "Grant the calling app access under System Settings > Privacy & Security > Files and Folders."
            case .ioError: return "Read the message. Running the tool again is safe."
            }
        }
    }

    public let code: Code
    public let message: String
    public let hint: String

    public init(_ code: Code, _ message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint ?? code.hint
    }

    /// Turns any error into one with a stable code.
    public static func wrap(_ error: Error) -> ToolError {
        if let error = error as? ToolError { return error }
        let ns = error as NSError
        let denied =
            (ns.domain == NSCocoaErrorDomain && [257, 513].contains(ns.code))
            || (ns.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(ns.code))
        return ToolError(denied ? .permissionDenied : .ioError, error.localizedDescription)
    }
}

// MARK: Output
// One record per operand. Successes go to stdout, failures to stderr, both as
// JSON lines unless --text is given. Nothing depends on whether a terminal is
// attached, and no tool ever prompts.

public struct Emitter {
    public let tool: String
    public let text: Bool
    public let quiet: Bool

    public init(tool: String, output: OutputOptions, mutation: MutationOptions? = nil) {
        self.tool = tool
        self.text = output.text
        self.quiet = output.quiet
        if let mutation { Versions.timeout = mutation.timeout }
    }

    /// The record for one operand that succeeded.
    public func result(_ fields: [String: Any], text line: @autoclosure () -> String) {
        if quiet { return }
        if text {
            let line = line()
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
        let line = text
            ? "\(tool): \(path): \(error.message)"
            : Self.jsonLine([
                "ok": false, "tool": tool, "path": path,
                "error": ["code": error.code.rawValue, "message": error.message, "hint": error.hint],
            ])
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// Runs `body` once per operand and keeps going after a failure. Exits with
    /// the failure's status, or 1 when operands failed for different reasons.
    public func forEach(_ paths: [String], _ body: (URL) throws -> Void) throws {
        var statuses = Set<Int32>()
        for path in paths {
            // Records always carry absolute paths, whatever the caller typed.
            var url = absoluteURL(path)
            do {
                // A symlink operand means the file it points to.
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    url = url.resolvingSymlinksInPath()
                }
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolError(.noSuchFile, "no such file or directory")
                }
                try body(url)
            } catch {
                let wrapped = ToolError.wrap(error)
                failure(url.path, wrapped)
                statuses.insert(wrapped.code.exit)
            }
        }
        if statuses.count == 1 { throw ExitCode(statuses.first!) }
        if statuses.count > 1 { throw ExitCode(1) }
    }

    public static func jsonLine(_ record: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: Small helpers

/// The absolute form of a path that every record uses. macOS shortens
/// /private/var to /var only for paths that exist, so a path that does not
/// exist yet is built from its folder, which does.
public func absoluteURL(_ path: String) -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    if FileManager.default.fileExists(atPath: url.path) { return url }
    return url.deletingLastPathComponent().standardizedFileURL.appendingPathComponent(url.lastPathComponent)
}

public func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// JSON has no "absent": a missing value is written as null so every record
/// of a kind has the same keys.
public func orNull(_ value: Any?) -> Any {
    value ?? NSNull()
}

/// "90s", "15m", "2h", "3d" or "1w" as seconds.
public func parseDuration(_ text: String) -> TimeInterval? {
    guard let unit = text.last, let count = Double(text.dropLast()), count >= 0 else { return nil }
    switch unit {
    case "s": return count
    case "m": return count * 60
    case "h": return count * 3600
    case "d": return count * 86400
    case "w": return count * 604800
    default: return nil
    }
}

/// A point in time: a duration back from now ("15m"), or an ISO 8601 date or date-time.
public func parseWhen(_ text: String) -> Date? {
    if let seconds = parseDuration(text) { return Date().addingTimeInterval(-seconds) }
    for options: ISO8601DateFormatter.Options in [
        [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate],
    ] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        if let date = formatter.date(from: text) { return date }
    }
    return nil
}
