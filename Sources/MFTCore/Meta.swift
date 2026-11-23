import Foundation

/// What the tools remember about a version that the system store has no field
/// for: why it was made, by whom, and an optional tag.
///
/// Kept as one small JSON file per version id under
/// ~/Library/Application Support/mft/meta (or $MFT_HOME/meta). It is keyed by
/// version id, not by path, so it survives the file being renamed or moved.
/// Like the versions themselves, it is local to this user on this Mac.
public struct Meta: Codable {
    public var note: String?
    public var tag: String?
    public var by: String?
    public var auto: Bool
    public var added: String?

    public init(note: String? = nil, tag: String? = nil, by: String? = nil, auto: Bool = false) {
        self.note = note
        self.tag = tag
        self.by = by ?? ProcessInfo.processInfo.environment["MFT_ACTOR"]
        self.auto = auto
    }

    static var directory: URL {
        let home = ProcessInfo.processInfo.environment["MFT_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("mft")
        return home.appendingPathComponent("meta")
    }

    static func file(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    public static func read(_ id: String) -> Meta {
        guard let data = try? Data(contentsOf: file(id)),
              let meta = try? JSONDecoder().decode(Meta.self, from: data)
        else { return Meta(by: nil).cleared() }
        return meta
    }

    /// Losing a note must never fail the operation it describes, so writes are best-effort.
    public static func write(_ id: String, _ meta: Meta) {
        var meta = meta
        if meta.added == nil { meta.added = iso8601(Date()) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: file(id), options: .atomic)
        }
    }

    public static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// A version nobody described: no note, no tag, no author.
    func cleared() -> Meta {
        var copy = self
        copy.by = nil
        return copy
    }
}
