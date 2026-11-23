import Foundation
import Observation

/// One danmaku (弹弹play-compatible) API endpoint. `baseURL` is the full path the service is
/// mounted at, e.g. `https://danmu.cynn.top/cynnsq`; the API paths (`/api/v2/...`) are appended
/// to it. Sources are bundled by default and can be replaced/added by an imported JSON file.
struct DanmakuSource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case baseURL = "baseUrl"
    }

    /// Accepts both `baseUrl` and `baseURL` spellings, and a bare `url` alias, for hand-written
    /// imported files.
    init(id: String, name: String, baseURL: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try c.decodeIfPresent(String.self, forKey: .name)) ?? id
        let url = try c.decodeIfPresent(String.self, forKey: .baseURL)
            ?? (try decoder.container(keyedBy: AliasKeys.self).decodeIfPresent(String.self, forKey: .url))
        guard let url, !url.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.baseURL, .init(codingPath: decoder.codingPath,
                debugDescription: "danmaku source needs a baseUrl"))
        }
        baseURL = url
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    private enum AliasKeys: String, CodingKey { case url }
}

/// Persists the user's danmaku sources. No sources are built in — the list starts empty and is
/// populated only by what the user imports (file or clipboard). Import merges by id: a matching
/// id is replaced, anything else is appended — the same semantics as TXT TOC rules.
@MainActor
@Observable
final class DanmakuSourceStore {
    static let shared = DanmakuSourceStore()

    private static let storageKey = "yd_danmaku_sources"

    private(set) var sources: [DanmakuSource]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([DanmakuSource].self, from: data) {
            sources = decoded
        } else {
            sources = []
        }
    }

    var enabledSources: [DanmakuSource] { sources.filter(\.enabled) }

    func source(id: String) -> DanmakuSource? { sources.first { $0.id == id } }

    /// Removes every source (the user's list is entirely their own).
    func removeAll() {
        sources = []
        persist()
    }

    /// Re-reads the persisted array (called after an external edit such as a delete).
    func reloadFromDisk() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([DanmakuSource].self, from: data) {
            sources = decoded
        }
    }

    /// Merges imported sources: same id replaces the existing entry, new ids append. Returns the
    /// number of sources accepted. Accepts a bare array, `{"sources": [...]}`, or one object.
    @discardableResult
    func `import`(_ data: Data) throws -> Int {
        let incoming = try Self.decodeSources(data)
        guard !incoming.isEmpty else { return 0 }
        var next = sources
        for source in incoming {
            if let index = next.firstIndex(where: { $0.id == source.id }) {
                next[index] = source
            } else {
                next.append(source)
            }
        }
        sources = next
        persist()
        return incoming.count
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled = enabled
        persist()
    }

    /// Removes a source by id.
    func remove(id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources.remove(at: index)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func decodeSources(_ data: Data) throws -> [DanmakuSource] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([DanmakuSource].self, from: data) {
            return list
        }
        if let wrapped = try? decoder.decode(SourceWrapper.self, from: data) {
            return wrapped.sources
        }
        if let single = try? decoder.decode(DanmakuSource.self, from: data) {
            return [single]
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription:
            "unrecognized danmaku source file"))
    }

    private struct SourceWrapper: Decodable {
        let sources: [DanmakuSource]
    }
}
