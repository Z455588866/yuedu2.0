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

    /// 自定义 `init(from:)` 会让编译器不再自动合成成员初始化器；而 py 站点面板
    /// 等处会用 `CatVodSite(key:name:type:api:...)` 直接构造，补上这个初始化器
    /// 才能让那些调用点编译通过。参数都带默认值，兼容只传部分字段的调用。
    init(key: String, name: String, type: Int? = nil, api: String? = nil,
         searchable: Bool? = nil, filterable: Bool? = nil, quickSearch: Bool? = nil,
         ext: String = "") {
        self.key = key
        self.name = name
        self.type = type
        self.api = api
        self.searchable = searchable
        self.filterable = filterable
        self.quickSearch = quickSearch
        self.ext = ext
    }

    enum CodingKeys: String, CodingKey {
        case key, name, type, api
        case searchable, filterable, quickSearch, ext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? key
        type = Self.flexibleInt(c, .type)
        api = try c.decodeIfPresent(String.self, forKey: .api)
        // 猫源网关把 `searchable`/`filterable`/`quickSearch` 发成数字 1/0
        // （实测 smdl/lmentor/douer 全是 number，只有极少数站点是 bool）。
        // JSONDecoder 的 decodeIfPresent(Bool.self) 遇到数字 1 会直接抛错，
        // 让整个站点被 compactMap 丢弃——79 个站点只剩 19 个网盘/Python 站点，
        // 界面就是「这个接口没有可用的站点」。照 CatVodMedia.string() 的容错
        // 模式改成先试 Bool、再试 Int、最后试字符串，任一类型都能读懂。
        searchable = Self.flexibleBool(c, .searchable)
        filterable = Self.flexibleBool(c, .filterable)
        quickSearch = Self.flexibleBool(c, .quickSearch)
        ext = (try? c.decodeIfPresent(String.self, forKey: .ext)) ?? ""
    }

    /// 站点标志位可能是 Bool、数字(1/0)或字符串("1"/"true")，逐个尝试，
    /// 都不匹配时按「未声明」处理（nil），绝不让一个字段毁掉整个站点。
    private static func flexibleBool(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let b = try? c.decodeIfPresent(Bool.self, forKey: key) { return b }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i != 0 }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            if let i = Int(s) { return i != 0 }
            if let b = Bool(s) { return b }
        }
        return nil
    }

    private static func flexibleInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return i }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
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

/// 一条可播的清晰度。网盘转码会给多档（4K/1080P/…），但只有会员权限内的档位
/// 带真实地址，所以这份列表本身就是「你现在到底能看多清楚」的答案。
struct CatVodQualityOption: Decodable, Sendable, Hashable, Identifiable {
    var name: String
    var url: String
    var width: Int?
    var height: Int?
    var bitrate: Int?

    var id: String { "\(name)@\(url)" }
}

/// 猫源自带的一条弹幕。TVBox 的 `danmaku` 数组就是这个形状：`{time, type, color, text}`，
/// `time` 是从片头算的秒数（可以是整数、小数或字符串——各家插件写法不一致）。
struct CatVodDanmakuItem: Decodable, Sendable {
    var time: Double
    var text: String
    var type: Int?
    var color: Int?

    enum CodingKeys: String, CodingKey { case time, text, type, color }

    init(time: Double, text: String, type: Int? = nil, color: Int? = nil) {
        self.time = time
        self.text = text
        self.type = type
        self.color = color
    }

    /// 手写解码：任何一个字段写坏了都只影响这一条，不连累整条播放结果。
    /// 之前用合成解码，一个源把 `time` 写成 `"12.5"` 就会让整个 `player` 响应解不出来，
    /// 表现是「点播放没反应」。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decodeIfPresent(Double.self, forKey: .time) {
            time = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .time),
                  let value = Double(text) {
            time = value
        } else {
            time = 0
        }
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        type = try? container.decodeIfPresent(Int.self, forKey: .type)
        color = try? container.decodeIfPresent(Int.self, forKey: .color)
    }
}

/// TVBox 还有一种约定：`danmaku` 里放的是**弹幕源列表**（`[{name, url}]`），url 指向
/// 一个返回 B 站 XML 的地址。红果就是这种——它在插件进程里开了个 `/hg_dm` 路由。
struct CatVodDanmakuSource: Decodable, Sendable {
    var name: String?
    var url: String?
}

/// `playerContent.danmaku` 的三种形态：行数组、单个地址、弹幕源列表。
/// 解码时永不抛错——弹幕只是锦上添花，不能因为它把能播的片子变成不能播。
struct CatVodDanmakuPayload: Decodable, Sendable {
    var items: [CatVodDanmakuItem] = []
    var link: String?
    var sources: [CatVodDanmakuSource] = []
    /// 弹幕地址常是插件进程里的 loopback（红果 `/hg_dm`）。它的临时端口会随
    /// spider 会话回收，直连会 404；带上 bundle 身份后，加载器可把地址改写成
    /// 稳定的网关代理，由网关重建会话再取。不参与 JSON 解码。
    var bundleURL: String? = nil

    init(items: [CatVodDanmakuItem] = [], link: String? = nil,
         sources: [CatVodDanmakuSource] = [], bundleURL: String? = nil) {
        self.items = items
        self.link = link
        self.sources = sources
        self.bundleURL = bundleURL
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.singleValueContainer() else { return }
        if let text = try? container.decode(String.self) {
            link = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        // 先按「弹幕行」解：有 text 才是行，没有 text 的是 {name, url} 源列表。
        if let rows = try? container.decode([CatVodDanmakuItem].self),
           rows.contains(where: { !$0.text.isEmpty }) {
            items = rows
            return
        }
        sources = (try? container.decode([CatVodDanmakuSource].self)) ?? []
    }
}

/// Result of a `player` invocation.
struct CatVodPlayback: Decodable, Sendable {
    var parse: Int?
    var url: String?
    var header: [String: String]?
    /// 当前选用档位的名字（"1080P"、"流畅"、"原画"）。
    var quality: String? = nil
    /// 这条线路所有能播的档位，按清晰度从高到低。只有一个时不必给用户选。
    var qualityOptions: [CatVodQualityOption]? = nil
    /// 网关给出的降级说明（`quark-original-size-limit` 等），由界面翻成人话。
    var playbackNotice: String? = nil
    /// 片源自带的弹幕。红果这类插件会在 `playerContent` 里直接给出整集弹幕。
    var danmaku: CatVodDanmakuPayload? = nil

    enum CodingKeys: String, CodingKey {
        case parse, url, header, quality, qualityOptions, playbackNotice, danmaku
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
