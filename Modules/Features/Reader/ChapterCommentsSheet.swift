import SwiftUI

/// A module's comments, opened from the text: a chapter's (its 本章说 card) or one paragraph's
/// (its 段评 bubble, its 热评 card), as 作品详情's 读者评论 lists a work's reviews. A module has
/// no page of its own to show, as a 来源配置 does. The comments are the site's own words; the
/// last row says whose.
struct ChapterCommentsSheet: View {
    @StateObject private var model: ChapterCommentsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    init(target: ModuleCommentTarget) {
        _model = StateObject(wrappedValue: ChapterCommentsModel(target: target))
    }

    /// A preview's, or a test's, own model.
    init(model: ChapterCommentsModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        NavigationStack {
            content
                .background(PageBackgroundView(scope: .global, base: DSColor.background).ignoresSafeArea())
                .navigationTitle(localized(model.paragraphID == nil ? "本章说" : "段评"))
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark").accessibilityHidden(true) }
                            .accessibilityLabel(localized("关闭"))
                            .accessibilityIdentifier("chapterComments.close")
                    }
                    if model.sorts.count > 1 {
                        ToolbarItem(placement: .topBarTrailing) { sortMenu }
                    }
                }
        }
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .accessibilityLabel(localized("读取中"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView {
                UnavailableLabel(localized("找不到这一章的评论"), systemImage: "text.bubble")
            }
            .accessibilityIdentifier("chapterComments.unavailable")
        case .failed(let message):
            ContentUnavailableView {
                UnavailableLabel(localized("评论读取失败"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(localized("重试")) { Task { await model.load() } }
            }
        case .loaded:
            if model.comments.isEmpty {
                ContentUnavailableView {
                    UnavailableLabel(localized("还没有评论"), systemImage: "text.bubble")
                }
                .accessibilityIdentifier("chapterComments.empty")
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            Section {
                Text(model.heading)
                    .font(DSFont.title3.weight(.bold))
                    .foregroundStyle(DSColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .reviewRow()
                // By position: two readers can write the same words.
                ForEach(model.comments.indices, id: \.self) { index in
                    WorkReviewCard(review: model.comments[index])
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(model.comments[index].spokenText(locale: locale))
                        .accessibilityIdentifier("chapterComments.card")
                        .reviewRow()
                        .task {
                            // The last row on screen: the next page.
                            if index == model.comments.count - 1 { await model.loadMore() }
                        }
                }
                if model.isLoadingMore {
                    ProgressView()
                        .accessibilityLabel(localized("读取中"))
                        .frame(maxWidth: .infinity)
                        .reviewRow()
                }
                if let thread = model.thread {
                    // A row in the footer's style, as 读者评论 has it (design.md §4.1).
                    Text(String(format: localized("评论来自 %@"), thread.module.title))
                        .dsSectionFooter()
                        .accessibilityIdentifier("chapterComments.source")
                        .reviewRow()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// The site's own orders (最热, 最新): choosing one asks the site again.
    private var sortMenu: some View {
        let sorts = model.sorts
        return Menu {
            Picker(localized("排序"), selection: Binding(
                get: { model.sort ?? "" },
                set: { value in Task { await model.choose(sort: value) } }
            )) {
                ForEach(sorts, id: \.value) { sort in
                    Text(sort.title).tag(sort.value)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down").accessibilityHidden(true)
        }
        .accessibilityLabel(localized("排序"))
        .accessibilityValue(sorts.first { $0.value == model.sort }?.title ?? "")
        .accessibilityIdentifier("chapterComments.sort")
    }
}

#Preview("本章说") {
    let module = RuleModule(id: "preview.comments", title: "范例模组", version: "1.0.0", hosts: ["example.com"], modules: [])
    let thread = ChapterCommentThread(
        module: module,
        record: RuleListItem(name: "三体", author: "刘慈欣", bookUrl: "https://example.com/b/1", coverUrl: "", intro: "",
                             wordCount: "", lastChapter: "", kind: ""),
        chapter: ModuleCommentChapter(id: "12", title: "第十二章 红岸之二"))
    ChapterCommentsSheet(model: ChapterCommentsModel(
        heading: "第十二章 红岸之二", findThread: { thread },
        readPage: { _, _, _, page in
            page > 1 ? [] : [
                WorkReview(title: nil, text: "这一章的伏笔到第三部才收回来。", author: "读者甲", date: nil, rating: nil, likes: 128),
                WorkReview(title: nil, text: "重读才看懂叶文洁那句话。", author: "读者乙", date: nil, rating: nil, likes: 12),
            ]
        }))
}

#Preview("段评：找不到") {
    ChapterCommentsSheet(model: ChapterCommentsModel(heading: "「你们是虫子。」", paragraphID: "7", findThread: { nil },
                                                     readPage: { _, _, _, _ in [] }))
}
