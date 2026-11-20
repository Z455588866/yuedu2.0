import SwiftUI

// MARK: - 首页
//
// maintainer, 2026-11-20: redrawn to the 青苔阅读 home (user's reference video + screenshots).
// The page now opens on a centred 主页 menu, a 右上 ... menu, a large weekday/date masthead with
// two status pills, then one large book in a carousel with the next one peeking at the side,
// left-aligned author / title / chapter with a progress bar and a black headphones button,
// followed by a 阅读目标 ring and the 连续阅读 / 今年已读 / 阅读计划 / 阅读统计 cards.
//
// All the working machinery — 开书, 听书, 长按删除, 全屏阅读, theme backdrop, stats — is kept;
// only the visual layout is new. Reading data comes from the existing ReadingStatsStore.

struct ReadingHomeView: View {
    /// 书架 is another root tab, not a page this one can push: the shell hands the switch
    /// down rather than the page reaching for a tab it does not own.
    var onOpenBookshelf: () -> Void

    init(onOpenBookshelf: @escaping () -> Void = {}) {
        self.onOpenBookshelf = onOpenBookshelf
    }

    @EnvironmentObject private var store: BookStore
    @Environment(\.colorScheme) private var scheme

    @Bindable private var gs = GlobalSettings.shared
    @ObservedObject private var stats = ReadingStatsStore.shared
    @ObservedObject private var subscription = SubscriptionStore.shared

    @State private var readingBookID: UUID?
    @State private var showsStats = false
    @State private var now = Date()

    /// 长按封面要删的那本书，以及确认框的开关 —— 删的是整本（从书架消失），不是只从继续阅读去掉。
    @State private var pendingDeleteBook: ReadingBook?
    @State private var showsDeleteConfirm = false

    /// Where `scrollPosition` puts the strip: written by `settleCarousel` to open on the book
    /// last read, never read back for the caption.
    @State private var centeredBookID: UUID?
    /// 中间那本封面在 window 里的位置：开书卡片从这里展开，和书架一样。
    @State private var centeredCoverFrame: CGRect?

    @State private var restingBookID: UUID?

    private static let carouselSpace = "homeCarousel"
    private static let carouselLimit = 12
    /// 青苔 首页「阅读目标」里写死的目标分钟数（截图为 15 分钟）。
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

    /// 首页所在的 tab 是 .library，没有同名的页面背景 scope，会回落到 .global。
    /// 因此这里和书架用同一套机制：PaperBackground 自己会在设了主题背景图时
    /// （yieldsToArtwork）让位，露出 tab 层 ThemedSurfaceBackground 铺的那张图；
    /// 没有图时它就画主题配色（颜色全部取自 DSColor，跟着主题/深浅模式走）。
    /// 关键是不再自造一层 .opacity 去隐藏背景——那会把首页做成脱离主题的单独一张。
    private var showsArtwork: Bool {
        guard subscription.hasAccess(.readerThemePacks) else { return false }
        return gs.resolvedPageBackgroundSlice(for: .global, colorScheme: scheme) != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                topBar
                dateMasthead
                carousel
                bookInfo
                goalCard
                streakCard
                yearCard
                planCard
                statsLink
            }
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background {
            // 和书架（ShelfPaperView）完全同一套：PaperBackground 内部根据 .global scope
            // 自动让位给主题背景图。底部再垫一层柔边，让主题图上的文字读得清；没设图时
            // 它整层隐形，纸感底照常显示。这样换主题、换背景图、切深浅模式，首页都跟着走。
            ZStack(alignment: .bottom) {
                PaperBackground(scope: .global)

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
            Button(localized("取消"), role: .cancel) {
                pendingDeleteBook = nil
            }
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

    /// 青苔书卡右侧的黑色耳机按钮：有声书直接交给播放器；其它书按普通开书处理。
    private func listen(_ book: ReadingBook) {
        if NowPlayingHub.shared.openIfAudiobook(book, store: store) { return }
        openBook(book)
    }

    private func recenterCarousel() {
        guard let id = restingBookID ?? carouselBooks.first?.id else { return }
        centeredBookID = id
    }

    // MARK: - Top bar (主页 menu + ... menu)

    private var topBar: some View {
        HStack(alignment: .center) {
            Menu {
                Button { showsStats = true } label: {
                    Label(localized("阅读统计"), systemImage: "chart.bar")
                }
                Button { onOpenBookshelf() } label: {
                    Label(localized("书架"), systemImage: "books.vertical")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(localized("主页"))
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

    // MARK: - Date masthead

    private var dateMasthead: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(weekdayText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PaperPalette.textTertiary(scheme))
            Text(dateText)
                .font(.system(size: 40, weight: .bold, design: .default))
                .foregroundStyle(PaperPalette.textPrimary(scheme))
                .padding(.top, 4)
            HStack(spacing: 8) {
                statusPill(
                    systemImage: "book.closed",
                    text: todaySeconds == 0
                        ? localized("今天还没开始读")
                        : String(format: localized("今日阅读 %d 分钟"), todaySeconds / 60)
                )
                statusPill(
                    systemImage: "flame",
                    text: String(format: localized("连续 %d 天"), consecutiveDays)
                )
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 26)
    }

    private func statusPill(systemImage: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(PaperPalette.textSecondary(scheme))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .clearGlassSurface(in: Capsule(), fill: PaperPalette.card(scheme))
        .overlay(Capsule().strokeBorder(PaperPalette.hairline(scheme).opacity(0.5), lineWidth: 0.6))
    }

    private var weekdayText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return f.string(from: now)
    }

    private var dateText: String {
        let cal = Calendar.current
        let m = cal.component(.month, from: now)
        let d = cal.component(.day, from: now)
        return "\(m)月\(d)日"
    }

    // MARK: - Cover carousel

    private var carousel: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let slot = min(212, width * 0.54)
            let coverWidth = slot
            let coverHeight = coverWidth * 1.42

            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(carouselBooks) { book in
                        cover(book, width: coverWidth, height: coverHeight)
                            .frame(width: slot, height: proxy.size.height)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear
                                        .onChange(
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
                            .onLongPressGesture {
                                pendingDeleteBook = book
                                showsDeleteConfirm = true
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(book.title)
                            .accessibilityValue(book.author)
                    }
                }
                .scrollTargetLayout()
            }
            // 让下一本从右边露出一截：起始留白偏左。
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

    // MARK: - Book info (left aligned + progress + headphones)

    private var bookInfo: some View {
        Group {
            if let book = centeredBook {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !book.author.isEmpty {
                            Text(book.author)
                                .font(.system(size: 11.5))
                                .foregroundStyle(PaperPalette.textTertiary(scheme))
                        }
                        Text(book.title)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(PaperPalette.textPrimary(scheme))
                            .lineLimit(2)
                        if let chapter = chapterTitle(of: book) {
                            Text(chapter)
                                .font(.system(size: 11.5))
                                .foregroundStyle(PaperPalette.textSecondary(scheme))
                                .lineLimit(1)
                        }
                        progressBar(progress: book.currentPosition)
                            .padding(.top, 4)
                    }
                    Spacer(minLength: 4)
                    Button { listen(book) } label: {
                        Image(systemName: "headphones")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(DSColor.textOnAccent)
                            .frame(width: 46, height: 46)
                            .background(Circle().fill(PaperPalette.ink(scheme)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(localized("听书"))
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
            } else {
                VStack(spacing: 8) {
                    Text(localized("书架还是空的")).font(PaperFont.serif(19))
                    Text(localized("去书架挑一本，这里就会亮起来。"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(PaperPalette.textSecondary(scheme))
                }
                .foregroundStyle(PaperPalette.textPrimary(scheme))
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
            }
        }
    }

    private func progressBar(progress: Double) -> some View {
        let p = min(max(progress, 0), 1)
        return HStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(PaperPalette.hairline(scheme).opacity(0.5))
                    Capsule().fill(PaperPalette.ink(scheme))
                        .frame(width: g.size.width * CGFloat(p))
                }
            }
            .frame(height: 5)
            Text("\(Int(p * 100))%")
                .font(.system(size: 11))
                .foregroundStyle(PaperPalette.textTertiary(scheme))
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)
        }
    }

    // MARK: - 阅读目标 ring card

    private var goalCard: some View {
        VStack(spacing: 14) {
            sectionHeader(localized("阅读目标"), showsChevron: true)
            goalRing
            Button { openCenteredOrShelf() } label: {
                Text(localized("继续阅读 · 读本书"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DSColor.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Capsule().fill(PaperPalette.ink(scheme)))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
        .padding(.horizontal, 20)
        .padding(.top, 30)
    }

    private func openCenteredOrShelf() {
        if let book = centeredBook { openBook(book) } else { onOpenBookshelf() }
    }

    private var goalRing: some View {
        let progress = min(CGFloat(todaySeconds) / CGFloat(Self.goalMinutes * 60), 1)
        return ZStack {
            Circle()
                .stroke(PaperPalette.hairline(scheme).opacity(0.45), lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(PaperPalette.ink(scheme), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 3) {
                Text(localized("今日阅读"))
                    .font(.system(size: 11))
                    .foregroundStyle(PaperPalette.textTertiary(scheme))
                Text(clockString(todaySeconds))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                    .monospacedDigit()
                Text(String(format: localized("目标 %d 分钟"), Self.goalMinutes))
                    .font(.system(size: 10.5))
                    .foregroundStyle(PaperPalette.textTertiary(scheme))
            }
        }
        .frame(width: 168, height: 168)
    }

    private func clockString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - 连续阅读 card

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(localized("连续阅读"), showsChevron: false)
            HStack(alignment: .firstTextBaseline) {
                Text("\(consecutiveDays)")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                Text(localized("天"))
                    .font(.system(size: 14))
                    .foregroundStyle(PaperPalette.textSecondary(scheme))
                Spacer()
                Text(String(format: localized("最长记录 %d 天"), longestStreak))
                    .font(.system(size: 11))
                    .foregroundStyle(PaperPalette.textTertiary(scheme))
            }
            weekBars
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var weekBars: some View {
        let labels = ["一", "二", "三", "四", "五", "六", "日"]
        return HStack(spacing: 10) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(weekRead(i) ? PaperPalette.ink(scheme) : PaperPalette.hairline(scheme).opacity(0.4))
                        .frame(height: weekRead(i) ? 38 : 24)
                    Text(labels[i])
                        .font(.system(size: 10))
                        .foregroundStyle(PaperPalette.textTertiary(scheme))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 今年已读 card

    private var yearCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(localized("今年已读"), showsChevron: false)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(finishedThisYear)")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundStyle(PaperPalette.textPrimary(scheme))
                Text("/ \(store.books.count) \(localized("本"))")
                    .font(.system(size: 15))
                    .foregroundStyle(PaperPalette.textSecondary(scheme))
            }
            GeometryReader { g in
                let p = store.books.isEmpty ? 0 : CGFloat(finishedThisYear) / CGFloat(store.books.count)
                ZStack(alignment: .leading) {
                    Capsule().fill(PaperPalette.hairline(scheme).opacity(0.45))
                    Capsule().fill(PaperPalette.ink(scheme)).frame(width: g.size.width * p)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    // MARK: - 阅读计划 card

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(localized("阅读计划"), showsChevron: false)
            Text(localized("给一本书定个节奏，按日或按周，慢慢读完。"))
                .font(.system(size: 12))
                .foregroundStyle(PaperPalette.textSecondary(scheme))
            Button { showsStats = true } label: {
                Text(localized("新建阅读计划"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PaperPalette.textSecondary(scheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(PaperPalette.iconTile(scheme)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var statsLink: some View {
        Button { showsStats = true } label: {
            HStack {
                sectionHeader(localized("阅读统计"), showsChevron: true)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(18)
        .interfaceCardSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous), fill: PaperPalette.card(scheme))
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private func sectionHeader(_ title: String, showsChevron: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PaperPalette.textPrimary(scheme))
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PaperPalette.textTertiary(scheme))
            }
        }
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
        var best = 0
        var run = 0
        var prev: Date?
        for day in days {
            if let p = prev, day == cal.date(byAdding: .day, value: 1, to: p) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            prev = day
        }
        return max(best, consecutiveDays)
    }

    /// 0 = 周一 … 6 = 周日，本周哪几天读过。
    private func weekRead(_ index: Int) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today) // 周日=1
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

    // MARK: - Pieces

    private func cover(_ book: ReadingBook, width: CGFloat, height: CGFloat) -> some View {
        BookshelfCoverStyle.artwork(
            for: book,
            colorScheme: scheme,
            displaySize: CGSize(width: width, height: height)
        )
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .leading) {
                LinearGradient(
                    colors: [Color.black.opacity(0.22), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: width * 0.11)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.28), radius: 18, x: 5, y: 12)
            .accessibilityHidden(true)
    }

    private func chapterTitle(of book: ReadingBook) -> String? {
        guard let chapters = book.onlineChapters, !chapters.isEmpty else { return nil }
        let position = min(max(book.currentPosition, 0), 1)
        let index = min(chapters.count - 1, max(0, Int(position * Double(chapters.count))))
        return chapters[index].title
    }
}
