import ArgumentParser
import Foundation
import MFTCore

/// The tools, in the order help and documentation list them.
let toolCommands: [ParsableCommand.Type] = [
    VerLs.self, VerAdd.self, VerCat.self, VerDiff.self, VerRestore.self, VerUndo.self,
    VerRm.self, VerPrune.self, VerStatus.self, VerCp.self, VerGuard.self,
    FileTrash.self, FileClone.self, FileSwap.self,
]

var toolNames: [String] {
    toolCommands.compactMap { $0.configuration.commandName }
}

struct Mft: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mft",
        abstract: "Small macOS file tools with one interface.",
        discussion: """
            Each tool is a subcommand here and, once linked, a command of its own:
            'mft ver-ls FILE' and 'ver-ls FILE' are the same. Start with 'mft guide'.
            """,
        version: mftVersion,
        subcommands: toolCommands + [Guide.self, Describe.self, Selftest.self, Link.self, Hook.self])
}

// Multi-call entry point: a symlink named after a tool runs that tool.
@main
enum Entry {
    static func main() {
        var arguments = CommandLine.arguments
        let invokedAs = URL(fileURLWithPath: arguments.removeFirst()).lastPathComponent
        if toolNames.contains(invokedAs) { arguments.insert(invokedAs, at: 0) }
        Mft.main(arguments)
    }
}
