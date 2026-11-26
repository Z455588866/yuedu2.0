import Foundation

/// 猫源 / Python 源里「非视频」的三种内容：音乐听书、漫画、小说文字。
///
/// 判定信号按可靠度排序：
/// 1. `playerContent` 返回的 url 本身（最可靠，已由 `CatVodService.player` 归一化）；
/// 2. 列表条目的 `vod_type`（自由文本，只作兜底）；
/// 3. 站点 type（PY 源一律被包装成 4，几乎无区分力）。
///
/// 已用真实 PY 源坐实：
/// - 喜马拉雅 / 音乐聚合：`playerContent` 返回 mp3/m4a/aac 音频直链；
/// - 包子漫画：`playerContent` 返回 `mange://https://img1&&https://img2&&…`；
/// - 哈密瓜动漫：`playerContent` 返回 m3u8 —— 与视频不可区分，按约定走现有视频播放器。
///
/// 已知限制：`CatVodService.player` 用 `firstURL` 过滤 `url`，纯正文（没有 `://`、
/// 也没有媒体扩展名）会在到达本类之前被判空。因此小说文字只在 url 带 scheme
/// （如 `json://…`）或正文含 `://` 时能被识别；要覆盖裸正文需改 CatVodService
/// 暴露原始 player 对象，本轮按「改动面最小」不动它。
///
/// NOTE: 未编译验证，首次构建需核对。
enum CatVodMediaKind: String, Sendable {
    case audio
    case manga
    case text
    case video
}

extension CatVodMediaKind {

    /// 与 `DirectChapterAudioResolver.audioExtensions` 保持一致。
    private static let audioExtensions: Set<String> = [
        "aac", "aiff", "aif", "flac", "m4a", "m4b", "mp3", "oga", "ogg", "opus", "wav"
    ]
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "bmp"
    ]
    private static let videoExtensions: Set<String> = [
        "m3u8", "mp4", "mkv", "avi", "mov", "flv", "ts", "wmv", "rmvb", "webm"
    ]

    /// 喜马拉雅的 `vod_type` 有「有声书 / 音乐 / 相声 / 广播剧 / 播客」，
    /// 音乐聚合把平台名写进 `vod_area`，听书源写「有声小说」。
    private static let audioNameKeywords = [
        "有声书", "听书", "音乐", "歌曲", "相声", "评书", "播客", "广播剧",
        "asmr", "助眠", "有声小说", "戏曲", "朗读", "音频"
    ]
    private static let mangaNameKeywords = [
        "漫画", "漫畫", "comic", "manga", "图漫", "條漫", "条漫"
    ]
    private static let textNameKeywords = [
        "小说", "小說", "文字", "文学", "文學", "ebook", "txt"
    ]

    /// 列表点击一律先进详情页（粗判会误判）；真正的类型在拿到 `playerContent`
    /// 的 url 后由 `classify` 精判，详情页点集时按它分流到听书/漫画/阅读器。

    /// 用播放结果精判内容类型。无法区分的 m3u8 一律按 `.video`（现有播放器）。
    static func classify(playbackURL: String, typeName: String, siteType: Int?) -> CatVodMediaKind {
        let raw = playbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = raw.lowercased()

        // 漫画：包子漫画把图片地址用 && 拼成 `mange://https://img1&&https://img2`。
        if mangaContent(from: raw) != nil { return .manga }
        if lowered.hasPrefix("["), parsedImageCount(from: raw) >= 2 { return .manga }

        // 音频：扩展名最强；无扩展名的签名 CDN 用 query 里的 mime/type 兜底。
        if let ext = pathExtension(of: raw), audioExtensions.contains(ext) { return .audio }
        if lowered.contains("mime=audio") || lowered.contains("type=audio") { return .audio }

        // 视频：哈密瓜动漫的 m3u8 落在这里，和漫画无法仅凭扩展名区分，按现有播放器走。
        if let ext = pathExtension(of: raw), videoExtensions.contains(ext) { return .video }
        if lowered.contains(".m3u8") || lowered.contains(".mp4") { return .video }

        // 小说文字：player 直接把正文放在 url 字段（CatVodPlayback.url 是 String）。
        // 带 scheme 的地址（parse:/json:/magnet: 等）不算正文，交给原播放链路。
        if !lowered.contains("://") && !lowered.hasPrefix("parse:")
            && !lowered.hasPrefix("json:") && raw.count >= 24 {
            return .text
        }

        // 兜底：喜马拉雅的 track 直链可能不带扩展名，用列表类型名认。
        let hint = (typeName + " " + siteTypeName(siteType)).lowercased()
        if audioNameKeywords.contains(where: { hint.contains($0) }) { return .audio }
        if mangaNameKeywords.contains(where: { hint.contains($0) }) { return .manga }
        if textNameKeywords.contains(where: { hint.contains($0) }) { return .text }
        return .video
    }

    /// 把猫源漫画的播放结果转成 `MangaChapterParser.parsedImages` 能直接吃的内容。
    /// 返回 nil 表示不是漫画地址。已知的猫源/图库漫画格式：
    /// - `mange://https://img1&&https://img2`（包子漫画）；
    /// - JSON 字符串数组 `["https://a.jpg","https://b.jpg"]`；
    /// - `<img src=…>` HTML（聚合源常见）；
    /// - 换行分隔的图片直链列表；
    /// - 单张图片直链（图库类源一集一张长图）。
    /// JSON/HTML/换行列表交给 `MangaChapterParser.looksLikeMangaContent` 同一套启发式
    /// （≥3 张图、几乎无正文），阅读器端本来就按这些格式解析，判定与解析保持一致。
    static func mangaContent(from url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 猫源自造的伪 scheme（mange:// 等）只剥壳；http(s) 原样保留。
        var content = trimmed
        if let scheme = content.range(of: "://") {
            let name = String(content[..<scheme.lowerBound]).lowercased()
            if name != "http" && name != "https" {
                content = String(content[scheme.upperBound...])
            }
        }

        // && 拼接的图片串：拆开、归一化协议后转成 JSON 数组。
        if content.contains("&&") {
            let images = content.components(separatedBy: "&&").compactMap { part -> String? in
                var token = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if let scheme = token.range(of: "://") {
                    let name = String(token[..<scheme.lowerBound]).lowercased()
                    if name != "http" && name != "https" {
                        token = String(token[scheme.upperBound...])
                    }
                }
                if token.hasPrefix("//") { token = "https:" + token }
                let lowered = token.lowercased()
                guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
                return token
            }
            guard images.count >= 2 else { return nil }
            guard JSONSerialization.isValidJSONObject(images),
                  let data = try? JSONSerialization.data(withJSONObject: images),
                  let json = String(data: data, encoding: .utf8) else { return nil }
            return json
        }

        // JSON 图片数组：全部元素都是 http(s) 直链即为漫画（≥2 张也认，
        // 比 looksLikeMangaContent 的 ≥3 门槛更宽，JSON 数组本身已无歧义）。
        if content.hasPrefix("["),
           let data = content.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [String],
           !array.isEmpty {
            let http = array.filter {
                let lowered = $0.lowercased()
                return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
            }
            if http.count == array.count { return content }
        }

        // JSON 图片数组 / <img> HTML / 换行图片列表：与阅读器同一判定。
        if MangaChapterParser.looksLikeMangaContent(content) { return content }

        // 单张图片直链：图库类源一集一张长图。视频地址不会以图片扩展名结尾，
        // 误判风险为零；漫画阅读器按单页呈现。
        if let ext = pathExtension(of: content), imageExtensions.contains(ext) {
            return content
        }
        return nil
    }

    // MARK: - private

    private static func parsedImageCount(from json: String) -> Int {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return 0 }
        return array.filter {
            let lowered = $0.lowercased()
            return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
        }.count
    }

    /// 优先取 URL path 的扩展名；没有时扫 query（签名 CDN 常把文件名放参数里）。
    private static func pathExtension(of raw: String) -> String? {
        if let url = URL(string: raw), !url.pathExtension.isEmpty {
            return url.pathExtension.lowercased()
        }
        guard let mark = raw.firstIndex(of: "?") else { return nil }
        let query = String(raw[raw.index(after: mark)...]).lowercased()
        for ext in audioExtensions.union(videoExtensions).union(imageExtensions) {
            if query.contains(".\(ext)") { return ext }
        }
        return nil
    }

    /// 猫源协议 1=音频 2=图片 3=文件 4=视频；PY 源一律被包装成 4。
    private static func siteTypeName(_ type: Int?) -> String {
        switch type {
        case 1: return "有声书 音乐"
        case 2: return "漫画"
        case 3: return "文件"
        case 4: return "视频"
        default: return ""
        }
    }
}
