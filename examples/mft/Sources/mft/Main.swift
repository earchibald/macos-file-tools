import ArgumentParser
import Foundation

struct Mft: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mft",
        abstract: "Small macOS file tools with one shared interface.",
        version: "0.1.0",
        subcommands: [VerLs.self, VerAdd.self, VerCat.self, VerRestore.self, VerRm.self, FileTrash.self])
}

// Multi-call entry point: `mft ver-ls FILE` and a symlink named `ver-ls`
// pointing at this binary run the same code.
@main
enum Entry {
    static func main() {
        var arguments = CommandLine.arguments
        let invokedAs = URL(fileURLWithPath: arguments.removeFirst()).lastPathComponent
        if invokedAs != "mft" { arguments.insert(invokedAs, at: 0) }
        Mft.main(arguments)
    }
}
