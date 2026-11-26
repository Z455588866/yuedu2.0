import SwiftUI

/// 一条已经落库的原生内容。`bookID` 来自 `CatVodNativeBridge`，阅读器只认书架里的 id。
struct CatVodNativeContent: Identifiable, Sendable {
    let id: UUID
    let kind: CatVodMediaKind
    let bookID: UUID
    let title: String

    init(kind: CatVodMediaKind, bookID: UUID, title: String) {
        self.id = UUID()
        self.kind = kind
        self.bookID = bookID
        self.title = title
    }
}

/// 按内容类型把猫元解析出来的内容交给 App 自带界面：
/// - `.audio` → `NowPlayingHub.shared.openAudiobookPlayer`；顶层被 present 盖住时（返回 false）
///   用全屏的 `AudiobookReaderView` 兜底，和 `AudiobookDetailView.play` 的模式一致；
/// - `.manga` → `FixedPageReaderView(bookId:)`；
/// - `.text`  → `BookReaderView(bookId:)`（按其 `resolvedPipelineKind` 再分派到正文阅读器）。
///
/// NOTE: 未编译验证，首次构建需核对。
struct CatVodNativeContentPresenter: ViewModifier {
    @EnvironmentObject private var store: BookStore
    @Binding var nativeContent: CatVodNativeContent?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $nativeContent) { item in
                CatVodNativeReaderHost(item: item)
                    .environmentObject(store)
            }
            .onChange(of: nativeContent?.id) { _, newID in
                guard newID != nil, let item = nativeContent, item.kind == .audio else { return }
                guard let book = store.readingBook(id: item.bookID) else { return }
                // 猫元页在 NavigationStack 内，rootTabsAreFrontmost 多半为 false；
                // 返回 false 时保留 nativeContent，让上面的 fullScreenCover 呈现播放器。
                if NowPlayingHub.shared.openAudiobookPlayer(book, store: store) {
                    nativeContent = nil
                }
            }
    }
}

/// 阅读器宿主。显式关闭按钮，避免全屏封面里没有退出路径。
private struct CatVodNativeReaderHost: View {
    let item: CatVodNativeContent
    @EnvironmentObject private var store: BookStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch item.kind {
                case .manga:
                    FixedPageReaderView(bookId: item.bookID)
                case .text:
                    BookReaderView(bookId: item.bookID)
                case .audio:
                    AudiobookReaderView(bookId: item.bookID)
                case .video:
                    EmptyView()
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(localized("关闭")) { dismiss() }
                }
            }
        }
        .environmentObject(store)
    }
}
