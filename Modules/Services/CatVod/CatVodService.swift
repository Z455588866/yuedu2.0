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

    /// bundle URL 里夹了没转义的空格/控制字符时，网关会下载失败并静默降级成 0 站点，
    /// 界面只剩空白。在触发下载前拦下来，让人一眼知道该改地址而不是怀疑 App 坏了。
    private func validate(bundleURL: String) throws {
        let illegal = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !bundleURL.isEmpty, bundleURL.rangeOfCharacter(from: illegal) == nil else {
            let shown = String(bundleURL.prefix(120))
            throw CatVodError.http(
                -8,
                localized("接口地址无效：含有空格或非法字符（\(shown)）。请把空格改成 %20，或重新复制一个完整的地址")
            )
        }
    }

    /// Loads the site catalog exposed by a CatVod bundle. Starts the engine with this bundle
    /// allowlisted, then asks the gateway for its sites.
    func catalog(bundleURL: String) async throws -> [CatVodSite] {
        try validate(bundleURL: bundleURL)
        let base = try await CatVodGateway.shared.ensureStarted(allowedBundleURL: bundleURL)
        let endpoint = base.appendingPathComponent("/v1/catvod/catalog")
        let object = try await post(endpoint, body: ["bundle": bundleURL])
        // 网关在 bundle 下载/校验/启动/config 失败时会降级返回独立站点，并把真实
        // 原因放进 diagnostic。以前这里完全静默，界面只剩「右边空白」无从排查；
        // 现在把原因写进 App 日志（用户可导出），按接口 URL 与站点数一起打印。
        if let diagnostic = object["diagnostic"] as? String, !diagnostic.isEmpty {
            let jsCount = (object["jsSiteCount"] as? Int) ?? -1
            AppLogger.error(
                "[CatVod] catalog 降级 bundle=\(bundleURL) jsSites=\(jsCount) reason=\(String(diagnostic.prefix(300)))",
                level: .error
            )
        }
        guard let sites = object["sites"] as? [[String: Any]] else {
            AppLogger.info("[CatVod] catalog 结果 bundle=\(bundleURL) 网关未返回 sites 数组", level: .notice)
            return []
        }
        let parsed = sites.compactMap { dict -> CatVodSite? in
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  var site = try? decoder.decode(CatVodSite.self, from: data) else { return nil }
            // `ext` may be a string or an object in the catalog; normalise it to the
            // JSON text the spider expects on every init.
            site.adoptRawExt(dict["ext"])
            return site
        }
        // 每轮都记站点数：成功返回 0 站点（jsSiteCount=0）不产生 diagnostic，
        // 界面只显示「暂无内容」而日志一片安静，无法区分「源没站点」和「本轮加载失败」。
        // 带上 jsSiteCount 与 URL 尾段，导出日志就能定位是哪个源、哪一轮空。
        let jsCount = (object["jsSiteCount"] as? Int) ?? -1
        let tail = bundleURL.split(separator: "/").suffix(2).joined(separator: "/")
        AppLogger.info(
            "[CatVod] catalog 结果 bundle=\(tail) 网关站点=\(sites.count) 解析站点=\(parsed.count) js=\(jsCount)",
            level: .notice
        )
        Self.persistCatalog(parsed, bundleURL: bundleURL)
        return parsed
    }

    /// Live playlists this bundle declares (`lives` in its config). Most JavaScript
    /// spiders have none — an empty array means "no live", not an error.
    func liveSources(bundleURL: String) async throws -> [CatVodLiveSource] {
        let base = try await CatVodGateway.shared.ensureStarted(allowedBundleURL: bundleURL)
        let endpoint = base.appendingPathComponent("/v1/catvod/catalog")
        let object = try await post(endpoint, body: ["bundle": bundleURL])
        guard let lives = object["lives"] as? [[String: Any]], !lives.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: lives) else { return [] }
        let sources = (try? decoder.decode([CatVodLiveSource].self, from: data)) ?? []
        if !sources.isEmpty {
            CatVodDiskCache.store(data, key: CatVodDiskCache.key(["lives", bundleURL]))
        }
        return sources
    }

    /// Last launch's live list, so the live screen draws its list before the bundle boots.
    func cachedLiveSources(bundleURL: String) -> [CatVodLiveSource]? {
        guard let data = CatVodDiskCache.load(key: CatVodDiskCache.key(["lives", bundleURL])),
              let sources = try? decoder.decode([CatVodLiveSource].self, from: data),
              !sources.isEmpty else { return nil }
        return sources
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
    func searchAll(bundleURL: String, sites: [CatVodSite], keyword: String,
                   preferring preferredKey: String? = nil) async -> [(CatVodSite, CatVodList)] {
        // 当前站点排第一、支持快搜的排前面：`for await` 是按完成顺序收集的，
        // 而一旦到了时间预算就整批取消。把「最可能立刻回话」的站点放在队首，
        // 决定的是 14 秒里到底能收到几个站点的结果。
        let ordered = sites.filter { $0.searchable != false }.sorted { lhs, rhs in
            if lhs.key == preferredKey { return true }
            if rhs.key == preferredKey { return false }
            return lhs.quickSearch == true && rhs.quickSearch != true
        }
        let targets = ordered
        guard !targets.isEmpty else { return [] }
        // 全源搜索动辄几十上百个站点。实测这批新接口（豆儿/Lee/L佬）里，单个
        // 站点的搜索要 7–17 秒才回话，12 秒的预算会在结果最好的站点回话前就
        // 整批取消——用户看到的"搜不到"其实是搜到了但没等到。改成 28 秒并把
        // 并发提到 10，让更多站点在预算内跑完；先回来的仍然先渲染。
        let maximumConcurrent = 10
        let budget: UInt64 = 28_000_000_000
        let started = DispatchTime.now().uptimeNanoseconds
        return await withTaskGroup(of: (CatVodSite, CatVodList?).self) { group in
            var next = 0
            var collected: [(CatVodSite, CatVodList)] = []
            let seed = min(maximumConcurrent, targets.count)
            while next < seed {
                let site = targets[next]
                next += 1
                group.addTask { [weak self] in
                    guard let self else { return (site, nil) }
                    return (site, try? await self.search(bundleURL: bundleURL, site: site, keyword: keyword))
                }
            }
            for await (site, list) in group {
                if let list, !list.media.isEmpty { collected.append((site, list)) }
                if DispatchTime.now().uptimeNanoseconds - started > budget { break }
                if next < targets.count {
                    let site = targets[next]
                    next += 1
                    group.addTask { [weak self] in
                        guard let self else { return (site, nil) }
                        return (site, try? await self.search(bundleURL: bundleURL, site: site, keyword: keyword))
                    }
                }
            }
            group.cancelAll()
            return collected
        }
    }

    /// Full detail incl. play groups for one media id.
    ///
    /// `expectedName` 用于在「片单/合集」里认回用户点的那一条：片单条目的 detail
    /// 常常一次返回整张片单（几十部电影），以前直接取 `list[0]`，于是点《A》
    /// 打开的却是《B》——封面、简介、剧集全对不上，看起来像"点开就是错的"。
    func detail(bundleURL: String, site: CatVodSite, id: String,
                expectedName: String? = nil) async throws -> CatVodDetailResult {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "detail",
                                      arguments: ["ids": [id]])
        let items = object["list"] as? [[String: Any]] ?? []
        guard !items.isEmpty else { throw CatVodError.emptyResponse }

        let picked = Self.pickItem(items, requestedID: id, expectedName: expectedName)
        guard let first = picked else {
            // 每个条目都和请求的 id/片名对不上：这是一张片单（合集），不是一部片。
            // 报清楚，让 UI 引导去全网搜，而不是拿错片子的剧集去播。
            throw CatVodError.collectionOnly
        }
        guard let data = try? JSONSerialization.data(withJSONObject: first.element),
              let media = try? decoder.decode(CatVodMedia.self, from: data) else {
            throw CatVodError.emptyResponse
        }
        var from = first.element["vod_play_from"] as? String ?? ""
        var playURL = first.element["vod_play_url"] as? String ?? ""
        // 交给 spider 的线路名（不含「·2」这类展示后缀）。
        var spiderFrom = from

        // Some bundles answer in two steps: the first detail returns provider
        // "groups" (七味/盘库/蜗牛 return one entry per 线路) whose ids must be
        // resolved again before any episode exists. Showing only `list[0]` left
        // the sheet with "没有可播放的剧集" while the source was perfectly fine.
        // Resolve up to three of them and merge their play lines.
        if playURL.isEmpty, items.count > 0 {
            var visited: Set<String> = [id]
            var candidates: [(order: Int, id: String)] = []
            // 从用户点中的那一条起步。以前固定 `items.prefix(3)`，按片名命中第 4 条之后
            // 的条目时会拿前面无关片子的线路去解析，选集全对不上。保持原始来源顺序。
            for (order, item) in items.dropFirst(first.index).prefix(3).enumerated() {
                guard let nextID = item["vod_id"] as? String, !nextID.isEmpty,
                      !visited.contains(nextID) else { continue }
                visited.insert(nextID)
                candidates.append((order, nextID))
            }
            // The providers are independent, so asking them one after another just
            // stacks their latencies: opening a detail used to cost up to 3 × 18s
            // before the sheet could show a single episode. Ask together, merge in
            // the original order, and keep the line order the source declared.
            let deeper = await withTaskGroup(of: (Int, String, String)?.self) { group in
                for candidate in candidates {
                    group.addTask { [weak self] in
                        guard let self else { return nil }
                        // 只在 MainActor 里碰 spider 返回的字典，跨任务边界带回来的
                        // 是两个字符串——`[String: Any]` 不是 Sendable，直接返回
                        // 会被编译器拒绝（也确实不该跨隔离域传递）。
                        return await self.playLine(bundleURL: bundleURL, site: site,
                                                   id: candidate.id, order: candidate.order)
                    }
                }
                var hits: [(Int, String, String)] = []
                for await hit in group { if let hit { hits.append(hit) } }
                return hits.sorted { $0.0 < $1.0 }
            }
            var fromParts: [String] = []
            var urlParts: [String] = []
            // 与 fromParts 一一对应的**原始**线路名。展示名可能被加了「·2」后缀，
            // 而 spider 的 `flag` 只认原名，所以两份都要留。
            var originalParts: [String] = []
            var usedFlags = Set<String>()
            for (_, rawFrom, deeperURL) in deeper {
                // 三个 provider 常常返回同一份剧集（只是线路名不同），合并后
                // 选集里就出现三组一模一样的「第1集…第10集」。同一份播放串只留一组。
                guard !urlParts.contains(deeperURL) else { continue }
                let deeperFrom = rawFrom.isEmpty ? "线路\(fromParts.count + 1)" : rawFrom
                // 两条线路可能同名（"量子线路(1)"），重名会让选集合并到同一条里。
                // 注意：这里只改**展示名**，`spiderFlag` 仍是原来的名字——spider 的
                // `flag` 参数只认原名，加了后缀就查不到，表现是点了没反应/一直转圈。
                originalParts.append(deeperFrom)
                var flags = deeperFrom.components(separatedBy: "$$$")
                for index in flags.indices where usedFlags.contains(flags[index]) {
                    flags[index] += " ·\(fromParts.count + index + 1)"
                }
                usedFlags.formUnion(flags)
                fromParts.append(flags.joined(separator: "$$$"))
                urlParts.append(deeperURL)
            }
            if !fromParts.isEmpty {
                from = fromParts.joined(separator: "$$$")
                playURL = urlParts.joined(separator: "$$$")
                spiderFrom = originalParts.joined(separator: "$$$")
            }
        }

        var groups = CatVodPlaylistParser.groups(from: from, playURL: playURL)
        // 把展示名换回原始名：`player` 要的是 spider 认识的那个 flag。
        if spiderFrom != from {
            let originals = spiderFrom.components(separatedBy: "$$$")
            for index in groups.indices where index < originals.count {
                groups[index].spiderFlag = originals[index]
                for episodeIndex in groups[index].episodes.indices {
                    groups[index].episodes[episodeIndex].spiderFlag = originals[index]
                }
            }
        }
        // 线路名换回原始名之后再合并重复组，否则索引会错位、flag 会对到别的线路。
        groups = Self.dedupeGroups(groups)
        // Only the two play columns are stored: the episode list is all the detail
        // sheet needs, and keeping `vod_*` text out of the cache avoids persisting
        // a whole title's metadata for every poster the person taps.
        if !groups.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: ["from": from, "url": playURL,
                                                                  "spiderFrom": spiderFrom]) {
            CatVodDiskCache.store(data, key: Self.detailCacheKey(bundleURL: bundleURL, site: site, id: id))
        }
        return CatVodDetailResult(media: media, groups: groups,
                                  isCollection: first.isFallbackForCollection)
    }

    /// 网盘源常把同一份文件列两遍（`01 [5.03GB]…` 与 `E01 [5.18GB]…`），
    /// 选集里就出现两组一模一样的集数，看着像"错乱"。播放 id 完全一致的两组只留第一组。
    private static func dedupeGroups(_ groups: [CatVodGroup]) -> [CatVodGroup] {
        var kept: [CatVodGroup] = []
        var signatures = Set<String>()
        for group in groups {
            let signature = group.episodes.map(\.playID).joined(separator: "|")
            guard !signature.isEmpty, signatures.insert(signature).inserted else { continue }
            kept.append(group)
        }
        return kept.isEmpty ? groups : kept
    }

    /// 从 detail 返回的条目里认出「用户点的那一条」。
    ///
    /// 三级匹配：`vod_id` 完全一致 → 片名一致 → 只有一条时就用它。都失败说明这是
    /// 片单/合集（一次返回整张片单），返回 nil 让上层走「合集」分支。
    private static func pickItem(_ items: [[String: Any]], requestedID: String,
                                 expectedName: String?) -> (element: [String: Any], index: Int, isFallbackForCollection: Bool)? {
        if let exact = items.enumerated().first(where: { _, item in
            let raw = item["vod_id"]
            if let text = raw as? String { return text == requestedID }
            if let number = raw as? NSNumber { return number.stringValue == requestedID }
            return false
        }) {
            return (exact.element, exact.offset, false)
        }
        if let name = expectedName.map(normalizeTitle) {
            if let sameName = items.enumerated().first(where: { _, item in
                normalizeTitle(item["vod_name"] as? String ?? "") == name
            }) {
                return (sameName.element, sameName.offset, false)
            }
        }
        if items.count == 1, let only = items.first { return (only, 0, false) }
        return nil
    }

    /// 片名归一化：去空白、去「(真彩)」「4K」这类后缀噪音，用来比对同一条目。
    static func normalizeTitle(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for noise in ["（", "(", "[", "【"] {
            if let range = text.range(of: noise) { text = String(text[text.startIndex..<range.lowerBound]) }
        }
        return text.replacingOccurrences(of: " ", with: "")
    }

    /// 追一层 provider，只把「线路名 + 播放串」这对纯字符串交出去。
    /// spider 的原始字典留在 MainActor 内解析，不跨任务边界。
    private func playLine(bundleURL: String, site: CatVodSite, id: String,
                          order: Int) async -> (Int, String, String)? {
        guard let response = try? await invoke(bundleURL: bundleURL, site: site, action: "detail",
                                               arguments: ["ids": [id]]),
              let first = (response["list"] as? [[String: Any]])?.first,
              let url = first["vod_play_url"] as? String, !url.isEmpty else { return nil }
        return (order, first["vod_play_from"] as? String ?? "", url)
    }

    /// Episode list from a previous visit, so re-opening a title shows its
    /// episodes on the first frame instead of the "正在加载剧集…" placeholder.
    func cachedDetail(bundleURL: String, site: CatVodSite, id: String) -> [CatVodGroup]? {
        let key = Self.detailCacheKey(bundleURL: bundleURL, site: site, id: id)
        guard let data = CatVodDiskCache.load(key: key),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let from = object["from"], let playURL = object["url"] else { return nil }
        var groups = CatVodPlaylistParser.groups(from: from, playURL: playURL)
        if let spiderFrom = object["spiderFrom"], spiderFrom != from {
            let originals = spiderFrom.components(separatedBy: "$$$")
            for index in groups.indices where index < originals.count {
                groups[index].spiderFlag = originals[index]
                for episodeIndex in groups[index].episodes.indices {
                    groups[index].episodes[episodeIndex].spiderFlag = originals[index]
                }
            }
        }
        return groups.isEmpty ? nil : groups
    }

    /// Resolves a spider episode id to a stream URL + headers. Mirrors tvbox-silicon's
    /// `resolvePlayback` routing: direct media plays as-is; `json:`/`parse:` payloads
    /// and `parse/jx == 1` need an external parser; netdisk shares are resolved by
    /// the trusted gateway (which holds the account credentials).
    func player(bundleURL: String, site: CatVodSite, episode: CatVodEpisode) async throws -> CatVodPlayback {
        // 网盘线路先认描述符再决定要不要打 spider：
        // - 支持名单见 CatVodNetdiskEpisode.supported（覆盖网关能处理的各家网盘
        //   及直链线路），都由网关 catvod-cloud-player.mjs 解析，不交给 spider
        //   访问分享页（那样会在网盘留下「查看记录」还白等超时）；
        // - 名单外的线路当场说清楚，让用户换普通线路。
        let netdisk = CatVodNetdiskEpisode.descriptor(from: episode.playID)
        if let netdisk {
            AppLogger.info("[CatVod] ⟐ netdisk episode provider=\(netdisk.provider) site=\(site.key)", level: .notice)
            if !CatVodNetdiskEpisode.isSupported(netdisk.provider) {
                AppLogger.error("[CatVod] netdisk provider unsupported=\(netdisk.provider)", level: .error)
                throw CatVodError.http(-5, String(
                    format: localized("这条是%@线路，App 内暂时不能直接播放。换一条普通线路，或用夸克网盘线路。"),
                    CatVodNetdiskEpisode.displayName(netdisk.provider)))
            }
        }
        // 网盘线路要验提取码、列目录、取直链（百度还要先 m3u8 再退回 dlink），
        // 网关分段各 20 秒；40 秒会在它回话前就超时。只对网盘放宽到 90 秒，
        // 普通线路仍用 40 秒，不影响它们的响应速度。
        let timeout: TimeInterval = netdisk != nil ? 90 : 40
        let object: [String: Any]
        do {
            object = try await invoke(bundleURL: bundleURL, site: site, action: "player",
                                      arguments: [
                                        // 只认 spider 声明的原始线路名；`groupName` 是
                                        // 展示用的（重名时加了「·2」后缀），传过去查不到线路。
                                        "flag": episode.spiderFlag,
                                        "id": episode.playID,
                                        "vipFlags": [String]()
                                      ],
                                      timeout: timeout)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw CatVodError.http(-7, String(
                format: localized("解析这一集的播放地址超过 %d 秒，源站没有回话。换一条线路，或稍后再试"),
                Int(timeout)))
        }
        var headers: [String: String] = [:]
        if let header = object["header"] as? [String: Any] {
            for (k, v) in header {
                if let s = v as? String { headers[k] = s }
                else { headers[k] = "\(v)" }
            }
        }
        var parse = Self.flexibleInt(object["parse"])
        var jx = Self.flexibleInt(object["jx"])
        // TVBox Python 音乐插件的显式标记：默认 audio，覆盖 URL 猜不出扩展名的情况。
        let musicPlayer = Self.flexibleInt(object["music_player"]) == 1
            || (object["music_player"] as? Bool) == true
        let rawURL = Self.firstURL(object["url"])
        // 网盘线路会带清晰度与降级说明：哪些档位真的能播、当前用的是哪一档。
        // 以前这两个字段被丢掉，用户只能看到「画面很糊」却没有任何解释。
        let playbackNotice = object["playbackNotice"] as? String
        let qualityName = object["quality"] as? String
        let qualityChoices = Self.qualityOptions(object["qualityOptions"])
        // 片源自带弹幕（红果这类）。放在这里解析，是因为下面每一条返回路径都要把它带上：
        // 切清晰度、parse=1 嗅探都会重建 `CatVodPlayback`，漏一处弹幕就没了。
        // 带上 bundle 身份：弹幕地址若是插件进程的 loopback，加载器据此把它改写成
        // 网关代理，避免临时端口回收后取不到弹幕（红果 /hg_dm 就是这种情况）。
        var danmakuWithContext = Self.danmakuPayload(object["danmaku"])
        danmakuWithContext?.bundleURL = bundleURL
        let danmakuPayload = danmakuWithContext

        // A spider may hand back an episode id that is itself a direct media URL.
        // The runner already normalises this, but keep a fallback for gateways that
        // return `url` empty with `parse=0`.
        let resolvedURL: String
        if rawURL.isEmpty {
            // 网盘/聚合源的播放地址常在 url 以外的字段。先把整个响应扫一遍，
            // 再退回 episode 自带的直链；都拿不到才报错，并留下诊断线索。
            let recovered = Self.recoverPlayerURL(from: object)
            if !recovered.isEmpty {
                resolvedURL = recovered
                // 从 qualityOptions/values 取到的已是直链，源站却常同时带 parse=1 /
                // jx=1（意思是「url  needs parsing」）。直链不需要再嗅探，否则会把
                // 一个能播的地址丢去做二次解析然后失败。FongMi 的 setDirect() 同理。
                if recovered.hasPrefix("http://") || recovered.hasPrefix("https://") {
                    parse = 0
                    jx = 0
                }
            } else if parse == 0, jx == 0, Self.isDirectMedia(episode.playID) {
                resolvedURL = episode.playID
            } else {
                // 只记键名和 parse 标记，不记值（值里可能有 share token）。
                let keys = object.keys.sorted().joined(separator: ",")
                AppLogger.error("[CatVod] player empty url site=\(site.key) parse=\(parse) jx=\(jx) keys=[\(keys)] qualityOptions=\(qualityChoices.count)", level: .error)
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
                // 嗅探拿到的直链同样要带默认防盗链头；否则原生听书接过去会静默失败。
                var sniffHeaders = headers
                if sniffHeaders["User-Agent"] == nil, sniffHeaders["user-agent"] == nil {
                    sniffHeaders["User-Agent"] =
                        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
                }
                if sniffHeaders["Referer"] == nil, sniffHeaders["referer"] == nil,
                   let scheme = sniffed.scheme, let host = sniffed.host {
                    sniffHeaders["Referer"] = "\(scheme)://\(host)/"
                }
                return Self.proxiedPlayback(url: sniffed, headers: sniffHeaders, bundleURL: bundleURL,
                                            originalURL: sniffed.absoluteString,
                                            originalHeader: sniffHeaders,
                                            musicPlayer: musicPlayer,
                                            danmaku: danmakuPayload,
                                            notice: playbackNotice)
            }
            throw CatVodError.parseUnsupported
        }
        // Magnet / thunder links are not playable in an in-app video player.
        if resolvedURL.hasPrefix("magnet:") || resolvedURL.hasPrefix("thunder:")
            || resolvedURL.hasPrefix("ed2k:") {
            throw CatVodError.unsupportedScheme
        }
        // 网盘「分享页」不是媒体流：AVPlayer 打开它只会黑屏/转圈。源站经常把
        // 分享链接直接当播放地址返回，必须认出来并说明白，否则就是无限转圈。
        if Self.isNetdiskSharePage(resolvedURL) {
            let shareHost = URL(string: resolvedURL)?.host ?? "?"
            AppLogger.error("[CatVod] netdisk share page used as play url host=\(shareHost)", level: .error)
            throw CatVodError.http(-6, localized("这条线路给的是网盘分享页，不是可播放的视频流。换一条线路，或先把分享转存到自己的网盘再播放。"))
        }

        // 网盘线路常把中文文件名/空格直接拼进 URL（录屏里的「4K AAC2026...」），
        // URL(string:) 遇到未编码的中文/空格会返回 nil，于是 player ok 之后抛
        // emptyPlayerURL——表现就是点了没反应。按 RFC 3986 对非法字符做百分号
        // 编码后再解析；结构符（:/?#[]@!$&'()*+,;=%）原样保留，避免破坏 query。
        let finalURL: URL
        if let direct = URL(string: resolvedURL), direct.scheme != nil {
            finalURL = direct
        } else if let encoded = Self.percentEncodeURL(resolvedURL),
                  let recovered = URL(string: encoded), recovered.scheme != nil {
            finalURL = recovered
        } else {
            AppLogger.error("[CatVod] player url 无法解析 site=\(site.key) raw=\(resolvedURL.prefix(120))", level: .error)
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
        return Self.proxiedPlayback(url: finalURL, headers: finalHeaders, bundleURL: bundleURL,
                                    originalURL: finalURL.absoluteString,
                                    originalHeader: finalHeaders,
                                    musicPlayer: musicPlayer,
                                    quality: qualityName, options: qualityChoices,
                                    danmaku: danmakuPayload,
                                    notice: playbackNotice)
    }

    /// Single place that hands a stream to the player.
    ///
    /// The gateway proxy is the only consumer that keeps the bundle's loopback
    /// port alive and re-sends Referer/Cookie/UA on every redirect and HLS
    /// segment — AVFoundation itself drops them, which is exactly the 403/404
    /// pair this app used to show on 网盘 lines. When the proxy is unavailable
    /// (engine not up) the raw URL still plays, so behaviour degrades instead of
    /// breaking.
    private static func proxiedPlayback(url: URL, headers: [String: String],
                                        bundleURL: String,
                                        originalURL: String? = nil,
                                        originalHeader: [String: String]? = nil,
                                        musicPlayer: Bool = false,
                                        quality: String? = nil,
                                        options: [CatVodQualityOption] = [],
                                        danmaku: CatVodDanmakuPayload? = nil,
                                        notice: String? = nil) -> CatVodPlayback {
        // Record scheme + host only — playback URLs routinely carry share tokens
        // and signatures in the query, which must never reach an exported log.
        AppLogger.info("[CatVod] ⟐ playback url=\(url.scheme ?? "?")://\(url.host ?? "?") path=\(url.pathExtension) headers=\(headers.count) danmaku=\(danmaku != nil)", level: .notice)
        // 每一档都要走同一个代理：转码地址同样校验 Referer/Cookie，直接把原始
        // CDN 地址交给 AVPlayer 会 403。代理不可用时退回原地址。
        let proxiedOptions: [CatVodQualityOption] = options.map { option in
            var copy = option
            if let raw = URL(string: option.url),
               let proxied = CatVodGateway.shared.playbackProxyURL(for: raw, bundleURL: bundleURL,
                                                                   headers: headers) {
                copy.url = proxied.absoluteString
            }
            return copy
        }
        if let proxied = CatVodGateway.shared.playbackProxyURL(for: url, bundleURL: bundleURL,
                                                               headers: headers) {
            return CatVodPlayback(parse: 0, url: proxied.absoluteString, header: [:],
                                  quality: quality,
                                  qualityOptions: proxiedOptions.isEmpty ? nil : proxiedOptions,
                                  playbackNotice: notice,
                                  danmaku: danmaku,
                                  originalURL: originalURL ?? url.absoluteString,
                                  originalHeader: originalHeader ?? headers,
                                  musicPlayer: musicPlayer)
        }
        return CatVodPlayback(parse: 0, url: url.absoluteString, header: headers,
                              quality: quality,
                              qualityOptions: proxiedOptions.isEmpty ? nil : proxiedOptions,
                              playbackNotice: notice,
                              danmaku: danmaku,
                              originalURL: originalURL ?? url.absoluteString,
                              originalHeader: originalHeader ?? headers,
                              musicPlayer: musicPlayer)
    }

    /// `playerContent.danmaku` 既可能是行数组，也可能是一个地址（B 站 XML）。
    /// 解不出来就返回 nil：弹幕坏了不能连带把能播的片子变成不能播。
    private static func danmakuPayload(_ value: Any?) -> CatVodDanmakuPayload? {
        guard let value else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : CatVodDanmakuPayload(link: trimmed)
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(CatVodDanmakuPayload.self, from: data)
    }

    /// 网关的清晰度列表解码成模型；字段缺失或类型异常时返回空表而不是抛错——
    /// 播放地址才是必需项，清晰度只是附加信息。
    private static func qualityOptions(_ value: Any?) -> [CatVodQualityOption] {        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String, !name.isEmpty,
                  let url = entry["url"] as? String, !url.isEmpty else { return nil }
            return CatVodQualityOption(
                name: name,
                url: url,
                width: Self.flexibleInt(entry["width"]),
                height: Self.flexibleInt(entry["height"]),
                bitrate: Self.flexibleInt(entry["bitrate"]))
        }
    }

    /// 判断一个字符串是否真的是可播放地址，而不是线路名/清晰度名。
    ///
    /// 实测多多等网盘源：`player` 结果的 `url` 字段可能是「代理」「高清 720P」
    /// 这类线路名文字，真地址在 `qualityOptions[{name,url}]` 里。旧代码把线路名
    /// 当 URL 解析，日志就是 `player url 无法解析 raw=代理`，然后抛「没有可播放
    /// 地址」——其实走不到下面已经写好的清晰度选择窗。FongMi/TV 的 `Url` 把
    /// 名称(n)和地址(v)分开、只把 v 当地址（getRealUrl），这里对齐同一语义。
    private static func isPlayableAddress(_ value: String) -> Bool {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return false }
        if s.contains("://") || s.hasPrefix("parse:") || s.hasPrefix("json:")
            || s.hasPrefix("magnet:") || s.hasPrefix("thunder:")
            || s.hasPrefix("ed2k:") { return true }
        return isDirectMedia(s)
    }

    private static func firstURL(_ value: Any?) -> String {
        if let s = value as? String { return isPlayableAddress(s) ? s : "" }
        if let arr = value as? [String] {
            return arr.first(where: { isPlayableAddress($0) }) ?? ""
        }
        // TVBox 各家 spider 的 player 返回字段不统一：`url` 有时是
        // `{url, playUrl, links}` 的字典，或嵌在 `data` 里。结果网关拿到的
        // `url` 是空串，App 就抛「没有可播放地址」，表现是网盘线路点了没反应。
        if let dict = value as? [String: Any] {
            for key in ["url", "playUrl", "play_url", "m3u8", "link", "links"] {
                let found = firstURL(dict[key])
                if !found.isEmpty { return found }
            }
        }
        return ""
    }

    /// 把网盘 spider 给的「带中文/空格的原始 URL」编码成合法 URL。
    /// 逐字符处理：已有 `%XX` 转义、scheme/分隔符、查询结构符全部保留，只对
    /// 真正的非法字符（中文、空格、控制符等）按 UTF-8 做 `%XX` 编码。
    private static func percentEncodeURL(_ raw: String) -> String? {
        // RFC 3986 保留字符 + 已在使用的 % 都原样放过。
        let allowed = CharacterSet(charactersIn: ":/?#[]@!$&'()*+,;=%-._~")
        var out = ""
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) || (scalar.value >= 0x21 && scalar.value <= 0x7E) {
                out.unicodeScalars.append(scalar)
            } else if let utf8 = String(scalar).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                out += utf8
            } else {
                return nil
            }
        }
        return out
    }

    /// player 返回空 url 时，从整个响应里再找一遍可播地址。网盘/聚合源的字段
    /// 位置和普通源不同，不能只看 `url` 一个键就判死。键名做白名单，避免把
    /// `header`/`danmaku` 之类误当成地址。
    private static func recoverPlayerURL(from object: [String: Any]) -> String {
        // 网盘多档位：url 字段常是线路名/清晰度名（"代理"、"高清 720P"），
        // 真地址在 qualityOptions[{name,url}]。FongMi 的 Result 把名称与地址
        // 分开、只把地址交给播放器，这里优先取档位里的真实地址。
        var containers: [[String: Any]] = [object]
        if let data = object["data"] as? [String: Any] { containers.append(data) }
        for container in containers {
            if let options = container["qualityOptions"] as? [[String: Any]] {
                for option in options {
                    if let url = option["url"] as? String, isPlayableAddress(url) { return url }
                }
            }
            // 名称/地址对数组：[{name,v}...] 或 [[name,url],...]（FongMi Url.values）
            if let values = container["values"] as? [[String: Any]] {
                for entry in values {
                    if let url = entry["v"] as? String, isPlayableAddress(url) { return url }
                    if let url = entry["url"] as? String, isPlayableAddress(url) { return url }
                }
            }
        }
        let keys = ["url", "playUrl", "play_url", "m3u8", "link", "links", "vod_play_url"]
        for key in keys {
            let found = firstURL(object[key])
            if found.hasPrefix("http://") || found.hasPrefix("https://") { return found }
        }
        if let data = object["data"] as? [String: Any] {
            for key in keys {
                let found = firstURL(data[key])
                if found.hasPrefix("http://") || found.hasPrefix("https://") { return found }
            }
        }
        return ""
    }

    private static func isDirectMedia(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return [".mp4", ".m3u8", ".mkv", ".avi", ".mov", ".flv", ".ts", ".mp3", ".m4a"]
            .contains { lowered.contains($0) }
    }

    /// `https://pan.baidu.com/s/xxx`、`https://pan.quark.cn/s/xxx` 这类是分享页，
    /// 不是视频。真流量的路径长成 `/file/xxx.mp4`、`play.m3u8` 或带签名参数的 CDN 地址。
    private static func isNetdiskSharePage(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased() else { return false }
        let shareHosts = ["pan.baidu.com", "pan.quark.cn", "drive.uc.cn", "fast.uc.cn",
                          "www.aliyundrive.com", "www.alipan.com", "115.com", "115cdn.com",
                          "www.123pan.com", "www.123684.com", "www.123865.com"]
        guard shareHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return false }
        let path = url.path.lowercased()
        return path.hasPrefix("/s/") || path == "/s" || path.hasPrefix("/share/")
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

    // MARK: - Cookie 池

    /// bundle -> 上次灌 cookie 的时间。刷得太勤等于每个请求都多一次 IPC，
    /// 5 分钟一次足够覆盖「用户在浏览器里刚登录完就回来播放」这条路径。
    private var cookieSeededAt: [String: Date] = [:]
    private let cookieSeedingLock = NSLock()

    private func shouldSeedCookies(_ bundleURL: String) -> Bool {
        cookieSeedingLock.lock()
        defer { cookieSeedingLock.unlock() }
        let now = Date()
        if let last = cookieSeededAt[bundleURL], now.timeIntervalSince(last) < 300 { return false }
        cookieSeededAt[bundleURL] = now
        return true
    }

    /// 把 WKWebView 的 cookie 交给 bundle 的 Cookie 池。
    ///
    /// 只按 domain 传，不按 url：WKWebView 里 `pan.quark.cn` 的 cookie 属于
    /// `.quark.cn`，按 url 存会变成 host-only，spider 访问 `drive-pc.quark.cn`
    /// 时又拿不到——正是「登录过但取链说没登录」的成因。
    private func seedCookies(bundleURL: String) async {
        let cookies = await WebViewCookieMirror.shared.allCookies()
        guard !cookies.isEmpty else { return }
        // 只传还没过期的，并限个数：整个 WKWebView jar 可能有几千条，灌给
        // 一个 bundle 既慢也没意义。
        let now = Date()
        let items: [[String: String]] = cookies.prefix(200).compactMap { cookie in
            guard !cookie.name.isEmpty, !cookie.domain.isEmpty,
                  cookie.expiresDate.map({ $0 > now }) ?? true else { return nil }
            return ["domain": cookie.domain, "cookie": "\(cookie.name)=\(cookie.value)"]
        }
        guard !items.isEmpty else { return }
        await CatVodGateway.shared.pushCookies(bundleURL: bundleURL, items: items)
    }

    private func invoke(bundleURL: String, site: CatVodSite, action: String,
                        arguments: [String: Any],
                        timeout: TimeInterval = 50) async throws -> [String: Any] {
        // Every spider action (home/category/detail/player/search…) funnels through
        // here. Log action + site + duration so a later exported log can show which
        // step actually failed — previously these all failed silently into the UI.
        // Keep the success line to the few actions a person actually triggers by hand;
        // bulk refreshes must not eat the 6000-line export window.
        let startedAt = Date()
        do {
            let base = try await CatVodGateway.shared.ensureStarted(allowedBundleURL: bundleURL)
            // WebView 里登录/过挑战拿到的 cookie，先灌进 bundle 的 Cookie 池，
            // 否则同一个站点在浏览器里是登录态、在 spider 里是游客态。
            if shouldSeedCookies(bundleURL) {
                await seedCookies(bundleURL: bundleURL)
            }
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
            let result = try await post(endpoint, body: body, timeout: timeout)
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            if ["catalog", "home", "category", "detail", "player", "search"].contains(action) {
                // site.key is an identifier, never a credential; api/arguments are
                // deliberately omitted — they can carry tokens and share links.
                AppLogger.info("[CatVod] ⟐ action=\(action) ok site=\(site.key) ms=\(elapsedMs)", level: .notice)
            }
            return result
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            // The concrete cause (HTTP status + upstream text) is logged in postOnce;
            // this line adds the action/site context and covers non-HTTP failures
            // such as timeouts that never reach postOnce's status guard.
            AppLogger.error("[CatVod] action=\(action) failed site=\(site.key) ms=\(elapsedMs)", error: error)
            throw error
        }
    }

    private func post(_ endpoint: URL, body: [String: Any],
                      timeout: TimeInterval = 50) async throws -> [String: Any] {
        // A spider session can be reclaimed while the app is backgrounded or idle.
        // The gateway rebuilds it on demand, so one automatic retry turns a
        // transient "CatVod stopped" 502 into a seamless success.
        do {
            return try await postOnce(endpoint, body: body, timeout: timeout)
        } catch let error as CatVodError {
            if case .http(let status, let message) = error,
               status == 502,
               message.localizedCaseInsensitiveContains("stopped")
                || message.localizedCaseInsensitiveContains("exited") {
                return try await postOnce(endpoint, body: body, timeout: timeout)
            }
            throw error
        }
    }

    private func postOnce(_ endpoint: URL, body: [String: Any],
                          timeout: TimeInterval = 50) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The embedded gateway is started with a per-launch token and rejects every
        // request without `Authorization: Bearer <token>` (401). Send the same token
        // the gateway was configured with.
        request.setValue("Bearer \(CatVodGateway.shared.authenticationToken)",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        // 50s is only the outer ceiling: the runner enforces its own per-action
        // budgets (home/category 20s, detail/search 25s, play 30s) and always
        // answers first, so this never cuts off a working source. The old 150s
        // only meant a dead source spun for two and a half minutes before failing.
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            let serverMessage = payload?["message"] as? String
            // The gateway may attach a short diagnostic (bundle stderr tail, error
            // code). Print it verbatim next to the status — this is the text that
            // used to exist only in the UI toast and vanish from every log.
            let diagnostic = payload?["diagnostic"] as? String
            let rawMessage = String(data: data, encoding: .utf8).map { String($0.prefix(120)) } ?? ""
            AppLogger.error(
                "[CatVod] gateway error status=\(status) message=\(String((serverMessage ?? rawMessage).prefix(200)))"
                    + (diagnostic.map { " diagnostic=\(String($0.prefix(200)))" } ?? ""),
                level: .error
            )
            throw CatVodError.http(status, serverMessage ?? rawMessage)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.error("[CatVod] gateway returned a non-object response status=\(status)", level: .error)
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
    /// detail 回的是整张片单（合集），里面没有用户点的那一条。
    static let collectionOnly = CatVodError.http(-4, "这一条是片单/合集，需要按片名重新搜索")
}

/// `detail` 的结果。`isCollection` 让 UI 能把「片单/合集」和「真的没有剧集」分开说。
struct CatVodDetailResult: Sendable {
    var media: CatVodMedia
    var groups: [CatVodGroup]
    var isCollection: Bool
}
