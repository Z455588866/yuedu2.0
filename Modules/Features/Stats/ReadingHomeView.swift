import SwiftUI

// MARK: - 首页模式
//
// 顶部「主页⌄」是模式切换器（对标参考 App）：展台 / 手账 / 经典 / 拟物 / 杂志 / 图书馆。
// 每种模式是一套独立的首页布局；当前模式存 UserDefaults，切换后立即生效。

enum HomeMode: String, CaseIterable, Identifiable {
    case stage, journal, classic, skeuomorphic, magazine, library
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stage:        return localized("展台")
        case .journal:      return localized("手账")
        case .classic:      return localized("经典")
        case .skeuomorphic: return localized("拟物")
        case .magazine:     return localized("杂志")
        case .library:      return localized("图书馆")
        }
    }
}

// MARK: - 首页
//
// maintainer, 2026-11-21: 一比一复刻参考 App 的六种首页，并支持顶部「主页⌄」实时切换。
// 六套布局：展台(大封面轮播) / 经典(继续阅读卡片流) / 手账(统计流) /
// 拟物(阅读目标大圆环) / 杂志(阅读特刊) / 图书馆(书房阅览室)。
// 所有颜色取自 PaperPalette / DSColor，背景用 PaperBackground(scope: .global)，
// 跟随主题、背景图与深浅模式联动（与书架同一套机制，不做成单独的背景）。
// 开书 / 听书 / 长按删除 / 阅读统计 / 全部统计数据来源等 machinery 原样保留。

struct ReadingHomeView: View {
    /// 书架 is another root tab; the shell hands the switch down.
    var onOpenBookshelf: () -> Void

    init(onOpenBookshelf: @escaping () -> Void = {}) {
        self.onOpenBookshelf = onOpenBookshelf
    }

    @EnvironmentObject private var store: BookStore
    @Environment(\.colorScheme) private var scheme

    @Bindable private var gs = GlobalSettings.shared
    @ObservedObject private var stats = ReadingStatsStore.shared
    @ObservedObject private var subscription = SubscriptionStore.shared

    /// 当前首页模式（持久化）。
    @AppStorage("yd_home_page_mode") private var modeRaw: String = HomeMode.stage.rawValue
    private var mode: HomeMode { HomeMode(rawValue: modeRaw) ?? .stage }

    @State private var readingBookID: UUID?
    /// 首页书卡「听书」耳机按钮点下的那一本：打开阅读器后自动开始朗读（仅此入口开启）。
    @State private var autoListenBookID: UUID?
    @State private var showsStats = false
    @State private var now = Date()

    @State private var pendingDeleteBook: ReadingBook?
    @State private var showsDeleteConfirm = false

    @State private var centeredBookID: UUID?
    @State private var centeredCoverFrame: CGRect?
    @State private var restingBookID: UUID?

    private static let carouselSpace = "homeCarousel"
    /// 每日阅读目标（分钟）：默认 30 分钟，用户可在「调整目标」里改，存进 UserDefaults。
    /// 之前是 private static let 15，写死的，所以界面上那个「调整目标 ···」点了没反应。
    @AppStorage("yd_daily_goal_minutes") private var goalMinutes: Int = 30
    /// 调整目标面板是否显示。
    @State private var showsGoalEditor = false
    /// 面板里正在挑的值（点「完成」才写回 goalMinutes，取消不生效）。
    @State private var draftGoalMinutes: Int = 30

    private var carouselBooks: [ReadingBook] {
        // 展示全部书籍，不再截断——否则加了 16 本只显示 12 本。
        // 居中/滚动定位都按 book.id 查找，不依赖固定数量，去掉上限无副作用。
        return store.books.sorted {
            ($0.lastOpenedDate ?? $0.addedDate) > ($1.lastOpenedDate ?? $1.addedDate)
        }
    }

    private var centeredBook: ReadingBook? {
        guard let id = restingBookID ?? centeredBookID else { return carouselBooks.first }
        return carouselBooks.first { $0.id == id } ?? carouselBooks.first
    }

    private var centeredIndex: Int {
        guard let book = centeredBook,
              let index = carouselBooks.firstIndex(where: { $0.id == book.id })
        else { return 0 }
        return index
    }

    private var showsArtwork: Bool {
        guard subscription.hasAccess(.readerThemePacks) else { return false }
        return gs.resolvedPageBackgroundSlice(for: .global, colorScheme: scheme) != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                topBar
                switch mode {
                case .stage:        stageContent
                case .classic:      classicContent
                case .journal:      journalContent
                case .skeuomorphic: skeuomorphicContent
                case .magazine:     magazineContent
                case .library:      libraryContent
                }
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background {
            ZStack(alignment: .bottom) {
                PaperBackground(scope: .global)
                // 一比一复刻青苔展台：深棕木质展台背景，向下渐隐到页面色。
                // 仅在展台模式、且用户未设置主题背景图时显示；设了背景图则整层让位，
                // 因此仍然跟随主题（换主题 / 深浅模式都会变），不是写死的独立背景。
                if mode == .stage && !showsArtwork {
                    ShowcaseWoodBackdrop(scheme: scheme)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
                LinearGradient(
                    stops: [
                        .init(color: PaperPalette.page(scheme).opacity(0), location: 0),
                        .init(color: PaperPalette.page(scheme).opacity(0.28), location: 0.55),
                        .init(color: PaperPalette.page(scheme).opacity(0.6), location: 1),
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
        .onAppear {
            now = Date()
            settleCarousel()
        }
        .onChange(of: store.books.count) { _, _ in settleCarousel() }
        // 在书架/TTS/任意入口读了一本书时，BookStore 会发出 bookOpened。这里实时把那本
        // 设为轮播焦点：carouselBooks 按 lastOpenedDate 排序，刚读的会自动排到第一位，
        // 于是「继续阅读」大卡和「最近阅读」横排都跟着刷新，不再要等重启才同步。
        .onReceive(store.bookOpened) { bookId in
            withAnimation(.easeInOut(duration: 0.25)) {
                focusBook(bookId)
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { readingBookID != nil },
            set: { isPresented in
                guard !isPresented else { return }
                readingBookID = nil
                autoListenBookID = nil
                recenterCarousel()
            }
        )) {
            if let id = readingBookID {
                BookReaderView(bookId: id, openingAutoListen: id == autoListenBookID)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showsStats) {
            NavigationStack { ReadingStatsView() }
        }
        .sheet(isPresented: $showsGoalEditor) { goalEditorSheet }
        .alert(localized("从书架删除"), isPresented: $showsDeleteConfirm) {
            Button(localized("删除"), role: .destructive) {
                if let book = pendingDeleteBook {
                    store.delete(bookId: book.id)
                    pendingDeleteBook = nil
                }
            }
            Button(localized("取消"), role: .cancel) { pendingDeleteBook = nil }
        } message: {
            if let book = pendingDeleteBook {
                Text(String(format: localized("确定要从书架删除《%@》吗？这本书及其阅读进度会被一并移除。"), book.title))
            }
        }
    }

    // MARK: - Machinery (kept)

    private func settleCarousel() {
        guard !carouselBooks.isEmpty else {
            centeredBookID = nil
            restingBookID = nil
            return
        }
        if let current = restingBookID, carouselBooks.contains(where: { $0.id == current }) {
            return
        }
        let target = store.books
            .filter { $0.lastOpenedDate != nil }
            .max { ($0.lastOpenedDate ?? .distantPast) < ($1.lastOpenedDate ?? .distantPast) }
        let settled = target?.id ?? carouselBooks.first?.id
        centeredBookID = settled
        restingBookID = settled
    }

    /// 刚打开的书：把它设为轮播焦点。carouselBooks 已按 lastOpenedDate 排序，bookId 现在排在
    /// 第一位；更新 centeredBookID/restingBookID 让「继续阅读」大卡与滚动位置一起落到它上面。
    /// 若这本书不在书架（例如已被移除），则退回最近读的一本。
    private func focusBook(_ bookId: UUID) {
        guard carouselBooks.contains(where: { $0.id == bookId }) else {
            settleCarousel()
            return
        }
        centeredBookID = bookId
        restingBookID = bookId
    }

    private func settleResting(_ book: ReadingBook, midX: CGFloat, middle: CGFloat, slot: CGFloat) {
        guard abs(midX - middle) < slot * 0.5 else { return }
        if restingBookID != book.id { restingBookID = book.id }
    }

    private func openBook(_ book: ReadingBook) {
        guard !NowPlayingHub.shared.openIfAudiobook(book, store: store) else { return }
        if ReaderOpener.open(
            bookID: book.id,
            store: store,
            coverFrame: centeredCoverFrame,
            onDismiss: { recenterCarousel() }
        ) { return }
        readingBookID = book.id
    }

    private func listen(_ book: ReadingBook) {
        // 有声书：直接交给全局播放器播放。
        if NowPlayingHub.shared.openIfAudiobook(book, store: store) { return }
        // 普通文字书：打开阅读器并请求自动开始 TTS 朗读（打开即听书），
        // 而不是只打开一个静止的阅读页。仅本入口开启 openingAutoListen。
        autoListenBookID = book.id
        readingBookID = book.id
        store.updateLastOpened(bookId: book.id)
    }

    private func recenterCarousel() {
        guard let id = restingBookID ?? carouselBooks.first?.id else { return }
        centeredBookID = id
    }

    func requestDelete(_ book: ReadingBook) {
        pendingDeleteBook = book
        showsDeleteConfirm = true
    }

    // MARK: - Top bar (模式切换 + ... 菜单)

    private var topBar: some View {
        HStack(alignment: .center) {
            Menu {
                ForEach(HomeMode.allCases) { m in
                    Button { modeRaw = m.rawValue } label: {
                        HStack {
                            Text(m.label)
                            Spacer()
                            if m == mode { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(mode.label)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(PaperPalette.textPrimary(scheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .barButtonGlass(in: Capsule(), scheme: scheme)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home_page_menu")

            Spacer()

            Menu {
                Button { showsStats = true } label: {
                    Label(localized("阅读统计"), systemImage: "chart.bar")
                }
                Button { onOpenBookshelf() } label: {
                    Label(localized("打开书架"), systemImage: "books.vertical")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                    .frame(width: 36, height: 36)
                    .barButtonGlass(in: Circle(), scheme: scheme)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home_more_menu")
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }

    // MARK: - 共用小组件

    private func sectionHeader(_ title: String, showsChevron: Bool = false, trailing: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PaperPalette.textPrimary(scheme))
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11, weight: .medium)).foregroundStyle(PaperPalette.textTertiary(scheme)) }
        }
    }

    /// 杂志 / 图书馆模式里的双语小标题（中文 + 大写英文）。
    private func bilingualHeader(_ cn: String, _ en: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(cn).font(.system(size: 15, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
            Spacer()
            Text(en).font(.system(size: 10, weight: .semibold)).foregroundStyle(PaperPalette.textTertiary(scheme))
                .kerning(1.2)
        }
    }

    private func progressBar(progress: Double) -> some View {
        let p = min(max(progress, 0), 1)
        // 一比一复刻青苔：黑色粗进度条(约9pt)，浅灰轨道，25% 灰字
        return HStack(spacing: 10) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.3))
                    Capsule().fill(Color(red: 0.08, green: 0.08, blue: 0.08))
                        .frame(width: g.size.width * CGFloat(p))
                }
            }
            .frame(height: 9)
            Text("\(Int(p * 100))%")
                .font(.system(size: 12))
                .foregroundStyle(PaperPalette.textTertiary(scheme))
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
        }
    }

    private func statusPill(systemImage: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(PaperPalette.textSecondary(scheme))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .clearGlassSurface(in: Capsule(), fill: PaperPalette.card(scheme))
        .overlay(Capsule().strokeBorder(PaperPalette.hairline(scheme).opacity(0.5), lineWidth: 0.6))
    }

    private func cover(_ book: ReadingBook, width: CGFloat, height: CGFloat) -> some View {
        BookshelfCoverStyle.artwork(
            for: book,
            colorScheme: scheme,
            displaySize: CGSize(width: width, height: height)
        )
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.24), radius: 10, x: 2, y: 5)
        .accessibilityHidden(true)
    }

    private func chapterTitle(of book: ReadingBook) -> String? {
        guard let chapters = book.onlineChapters, !chapters.isEmpty else { return nil }
        let position = min(max(book.currentPosition, 0), 1)
        let index = min(chapters.count - 1, max(0, Int(position * Double(chapters.count))))
        return chapters[index].title
    }

    private func emptyHint(_ text: String = localized("去书架挑一本，这里就会亮起来。")) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical").font(.system(size: 34)).foregroundStyle(PaperPalette.textTertiary(scheme))
            Text(localized("书架还是空的")).font(PaperFont.serif(19))
            Text(text).font(.system(size: 12.5)).foregroundStyle(PaperPalette.textSecondary(scheme))
        }
        .foregroundStyle(PaperPalette.textPrimary(scheme))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - 日期与状态（展台 / 经典 / 手账）

    private var weekdayText: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "EEEE"
        return f.string(from: now)
    }
    private var shortWeekdayText: String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "EEE"
        return f.string(from: now)
    }
    private var dateText: String {
        let cal = Calendar.current
        return "\(cal.component(.month, from: now))月\(cal.component(.day, from: now))日"
    }

    private var dateMasthead: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(weekdayText).font(.system(size: 13, weight: .medium)).foregroundStyle(PaperPalette.textTertiary(scheme))
            Text(dateText)
                .font(.system(size: 40, weight: .bold, design: .default))
                .foregroundStyle(PaperPalette.textPrimary(scheme))
                .padding(.top, 4)
            HStack(spacing: 8) {
                statusPill(systemImage: "book.closed", text: todaySeconds == 0
                    ? localized("今天还没开始读")
                    : String(format: localized("今日阅读 %d 分钟"), todaySeconds / 60))
                statusPill(systemImage: "flame", text: String(format: localized("连续 %d 天"), consecutiveDays))
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 26)
    }

    private var dateHeaderSmall: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(weekdayText).font(.system(size: 12, weight: .medium)).foregroundStyle(PaperPalette.textTertiary(scheme))
            Text(dateText).font(.system(size: 28, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
            HStack(spacing: 6) {
                Text(todaySeconds == 0 ? localized("今天还没开始读") : String(format: localized("今日阅读 %d 分钟"), todaySeconds / 60))
                Text("·")
                Text(String(format: localized("连续 %d 天"), consecutiveDays))
            }
            .font(.system(size: 11))
            .foregroundStyle(PaperPalette.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 20)
    }

    // MARK: - 统计卡片（各模式共用）

    private var todayRingCard: some View {
        VStack(spacing: 12) {
            Button { openGoalEditor() } label: {
                sectionHeader(localized("阅读目标"), showsChevron: true, trailing: localized("调整目标　···"))
            }
            .buttonStyle(.plain)
            HStack(spacing: 18) {
                smallRing(progress: min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1), size: 74, line: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(clockString(todaySeconds))
                        .font(.system(size: 28, weight: .bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.55)
                        .foregroundStyle(PaperPalette.textPrimary(scheme))
                    Text(goalLabel)
                        .font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                    HStack(spacing: 14) {
                        Label(String(format: localized("阅读 %@"), durationText(todaySeconds / 60)), systemImage: "book.closed")
                        Label(localized("听书 0 分钟"), systemImage: "headphones")
                    }
                    .font(.system(size: 11)).foregroundStyle(PaperPalette.textSecondary(scheme))
                }
                Spacer()
            }
        }
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    private func smallRing(progress: CGFloat, size: CGFloat, line: CGFloat) -> some View {
        ZStack {
            Circle().stroke(PaperPalette.hairline(scheme).opacity(0.45), lineWidth: line)
            Circle().trim(from: 0, to: progress)
                .stroke(PaperPalette.ink(scheme), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(localized("连续阅读"))
            HStack(alignment: .firstTextBaseline) {
                Text("\(consecutiveDays)").font(.system(size: 38, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(localized("天")).font(.system(size: 14)).foregroundStyle(PaperPalette.textSecondary(scheme))
                Spacer()
                Text(String(format: localized("最长记录 %d 天"), longestStreak))
                    .font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            weekBars
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    private var weekBars: some View {
        let labels = ["一", "二", "三", "四", "五", "六", "日"]
        return HStack(spacing: 10) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(weekRead(i) ? PaperPalette.ink(scheme) : PaperPalette.hairline(scheme).opacity(0.4))
                        .frame(height: weekRead(i) ? 38 : 24)
                    Text(labels[i]).font(.system(size: 10)).foregroundStyle(PaperPalette.textTertiary(scheme))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var yearCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(localized("今年已读"))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(finishedThisYear)").font(.system(size: 38, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Text("/ \(store.books.count) \(localized("本"))").font(.system(size: 15)).foregroundStyle(PaperPalette.textSecondary(scheme))
            }
            GeometryReader { g in
                let p = store.books.isEmpty ? 0 : CGFloat(finishedThisYear) / CGFloat(store.books.count)
                ZStack(alignment: .leading) {
                    Capsule().fill(PaperPalette.hairline(scheme).opacity(0.45))
                    Capsule().fill(PaperPalette.ink(scheme)).frame(width: g.size.width * p)
                }
            }
            .frame(height: 6)
            Text(localized("读到最后章节末会自动记为读完，也可以在书架「…」里标记"))
                .font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(localized("阅读计划"))
            Text(localized("给一本书定个节奏，按日或按周，慢慢读完。"))
                .font(.system(size: 12)).foregroundStyle(PaperPalette.textSecondary(scheme))
            Button { showsStats = true } label: {
                Text(localized("新建阅读计划"))
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(PaperPalette.textSecondary(scheme))
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Capsule().fill(PaperPalette.iconTile(scheme)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    private var statsLink: some View {
        Button { showsStats = true } label: {
            HStack { sectionHeader(localized("阅读统计"), showsChevron: true); Spacer() }
        }
        .buttonStyle(.plain)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    // MARK: - ① 展台（stage）

    private var stageContent: some View {
        Group {
            dateMasthead
            carousel
            bookInfo
            goalCard
            streakCard
            yearCard
            planCard
            statsLink
        }
    }

    private var carousel: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            // 一比一复刻青苔展台：书封宽度约 54.6% 屏宽，宽高比 1:1.30
            // （实测官方录屏：书封左22.7%/右77.3% → 宽54.6%；上34%/下67% → 高33%；
            //   以 iPhone 393×852 计，宽≈215pt、高≈281pt，宽高比≈1.30）
            let slot = min(224, width * 0.546)
            let coverWidth = slot
            let coverHeight = coverWidth * 1.30

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(carouselBooks) { book in
                        cover(book, width: coverWidth, height: coverHeight)
                            .frame(width: slot, height: proxy.size.height)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.onChange(
                                        of: geometry.frame(in: .named(Self.carouselSpace)).midX,
                                        initial: true
                                    ) { _, midX in
                                        settleResting(book, midX: midX, middle: width / 2, slot: slot)
                                    }
                                }
                            }
                            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(CGFloat(1 - abs(phase.value) * 0.16))
                                    .opacity(1 - abs(phase.value) * 0.25)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { openBook(book) }
                            .onLongPressGesture { requestDelete(book) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(book.title)
                            .accessibilityValue(book.author)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, max(0, (width - slot) / 2 - 26), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centeredBookID, anchor: .center)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .coordinateSpace(.named(Self.carouselSpace))
            .onChange(of: proxy.frame(in: .global), initial: true) { _, global in
                centeredCoverFrame = CGRect(
                    x: global.minX + (global.width - coverWidth) / 2,
                    y: global.minY + (global.height - coverHeight) / 2,
                    width: coverWidth,
                    height: coverHeight
                )
            }
        }
        .frame(height: 360)
        .padding(.top, 22)
    }

    private var bookInfo: some View {
        Group {
            if let book = centeredBook {
                VStack(alignment: .leading, spacing: 0) {
                    // 作者/书名/章节在左，黑色实心耳机圆在右垂直居中（一比一复刻青苔）
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            if !book.author.isEmpty {
                                Text(book.author).font(.system(size: 12.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
                            }
                            Text(book.title).font(.system(size: 22, weight: .heavy))
                                .foregroundStyle(PaperPalette.textPrimary(scheme)).lineLimit(2)
                            if let chapter = chapterTitle(of: book) {
                                Text(chapter).font(.system(size: 12.5)).foregroundStyle(PaperPalette.textTertiary(scheme)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)
                        Button { listen(book) } label: {
                            Image(systemName: "headphones")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .frame(width: 54, height: 54)
                                .background(Circle().fill(Color(red: 0.08, green: 0.08, blue: 0.08)))
                                .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 5)
                        }
                        .buttonStyle(.plain).accessibilityLabel(localized("听书"))
                    }
                    // 黑色粗进度条 + 25% 独占下方一行
                    progressBar(progress: book.currentPosition)
                        .padding(.top, 12)
                }
                .padding(.horizontal, 24).padding(.top, 14)
            } else {
                emptyHint()
            }
        }
    }

    private var goalCard: some View {
        VStack(spacing: 14) {
            // 标题行整条可点：以前只有一个画出来的 chevron，点了没反应。
            Button { openGoalEditor() } label: {
                sectionHeader(localized("阅读目标"), showsChevron: true, trailing: localized("调整目标　···"))
            }
            .buttonStyle(.plain)
            goalRing
            Button { openCenteredOrShelf() } label: {
                Text(localized("继续阅读 · 读本书"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .glassButtonChrome(in: Capsule(), scheme: scheme)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
        .padding(.horizontal, 20).padding(.top, 30)
    }

    private func openCenteredOrShelf() {
        if let book = centeredBook { openBook(book) } else { onOpenBookshelf() }
    }

    private var goalRing: some View {
        let progress = min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1)
        return ZStack {
            Circle().stroke(PaperPalette.hairline(scheme).opacity(0.45), lineWidth: 12)
            Circle().trim(from: 0, to: progress)
                .stroke(PaperPalette.ink(scheme), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text(localized("今日阅读")).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                Text(clockString(todaySeconds)).font(.system(size: 30, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(goalLabel)
                    .font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
        }
        .frame(width: 168, height: 168)
    }

    /// 今日阅读计时：不足 1 小时显示「5:20」；
    /// 满 1 小时改为「1 小时 5 分 20 秒」，一眼看清读了几小时几分几秒。
    private func clockString(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 3600 { return String(format: "%d:%02d", s / 60, s % 60) }
        return String(format: localized("%d 小时 %d 分钟 %d 秒"), s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 纯时长文案（分钟粒度）：不足 1 小时「30 分钟」，满 1 小时「1 小时 30 分钟」。
    private func durationText(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return String(format: localized("%d 分钟"), m) }
        let h = m / 60, mm = m % 60
        return mm == 0
            ? String(format: localized("%d 小时"), h)
            : String(format: localized("%d 小时 %d 分钟"), h, mm)
    }

    /// 目标文案：带「目标」前缀。
    private var goalLabel: String { String(format: localized("目标 %@"), durationText(goalMinutes)) }

    /// 打开「调整目标」面板：把当前值带进去当初始选中项。
    private func openGoalEditor() {
        draftGoalMinutes = goalMinutes
        showsGoalEditor = true
    }

    // MARK: - ② 经典（classic）：继续阅读大卡片 + 横排书 + 阅读目标

    private var classicContent: some View {
        Group {
            if !carouselBooks.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    // 经典 = 第二张图：深棕横滑继续阅读卡 + 半圆弧阅读目标大卡
                    sectionHeader(localized("继续阅读"))
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(carouselBooks) { book in
                                classicDarkCard(book)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    classicGoalArcCard
                }
                .padding(.top, 16)
            } else {
                emptyHint()
            }
        }
    }

    /// 下半屏（第一张图）：阅读目标 › + 今日阅读 + 连续阅读 18 周 + 今年已读（手账/经典共用）
    private var readingGoalStatsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { openGoalEditor() } label: {
                HStack {
                    Text(localized("阅读目标")).font(.system(size: 15, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                    Spacer()
                    Text(localized("调整目标　···")).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                    Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(PaperPalette.textTertiary(scheme))
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            journalRingCard
            journalStreak18Card
            yearCard
        }
        .padding(.top, 22)
    }

    /// 经典·继续阅读深棕渐变横滑卡（对标参考图第二屏）
    private func classicDarkCard(_ book: ReadingBook) -> some View {
        HStack(spacing: 12) {
            cover(book, width: 62, height: 84)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Color.white).lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.68)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(book.currentPosition > 0 ? String(format: localized("书籍 · %d%%"), Int(book.currentPosition * 100)) : localized("书籍 · 未读"))
                    .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.72))
            }
            Spacer(minLength: 2)
            VStack {
                Spacer()
                Button { openBook(book) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 290, height: 112)
        .background(
            LinearGradient(gradient: Gradient(colors: [Color(red: 0.45, green: 0.42, blue: 0.33),
                                                      Color(red: 0.36, green: 0.34, blue: 0.26),
                                                      Color(red: 0.29, green: 0.27, blue: 0.20)]),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { openBook(book) }
    }

    /// 经典·阅读目标半圆弧大卡（对标参考图第二屏）
    private var classicGoalArcCard: some View {
        let progress = min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1)
        return VStack(spacing: 0) {
            Text(localized("阅读目标")).font(.system(size: 19, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
            Text(localized("日知其所亡，月无忘其所能，可谓好学也已矣。"))
                .font(.system(size: 11.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
                .padding(.top, 6)

            // 半圆弧：从左到右的上半圆，左端一个黑点
            ZStack(alignment: .top) {
                ArcShape()
                    .stroke(PaperPalette.hairline(scheme).opacity(0.55), style: StrokeStyle(lineWidth: 13, lineCap: .round))
                VStack(spacing: 2) {
                    Text(localized("今日阅读进度")).font(.system(size: 14, weight: .semibold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                    Text(clockString(todaySeconds)).font(.system(size: 46, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                        .foregroundStyle(PaperPalette.textPrimary(scheme))
                    Button { openGoalEditor() } label: {
                        Text(String(format: localized("（%@）›"), goalLabel))
                            .font(.system(size: 12)).foregroundStyle(PaperPalette.textTertiary(scheme))
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 34)
                // 弧左端黑点
                Circle().fill(Color(red: 0.09, green: 0.09, blue: 0.09))
                    .frame(width: 15, height: 15)
                    .offset(x: -136, y: 62)
            }
            .frame(height: 150)
            .padding(.top, 4)

            Button { openCenteredOrShelf() } label: {
                VStack(spacing: 3) {
                    Text(localized("继续阅读")).font(.system(size: 15, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                    if let book = centeredBook {
                        Text(book.title).font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .glassButtonChrome(in: Capsule(), scheme: scheme)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            // 周日 → 周六，周五周六实心
            HStack(spacing: 8) {
                let labels = [localized("周日"), localized("周一"), localized("周二"), localized("周三"), localized("周四"), localized("周五"), localized("周六")]
                ForEach(0..<7, id: \.self) { i in
                    let filled = (i == 5 || i == 6)
                    Text(labels[i]).font(.system(size: 11))
                        .foregroundStyle(filled ? Color.white : PaperPalette.textTertiary(scheme))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(filled ? Color(red: 0.72, green: 0.71, blue: 0.69) : Color.clear))
                        .overlay(Circle().strokeBorder(filled ? Color.clear : PaperPalette.hairline(scheme), lineWidth: 1))
                }
            }
            .padding(.top, 16)

            VStack(spacing: 4) {
                Text(String(format: localized("连续阅读 %d 天 ›"), consecutiveDays))
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(String(format: localized("你的记录是 %d 天。"), consecutiveDays))
                    .font(.system(size: 11.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(PaperPalette.card(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func classicContinueCard(_ book: ReadingBook) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                cover(book, width: 68, height: 96)
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(format: localized("书籍 · %d%%"), Int(book.currentPosition * 100)))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(PaperPalette.textTertiary(scheme))
                    Text(book.title).font(.system(size: 17, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme)).lineLimit(2)
                    if !book.author.isEmpty {
                        Text(book.author).font(.system(size: 11.5)).foregroundStyle(PaperPalette.textSecondary(scheme))
                    }
                    if let ch = chapterTitle(of: book) {
                        HStack(spacing: 4) {
                            Image(systemName: "bookmark").font(.system(size: 10))
                            Text(ch).lineLimit(1)
                        }
                        .font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                    progressBar(progress: book.currentPosition)
                }
            }
            .frame(height: 96)
            HStack(spacing: 10) {
                Button { openBook(book) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "book.closed")
                        Text(localized("继续阅读"))
                    }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .glassButtonChrome(in: Capsule(), scheme: scheme)
                }
                .buttonStyle(.plain)
                Button { listen(book) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "headphones")
                        Text(localized("听书"))
                    }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Capsule().fill(PaperPalette.iconTile(scheme)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    private func classicTile(_ book: ReadingBook) -> some View {
        HStack(spacing: 10) {
            cover(book, width: 52, height: 74)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(PaperPalette.textPrimary(scheme)).lineLimit(2)
                Text(book.author).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme)).lineLimit(1)
                Text(book.currentPosition > 0 ? String(format: localized("书籍 · %d%%"), Int(book.currentPosition * 100)) : localized("未读"))
                    .font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            Spacer(minLength: 2)
            Button { listen(book) } label: {
                Image(systemName: "headphones").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PaperPalette.textSecondary(scheme))
                    .frame(width: 34, height: 34).background(Circle().fill(PaperPalette.iconTile(scheme)))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 264)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    // MARK: - ③ 手账（journal）：统计流

    private var journalContent: some View {
        Group {
            if let book = centeredBook {
                VStack(alignment: .leading, spacing: 14) {
                    // 手账 = 第一张图：日期 + 继续阅读大卡 + 最近阅读 + 阅读目标统计流
                    dateHeaderSmall
                    sectionHeader(localized("继续阅读"))
                    classicContinueCard(book)
                    if carouselBooks.count > 1 {
                        sectionHeader(localized("最近阅读"))
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(carouselBooks.filter { $0.id != book.id }) { other in
                                    classicTile(other)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .scrollClipDisabled()
                    }
                    readingGoalStatsSection
                    planCard
                    statsLink
                }
                .padding(.top, 14)
            } else {
                emptyHint()
            }
        }
    }

    // 手账专属：今日阅读圆环卡（对标视频：0% 圆环 + 0:00 + 目标15分钟 + 阅读/听书分钟）
    private var journalRingCard: some View {
        let progress = min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(localized("今日阅读")).font(.system(size: 14, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Spacer()
                Button { openGoalEditor() } label: {
                    Text(localized("调整目标　···"))
                        .font(.system(size: 11))
                        .foregroundStyle(PaperPalette.textTertiary(scheme))
                        // 加大可点区域，别让人戳半天戳不到
                        .padding(.vertical, 4).padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(PaperPalette.hairline(scheme).opacity(0.5), lineWidth: 11)
                    Circle().trim(from: 0, to: max(progress, 0.001))
                        .stroke(PaperPalette.ink(scheme), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%").font(.system(size: 13, weight: .semibold)).foregroundStyle(PaperPalette.textSecondary(scheme))
                }
                .frame(width: 88, height: 88)
                VStack(alignment: .leading, spacing: 5) {
                    Text(clockString(todaySeconds)).font(.system(size: 32, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55).foregroundStyle(PaperPalette.textPrimary(scheme))
                    Text(goalLabel).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                    HStack(spacing: 14) {
                        Label(String(format: localized("阅读 %@"), durationText(todaySeconds / 60)), systemImage: "book.closed")
                        Label(localized("听书 0 分钟"), systemImage: "headphones")
                    }
                    .font(.system(size: 10.5)).foregroundStyle(PaperPalette.textSecondary(scheme))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    // 手账专属：连续阅读 + 近18周格子打卡（对标视频）
    private var journalStreak18Card: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(localized("连续阅读")).font(.system(size: 14, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Spacer()
                Text("···").font(.system(size: 13)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            HStack(spacing: 34) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("当前连续")).font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
                    Text("\(consecutiveDays) 天").font(.system(size: 22, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("最长纪录")).font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
                    Text("\(longestStreak) 天").font(.system(size: 22, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                }
            }
            // 18 周 × 7 天格子
            HStack(spacing: 2.5) {
                ForEach(0..<18, id: \.self) { w in
                    VStack(spacing: 2.5) {
                        ForEach(0..<7, id: \.self) { d in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill((w == 17 && d <= consecutiveDays) ? PaperPalette.ink(scheme) : PaperPalette.hairline(scheme).opacity(0.42))
                                .frame(width: 8, height: 8)
                        }
                    }
                }
            }
            HStack {
                Text(localized("近 18 周")).font(.system(size: 10)).foregroundStyle(PaperPalette.textTertiary(scheme))
                Spacer()
                Text(localized("少　▪▪▪▪▪　多")).font(.system(size: 10)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    private var journalTodayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(localized("今日阅读"))
            HStack(alignment: .firstTextBaseline) {
                Text(clockString(todaySeconds)).font(.system(size: 44, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                Spacer()
                Text(goalLabel)
                    .font(.system(size: 12)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            GeometryReader { g in
                let p = min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(PaperPalette.hairline(scheme).opacity(0.45))
                    Capsule().fill(PaperPalette.ink(scheme)).frame(width: g.size.width * p)
                }
            }
            .frame(height: 7)
            HStack(spacing: 20) {
                Label(String(format: localized("阅读 %@"), durationText(todaySeconds / 60)), systemImage: "book.closed")
                Label(localized("听书 0 分钟"), systemImage: "headphones")
            }
            .font(.system(size: 11.5)).foregroundStyle(PaperPalette.textSecondary(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    // MARK: - ④ 拟物（skeuomorphic）：阅读目标大圆环 + 周打卡

    private var skeuomorphicContent: some View {
        VStack(spacing: 14) {
            if let book = centeredBook {
                skeuContinueStrip(book)
            }
            skeuGoalCard
            streakCard
        }
        .padding(.top, 18)
    }

    private func skeuContinueStrip(_ book: ReadingBook) -> some View {
        HStack(spacing: 12) {
            cover(book, width: 46, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(PaperPalette.textPrimary(scheme)).lineLimit(2)
                if !book.author.isEmpty { Text(book.author).font(.system(size: 11)).foregroundStyle(PaperPalette.textSecondary(scheme)) }
                Text(book.currentPosition > 0 ? String(format: localized("书籍 · %d%%"), Int(book.currentPosition * 100)) : localized("书籍 · 未读"))
                    .font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            Spacer()
            Button { openBook(book) } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PaperPalette.textSecondary(scheme))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
        .padding(.horizontal, 4)
    }

    private var skeuGoalCard: some View {
        VStack(spacing: 16) {
            Text(localized("阅读目标")).font(PaperFont.serif(24)).foregroundStyle(PaperPalette.textPrimary(scheme))
            Text(localized("学不可以已。青，取之于蓝，而青于蓝。"))
                .font(.system(size: 12)).foregroundStyle(PaperPalette.textTertiary(scheme))
            Text(localized("今日阅读进度")).font(.system(size: 12, weight: .medium)).foregroundStyle(PaperPalette.textSecondary(scheme))
            ZStack {
                Circle().stroke(PaperPalette.hairline(scheme).opacity(0.4), lineWidth: 12)
                Circle().trim(from: 0, to: min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1))
                    .stroke(PaperPalette.ink(scheme), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(clockString(todaySeconds)).font(.system(size: 38, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                        .foregroundStyle(PaperPalette.textPrimary(scheme))
                    Button { openGoalEditor() } label: {
                        Text(String(format: localized("（%@）"), goalLabel))
                            .font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                            .padding(.vertical, 3).padding(.horizontal, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 190, height: 190)
            Button { openCenteredOrShelf() } label: {
                VStack(spacing: 3) {
                    Text(localized("继续阅读")).font(.system(size: 14, weight: .semibold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                    if let book = centeredBook {
                        Text(book.title).font(.system(size: 10)).foregroundStyle(PaperPalette.textTertiary(scheme)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .glassButtonChrome(in: Capsule(), scheme: scheme)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                let labels = ["日", "一", "二", "三", "四", "五", "六"]
                ForEach(0..<7, id: \.self) { i in
                    Text(labels[i]).font(.system(size: 11))
                        .foregroundStyle(weekRead(i) ? Color.white : PaperPalette.textTertiary(scheme))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(weekRead(i) ? PaperPalette.ink(scheme) : PaperPalette.iconTile(scheme)))
                }
            }
            VStack(spacing: 3) {
                Text(String(format: localized("连续阅读 %d 天"), consecutiveDays))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(String(format: localized("你的记录是 %d 天。"), consecutiveDays))
                    .font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    // MARK: - ⑤ 杂志（magazine）：阅读特刊

    private var magazineContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(format: localized("ISSUE · %@"), dateText))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(PaperPalette.textTertiary(scheme)).kerning(1)
                    Spacer()
                    Text(weekdayText).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                }
                Text(localized("阅读特刊")).font(PaperFont.serif(38)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Rectangle().frame(height: 1).foregroundStyle(PaperPalette.hairline(scheme)).padding(.top, 4)
                HStack(spacing: 8) {
                    Label(localized("今日待翻开"), systemImage: "book.closed")
                    Text("·")
                    Label(String(format: localized("连续 %d 天"), consecutiveDays), systemImage: "flame")
                }
                .font(.system(size: 11)).foregroundStyle(PaperPalette.textSecondary(scheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 24)

            if !carouselBooks.isEmpty {
                VStack(spacing: 14) {
                    bilingualHeader(localized("本期在读"), "FEATURED")
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(carouselBooks) { book in
                                VStack(alignment: .leading, spacing: 8) {
                                    cover(book, width: 132, height: 184)
                                    Text(book.title).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(PaperPalette.textPrimary(scheme)).lineLimit(2).frame(width: 132, alignment: .leading)
                                    Text(book.author).font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme)).lineLimit(1)
                                }
                                .onTapGesture { openBook(book) }
                            }
                        }
                    }
                    .scrollIndicators(.hidden).scrollClipDisabled()
                    .padding(.horizontal, -20).padding(.horizontal, 20)

                    magazineGoalCard
                    streakCard
                }
                .padding(.top, 20)
            } else {
                emptyHint()
            }
        }
    }

    private var magazineGoalCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text(localized("阅读目标")).font(.system(size: 13, weight: .semibold)).foregroundStyle(PaperPalette.textSecondary(scheme))
                Spacer()
                Button { openGoalEditor() } label: {
                    Text(localized("调整目标　···")).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                        .padding(.vertical, 4).padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(clockString(todaySeconds)).font(.system(size: 30, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(localized("/ 今日")).font(.system(size: 12)).foregroundStyle(PaperPalette.textTertiary(scheme))
                Spacer()
                Text("\(Int(min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1) * 100))%")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(PaperPalette.ink(scheme))
                Text(goalLabel)
                    .font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            GeometryReader { g in
                let p = min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(PaperPalette.hairline(scheme).opacity(0.45))
                    Capsule().fill(PaperPalette.ink(scheme)).frame(width: g.size.width * p)
                }
            }
            .frame(height: 6)
        }
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }

    // MARK: - ⑥ 图书馆（library）：书房阅览室 + 竖立书脊

    private var libraryContent: some View {
        Group {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localized("私人馆藏 · ARCHIVE"))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(PaperPalette.textTertiary(scheme)).kerning(1)
                    Spacer()
                    Text(String(format: localized("藏书 %d 册"), store.books.count))
                        .font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                }
                Text(localized("书房阅览室")).font(PaperFont.serif(38)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(String(format: localized("%@ · 静候翻阅"), dateText))
                    .font(.system(size: 12)).foregroundStyle(PaperPalette.textSecondary(scheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 24)

            if !carouselBooks.isEmpty {
                VStack(spacing: 18) {
                    bilingualHeader(localized("馆藏书架"), "ON SHELF")
                    ScrollView(.horizontal) {
                        HStack(alignment: .bottom, spacing: 10) {
                            ForEach(carouselBooks) { book in
                                spineView(book).onTapGesture { openBook(book) }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .scrollIndicators(.hidden).scrollClipDisabled()
                    .frame(height: 160)
                    .background(alignment: .bottom) {
                        Rectangle().frame(height: 2).foregroundStyle(PaperPalette.hairline(scheme))
                    }
                    .padding(.horizontal, -20).padding(.horizontal, 20)

                    libraryGoalCard
                    streakCard
                }
                .padding(.top, 20)
            } else {
                emptyHint()
            }
        }
    }

    private func spineView(_ book: ReadingBook) -> some View {
        let h: CGFloat = 132
        return ZStack(alignment: .center) {
            BookshelfCoverStyle.artwork(
                for: book,
                colorScheme: scheme,
                displaySize: CGSize(width: 92, height: h)
            )
            .frame(width: 44, height: h)
            .clipped()
            .overlay(
                LinearGradient(colors: [Color.black.opacity(0.28), .clear, Color.black.opacity(0.18)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 44)
            )
            // 竖排书名
            VStack(spacing: 1) {
                ForEach(Array(book.title.prefix(7).enumerated()), id: \.offset) { _, ch in
                    Text(String(ch)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 1)
        }
        .frame(width: 44, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: Color.black.opacity(0.3), radius: 5, x: 2, y: 4)
    }

    private var libraryGoalCard: some View {
        VStack(spacing: 12) {
            HStack {
                sectionHeader(localized("阅览日志"))
                Button { openGoalEditor() } label: {
                    Text(localized("调整目标　···")).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                        .padding(.vertical, 4).padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(clockString(todaySeconds)).font(.system(size: 30, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.55)
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                Text("/ \(durationText(goalMinutes))").font(.system(size: 14)).foregroundStyle(PaperPalette.textSecondary(scheme))
            }
            GeometryReader { g in
                let p = min(CGFloat(todaySeconds) / CGFloat(goalMinutes * 60), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(PaperPalette.hairline(scheme).opacity(0.45))
                    Capsule().fill(PaperPalette.ink(scheme)).frame(width: g.size.width * p)
                }
            }
            .frame(height: 6)
        }
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
    }


    // MARK: - 调整阅读目标

    /// 「调整目标」面板：滚轮按 5 分钟一档（5 分钟 ~ 10 小时），上面一排常用值快点。
    /// 点「完成」才写回 @AppStorage，取消不生效；满 60 分钟自动按「X 小时 Y 分钟」显示。
    private var goalEditorSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text(localized("每天想读多久？"))
                    .font(.system(size: 13))
                    .foregroundStyle(PaperPalette.textSecondary(scheme))
                    .padding(.top, 4)

                goalWheelPicker
                goalQuickPicks
            }
            .background(PaperBackground(scope: .global).ignoresSafeArea())
            .navigationTitle(localized("调整阅读目标"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { showsGoalEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) {
                        goalMinutes = draftGoalMinutes
                        showsGoalEditor = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.height(400)])
        .presentationDragIndicator(.visible)
        .onAppear {
            draftGoalMinutes = goalMinutes
            // 滚轮落在当前值上，而不是每次都从 5 分钟开始
            clampDraftToWheel()
        }
    }

    /// 滚轮：5 分钟一档，5 分钟 ~ 10 小时。单独抽出来，避免整个面板表达式过深、
    /// 编译器类型推断超时（1.91 第一次构建就是卡在这里）。
    private var goalWheelPicker: some View {
        Picker(localized("每日目标"), selection: $draftGoalMinutes) {
            ForEach(Array(stride(from: 5, through: 600, by: 5)), id: \.self) { m in
                let label: String = durationText(m)
                Text(label).tag(m)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxHeight: 160)
    }

    /// 常用值快捷条：点一下把滚轮切过去，不用一直拨。
    private var goalQuickPicks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in
                    goalQuickPick(m)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 6)
    }

    /// 单个快捷值。选中态只是一层淡强调色玻璃，不是实心色块。
    private func goalQuickPick(_ minutes: Int) -> some View {
        let selected = draftGoalMinutes == minutes
        let textColor = selected ? DSColor.accent : PaperPalette.textSecondary(scheme)
        let label: String = durationText(minutes)
        return Button {
            withAnimation(.snappy(duration: 0.2)) { draftGoalMinutes = minutes }
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(textColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassButtonChrome(
                    in: Capsule(),
                    scheme: scheme,
                    tint: selected ? DSColor.accent : nil
                )
        }
        .buttonStyle(.plain)
    }

    /// 把已有目标对齐到 5 分钟档位（用户以前存过 15、30 这类值不会跑偏）。
    private func clampDraftToWheel() {
        let clamped = min(600, max(5, goalMinutes))
        draftGoalMinutes = (clamped + 2) / 5 * 5
    }

    // MARK: - Stats helpers

    private var todaySeconds: Int {
        let start = Calendar.current.startOfDay(for: now)
        let total = stats.totalDuration(in: stats.sessionsInRange(from: start, to: now))
        return max(0, Int(total))
    }

    private func hasRead(on day: Date) -> Bool {
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        let next = cal.date(byAdding: .day, value: 1, to: start)!
        return stats.sessions.contains { $0.startDate >= start && $0.startDate < next }
    }

    private var consecutiveDays: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var cursor = hasRead(on: today) ? today : cal.date(byAdding: .day, value: -1, to: today)!
        var count = 0
        while count < 400, hasRead(on: cursor) {
            count += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }

    private var longestStreak: Int {
        let cal = Calendar.current
        let days = Set(stats.sessions.map { cal.startOfDay(for: $0.startDate) }).sorted()
        var best = 0, run = 0
        var prev: Date?
        for day in days {
            if let p = prev, day == cal.date(byAdding: .day, value: 1, to: p) { run += 1 }
            else { run = 1 }
            best = max(best, run)
            prev = day
        }
        return max(best, consecutiveDays)
    }

    private func weekRead(_ index: Int) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)
        let mondayOffset = (weekday + 5) % 7
        let monday = cal.date(byAdding: .day, value: -mondayOffset, to: today)!
        let day = cal.date(byAdding: .day, value: index, to: monday)!
        return hasRead(on: day)
    }

    private var finishedThisYear: Int {
        let year = Calendar.current.component(.year, from: now)
        return store.books.filter { book in
            guard book.currentPosition >= 0.999 else { return false }
            let d = book.lastOpenedDate ?? book.addedDate
            return Calendar.current.component(.year, from: d) == year
        }.count
    }
}

// MARK: - 展台木质背景（一比一复刻青苔展台）
//
// 顶部深棕木质展台、向下渐隐到页面色，是青苔展台首页最标志性的质感。
// 颜色取自官方高清录屏的实测主色（#736C5F / #AAA59A）。
// 深浅两套：深色模式用更深的棕黑，保证日期大字仍然清晰。
private struct ShowcaseWoodBackdrop: View {
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

                // 极淡的木质横向纹理，增加展台的材质感（不抢戏）
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

// MARK: - 经典模式「阅读目标」半圆弧（对标参考图第二屏的上半圆弧进度条）
private struct ArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // 上半圆：起点左端 → 顶点 → 右端
        let radius = min(rect.width / 2, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.minY + radius)
        p.addArc(center: center,
                 radius: radius,
                 startAngle: .degrees(180),
                 endAngle: .degrees(0),
                 clockwise: true)
        return p
    }
}
