import Foundation
import CryptoKit

/// On-disk cache for the **raw** spider responses behind 猫元's browse screens.
///
/// Why raw JSON instead of the view models: `CatVodMedia` / `CatVodGroup` are
/// decode-only (they read the spider's `vod_*` shape), so persisting them would
/// need a second encoder for every model. Storing the response bytes lets the
/// existing `CatVodService.parseList` rebuild the list unchanged, and keeps this
/// file free of any model knowledge.
///
/// Policy is stale-while-revalidate: callers paint the stored copy immediately
/// and replace it when a fresh request lands. A miss is never an error — a cold
/// start simply behaves as it did before.
enum CatVodDiskCache {
    /// Bumped when the stored shape changes, so old entries are ignored instead
    /// of being decoded into the wrong type.
    private static let schemaVersion = 1

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("CatVodCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Writes happen off the main thread; the browse UI must never wait on disk.
    private static let writer = DispatchQueue(label: "app.yuedu.catvod.diskcache", qos: .utility)

    private struct Envelope: Codable, Sendable {
        var version: Int
        var savedAt: Double
        var payload: Data
    }

    /// Stable file name for an arbitrary tuple of identity parts.
    static func key(_ parts: [String]) -> String {
        let joined = parts.joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a stored payload. `maxAge` of `nil` accepts any age — that is the
    /// stale copy the UI shows before the network answers.
    static func load(key: String, maxAge: TimeInterval? = nil) -> Data? {
        let url = fileURL(for: key)
        guard let raw = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: raw),
              envelope.version == schemaVersion,
              !envelope.payload.isEmpty else { return nil }
        if let maxAge, Date().timeIntervalSince1970 - envelope.savedAt > maxAge { return nil }
        return envelope.payload
    }

    /// Upper bound on stored responses. Browsing dozens of titles must not let
    /// the cache grow without limit; the oldest files are dropped first, which is
    /// exactly the copy least likely to be revisited.
    private static let maximumFiles = 400

    static func store(_ payload: Data, key: String) {
        guard !payload.isEmpty else { return }
        let envelope = Envelope(version: schemaVersion,
                                savedAt: Date().timeIntervalSince1970,
                                payload: payload)
        writer.async {
            guard let data = try? JSONEncoder().encode(envelope) else { return }
            try? data.write(to: fileURL(for: key), options: .atomic)
            trimIfNeeded()
        }
    }

    /// Drops every stored response. Called when the person clears 猫元 data or
    /// switches interfaces, so a renamed/replaced source cannot show old titles.
    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    /// Runs on the writer queue only, so the plain `FileManager` calls need no
    /// extra locking.
    private static func trimIfNeeded() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys),
              files.count > maximumFiles else { return }
        let keySet = Set(keys)
        let byAge = files.sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: keySet).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: keySet).contentModificationDate) ?? .distantPast
            return left < right
        }
        for url in byAge.prefix(files.count - maximumFiles) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
