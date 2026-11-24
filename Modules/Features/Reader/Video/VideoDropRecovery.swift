import Foundation

/// 断流自动重连。
///
/// AVPlayer 只在缓冲时自己等，连接真断了（切 Wi-Fi、CDN 掐连接、网盘签名过期前
/// 的一次抖动）它会直接结束这一集，停在「无法播放这一集」，要人手动退出重进。
/// 安卓的播放器（ExoPlayer/lijk）都是自己重连的，这里补上同样的行为：按 1s、3s、8s
/// 在原位置重开三次，中途能连续播满一分钟就重新计数。
///
/// 只对「连接类」错误重连。403/404 是链接本身失效，重连没有意义；解码失败也不是
/// 网络问题，重开只会让人多等 12 秒。
struct VideoDropRecovery: Sendable {
    static let delays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
    /// 从这个位置往后连续播了这么久，说明连接回来了，计数清零。
    static let recovered: Double = 60

    private(set) var attempts = 0
    private var reopenedAt: Double?

    /// 下一次重开前要等多久；nil 表示这次该把错误显示出来。
    mutating func delay(after failure: Error?, position: Double) -> Duration? {
        guard Self.isDrop(failure), position.isFinite else { return nil }
        if let reopenedAt, abs(position - reopenedAt) >= Self.recovered { attempts = 0 }
        guard attempts < Self.delays.count else { return nil }
        reopenedAt = position
        attempts += 1
        return Self.delays[attempts - 1]
    }

    mutating func reset() {
        attempts = 0
        reopenedAt = nil
    }

    /// 连接断掉、超时、断网、主机不可达，以及媒体「一直没数据」——这些都值得重开。
    /// 与「服务器拒绝这个链接」（403/404）和「解码不了」区分开。
    static func isDrop(_ error: Error?) -> Bool {
        var current = error as NSError?
        var dropped = false
        while let error = current {
            switch error.domain {
            case NSURLErrorDomain:
                guard droppedConnection.contains(error.code) else { return false }
                dropped = true
            case "CoreMediaErrorDomain":
                guard stalledMedia.contains(error.code) else { return false }
                dropped = true
            default:
                break
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return dropped
    }

    /// -1005 连接丢失、-1001 超时、-1009 断网、-1004 连不上、-1003 找不到主机、
    /// -1200 TLS 握手失败（已经播过同一连接，多半是网络换手）。
    static let droppedConnection: Set<Int> = [
        NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
        NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
        NSURLErrorSecureConnectionFailed,
    ]
    /// Core Media 的 -15628（媒体加载失败）与 -12889（媒体文件无响应）。
    static let stalledMedia: Set<Int> = [-15628, -12889]
}
