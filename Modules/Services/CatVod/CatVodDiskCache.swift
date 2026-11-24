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
    /// 写盘在后台，但**读盘原来是在主线程同步做的**：每次切分类、每次回到
    /// 推荐，`cachedCategory` / `cachedHome` 都会 `Data(contentsOf:)` 再解一遍
    /// JSON。单条几 KB 看着不多，可它发生在按下 chip 的那一帧上，滚动和点击
    /// 的手感就是从这里丢的。这一层内存副本让重复访问完全不碰磁盘。
    ///
    /// 只存 payload，不存 envelope：envelope 的 `savedAt` 只服务于 `maxAge`，
    /// 而目前没有调用方传 `maxAge`。真要用时走磁盘那条路即可，不会读错。
    /// `NSCache` 自己是线程安全的（Apple 明确的 thread-safe 类），它没有标
    /// `Sendable` 是历史原因。Swift 6 对 `static let` 做并发安全检查时会因此
    /// 报错，这里用 `nonisolated(unsafe)` 显式承担这个保证。
    nonisolated(unsafe) private static let memory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 400
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func load(key: String, maxAge: TimeInterval? = nil) -> Data? {
        if maxAge == nil, let cached = memory.object(forKey: key as NSString) {
            return cached as Data
        }
        let url = fileURL(for: key)
        guard let raw = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: raw),
              envelope.version == schemaVersion,
              !envelope.payload.isEmpty else { return nil }
        if let maxAge, Date().timeIntervalSince1970 - envelope.savedAt > maxAge { return nil }
        if maxAge == nil {
            memory.setObject(envelope.payload as NSData, forKey: key as NSString,
                             cost: envelope.payload.count)
        }
        return envelope.payload
    }

    /// Upper bound on stored responses. Browsing dozens of titles must not let
    /// the cache grow without limit; the oldest files are dropped first, which is
    /// exactly the copy least likely to be revisited.
    private static let maximumFiles = 400

    static func store(_ payload: Data, key: String) {
        guard !payload.isEmpty else { return }
        // 新结果立刻可读：否则同一次浏览里刚加载完的分类，切回来还要再解一次盘。
        memory.setObject(payload as NSData, forKey: key as NSString, cost: payload.count)
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
        memory.removeAllObjects()
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
