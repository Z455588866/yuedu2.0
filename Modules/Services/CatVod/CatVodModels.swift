import Foundation

/// Minimal CatVod / 苹果CMS `vod_*` wire models. The gateway returns the spider's standard JSON
/// unchanged; only the fields the browsing UI needs are decoded here (unknown keys are ignored).
struct CatVodSite: Codable, Identifiable, Hashable, Sendable {
    var key: String
    var name: String
    var type: Int?
    var api: String?
    var searchable: Bool?
    var filterable: Bool?
    var quickSearch: Bool?
    /// Provider configuration handed back on every `init`. CatVod catalogs declare
    /// `ext` either as a string or as an object (`{"configurable":true}`); the
    /// spider always wants the JSON text, so both shapes are flattened here.
    var ext: String = ""

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, name, type, api
        case searchable, filterable, quickSearch, ext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? key
        type = try c.decodeIfPresent(Int.self, forKey: .type)
        api = try c.decodeIfPresent(String.self, forKey: .api)
        searchable = try c.decodeIfPresent(Bool.self, forKey: .searchable)
        filterable = try c.decodeIfPresent(Bool.self, forKey: .filterable)
        quickSearch = try c.decodeIfPresent(Bool.self, forKey: .quickSearch)
        ext = (try? c.decodeIfPresent(String.self, forKey: .ext)) ?? ""
    }

    /// Replaces `ext` with the JSON text of whatever shape the catalog declared.
    /// `init(from:)` cannot do this itself because `ext` may be an arbitrary JSON
    /// value, which `Codable` cannot decode into `Any`.
    mutating func adoptRawExt(_ value: Any?) {
        guard let value else { return }
        if let string = value as? String {
            ext = string
            return
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        ext = text
    }
}

/// One media item from `/home`, `/category`, `/detail` or `/search` (`vod_*` fields).
struct CatVodMedia: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var cover: String
    var remark: String
    var detail: String
    var year: String
    var typeName: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.string(c, .vodId)
        name = Self.string(c, .vodName)
        cover = Self.string(c, .vodPic)
        remark = Self.string(c, .vodRemarks)
        detail = Self.string(c, .vodContent)
        year = Self.string(c, .vodYear)
        typeName = Self.string(c, .vodTypeName)
    }

    private enum CodingKeys: String, CodingKey {
        case vodId = "vod_id", vodName = "vod_name", vodPic = "vod_pic"
        case vodRemarks = "vod_remarks", vodContent = "vod_content"
        case vodYear = "vod_year", vodTypeName = "vod_type"
    }

    private static func string(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String {
        if let s = try? c.decode(String.self, forKey: key) { return s }
        if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
        return ""
    }
}

extension CatVodMedia: Decodable {}

/// A category returned by `home`'s `class` array.
struct CatVodCategory: Identifiable, Hashable, Decodable, Sendable {
    var id: String
    var name: String

    enum CodingKeys: String, CodingKey {
        case id = "type_id", name = "type_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
    }
}

/// A playable episode parsed from `vod_play_from` / `vod_play_url`.
struct CatVodEpisode: Identifiable, Hashable, Sendable {
    var id: String { "\(groupIndex)-\(index)-\(title)" }
    var groupIndex: Int
    var groupName: String
    var index: Int
    var title: String
    /// Spider play id or a direct URL. Passed to the gateway's `player` action.
    var playID: String
}

struct CatVodGroup: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
    var episodes: [CatVodEpisode]
}

/// Result of a `player` invocation.
struct CatVodPlayback: Decodable, Sendable {
    var parse: Int?
    var url: String?
    var header: [String: String]?

    enum CodingKeys: String, CodingKey {
        case parse, url, header
    }
}

/// A paged list response (home/category/search share this shape).
struct CatVodList: Sendable {
    var categories: [CatVodCategory]
    var media: [CatVodMedia]
    var page: Int
    var pageCount: Int
}

/// Splits the pipe/# separated `vod_play_from` and `vod_play_url` fields into groups of episodes.
/// `vod_play_from` groups are `$$$` separated; each group's `vod_play_url` episodes are `#` separated,
/// with each episode `title$playId` (a bare value counts as both title and id).
enum CatVodPlaylistParser {
    static func groups(from: String, playURL: String) -> [CatVodGroup] {
        let names = split(from, separator: "$$$")
        let urlGroups = split(playURL, separator: "$$$")
        var result: [CatVodGroup] = []
        for (gi, rawGroup) in urlGroups.enumerated() {
            let groupName = gi < names.count ? names[gi] : String(format: localized("线路 %d"), gi + 1)
            var episodes: [CatVodEpisode] = []
            let entries = rawGroup.split(separator: "#", omittingEmptySubsequences: true)
            for (ei, entry) in entries.enumerated() {
                let parts = entry.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
                let title = parts.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "\(ei + 1)"
                let playID: String
                if parts.count > 1 {
                    playID = String(parts[1])
                } else {
                    playID = String(entry)
                }
                if playID.isEmpty { continue }
                episodes.append(CatVodEpisode(groupIndex: gi, groupName: groupName,
                                              index: ei, title: title.isEmpty ? "\(ei + 1)" : title,
                                              playID: playID))
            }
            if !episodes.isEmpty { result.append(CatVodGroup(name: groupName, episodes: episodes)) }
        }
        return result
    }

    private static func split(_ text: String, separator: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: separator)
    }
}
