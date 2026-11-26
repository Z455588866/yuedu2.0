import Foundation

/// 一集该交给哪个内核。
///
/// 系统的 AVFoundation 只能打开 mp4/mov/m4v、HLS 与裸 TS；MKV、AVI、FLV、WMV、RMVB
/// 这些容器它根本不认，交给它只会得到「无法播放这一集」或者一片黑色。VLC 能解这些，
/// 但它的画面、弹幕、PiP 都不如系统播放器，所以只在系统开不了的时候才用它。
///
/// 判断分两步：先看地址里的扩展名（最便宜，插件给的直链常常带名字），名字看不出来
/// 再读文件最前面的 16 个字节——这是容器自己的指纹，比 Content-Type 可靠，很多源站
/// 把 MKV 标成 application/octet-stream。
enum CatVodPlaybackRoute: Sendable, Equatable {
    case system
    case vlc(reason: String)

    /// Compact tag for the diagnostic log — never includes a URL or token.
    var logTag: String {
        switch self {
        case .system: return "system"
        case .vlc(let reason): return "vlc(\(reason))"
        }
    }

    /// 只有这些容器才是 VLC 的活。TS 不在此列：AVPlayer 播裸 TS 没问题。
    static let vlcOnlyExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "f4v", "wmv", "asf",
        "rm", "rmvb", "mpg", "mpeg", "vob", "divx", "xvid", "m2ts",
    ]

    /// 系统播放器的强项格式。代理后扩展名丢失又 sniff 超时时，靠它们把
    /// HLS/MP4/纯音频从 loopback→VLC 兜底里救回来（走错内核的正是这几类）。
    static let systemOnlyExtensions: Set<String> = [
        "m3u8", "m3u", "ts", "mpd", "mp4", "m4v", "mov",
        "m4a", "m4b", "mp3", "aac", "wav", "flac", "ogg",
    ]

    static func decide(url: URL, headers: [String: String]) async -> CatVodPlaybackRoute {
        // 本地网关（127.0.0.1）的路径是 /v1/media 之类，没有扩展名，只能读字节。
        let name = url.lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        if vlcOnlyExtensions.contains(ext) {
            return .vlc(reason: ext.uppercased())
        }
        // HLS 与裸 TS 是 AVPlayer 的强项，直播走这条路；不必为一个 m3u8 再读一次文件头。
        if ["m3u8", "m3u", "ts", "mpd"].contains(ext) {
            return .system
        }
        if let kind = await sniff(url: url, headers: headers) {
            if vlcOnlyExtensions.contains(kind) { return .vlc(reason: kind.uppercased()) }
            // 本地网关把 m3u8 直播也代理成无扩展名的 127.0.0.1。sniff 认出是 HLS
            // 后要明确交给系统，不能掉进下面的 loopback→VLC 兜底（否则直播会走错内核）。
            if kind == "hls" { return .system }
        }
        // sniff 读不到（超时/空/非容器指纹）时怎么办，是这次真机日志定位到的关键：
        //   带 Cookie 的网盘线（headers=3）代理后 sniff 稳定 3 秒超时 → 落到这里；
        //   旧代码一律 return .system，而 AVFoundation 根本解不了网盘的 MKV，
        //   结果就是「无可用资源」黑屏（FongMi/TV 的做法是默认用能力最强的内核，
        //   只有明确认出是系统强项才给系统，而不是反过来）。
        // 这里优先看代理 URL 里编码的「原始格式」：m3u8/mp4/m4a 是系统强项，
        // 明确认出的 VLC 容器走 VLC，两者都不是才沿用原来的 PROXY 兜底。
        // 真 MKV 走上面 sniff 命中 EBML 的分支，不受这里影响。
        if let hint = originalExtension(of: url) {
            if vlcOnlyExtensions.contains(hint) { return .vlc(reason: hint.uppercased()) }
            if systemOnlyExtensions.contains(hint) { return .system }
        }
        if isLoopback(url) { return .vlc(reason: "PROXY") }
        return .system
    }

    /// 网关把原始地址编码进代理 URL 的 `?s=`（见 CatVodGateway.proxyURL），
    /// 扩展名因此丢失。路由决策和 VLC 内核都需要知道代理前的格式，统一在这里还原。
    /// 解不出来只返回 nil，调用方沿用原有兜底，绝不让解析失败改变既有行为。
    static func originalExtension(of url: URL) -> String? {
        // 未走代理（或代理不可用时）的直链，路径里本来就有扩展名。
        let direct = (url.lastPathComponent as NSString).pathExtension.lowercased()
        if !direct.isEmpty { return direct }
        guard let specText = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "s" })?.value else { return nil }
        // 代理 spec 用 URL-safe 且去掉 padding 的 base64，解码方式必须和网关一致。
        var base64 = specText.replacingOccurrences(of: "-", with: "+")
                             .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // 公网源：u 是原始完整地址；回环源：p 是原始 path（可能带 query）。
        if let original = spec["u"] as? String, let ext = extensionFromPath(original) { return ext }
        if let path = spec["p"] as? String, let ext = extensionFromPath(path) { return ext }
        return nil
    }

    private static func extensionFromPath(_ path: String) -> String? {
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let ext = (withoutQuery as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    private static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
    }

    /// 读文件头，返回容器种类；读不到（超时、拒绝、直播流）就返回 nil，交给系统试。
    static func sniff(url: URL, headers: [String: String]) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        // 两个字节就够判 RIFF/EBML，但要读满 12 才能确认 AVI。范围小，源站不会因此传整个文件。
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        request.timeoutInterval = 3
        let isLoopback = Self.isLoopback(url)
        if !isLoopback {
            for (field, value) in headers where field.lowercased() != "range" {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        // 只读前 16 字节就断开。用 data(for:) 会把整个响应读进内存——遇到
        // 不认 Range 的服务（Python 源的 localProxy 就是），那就是几百 MB。
        guard let (stream, response) = try? await URLSession.shared.bytes(for: request) else { return nil }
        var data = Data()
        do {
            for try await byte in stream {
                data.append(byte)
                if data.count >= 16 { break }
            }
        } catch {
            // 读到一半断开也算拿到指纹；一个字节没读到就交给系统播放器。
        }
        if let kind = container(of: data) { return kind }
        // HLS 播放列表是文本，前几个字节就是 #EXTM3U；本地网关代理后扩展名丢失，
        // 靠这个把它和网盘二进制容器区分开，避免直播被 loopback 兜底塞给 VLC。
        if let head = String(data: data.prefix(16), encoding: .utf8),
           head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXT") {
            return "hls"
        }
        // 指纹认不出来时再看 MIME：有些源站把 MKV 直接标成 video/x-matroska。
        if let mime = (response as? HTTPURLResponse)?.mimeType?.lowercased() {
            if mime.contains("mpegurl") { return "hls" }
            if mime.contains("matroska") { return "mkv" }
            if mime.contains("msvideo") { return "avi" }
            if mime.contains("x-flv") { return "flv" }
            if mime.contains("vnd.rn-realmedia") { return "rmvb" }
            if mime.contains("x-ms-wmv") || mime.contains("x-ms-asf") { return "wmv" }
        }
        return nil
    }

    /// 容器文件头里的指纹。EBML、RIFF/AVI、FLV、ASF、RealMedia、MPEG-PS。
    static func container(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return nil }
        func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        if bytes[0..<4].elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) { return "mkv" }
        if bytes.count >= 12, text(0..<4) == "RIFF", text(8..<12) == "AVI " { return "avi" }
        if text(0..<3) == "FLV" { return "flv" }
        if bytes[0..<4].elementsEqual([0x30, 0x26, 0xB2, 0x75]) { return "wmv" }
        if text(0..<4) == ".RMF" { return "rmvb" }
        if bytes[0..<4].elementsEqual([0x00, 0x00, 0x01, 0xBA]) { return "mpg" }
        return nil
    }
}
