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

/// One filter group for a category, parsed from the `filters` map a CatVod `home`
/// response returns. Mirrors tvbox-silicon's `CategoryFilter`. Each group has a
/// `key` (sent back in `extend`) and a list of `{ name, value }` options.
struct CatVodFilter: Identifiable, Hashable, Sendable {
    struct Option: Identifiable, Hashable, Sendable {
        var name: String
        var value: String
        var id: String { value }
    }

    var key: String
    var name: String
    var options: [Option]

    var id: String { key }

    /// Parses one filter object. Accepts both `{value:[{n,v}]}` and
    /// `{value:[{name,value}]}` shapes used by different bundles, and prepends
    /// an "全部" (all) option bound to the empty value when none exists.
    static func parse(_ dict: [String: Any]) -> CatVodFilter? {
        guard let key = dict["key"] as? String, !key.isEmpty else { return nil }
        let rawOptions = dict["value"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        var options: [Option] = []
        for entry in rawOptions {
            let value = (entry["v"] as? String) ?? (entry["value"] as? String) ?? ""
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            let rawName = (entry["n"] as? String) ?? (entry["name"] as? String) ?? value
            options.append(Option(name: rawName.isEmpty ? value : rawName, value: value))
        }
        guard !options.isEmpty else { return nil }
        let name = (dict["name"] as? String).map { $0.isEmpty ? key : $0 } ?? key
        if !options.contains(where: { $0.value.isEmpty }) {
            options.insert(Option(name: localized("全部"), value: ""), at: 0)
        }
        return CatVodFilter(key: key, name: name, options: options)
    }
}

/// Parses the full `filters` payload: category id → filter groups. Some bundles
/// send it as a JSON string rather than an object, so try both shapes.
enum CatVodFilterParser {
    static func parse(_ value: Any?) -> [String: [CatVodFilter]] {
        var object: [String: Any]?
        if let dict = value as? [String: Any] {
            object = dict
        } else if let text = value as? String, let data = text.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object = dict
        }
        guard let object else { return [:] }
        var result: [String: [CatVodFilter]] = [:]
        for (categoryID, rawList) in object {
            guard let list = rawList as? [[String: Any]] else { continue }
            let filters = list.compactMap(CatVodFilter.parse)
            if !filters.isEmpty { result[categoryID] = filters }
        }
        return result
    }
}

/// A playable episode parsed from `vod_play_from` / `vod_play_url`.
struct CatVodEpisode: Identifiable, Hashable, Sendable {
    var id: String { "\(groupIndex)-\(index)-\(title)" }
    var groupIndex: Int
    /// 展示用的线路名。可能被改过（重名线路加「·2」后缀），**不能**回传给 spider。
    var groupName: String
    /// spider 声明的原始线路名，`player` 的 `flag` 只认这个。
    var spiderFlag: String
    var index: Int
    var title: String
    /// Spider play id or a direct URL. Passed to the gateway's `player` action.
    var playID: String
}

struct CatVodGroup: Identifiable, Hashable, Sendable {
    /// 线路名可能重复（源自己就会给两组同名线路），id 里带上首集的播放 id，
    /// 免得 `ForEach` 撞 id 导致整块选集不刷新或抖动。
    var id: String { "\(name)#\(episodes.first?.playID ?? "")" }
    var name: String
    /// 交给 spider 的原始线路名（见 `CatVodEpisode.spiderFlag`）。
    var spiderFlag: String
    var episodes: [CatVodEpisode]
}

/// 网盘线路的播放 id 不是 URL，而是一段 base64(JSON) 描述符，里面写着 `providerId`。
///
/// 为什么要在客户端先读它：百度网盘的播放请求在网关里必然失败（见
/// `catvod-cloud-player.mjs` 的 422 分支），但如果把 id 直接丢给 spider，
/// spider 会先去访问分享页（网盘里于是留下「查看记录」）、再走 `/play` 的 60 秒
/// 超时、再做一次流探测，一共两三分钟都停在转圈上。提前解码就能立刻说清楚。
enum CatVodNetdiskEpisode {
    struct Descriptor {
        var provider: String
    }

    private static let supported: Set<String> = ["quark", "uc", "aliyun", "123"]

    static func descriptor(from playID: String) -> Descriptor? {
        var text = playID.trimmingCharacters(in: .whitespacesAndNewlines)
        // CatVod 的 base64 可能是 URL-safe 且省略 padding 的。
        text = text.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard text.count < 8192,
              let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let provider = object["providerId"] as? String, !provider.isEmpty else { return nil }
        return Descriptor(provider: provider.lowercased())
    }

    static func isSupported(_ provider: String) -> Bool { supported.contains(provider) }

    /// 网盘客户端不认识的 provider 名字直接用原样展示。
    static func displayName(_ provider: String) -> String {
        switch provider {
        case "quark": return "夸克网盘"
        case "uc": return "UC 网盘"
        case "aliyun": return "阿里云盘"
        case "baidu": return "百度网盘"
        case "123": return "123 网盘"
        case "115": return "115 网盘"
        default: return provider
        }
    }
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
    /// Filter groups keyed by category id, present on `home` responses.
    var filters: [String: [CatVodFilter]]

    init(categories: [CatVodCategory], media: [CatVodMedia], page: Int, pageCount: Int,
         filters: [String: [CatVodFilter]] = [:]) {
        self.categories = categories
        self.media = media
        self.page = page
        self.pageCount = pageCount
        self.filters = filters
    }
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
            var entries = rawGroup.split(separator: "#", omittingEmptySubsequences: true)
            // 少数网盘源用换行分隔分集（`第1集$id\n第2集$id`），按 `#` 切会得到
            // 一整条无法解析的串，选集就空了。这里兜一层。
            if entries.count == 1, rawGroup.contains("\n") {
                entries = rawGroup.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
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
                episodes.append(CatVodEpisode(groupIndex: gi, groupName: groupName, spiderFlag: groupName,
                                              index: ei, title: title.isEmpty ? "\(ei + 1)" : title,
                                              playID: playID))
            }
            if !episodes.isEmpty {
                result.append(CatVodGroup(name: groupName, spiderFlag: groupName, episodes: episodes))
            }
        }
        return result
    }

    private static func split(_ text: String, separator: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return text.components(separatedBy: separator)
    }
}
