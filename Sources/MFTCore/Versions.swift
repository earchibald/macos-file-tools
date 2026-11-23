import Foundation

/// One stored version of a file.
public struct Version {
    public let index: Int          // 1 is the newest; shifts when versions are added
    public let id: String          // stable for as long as the version exists
    public let date: Date          // modification date of the saved contents
    public let meta: Meta
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
            "note": orNull(meta.note),
            "tag": orNull(meta.tag),
            "by": orNull(meta.by),
        ]
    }

    /// The same facts as one tab-separated line.
    public func line(_ path: String) -> String {
        "@\(index)\t\(id)\t\(iso8601(date))\t\(meta.tag ?? "-")\t\(meta.note ?? "-")\t\(path)"
    }
}

/// The only place that talks to NSFileVersion.
public enum Versions {
    /// How long a change waits for other programs to let go of the file.
    public static var timeout: TimeInterval = 10

    static func id(of version: NSFileVersion) -> String {
        // The store names each version file with a UUID, which serves as the
        // id. Observed behaviour, not documented.
        version.url.deletingPathExtension().lastPathComponent.lowercased()
    }

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
                let id = id(of: item.element)
                return Version(
                    index: position + 1, id: id,
                    date: item.element.modificationDate ?? .distantPast,
                    meta: Meta.read(id), raw: item.element)
            }
    }

    /// Finds the version a selector names.
    public static func resolve(_ selector: String, for url: URL) throws -> Version {
        let all = list(url)
        guard !all.isEmpty else { throw ToolError(.noVersions, "file has no stored versions") }
        let lowered = selector.lowercased()
        switch lowered {
        case "latest": return all.first!
        case "oldest": return all.last!
        case _ where lowered.hasPrefix("@"):
            guard let n = Int(lowered.dropFirst()), all.indices.contains(n - 1) else {
                throw ToolError(.noSuchVersion, "no version \(selector); have @1 to @\(all.count)")
            }
            return all[n - 1]
        case _ where lowered.hasPrefix("tag:"):
            let tag = String(selector.dropFirst(4))
            guard let match = all.first(where: { $0.meta.tag == tag }) else {
                throw ToolError(.noSuchVersion, "no version tagged \(tag)")
            }
            return match
        case _ where lowered.hasPrefix("before:"):
            let when = String(selector.dropFirst(7))
            guard let cutoff = parseWhen(when) else {
                throw ToolError(
                    .noSuchVersion, "cannot read \(when) as a time",
                    hint: "Use a duration such as 15m, 2h or 3d, or an ISO 8601 date-time.")
            }
            guard let match = all.first(where: { $0.date <= cutoff }) else {
                throw ToolError(.noSuchVersion, "no version from before \(iso8601(cutoff))")
            }
            return match
        default:
            let matches = all.filter { $0.id.hasPrefix(lowered) }
            if matches.isEmpty { throw ToolError(.noSuchVersion, "no version with id \(selector)") }
            if matches.count > 1 {
                throw ToolError(.ambiguousVersion, "id prefix \(selector) matches \(matches.count) versions")
            }
            return matches[0]
        }
    }

    /// Fails unless the newest version is the one the caller expects.
    public static func expectLatest(_ expected: String?, for url: URL) throws {
        guard let expected else { return }
        let latest = list(url).first?.id
        if expected.lowercased() == "none" ? latest != nil : latest?.hasPrefix(expected.lowercased()) != true {
            throw ToolError(.preconditionFailed, "latest version is \(latest ?? "none"), not \(expected)")
        }
    }

    /// True when two files hold the same bytes (or two folders the same tree).
    public static func sameContents(_ a: URL, _ b: URL) -> Bool {
        FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
    }

    /// Stores the file's current contents as a new version, unless the newest
    /// version already holds exactly those contents. Returns the version that
    /// holds them either way. On APFS a new version is a clone: no data is copied.
    public static func add(
        to url: URL, from source: URL? = nil, meta: Meta = Meta(), force: Bool = false
    ) throws -> (version: Version, created: Bool) {
        if !force, source == nil, let latest = list(url).first,
           sameContents(latest.raw.url, url),
           // A disposable version cannot be made permanent, so a deliberate
           // checkpoint never reuses one.
           meta.auto || !latest.raw.isDiscardable,
           meta.tag == nil || latest.meta.tag == nil || latest.meta.tag == meta.tag
        {
            if meta.tag != nil, latest.meta.tag == nil {
                var updated = latest.meta
                updated.tag = meta.tag
                updated.note = updated.note ?? meta.note
                updated.by = updated.by ?? meta.by
                Meta.write(latest.id, updated)
                return (list(url).first { $0.id == latest.id } ?? latest, false)
            }
            return (latest, false)
        }

        var added: NSFileVersion?
        do {
            try coordinated(url) { actual in
                let version = try NSFileVersion.addOfItem(at: actual, withContentsOf: source ?? actual, options: [])
                // Disposable versions may be reclaimed by macOS when space runs low.
                if meta.auto { version.isDiscardable = true }
                added = version
            }
        } catch let error as ToolError {
            throw error
        } catch {
            let wrapped = ToolError.wrap(error)
            if wrapped.code == .permissionDenied { throw wrapped }
            // Seen on ExFAT and HFS+ disk images: Cocoa error 512 with no detail.
            throw ToolError(.versionsUnsupported, "cannot store a version here: \(error.localizedDescription)")
        }
        let id = id(of: added!)
        Meta.write(id, meta)
        guard let version = list(url).first(where: { $0.id == id }) else {
            throw ToolError(.ioError, "version \(id) was stored but cannot be read back")
        }
        return (version, true)
    }

    /// Overwrites the file with a stored version and confirms the bytes match.
    /// Keeps nothing: call `add` first if the current contents matter.
    public static func restore(_ version: Version, to url: URL) throws -> Bool {
        try coordinated(url) { actual in
            _ = try version.raw.replaceItem(at: actual, options: [])
        }
        return sameContents(version.raw.url, url)
    }

    /// Deletes stored versions and what was noted about them. The file itself is not touched.
    public static func remove(_ versions: [Version], of url: URL) throws {
        try coordinated(url) { _ in
            for version in versions { try version.raw.remove() }
        }
        for version in versions { Meta.delete(version.id) }
    }

    /// Runs `body` inside a coordinated write, so apps that have the file open
    /// are told it changed. Gives up with `busy` instead of waiting forever.
    static func coordinated(_ url: URL, _ body: @escaping (URL) throws -> Void) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        let intent = NSFileAccessIntent.writingIntent(with: url, options: [])
        let finished = DispatchSemaphore(value: 0)
        var failure: Error?
        coordinator.coordinate(with: [intent], queue: OperationQueue()) { error in
            if let error {
                failure = error
            } else {
                do { try body(intent.url) } catch { failure = error }
            }
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            coordinator.cancel()
            throw ToolError(.busy, "another program held the file for more than \(Int(timeout)) seconds")
        }
        if let failure { throw failure }
    }
}
