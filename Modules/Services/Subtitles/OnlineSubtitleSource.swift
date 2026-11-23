import Foundation
import Observation

/// Which wire protocol a source speaks. Both are real, public, open-source subtitle APIs:
/// - `thesubtitledb`: title search, keyless, excellent Chinese coverage (api.thesubtitledb.org).
/// - `wyzie`: IMDB-id search, aggregates OpenSubtitles/SubDL/Subscene, needs a free user key.
///   The app bridges a Chinese title to an IMDB id through theSubtitleDB, then queries wyzie.
/// Unknown values fall back to `thesubtitledb` so old configs keep working.
enum SubtitleApiType: String, Codable, Sendable {
    case thesubtitledb
    case wyzie
}

/// One online subtitle provider. `baseURL` is the API root. `apiType` selects the wire protocol
/// (defaults to theSubtitleDB for backward compatibility); `apiKey` is only used by providers that
/// require one (wyzie) and is supplied by the user in the imported config — never built in.
/// `language` is the preferred track code (zh/en/…). Sources are never built in — imported only.
struct OnlineSubtitleSource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var baseURL: String
    var language: String
    var enabled: Bool = true
    var apiType: SubtitleApiType = .thesubtitledb
    var apiKey: String = ""

    enum CodingKeys: String, CodingKey {
        case id, name, language, enabled, apiType
        case baseURL = "baseUrl"
        case apiKey
    }

    init(id: String, name: String, baseURL: String, language: String = "zh", enabled: Bool = true,
         apiType: SubtitleApiType = .thesubtitledb, apiKey: String = "") {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.language = language
        self.enabled = enabled
        self.apiType = apiType
        self.apiKey = apiKey
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
        // Accept `apiType`, `type`, or `format`; unknown strings degrade to theSubtitleDB.
        // `try` goes once in front of the whole `??` chain — marking only an operand makes the
        // other throwing operands unmarked ("operator can throw but expression is not marked").
        let alias = decoder.container(keyedBy: AliasKeys.self)
        let rawType = try c.decodeIfPresent(String.self, forKey: .apiType)
            ?? alias.decodeIfPresent(String.self, forKey: .type)
            ?? alias.decodeIfPresent(String.self, forKey: .format)
        apiType = rawType.flatMap(SubtitleApiType.init(rawValue:)) ?? .thesubtitledb
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
            ?? alias.decodeIfPresent(String.self, forKey: .key)
            ?? ""
    }

    private enum AliasKeys: String, CodingKey { case url, type, format, key }
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
