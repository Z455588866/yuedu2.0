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
        guard let topVC = BookSourceFormLoginView.topViewController(),
              let scene = topVC.view.window?.windowScene else { return }
        // Never stack a second player on top of one that is already presented or
        // mid-presentation. Repeated episode taps (or a slow resolve that lands
        // late) must not pile up a dozen full-screen players.
        if topVC.presentedViewController != nil { return }
        if let activePlayer, activePlayer.presentingViewController != nil { return }
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
}
