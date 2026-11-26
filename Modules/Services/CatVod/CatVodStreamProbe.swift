import Foundation

/// AVFoundation funnels every network-level failure into one system sheet:
/// 「无法连接服务器。」 — no host, no status, no hint, and it reads like the app
/// broke. CatVod lines fail for very different reasons (dead domain, self-signed
/// certificate, expired netdisk token, retired proxy session), so probe the
/// stream once here and name the actual cause before opening a black player.
///
/// Only *transport* failures are reported. Anything that got an HTTP answer —
/// 403, 404, 500 — is left to the player: AVPlayer sends its own headers and may
/// well succeed where this probe does not, so guessing there would block a line
/// that plays fine.
enum CatVodStreamProbe {
    enum Verdict {
        case playable
        /// Fatal for this attempt: say why and let the person pick another line.
        case blocked(String)
        /// The bundle's proxy is gone; resolving the episode again usually
        /// rebuilds it, so the caller should retry once before giving up.
        case retryable(String)
    }

    static func check(_ url: URL, headers: [String: String]) async -> Verdict {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return .playable
        }

        var request = URLRequest(url: url)
        request.setValue("bytes=0-1024", forHTTPHeaderField: "Range")
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "")
        // 探测只是「提前说清楚死因」，不是播放的前置条件。以前给 12 秒，网盘 CDN
        // 光握手就要好几秒，于是正常线路被判定成"源站连不上"，人看到转圈十几秒
        // 然后回到选集——也就是"点了半天进不去播放器"。6 秒够识别死域名。
        request.timeoutInterval = 6
        // Loopback belongs to the bundle's own proxy; its headers are not ours to
        // forward, and a stale Range can upset it.
        if !isLoopback {
            for (field, value) in headers where field.lowercased() != "range" {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }

        do {
            _ = try await URLSession.shared.data(for: request)
            return .playable
        } catch let error as URLError {
            if isLoopback {
                // 127.0.0.1 是我们自己的网关：第一包要等 spider 去远端换地址
                // （短剧源经常 5 秒以上才开始吐流），探测超时完全不代表播不了。
                // 以前在这里报「播放代理已断开」，红果短剧每一集都被这句话拦下，
                // 其实播放器自己连上去就能播。交给 AVPlayer 判定。
                return .playable
            }
            // 网盘/大文件 CDN 对 Range 探测经常不回包，超时不代表不能播。这类地址
            // 交给 AVPlayer 自己谈，失败时播放器会带着自己的错误提示。
            if error.code == .timedOut, Self.isNetdiskCDN(url) { return .playable }
            switch error.code {
            case .cannotFindHost, .dnsLookupFailed:
                return .blocked(localized("这条线路的域名已失效（源站问题），换一条线路或换一个源"))
            case .cannotConnectToHost, .networkConnectionLost, .timedOut:
                return .blocked(localized("源站连不上（超时或被拒绝，源自己的问题），换一条线路或稍后重试"))
            case .notConnectedToInternet:
                return .blocked(localized("手机当前没有网络"))
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return .blocked(localized("这条线路的证书无效，iOS 播放器无法直接播放"))
            case .unsupportedURL:
                return .blocked(localized("这一集的播放地址格式不受支持"))
            default:
                return .playable
            }
        } catch {
            return .playable
        }
    }

    /// 网盘与云存储的下载节点。它们的签名 URL 对 `Range` 探测不友好，超时很常见。
    private static func isNetdiskCDN(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let markers = ["baidupcs", "pan.baidu", "quark", "uc.cn", "aliyundrive", "alipan",
                       "aliyuncs", "115.com", "115cdn", "123pan", "123684", "123865",
                       "pcs.baidu", "d.pcs"]
        return markers.contains { host.contains($0) }
    }
}
