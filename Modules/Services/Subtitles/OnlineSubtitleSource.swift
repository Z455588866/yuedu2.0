import Foundation
import Observation

/// One online subtitle provider, thesubtitledb-compatible. `baseURL` is the API root, e.g.
/// `https://api.thesubtitledb.org`; the service appends `/v1/by-title?q=…` and follows the
/// `download_url` returned in the payload. `language` is the preferred track code (zh/en/…).
/// Sources are never built in — the list starts empty and is filled only by import.
struct OnlineSubtitleSource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var language: String
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, language, enabled
        case baseURL = "baseUrl"
    }

    init(id: String, name: String, baseURL: String, language: String = "zh", enabled: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.language = language
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
                debugDescription: "online subtitle source needs a baseUrl"))
        }
        baseURL = url
        language = (try c.decodeIfPresent(String.self, forKey: .language)) ?? "zh"
        enabled = (try c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    private enum AliasKeys: String, CodingKey { case url }
}

/// Persists the user's online subtitle sources. Nothing is built in — populated only by import
/// (file or clipboard). Import merges by id: a matching id is replaced, new ids appended — the
/// same semantics as danmaku sources. Accepts a bare array, `{"sources": [...]}`, or one object.
@MainActor
@Observable
final class OnlineSubtitleSourceStore {
    static let shared = OnlineSubtitleSourceStore()

    private static let storageKey = "yd_online_subtitle_sources"

    private(set) var sources: [OnlineSubtitleSource]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([OnlineSubtitleSource].self, from: data) {
            sources = decoded
        } else {
            sources = []
        }
    }

    var enabledSources: [OnlineSubtitleSource] { sources.filter(\.enabled) }

    func source(id: String) -> OnlineSubtitleSource? { sources.first { $0.id == id } }

    func removeAll() {
        sources = []
        persist()
    }

    func reloadFromDisk() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([OnlineSubtitleSource].self, from: data) {
            sources = decoded
        }
    }

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

    func remove(id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources.remove(at: index)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func decodeSources(_ data: Data) throws -> [OnlineSubtitleSource] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([OnlineSubtitleSource].self, from: data) {
            return list
        }
        if let wrapped = try? decoder.decode(SourceWrapper.self, from: data) {
            return wrapped.sources
        }
        if let single = try? decoder.decode(OnlineSubtitleSource.self, from: data) {
            return [single]
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription:
            "unrecognized online subtitle source file"))
    }

    private struct SourceWrapper: Decodable {
        let sources: [OnlineSubtitleSource]
    }
}
