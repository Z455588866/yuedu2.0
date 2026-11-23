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
    static func name(from url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else {
            return String(url.suffix(24))
        }
        let last = (components.path as NSString).lastPathComponent
        return last.isEmpty ? host : "\(host) · \(last)"
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
            sources = decoded
        } else {
            sources = []
        }
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
        for source in incoming {
            if let index = next.firstIndex(where: { $0.id == source.id || $0.url == source.url }) {
                next[index] = source
            } else {
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
        let source = CatVodSource(id: CatVodSource.id(from: url),
                                  name: name ?? CatVodSource.name(from: url), url: url)
        if let index = sources.firstIndex(where: { $0.id == source.id || $0.url == source.url }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        persist()
        return source
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
