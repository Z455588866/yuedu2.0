import SwiftUI
import UIKit

// MARK: - 书架（纸感版）
//
// The shelf, drawn as the maintainer's reference (2026-11-04): one page of paper with the
// book you were last in at the top — cover, title, author, the chapter you stopped at — then
// the rest of the shelf as a grid. The tab keeps its name: 书架, never 藏书.
//
// What the old grid did and this one still does: open a book, add a book, sort, select and
// delete. 分组 pages are gone with the old layout — the chips across the middle filter the
// shelf (全部 / 本地 / 漫画 / 视频 / 听书 / 养肥) instead of by folder, which is what the
// reference shows and what the shelf is actually used for. Only 养肥 is a shelf the reader
// fills by hand; the rest read from the book itself.

struct ShelfPaperView: View {
    @EnvironmentObject private var store: BookStore
    @Environment(\.colorScheme) private var scheme
    @Bindable private var gs = GlobalSettings.shared
    @ObservedObject private var subscription = SubscriptionStore.shared

    @State private var filter: ShelfFilter = .all
    @State private var sort: ShelfSort = .recent
    @State private var isManaging = false
    @State private var selection: Set<UUID> = []

    // MARK: 展示样式（视频里的展台书架 + 现有经典书架，可切换）
    /// 书架整体样式：展台（视频一比一，默认）/ 经典（接着读 + 网格）。
    @AppStorage("yd_shelf_display_style") private var displayStyleRaw: String = ShelfDisplayStyle.stage.rawValue
    private var displayStyle: ShelfDisplayStyle {
        get { ShelfDisplayStyle(rawValue: displayStyleRaw) ?? .stage }
        nonmutating set { displayStyleRaw = newValue.rawValue }
    }
    /// 展台底部书籍排布：随机书脊斜放 / 展台下方(挂绳翻书) / 多书脊拼图 / 网格封面。
    @AppStorage("yd_shelf_stage_arrangement") private var stageArrangementRaw: String = StageArrangement.showcase.rawValue
    private var stageArrangement: StageArrangement {
        get { StageArrangement(rawValue: stageArrangementRaw) ?? .spine }
        nonmutating set { stageArrangementRaw = newValue.rawValue }
    }
    /// 封面背景模糊（视频菜单里的开关）。
    @AppStorage("yd_shelf_cover_blur") private var coverBlur = true
    /// 展台搜索关键字。
    @State private var stageSearch = ""
    @State private var readingBookID: UUID?
    @State private var showsAddBook = false
    @State private var confirmsDelete = false
    /// 长按「搜索网络封面」时要找封面的那本书。用整本书而不只是 id：封面搜索按
    /// 书名 + 作者查，换书的同一帧里 state 还没落盘时也能拿到正确的名字。
    @State private var coverSearchBook: ReadingBook?
    /// 长按 → 编辑书籍信息（书名 / 作者 / 分组 / 简介 / 封面）。复用详情页那张
    /// EditBookSheet；iOS 17 上它里面的一级封面选择器只能从 push 弹出，所以走和
    /// 旧书架同一套 presentation policy（`pushedEditingBookId` / `sheetEditingBook`）。
    @State private var editingBook: ReadingBook?
    /// 长按 → 书籍详情：进入作品详情页（读者评论就显示在这一页）。
    /// 用 item 目的地而不是布尔量，避免 iOS 17 在 push 时把刚赋的 route 清空。
    @State private var shelfWork: WorkDetailRoute?
    /// 选完封面后正在下载 —— 期间再点一次不应叠第二个下载。
    @State private var isApplyingCover = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.appDependencies) private var appDependencies
    @Environment(\.rootTabBarVisibility) private var rootTabBarVisibility
    /// 直接复用旧书架的 holder：它不是被观察的 coordinator，发布的状态不会在
    /// UIKit 开始 push 之前重绘书架（iOS 17 会把刚 push 的 reader reconcile 掉）。
    @StateObject private var readerNavigation = ShelfReaderNavigation()
    /// 每本书封各自的窗口坐标 frame / 绘制内容。引用类型，写入内部字典不会触发
    /// SwiftUI 重绘，也不会在 body 求值时改动 @State 本身。
    @State private var coverBoxes = ShelfPaperCoverBoxes()

    // MARK: 编辑书籍信息的呈现（与旧书架同一套 policy）

    /// 书籍资讯 as a pushed destination (iOS 17) — nil on iOS 18+. Carries the id because
    /// `navigationDestination(item:)` needs a Hashable; the editor reads the live record.
    private var pushedEditingBookId: Binding<UUID?> {
        Binding(
            get: {
                BookInfoEditPresentationPolicy.prefersNavigationDestination
                    ? editingBook?.id
                    : nil
            },
            set: { if $0 == nil { editingBook = nil } }
        )
    }

    /// 书籍资讯 as a sheet (iOS 18+) — nil on iOS 17.
    private var sheetEditingBook: Binding<ReadingBook?> {
        Binding(
            get: {
                BookInfoEditPresentationPolicy.prefersNavigationDestination
                    ? nil
                    : editingBook
            },
            set: { if $0 == nil { editingBook = nil } }
        )
    }

    /// 保存书名 / 作者 / 分组 / 简介。封面由 EditBookSheet 内 own pickers 直接写 store。
    private func saveBookInfo(
        _ book: ReadingBook,
        title: String,
        author: String,
        group: String,
        intro: String
    ) {
        store.updateBook(bookId: book.id, title: title, author: author)
        store.setGroup(group, for: book.id)
        store.setCustomIntro(intro, for: book.id)
    }

    // MARK: Data

    /// The book the reader was in last: what 接着读 offers, and the one the grid leaves out.
    private var currentBook: ReadingBook? {
        store.books
            .filter { $0.lastOpenedDate != nil }
            .max { ($0.lastOpenedDate ?? .distantPast) < ($1.lastOpenedDate ?? .distantPast) }
    }

    private var restBooks: [ReadingBook] {
        store.books
            .filter { $0.id != currentBook?.id }
            .filter(filter.accepts)
            .sorted(by: sort.areInIncreasingOrder)
    }

    // MARK: 管理模式 · 全选与分享

    /// 管理模式下能被勾选的书 = 当前筛选/排序下的「其余书籍」网格。
    /// 「接着读」卡片不参与多选（它的封面点击仍是直接打开书），所以全选也只覆盖这一批，
    /// 与读者实际能看到勾选圈的书保持一致。
    private var selectableBooks: [ReadingBook] { restBooks }

    /// 是否已把当前可见的书全部选上（空列表不算，避免空书架时「全不选」误亮）。
    private var isAllSelected: Bool {
        !selectableBooks.isEmpty && selection.count == selectableBooks.count
    }

    /// 选中书对应的本地文件 URL，交给分享面板。在线书（无本地文件）会被跳过。
    private var selectedShareableURLs: [URL] {
        selection
            .compactMap { id in store.books.first(where: { $0.id == id }) }
            .compactMap { store.shareableFileURL(for: $0) }
    }

    /// Every chip stays on the bar even when its count is 0 — 视频 / 漫画 / 听书 are how the
    /// maintainer looks for those books, so hiding the entry until one exists made them
    /// impossible to find. An empty chip now says so instead of disappearing.
    private var availableFilters: [ShelfFilter] { ShelfFilter.allCases }

    /// 读者给书架设了页面背景图时，页面下半的书名会直接坐在图上 —— 那时才需要底下那层
    /// 从透明回到页面色的柔边。没设图时整页都是底色，柔边只会让页面发灰。
    private var showsArtwork: Bool {
        guard subscription.hasAccess(.readerThemePacks) else { return false }
        return gs.resolvedPageBackgroundSlice(for: .bookshelf, colorScheme: scheme) != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if displayStyle == .stage {
                    StageShelfView(
                        books: store.books,
                        search: $stageSearch,
                        arrangement: Binding(
                            get: { stageArrangement },
                            set: { stageArrangement = $0 }
                        ),
                        coverBlur: $coverBlur,
                        isManaging: $isManaging,
                        selection: $selection,
                        onOpenBook: { openBook($0) },
                        onOpenAudiobook: { NowPlayingHub.shared.openIfAudiobook($0, store: store) },
                        onDetail: { showWorkDetail(for: $0) },
                        onEdit: { editingBook = $0 },
                        onCoverSearch: { requestCoverSearch(for: $0) },
                        onFattening: { store.setFattening(!$0.isFattening, for: $0.id) },
                        onDelete: { store.delete(bookId: $0.id) },
                        onAdd: { showsAddBook = true },
                        onDeleteSelected: { confirmsDelete = true },
                        shareableURLs: selectedShareableURLs,
                        onSwitchToClassic: { displayStyle = .classic },
                        onFilter: { filter = $0 },
                        currentFilter: filter,
                        onSort: { sort = $0 },
                        currentSort: sort
                    )
                    .padding(.bottom, 32)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        masthead
                            .padding(.bottom, 22)

                        if store.books.isEmpty {
                            emptyShelf
                        } else {
                            continueReading
                            chips
                            restOfShelf
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .scrollIndicators(.hidden)
            .background {
                // 有背景图时，页面下半的书名直接坐在山水上，灰字读不清。这层柔边把页面下半
                // 渐回页面底色，图仍从上半页透出来；它铺在内容**之下**，所以封面和文字照旧
                // 清楚，只是它们背后的图淡了。没设图时它整层隐形。
                ZStack(alignment: .bottom) {
                    PaperBackground(scope: .bookshelf)

                    // 展台模式一比一复刻青苔：深棕木质展台背景，向下渐隐到页面色。
                    // 仅在展台、且未设置主题背景图时显示；设了背景图则让位，仍跟随主题。
                    if displayStyle == .stage && !showsArtwork {
                        ShelfShowcaseWoodBackdrop(scheme: scheme)
                            .allowsHitTesting(false)
                            .ignoresSafeArea()
                    }

                    // 有背景图时让山水透上来：这层柔边只兜住最底部的一小段，避免整页
                    // 被盖成纯色（此前底部不透明度 0.92、高 420，几乎把主题背景全挡住，
                    // 别的页面都显示了背景、只有书架看着像没同步）。中段压低到 0.3，
                    // 书名那行在图上仍留一点托底可读，上半页的背景则完整露出。
                    LinearGradient(
                        stops: [
                            .init(color: PaperPalette.page(scheme).opacity(0), location: 0),
                            .init(color: PaperPalette.page(scheme).opacity(0.3), location: 0.55),
                            .init(color: PaperPalette.page(scheme).opacity(0.62), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 260)
                    .opacity(showsArtwork ? 1 : 0)
                    .allowsHitTesting(false)
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            // 长按 → 书籍详情（作品详情页）。读者评论、同作者作品、系列都画在这一页；
            // 书架纸感版原先只有「打开 / 封面 / 养肥 / 删除」，没有进这一页的入口。
            .navigationDestination(item: $shelfWork) { route in
                WorkDetailView(route: route, onRemoveFromShelf: { shelfWork = nil })
                    .environmentObject(store)
            }
            // 长按 → 编辑书籍信息（iOS 17：push）。EditBookSheet 里的封面选择器是
            // 一级弹层，iOS 17 上不能从 sheet 里再弹，所以这条路走 push。
            .navigationDestination(item: pushedEditingBookId) { bookId in
                if let book = store.books.first(where: { $0.id == bookId }) {
                    EditBookSheet(book: book, presentation: .push) { title, author, group, intro in
                        saveBookInfo(book, title: title, author: author, group: group, intro: intro)
                    }
                    .environmentObject(store)
                }
            }
            .background {
                // 卡片翻开转场必须挂在外层 UINavigationController 上。这个零尺寸探针
                // 解析出书架自己的 nav controller，交给 coordinator 提供打开动画与
                // 侧滑返回；放在 NavigationStack 的内容里，responder 链才找得到它。
                ReaderEdgeSwipeEnabler(navigator: readerNavigation.coordinator)
                    .frame(width: 0, height: 0)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { readingBookID != nil },
            set: { if !$0 { readingBookID = nil } }
        )) {
            if let id = readingBookID {
                BookReaderView(bookId: id)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showsAddBook) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readableListWidth) {
                AddBookView()
                    .environmentObject(store)
            }
        }
        // 书架长按 → 搜索网络封面。复用 书籍资讯 → 封面 里那张页，只是把入口从
        // 三层深的面板搬到长按菜单上：想换封面的时候人正在书架上，不该先点进书。
        // onDismiss 一定把 item 清掉：页内选中后是它自己 dismiss 的，binding 若还留着
        // 那本书，下次长按同一本不会重新弹出。
        .sheet(item: $coverSearchBook, onDismiss: { coverSearchBook = nil }) { book in
            NavigationStack {
                OnlineCoverSearchView(
                    title: book.title,
                    author: book.author,
                    onSelect: { candidate in
                        applyCover(candidate, to: book)
                    },
                    onImportImage: { data in
                        applyImportedCover(data, to: book)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(localized("取消")) { coverSearchBook = nil }
                    }
                }
            }
            // 全 App 的浮层都是玻璃，这一张也一样：后面的书架透上来，
            // 封面格子自己带 surface，不会糊成一片。统一走「全局玻璃」总闸，
            // 关掉时退成不透明纯色，供 iOS 17 一键兜底（第 13 条）。
            .presentationBackground { GlobalGlassBackdrop() }
        }
        // 长按 → 编辑书籍信息（iOS 18+：sheet）。iOS 17 上走 NavigationStack 内的 push。
        .sheet(item: sheetEditingBook, onDismiss: { editingBook = nil }) { book in
            AdaptiveSheetContainer(maxWidth: DSLayout.readableCompactWidth) {
                EditBookSheet(book: book) { title, author, group, intro in
                    saveBookInfo(book, title: title, author: author, group: group, intro: intro)
                }
                .environmentObject(store)
            }
        }
        .confirmationDialog(
            localized("删除所选书籍"),
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button(localized("删除"), role: .destructive) {
                for id in selection { store.delete(bookId: id) }
                selection = []
                isManaging = false
            }
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(localized("删除后，书籍与其阅读进度都会从这台装置移除。"))
        }
    }

    // MARK: 标题

    private var masthead: some View {
        HStack(alignment: .center) {
            Text(localized("书架"))
                .font(PaperFont.serif(32))
                .foregroundStyle(ShelfInk.strong(scheme))
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            if isManaging {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isManaging = false
                        selection = []
                    }
                } label: {
                    Text(localized("完成"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(ShelfInk.strong(scheme))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .glassCapsule(scheme)
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { displayStyle = .stage }
                    } label: {
                        Label(localized("展台书架"), systemImage: "books.vertical")
                    }
                    Divider()
                    Button {
                        showsAddBook = true
                    } label: {
                        Label(localized("添加书籍"), systemImage: "plus")
                    }
                    Divider()
                    Picker(localized("排序"), selection: $sort) {
                        ForEach(ShelfSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Divider()
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { isManaging = true }
                    } label: {
                        Label(localized("管理"), systemImage: "checkmark.circle")
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ShelfInk.strong(scheme))
                        .frame(width: 38, height: 38)
                        .glassCircle(scheme)
                }
                .accessibilityLabel(localized("书架选项"))
            }
        }
        .padding(.top, 6)
    }

    // MARK: 接着读

    @ViewBuilder
    private var continueReading: some View {
        // 筛到某个分类时，卡片跟著走：在「漫画」下却顶著最近读的 TXT，会让人以为
        // 那本书属于这个分类 —— 养肥尤其如此，它现在是读者自己挑的一架书。
        if let book = currentBook, filter.accepts(book) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(localized("接着读"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(ShelfInk.strong(scheme))
                    Spacer(minLength: 0)
                    Text(localized("上次打开"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(ShelfInk.muted(scheme))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(ShelfInk.muted(scheme))
                }
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 16) {
                        shelfCover(book, width: 74, height: 104)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(book.title)
                                .font(PaperFont.serif(20))
                                .foregroundStyle(ShelfInk.strong(scheme))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)

                            Text(book.author)
                                .font(.system(size: 12.5))
                                .foregroundStyle(ShelfInk.soft(scheme))
                                .lineLimit(1)
                                .padding(.top, 5)

                            Text(chapterLine(for: book) ?? localized("还没有开始读"))
                                .font(.system(size: 12.5))
                                .foregroundStyle(ShelfInk.muted(scheme))
                                .lineLimit(1)
                                .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // 书签提示在左、继续阅读在右 — the button used to sit under the title
                    // and squeezed the three lines of text into a narrow column.
                    HStack(spacing: 12) {
                        HStack(spacing: 5) {
                            Image(systemName: "bookmark")
                                .font(.system(size: 10))
                            Text(localized("已为你保留上次阅读位置"))
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                        }
                        .foregroundStyle(ShelfInk.muted(scheme))

                        Spacer(minLength: 8)

                        Button {
                            // An audiobook's player grows out of the now-playing bar.
                            if !NowPlayingHub.shared.openIfAudiobook(book, store: store) {
                                openBook(book)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(localized("继续阅读"))
                                    .font(.system(size: 13, weight: .medium))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(ShelfInk.strong(scheme))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            // 与首页「继续阅读」按钮同一套玻璃语言：卡片本身已经是玻璃，
                            // 里面不能再叠 .ultraThinMaterial（两层 glassEffect 会互采、
                            // 糊成一团），所以用「单层中性半透明填充」——读起来是透明玻璃，
                            // 而不是主题色块。
                            .background {
                                Capsule().fill(
                                    Color.primary.opacity(scheme == .dark ? 0.12 : 0.05)
                                )
                            }
                            .overlay(Capsule().strokeBorder(PaperPalette.hairline(scheme), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 14)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperCard(radius: 22)
                // 长按整张卡都能弹出菜单，不只是封面和文字那几块 —— 读者圈著整张卡说
                // 「这里删不掉」，就是因为空白处（右半边、书名右侧）没有命中区域。
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                // The book being read is the one most often 养肥-ed (a serial you are
                // letting run), and it never appears in the grid below — so the menu
                // has to be reachable here too.
                .contextMenu {
                    Button {
                        if !NowPlayingHub.shared.openIfAudiobook(book, store: store) {
                            openBook(book)
                        }
                    } label: {
                        Label(localized("打开"), systemImage: "book")
                    }
                    Button {
                        showWorkDetail(for: book)
                    } label: {
                        Label(localized("书籍详情"), systemImage: "books.vertical")
                    }
                    Button {
                        editingBook = book
                    } label: {
                        Label(localized("编辑书籍资讯"), systemImage: "square.and.pencil")
                    }
                    Button {
                        requestCoverSearch(for: book)
                    } label: {
                        Label(localized("搜索网络封面"), systemImage: "photo.on.rectangle.angled")
                    }
                    Button {
                        store.setFattening(!book.isFattening, for: book.id)
                    } label: {
                        Label(
                            book.isFattening ? localized("移出养肥") : localized("加入养肥"),
                            systemImage: book.isFattening ? "leaf.fill" : "leaf"
                        )
                    }
                    Button(role: .destructive) {
                        store.delete(bookId: book.id)
                    } label: {
                        Label(localized("删除"), systemImage: "trash")
                    }
                }
            }
        }
    }

    // MARK: 分类

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(availableFilters) { option in
                    let isOn = option == filter
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { filter = option }
                    } label: {
                        HStack(spacing: 5) {
                            Text(option.title)
                                .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                            Text("\(count(for: option))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(
                                    isOn ? ShelfInk.soft(scheme)
                                         : ShelfInk.muted(scheme)
                                )
                        }
                        .foregroundStyle(
                            isOn ? ShelfInk.strong(scheme)
                                 : ShelfInk.soft(scheme)
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background {
                            if isOn {
                                // 选中态染主题强调色，不画一块不透明的灰：玻璃上的不透明
                                // 色块会把整条 bar 的玻璃打断，看起来像贴纸。
                                Capsule().fill(
                                    DSColor.accent.opacity(scheme == .dark ? 0.28 : 0.16)
                                )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .scrollIndicators(.hidden)
        // 收编到全局玻璃统一入口（参考待改清单第 13 条）：与设置行/卡片同一套玻璃，
        // 由「全局玻璃」总闸控制；关掉后连同整条分类栏一起回退为不透明底色，
        // 不再绕过开关写死 .ultraThinMaterial（iOS 17 兜底）。横向 ScrollView 保留。
        .clearGlassSurface(in: Capsule())
        .overlay(Capsule().strokeBorder(PaperPalette.hairline(scheme).opacity(0.55), lineWidth: 0.6))
        .padding(.top, 18)
    }

    // MARK: 其余书籍

    /// 「其余书籍」 only describes the whole shelf; once a chip is chosen the list below is
    /// that shelf, so it takes the chip's own name — 养肥 is the reader's own shelf now.
    private var sectionTitle: String {
        filter == .all ? localized("其余书籍") : filter.title
    }

    private var restOfShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(sectionTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(ShelfInk.strong(scheme))
                Text("· \(restBooks.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(ShelfInk.muted(scheme))

                Spacer(minLength: 8)

                if isManaging {
                    // 全选 / 全不选：只作用于当前筛选下可见的书，与能勾选的封面一致。
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            if isAllSelected {
                                selection = []
                            } else {
                                selection = Set(selectableBooks.map(\.id))
                            }
                        }
                    } label: {
                        Text(localized(isAllSelected ? "全不选" : "全选"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(ShelfInk.strong(scheme))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassCapsule(scheme)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectableBooks.isEmpty)

                    Text("\(selection.count) \(localized("已选"))")
                        .font(.system(size: 12))
                        .foregroundStyle(ShelfInk.muted(scheme))

                    // 分享选中的书（本地文件）。ShareLink 必须留在普通 HStack 里，
                    // 放进 Menu 会在 iOS 17 丢掉分享面板 —— 与书源汇出那边同一条约束。
                    ShareLink(items: selectedShareableURLs) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(ShelfInk.strong(scheme))
                            .frame(width: 30, height: 30)
                            .glassCircle(scheme)
                    }
                    .disabled(selectedShareableURLs.isEmpty)
                    .accessibilityLabel(localized("分享"))

                    Button {
                        confirmsDelete = true
                    } label: {
                        Text(localized("删除"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassCapsule(scheme)
                    }
                    .buttonStyle(.plain)
                    .disabled(selection.isEmpty)
                } else {
                    Menu {
                        Picker(localized("排序"), selection: $sort) {
                            ForEach(ShelfSort.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(sort.title)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(ShelfInk.muted(scheme))
                    }
                }
            }
            .padding(.horizontal, 4)

            if restBooks.isEmpty {
                if filter == .fattening {
                    // 养肥 is a shelf the reader fills by hand now, so 空 is the normal
                    // state on a fresh install — say how to add one instead of "no books".
                    VStack(alignment: .leading, spacing: 8) {
                        Text(localized("养肥还是空的"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ShelfInk.strong(scheme))
                        Text(localized("长按书架上的书，选「加入养肥」。"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(ShelfInk.muted(scheme))
                        Button {
                            withAnimation(.snappy(duration: 0.18)) { filter = .all }
                        } label: {
                            HStack(spacing: 5) {
                                Text(localized("去挑书"))
                                    .font(.system(size: 12.5, weight: .medium))
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundStyle(ShelfInk.strong(scheme))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .glassCapsule(scheme)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 18)
                } else {
                    Text(localized("这个分类还没有书"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(ShelfInk.muted(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 18)
                }
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 3),
                    alignment: .leading,
                    spacing: 22
                ) {
                    ForEach(restBooks) { book in
                        cell(for: book)
                    }
                }
            }
        }
        .padding(.top, 26)
    }

    private func cell(for book: ReadingBook) -> some View {
        Button {
            if isManaging {
                if selection.contains(book.id) { selection.remove(book.id) }
                else { selection.insert(book.id) }
            } else {
                // An audiobook's player grows out of the now-playing bar.
                if !NowPlayingHub.shared.openIfAudiobook(book, store: store) {
                    openBook(book)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    shelfCover(book, width: nil, height: 150)
                    if isManaging {
                        Image(systemName: selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 19))
                            .foregroundStyle(
                                selection.contains(book.id)
                                    ? ShelfInk.strong(scheme)
                                    : Color.white.opacity(0.9)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 3)
                            .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ShelfInk.strong(scheme))
                        .lineLimit(1)

                    // 次要行用二级文字而非三级：书名下面这一行在页面背景图上也要读得清。
                    Text(subtitle(for: book))
                        .font(.system(size: 11.5))
                        .foregroundStyle(ShelfInk.soft(scheme))
                        .lineLimit(1)
                }
            }
            // 封面与书名之间的空隙原本不属于任何可命中区域，长按会落空；铺平之后
            // 整格都是长按范围，删除、加入养肥不必对准封面。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                // An audiobook's player grows out of the now-playing bar.
                if !NowPlayingHub.shared.openIfAudiobook(book, store: store) {
                    openBook(book)
                }
            } label: {
                Label(localized("打开"), systemImage: "book")
            }
            Button {
                showWorkDetail(for: book)
            } label: {
                Label(localized("书籍详情"), systemImage: "books.vertical")
            }
            Button {
                editingBook = book
            } label: {
                Label(localized("编辑书籍资讯"), systemImage: "square.and.pencil")
            }
            Button {
                requestCoverSearch(for: book)
            } label: {
                Label(localized("搜索网络封面"), systemImage: "photo.on.rectangle.angled")
            }
            Button {
                store.setFattening(!book.isFattening, for: book.id)
            } label: {
                Label(
                    book.isFattening ? localized("移出养肥") : localized("加入养肥"),
                    systemImage: book.isFattening ? "leaf.fill" : "leaf"
                )
            }
            Button(role: .destructive) {
                store.delete(bookId: book.id)
            } label: {
                Label(localized("删除"), systemImage: "trash")
            }
        }
    }

    private var emptyShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("书架还是空的"))
                .font(PaperFont.serif(20))
                .foregroundStyle(ShelfInk.strong(scheme))
            Text(localized("汇入一本书，这里就会亮起来。"))
                .font(.system(size: 13))
                .foregroundStyle(ShelfInk.soft(scheme))
            Button {
                showsAddBook = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text(localized("添加书籍"))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(ShelfInk.strong(scheme))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassCapsule(scheme)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .paperCard(radius: 22)
    }

    // MARK: 零件

    /// A cover on the page: no tilt here, the shelf is a shelf — the spine's shade and a soft
    /// shadow are enough to keep it from reading as a flat rectangle.
    private func shelfCover(_ book: ReadingBook, width: CGFloat?, height: CGFloat) -> some View {
        // 换封面后这里必须跟着刷新。旧的 BookCoverImage(readingBook:) 只读 coverUrl
        // 且按 URL 做缓存 key —— 换封面改的是 coverImagePath，coverUrl 不变，task id
        // 也不变，于是书架沿用旧缓存图（详情页却会更新，因为它用的是下面这套）。
        // BookshelfCoverArtwork 读 coverImagePath，并监听 pipeline.invalidations：
        // 写封面时 BookCoverLoader.write 会 invalidate，这一格随即重载新图。
        // 走 BookshelfCoverStyle 与详情页、旧书架同一条解析链路，转场上报的
        // bookshelfDrawnCoverObserver 也由外层的 reportBookshelfCoverFrame 提供。
        BookshelfCoverStyle.artwork(
            for: book,
            colorScheme: scheme,
            displaySize: CGSize(width: width ?? 100, height: height)
        )
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [Color.black.opacity(0.22), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: (width ?? 100) * 0.1)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.16), radius: 8, x: 3, y: 6)
            .accessibilityHidden(true)
            .reportBookshelfCoverFrame(into: coverBoxes.box(for: book.id), onChange: nil)
    }

    /// 长按 → 书籍详情：把书架上这本书变成作品详情页的记录（与 HomeView 的
    /// 「作品详情」用同一条构造路径）。作品详情页才会去问各模块的读者评论。
    private func showWorkDetail(for book: ReadingBook) {
        shelfWork = ShelfProvider(store: store).items([book]).first.flatMap(WorkDetailRoute.init)
    }

    /// 点开书籍时走项目里已有的卡片翻开转场（ReaderCardTransitionAnimator）：
    /// 被点的封面从原位置放大、沿书脊 3D 翻开展成阅读页，而不是直接模态硬切。
    /// 书架改版成 ShelfPaperView 后一直只设 readingBookID 走 fullScreenCover，
    /// 把这套上游动画整个绕过去了；这里把它接回来。
    /// 紧凑宽度、非音视频的书才走 push；iPad / 听书 / 视频保留原来的全屏模态，
    /// 免得把阅读器塞进内容列或抢了正在播放的播放器。
    private func openBook(_ book: ReadingBook) {
        let navigator = readerNavigation.coordinator
        guard BookCardNavigationGate.shouldUseCardTransition(
            for: book, isRegularWidth: sizeClass == .regular
        ), navigator.isNavigationControllerAttached else {
            // 没挂上导航控制器（或 iPad / 音视频）时别直接硬切，统一走封面翻开转场。
            if ReaderOpener.open(bookID: book.id, store: store) { return }
            readingBookID = book.id
            return
        }

        let box = coverBoxes.box(for: book.id)
        let tapped = box.tappedCover()
        let geometry = tapped.geometry
        let snapshot = BookshelfCoverStyle.snapshot(
            for: book,
            drawn: tapped.drawnCover,
            catalogImage: tapped.catalogImage,
            colorScheme: scheme,
            sourceSize: geometry?.frame.size
        )
        let snapshotUpgrade = snapshot == nil
            ? nil
            : BookshelfCoverStyle.snapshotUpgrade(for: tapped.drawnCover)
        let source = ReaderTransitionSource(
            bookID: book.id,
            cornerRadius: geometry?.cornerRadius ?? 5,
            frame: geometry?.frame,
            frameProvider: { [weak box] in
                guard let box, !box.frame.isEmpty else { return nil }
                return box.frame
            },
            snapshot: snapshot,
            snapshotUpgrade: snapshotUpgrade,
            direction: .leftSpine
        )

        let readerBookID = book.id
        let readerStore = store
        let readerDependencies = appDependencies
        let readerTabBarVisibility = rootTabBarVisibility
        navigator.open(
            bookID: readerBookID,
            source: source,
            destination: {
                ReaderHostingController(content: AnyView(
                    BookReaderView(bookId: readerBookID)
                        .environmentObject(readerStore)
                        .environment(\.appDependencies, readerDependencies)
                        .environment(\.readerNavigator, navigator)
                        .environment(\.rootTabBarVisibility, readerTabBarVisibility)
                ))
            },
            onTransitionCompleted: {
                readerStore.updateLastOpened(bookId: readerBookID)
            }
        )
    }

    private func count(for option: ShelfFilter) -> Int {
        store.books.filter(option.accepts).count
    }

    /// 第三章 · 未寄出的信 — the chapter the book is open at, when the book knows its chapters.
    private func chapterLine(for book: ReadingBook) -> String? {
        if let chapters = book.onlineChapters, !chapters.isEmpty {
            let index = min(chapters.count - 1, max(0, Int(book.currentPosition * Double(chapters.count))))
            let title = chapters[index].title
            return title.isEmpty ? chapterNumber(index + 1) : "\(chapterNumber(index + 1)) · \(title)"
        }
        if let total = book.totalChapterNum, total > 0, book.currentPosition > 0.001 {
            let index = min(total, max(1, Int(book.currentPosition * Double(total)) + 1))
            return chapterNumber(index)
        }
        if book.currentPosition > 0.001 {
            return String(format: localized("读至 %d%%"), Int(book.currentPosition * 100))
        }
        return nil
    }

    /// 第 3 章 — what the grid's second line leads with.
    private func chapterNumber(_ index: Int) -> String {
        String(format: localized("第 %d 章"), index)
    }

    /// 更新 3 章 · 本地 — how far in, or how many new chapters a refresh found.
    /// 下拉刷新 / 进 App 自动刷新发现新章后，书卡这一行直接显示「更新 N 章」，
    /// 让刷新有看得见的反馈；点开书后 `newChapterCount` 清零，恢复成原来的进度显示。
    private func subtitle(for book: ReadingBook) -> String {
        let place = book.isOnline ? localized("云端") : localized("本地")
        if book.hasNewChapterUpdate && book.newChapterCount > 0 {
            return "\(String(format: localized("更新 %d 章"), book.newChapterCount)) · \(place)"
        }
        guard let chapter = chapterLine(for: book) else {
            return "\(localized("未读")) · \(place)"
        }
        return "\(chapter) · \(place)"
    }

    // MARK: 搜索网络封面

    /// 从长按菜单请求封面搜索。
    ///
    /// 菜单收起和 sheet 弹出若撞在同一帧，iOS 会把这个 presentation 丢掉 —— 表现就是
    /// 「长按点了没反应」。让出两帧再设 item，菜单先收干净。
    private func requestCoverSearch(for book: ReadingBook) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            coverSearchBook = book
        }
    }

    /// 下载长按选中封面并设成这本书的封面。
    ///
    /// 走的是 书籍资讯 里同一个 `applyCustomCover`，所以去重、备份原封面、
    /// 「重设封面」能还原，全都和面板里改的一致。失败不静默：书架上的封面没变，
    /// 不说一声就会以为点空了。
    private func applyCover(_ candidate: CoverCandidate, to book: ReadingBook) {
        guard !isApplyingCover else {
            BookSourceFormLoginView.presentToastAlert(message: localized("正在应用上一张封面…"))
            return
        }
        isApplyingCover = true
        Task { @MainActor in
            let applied = await store.applyCustomCover(
                bookId: book.id,
                coverUrl: candidate.coverUrl,
                sourceId: candidate.sourceId
            )
            isApplyingCover = false
            // 选中后面板会自己关掉；关闭动画还在跑时 present 会落在一个正在消失的
            // 控制器上，系统直接丢掉这个 alert。等一拍，等它落定。
            try? await Task.sleep(for: .milliseconds(350))
            BookSourceFormLoginView.presentToastAlert(
                message: applied
                    ? localized("封面已更新")
                    : localized("无法下载这张封面，请换一张或检查网络。")
            )
        }
    }

    /// 「导入封面」：把相簿/档案里选的图片直接设成封面。走 BookStore 里与
    /// 书籍资讯相同的 `applyCustomCover(bookId:imageData:)`，所以降采样、备份
    /// 原封面、「重设封面」可还原都一致。
    private func applyImportedCover(_ data: Data, to book: ReadingBook) {
        let applied = store.applyCustomCover(bookId: book.id, imageData: data)
        BookSourceFormLoginView.presentToastAlert(
            message: applied
                ? localized("封面已更新")
                : localized("无法读取图片。")
        )
    }
}

// MARK: - 分类与排序

enum ShelfFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case manga
    case video
    case audio
    case fattening

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return localized("全部")
        case .local: return localized("本地")
        case .manga: return localized("漫画")
        // 视频一直被 `isMediaOnly` 挡在「本地」之外，却没有自己的筛选 ——
        // 视频书只出现在「全部」里，等于没法找。漫画、听书都有，它也得有。
        case .video: return localized("视频")
        case .audio: return localized("听书")
        case .fattening: return localized("养肥")
        }
    }

    func accepts(_ book: ReadingBook) -> Bool {
        let kind = book.resolvedPipelineKind
        switch self {
        case .all: return true
        case .manga: return kind == .manga
        case .video: return kind == .video
        case .audio: return kind == .audio
        case .local: return !book.isOnline && !Self.isMediaOnly(kind)
        // 养肥 — a shelf the reader keeps themselves (长按 → 加入养肥), not "everything
        // imported but never opened": that swept in every new book and left no way to
        // leave one out. Nothing lands here unless the reader puts it here.
        case .fattening: return book.isFattening
        }
    }

    /// 漫画 / 听书 hang off their own chips; 本地 means "text books on this device".
    private static func isMediaOnly(_ kind: BookPipelineKind) -> Bool {
        kind == .video || kind == .manga || kind == .audio
    }
}

enum ShelfSort: String, CaseIterable, Identifiable {
    case recent
    case added
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: return localized("最近阅读")
        case .added: return localized("添加日期")
        case .title: return localized("书名")
        }
    }

    func areInIncreasingOrder(_ lhs: ReadingBook, _ rhs: ReadingBook) -> Bool {
        switch self {
        case .recent:
            return (lhs.lastOpenedDate ?? lhs.addedDate) > (rhs.lastOpenedDate ?? rhs.addedDate)
        case .added:
            return lhs.addedDate > rhs.addedDate
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

// MARK: - 黑白墨色

/// Headings, body and captions differ by weight and level, not by hue — that part of the
/// maintainer's 2026-11-04 reference stays. The levels now come from the appearance theme's
/// own label colours (2026-11-06: the shelf has to follow the theme like every other page),
/// instead of fixed greys that ignored it.
enum ShelfInk {
    static func strong(_ scheme: ColorScheme) -> Color {
        Color(uiColor: DSUIColor.textPrimary)
    }

    static func soft(_ scheme: ColorScheme) -> Color {
        Color(uiColor: DSUIColor.textSecondary)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        Color(uiColor: DSUIColor.textTertiary)
    }
}

// MARK: - 打开动画桥接

/// 每本书一个封面框，按 id 复用；写内部字典不触发 SwiftUI 状态更新。
private final class ShelfPaperCoverBoxes {
    private var boxes: [UUID: BookshelfCoverFrameBox] = [:]

    func box(for id: UUID) -> BookshelfCoverFrameBox {
        if let existing = boxes[id] { return existing }
        let created = BookshelfCoverFrameBox()
        boxes[id] = created
        return created
    }
}

// MARK: - 玻璃按钮

private extension View {
    /// The app's one glass entry point, not a private copy of it.
    ///
    /// These used to paint `.ultraThinMaterial` themselves, which meant 毛玻璃、透明度
    /// and 光晕 in 外观主题 › 界面效果 never reached them, and iOS 26's `glassEffect` —
    /// the material the system's own toolbars are made of — was never used on the page
    /// that has the most chrome on it.
    func glassCapsule(_ scheme: ColorScheme) -> some View {
        floatingSurface(in: Capsule())
    }

    func glassCircle(_ scheme: ColorScheme) -> some View {
        floatingSurface(in: Circle())
    }
}

// MARK: - 书架展示样式（视频一比一的展台书架 / 经典书架）

enum ShelfDisplayStyle: String, CaseIterable, Identifiable {
    case stage
    case classic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stage: return localized("展台书架")
        case .classic: return localized("经典书架")
        }
    }
}

/// 视频里「书架显示」菜单的 7 种整页模式，逐字对应官方新版（2.0.7）：
/// 宫格 / 列表 / 展台 / 翻阅 / 杂志 / 图书馆 / 挂绳。
/// 每一种都会整页切换布局（不再只是展台下方的一小排）。
enum StageArrangement: String, CaseIterable, Identifiable {
    case grid        // 宫格
    case list        // 列表
    case showcase    // 展台
    case flip        // 翻阅
    case magazine    // 杂志
    case library     // 图书馆
    case hanging     // 挂绳
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: return localized("宫格")
        case .list: return localized("列表")
        case .showcase: return localized("展台")
        case .flip: return localized("翻阅")
        case .magazine: return localized("杂志")
        case .library: return localized("图书馆")
        case .hanging: return localized("挂绳")
        }
    }
    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .showcase: return "rectangle.portrait"
        case .flip: return "book.closed"
        case .magazine: return "book.closed"
        case .library: return "books.vertical"
        case .hanging: return "paperclip"
        }
    }
}

// MARK: - 展台书架（视频一比一）
//
// 顶部「书架⌄」胶囊 + 「≡ 视图切换 / +」胶囊 + 搜索框，居中大封面 + 书名作者进度，
// 底部四种可切换排布（书脊斜放 / 展台下方 / 多书脊拼图 / 网格封面），全玻璃导航由外层提供。
// 大封面与每本书都挂完整长按菜单（打开 / 书籍详情 / 编辑书籍资讯 / 搜索网络封面 /
// 加入养肥 / 删除），管理模式保留全选 / 分享 / 删除 —— 与经典书架逐项一致。
// 颜色全部走 ShelfInk / PaperPalette，背景由外层 ShelfPaperView 的 PaperBackground 提供，
// 跟随主题、背景图与深浅模式联动。

struct StageShelfView: View {
    let books: [ReadingBook]
    @Binding var search: String
    @Binding var arrangement: StageArrangement
    @Binding var coverBlur: Bool
    @Binding var isManaging: Bool
    @Binding var selection: Set<UUID>

    let onOpenBook: (ReadingBook) -> Void
    let onOpenAudiobook: (ReadingBook) -> Bool
    let onDetail: (ReadingBook) -> Void
    let onEdit: (ReadingBook) -> Void
    let onCoverSearch: (ReadingBook) -> Void
    let onFattening: (ReadingBook) -> Void
    let onDelete: (ReadingBook) -> Void
    let onAdd: () -> Void
    let onDeleteSelected: () -> Void
    let shareableURLs: [URL]
    let onSwitchToClassic: () -> Void
    let onFilter: (ShelfFilter) -> Void
    let currentFilter: ShelfFilter
    let onSort: (ShelfSort) -> Void
    let currentSort: ShelfSort

    @Environment(\.colorScheme) private var scheme

    /// 大封面居中对齐用的滚动坐标空间。
    private static let stageSpace = "stageShelf"

    private var filteredBooks: [ReadingBook] {
        let base = books.filter { currentFilter.accepts($0) }
            .sorted(by: currentSort.areInIncreasingOrder)
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.author.localizedCaseInsensitiveContains(q)
        }
    }

    /// 最近读的那本作为展台主角；没有阅读记录时取第一本。
    private var feature: ReadingBook? {
        let f = filteredBooks
        return f.first { $0.lastOpenedDate != nil } ?? f.first
    }

    private var otherBooks: [ReadingBook] {
        guard let f = feature else { return filteredBooks }
        return filteredBooks.filter { $0.id != f.id }
    }

    private var isAllSelected: Bool {
        !selectable.isEmpty && selection.count == selectable.count
    }
    private var selectable: [ReadingBook] { filteredBooks }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            searchBar
                .padding(.top, 10)

            if isManaging && !books.isEmpty {
                manageBar
                    .padding(.top, 14)
            }

            if books.isEmpty {
                emptyStage
            } else if filteredBooks.isEmpty {
                noResult
            } else {
                // 7 种显示模式整页切换 —— 对应视频「书架显示」菜单逐字：
                // 宫格 / 列表 / 展台 / 翻阅 / 杂志 / 图书馆 / 挂绳。
                // 每一种模式里的书都挂完整长按菜单，管理模式勾选与全选分享全程保留。
                switch arrangement {
                case .grid:
                    gridView.padding(.top, 22)
                case .list:
                    listView.padding(.top, 16)
                case .showcase:
                    if let feature {
                        featureCard(feature).padding(.top, 24)
                        hangingRow.padding(.top, 26)
                    }
                case .flip:
                    flipView.padding(.top, 22)
                case .magazine:
                    magazineView.padding(.top, 22)
                case .library:
                    libraryView.padding(.top, 24)
                case .hanging:
                    hangingFullView.padding(.top, 24)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: 顶部栏

    private var topBar: some View {
        HStack(alignment: .center) {
            Spacer(minLength: 0)

            Menu {
                ForEach(ShelfFilter.allCases) { f in
                    Button {
                        onFilter(f)
                    } label: {
                        HStack {
                            Text(f.title)
                            Spacer()
                            if f == currentFilter { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(localized("书架"))
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(ShelfInk.strong(scheme))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassCapsule(scheme)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                // ≡ 视图切换菜单 —— 一比一对应视频新版（2.0.7）的菜单结构：
                // 选择 / 分组 › / 排序(最近阅读·添加日期) / 格式 书名 / 书架显示 ›
                Menu {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { isManaging.toggle() }
                    } label: {
                        Label(localized(isManaging ? "完成" : "选择"), systemImage: "checkmark.circle")
                    }
                    Divider()

                    // 分组：沿用书架分类维度（全部/本地/漫画/视频/听书/养肥）
                    Menu {
                        ForEach(ShelfFilter.allCases) { f in
                            Button {
                                onFilter(f)
                            } label: {
                                HStack {
                                    Text(f.title)
                                    Spacer()
                                    if f == currentFilter { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Label(localized("分组"), systemImage: "folder")
                    }

                    Divider()

                    // 排序：最近阅读 / 添加日期（视频里就这两项为主，书名作第三项保留）
                    Picker(localized("排序"), selection: Binding(
                        get: { currentSort },
                        set: { onSort($0) }
                    )) {
                        ForEach(ShelfSort.allCases) { s in
                            Text(s.title).tag(s)
                        }
                    }

                    Divider()

                    // 格式：书名（视频固定显示格式）
                    Label(localized("格式　书名"), systemImage: "textformat")

                    Divider()

                    // 书架显示：视频 7 种模式整页切换
                    Menu {
                        ForEach(StageArrangement.allCases) { a in
                            Button {
                                withAnimation(.snappy(duration: 0.2)) { arrangement = a }
                            } label: {
                                HStack {
                                    Label(a.title, systemImage: a.icon)
                                    Spacer()
                                    if a == arrangement { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Label(localized("书架显示"), systemImage: "square.grid.2x2")
                    }
                    Toggle(localized("封面背景模糊"), isOn: $coverBlur)
                    Divider()
                    Button {
                        onSwitchToClassic()
                    } label: {
                        Label(localized("经典书架"), systemImage: "rectangle.grid.2x2")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ShelfInk.strong(scheme))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)

                Divider().frame(height: 18).opacity(0.4)

                Button { onAdd() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ShelfInk.strong(scheme))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }
            .glassCapsule(scheme)
        }
        .padding(.top, 6)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ShelfInk.muted(scheme))
            TextField(localized("搜索书架：书名 / 作者"), text: $search)
                .font(.system(size: 13))
                .foregroundStyle(ShelfInk.strong(scheme))
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(ShelfInk.muted(scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(PaperPalette.card(scheme).opacity(0.65))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(PaperPalette.hairline(scheme).opacity(0.5), lineWidth: 0.6)
        }
    }

    // MARK: 大封面主角

    private func featureCard(_ book: ReadingBook) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { proxy in
                let w = proxy.size.width
                // 一比一复刻青苔：封面宽约 55% 屏宽，宽高比 1:1.30（实测官方录屏）
                let cw = min(212, w * 0.55)
                let ch = cw * 1.30
                HStack {
                    Spacer(minLength: 0)
                    stageCover(book, width: cw, height: ch)
                    Spacer(minLength: 0)
                }
                .frame(height: ch)
            }
            .frame(height: 320)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.author)
                        .font(.system(size: 12))
                        .foregroundStyle(ShelfInk.soft(scheme))
                    Text(book.title)
                        .font(PaperFont.serif(21))
                        .foregroundStyle(ShelfInk.strong(scheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PaperPalette.hairline(scheme).opacity(0.5))
                                Capsule().fill(PaperPalette.ink(scheme))
                                    .frame(width: g.size.width * CGFloat(min(max(book.currentPosition, 0), 1)))
                            }
                        }
                        .frame(height: 5)
                        Text(book.currentPosition > 0 ? "\(Int(book.currentPosition * 100))%" : localized("未读"))
                            .font(.system(size: 11))
                            .foregroundStyle(ShelfInk.muted(scheme))
                            .frame(width: 42, alignment: .trailing)
                    }
                    .padding(.top, 3)
                }
                Spacer(minLength: 8)
                // ... 按钮，点击弹出与长按相同的菜单（保证入口可见）
                Menu {
                    bookMenuItems(book)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ShelfInk.soft(scheme))
                        .frame(width: 36, height: 36)
                        .glassCapsule(scheme)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 18)
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenBook(book) }
        .contextMenu { bookMenuItems(book) }
    }

    @ViewBuilder
    private func bookMenuItems(_ book: ReadingBook) -> some View {
        Button {
            if !onOpenAudiobook(book) { onOpenBook(book) }
        } label: {
            Label(localized("打开"), systemImage: "book")
        }
        Button { onDetail(book) } label: {
            Label(localized("书籍详情"), systemImage: "books.vertical")
        }
        Button { onEdit(book) } label: {
            Label(localized("编辑书籍资讯"), systemImage: "square.and.pencil")
        }
        Button { onCoverSearch(book) } label: {
            Label(localized("搜索网络封面"), systemImage: "photo.on.rectangle.angled")
        }
        Button { onFattening(book) } label: {
            Label(localized("加入养肥"), systemImage: "leaf")
        }
        Button(role: .destructive) { onDelete(book) } label: {
            Label(localized("删除"), systemImage: "trash")
        }
    }

    private func stageCover(_ book: ReadingBook, width: CGFloat, height: CGFloat) -> some View {
        BookshelfCoverStyle.artwork(
            for: book,
            colorScheme: scheme,
            displaySize: CGSize(width: width, height: height)
        )
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .leading) {
            LinearGradient(colors: [Color.black.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, x: 4, y: 12)
        .accessibilityHidden(true)
    }

    // MARK: 管理模式（全选 / 分享 / 删除 —— 与经典书架一致）

    private var manageBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    if isAllSelected { selection = [] }
                    else { selection = Set(selectable.map(\.id)) }
                }
            } label: {
                Text(localized(isAllSelected ? "全不选" : "全选"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(ShelfInk.strong(scheme))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassCapsule(scheme)
            }
            .buttonStyle(.plain)
            .disabled(selectable.isEmpty)

            Text("\(selection.count) \(localized("已选"))")
                .font(.system(size: 12))
                .foregroundStyle(ShelfInk.muted(scheme))

            // 分享选中的书（本地文件）—— 与经典书架同一份能力，7 种模式下都在。
            ShareLink(items: shareableURLs) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ShelfInk.strong(scheme))
                    .frame(width: 30, height: 30)
                    .glassCircle(scheme)
            }
            .disabled(shareableURLs.isEmpty)
            .accessibilityLabel(localized("分享"))

            Spacer()

            Button {
                onDeleteSelected()
            } label: {
                Text(localized("删除"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .glassCapsule(scheme)
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
        }
    }

    // MARK: - 7 种显示模式（视频「书架显示」逐字：宫格/列表/展台/翻阅/杂志/图书馆/挂绳）
    //
    // 每一种模式里的书都挂完整长按菜单 bookMenuItems（打开/详情/编辑/封面/养肥/删除），
    // 管理模式下的勾选圈、顶部全选/分享/删除 manageBar 全部贯通，不因模式切换而丢失。

    /// 勾选圈：管理模式叠在每本书封面右上角，点击切换选中。
    @ViewBuilder
    private func selectBadge(_ book: ReadingBook) -> some View {
        if isManaging {
            Image(systemName: selection.contains(book.id) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(
                    selection.contains(book.id)
                        ? ShelfInk.strong(scheme)
                        : Color.white.opacity(0.92)
                )
                .shadow(color: .black.opacity(0.35), radius: 3)
                .padding(6)
                .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }

    /// 统一的书本点击：管理模式勾选，普通模式打开（听书优先走播放器）。
    private func activate(_ book: ReadingBook) {
        if isManaging {
            if selection.contains(book.id) { selection.remove(book.id) }
            else { selection.insert(book.id) }
        } else if !onOpenAudiobook(book) {
            onOpenBook(book)
        }
    }

    // MARK: 宫格（视频：2 列封面，每本下方书名/作者/进度 + … 按钮）

    private var gridView: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 2), spacing: 24) {
            ForEach(filteredBooks) { book in
                VStack(alignment: .leading, spacing: 7) {
                    GeometryReader { g in
                        let cw = g.size.width
                        let ch = cw * 1.34
                        ZStack(alignment: .topTrailing) {
                            stageCover(book, width: cw, height: ch)
                            selectBadge(book)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { activate(book) }
                        .contextMenu { bookMenuItems(book) }
                        .frame(width: cw, height: ch)
                    }
                    .frame(height: (UIScreen.main.bounds.width - 40 - 14) / 2 * 1.34)

                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ShelfInk.strong(scheme))
                                .lineLimit(1)
                            Text(book.author.isEmpty ? "—" : book.author)
                                .font(.system(size: 11))
                                .foregroundStyle(ShelfInk.soft(scheme))
                                .lineLimit(1)
                            Text(book.currentPosition > 0 ? "\(Int(book.currentPosition * 100))%" : localized("未读"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(ShelfInk.muted(scheme))
                        }
                        Spacer(minLength: 2)
                        Menu {
                            bookMenuItems(book)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ShelfInk.muted(scheme))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: 列表（视频：每行小封面 + 书名/作者/进度）

    private var listView: some View {
        LazyVStack(spacing: 0) {
            ForEach(filteredBooks) { book in
                HStack(spacing: 14) {
                    ZStack(alignment: .topTrailing) {
                        stageCover(book, width: 58, height: 82)
                        selectBadge(book)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(ShelfInk.strong(scheme))
                            .lineLimit(1)
                        Text(book.author.isEmpty ? "—" : book.author)
                            .font(.system(size: 12))
                            .foregroundStyle(ShelfInk.soft(scheme))
                            .lineLimit(1)
                        Text(book.currentPosition > 0 ? "\(Int(book.currentPosition * 100))% · \(localized("在读"))" : localized("未读"))
                            .font(.system(size: 11))
                            .foregroundStyle(ShelfInk.muted(scheme))
                            .lineLimit(1)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(PaperPalette.hairline(scheme).opacity(0.5))
                                Capsule().fill(PaperPalette.ink(scheme))
                                    .frame(width: g.size.width * CGFloat(min(max(book.currentPosition, 0), 1)))
                            }
                        }
                        .frame(height: 4)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        bookMenuItems(book)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ShelfInk.muted(scheme))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .onTapGesture { activate(book) }
                .contextMenu { bookMenuItems(book) }
                Divider().opacity(0.35)
            }
        }
    }

    // MARK: 翻阅（视频：横向大卡片一本一本翻，带页码）

    private var flipView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 18) {
                ForEach(Array(filteredBooks.enumerated()), id: \.offset) { idx, book in
                    VStack(spacing: 12) {
                        ZStack(alignment: .topTrailing) {
                            stageCover(book, width: 230, height: 300)
                            selectBadge(book)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { activate(book) }
                        .contextMenu { bookMenuItems(book) }
                        Text("\(idx + 1) / \(filteredBooks.count)")
                            .font(.system(size: 11)).foregroundStyle(ShelfInk.muted(scheme))
                        Text(book.title)
                            .font(PaperFont.serif(16))
                            .foregroundStyle(ShelfInk.strong(scheme))
                            .lineLimit(1)
                    }
                    .frame(width: 230)
                }
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 8)
        }
    }

    // MARK: 杂志（视频：大图主导的杂志化排版，交错封面 + 书名块）

    private var magazineView: some View {
        LazyVStack(spacing: 28) {
            ForEach(Array(filteredBooks.enumerated()), id: \.offset) { idx, book in
                HStack(alignment: .top, spacing: 16) {
                    if idx % 2 == 1 { Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .topTrailing) {
                            stageCover(book, width: 168, height: 224)
                            selectBadge(book)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { activate(book) }
                        .contextMenu { bookMenuItems(book) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.title)
                                .font(PaperFont.serif(16))
                                .foregroundStyle(ShelfInk.strong(scheme))
                                .lineLimit(2)
                            Text(book.author.isEmpty ? "—" : book.author)
                                .font(.system(size: 11.5))
                                .foregroundStyle(ShelfInk.soft(scheme))
                        }
                    }
                    .frame(width: 168, alignment: .leading)
                    if idx % 2 == 0 { Spacer(minLength: 0) }
                }
            }
        }
    }

    // MARK: 图书馆（视频：一排竖立书脊陈列，可横滑）

    private var libraryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(Array(filteredBooks.enumerated()), id: \.offset) { idx, book in
                        ZStack(alignment: .topTrailing) {
                            spine(for: book, tilt: (idx % 3 - 1) == 0 ? 0 : Double(idx % 3 - 1) * 2.5)
                            selectBadge(book)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { activate(book) }
                        .contextMenu { bookMenuItems(book) }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            }
            // 木质书架搁板
            Rectangle()
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.31, blue: 0.21), Color(red: 0.30, green: 0.21, blue: 0.14)], startPoint: .top, endPoint: .bottom))
                .frame(height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 4, y: 3)
        }
    }

    // MARK: 挂绳（视频：木夹子夹住正面封面，挂在线上，可多行）

    private var hangingFullView: some View {
        // 视频真实：一整条挂绳，书横向排成一排可左右滑动（不是多行静态网格）
        VStack(spacing: 0) {
            // 挂绳横线
            Rectangle()
                .fill(Color(red: 0.72, green: 0.62, blue: 0.46))
                .frame(height: 1.5)
                .padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(filteredBooks) { book in
                        VStack(spacing: 5) {
                            hangingBook(book)
                            Text(book.title)
                                .font(.system(size: 10))
                                .foregroundStyle(ShelfInk.soft(scheme))
                                .lineLimit(1)
                                .frame(width: 88)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { activate(book) }
                        .contextMenu { bookMenuItems(book) }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            }
        }
    }

    /// 把数组按 n 个一组切分，供挂绳多行布局用。
    private func chunked(_ array: [ReadingBook], _ n: Int) -> [[ReadingBook]] {
        guard n > 0 else { return [] }
        var result: [[ReadingBook]] = []
        var i = 0
        while i < array.count {
            result.append(Array(array[i..<min(i + n, array.count)]))
            i += n
        }
        return result
    }

    // MARK: 展台下方挂绳（大封面下方那一排：木夹 + 正面封面）

    private var hangingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(otherBooks.prefix(12)) { book in
                    hangingBook(book)
                        .contentShape(Rectangle())
                        .onTapGesture { activate(book) }
                        .contextMenu { bookMenuItems(book) }
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 16)
        }
        .background(alignment: .top) {
            // 挂绳横线
            Rectangle()
                .fill(Color(red: 0.72, green: 0.62, blue: 0.46))
                .frame(height: 1.5)
                .padding(.top, 10)
        }
    }

    /// 木夹子 + 正面封面（视频真实：挂绳模式下书是正面朝前，不是书脊）。
    private func hangingBook(_ book: ReadingBook) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: 0.66, green: 0.48, blue: 0.27))
                .frame(width: 15, height: 20)
                .shadow(color: .black.opacity(0.32), radius: 2, x: 0, y: 1)
                .zIndex(2)
            ZStack(alignment: .topTrailing) {
                stageCover(book, width: 76, height: 108)
                selectBadge(book)
            }
        }
    }

    // MARK: 书脊辅助（图书馆模式 + 书脊颜色派生）

    private func spine(for book: ReadingBook, tilt: Double) -> some View {
        let h: CGFloat = 132
        return ZStack(alignment: .center) {
            BookshelfCoverStyle.artwork(for: book, colorScheme: scheme, displaySize: CGSize(width: 92, height: h))
                .frame(width: 46, height: h)
                .clipped()
                .overlay(
                    LinearGradient(colors: [Color.black.opacity(0.3), .clear, Color.black.opacity(0.2)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 46)
                )
            VStack(spacing: 1) {
                ForEach(Array(book.title.prefix(8).enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 1)
        }
        .frame(width: 46, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 5, x: 2, y: 4)
        .rotationEffect(.degrees(tilt), anchor: .bottom)
    }

    /// 由书名稳定派生书脊颜色，保证同一本书颜色一致。
    private func spineColor(for book: ReadingBook) -> Color {
        let palette: [Color] = [
            Color(red: 0.42, green: 0.32, blue: 0.27),
            Color(red: 0.20, green: 0.24, blue: 0.31),
            Color(red: 0.31, green: 0.22, blue: 0.16),
            Color(red: 0.36, green: 0.36, blue: 0.34),
            Color(red: 0.24, green: 0.30, blue: 0.24),
            Color(red: 0.44, green: 0.35, blue: 0.22),
        ]
        let h = abs(book.title.unicodeScalars.reduce(0) { $0 + Int($1.value) })
        return palette[h % palette.count]
    }

    // MARK: 空态

    private var emptyStage: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 34)).foregroundStyle(ShelfInk.muted(scheme))
            Text(localized("书架还是空的")).font(PaperFont.serif(20)).foregroundStyle(ShelfInk.strong(scheme))
            Button { onAdd() } label: {
                Text(localized("添加书籍"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ShelfInk.strong(scheme))
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .glassCapsule(scheme)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var noResult: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 30)).foregroundStyle(ShelfInk.muted(scheme))
            Text(localized("没有找到匹配的书")).font(.system(size: 14)).foregroundStyle(ShelfInk.soft(scheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }
}

// MARK: - 书架展台木质背景（一比一复刻青苔展台）
//
// 与首页展台同一套质感：顶部深棕木质、向下渐隐到页面色。
// 颜色取自官方高清录屏实测主色（#736C5F / #AAA59A）。深浅各一套。
private struct ShelfShowcaseWoodBackdrop: View {
    let scheme: ColorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    stops: scheme == .dark ? [
                        .init(color: Color(red: 0.15, green: 0.13, blue: 0.11), location: 0),
                        .init(color: Color(red: 0.24, green: 0.21, blue: 0.18), location: 0.30),
                        .init(color: Color(red: 0.30, green: 0.27, blue: 0.23).opacity(0.55), location: 0.50),
                        .init(color: Color.clear, location: 0.70),
                    ] : [
                        .init(color: Color(red: 0.40, green: 0.37, blue: 0.32), location: 0),
                        .init(color: Color(red: 0.53, green: 0.50, blue: 0.44), location: 0.22),
                        .init(color: Color(red: 0.67, green: 0.64, blue: 0.59), location: 0.42),
                        .init(color: Color(red: 0.82, green: 0.80, blue: 0.77).opacity(0.5), location: 0.58),
                        .init(color: Color.clear, location: 0.74),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white.opacity(scheme == .dark ? 0.012 : 0.022))
                            .frame(height: 1)
                            .padding(.horizontal, 12)
                        Spacer().frame(height: proxy.size.height * 0.055)
                    }
                }
                .opacity(0.9)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .clear, location: 0.62),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
    }
}
