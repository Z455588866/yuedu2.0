import SwiftUI
import UIKit

/// Route for the CatVod standalone home, pushed from 探索's 猫元 button. Separate from
/// `ExploreNavigationRoute` so the complex hand-written ==/hash there need not change.
struct CatVodHomeRoute: Hashable {}

/// The "猫元" page: picks an imported interface + one of its sites, then browses categories,
/// search and detail in a poster grid, reusing the app's full-screen player for playback.
struct CatVodHomeView: View {
    @State private var store = CatVodSourceStore.shared
    @State private var selectedSourceID: String?
    @State private var sites: [CatVodSite] = []
    @State private var selectedSite: CatVodSite?
    @State private var list: CatVodList = CatVodList(categories: [], media: [], page: 1, pageCount: 1)
    @State private var currentCategory: CatVodCategory?
    @State private var keyword = ""
    @State private var isLoading = false
    @State private var message: String?
    @State private var detailItem: CatVodMedia?
    @State private var detailGroups: [CatVodGroup] = []
    /// The source answered the detail request with nothing (豆瓣-style rows carry a
    /// poster and a rating but no episode list). Shown inside the sheet instead of
    /// closing it — a sheet that disappears on its own reads as a crash.
    @State private var detailMissing = false
    /// Filter groups from the last `home` response, keyed by category id. Kept
    /// separately from `list` because `category` responses do not carry filters.
    @State private var allFilters: [String: [CatVodFilter]] = [:]
    /// Chosen filter values for the current category, keyed by filter key.
    @State private var filterChoices: [String: String] = [:]
    /// Reverse episode order within every group (影匣's 倒序 switch).
    @State private var episodesReversed = false
    @State private var searchHistory: [String] = []
    /// Monotonic token: every load bumps it, and stale responses (from a source
    /// the person already switched away from) are discarded. Prevents the
    /// endless spinner and wrong-list flashes caused by racing requests.
    @State private var loadToken = 0
    /// 搜索独立计次：首页/分类完成时不能作废一次正在进行的搜索。
    @State private var searchToken = 0
    /// 点搜索时先收起键盘：不然键盘挡住结果区，看着就像没搜。
    @FocusState private var searchFocused: Bool
    /// Guards a poster tap while its detail request is in flight: without it a
    /// burst of taps queues a burst of requests, and when they all land they
    /// stack a dozen detail sheets on top of each other.
    @State private var isOpeningDetail = false
    /// Same guard for episode taps — a slow `player` resolve must not let a
    /// dozen taps each present a player the moment they finally answer.
    @State private var isResolvingPlayback = false
    /// True while the detail sheet is open but its episode list is still loading.
    /// The sheet is presented on the tap itself (see `openDetail`), so this is
    /// what the sheet shows instead of an empty "no episodes" state.
    @State private var isLoadingDetail = false
    /// Which episode tile is being resolved right now, so that tile shows a
    /// spinner instead of looking dead for the length of a slow `player` call.
    @State private var playingEpisodeID: String?
    /// Episode lists already fetched, keyed by source + media id. Re-opening a
    /// title the person just looked at becomes instant.
    @State private var detailCache: [String: [CatVodGroup]] = [:]
    /// Which site the currently open detail page belongs to. Search results span
    /// every site in the interface, so a tap must remember the site that actually
    /// produced that title — otherwise detail/episode requests hit the wrong one.
    @State private var detailSite: CatVodSite?
    /// media id → the site it came from, for search results only.
    @State private var resultSites: [String: CatVodSite] = [:]

    private var sources: [CatVodSource] { store.enabledSources }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 104), spacing: 12)]
    }

    private static let searchHistoryKey = "yd_catvod_search_history"

    private var currentFilters: [CatVodFilter] {
        guard let category = currentCategory else { return [] }
        return allFilters[category.id] ?? []
    }

    /// Names that mean "the home page" in the feeds we have seen. A source's own
    /// class list usually starts with one of these, and drawing it next to our
    /// pinned 推荐 chip is what put the same chip on screen twice.
    private static let homeCategoryNames: Set<String> = [
        "推荐", "首页", "精选", "推荐片单", "热门推荐",
    ]

    /// Class list with the pinned home chip removed and repeated names collapsed.
    /// Feeds routinely ship 「最近更新」 twice (once per provider), and a duplicate
    /// name means a duplicate chip that scrolls to nowhere.
    private var displayCategories: [CatVodCategory] {
        var seen = Set<String>()
        return list.categories.filter { category in
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !Self.homeCategoryNames.contains(name) else { return false }
            return seen.insert(name).inserted
        }
    }

    var body: some View {
        Group {
            if sources.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(localized("猫元"))
        .navigationBarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .task {
            loadSearchHistory()
            if selectedSourceID == nil { selectedSourceID = sources.first?.id }
        }
        .sheet(item: $detailItem, onDismiss: {
            isLoadingDetail = false
            playingEpisodeID = nil
            // A sheet swiped away mid-request must not leave the tap guard armed:
            // otherwise a 150s resolve keeps the grid refusing every tap.
            isOpeningDetail = false
        }) { item in detailSheet(item) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    CatVodSourceSettingsView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(localized("管理猫源"))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.and.hifispeaker.fill")
                .font(.system(size: 44))
                .foregroundStyle(DSColor.textSecondary)
            Text(localized("还没有可用的猫源"))
                .font(DSFont.headline)
            Text(localized("到「模组 → 猫源」导入接口后，就能在这里浏览。"))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Picker header

    private var sourcePicker: some View {
        HStack(spacing: 10) {
            Picker(localized("接口"), selection: Binding(
                get: { selectedSourceID ?? sources.first?.id ?? "" },
                set: { selectedSourceID = $0 }
            )) {
                ForEach(sources) { source in
                    Text(source.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(source.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)

            if sites.count > 1 {
                Picker(localized("站点"), selection: Binding(
                    get: { selectedSite?.key ?? sites.first?.key ?? "" },
                    set: { key in
                        selectedSite = sites.first { $0.key == key }
                        Task { await loadHome() }
                    }
                )) {
                    ForEach(sites) { site in Text(site.name).tag(site.key) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: selectedSourceID) { _, _ in Task { await loadCatalogAndHome() } }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(localized("搜索全部站点片名"), text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { Task { await search() } }
                Button { Task { await search() } } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !searchHistory.isEmpty && keyword.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(DSFont.caption2)
                            .foregroundStyle(DSColor.textSecondary)
                        ForEach(searchHistory, id: \.self) { term in
                            Button {
                                keyword = term
                                Task { await search() }
                            } label: {
                                Text(term)
                                    .font(DSFont.caption2)
                                    .foregroundStyle(DSColor.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(DSColor.surfaceTertiary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(title: localized("推荐"), selected: currentCategory == nil) {
                    currentCategory = nil
                    Task { await loadHome() }
                }
                ForEach(Array(displayCategories.enumerated()), id: \.offset) { _, category in
                    categoryChip(title: category.name, selected: currentCategory?.id == category.id) {
                        currentCategory = category
                        filterChoices = [:]
                        Task { await loadCategory(category) }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    /// Filter chip row shown under the category bar when the current category
    /// declares filters. Selecting a value reloads the category with `extend`.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(currentFilters.enumerated()), id: \.offset) { _, filter in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(filter.name)
                        .font(DSFont.caption2.weight(.semibold))
                        .foregroundStyle(DSColor.textSecondary)
                        .frame(width: 44, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(filter.options.enumerated()), id: \.offset) { _, option in
                                let selected = (filterChoices[filter.key] ?? "") == option.value
                                Button {
                                    var choices = filterChoices
                                    if option.value.isEmpty { choices[filter.key] = nil }
                                    else { choices[filter.key] = option.value }
                                    filterChoices = choices
                                    if let category = currentCategory {
                                        Task { await loadCategory(category) }
                                    }
                                } label: {
                                    Text(option.name)
                                        .font(DSFont.caption2)
                                        .foregroundStyle(selected ? Color.white : DSColor.textPrimary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(selected ? Color.accentColor : DSColor.surfaceTertiary,
                                                    in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private func categoryChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DSFont.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : DSColor.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Color.accentColor : DSColor.surfaceTertiary,
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sourcePicker
                searchBar

                // Category and filter chips live outside the grid branch on
                // purpose: an empty 推荐 page used to hide the whole category
                // bar, so a source whose home is blank could never be browsed
                // at all — exactly the "暂无内容 and nothing else" screen.
                if !list.categories.isEmpty { categoryBar }
                if !currentFilters.isEmpty { filterBar }

                if isLoading && list.media.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 40)
                } else if list.media.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 36))
                            .foregroundStyle(DSColor.textSecondary)
                        Text(localized("暂无内容")).font(DSFont.subheadline)
                        // An empty page is not always a dead end: netdisk/Alist
                        // sources answer nothing until an account is configured,
                        // and a slow source can simply have timed out. Say which
                        // case it is instead of leaving a blank grid.
                        Text(message ?? localized("这个分类没有返回内容。换一个分类，或点重试再看看。"))
                            .font(DSFont.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        if message == nil {
                            Text(localized("网盘或 Alist 站点需要先在「管理猫源 → 网盘账号」里登录。"))
                                .font(DSFont.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        HStack(spacing: 12) {
                            Button {
                                Task { await reloadCurrent() }
                            } label: {
                                Text(localized("重试")).font(DSFont.caption)
                            }
                            .buttonStyle(.bordered)
                            NavigationLink {
                                CatVodSourceSettingsView()
                            } label: {
                                Text(localized("管理猫源")).font(DSFont.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        // Position identity: even if a source returns duplicate/empty
                        // vod_id, SwiftUI never crashes on duplicate Identifiable ids.
                        ForEach(Array(list.media.enumerated()), id: \.offset) { _, item in
                            Button { if !isOpeningDetail { Task { await openDetail(item, from: resultSites[item.id]) } } } label: {
                                CatVodPosterCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)

                    if list.page < list.pageCount {
                        Button { Task { await loadMore() } } label: {
                            if isLoading { ProgressView() }
                            else { Text(localized("加载更多")).font(DSFont.subheadline) }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical)
                    }
                }

                if let message, !list.media.isEmpty {
                    Text(message).font(DSFont.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .padding(.top, 8)
        }
        // The inline navigation bar is translucent, so a grid that starts flush with the
        // scroll view's top edge has its first row of posters half under the title. An
        // explicit content margin keeps that row readable while still letting the posters
        // scroll under the bar afterwards.
        .contentMargins(.top, 6, for: .scrollContent)
        .refreshable { await loadHome() }
        .task {
            await loadCatalogAndHome()
            warmUpOtherSources()
        }
    }

    /// Boots the other enabled interfaces while the person is reading the current
    /// one — the same thing the CatVod shells do by keeping every spider loaded.
    ///
    /// A cold source costs download + compile + process boot before it returns a
    /// single item, and paying that on tap is the 3–8s wait. Two lanes, four
    /// interfaces max: each session holds a 256MB heap and the app has to stay
    /// inside the jetsam budget, so this is deliberately not a fan-out.
    private func warmUpOtherSources() {
        let current = selectedSourceID
        let targets = Array(sources.filter { $0.id != current }.map(\.url).prefix(2))
        guard !targets.isEmpty else { return }
        Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for lane in 0..<2 {
                    group.addTask {
                        for (index, url) in targets.enumerated() where index % 2 == lane {
                            await Self.warmInterface(url)
                        }
                    }
                }
            }
        }
    }

    private static func warmInterface(_ bundleURL: String) async {
        guard await CatVodService.shared.claimWarmUp(bundleURL: bundleURL) else { return }
        guard let sites = try? await CatVodService.shared.catalog(bundleURL: bundleURL),
              let first = sites.first else {
            // A transient failure should not burn the one attempt this interface
            // gets; the next visit to 猫元 can try again.
            await CatVodService.shared.releaseWarmUp(bundleURL: bundleURL)
            return
        }
        // First page as well: a warm process with no content still shows an empty
        // grid until the upstream answers. This also writes the on-disk cache the
        // browse screen paints from on the next launch.
        _ = try? await CatVodService.shared.home(bundleURL: bundleURL, site: first)
    }

    // MARK: - Data

    private var currentBundleURL: String? {
        guard let id = selectedSourceID, let source = store.source(id: id) else { return nil }
        return source.url
    }

    private func loadCatalogAndHome() async {
        guard let bundle = currentBundleURL else {
            await MainActor.run { isLoading = false }
            return
        }
        let token = await MainActor.run { loadToken += 1; return loadToken }
        // Cold start: paint the site list and the last 推荐 from disk before the
        // gateway has downloaded (or verified) and booted the bundle. Without this
        // the whole page is one spinner for the length of the process start.
        if let cachedSites = CatVodService.shared.cachedCatalog(bundleURL: bundle),
           let firstSite = CatVodSourceHealth.shared.arranged(cachedSites, bundleURL: bundle).first {
            let cachedList = CatVodService.shared.cachedHome(bundleURL: bundle, site: firstSite)
            await MainActor.run {
                guard token == loadToken else { return }
                sites = CatVodSourceHealth.shared.arranged(cachedSites, bundleURL: bundle)
                selectedSite = firstSite
                currentCategory = nil
                filterChoices = [:]
                if let cachedList {
                    list = cachedList
                    allFilters = cachedList.filters
                }
            }
        }
        await MainActor.run { isLoading = true; message = nil }
        do {
            let loaded = try await CatVodService.shared.catalog(bundleURL: bundle)
            let stale = await MainActor.run { token != loadToken }
            if stale { return }
            // 最近反复失败的站点沉到列表底部：它们每次都要走完整个超时预算，
            // 排在第一个就等于每次打开都要等一遍。
            CatVodSourceHealth.shared.prune(bundleURL: bundle)
            let ordered = CatVodSourceHealth.shared.arranged(loaded, bundleURL: bundle)
            await MainActor.run {
                sites = ordered
                selectedSite = ordered.first
                currentCategory = nil
                filterChoices = [:]
                allFilters = [:]
                if loaded.isEmpty {
                    message = localized("这个接口没有可用的站点，换一个接口试试")
                    isLoading = false
                }
            }
            if loaded.isEmpty { return }
            await loadHome()
        } catch {
            await MainActor.run {
                if token == loadToken {
                    message = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    /// Retry what the grid is showing right now: the chosen category, or the
    /// recommended page when no category has been picked.
    private func reloadCurrent() async {
        if let category = currentCategory {
            await loadCategory(category)
        } else {
            await loadHome()
        }
    }

    private func loadHome() async {
        guard let bundle = currentBundleURL, let site = selectedSite else {
            await MainActor.run { isLoading = false }
            return
        }
        let token = await MainActor.run { loadToken += 1; return loadToken }
        // Paint the last known 推荐 from disk before touching the network. A cold
        // interface costs download + compile + process boot + upstream, and an
        // empty grid for all of that is exactly what reads as "点了没反应".
        if let cached = CatVodService.shared.cachedHome(bundleURL: bundle, site: site) {
            await MainActor.run {
                guard token == loadToken else { return }
                list = cached
                if !cached.filters.isEmpty { allFilters = cached.filters }
                resultSites = [:]
            }
        }
        await MainActor.run { isLoading = true; message = nil }
        do {
            let result = try await CatVodService.shared.home(bundleURL: bundle, site: site)
            // An interface whose first site is a 豆瓣-style aggregator answers the home
            // request with nothing at all, and the screen then shows 「暂无内容」 no matter
            // which category the person taps. Fall through to the next site that has
            // something, so opening 猫元 lands on a browsable page instead of an empty one.
            if result.media.isEmpty && result.categories.isEmpty,
               let fallback = await firstStockedSite(bundle: bundle, excluding: site) {
                await MainActor.run {
                    guard token == loadToken else { return }
                    selectedSite = fallback.site
                    list = fallback.list
                    if !fallback.list.filters.isEmpty { allFilters = fallback.list.filters }
                    resultSites = [:]
                    isLoading = false
                }
                return
            }
            await MainActor.run {
                guard token == loadToken else { return }
                list = result
                if !result.filters.isEmpty { allFilters = result.filters }
                resultSites = [:]
                isLoading = false
            }
            CatVodSourceHealth.shared.recordSuccess(bundleURL: bundle, siteKey: site.key)
        } catch {
            CatVodSourceHealth.shared.note(error: error, bundleURL: bundle, siteKey: site.key)
            await MainActor.run {
                if token == loadToken {
                    message = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    /// The first other site in this interface whose 推荐 page is not empty.
    ///
    /// Only two candidates, raced: a dead interface has a dozen silent sites, and
    /// walking them one by one is a minute of spinner for a page that may still be
    /// empty at the end. A site already on disk answers without any network at all.
    private func firstStockedSite(bundle: String, excluding current: CatVodSite)
        async -> (site: CatVodSite, list: CatVodList)? {
        let candidates = Array(sites.filter { $0.key != current.key }.prefix(2))
        for candidate in candidates {
            if let cached = CatVodService.shared.cachedHome(bundleURL: bundle, site: candidate),
               !cached.media.isEmpty {
                return (candidate, cached)
            }
            guard let fresh = try? await CatVodService.shared.home(bundleURL: bundle, site: candidate),
                  !fresh.media.isEmpty else { continue }
            return (candidate, fresh)
        }
        return nil
    }

    private func loadCategory(_ category: CatVodCategory) async {
        guard let bundle = currentBundleURL, let site = selectedSite else {
            await MainActor.run { isLoading = false }
            return
        }
        let token = await MainActor.run { loadToken += 1; return loadToken }
        // Same stale-while-revalidate treatment as 推荐: a category the person
        // already opened shows its previous page on the first frame.
        if let cached = CatVodService.shared.cachedCategory(bundleURL: bundle, site: site,
                                                            categoryID: category.id, page: 1,
                                                            extend: filterChoices) {
            await MainActor.run {
                guard token == loadToken else { return }
                list = keepingCategories(cached)
                resultSites = [:]
            }
        }
        await MainActor.run { isLoading = true; message = nil }
        do {
            let result = try await CatVodService.shared.category(bundleURL: bundle, site: site,
                                                                categoryID: category.id, page: 1,
                                                                extend: filterChoices)
            await MainActor.run {
                guard token == loadToken else { return }
                list = keepingCategories(result)
                resultSites = [:]
                isLoading = false
            }
            CatVodSourceHealth.shared.recordSuccess(bundleURL: bundle, siteKey: site.key)
        } catch {
            CatVodSourceHealth.shared.note(error: error, bundleURL: bundle, siteKey: site.key)
            await MainActor.run {
                if token == loadToken {
                    message = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    /// `category` and `search` replies normally omit `class`; carry the list
    /// from the last `home` so switching category does not erase the chip bar
    /// (it used to vanish, leaving no way back to 推荐).
    private func keepingCategories(_ result: CatVodList) -> CatVodList {
        guard result.categories.isEmpty, !list.categories.isEmpty else { return result }
        var copy = result
        copy.categories = list.categories
        return copy
    }

    private func loadMore() async {
        guard let bundle = currentBundleURL, let site = selectedSite else {
            await MainActor.run { isLoading = false }
            return
        }
        let next = list.page + 1
        guard next <= list.pageCount else { return }
        let token = await MainActor.run { loadToken += 1; return loadToken }
        await MainActor.run { isLoading = true }
        do {
            let result: CatVodList
            if let category = currentCategory {
                result = try await CatVodService.shared.category(bundleURL: bundle, site: site,
                                                                 categoryID: category.id, page: next,
                                                                 extend: filterChoices)
            } else {
                result = try await CatVodService.shared.home(bundleURL: bundle, site: site)
            }
            await MainActor.run {
                guard token == loadToken else { return }
                var merged = list
                var seen = Set(merged.media.map(\.id))
                for item in result.media where !seen.contains(item.id) {
                    merged.media.append(item); seen.insert(item.id)
                }
                merged.page = result.page
                merged.pageCount = result.pageCount
                list = merged
                isLoading = false
            }
        } catch {
            await MainActor.run {
                if token == loadToken {
                    message = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func search() async {
        guard let bundle = currentBundleURL else { return }
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        // 搜索用自己的一条令牌，不跟 loadToken 共用：搜索期间只要首页/分类
        // 有一次加载完成，共用令牌就会把搜索结果整份丢掉，表现是「搜了没反应」。
        let token = await MainActor.run { searchToken += 1; return searchToken }
        await MainActor.run { isLoading = true; message = nil; searchFocused = false }

        // 站点表可能还没准备好——冷启动时脚本还在下载。旧代码在这里直接
        // return，点了搜索什么都不发生。现在用它手头能有的：上次落盘的站点表，
        // 或者等一次 catalog，实在没有才如实说一句。
        var pool = sites
        if pool.isEmpty {
            if let cached = CatVodService.shared.cachedCatalog(bundleURL: bundle), !cached.isEmpty {
                pool = CatVodSourceHealth.shared.arranged(cached, bundleURL: bundle)
                await MainActor.run {
                    guard token == searchToken else { return }
                    sites = pool
                    if selectedSite == nil { selectedSite = pool.first }
                }
            } else if let loaded = try? await CatVodService.shared.catalog(bundleURL: bundle), !loaded.isEmpty {
                pool = CatVodSourceHealth.shared.arranged(loaded, bundleURL: bundle)
                await MainActor.run {
                    guard token == searchToken else { return }
                    sites = pool
                    if selectedSite == nil { selectedSite = pool.first }
                }
            }
        }
        guard !pool.isEmpty else {
            await MainActor.run {
                guard token == searchToken else { return }
                isLoading = false
                message = localized("站点列表还没准备好，等首页出来再搜一次")
            }
            return
        }

        // 搜整个接口下的所有站点，而不是当前选中的那一个。
        let targets = pool
        let hits = await CatVodService.shared.searchAll(bundleURL: bundle, sites: targets, keyword: term)

        await MainActor.run {
            guard token == searchToken else { return }
            var merged: [CatVodMedia] = []
            var sitesByID: [String: CatVodSite] = [:]
            var seenKeys = Set<String>()
            for (site, result) in hits {
                for item in result.media {
                    // 同一部片常同时出现在多个站点，保留第一个，避免同一张封面重复三行。
                    let key = "\(item.name)|\(item.year)|\(item.remark)"
                    if seenKeys.contains(key) { continue }
                    seenKeys.insert(key)
                    sitesByID[item.id] = site
                    merged.append(item)
                }
            }
            resultSites = sitesByID
            list = CatVodList(categories: list.categories, media: merged, page: 1, pageCount: 1)
            currentCategory = nil
            isLoading = false
            if merged.isEmpty {
                // 一个站点都没回话，和「都回了但没有这部片」是两件事：前者该说
                // 站点没响应（再搜一次没用），后者该说换个词。
                message = hits.isEmpty
                    ? String(format: localized("「%@」的 %ld 个站点都没有响应，可能是源站在维护，换一个接口或稍后再试"), term, targets.count)
                    : String(format: localized("在「%@」的所有站点里都没有找到结果"), term)
            } else {
                message = nil
            }
            saveSearchTerm(term)
        }
    }

    private func loadSearchHistory() {
        searchHistory = (UserDefaults.standard.array(forKey: Self.searchHistoryKey) as? [String]) ?? []
    }

    private func saveSearchTerm(_ term: String) {
        var history = searchHistory.filter { $0 != term }
        history.insert(term, at: 0)
        searchHistory = Array(history.prefix(12))
        UserDefaults.standard.set(searchHistory, forKey: Self.searchHistoryKey)
    }

    private func openDetail(_ item: CatVodMedia, from overrideSite: CatVodSite? = nil) async {
        guard let bundle = currentBundleURL, let site = overrideSite ?? selectedSite else { return }
        // 豆瓣/推荐类站点的条目是「聚合条目」，id 形如 msearch:36847425，它们的
        // detail 永远返回空——点下去只能看到「没有可播放的剧集」。TVBox 的处理
        // 方式是把这类条目转成一次全网搜索，这里照做，否则默认落地页整个废物。
        if item.id.lowercased().hasPrefix("msearch") {
            await MainActor.run { keyword = item.name }
            await search()
            return
        }
        // The interface URL belongs in the key: two different interfaces can carry a
        // site with the same key, and a cache hit from the other one would show the
        // wrong episode list.
        let cacheKey = "\(bundle)|\(site.key)|\(item.id)"
        // Memory first, then disk. Both mean the sheet can show real episodes on
        // the tap instead of the "正在加载剧集…" placeholder.
        let known = detailCache[cacheKey]
            ?? CatVodService.shared.cachedDetail(bundleURL: bundle, site: site, id: item.id)

        // Claim the in-flight flag and present the sheet in the SAME main-actor hop.
        // The important part is ordering: the tap now shows a screen immediately,
        // instead of leaving the person staring at a dead grid for the length of a
        // slow remote call — which is what made them tap a dozen times.
        let busy = await MainActor.run { () -> Bool in
            if isOpeningDetail { return true }
            isOpeningDetail = true
            if let known { detailCache[cacheKey] = known }
            detailGroups = known ?? []
            // With a stored copy on screen the spinner must not cover it; it only
            // signals that the episodes are being refreshed in the background.
            isLoadingDetail = true
            message = nil
            detailMissing = false
            detailSite = site
            detailItem = item
            return false
        }
        if busy { return }

        do {
            let (_, groups) = try await CatVodService.shared.detail(bundleURL: bundle, site: site, id: item.id)
            await MainActor.run {
                detailCache[cacheKey] = groups
                // Fill the sheet only if the person has not moved on to another title.
                if detailItem?.id == item.id {
                    detailGroups = groups
                    isLoadingDetail = false
                }
                isOpeningDetail = false
            }
        } catch {
            // 源对这一条什么都没返回。以前这里会 `detailItem = nil` 再自动跳到全网
            // 搜索：弹层在加载动画之后自己消失，看起来就是「点开一部剧就闪退」。
            // 现在留在弹层里说清楚，把「换源搜」交给用户点。
            var missing = false
            if let catError = error as? CatVodError, case .emptyResponse = catError { missing = true }
            await MainActor.run {
                if detailItem?.id == item.id {
                    // Keep the cached episodes visible: a failed refresh is worth a
                    // line of text, not wiping the list the person can still play.
                    message = missing
                        ? localized("这个源没有返回这部剧的详细信息")
                        : error.localizedDescription
                    // Whatever the cause, ending with no episodes needs an exit that the
                    // person can see. `missing` only changes the wording.
                    detailMissing = true
                    isLoadingDetail = false
                }
                isOpeningDetail = false
            }
        }
    }

    private func play(_ episode: CatVodEpisode, title: String) async {
        let busy = await MainActor.run { () -> Bool in
            if isResolvingPlayback { return true }
            isResolvingPlayback = true
            // Mark the tapped tile so it can show a spinner. Without this the tile
            // looks dead for the whole resolve, and the person taps it again.
            playingEpisodeID = episode.id
            message = nil
            return false
        }
        if busy { return }
        // Episode came from whichever site the open detail page belongs to — under
        // whole-interface search that is not necessarily `selectedSite`.
        guard let bundle = currentBundleURL, let site = detailSite ?? selectedSite else {
            await MainActor.run {
                isResolvingPlayback = false
                playingEpisodeID = nil
            }
            return
        }
        do {
            let playback = try await CatVodService.shared.player(bundleURL: bundle, site: site, episode: episode)
            guard let urlString = playback.url, let url = URL(string: urlString) else {
                await MainActor.run {
                    message = localized("该片源没有返回可播放地址")
                    isResolvingPlayback = false
                    playingEpisodeID = nil
                }
                return
            }
            // Probe before presenting. A dead line used to open a black player
            // showing the system's 「无法连接服务器。」, which names no cause and
            // reads like our bug; the probe either explains it or retries once
            // when only the bundle's proxy session had been retired.
            var resolved = playback
            var target = url
            var verdict = await CatVodStreamProbe.check(url, headers: resolved.header ?? [:])
            if case .retryable(_) = verdict {
                if let again = try? await CatVodService.shared.player(bundleURL: bundle, site: site,
                                                                     episode: episode),
                   let againURL = again.url.flatMap(URL.init(string:)) {
                    resolved = again
                    target = againURL
                    verdict = await CatVodStreamProbe.check(againURL, headers: again.header ?? [:])
                }
            }
            if case .blocked(let reason) = verdict {
                await MainActor.run {
                    message = reason
                    isResolvingPlayback = false
                    playingEpisodeID = nil
                }
                return
            }
            if case .retryable(let reason) = verdict {
                await MainActor.run {
                    message = reason
                    isResolvingPlayback = false
                    playingEpisodeID = nil
                }
                return
            }
            await MainActor.run {
                CatVodPlayerPresenter.present(url: target, headers: resolved.header ?? [:],
                                              title: "\(title) · \(episode.title)")
                isResolvingPlayback = false
                playingEpisodeID = nil
            }
        } catch {
            await MainActor.run {
                message = error.localizedDescription
                isResolvingPlayback = false
                playingEpisodeID = nil
            }
        }
    }

    // MARK: - Detail sheet

    private func detailSheet(_ item: CatVodMedia) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Header: poster + title + metadata + synopsis.
                    HStack(alignment: .top, spacing: 14) {
                        CatVodCoverImage(url: item.cover)
                            .frame(width: 96, height: 136)
                            .clipped()
                            .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name)
                                .font(DSFont.title3.weight(.bold))
                                .foregroundStyle(DSColor.textPrimary)
                            if !item.typeName.isEmpty {
                                Text(item.typeName)
                                    .font(DSFont.caption)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                            if !item.year.isEmpty {
                                Text(item.year)
                                    .font(DSFont.caption)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                            if !item.remark.isEmpty {
                                Text(item.remark)
                                    .font(DSFont.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    if !item.detail.isEmpty {
                        Text(item.detail)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(4)
                    }

                    if isLoadingDetail && detailGroups.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 10) {
                                ProgressView()
                                Text(localized("正在加载剧集…"))
                                    .font(DSFont.caption)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 30)
                    } else if detailGroups.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: detailMissing ? "magnifyingglass" : "film.stack")
                                .font(.system(size: 30))
                                .foregroundStyle(DSColor.textSecondary)
                            Text(detailMissing
                                 ? localized("没拿到这部剧的剧集")
                                 : localized("没有可播放的剧集"))
                                .font(DSFont.caption)
                                .foregroundStyle(DSColor.textSecondary)
                            // Netdisk/Alist rows often carry a title and a size
                            // ("6.6GB") but no episode list until an account is
                            // signed in — that is why this sheet looked empty
                            // for cloud titles while ordinary ones worked.
                            Text(detailMissing
                                 ? localized("这一条只有简介（豆瓣类条目常见），或者刚刚请求超时了。可以重试，也可以换到已启用的其它源里搜这部剧。")
                                 : localized("这个条目只有简介，没有剧集列表。网盘或 Alist 资源需要先在网盘账号里登录；也可能是源站只给了分享链接、没有可播放地址。"))
                                .font(DSFont.caption2)
                                .foregroundStyle(DSColor.textSecondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                            if detailMissing {
                                HStack(spacing: 10) {
                                    Button {
                                        Task { await openDetail(item) }
                                    } label: {
                                        Label(localized("重试"), systemImage: "arrow.clockwise")
                                            .font(DSFont.caption)
                                    }
                                    .buttonStyle(.bordered)
                                    Button {
                                        let name = item.name
                                        // Closing the sheet is now something the person
                                        // asks for, not something that happens to them.
                                        detailItem = nil
                                        Task {
                                            keyword = name
                                            await search()
                                        }
                                    } label: {
                                        Label(localized("全网搜索"), systemImage: "magnifyingglass")
                                            .font(DSFont.caption)
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                .padding(.top, 2)
                            } else {
                                NavigationLink {
                                    CatVodCloudAccountView()
                                } label: {
                                    Text(localized("网盘账号配置")).font(DSFont.caption)
                                }
                                .buttonStyle(.bordered)
                                .padding(.top, 2)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    } else {
                        if isLoadingDetail {
                            // Episodes from the cache are already on screen; this is
                            // just an inline hint that a refresh is in flight.
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.6)
                                Text(localized("正在刷新剧集…"))
                                    .font(DSFont.caption2)
                                    .foregroundStyle(DSColor.textSecondary)
                            }
                        }
                        ForEach(detailGroups) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label(group.name, systemImage: "list.bullet.rectangle")
                                        .font(DSFont.subheadline.weight(.semibold))
                                        .foregroundStyle(DSColor.textPrimary)
                                    Spacer()
                                    Text(String(format: localized("%d 集"), group.episodes.count))
                                        .font(DSFont.caption2)
                                        .foregroundStyle(DSColor.textSecondary)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                                    ForEach(episodes(for: group)) { episode in
                                        Button { if !isResolvingPlayback { Task { await play(episode, title: item.name) } } } label: {
                                            ZStack {
                                                if playingEpisodeID == episode.id {
                                                    ProgressView()
                                                        .scaleEffect(0.7)
                                                } else {
                                                    Text(episodeTitle(episode.title))
                                                        .font(DSFont.caption)
                                                        .foregroundStyle(DSColor.textPrimary)
                                                        .lineLimit(2)
                                                        .minimumScaleFactor(0.7)
                                                        .multilineTextAlignment(.center)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .padding(.horizontal, 4)
                                            .background(DSColor.surfaceTertiary, in: RoundedRectangle(cornerRadius: 8))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    if let message {
                        Text(message)
                            .font(DSFont.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            // The header already carries the title at title3; repeating it in the
            // navigation bar put the same line on screen twice.
            .navigationTitle(localized("选集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) {
                        detailItem = nil
                        isLoadingDetail = false
                        playingEpisodeID = nil
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        episodesReversed.toggle()
                    } label: {
                        Label(localized("倒序"), systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .themedAppSurface(for: .explore)
        }
        .presentationDetents([.medium, .large])
    }

    private func episodes(for group: CatVodGroup) -> [CatVodEpisode] {
        episodesReversed ? Array(group.episodes.reversed()) : group.episodes
    }

    /// Episode tiles are narrow (72pt at 5 columns). A title like
    /// 「第1集 完整版」 rendered as 「第1集 完…」, which tells the person nothing;
    /// the marker alone is what they scan for, so fall back to it when the full
    /// title cannot fit even at two lines.
    private func episodeTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 6,
              let range = trimmed.range(of: #"第\s*\d+\s*[集话期回]"#,
                                        options: .regularExpression) else { return trimmed }
        return String(trimmed[range])
    }
}

/// Poster card with cover, title and remark — closer to tvbox-silicon's grid than
/// the previous plain text list.
private struct CatVodPosterCard: View {
    let item: CatVodMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CatVodCoverImage(url: item.cover)
                .frame(width: 104, height: 148)
                .clipped()
                .cornerRadius(10)

            Text(item.name)
                .font(DSFont.caption.weight(.semibold))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
            if !item.remark.isEmpty {
                Text(item.remark)
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 104, alignment: .leading)
    }
}
