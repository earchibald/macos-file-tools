import Foundation

/// One stored version of a file.
public struct Version {
    public let index: Int          // 1 is the newest; shifts when versions are added
    public let id: String          // stable for as long as the version exists
    public let date: Date          // modification date of the saved contents
    public let raw: NSFileVersion

    /// The record every tool prints for a version.
    public var fields: [String: Any] {
        let size = (try? raw.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return [
            "id": id,
            "index": index,
            "date": iso8601(date),
            "size": size,
            "discardable": raw.isDiscardable,
            // A read-only file holding this version's contents. Any program
            // can read it directly; nothing should write to it.
            "contents_path": raw.url.path,
        ]
    }
}

/// The only place that talks to NSFileVersion.
public enum Versions {
    /// Stored versions of `url`, newest first. Never includes the current contents.
    public static func list(_ url: URL) -> [Version] {
        let stored = NSFileVersion.otherVersionsOfItem(at: url) ?? []
        return stored.enumerated()
            .sorted { a, b in
                let (da, db) = (a.element.modificationDate ?? .distantPast,
                                b.element.modificationDate ?? .distantPast)
                return da == db ? a.offset > b.offset : da > db
            }
            .enumerated()
            .map { position, item in
                Version(
                    index: position + 1,
                    // The store names each version file with a UUID, which
                    // serves as the id. Observed behaviour, not documented.
                    id: item.element.url.deletingPathExtension().lastPathComponent.lowercased(),
                    date: item.element.modificationDate ?? .distantPast,
                    raw: item.element)
            }
    }

    /// Finds the version a selector names: an id or unique prefix, latest, oldest, or @N.
    public static func resolve(_ selector: String, for url: URL) throws -> Version {
        let all = list(url)
        guard !all.isEmpty else { throw ToolError(.noVersions, "file has no stored versions") }
        switch selector.lowercased() {
        case "latest": return all.first!
        case "oldest": return all.last!
        case let s where s.hasPrefix("@"):
            guard let n = Int(s.dropFirst()), all.indices.contains(n - 1) else {
                throw ToolError(.noSuchVersion, "no version \(selector); have @1 to @\(all.count)")
            }
            return all[n - 1]
        case let s:
            let matches = all.filter { $0.id.hasPrefix(s) }
            if matches.isEmpty { throw ToolError(.noSuchVersion, "no version with id \(selector)") }
            if matches.count > 1 { throw ToolError(.ambiguousVersion, "id prefix \(selector) matches \(matches.count) versions") }
            return matches[0]
        }
    }

    /// Stores the contents of `source` (default: the file itself) as a new version.
    /// On APFS this is a clone: no data is copied.
    @discardableResult
    public static func add(to url: URL, from source: URL? = nil) throws -> Version {
        do {
            var added: NSFileVersion!
            try coordinated(url) {
                added = try NSFileVersion.addOfItem(at: $0, withContentsOf: source ?? $0, options: [])
            }
            return list(url).first { $0.raw.url == added.url }!
        } catch {
            // Seen on ExFAT and HFS+ disk images: Cocoa error 512 with no detail.
            throw ToolError(.versionsUnsupported, "cannot store a version here: \(error.localizedDescription)")
        }
    }

    /// Overwrites the file with a stored version. Keeps nothing: call `add` first
    /// if the current contents matter.
    public static func restore(_ version: Version, to url: URL) throws {
        try coordinated(url) { _ = try version.raw.replaceItem(at: $0, options: []) }
    }

    /// Deletes stored versions. The file itself is not touched.
    public static func remove(_ versions: [Version], of url: URL) throws {
        try coordinated(url) { _ in
            for version in versions { try version.raw.remove() }
        }
    }

    /// Runs `body` inside a coordinated write, so apps that have the file open
    /// are told it changed instead of discovering it later.
    static func coordinated(_ url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: [], error: &coordinationError
        ) { actualURL in
            do { try body(actualURL) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }
}
