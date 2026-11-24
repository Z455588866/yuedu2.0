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

    /// 只有这些容器才是 VLC 的活。TS 不在此列：AVPlayer 播裸 TS 没问题。
    static let vlcOnlyExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "f4v", "wmv", "asf",
        "rm", "rmvb", "mpg", "mpeg", "vob", "divx", "xvid", "m2ts",
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
        if let kind = await sniff(url: url, headers: headers), vlcOnlyExtensions.contains(kind) {
            return .vlc(reason: kind.uppercased())
        }
        return .system
    }

    /// 读文件头，返回容器种类；读不到（超时、拒绝、直播流）就返回 nil，交给系统试。
    static func sniff(url: URL, headers: [String: String]) async -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        // 两个字节就够判 RIFF/EBML，但要读满 12 才能确认 AVI。范围小，源站不会因此传整个文件。
        request.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        request.timeoutInterval = 5
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
        if !isLoopback {
            for (field, value) in headers where field.lowercased() != "range" {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let kind = container(of: data) { return kind }
        // 指纹认不出来时再看 MIME：有些源站把 MKV 直接标成 video/x-matroska。
        if let mime = (response as? HTTPURLResponse)?.mimeType?.lowercased() {
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
