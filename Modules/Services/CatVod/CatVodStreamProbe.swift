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
        request.timeoutInterval = isLoopback ? 5 : 12
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
                // The proxy died with its session. Re-resolving the episode is
                // the actual fix, so this must be retryable rather than fatal.
                return .retryable(localized("播放代理已断开（源会话被回收），请重试这一集"))
            }
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
}
