import Foundation
import Observation

/// One imported CatVod node bundle (a `.js` / `.js.md5` spider interface, e.g. the
/// "二小 / 潇洒 / 豆儿" feeds). Only the address is stored; the bundle itself is downloaded,
/// md5-verified and cached by `CatVodGateway` when the source is first used.
///
/// Kept deliberately parallel to `DanmakuSource`: no sources are built in, the list starts
/// empty and is filled only by what the user imports. Import merges by id.
struct CatVodSource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Full `.js.md5` (or `.js`) address. The gateway derives the companion `.js` URL.
    var url: String
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, url, enabled
    }

    init(id: String, name: String, url: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        guard !rawURL.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.url, .init(codingPath: decoder.codingPath,
                debugDescription: "catvod source needs a url"))
        }
        url = rawURL
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Self.id(from: rawURL)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.name(from: rawURL)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Stable id derived from the URL so re-importing the same link replaces rather than duplicates.
    static func id(from url: String) -> String {
        var hasher = Hasher()
        hasher.combine(url.trimmingCharacters(in: .whitespacesAndNewlines))
        return String(format: "catvod-%016llx", UInt64(bitPattern: Int64(hasher.finalize())))
    }

    /// A readable default name from the URL host/path when the import has no explicit name.
    ///
    /// Deliberately short: the picker draws this in a menu row, and "host · index.js.md5"
    /// wrapped onto two lines and read as an address rather than a name. The file name is
    /// dropped entirely when it is the generic CatVod entry point, and the host is used
    /// alone — uniqueness is enforced by `CatVodSourceStore` (see `uniqueName`).
    static func name(from url: String) -> String {
        guard let components = URLComponents(string: url), var host = components.host else {
            return String(url.suffix(24))
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let last = (components.path as NSString).lastPathComponent
        let generic: Set<String> = ["index.js.md5", "index.js", "index.md5", "config.js", "api.js"]
        guard !last.isEmpty, !generic.contains(last.lowercased()) else { return host }
        return "\(host) · \(last)"
    }

    var checksumURL: String {
        url.hasSuffix(".md5") ? url : url + ".md5"
    }
}

/// Persists the user's CatVod sources. Mirrors `DanmakuSourceStore`: empty by default,
/// import merges by id, same UserDefaults-backed `@Observable` pattern.
@MainActor
@Observable
final class CatVodSourceStore {
    static let shared = CatVodSourceStore()

    private static let storageKey = "yd_catvod_sources"

    private(set) var sources: [CatVodSource]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CatVodSource].self, from: data) {
            sources = Self.dedupeNames(decoded)
            // Older builds stored the same interface several times under one display
            // name ("ghfast.top · index.js.md5" x5), which made the picker a list of
            // identical rows. Persist the suffix once so the fix survives relaunch.
            if sources.map(\.name) != decoded.map(\.name) { persist() }
        } else {
            sources = []
        }
    }

    /// Suffixes duplicated display names so every row in the picker is distinguishable.
    /// Names are what the person reads; ids stay untouched.
    private static func dedupeNames(_ list: [CatVodSource]) -> [CatVodSource] {
        var result: [CatVodSource] = []
        var taken = Set<String>()
        for var source in list {
            let base = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty {
                source.name = CatVodSource.name(from: source.url)
            }
            var candidate = source.name
            if taken.contains(candidate) {
                var index = 2
                while taken.contains("\(candidate) (\(index))") { index += 1 }
                candidate = "\(candidate) (\(index))"
            }
            source.name = candidate
            taken.insert(candidate)
            result.append(source)
        }
        return result
    }

    var enabledSources: [CatVodSource] { sources.filter(\.enabled) }

    func source(id: String) -> CatVodSource? { sources.first { $0.id == id } }

    func removeAll() {
        sources = []
        persist()
    }

    func reloadFromDisk() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CatVodSource].self, from: data) {
            sources = decoded
        }
    }

    /// Imports one or more sources. Accepts a bare array, `{"sources":[…]}`, a single object,
    /// or a plain-text list of URLs (one per line, `#` comments). Returns sources accepted.
    @discardableResult
    func `import`(_ data: Data) throws -> Int {
        let incoming = try Self.decodeSources(data)
        guard !incoming.isEmpty else { return 0 }
        var next = sources
        for var source in incoming {
            let defaultName = CatVodSource.name(from: source.url)
            if let index = next.firstIndex(where: { $0.id == source.id || $0.url == source.url }) {
                // Re-importing the same address must not wipe a name the person typed.
                if source.name == defaultName { source.name = next[index].name }
                next[index] = source
            } else {
                if source.name == defaultName {
                    source.name = uniqueName(defaultName, in: next)
                }
                next.append(source)
            }
        }
        sources = next
        persist()
        return incoming.count
    }

    /// Convenience for a URL typed/pasted on its own.
    @discardableResult
    func add(url: String, name: String? = nil) -> CatVodSource {
        var source = CatVodSource(id: CatVodSource.id(from: url),
                                  name: name ?? CatVodSource.name(from: url), url: url)
        if let index = sources.firstIndex(where: { $0.id == source.id || $0.url == source.url }) {
            sources[index] = source
        } else {
            source.name = uniqueName(source.name, in: sources)
            sources.append(source)
        }
        persist()
        return source
    }

    /// Appends " (2)", " (3)"… when another interface already owns this display name, so
    /// the picker never renders two rows that read identically.
    private func uniqueName(_ base: String, in list: [CatVodSource]) -> String {
        let taken = Set(list.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) (\(index))") { index += 1 }
        return "\(base) (\(index))"
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled = enabled
        persist()
    }

    func rename(id: String, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].name = name
        persist()
    }

    func remove(id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources.remove(at: index)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func decodeSources(_ data: Data) throws -> [CatVodSource] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([CatVodSource].self, from: data) { return list }
        if let wrapped = try? decoder.decode(SourceWrapper.self, from: data) { return wrapped.sources }
        if let single = try? decoder.decode(CatVodSource.self, from: data) { return [single] }
        // Plain text: one interface address per line. Annotations like "#二小接口" are names.
        if let text = String(data: data, encoding: .utf8) {
            var result: [CatVodSource] = []
            var pendingName: String?
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                if line.hasPrefix("#") {
                    let candidate = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.contains("http") { pendingName = nil } else { pendingName = candidate }
                    continue
                }
                guard let range = line.range(of: "https?://", options: .regularExpression) else { continue }
                let url = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(CatVodSource(id: CatVodSource.id(from: url),
                                           name: pendingName ?? CatVodSource.name(from: url), url: url))
                pendingName = nil
            }
            if !result.isEmpty { return result }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription:
            "unrecognized catvod source file"))
    }

    private struct SourceWrapper: Decodable {
        let sources: [CatVodSource]
    }
}
