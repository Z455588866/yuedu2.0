import SwiftUI

// MARK: - Results section

/// The 其他来源配置 section of a 换源 sheet — rows, progress, empty and error states — the same
/// on the reader's sheet and on 作品详情's. Each row switches on a tap, and a long press offers
/// Legado's 置顶／置底／编辑来源配置／停用／删除.
struct ChangeSourceResultsSection: View {
    @ObservedObject var search: ChangeSourceSearch
    /// The origin a tap is switching to, for its row's 正在载入目录….
    var pendingOriginID: UUID?
    /// One switch at a time: a second tap would cancel the first.
    var isSwitching = false
    let onSelect: (BookOrigin) -> Void

    @State private var pendingDeletion: BookOrigin?

    var body: some View {
        let shown = search.displayedOrigins
        Section {
            if !shown.isEmpty {
                ForEach(shown) { origin in
                    row(origin)
                }
                if search.isSearching {
                    ChangeSourceProgressRow(progress: search.progress)
                }
            } else if search.isSearching {
                ChangeSourceProgressRow(progress: search.progress)
            } else if !search.origins.isEmpty {
                // 筛选 hid every result: say so, not “暂无其他来源配置”.
                Text(localized("没有符合筛选的来源配置"))
                    .foregroundStyle(DSColor.textSecondary)
            } else {
                Text(localized("暂无其他来源配置"))
                    .foregroundStyle(DSColor.textSecondary)
            }
        } header: {
            Text(localized("其他来源配置"))
                .foregroundStyle(DSColor.textSecondary)
        } footer: {
            if let err = search.error {
                Label(err, systemImage: "exclamationmark.triangle")
                    .dsSectionFooter(color: DSColor.destructive)
            }
        }
        .changeSourceEmptyGroupAlert(search: search)
    }

    private func row(_ origin: BookOrigin) -> some View {
        let key = ChangeSourceSearch.key(origin)
        return ChangeSourceOriginRow(
            origin: origin,
            lastChapter: search.lastChapter(of: origin),
            probe: search.probes[key],
            showsWordCount: search.loadWordCount,
            isProbing: search.probing.contains(key),
            isFailed: search.isFailed(origin),
            isPending: pendingOriginID == origin.id,
            kind: origin.inferredContentKind(),
            score: search.bookScore(of: origin),
            onScore: { search.setBookScore($0, for: origin) },
            action: { onSelect(origin) }
        )
        .disabled(isSwitching)
        .contextMenu {
            ChangeSourceSourceActions(search: search, sourceId: origin.sourceId) {
                pendingDeletion = origin
            }
        }
        .changeSourceDeleteConfirmation(
            sourceName: origin.sourceName,
            isPresented: Binding(
                get: { pendingDeletion?.id == origin.id },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            onDelete: { search.deleteSource(id: origin.sourceId) }
        )
    }
}

// MARK: - The source in use

/// 目前来源: where the book is read from now, checked. A 来源配置 there takes the same long
/// press as the results; deleting it is Legado's `deleteSource` on the book's own origin,
/// which switches to the first result that loads (`onDeletedCurrent`).
struct ChangeSourceCurrentSection: View {
    @ObservedObject var search: ChangeSourceSearch
    let name: String
    let lastChapter: String?
    /// The 来源配置 the book reads from; nil for a book read from anywhere else.
    let source: BookSource?
    let onDeletedCurrent: () -> Void

    @State private var confirmsDeletion = false

    var body: some View {
        Section(localized("目前来源")) {
            HStack {
                VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                    Text(name)
                        .foregroundStyle(DSColor.textPrimary)
                    if let lastChapter, !lastChapter.isEmpty {
                        Text(lastChapter)
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(DSFont.body.weight(.semibold))
                    .foregroundStyle(DSColor.accent)
                    // The tick is the visual form of “使用中”; the `.isSelected` trait below
                    // says it, so leaving it focusable only got the symbol name read out.
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isSelected)
            .contextMenu {
                if let source {
                    ChangeSourceSourceActions(search: search, sourceId: source.id) {
                        confirmsDeletion = true
                    }
                }
            }
            .changeSourceDeleteConfirmation(
                sourceName: source?.bookSourceName ?? name,
                isPresented: $confirmsDeletion,
                onDelete: {
                    guard let source else { return }
                    search.deleteSource(id: source.id)
                    onDeletedCurrent()
                }
            )
        }
    }
}

// MARK: - Row

/// One origin: its 来源配置, the author it gave, its latest chapter, and with 加载字数 the
/// chapter it read; 👍/👎 on the trailing edge, then the switch state.
struct ChangeSourceOriginRow: View {
    let origin: BookOrigin
    let lastChapter: String
    let probe: ChangeSourceProbe?
    let showsWordCount: Bool
    let isProbing: Bool
    let isFailed: Bool
    let isPending: Bool
    let kind: OnlineBookContentKind
    let score: Int
    let onScore: (Int) -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Button(action: action) {
                HStack(spacing: DSSpacing.sm) {
                    details
                    Spacer(minLength: DSSpacing.xs)
                    status
                }
                .frame(minHeight: DSLayout.minimumTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(accessibilityValue)
            .accessibilityAction(named: Text(localized(score > 0 ? "取消赞" : "赞"))) {
                onScore(score > 0 ? 0 : 1)
            }
            .accessibilityAction(named: Text(localized(score < 0 ? "取消踩" : "踩"))) {
                onScore(score < 0 ? 0 : -1)
            }
            scoreButtons
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            HStack(spacing: DSSpacing.sm) {
                Text(origin.sourceName)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(1)
                if let kindLabel = ChangeSourceKindLabel.text(for: kind) {
                    Text(kindLabel)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .padding(.horizontal, DSSpacing.sm)
                        .padding(.vertical, DSSpacing.xxs)
                        .background(DSColor.surfaceTertiary, in: Capsule())
                }
            }
            let author = origin.author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty {
                Text(author)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            // Aggregation sources share one sourceName across channels; the latest chapter
            // tells them apart.
            if !lastChapter.isEmpty {
                Text(lastChapter)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .lineLimit(1)
            }
            if showsWordCount, let line = ChangeSourceWordCountText.line(for: probe) {
                Text(line)
                    .font(DSFont.caption)
                    .foregroundStyle(probe?.wordCount == -1 ? DSColor.destructive : DSColor.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if isPending {
            // The tap is being worked on. Without this the sheet sat completely unchanged
            // while the TOC downloaded, which reads as "nothing happened".
            HStack(spacing: DSSpacing.xs) {
                ProgressView()
                Text(localized("正在载入目录…"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }
        } else if isFailed {
            Text(localized("载入失败"))
                .font(DSFont.caption2)
                .foregroundStyle(DSColor.destructive)
                .padding(.horizontal, DSSpacing.sm)
                .padding(.vertical, DSSpacing.xxs)
                .background(Capsule().fill(DSColor.destructive.opacity(0.12)))
        } else if isProbing {
            ProgressView()
                .accessibilityLabel(localized("正在载入"))
        } else {
            Image(systemName: "chevron.right")
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .accessibilityHidden(true)   // 纯装饰，否则旁白念出 "chevron.right"
        }
    }

    /// Legado's 👍/👎: both while unscored, only the chosen one after; tapping it again clears.
    /// VoiceOver reaches them as the row's actions instead (see `body`).
    private var scoreButtons: some View {
        HStack(spacing: 0) {
            if score >= 0 {
                Button { onScore(score > 0 ? 0 : 1) } label: {
                    Image(systemName: score > 0 ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .foregroundStyle(score > 0 ? DSColor.accent : DSColor.textSecondary)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
            }
            if score <= 0 {
                Button { onScore(score < 0 ? 0 : -1) } label: {
                    Image(systemName: score < 0 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .foregroundStyle(score < 0 ? DSColor.accent : DSColor.textSecondary)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                        .contentShape(Rectangle())
                }
            }
        }
        .font(DSFont.body)
        .buttonStyle(.borderless)
        .accessibilityHidden(true)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let kindLabel = ChangeSourceKindLabel.text(for: kind) { parts.append(kindLabel) }
        if score > 0 { parts.append(localized("已赞")) }
        if score < 0 { parts.append(localized("已踩")) }
        return parts.joined(separator: ", ")
    }
}

enum ChangeSourceKindLabel {
    /// The kind, when it is not plain text: a different kind asks before switching.
    static func text(for kind: OnlineBookContentKind) -> String? {
        switch kind {
        case .text: nil
        case .audio: localized("有声书")
        case .manga: localized("漫画")
        case .video: localized("影片")
        }
    }
}

enum ChangeSourceWordCountText {
    /// Legado's “[章节序] 标题 字数：N” and 响应时间 line.
    static func line(for probe: ChangeSourceProbe?) -> String? {
        guard let probe, let count = probe.wordCount else { return nil }
        // “[序] 标题” has no words to translate.
        let chapter = probe.chapterIndex.map { index in
            "[\(index + 1)] \(probe.chapterTitle ?? "")"
        }
        var parts: [String] = chapter.map { [$0] } ?? []
        if count >= 0 {
            parts.append(String(format: localized("%d 字"), count))
        } else {
            parts.append(localized("取不到字数"))
        }
        if let ms = probe.respondMs {
            parts.append(String(format: localized("%d 毫秒"), ms))
        }
        return parts.joined(separator: " · ")
    }
}

/// While the fan-out runs: how many of the searched 来源配置 are done (Legado's 换源 progress).
struct ChangeSourceProgressRow: View {
    let progress: ChangeSourceSearch.Progress

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            ProgressView()
            Text(String(format: localized("已搜寻 %1$d／%2$d 个来源配置"), progress.finished, progress.total))
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Long-press actions

/// Legado's change_source_item.xml menu, for one 来源配置. 删除 asks first (`onDelete` shows the
/// confirmation, on the row the long press was on).
struct ChangeSourceSourceActions: View {
    let search: ChangeSourceSearch
    let sourceId: UUID
    let onDelete: () -> Void

    var body: some View {
        Button { search.pinToTop(sourceId: sourceId) } label: {
            Label(localized("置顶"), systemImage: "arrow.up.to.line")
        }
        Button { search.pinToBottom(sourceId: sourceId) } label: {
            Label(localized("置底"), systemImage: "arrow.down.to.line")
        }
        if let source = BookSourceStore.shared.source(id: sourceId) {
            // A sheet from a context menu, as 探索's 编辑 (`bookSourceActionSheets`); here it is
            // nested under the 换源 sheet, as its 设置源变量 editor already is.
            Button { search.editingSource = source } label: {
                Label(localized("编辑来源配置"), systemImage: "square.and.pencil")
            }
        }
        Button { search.disableSource(id: sourceId) } label: {
            Label(localized("停用来源配置"), systemImage: "nosign")
        }
        Divider()
        Button(role: .destructive, action: onDelete) {
            Label(localized("删除来源配置"), systemImage: "trash")
        }
    }
}

extension View {
    /// 删除's confirmation, on the row the long press was on (as `bookSourceDeleteConfirmation`),
    /// so on iOS 26+ its popover points at that row.
    func changeSourceDeleteConfirmation(
        sourceName: String,
        isPresented: Binding<Bool>,
        onDelete: @escaping () -> Void
    ) -> some View {
        confirmationDialog(localized("删除来源配置"), isPresented: isPresented, titleVisibility: .visible) {
            Button(localized("删除"), role: .destructive, action: onDelete)
            Button(localized("取消"), role: .cancel) {}
        } message: {
            Text(sourceName)
        }
    }

    /// Legado's 搜索结果为空 prompt after a search scoped to one group found nothing.
    func changeSourceEmptyGroupAlert(search: ChangeSourceSearch) -> some View {
        alert(
            localized("搜寻结果为空"),
            isPresented: Binding(
                get: { search.emptyGroupPrompt != nil },
                set: { if !$0 { search.emptyGroupPrompt = nil } }
            ),
            presenting: search.emptyGroupPrompt
        ) { _ in
            Button(localized("取消"), role: .cancel) {}
            Button(localized("搜寻全部")) { search.searchAllGroups() }
        } message: { group in
            Text(String(format: localized("“%@”分组没有找到这本书，要改搜全部来源配置吗？"), group))
        }
    }

    /// 筛选 (Legado's 换源 SearchView): the list narrows to sources or latest chapters with the text.
    func changeSourceFilter(_ search: ChangeSourceSearch) -> some View {
        modifier(ChangeSourceFilterModifier(search: search))
    }

    /// The editor 编辑来源配置 opens; saving searches that source again.
    func changeSourceEditor(_ search: ChangeSourceSearch) -> some View {
        modifier(ChangeSourceEditorModifier(search: search))
    }

    /// Legado's `book_type_different`: an origin of another kind than the book asks first.
    func changeSourceKindConfirmation(
        _ search: ChangeSourceSearch, onConfirm: @escaping (BookOrigin) -> Void
    ) -> some View {
        modifier(ChangeSourceKindConfirmationModifier(search: search, onConfirm: onConfirm))
    }
}

private struct ChangeSourceEditorModifier: ViewModifier {
    @ObservedObject var search: ChangeSourceSearch

    func body(content: Content) -> some View {
        content.sheet(item: $search.editingSource) { source in
            AdaptiveSheetContainer(maxWidth: DSLayout.readableExpandedWidth) {
                BookSourceEditView(source: source) { updated in
                    search.saveEditedSource(updated)
                }
            }
        }
    }
}

private struct ChangeSourceKindConfirmationModifier: ViewModifier {
    @ObservedObject var search: ChangeSourceSearch
    let onConfirm: (BookOrigin) -> Void

    func body(content: Content) -> some View {
        content.sourceKindMismatchAlert(origin: $search.kindMismatchOrigin, onConfirm: onConfirm)
    }
}

extension ChangeSourceSearch {
    /// A tap on an origin: switches through `perform`, or — when the origin is of another kind
    /// than the book — asks first (`changeSourceKindConfirmation`).
    func select(_ origin: BookOrigin, perform: (BookOrigin) -> Void) {
        if let target, origin.inferredContentKind() != target.kind {
            kindMismatchOrigin = origin
        } else {
            perform(origin)
        }
    }
}

private struct ChangeSourceFilterModifier: ViewModifier {
    @ObservedObject var search: ChangeSourceSearch

    func body(content: Content) -> some View {
        content.searchable(
            text: $search.filterText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(localized("筛选来源配置或最新章节"))
        )
    }
}

// MARK: - Toolbar

/// Legado's start/stop: 停止 while searching, 刷新 otherwise. One `Button` whose label changes,
/// never an if/else pair — a toolbar item that changes identity flickers or drops out.
struct ChangeSourceSearchButton: View {
    @ObservedObject var search: ChangeSourceSearch
    /// Also run on 刷新 (the reader searches its libraries and modules again).
    var onRefresh: () -> Void = {}

    var body: some View {
        Button {
            if !search.isSearching { onRefresh() }
            search.toggleSearch()
        } label: {
            Label(localized(search.isSearching ? "停止" : "重新搜寻"),
                  systemImage: search.isSearching ? "stop.circle" : "arrow.clockwise")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(localized(search.isSearching ? "停止" : "重新搜寻"))
    }
}

/// The 换源 options (Legado change_source.xml): 分组, 校验作者, 加载详情, 换源时载入目录,
/// 加载字数, then the host's own items. Nothing here presents a modal, so it stays a native
/// `Menu` on iOS 17 too (Technotes/iOS17MenuModalPresentation.md).
struct ChangeSourceOptionsMenu<Extra: View>: View {
    @ObservedObject var search: ChangeSourceSearch
    @ViewBuilder var extra: () -> Extra

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { search.group }, set: { search.setGroup($0) })) {
                Text(localized("全部来源配置")).tag("")
                ForEach(groupChoices, id: \.self) { group in
                    Text(group).tag(group)
                }
            } label: {
                Label(groupTitle, systemImage: "folder")
            }
            .pickerStyle(.menu)
            Toggle(isOn: Binding(get: { search.checkAuthor }, set: { search.setCheckAuthor($0) })) {
                Label(localized("校验作者"), systemImage: "person.text.rectangle")
            }
            Toggle(isOn: Binding(get: { search.loadInfo }, set: { search.setLoadInfo($0) })) {
                Label(localized("载入详情"), systemImage: "info.circle")
            }
            Toggle(isOn: Binding(get: { search.loadToc }, set: { search.setLoadToc($0) })) {
                Label(localized("换源时载入目录"), systemImage: "list.bullet")
            }
            Toggle(isOn: Binding(get: { search.loadWordCount }, set: { search.setLoadWordCount($0) })) {
                Label(localized("载入字数"), systemImage: "textformat.123")
            }
            extra()
        } label: {
            Label(localized("更多"), systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .accessibilityLabel(localized("更多"))
    }

    /// The saved group stays offered even when no enabled source is in it any more.
    private var groupChoices: [String] {
        let groups = search.availableGroups
        let saved = search.group
        return saved.isEmpty || groups.contains(saved) ? groups : groups + [saved]
    }

    private var groupTitle: String {
        search.group.isEmpty
            ? localized("分组")
            : String(format: localized("分组（%@）"), search.group)
    }
}

extension ChangeSourceOptionsMenu where Extra == EmptyView {
    init(search: ChangeSourceSearch) {
        self.init(search: search, extra: { EmptyView() })
    }
}

// MARK: - Previews

// The seeded lists (`ChangeSourceSearch.preview`) exist in Debug builds only.
#if DEBUG
#Preview("换源结果") {
    let origins = [
        ChangeSourceSearch.previewOrigin("笔趣阁"),
        ChangeSourceSearch.previewOrigin("起点中文网", last: "第 1450 章 大结局"),
        ChangeSourceSearch.previewOrigin("聚合有声", kind: "有声"),
    ]
    let probes = [
        ChangeSourceSearch.key(origins[0]): ChangeSourceProbe(
            chapterIndex: 41, chapterTitle: "第 42 章 星斗大森林", wordCount: 3215, respondMs: 820),
        ChangeSourceSearch.key(origins[1]): ChangeSourceProbe(
            chapterIndex: 41, chapterTitle: "第 42 章", wordCount: -1, respondMs: 60_000, failure: "逾时"),
    ]
    let search = ChangeSourceSearch.preview(
        origins: origins, probes: probes, searching: true,
        progress: .init(finished: 120, total: 459))
    return NavigationStack {
        List {
            ChangeSourceResultsSection(search: search, onSelect: { _ in })
        }
        .changeSourceFilter(search)
        .navigationTitle(localized("换源"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                ChangeSourceSearchButton(search: search)
                ChangeSourceOptionsMenu(search: search)
            }
        }
    }
}

#Preview("换源列，加载字数与评分") {
    let origin = ChangeSourceSearch.previewOrigin("笔趣阁")
    return List {
        ChangeSourceOriginRow(
            origin: origin, lastChapter: origin.lastChapter,
            probe: ChangeSourceProbe(chapterIndex: 41, chapterTitle: "第 42 章 星斗大森林", wordCount: 3215, respondMs: 820),
            showsWordCount: true, isProbing: false, isFailed: false, isPending: false,
            kind: .text, score: 1, onScore: { _ in }, action: {})
        ChangeSourceOriginRow(
            origin: origin, lastChapter: origin.lastChapter,
            probe: ChangeSourceProbe(chapterIndex: 41, chapterTitle: "第 42 章", wordCount: -1, respondMs: 60_000),
            showsWordCount: true, isProbing: false, isFailed: true, isPending: false,
            kind: .audio, score: -1, onScore: { _ in }, action: {})
    }
}

#Preview("换源结果，空的分组") {
    let search = ChangeSourceSearch.preview(origins: [])
    return NavigationStack {
        List {
            ChangeSourceResultsSection(search: search, onSelect: { _ in })
        }
        .navigationTitle(localized("换源"))
        .toolbarTitleDisplayMode(.inline)
    }
}
#endif
