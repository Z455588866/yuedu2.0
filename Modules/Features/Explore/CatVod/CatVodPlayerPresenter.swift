import Foundation
import SwiftUI
import UIKit

/// Presents a resolved CatVod stream in the app's own full-screen player, so danmaku, subtitles,
/// PiP and gestures are identical to every other video. Mirrors `SourceBrowserPresenter.presentVideo`.
@MainActor
enum CatVodPlayerPresenter {
    /// The player currently on screen. `topViewController()` returns the topmost
    /// presented controller, so once a player is up, its own
    /// `presentedViewController` is nil and the check below cannot see it — this
    /// weak reference is what actually stops a second player stacking on top.
    private static weak var activePlayer: UIViewController?

    static func present(url: URL, headers: [String: String], title: String,
                        danmaku: CatVodDanmakuPayload? = nil,
                        info: VideoStreamInfo? = nil,
                        onNextEpisode: (@MainActor () -> Void)? = nil) {
        // 弹幕**不能**在这里同步取完再播：红果的弹幕要按 30 秒一个窗口打 20 次接口，
        // 取完要几秒到十几秒，先取再播就等于点一集黑屏十几秒。这里只把「怎么取」
        // 交给播放器，片子先起来，弹幕到了再叠上去。
        let loader: (@MainActor () async -> [DanmakuItem]?)?
        if let danmaku {
            loader = { await DanmakuFeed.load(danmaku) }
        } else {
            loader = nil
        }
        guard let topVC = BookSourceFormLoginView.topViewController() else { return }
        // Never stack a second player on top of one that is already presented or
        // mid-presentation. Repeated episode taps (or a slow resolve that lands
        // late) must not pile up a dozen full-screen players.
        if topVC.presentedViewController != nil { return }
        if let activePlayer, activePlayer.presentingViewController != nil { return }
        guard topVC.view.window?.windowScene != nil else { return }
        Task { @MainActor in
            // AVFoundation 打不开的容器（MKV/AVI/FLV…）交给 VLC 内核，别的仍用系统
            // 播放器——弹幕、字幕、画中画都在那边。判断要读一次文件头，所以放到
            // 异步里，不阻塞点击。
            let route = await CatVodPlaybackRoute.decide(url: url, headers: headers)
            // scheme + host only: playback URLs carry share tokens in the query.
            AppLogger.info("[CatVod] ⟐ present route=\(route.logTag) url=\(url.scheme ?? "?")://\(url.host ?? "?") ext=\(url.pathExtension)", level: .notice)
            presentResolved(route, url: url, headers: headers, title: title,
                            danmaku: loader, info: info, onNextEpisode: onNextEpisode)
        }
    }

    /// 决策等回来之后再取一次顶层控制器：`topVC` 是 UIKit 对象，不能跨到后台再拿回来用。
    private static func presentResolved(_ route: CatVodPlaybackRoute, url: URL,
                                        headers: [String: String], title: String,
                                        danmaku: (@MainActor () async -> [DanmakuItem]?)?,
                                        info: VideoStreamInfo?,
                                        onNextEpisode: (@MainActor () -> Void)?) {
        guard let topVC = BookSourceFormLoginView.topViewController(),
              let scene = topVC.view.window?.windowScene else { return }
        // 等待期间可能已经有人开了播放器。
        guard topVC.presentedViewController == nil,
              !(activePlayer?.presentingViewController != nil) else { return }
        switch route {
        case .vlc(let reason) where CatVodVLCKernel.isAvailable:
            AppLogger.info("[CatVod] 用 VLC 内核播放（\(reason)）", level: .notice)
            presentVLC(url: url, headers: headers, title: title, danmaku: danmaku,
                       info: info, onNextEpisode: onNextEpisode, scene: scene, on: topVC)
        default:
            presentSystem(url: url, headers: headers, title: title, danmaku: danmaku,
                          info: info, onNextEpisode: onNextEpisode, scene: scene, on: topVC)
        }
    }

    private static func presentSystem(url: URL, headers: [String: String], title: String,
                                      danmaku: (@MainActor () async -> [DanmakuItem]?)?,
                                      info: VideoStreamInfo?, onNextEpisode: (@MainActor () -> Void)?,
                                      scene: UIWindowScene, on topVC: UIViewController) {
        let stream = VideoStream(url: url, headers: headers, info: info)
        final class HostBox { weak var host: UIViewController? }
        let box = HostBox()
        // 播完一集：先关掉当前全屏播放器，再让上层解析并播下一集。
        // 必须等 dismiss 完成再回调，否则上一个播放器还占着屏，present 会被防重叠拦掉。
        var ended: (@MainActor () -> Void)?
        if let next = onNextEpisode {
            let action: @MainActor () -> Void = {
                box.host?.dismiss(animated: false) {
                    Task { @MainActor in next() }
                }
            }
            ended = action
        }
        let host = UIHostingController(rootView:
            VideoPlayerView(content: .link(stream, title: title), danmaku: danmaku,
                            onNoVideoTrack: { [weak topVC] stream, at in
                Self.switchToVLC(stream: stream, startAt: at, headers: headers, title: title,
                                 danmaku: danmaku, info: info, onNextEpisode: onNextEpisode,
                                 scene: scene, presenting: topVC, systemHost: box.host)
            }, onPlaybackEnded: ended) { box.host?.dismiss(animated: true) }
                .followsScenePhase(of: scene)
        )
        box.host = host
        host.coversFullScreen()
        activePlayer = host
        topVC.present(host, animated: true)
    }

    /// 给书源脚本 `java.openVideoPlayer` 用的换核入口：系统内核解不出画面时切 VLC。
    /// 与猫源共用一个实现；单集直链没有下一集，onNextEpisode 传 nil。
    /// 必须放在这里而不是调用方：`CatVodVLCVideoView` 只在 VLCKit 构建中存在，
    /// 由本文件内已有的 `#if canImport(VLCKitSPM)` 边界统一保护。
    static func replaceWithVLC(stream: VideoStream, startAt: Double, title: String,
                               scene: UIWindowScene, presenting: UIViewController,
                               systemHost: UIViewController) {
        switchToVLC(stream: stream, startAt: startAt, headers: stream.headers, title: title,
                    danmaku: nil, info: stream.info, onNextEpisode: nil,
                    scene: scene, presenting: presenting, systemHost: systemHost)
    }

    /// 系统内核只解出音频轨（有声音没画面）时的兜底：把这一集原样交给 VLC 软解重播一次。
    /// 只有系统内核的检测回调会走到这里；VLC 视图不设该回调，不会来回切。
    private static func switchToVLC(stream: VideoStream, startAt: Double,
                                    headers: [String: String], title: String,
                                    danmaku: (@MainActor () async -> [DanmakuItem]?)?,
                                    info: VideoStreamInfo?, onNextEpisode: (@MainActor () -> Void)?,
                                    scene: UIWindowScene,
                                    presenting: UIViewController?, systemHost: UIViewController?) {
        guard let systemHost, systemHost.presentingViewController != nil,
              let presenting else { return }
        // 进度先落盘：即使 startAt 传参环节出意外，VLC 侧仍能从 VideoLinkPositions 续上。
        VideoLinkPositions.save(startAt, for: stream.url)
        AppLogger.info("[CatVod] 系统内核无画面，切 VLC 内核重播（\(Int(startAt))s）", level: .notice)
        systemHost.dismiss(animated: false) {
            Task { @MainActor in
                guard presenting.presentedViewController == nil else { return }
                presentVLC(url: stream.url, headers: headers, title: title, danmaku: danmaku,
                           info: info, startAt: startAt, onNextEpisode: onNextEpisode,
                           scene: scene, on: presenting)
            }
        }
    }

    #if canImport(VLCKitSPM)
    private static func presentVLC(url: URL, headers: [String: String], title: String,
                                   danmaku: (@MainActor () async -> [DanmakuItem]?)?,
                                   info: VideoStreamInfo?, startAt: Double = 0,
                                   onNextEpisode: (@MainActor () -> Void)?,
                                   scene: UIWindowScene, on topVC: UIViewController) {
        final class HostBox { weak var host: UIViewController? }
        let box = HostBox()
        var ended: (@MainActor () -> Void)?
        if let next = onNextEpisode {
            let action: @MainActor () -> Void = {
                box.host?.dismiss(animated: false) {
                    Task { @MainActor in next() }
                }
            }
            ended = action
        }
        let host = UIHostingController(rootView:
            CatVodVLCVideoView(url: url, headers: headers, title: title, startAt: startAt,
                               danmaku: danmaku, info: info, onPlaybackEnded: ended) {
                box.host?.dismiss(animated: true)
            }
            .followsScenePhase(of: scene)
        )
        box.host = host
        host.coversFullScreen()
        activePlayer = host
        topVC.present(host, animated: true)
    }
    #else
    private static func presentVLC(url: URL, headers: [String: String], title: String,
                                   danmaku: (@MainActor () async -> [DanmakuItem]?)?,
                                   info: VideoStreamInfo?, startAt: Double = 0,
                                   onNextEpisode: (@MainActor () -> Void)?,
                                   scene: UIWindowScene, on topVC: UIViewController) {
        // 没链接 VLCKit 的构建无法软解兜底，维持原来的系统内核行为。
        presentSystem(url: url, headers: headers, title: title, danmaku: danmaku,
                      info: info, onNextEpisode: onNextEpisode, scene: scene, on: topVC)
    }
    #endif
}

// MARK: - 片源弹幕加载

/// 把源给的 `danmaku` 载荷变成播放器能画的行。
///
/// 三种形态都要接：
/// 1. 行数组 —— TVBox 规范，可直接用；
/// 2. 单个地址 —— 拉下来是 B 站 XML；
/// 3. 弹幕源列表 `[{name, url}]` —— 红果就是这种，地址指向插件进程里的 `/hg_dm`。
///
/// 全过程放在播放之后执行：拉弹幕要几秒到十几秒，先取再播就是点一集黑屏十几秒。
enum DanmakuFeed {
    @MainActor
    static func load(_ payload: CatVodDanmakuPayload) async -> [DanmakuItem]? {
        if !payload.items.isEmpty {
            let rows: [DanmakuItem] = payload.items.enumerated().compactMap { index, row in
                make(time: row.time, mode: row.type ?? 1, color: row.color ?? 0xFFFFFF,
                     text: row.text, cid: index)
            }
            return rows.isEmpty ? nil : rows
        }
        var candidates: [String] = []
        if let link = payload.link, !link.isEmpty { candidates.append(link) }
        candidates.append(contentsOf: payload.sources.compactMap(\.url).filter { !$0.isEmpty })
        for address in candidates {
            // 弹幕地址若是插件进程的 loopback，直连会随会话回收而 404。
            // 走网关代理（与播放同一条稳定路由），由网关重建会话再取。
            let routed = Self.proxied(address, bundleURL: payload.bundleURL)
            if let items = await fetchXML(routed), !items.isEmpty { return items }
        }
        return nil
    }

    /// 把弹幕地址改写成网关代理。仅对 loopback 且能拿到 bundle 身份时改写；
    /// 普通公网弹幕源（B 站 XML）直连即可，不必绕网关。
    @MainActor
    private static func proxied(_ address: String, bundleURL: String?) -> String {
        guard let bundleURL,
              let original = URL(string: address),
              let host = original.host?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host),
              let proxied = CatVodGateway.shared.danmakuProxyURL(for: original,
                                                                  bundleURL: bundleURL) else {
            return address
        }
        return proxied.absoluteString
    }

    private static func make(time: Double, mode: Int, color: Int,
                             text: String, cid: Int) -> DanmakuItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, time.isFinite, time >= 0 else { return nil }
        let resolvedMode = (mode == 4 || mode == 5) ? mode : 1
        let rgb = UInt32(max(0, min(color, 0xFFFFFF)))
        return DanmakuItem(time: time, text: trimmed, mode: resolvedMode, color: rgb, cid: cid)
    }

    private static func fetchXML(_ address: String) async -> [DanmakuItem]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        // 红果的弹幕按时间窗打 20 次接口才取全，服务端会 hold 住请求直到取完
        // 或到它自己的上限（18 秒）；客户端超时设宽一点，别在最后一刻放弃。
        request.timeoutInterval = 25
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        let parser = XMLParser(data: data)
        let delegate = DanmakuXMLParser()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.items.isEmpty ? nil : delegate.items
    }
}

/// B 站弹幕 XML：`<d p="起始秒,模式,字号,颜色,...">正文</d>`。
/// 用 XMLParser 而不是正则，是因为正文里的 `&amp;` / `&lt;` 要按实体还原。
private final class DanmakuXMLParser: NSObject, XMLParserDelegate {
    private(set) var items: [DanmakuItem] = []
    private var buffer: String?
    private var attributes: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard elementName == "d" else { return }
        attributes = attributeDict
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if buffer != nil { buffer?.append(string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard elementName == "d", let text = buffer else { return }
        buffer = nil
        let parts = (attributes["p"] ?? "").split(separator: ",")
        guard parts.count >= 4,
              let time = Double(parts[0]),
              let mode = Int(parts[1]),
              let color = Int(parts[3]) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, time >= 0 else { return }
        let resolved = (mode == 4 || mode == 5) ? mode : 1
        items.append(DanmakuItem(time: time, text: trimmed, mode: resolved,
                                 color: UInt32(max(0, min(color, 0xFFFFFF))),
                                 cid: items.count))
    }
}
