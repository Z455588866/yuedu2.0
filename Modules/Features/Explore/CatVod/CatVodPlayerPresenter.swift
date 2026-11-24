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

    static func present(url: URL, headers: [String: String], title: String) {
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
            presentResolved(route, url: url, headers: headers, title: title)
        }
    }

    /// 决策等回来之后再取一次顶层控制器：`topVC` 是 UIKit 对象，不能跨到后台再拿回来用。
    private static func presentResolved(_ route: CatVodPlaybackRoute, url: URL,
                                        headers: [String: String], title: String) {
        guard let topVC = BookSourceFormLoginView.topViewController(),
              let scene = topVC.view.window?.windowScene else { return }
        // 等待期间可能已经有人开了播放器。
        guard topVC.presentedViewController == nil,
              !(activePlayer?.presentingViewController != nil) else { return }
        switch route {
        case .vlc(let reason) where CatVodVLCKernel.isAvailable:
            AppLogger.info("[CatVod] 用 VLC 内核播放（\(reason)）", level: .notice)
            presentVLC(url: url, headers: headers, title: title, scene: scene, on: topVC)
        default:
            presentSystem(url: url, headers: headers, title: title, scene: scene, on: topVC)
        }
    }

    private static func presentSystem(url: URL, headers: [String: String], title: String,
                                      scene: UIWindowScene, on topVC: UIViewController) {
        let stream = VideoStream(url: url, headers: headers)
        final class HostBox { weak var host: UIViewController? }
        let box = HostBox()
        let host = UIHostingController(rootView:
            VideoPlayerView(content: .link(stream, title: title)) { box.host?.dismiss(animated: true) }
                .followsScenePhase(of: scene)
        )
        box.host = host
        host.coversFullScreen()
        activePlayer = host
        topVC.present(host, animated: true)
    }

    #if canImport(VLCKitSPM)
    private static func presentVLC(url: URL, headers: [String: String], title: String,
                                   scene: UIWindowScene, on topVC: UIViewController) {
        final class HostBox { weak var host: UIViewController? }
        let box = HostBox()
        let host = UIHostingController(rootView:
            CatVodVLCVideoView(url: url, headers: headers, title: title) {
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
                                   scene: UIWindowScene, on topVC: UIViewController) {
        presentSystem(url: url, headers: headers, title: title, scene: scene, on: topVC)
    }
    #endif
}
