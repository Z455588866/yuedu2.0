import SwiftUI
import UIKit

/// Route for the CatVod standalone home, pushed from 探索's 猫元 button. Separate from
/// `ExploreNavigationRoute` so the complex hand-written ==/hash there need not change.
struct CatVodHomeRoute: Hashable {}

/// The "猫元" page: picks an imported interface + one of its sites, then browses categories,
/// search and detail in a poster grid, reusing the app's full-screen player for playback.
struct CatVodHomeView: View {
    @ObservedObject private var store = CatVodSourceStore.shared
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
    /// 多组筛选默认只露第一组，其余收进「更多筛选」。
    @State private var filtersExpanded = false
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
    @State private var showsSitePicker = false
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
    /// 当前网格是「全网搜索结果」而不是某个分类；非空时顶部会显示一条说明，
    /// 让人知道自己在看什么、以及怎么退回分类浏览。
    @State private var activeSearchTerm: String?
    /// 详情页里最近点开播放的那一集，返回详情时高亮它。
    @State private var lastPlayedEpisodeID: String?
    /// 有多档清晰度时先让用户选一次；nil 表示没有待选。
    @State private var qualityPrompt: QualityPrompt?
    /// 直播页的开关。
    @State private var showsLive = false

    /// 渲染用的启用源快照。和设置页同样的理由：不把「导入后上面能不能看见」
    /// 押在 SwiftUI 对 @Observable 的自动追踪上，改为显式同步。
    @State private var sourceRows: [CatVodSource] = []

    private var sources: [CatVodSource] { sourceRows }

    private var columns: [GridItem] {
        // 上限 160：iPad 和 Plus 上铺满宽度时海报不会被拉成一条长条，
        // 下限 104 保证 iPhone mini 上还是四列。原来固定 104 宽，在宽屏上
        // 每列右边缘留一条不等的缝，看起来像排版没做完。
        [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12)]
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
            sourceRows = store.enabledSources
            if selectedSourceID == nil { selectedSourceID = sources.first?.id }
        }
        // 从「管理猫源」导完返回时，`content` 的 task 不会重跑（视图一直在），
        // 于是顶部接口菜单已经能看到新源，站点却还停在上一个接口上——看着就是
        // 「导入成功但上面什么都没有」。源列表一变就重新对齐当前接口。
        .onChange(of: store.sources) { _, list in
            let enabled = list.filter(\.enabled)
            sourceRows = enabled
            guard !enabled.isEmpty else { return }
            if selectedSourceID == nil || !enabled.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = enabled.first?.id
                selectedSite = nil
                currentCategory = nil
                activeSearchTerm = nil
                Task { await loadCatalogAndHome() }
            }
        }
        // .py 导入走这条：Python 源不进 `sources`，上面那个 onChange 不会触发，
        // 但站点表里已经多了几个 `py-` 源，不重拉就还是「导入成功却看不到」。
        .onChange(of: store.pythonRevision) { _, _ in
            Task { await loadCatalogAndHome() }
        }
        .sheet(item: $detailItem, onDismiss: {
            isLoadingDetail = false
            playingEpisodeID = nil
            // A sheet swiped away mid-request must not leave the tap guard armed:
            // otherwise a 150s resolve keeps the grid refusing every tap.
            isOpeningDetail = false
        }) { item in detailSheet(item) }
        .sheet(isPresented: $showsSitePicker) {
            CatVodSitePickerSheet(sites: sites, selected: selectedSite,
                                  bundleURL: currentBundleURL ?? "") { site in
                selectedSite = site
                currentCategory = nil
                filterChoices = [:]
                filtersExpanded = false
                Task { await loadHome() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // 直播由接口的 `lives` 提供，多数 JS 猫源没有；点进去会说明情况，
                // 所以按钮不隐藏，避免"同一个接口在别人那儿有直播、我这儿没有入口"。
                Button {
                    showsLive = true
                } label: {
                    Image(systemName: "tv")
                }
                .disabled(currentBundleURL == nil)
                .accessibilityLabel(localized("直播"))
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    CatVodSourceSettingsView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(localized("管理猫源"))
            }
        }
        .sheet(isPresented: $showsLive) {
            CatVodLiveView(bundleURL: currentBundleURL ?? "", title: currentSource?.name ?? "")
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
        HStack(spacing: 8) {
            // 接口用 Menu 而不是 Picker(.menu)：Picker 在胶囊样式下无法显示
            // 当前项的对勾，接口一多就分不清自己在哪一个里。
            Menu {
                ForEach(sources) { source in
                    Button {
                        selectedSourceID = source.id
                    } label: {
                        if source.id == (selectedSourceID ?? sources.first?.id) {
                            Label(source.name, systemImage: "checkmark")
                        } else {
                            Text(source.name)
                        }
                    }
                }
            } label: {
                headerPill(icon: "square.stack.3d.up.fill",
                           title: currentSource?.name ?? localized("接口"),
                           showsChevron: true)
            }

            // 只有一个站点时也显示，让人知道当前在用哪个；只是不可切换。
            if !sites.isEmpty {
                Button {
                    showsSitePicker = true
                } label: {
                    headerPill(icon: "antenna.radiowaves.left.and.right",
                               title: selectedSite?.name ?? localized("选择站点"),
                               showsChevron: sites.count > 1)
                }
                .buttonStyle(.plain)
                .disabled(sites.count <= 1)
                .accessibilityLabel(localized("选择站点"))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .onChange(of: selectedSourceID) { old, _ in
            // 首次由 `.task` 赋值时不重复加载，那一次由 content 的 task 负责。
            guard old != nil else { return }
            // 切接口立刻清空上一个接口的内容。新接口要下载脚本、编译、起服务，
            // 这段时间里如果还挂着旧站点和旧海报，看起来就是「换了猫源但画面
            // 卡在上一个源」——实际是没清状态，不是缓存串了。
            sites = []
            list = CatVodList(categories: [], media: [], page: 1, pageCount: 1)
            selectedSite = nil
            currentCategory = nil
            filterChoices = [:]
            allFilters = [:]
            message = nil
            isLoading = true
            Task { await loadCatalogAndHome() }
        }
    }

    private var currentSource: CatVodSource? {
        sources.first { $0.id == selectedSourceID } ?? sources.first
    }

    private func headerPill(icon: String, title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(DSFont.caption2)
                .foregroundStyle(DSColor.textSecondary)
            Text(title)
                .font(DSFont.caption.weight(.medium))
                .foregroundStyle(DSColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(DSColor.surfaceTertiary, in: Capsule())
        .contentShape(Capsule())
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                    TextField(localized("搜索全部站点片名"), text: $keyword)
                        .textFieldStyle(.plain)
                        .font(DSFont.subheadline)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onSubmit { Task { await search() } }
                    if !keyword.isEmpty {
                        Button {
                            keyword = ""
                            activeSearchTerm = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(DSFont.caption)
                                .foregroundStyle(DSColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localized("清空"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(DSColor.surfaceTertiary,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button { Task { await search() } } label: {
                    if isLoading && activeSearchTerm == nil {
                        ProgressView().scaleEffect(0.8).frame(width: 44)
                    } else {
                        Text(localized("搜索"))
                            .font(DSFont.subheadline.weight(.semibold))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // 搜索历史只在输入框聚焦时空出来，否则会永久占一行、把网格往下压。
            if searchFocused && !searchHistory.isEmpty && keyword.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(DSFont.caption2)
                            .foregroundStyle(DSColor.textSecondary)
                        ForEach(searchHistory, id: \.self) { term in
                            HStack(spacing: 4) {
                                // 点词搜索。
                                Button {
                                    keyword = term
                                    Task { await search() }
                                } label: {
                                    Text(term)
                                        .font(DSFont.caption2)
                                        .foregroundStyle(DSColor.textPrimary)
                                }
                                .buttonStyle(.plain)
                                // 点 × 只删除这一条，不再触发搜索。
                                Button {
                                    removeSearchTerm(term)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(DSFont.caption2)
                                        .foregroundStyle(DSColor.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(String(format: localized("删除搜索记录 %@"), term))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(DSColor.surfaceTertiary, in: Capsule())
                            .contextMenu {
                                Button(role: .destructive) {
                                    removeSearchTerm(term)
                                } label: {
                                    Label(localized("删除搜索记录"), systemImage: "trash")
                                }
                            }
                        }
                        // 一键清空全部历史。
                        Button {
                            clearSearchHistory()
                        } label: {
                            Text(localized("清除"))
                                .font(DSFont.caption2)
                                .foregroundStyle(DSColor.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private var categoryBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryChip(title: localized("推荐"), selected: currentCategory == nil) {
                        currentCategory = nil
                        Task { await loadHome() }
                    }
                    .id(Self.homeCategoryID)
                    ForEach(Array(displayCategories.enumerated()), id: \.offset) { _, category in
                        categoryChip(title: category.name, selected: currentCategory?.id == category.id) {
                            currentCategory = category
                            filterChoices = [:]
                            filtersExpanded = false
                            Task { await loadCategory(category) }
                        }
                        .id(category.id)
                    }
                }
                .padding(.horizontal)
            }
            // 一个接口常有二三十个分类，选中的那个经常在屏幕外——尤其是从搜索结果
            // 回来或者切了站点之后。选中项自动滚到中间，不用再横着扒半天。
            .onChange(of: currentCategory?.id) { _, next in
                withAnimation(.snappy(duration: 0.25)) {
                    proxy.scrollTo(next ?? Self.homeCategoryID, anchor: .center)
                }
            }
        }
    }

    private static let homeCategoryID = "__catvod_home__"

    /// Filter chip row shown under the category bar when the current category
    /// declares filters. Selecting a value reloads the category with `extend`.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(visibleFilters.enumerated()), id: \.offset) { _, filter in
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

            if currentFilters.count > 1 {
                Button {
                    withAnimation(.snappy(duration: 0.25)) { filtersExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(filtersExpanded
                             ? localized("收起筛选")
                             : localized("更多筛选") + "（\(currentFilters.count - 1)）")
                        Image(systemName: filtersExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.accent)
                }
                .buttonStyle(.plain)
                .padding(.leading, 52)
            }
        }
        .padding(.horizontal)
    }

    /// 展开时给全部筛选，收起时只给第一组。
    private var visibleFilters: [CatVodFilter] {
        filtersExpanded ? currentFilters : Array(currentFilters.prefix(1))
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
        VStack(spacing: 10) {
            // 接口 / 站点、分类、筛选固定在顶部。原来它们都在 ScrollView 里，
            // 往下翻两屏之后想换个分类或看看别的站点，必须先滚回顶——这是这种
            // 影视壳最影响手感的地方，也是「用起来像网页」的主要来源。
            sourcePicker
            searchBar
            if !list.categories.isEmpty { categoryBar }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 筛选跟着内容滚：有的源一次给五六组筛选，全固定在顶部会
                    // 把网格挤到屏幕外。默认只露第一组，其余收在「更多筛选」里。
                    if !currentFilters.isEmpty { filterBar }
                    gridBody
                }
                .padding(.top, 2)
            }
            .refreshable { await loadHome() }
        }
        .padding(.top, 8)
        .task {
            await loadCatalogAndHome()
            warmUpOtherSources()
        }
    }

    @ViewBuilder
    private var gridBody: some View {
        if let term = activeSearchTerm {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
                Text(String(format: localized("「%@」的搜索结果 %ld 条"), term, list.media.count))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button {
                    keyword = ""
                    activeSearchTerm = nil
                    Task { await reloadCurrent() }
                } label: {
                    Text(localized("清除"))
                        .font(DSFont.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DSColor.accent)
            }
            .padding(.horizontal)
        }

        if list.media.isEmpty && isLoading {
            // 空白的网格 + 屏幕中央一个菊花，看不出是「在加载」还是「没内容」。
            // 用和真实卡片同尺寸的占位，加载完成时是原地替换，不会整页跳一下。
            CatVodGridSkeleton()
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
                    // 已经填过网盘凭据还劝人去登录，是把自己「源站没返回」的问题
                    // 推给用户——天翼这类站点登录了照样空，文案必须先认这个事实。
                    Text(CatVodCloudAccountStore.shared.accounts.hasAnyCredential
                         ? localized("已经填过网盘账号。分类还空有两种原因：接口本身没有这个网盘的线路（多数公共接口只做夸克），或源站这次没返回内容。")
                         : localized("网盘或 Alist 站点需要先在「管理猫源 → 网盘账号」里登录。"))
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

            // 「推荐」页由 home 返回，本来就只有一页；给它显示「加载更多」点了
            // 也只会重新拉一遍第一页。只在真的分页的分类里给这个按钮。
            if currentCategory != nil, list.page < list.pageCount {
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
        if let id = selectedSourceID, let source = store.source(id: id) { return source.url }
        // 首帧 `selectedSourceID` 还是 nil：直接用第一个启用的接口，免得为了
        // 赋值再触发一次 onChange 之外的重复加载。
        return sources.first?.url
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
            // 「这个接口加载失败」比「猫源请求失败（400）」有用得多：列表里常有
            // 好几条源，人得先知道是哪一个出问题才谈得上改或删。
            let failure = error.localizedDescription
            let currentName = await MainActor.run {
                sources.first(where: { $0.id == selectedSourceID })?.name
            }
            await MainActor.run {
                if token == loadToken {
                    message = currentName.map { String(format: localized("接口「%@」加载失败：%@"), $0, failure) }
                        ?? failure
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
        await MainActor.run { isLoading = true; message = nil; activeSearchTerm = nil }
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
        await MainActor.run { isLoading = true; message = nil; activeSearchTerm = nil }
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
        // 「推荐」来自 home，没有分页；调它只会拿到同一页。
        guard currentCategory != nil else { return }
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
                // 只按 vod_id 去重会误伤：有的源整页 id 都是空串或同一个值，
                // 第二页就会被整页吞掉。带上片名才是「同一条」的可靠判据。
                var seen = Set(merged.media.map { "\($0.id)|\($0.name)" })
                for item in result.media where !seen.contains("\(item.id)|\(item.name)") {
                    merged.media.append(item); seen.insert("\(item.id)|\(item.name)")
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
        // 当前站点先搜一遍：一个请求通常亚秒级，先把第一屏结果放出来，再让
        // 全网搜索在后台补齐。等十几秒才出现第一条，跟「点了没反应」没区别。
        let preferred = selectedSite ?? pool.first
        var prefetched: [CatVodMedia] = []
        var prefetchedSite: CatVodSite?
        if let preferred,
           let quick = try? await CatVodService.shared.search(bundleURL: bundle, site: preferred, keyword: term),
           !quick.media.isEmpty {
            prefetched = quick.media
            prefetchedSite = preferred
            await MainActor.run {
                guard token == searchToken else { return }
                var map: [String: CatVodSite] = [:]
                for item in quick.media { map[item.id] = preferred }
                resultSites = map
                list = CatVodList(categories: list.categories, media: quick.media,
                                  page: 1, pageCount: 1)
                activeSearchTerm = term
            }
        }

        let targets = pool
        let hits = await CatVodService.shared.searchAll(bundleURL: bundle, sites: targets,
                                                        keyword: term, preferring: preferred?.key)
        // 闭包捕获用不可变副本，避免 Swift 6 对「捕获可变量」的并发诊断。
        let seed = prefetched
        let seedSite = prefetchedSite

        await MainActor.run {
            guard token == searchToken else { return }
            var merged: [CatVodMedia] = []
            var sitesByID: [String: CatVodSite] = [:]
            var seenKeys = Set<String>()
            // 先放当前站点那批：它已经上过屏，合并时保持在前，避免结果重排。
            for item in seed {
                let key = "\(item.name)|\(item.year)|\(item.remark)"
                if seenKeys.contains(key) { continue }
                seenKeys.insert(key)
                if let seedSite { sitesByID[item.id] = seedSite }
                merged.append(item)
            }
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
                activeSearchTerm = nil
            } else {
                message = nil
                activeSearchTerm = term
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

    /// 删除单条搜索历史；长按某个词时调用。
    private func removeSearchTerm(_ term: String) {
        searchHistory.removeAll { $0 == term }
        UserDefaults.standard.set(searchHistory, forKey: Self.searchHistoryKey)
    }

    /// 清空搜索历史。
    private func clearSearchHistory() {
        searchHistory = []
        UserDefaults.standard.set(searchHistory, forKey: Self.searchHistoryKey)
    }

    /// 聚合条目（豆瓣/榜单）没有自己的 detail，只能按片名去别的站点找。
    /// 先问当前站点——一个请求通常亚秒级——没有再全网并发；拿到第一条命中就
    /// 直接打开它的详情，人看到的是海报→选集，而不是海报→搜索框。
    private func openAggregate(_ item: CatVodMedia) async {
        guard let bundle = currentBundleURL else { return }
        let term = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let claimed = await MainActor.run { () -> Bool in
            if isOpeningDetail { return true }
            isOpeningDetail = true
            message = nil
            return false
        }
        if claimed { return }

        var pool = sites
        if pool.isEmpty, let cached = CatVodService.shared.cachedCatalog(bundleURL: bundle), !cached.isEmpty {
            pool = CatVodSourceHealth.shared.arranged(cached, bundleURL: bundle)
        }
        let preferred = selectedSite ?? pool.first
        var best: (site: CatVodSite, media: CatVodMedia)?
        // 聚合条目自己常待在一个「只做榜单」的站点上，它的 search 多半什么都不回，
        // 所以当前站点失败后要立刻转全网，而不是把这次点击耗成一次空搜索。
        // 榜单站（豆瓣这类）自己声明了不可搜索，先问它只会白等一次超时。
        if let preferred, preferred.searchable != false,
           let quick = try? await CatVodService.shared.search(bundleURL: bundle, site: preferred, keyword: term) {
            best = quick.media.first.map { (site: preferred, media: $0) }
        }
        if best == nil, !pool.isEmpty {
            let hits = await CatVodService.shared.searchAll(bundleURL: bundle, sites: pool,
                                                            keyword: term, preferring: preferred?.key)
            for (site, result) in hits {
                if let media = result.media.first { best = (site: site, media: media); break }
            }
        }
        await MainActor.run { isOpeningDetail = false }

        if let best {
            await openDetail(best.media, from: best.site)
        } else {
            // 一部都没找到：退回搜索界面，词留在框里可以改，并且让下面的空态
            // 说清楚是「没搜到」，不是「源没响应」。
            await MainActor.run { keyword = item.name }
            await search()
        }
    }

    private func openDetail(_ item: CatVodMedia, from overrideSite: CatVodSite? = nil) async {
        guard let bundle = currentBundleURL, let site = overrideSite ?? selectedSite else { return }
        // 豆瓣/推荐类站点的条目是「聚合条目」，id 形如 msearch:36847425，它们的
        // detail 永远返回空。TVBox 的处理方式是把这类条目转成一次搜索；但直接把
        // 词填进搜索框再走一遍搜索，人点了一张海报却退回列表、输入框里多出一个
        // 片名，看起来就是「点开不播放，只是替我把名字填上去了」。
        if item.id.lowercased().hasPrefix("msearch") {
            await openAggregate(item)
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
            // 换了一部剧就清掉上一部的高亮；同一部重开时保留。
            if detailItem?.id != item.id { lastPlayedEpisodeID = nil }
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
            let result = try await CatVodService.shared.detail(bundleURL: bundle, site: site,
                                                              id: item.id, expectedName: item.name)
            await MainActor.run {
                detailCache[cacheKey] = result.groups
                // Fill the sheet only if the person has not moved on to another title.
                if detailItem?.id == item.id {
                    detailGroups = result.groups
                    isLoadingDetail = false
                    // 片单/合集：spider 一次回了整张片单，里面没有用户点的那一部。
                    // 以前会拿第一条去播，于是「点开就是错的」。
                    if result.isCollection {
                        detailMissing = true
                        message = localized("这一条是片单/合集，里面没有这一部片子。点下面按片名重新搜一次。")
                    }
                }
                isOpeningDetail = false
            }
        } catch {
            // 源对这一条什么都没返回。以前这里会 `detailItem = nil` 再自动跳到全网
            // 搜索：弹层在加载动画之后自己消失，看起来就是「点开一部剧就闪退」。
            // 现在留在弹层里说清楚，把「换源搜」交给用户点。
            var missing = false
            var collection = false
            if let catError = error as? CatVodError {
                switch catError {
                case .emptyResponse: missing = true
                case .http(-4, _): collection = true
                default: break
                }
            }
            // 先把错误翻译成一句话再进 MainActor：`any Error` 不是 Sendable，
            // 直接跨进 @Sendable 闭包在 Swift 6 下会被拒绝。
            let failureText = collection
                ? localized("这一条是片单/合集，里面没有这一部片子。点下面按片名重新搜一次。")
                : (missing ? localized("这个源没有返回这部剧的详细信息")
                           : error.localizedDescription)
            await MainActor.run {
                if detailItem?.id == item.id {
                    // Keep the cached episodes visible: a failed refresh is worth a
                    // line of text, not wiping the list the person can still play.
                    message = failureText
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
            guard let urlString = playback.url, !urlString.isEmpty, let url = URL(string: urlString) else {
                AppLogger.error("[CatVod] play: player 返回空地址 site=\(site.key) flag=\(episode.spiderFlag)", level: .error)
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
                AppLogger.error("[CatVod] play: 流探测判定不可播 \(reason) site=\(site.key)", level: .error)
                await MainActor.run {
                    message = reason
                    isResolvingPlayback = false
                    playingEpisodeID = nil
                }
                return
            }
            if case .retryable(let reason) = verdict {
                AppLogger.error("[CatVod] play: 流探测要求重试 \(reason) site=\(site.key)", level: .error)
                await MainActor.run {
                    message = reason
                    isResolvingPlayback = false
                    playingEpisodeID = nil
                }
                return
            }
            // 网盘线路会给出多档清晰度（会员权限决定哪几档能播）。有多档就先问
            // 一次，只有一档就直接播——非会员常常只有一档，多问一次纯属打扰。
            if let options = resolved.qualityOptions, options.count > 1 {
                AppLogger.info("[CatVod] play: \(options.count) 档清晰度，弹选择窗 site=\(site.key)", level: .notice)
                await MainActor.run {
                    qualityPrompt = QualityPrompt(title: "\(title) · \(episode.title)",
                                                  episodeID: episode.id,
                                                  options: options,
                                                  headers: resolved.header ?? [:],
                                                  danmaku: resolved.danmaku)
                    isResolvingPlayback = false
                    playingEpisodeID = nil
                }
                return
            }
            await MainActor.run {
                lastPlayedEpisodeID = episode.id
                // 「画面为什么这么糊」必须有答案：网盘把原画/高清掐掉时，网关会
                // 带回降级原因，这里翻成一句人话，跟着播放一起显示。
                if let notice = resolved.playbackNotice {
                    message = Self.playbackNoticeText(notice, quality: resolved.quality)
                }
                CatVodPlayerPresenter.present(url: target, headers: resolved.header ?? [:],
                                              title: QualityPrompt.displayTitle("\(title) · \(episode.title)",
                                                                                quality: resolved.quality),
                                              danmaku: resolved.danmaku)
                isResolvingPlayback = false
                playingEpisodeID = nil
            }
        } catch {
            AppLogger.error("[CatVod] play: 解析/播放失败 site=\(site.key) error=\(error.localizedDescription)", level: .error)
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

                    // 主要动作放最显眼的位置。原来只有下面的集数网格，几十集里
                    // 找「上次看到哪」全靠翻——给一个直接开播的按钮。
                    if let episode = preferredEpisode {
                        Button {
                            if !isResolvingPlayback { Task { await play(episode, title: item.name) } }
                        } label: {
                            HStack(spacing: 8) {
                                if playingEpisodeID == episode.id {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "play.fill")
                                }
                                Text(lastPlayedEpisodeID == nil
                                     ? localized("播放第一集")
                                     : localized("继续播放") + " · " + episodeTitle(episode.title))
                                    .font(DSFont.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isResolvingPlayback)
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
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                                    ForEach(episodes(for: group)) { episode in
                                        // 回到详情页时把刚看过的那一集标出来：几十集的
                                        // 列表里，光靠记忆找「上次看到哪」是不现实的。
                                        let isLastPlayed = lastPlayedEpisodeID == episode.id
                                        Button { if !isResolvingPlayback { Task { await play(episode, title: item.name) } } } label: {
                                            ZStack {
                                                if playingEpisodeID == episode.id {
                                                    ProgressView()
                                                        .scaleEffect(0.7)
                                                } else {
                                                    Text(episodeTitle(episode.title))
                                                        .font(DSFont.caption.weight(isLastPlayed ? .semibold : .regular))
                                                        .foregroundStyle(isLastPlayed ? DSColor.accent : DSColor.textPrimary)
                                                        .lineLimit(2)
                                                        .minimumScaleFactor(0.7)
                                                        .multilineTextAlignment(.center)
                                                }
                                            }
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .padding(.horizontal, 4)
                                            .background(isLastPlayed ? DSColor.accent.opacity(0.14) : DSColor.surfaceTertiary,
                                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                            .overlay {
                                                if isLastPlayed {
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .strokeBorder(DSColor.accent.opacity(0.55), lineWidth: 1)
                                                }
                                            }
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
        .confirmationDialog(
            qualityPrompt?.title ?? localized("选择清晰度"),
            isPresented: Binding(get: { qualityPrompt != nil },
                                 set: { if !$0 { qualityPrompt = nil } }),
            titleVisibility: .visible
        ) {
            if let prompt = qualityPrompt {
                ForEach(prompt.options) { option in
                    Button(option.name) {
                        lastPlayedEpisodeID = prompt.episodeID
                        CatVodPlayerPresenter.present(
                            url: URL(string: option.url) ?? URL(string: "about:blank")!,
                            headers: prompt.headers,
                            title: QualityPrompt.displayTitle(prompt.title, quality: option.name),
                            danmaku: prompt.danmaku)
                        qualityPrompt = nil
                    }
                }
            }
            Button(localized("取消"), role: .cancel) { qualityPrompt = nil }
        }
        // 这个弹层的主要任务是「选集」，半屏高度里放一行海报头 + 半截集数网格，
        // 每次都得往上拖一把才能点集。直接给整页。
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func episodes(for group: CatVodGroup) -> [CatVodEpisode] {
        episodesReversed ? Array(group.episodes.reversed()) : group.episodes
    }

    /// 「继续播放」指向的那一集：上次真播过的那集，没有就给第一条线路的第一集。
    private var preferredEpisode: CatVodEpisode? {
        if let id = lastPlayedEpisodeID {
            for group in detailGroups {
                if let hit = group.episodes.first(where: { $0.id == id }) { return hit }
            }
        }
        return detailGroups.first?.episodes.first
    }

    /// Episode tiles are narrow (72pt at 5 columns). A title like
    /// 「第1集 完整版」 rendered as 「第1集 完…」, which tells the person nothing;
    /// the marker alone is what they scan for, so fall back to it when the full
    /// title cannot fit even at two lines.
    private func episodeTitle(_ title: String) -> String {
        var trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 网盘源返回的是文件名：`01 [5.03GB]`、`E01 2160p WEB-DL H265`。
        // 方括号里几乎永远是体积/分辨率，格子只有 76pt 宽，留着就只剩省略号。
        trimmed = trimmed.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        trimmed = trimmed.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
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
            // 封面尺寸必须与图片本身无关：榜单/片单/搜索里混着竖海报、横剧照、
            // 豆瓣方图，一旦让 `Image` 参与测量，`scaledToFill` 的画布就会溢出
            // 单元格，压住下一行的文字——这就是「榜单/片单错乱」。
            // 做法：空色块先定出 2:3 的框，图片只作为 overlay 画在里面，
            // overlay 不参与布局，再 clip 一刀，几何就完全由列宽决定。
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    CatVodCoverImage(url: item.cover)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // 标题区高度固定（两行位），这样每张卡高度一致，行与行不会错位；
            // 没有 remark 的条目也占住那一行，避免半行卡挤上来。
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(DSFont.caption.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(item.remark.isEmpty ? " " : item.remark)
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// 首次加载时的占位网格：和真实卡片同尺寸、同圆角，加载完成是原地替换。
private struct CatVodGridSkeleton: View {
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(0..<9, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .background(DSColor.surfaceTertiary,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DSColor.surfaceTertiary)
                            .frame(height: 11)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(DSColor.surfaceTertiary.opacity(0.55))
                            .frame(width: 46, height: 9)
                    }
                    .frame(height: 32, alignment: .top)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // 轻微错落，避免九块灰砖排得太整齐反而像内容已经出来了。
                .opacity(index % 3 == 0 ? 0.85 : 1)
            }
        }
        .padding(.horizontal)
        .accessibilityHidden(true)
    }
}


/// 多档清晰度的待选状态。只在这一个页面用，放文件末尾避免污染模块命名空间。
private struct QualityPrompt: Identifiable {
    let id = UUID()
    let title: String
    let episodeID: String
    let options: [CatVodQualityOption]
    let headers: [String: String]
    /// 选完档位再开播，弹幕不能在这一步丢掉。
    var danmaku: CatVodDanmakuPayload? = nil

    /// 播放器标题后面缀上当前清晰度——用户不必去猜「这一版是几 P」。
    static func displayTitle(_ base: String, quality: String?) -> String {
        guard let quality, !quality.isEmpty else { return base }
        return "\(base) · \(quality)"
    }
}

extension CatVodHomeView {
    /// 网关的降级原因 → 一句人话。返回 nil 表示没有需要解释的事。
    static func playbackNoticeText(_ notice: String, quality: String?) -> String? {
        let label = quality.map { "（\($0)）" } ?? ""
        if notice.hasSuffix("-original-size-limit") {
            return String(format: localized("这个网盘账号取不到原画，已自动切到转码%@。原画需要该网盘的会员。"), label)
        }
        if notice.hasSuffix("-transcoded-container") {
            return String(format: localized("这个文件是 MKV/AVI 容器，播放器只吃 MP4，已自动转码%@。"), label)
        }
        return String(format: localized("这条线路已自动切换到可播放的版本%@。"), label)
    }
}
