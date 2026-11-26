import CryptoKit
import Foundation

/// 猫元原生内容桥接的产物。`bookID` 已经落库 —— `BookReaderView` / `FixedPageReaderView`
/// 都只认书架里的 id（`FixedPageReaderView.swift:103` 从 store 读），所以三类内容统一落库。
struct CatVodNativeBook: Sendable {
    let kind: CatVodMediaKind
    let bookID: UUID
    let title: String
}

enum CatVodNativeBridgeError: Error, LocalizedError {
    case emptyContent
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .emptyContent:
            return localized("这个源没有返回可接入原生阅读器的内容")
        case .verificationFailed:
            return localized("内容缓存校验失败，请重试")
        }
    }
}

/// 把 `CatVodPlayback { url, header }` 转成 App 自带界面能消费的内容：
/// - 音频 URL → `OnlineChapterRef` + 虚拟音频源（`readsChapterURLAsContent` 把 URL 当正文）；
/// - 漫画图片列表 → 章节正文（JSON 图片数组，由 `MangaChapterParser` 解析；
///   `bookSourceType == 2` 不命中 `readsChapterURLAsContent`，必须预写缓存）；
/// - 小说文字 → 预写 `ChapterPackage` 缓存（`saveChapterPackageToCache`），
///   `sourceURL` / `tocTitle` 与 `OnlineChapterRef` 严格对齐，否则缓存校验失败会回落规则引擎。
///
/// NOTE: 未编译验证，首次构建需核对（所有 API 签名均按真实代码逐条核对）。
@MainActor
enum CatVodNativeBridge {

    static func bridge(
        playback: CatVodPlayback,
        media: CatVodMedia,
        site: CatVodSite?,
        store: BookStore
    ) throws -> CatVodNativeBook {
        let url = playback.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind = CatVodMediaKind.classify(
            playbackURL: url, typeName: media.typeName, siteType: site?.type)
        guard kind != .video else { throw CatVodNativeBridgeError.emptyContent }

        // 章节正文与 url：音频用真实直链（虚拟源 type=1 时空内容规则会把它当正文）；
        // 漫画/文字用稳定的合成 key，避免图片列表/正文被当成网络地址去抓。
        let content: String
        let chapterURL: String
        switch kind {
        case .audio:
            guard !url.isEmpty else { throw CatVodNativeBridgeError.emptyContent }
            content = url
            chapterURL = url
        case .manga:
            guard let images = CatVodMediaKind.mangaContent(from: url) else {
                throw CatVodNativeBridgeError.emptyContent
            }
            content = images
            chapterURL = syntheticURL(kind: kind, site: site, media: media)
        case .text:
            guard !url.isEmpty else { throw CatVodNativeBridgeError.emptyContent }
            content = url
            chapterURL = syntheticURL(kind: kind, site: site, media: media)
        case .video:
            throw CatVodNativeBridgeError.emptyContent
        }

        // 1) 虚拟书源：空内容规则 + 类型号；header 把猫源播放器拿到的 referer/UA 带过去。
        // 按 bookSourceUrl 复用已有虚拟源，不再每次点击都 add 一条——以前反复打开同一
        // 站点会在用户的书源列表里堆出几十条「猫元·听书/漫画/小说」，还会触发同步写盘。
        // 来源 url 由 kind+site 决定，是稳定身份；正文已预写缓存，header 差异不影响取内容。
        let sourceURL = "catvod-native://\(kind.rawValue)/\(site?.key ?? "site")"
        let sourceID: UUID
        if let existing = BookSourceStore.shared.sources.first(where: {
            $0.bookSourceUrl == sourceURL
        }) {
            sourceID = existing.id
        } else {
            var source = BookSource()
            source.bookSourceName = "猫元·\(label(for: kind))"
            source.bookSourceUrl = sourceURL
            source.bookSourceType = kind == .audio ? 1 : (kind == .manga ? 2 : 0)
            source.ruleContent.content = ""
            source.header = headerJSON(playback.header ?? [:])
            BookSourceStore.shared.add(source)
            sourceID = source.id
        }

        // 2) 章节引用：addOnlineBook 会用 ReaderHTMLUtilities 清洗 title，
        //    因此缓存里的 tocTitle 必须用同一份清洗后的值；sourceURL 原样使用。
        let rawTitle = media.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localized("第 1 章") : media.name
        let storedTitle = ReaderHTMLUtilities.displayText(fromHTMLFragment: rawTitle)
        let chapter = OnlineChapterRef(index: 0, title: storedTitle, url: chapterURL)

        // 3) 落库拿 bookId。
        let book = store.addOnlineBook(
            name: media.name.isEmpty ? storedTitle : media.name,
            author: "",
            sourceId: sourceID,
            bookInfoURL: chapterURL,
            coverUrl: media.cover,
            contentKind: contentKind(for: kind),
            chapters: [chapter]
        )

        // 4) 预写 ChapterPackage 缓存，三类内容都不再触发网络/规则解析。
        let checksum = SHA256.hash(data: Data(content.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let package = ChapterPackage(
            bookId: book.id,
            chapterIndex: 0,
            sourceURL: chapterURL,
            tocTitle: storedTitle,
            canonicalTitle: nil,
            content: content,
            contentChecksum: checksum,
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
        try BookSourceFetcher.shared.saveChapterPackageToCache(
            package, rawHTML: nil, normalizedHTML: nil)
        guard let verified = BookSourceFetcher.shared.loadChapterPackageSync(
            bookId: book.id,
            chapterIndex: 0,
            expectedSourceURL: chapterURL,
            expectedTOCTitle: storedTitle
        ), verified.content == content else {
            throw CatVodNativeBridgeError.verificationFailed
        }

        return CatVodNativeBook(kind: kind, bookID: book.id, title: media.name)
    }

    // MARK: - private

    private static func syntheticURL(kind: CatVodMediaKind, site: CatVodSite?,
                                     media: CatVodMedia) -> String {
        "catvod-native://\(kind.rawValue)/\(site?.key ?? "site")/\(media.id)/0"
    }

    private static func contentKind(for kind: CatVodMediaKind) -> OnlineBookContentKind {
        switch kind {
        case .audio: return .audio
        case .manga: return .manga
        case .text: return .text
        case .video: return .video
        }
    }

    private static func label(for kind: CatVodMediaKind) -> String {
        switch kind {
        case .audio: return localized("听书")
        case .manga: return localized("漫画")
        case .text: return localized("小说")
        case .video: return localized("视频")
        }
    }

    private static func headerJSON(_ headers: [String: String]) -> String {
        guard JSONSerialization.isValidJSONObject(headers),
              let data = try? JSONSerialization.data(withJSONObject: headers),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
