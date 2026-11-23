import Foundation
import SwiftUI
import UIKit

/// Presents a resolved CatVod stream in the app's own full-screen player, so danmaku, subtitles,
/// PiP and gestures are identical to every other video. Mirrors `SourceBrowserPresenter.presentVideo`.
@MainActor
enum CatVodPlayerPresenter {
    static func present(url: URL, headers: [String: String], title: String) {
        guard let topVC = BookSourceFormLoginView.topViewController(),
              let scene = topVC.view.window?.windowScene else { return }
        // Never stack a second player on top of one that is already presented or
        // mid-presentation. Repeated episode taps (or a slow resolve that lands
        // late) must not pile up a dozen full-screen players.
        if topVC.presentedViewController != nil { return }
        let stream = VideoStream(url: url, headers: headers)
        final class HostBox { weak var host: UIViewController? }
        let box = HostBox()
        let host = UIHostingController(rootView:
            VideoPlayerView(content: .link(stream, title: title)) { box.host?.dismiss(animated: true) }
                .followsScenePhase(of: scene)
        )
        box.host = host
        host.coversFullScreen()
        topVC.present(host, animated: true)
    }
}
