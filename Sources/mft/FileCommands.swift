import ArgumentParser
import Foundation
import MFTCore

// Single-file operations that follow the same contract as the ver-* tools.

struct FileTrash: ParsableCommand {
    static let configuration = Catalog.doc("file-trash").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @OptionGroup var operands: FileOperands

    func run() throws {
        let emit = Emitter(tool: "file-trash", output: output, mutation: mutation)
        try emit.forEach(operands.paths) { url in
            if mutation.dryRun {
                emit.result(
                    ["path": url.path, "trashed_to": NSNull(), "dry_run": true],
                    text: "would trash\t\(url.path)")
                return
            }
            var destination: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
            let landed = destination?.path ?? ""
            emit.result(
                ["path": url.path, "trashed_to": landed, "dry_run": false],
                text: "trashed\t\(url.path)\t\(landed)")
        }
    }
}

struct FileClone: ParsableCommand {
    static let configuration = Catalog.doc("file-clone").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Flag(help: "Where the volume cannot clone, make a full copy instead of failing.") var allowCopy = false
    @Argument(help: "File to clone.") var source: String
    @Argument(help: "Where to put the clone. Must not exist.") var destination: String

    func run() throws {
        let emit = Emitter(tool: "file-clone", output: output, mutation: mutation)
        try emit.forEach([source]) { url in
            let target = URL(fileURLWithPath: destination).standardizedFileURL
            if FileManager.default.fileExists(atPath: target.path) {
                throw ToolError(.alreadyExists, "\(target.path) already exists")
            }
            if mutation.dryRun {
                emit.result(
                    ["path": url.path, "destination": target.path, "cloned": NSNull(), "dry_run": true],
                    text: "would clone\t\(url.path)\t\(target.path)")
                return
            }
            var cloned = true
            if clonefile(url.path, target.path, 0) != 0 {
                let reason = errno
                switch reason {
                case EEXIST:
                    throw ToolError(.alreadyExists, "\(target.path) already exists")
                case ENOTSUP, EXDEV:
                    // cp -c falls back to a full copy without saying so. Here
                    // the caller has to ask for that, and is told it happened.
                    guard allowCopy else {
                        throw ToolError(
                            .unsupportedOperation, "this volume cannot clone, or the two paths are on different volumes",
                            hint: "Pass --allow-copy to make a full copy instead.")
                    }
                    try FileManager.default.copyItem(at: url, to: target)
                    cloned = false
                default:
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(reason))
                }
            }
            emit.result(
                ["path": url.path, "destination": target.path, "cloned": cloned, "dry_run": false],
                text: "\(cloned ? "cloned" : "copied")\t\(url.path)\t\(target.path)")
        }
    }
}

struct FileSwap: ParsableCommand {
    static let configuration = Catalog.doc("file-swap").configuration

    @OptionGroup var output: OutputOptions
    @OptionGroup var mutation: MutationOptions
    @Argument(help: "First file.") var first: String
    @Argument(help: "Second file.") var second: String

    func run() throws {
        let emit = Emitter(tool: "file-swap", output: output, mutation: mutation)
        try emit.forEach([first]) { url in
            let other = URL(fileURLWithPath: second).standardizedFileURL
            guard FileManager.default.fileExists(atPath: other.path) else {
                throw ToolError(.noSuchFile, "\(other.path): no such file or directory")
            }
            if mutation.dryRun {
                emit.result(
                    ["path": url.path, "other": other.path, "dry_run": true],
                    text: "would swap\t\(url.path)\t\(other.path)")
                return
            }
            if renamex_np(url.path, other.path, UInt32(RENAME_SWAP)) != 0 {
                let reason = errno
                if reason == ENOTSUP || reason == EXDEV {
                    throw ToolError(
                        .unsupportedOperation, "these two paths cannot be swapped atomically",
                        hint: "Both files must be on the same volume, and the volume must support swapping (APFS does).")
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(reason))
            }
            emit.result(
                ["path": url.path, "other": other.path, "dry_run": false],
                text: "swapped\t\(url.path)\t\(other.path)")
        }
    }
}
