import Foundation

/// Talks to the embedded spider gateway over loopback HTTP and decodes the CatVod JSON into the
/// small view models in `CatVodModels`. Independent of the book-source engine on purpose: the
/// gateway owns the Node runtime and the spider protocol; this is a thin typed client.
@MainActor
final class CatVodService {
    static let shared = CatVodService()

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Interfaces already warmed during this launch (bundle downloaded, process
    /// booted, first page fetched). Warm-up is idempotent, but `claimWarmUp`
    /// keeps re-opening the 猫元 page from re-hammering every source.
    private var warmedBundles = Set<String>()

    func claimWarmUp(bundleURL: String) -> Bool {
        warmedBundles.insert(bundleURL).inserted
    }

    /// Gives the claim back after a failed warm-up, so a later attempt can retry
    /// instead of treating a transient network error as "already warm".
    func releaseWarmUp(bundleURL: String) {
        warmedBundles.remove(bundleURL)
    }

    /// Loads the site catalog exposed by a CatVod bundle. Starts the engine with this bundle
    /// allowlisted, then asks the gateway for its sites.
    func catalog(bundleURL: String) async throws -> [CatVodSite] {
        let base = try await CatVodGateway.shared.ensureStarted(allowedBundleURL: bundleURL)
        let endpoint = base.appendingPathComponent("/v1/catvod/catalog")
        let object = try await post(endpoint, body: ["bundle": bundleURL])
        guard let sites = object["sites"] as? [[String: Any]] else { return [] }
        let parsed = sites.compactMap { dict -> CatVodSite? in
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  var site = try? decoder.decode(CatVodSite.self, from: data) else { return nil }
            // `ext` may be a string or an object in the catalog; normalise it to the
            // JSON text the spider expects on every init.
            site.adoptRawExt(dict["ext"])
            return site
        }
        Self.persistCatalog(parsed, bundleURL: bundleURL)
        return parsed
    }

    /// Site list from the previous launch. Lets the browse screen draw its site
    /// picker and category bar before the gateway has downloaded and booted the
    /// bundle, instead of showing one spinner for the whole cold start.
    func cachedCatalog(bundleURL: String) -> [CatVodSite]? {
        let data = CatVodDiskCache.load(key: CatVodDiskCache.key(["catalog", bundleURL]))
        guard let data, let sites = try? JSONDecoder().decode([CatVodSite].self, from: data),
              !sites.isEmpty else { return nil }
        return sites
    }

    /// Home categories and recommended media for a site.
    func home(bundleURL: String, site: CatVodSite) async throws -> CatVodList {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "home",
                                      arguments: ["filter": true])
        let list = Self.parseList(object)
        Self.persistList(object, bundleURL: bundleURL, site: site, action: "home",
                         categoryID: "", page: 1, extend: [:])
        return list
    }

    /// The last successful 推荐 response for this interface + site, straight from
    /// disk. The browse screen paints this before the network answers, so a
    /// relaunch shows content immediately instead of an empty grid.
    func cachedHome(bundleURL: String, site: CatVodSite) -> CatVodList? {
        Self.loadList(bundleURL: bundleURL, site: site, action: "home",
                      categoryID: "", page: 1, extend: [:])
    }

    func category(bundleURL: String, site: CatVodSite, categoryID: String, page: Int,
                  extend: [String: String] = [:]) async throws -> CatVodList {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "category",
                                      arguments: ["tid": categoryID, "page": String(page),
                                                  "filter": false, "extend": extend])
        let list = Self.parseList(object)
        Self.persistList(object, bundleURL: bundleURL, site: site, action: "category",
                         categoryID: categoryID, page: page, extend: extend)
        return list
    }

    /// Cached copy of one category page, same stale-while-revalidate contract as
    /// `cachedHome`. Switching back to a category you already opened is instant.
    func cachedCategory(bundleURL: String, site: CatVodSite, categoryID: String, page: Int,
                        extend: [String: String] = [:]) -> CatVodList? {
        Self.loadList(bundleURL: bundleURL, site: site, action: "category",
                      categoryID: categoryID, page: page, extend: extend)
    }

    func search(bundleURL: String, site: CatVodSite, keyword: String, page: Int = 1) async throws -> CatVodList {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "search",
                                      arguments: ["keyword": keyword, "page": String(page), "quick": false])
        return Self.parseList(object)
    }

    /// 该接口下**所有**可搜索站点并发搜索，合成一份结果。
    ///
    /// 之前只搜当前选中的那一个站点，所以同一个源里其它站点的片子在搜索里
    /// 根本不存在。这里并发打全部站点，慢的那个不再拖住快的——用 `withTaskGroup`
    /// 是为了让先回来的结果先可用，而不是按站点顺序排队。
    ///
    /// 返回 `(站点, 结果)`，调用方必须保留站点信息：点进详情时要打回**命中它的
    /// 那个站点**，否则用别的站点去查 id 必然查不到。
    func searchAll(bundleURL: String, sites: [CatVodSite], keyword: String) async -> [(CatVodSite, CatVodList)] {
        let targets = sites.filter { $0.searchable != false }
        guard !targets.isEmpty else { return [] }
        return await withTaskGroup(of: (CatVodSite, CatVodList?).self) { group in
            for site in targets {
                group.addTask { [weak self] in
                    guard let self else { return (site, nil) }
                    let list = try? await self.search(bundleURL: bundleURL, site: site, keyword: keyword)
                    return (site, list)
                }
            }
            var collected: [(CatVodSite, CatVodList)] = []
            for await (site, list) in group {
                if let list, !list.media.isEmpty { collected.append((site, list)) }
            }
            return collected
        }
    }

    /// Full detail incl. play groups for one media id.
    func detail(bundleURL: String, site: CatVodSite, id: String) async throws -> (CatVodMedia, [CatVodGroup]) {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "detail",
                                      arguments: ["ids": [id]])
        guard let first = (object["list"] as? [[String: Any]])?.first,
              let data = try? JSONSerialization.data(withJSONObject: first),
              let media = try? decoder.decode(CatVodMedia.self, from: data) else {
            throw CatVodError.emptyResponse
        }
        let from = first["vod_play_from"] as? String ?? ""
        let playURL = first["vod_play_url"] as? String ?? ""
        let groups = CatVodPlaylistParser.groups(from: from, playURL: playURL)
        // Only the two play columns are stored: the episode list is all the detail
        // sheet needs, and keeping `vod_*` text out of the cache avoids persisting
        // a whole title's metadata for every poster the person taps.
        if !groups.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: ["from": from, "url": playURL]) {
            CatVodDiskCache.store(data, key: Self.detailCacheKey(bundleURL: bundleURL, site: site, id: id))
        }
        return (media, groups)
    }

    /// Episode list from a previous visit, so re-opening a title shows its
    /// episodes on the first frame instead of the "正在加载剧集…" placeholder.
    func cachedDetail(bundleURL: String, site: CatVodSite, id: String) -> [CatVodGroup]? {
        let key = Self.detailCacheKey(bundleURL: bundleURL, site: site, id: id)
        guard let data = CatVodDiskCache.load(key: key),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let from = object["from"], let playURL = object["url"] else { return nil }
        let groups = CatVodPlaylistParser.groups(from: from, playURL: playURL)
        return groups.isEmpty ? nil : groups
    }

    /// Resolves a spider episode id to a stream URL + headers. Mirrors tvbox-silicon's
    /// `resolvePlayback` routing: direct media plays as-is; `json:`/`parse:` payloads
    /// and `parse/jx == 1` need an external parser; netdisk shares are resolved by
    /// the trusted gateway (which holds the account credentials).
    func player(bundleURL: String, site: CatVodSite, episode: CatVodEpisode) async throws -> CatVodPlayback {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "player",
                                      arguments: [
                                        "flag": episode.groupName,
                                        "id": episode.playID,
                                        "vipFlags": [String]()
                                      ])
        var headers: [String: String] = [:]
        if let header = object["header"] as? [String: Any] {
            for (k, v) in header {
                if let s = v as? String { headers[k] = s }
                else { headers[k] = "\(v)" }
            }
        }
        let parse = Self.flexibleInt(object["parse"])
        let jx = Self.flexibleInt(object["jx"])
        let rawURL = Self.firstURL(object["url"])

        // A spider may hand back an episode id that is itself a direct media URL.
        // The runner already normalises this, but keep a fallback for gateways that
        // return `url` empty with `parse=0`.
        let resolvedURL: String
        if rawURL.isEmpty {
            if parse == 0, jx == 0, Self.isDirectMedia(episode.playID) {
                resolvedURL = episode.playID
            } else {
                throw CatVodError.emptyPlayerURL
            }
        } else {
            resolvedURL = rawURL
        }

        // `parse=1` / `jx=1` lines need a secondary resolver. The gateway first tries
        // an HTTP fast path (embedded player_aaaa / inline m3u8 / JSON parse service).
        // Whatever it cannot resolve, this app finishes with its own headless WebView
        // sniffer — the same one Legado book sources use to find a page's stream.
        if parse == 1 || jx == 1 || resolvedURL.hasPrefix("parse:")
            || resolvedURL.hasPrefix("json:") {
            if let sniffed = await Self.sniffPlaybackPage(resolvedURL, headers: headers) {
                return CatVodPlayback(parse: 0, url: sniffed.absoluteString, header: headers)
            }
            throw CatVodError.parseUnsupported
        }
        // Magnet / thunder links are not playable in an in-app video player.
        if resolvedURL.hasPrefix("magnet:") || resolvedURL.hasPrefix("thunder:")
            || resolvedURL.hasPrefix("ed2k:") {
            throw CatVodError.unsupportedScheme
        }

        // Relative URLs are meaningless against the gateway loopback; spider URLs
        // are always absolute, so a missing scheme means the source is malformed.
        guard let finalURL = URL(string: resolvedURL), finalURL.scheme != nil else {
            throw CatVodError.emptyPlayerURL
        }
        // Many CDNs answer 403 ("你没有访问所请求的资源的许可") to a bare request.
        // When the spider handed back no UA/Referer, add the browser defaults a
        // web player would send so the stream is not gated out by anti-hotlink.
        var finalHeaders = headers
        if finalHeaders["User-Agent"] == nil, finalHeaders["user-agent"] == nil {
            finalHeaders["User-Agent"] =
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }
        if finalHeaders["Referer"] == nil, finalHeaders["referer"] == nil,
           let scheme = finalURL.scheme, let host = finalURL.host {
            finalHeaders["Referer"] = "\(scheme)://\(host)/"
        }
        return CatVodPlayback(parse: parse, url: finalURL.absoluteString, header: finalHeaders)
    }

    private static func firstURL(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [String] { return arr.first(where: { !$0.isEmpty }) ?? "" }
        return ""
    }

    private static func isDirectMedia(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return [".mp4", ".m3u8", ".mkv", ".avi", ".mov", ".flv", ".ts", ".mp3", ".m4a"]
            .contains { lowered.contains($0) }
    }

    /// Last chance for a `parse=1` line: load the play page unseen and let its own
    /// script hand over the stream (mirrors tvbox-silicon's WebSniffer and the app's
    /// own Legado page sniffer). Returns nil for `json:`/`parse:` service payloads,
    /// which carry no page of their own — those are resolved inside the gateway.
    private static func sniffPlaybackPage(_ address: String, headers: [String: String]) async -> URL? {
        guard let pageURL = URL(string: address),
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return nil }
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 15
        var userAgent: String?
        for (field, value) in headers {
            if field.lowercased() == "user-agent" { userAgent = value }
            else { request.setValue(value, forHTTPHeaderField: field) }
        }
        return await LegadoHeadlessWebView.sniffVideo(
            page: request,
            userAgent: userAgent,
            timeout: 15,
            isVideoRequest: DirectChapterVideoResolver.isVideoRequest
        )
    }

    // MARK: - Low level

    private func invoke(bundleURL: String, site: CatVodSite, action: String,
                        arguments: [String: Any]) async throws -> [String: Any] {
        let base = try await CatVodGateway.shared.ensureStarted(allowedBundleURL: bundleURL)
        let endpoint = base.appendingPathComponent("/v1/spider/invoke")
        let body: [String: Any] = [
            "version": 1,
            "action": action,
            "site": [
                "key": site.key,
                "api": site.api ?? "/spider/\(site.key)/3",
                "jar": bundleURL,
                "ext": site.ext,
                "quickSearch": site.quickSearch ?? false
            ],
            "arguments": arguments
        ]
        return try await post(endpoint, body: body)
    }

    private func post(_ endpoint: URL, body: [String: Any]) async throws -> [String: Any] {
        // A spider session can be reclaimed while the app is backgrounded or idle.
        // The gateway rebuilds it on demand, so one automatic retry turns a
        // transient "CatVod stopped" 502 into a seamless success.
        do {
            return try await postOnce(endpoint, body: body)
        } catch let error as CatVodError {
            if case .http(let status, let message) = error,
               status == 502,
               message.localizedCaseInsensitiveContains("stopped")
                || message.localizedCaseInsensitiveContains("exited") {
                return try await postOnce(endpoint, body: body)
            }
            throw error
        }
    }

    private func postOnce(_ endpoint: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The embedded gateway is started with a per-launch token and rejects every
        // request without `Authorization: Bearer <token>` (401). Send the same token
        // the gateway was configured with.
        request.setValue("Bearer \(CatVodGateway.shared.authenticationToken)",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // A cold bundle (download + JS compile + server start) plus a slow
        // overseas upstream needs the budget the CatVod players give a source
        // (150s for catalog/home/category, less for search and play). The old
        // 30–50s reported healthy-but-slow sources as "cannot load".
        request.timeoutInterval = 150

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let serverMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            let rawMessage = String(data: data, encoding: .utf8).map { String($0.prefix(120)) } ?? ""
            throw CatVodError.http(status, serverMessage ?? rawMessage)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatVodError.emptyResponse
        }
        return object
    }

    /// Rebuilds a list from stored response bytes (see `CatVodDiskCache`).
    static func parseList(data: Data) -> CatVodList? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return parseList(object)
    }

    private static func persistCatalog(_ sites: [CatVodSite], bundleURL: String) {
        guard !sites.isEmpty, let data = try? JSONEncoder().encode(sites) else { return }
        CatVodDiskCache.store(data, key: CatVodDiskCache.key(["catalog", bundleURL]))
    }

    private static func listCacheKey(bundleURL: String, site: CatVodSite, action: String,
                                     categoryID: String, page: Int,
                                     extend: [String: String]) -> String {
        let extendText = extend.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return CatVodDiskCache.key(["list", bundleURL, site.key, action,
                                    categoryID, String(page), extendText])
    }

    private static func detailCacheKey(bundleURL: String, site: CatVodSite, id: String) -> String {
        CatVodDiskCache.key(["detail", bundleURL, site.key, id])
    }

    private static func persistList(_ object: [String: Any], bundleURL: String, site: CatVodSite,
                                    action: String, categoryID: String, page: Int,
                                    extend: [String: String]) {
        // Cache only real content: an empty or error-shaped response must not
        // replace a good list the person can still browse.
        let hasContent = (object["list"] as? [[String: Any]])?.isEmpty == false
            || (object["class"] as? [[String: Any]])?.isEmpty == false
        guard hasContent, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        CatVodDiskCache.store(data, key: listCacheKey(bundleURL: bundleURL, site: site, action: action,
                                                      categoryID: categoryID, page: page,
                                                      extend: extend))
    }

    private static func loadList(bundleURL: String, site: CatVodSite, action: String,
                                 categoryID: String, page: Int,
                                 extend: [String: String]) -> CatVodList? {
        let key = listCacheKey(bundleURL: bundleURL, site: site, action: action,
                               categoryID: categoryID, page: page, extend: extend)
        guard let data = CatVodDiskCache.load(key: key) else { return nil }
        return parseList(data: data)
    }

    static func parseList(_ object: [String: Any]) -> CatVodList {
        var categories: [CatVodCategory] = []
        if let classes = object["class"] as? [[String: Any]] {
            for (index, dict) in classes.enumerated() {
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      var category = try? JSONDecoder().decode(CatVodCategory.self, from: data) else { continue }
                // Some sources omit type_id, which would decode to "" and make every
                // category share one identity -> SwiftUI ForEach diffing crash.
                if category.id.isEmpty { category.id = "__cat_\(index)" }
                categories.append(category)
            }
        }
        var media: [CatVodMedia] = []
        if let list = object["list"] as? [[String: Any]] {
            for (index, dict) in list.enumerated() {
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      var item = try? JSONDecoder().decode(CatVodMedia.self, from: data) else { continue }
                // Missing/duplicate vod_id previously collapsed to "" and crashed
                // LazyVGrid with duplicate identities. Guarantee a unique id.
                if item.id.isEmpty { item.id = "__media_\(index)_\(item.name.hashValue)" }
                media.append(item)
            }
        }
        return CatVodList(categories: categories, media: media,
                          page: flexibleInt(object["page"]), pageCount: flexibleInt(object["pagecount"]),
                          filters: CatVodFilterParser.parse(object["filters"]))
    }

    static func flexibleInt(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let s = value as? String, let i = Int(s) { return i }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }
}

extension CatVodError {
    static let parseUnsupported = CatVodError.http(-1, "该线路需要外部解析，换一条线路试试")
    static let emptyPlayerURL = CatVodError.http(-2, "该片源没有返回可播放地址")
    static let unsupportedScheme = CatVodError.http(-3, "该线路是磁力/电驴链接，App 内无法直接播放")
}
