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
    @State private var showsStats = false
    @State private var now = Date()

    @State private var pendingDeleteBook: ReadingBook?
    @State private var showsDeleteConfirm = false

    @State private var centeredBookID: UUID?
    @State private var centeredCoverFrame: CGRect?
    @State private var restingBookID: UUID?

    private static let carouselSpace = "homeCarousel"
    private static let carouselLimit = 12
    private static let goalMinutes = 15

    private var carouselBooks: [ReadingBook] {
        let sorted = store.books.sorted {
            ($0.lastOpenedDate ?? $0.addedDate) > ($1.lastOpenedDate ?? $1.addedDate)
        }
        return Array(sorted.prefix(Self.carouselLimit))
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
        .fullScreenCover(isPresented: Binding(
            get: { readingBookID != nil },
            set: { isPresented in
                guard !isPresented else { return }
                readingBookID = nil
                recenterCarousel()
            }
        )) {
            if let id = readingBookID {
                BookReaderView(bookId: id)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showsStats) {
            NavigationStack { ReadingStatsView() }
        }
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
        if NowPlayingHub.shared.openIfAudiobook(book, store: store) { return }
        openBook(book)
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
                .clearGlassSurface(in: Capsule(), fill: PaperPalette.card(scheme))
                .overlay(Capsule().strokeBorder(PaperPalette.hairline(scheme).opacity(0.5), lineWidth: 0.6))
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
                    .clearGlassSurface(in: Circle(), fill: PaperPalette.card(scheme))
                    .overlay(Circle().strokeBorder(PaperPalette.hairline(scheme).opacity(0.5), lineWidth: 0.6))
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
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
            sectionHeader(localized("阅读目标"), showsChevron: true)
            HStack(spacing: 18) {
                smallRing(progress: min(CGFloat(todaySeconds) / CGFloat(Self.goalMinutes * 60), 1), size: 74, line: 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text(clockString(todaySeconds))
                        .font(.system(size: 28, weight: .bold)).monospacedDigit()
                        .foregroundStyle(PaperPalette.textPrimary(scheme))
                    Text(String(format: localized("目标 %d 分钟"), Self.goalMinutes))
                        .font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                    HStack(spacing: 14) {
                        Label(String(format: localized("阅读 %d 分钟"), todaySeconds / 60), systemImage: "book.closed")
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
            sectionHeader(localized("阅读目标"), showsChevron: true)
            goalRing
            Button { openCenteredOrShelf() } label: {
                Text(localized("继续阅读 · 读本书"))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(DSColor.textOnAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Capsule().fill(PaperPalette.ink(scheme)))
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
        let progress = min(CGFloat(todaySeconds) / CGFloat(Self.goalMinutes * 60), 1)
        return ZStack {
            Circle().stroke(PaperPalette.hairline(scheme).opacity(0.45), lineWidth: 12)
            Circle().trim(from: 0, to: progress)
                .stroke(PaperPalette.ink(scheme), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text(localized("今日阅读")).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                Text(clockString(todaySeconds)).font(.system(size: 30, weight: .bold)).monospacedDigit()
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(String(format: localized("目标 %d 分钟"), Self.goalMinutes))
                    .font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
        }
        .frame(width: 168, height: 168)
    }

    private func clockString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - ② 经典（classic）：继续阅读大卡片 + 横排书 + 阅读目标

    private var classicContent: some View {
        Group {
            dateHeaderSmall
            if let book = centeredBook {
                VStack(alignment: .leading, spacing: 14) {
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
                        .padding(.horizontal, -20)
                        .padding(.horizontal, 20)
                    }
                    todayRingCard
                    streakCard
                }
                .padding(.top, 18)
            } else {
                emptyHint()
            }
        }
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
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(DSColor.textOnAccent)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Capsule().fill(PaperPalette.ink(scheme)))
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
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), fill: PaperPalette.card(scheme))
    }

    // MARK: - ③ 手账（journal）：统计流

    private var journalContent: some View {
        VStack(spacing: 14) {
            dateMasthead
            journalTodayCard
            streakCard
            yearCard
            planCard
            statsLink
        }
        .padding(.top, 14)
    }

    private var journalTodayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(localized("今日阅读"))
            HStack(alignment: .firstTextBaseline) {
                Text("\(todaySeconds / 60)").font(.system(size: 52, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(localized("分钟")).font(.system(size: 16)).foregroundStyle(PaperPalette.textSecondary(scheme))
                Spacer()
                Text(String(format: localized("目标 %d 分钟"), Self.goalMinutes))
                    .font(.system(size: 12)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            GeometryReader { g in
                let p = min(CGFloat(todaySeconds) / CGFloat(Self.goalMinutes * 60), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(PaperPalette.hairline(scheme).opacity(0.45))
                    Capsule().fill(PaperPalette.ink(scheme)).frame(width: g.size.width * p)
                }
            }
            .frame(height: 7)
            HStack(spacing: 20) {
                Label(String(format: localized("阅读 %d 分钟"), todaySeconds / 60), systemImage: "book.closed")
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
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous), fill: PaperPalette.card(scheme))
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
                Circle().trim(from: 0, to: min(CGFloat(todaySeconds) / CGFloat(Self.goalMinutes * 60), 1))
                    .stroke(PaperPalette.ink(scheme), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(clockString(todaySeconds)).font(.system(size: 38, weight: .bold)).monospacedDigit()
                        .foregroundStyle(PaperPalette.textPrimary(scheme))
                    Text(String(format: localized("（目标 %d 分钟）"), Self.goalMinutes))
                        .font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
                }
            }
            .frame(width: 190, height: 190)
            Button { openCenteredOrShelf() } label: {
                VStack(spacing: 3) {
                    Text(localized("继续阅读")).font(.system(size: 14, weight: .semibold)).foregroundStyle(DSColor.textOnAccent)
                    if let book = centeredBook {
                        Text(book.title).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.75)).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(Capsule().fill(PaperPalette.ink(scheme)))
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
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous), fill: PaperPalette.card(scheme))
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
                            ForEach(carouselBooks.prefix(8)) { book in
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
                Text(localized("设定")).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("\(todaySeconds / 60)").font(.system(size: 34, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(localized("分钟 / 今日")).font(.system(size: 12)).foregroundStyle(PaperPalette.textTertiary(scheme))
                Spacer()
                Text("\(Int(min(CGFloat(todaySeconds) / CGFloat(Self.goalMinutes * 60), 1) * 100))%")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(PaperPalette.ink(scheme))
                Text(String(format: localized("目标 %d 分钟"), Self.goalMinutes))
                    .font(.system(size: 10.5)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            GeometryReader { g in
                let p = min(CGFloat(todaySeconds) / CGFloat(Self.goalMinutes * 60), 1)
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
                            ForEach(carouselBooks.prefix(12)) { book in
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
                Text(localized("设定")).font(.system(size: 11)).foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(todaySeconds / 60)").font(.system(size: 34, weight: .bold)).foregroundStyle(PaperPalette.textPrimary(scheme))
                Text("/ \(Self.goalMinutes) \(localized("分钟"))").font(.system(size: 14)).foregroundStyle(PaperPalette.textSecondary(scheme))
            }
            GeometryReader { g in
                let p = min(CGFloat(todaySeconds) / CGFloat(Self.goalMinutes * 60), 1)
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
