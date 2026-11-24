import SwiftUI

/// 第二播放内核的开关。没有链接到 VLCKit 的构建里这里是 false，调用方据此回退，
/// 整个功能对安装包没有任何影响。
enum CatVodVLCKernel {
    static var isAvailable: Bool {
        #if canImport(VLCKitSPM)
        return true
        #else
        return false
        #endif
    }
}

#if canImport(VLCKitSPM)
import VLCKitSPM
import UIKit
// iOS 26 SDK 起 SwiftUI 不再把 Combine 转出（re-export），@Published /
// ObservableObject 的成员必须显式 import，否则报 "missing import of defining
// module 'Combine'"。
import Combine

/// VLC 内核的播放状态。系统播放器开不了的容器（MKV/AVI/FLV/WMV/RMVB）走这里。
///
/// 只做一件事：把一集放出来。弹幕、字幕、选集仍由 App 原来的界面负责，
/// 所以这里没有把它们重做一遍。
@MainActor
final class CatVodVLCPlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published private(set) var isPreparing = true
    @Published private(set) var isPlaying = false
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var failure: String?

    /// 画面容器。VLC 把像素直接画进这个 UIView，SwiftUI 只负责摆放它。
    let drawable = UIView(frame: .zero)

    private var player: VLCMediaPlayer?
    private var tickTask: Task<Void, Never>?
    private var pendingSeek: Double = 0
    /// 播完之后要能重来一遍：VLC 停在 `.ended` 时再调 `play()` 不会动，
    /// 必须换一个新的 media 对象。
    private var sourceURL: URL?
    private var sourceHeaders: [String: String] = [:]

    var isLive: Bool { duration <= 0 }

    /// 给弹幕时钟采样用。`time` 是 500ms 采一次的发布值，画弹幕太粗；
    /// 这里每次问 VLC 要最新的毫秒值，由 `PlaybackClock` 负责插值。
    var rawTime: Double {
        guard let player else { return time }
        let seconds = Double(player.time.intValue) / 1000
        return seconds.isFinite && seconds >= 0 ? seconds : time
    }

    func open(url: URL, headers: [String: String], startAt: Double) {
        guard player == nil else { return }
        failure = nil
        isPreparing = true
        pendingSeek = startAt
        sourceURL = url
        sourceHeaders = headers

        // 与系统播放器相同的取舍：少丢帧、按音频时钟走，避免网盘流忽快忽慢时画面抖。
        let player = VLCMediaPlayer(options: ["--no-drop-late-frames", "--no-skip-frames"])
        player.delegate = self
        player.drawable = drawable
        self.player = player

        player.media = makeMedia(url: url, headers: headers)
        player.play()
        startTicker()
    }

    /// 这个容器要带 Referer/Cookie/UA 才拿得到数据；字段名大小写不固定，统一小写比对。
    private func makeMedia(url: URL, headers: [String: String]) -> VLCMedia {
        let media = VLCMedia(url: url)
        // 缓存给足一点：网盘 CDN 的握手和首包经常要几秒，缓存太小会刚播就卡。
        var options: [String: Any] = [
            "network-caching": 3000,
            "live-caching": 1500,
            "file-caching": 1000,
            "http-reconnect": 1,
        ]
        var cookie: [String] = []
        for (field, value) in headers {
            switch field.lowercased() {
            case "referer", "referrer":
                options["http-referrer"] = value
            case "user-agent":
                options["http-user-agent"] = value
            case "cookie":
                cookie.append(value)
            case "origin":
                options["http-origin"] = value
            default:
                break
            }
        }
        if !cookie.isEmpty {
            options["http-cookie"] = cookie.joined(separator: "; ")
        }
        options["http-user-agent"] = options["http-user-agent"] ?? Self.safariUserAgent
        media.addOptions(options)
        return media
    }

    func togglePlayPause() {
        guard let player else { return }
        // 播完停在 `.ended`：直接 play() 不会动，得换一个 media 从头来。
        if player.state == .ended {
            replay()
            return
        }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying = player.isPlaying
    }

    private func replay() {
        guard let player, let url = sourceURL else { return }
        failure = nil
        isPreparing = true
        pendingSeek = 0
        time = 0
        // 不要先 stop()：libvlc 的 stop 是异步收尾，紧接着 setMedia 会被那次
        // 收尾一起清掉，表现就是重播一片黑。ended 状态下直接换 media 再 play
        // 才是 VLCKit 认的用法。
        player.media = makeMedia(url: url, headers: sourceHeaders)
        player.play()
    }

    func seek(to seconds: Double) {
        guard let player, !isLive else { return }
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.time = VLCTime(int: Int32(target * 1000))
        time = target
    }

    func setRate(_ value: Float) {
        rate = value
        player?.rate = value
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        player?.stop()
        player?.drawable = nil
        player = nil
    }

    private func startTicker() {
        tickTask?.cancel()
        // 用定时采样而不是跟着 VLC 的高频回调刷新，主线程不会被它拖住。
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                self.sample()
            }
        }
    }

    private func sample() {
        guard let player else { return }
        let current = Double(player.time.intValue) / 1000
        if current.isFinite, current >= 0 { time = current }
        let length = Double(player.media?.length.intValue ?? 0) / 1000
        if length.isFinite, length > 0 { duration = length }
        if pendingSeek > 0, current > 0.5 {
            let target = pendingSeek
            pendingSeek = 0
            seek(to: target)
        }
        isPlaying = player.isPlaying
    }

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in self?.stateChanged() }
    }

    private func stateChanged() {
        guard let player else { return }
        switch player.state {
        case .opening, .buffering:
            isPreparing = true
        case .playing:
            isPreparing = false
            isPlaying = true
        case .paused:
            isPreparing = false
            isPlaying = false
        case .ended:
            isPreparing = false
            isPlaying = false
        case .error:
            isPreparing = false
            isPlaying = false
            failure = "这个格式用 VLC 也打不开，换一条线路试试"
        case .stopped:
            isPreparing = false
            isPlaying = false
        default:
            break
        }
    }

    static let safariUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}

/// 全屏的 VLC 播放页。外观与 App 自己的播放器一致：黑底、顶部标题、底部控制条。
@MainActor
struct CatVodVLCVideoView: View {
    let url: URL
    let headers: [String: String]
    let title: String
    var startAt: Double = 0
    /// 片源自带弹幕的加载器。VLC 内核只负责解码画面，弹幕是 SwiftUI 层叠上去的。
    /// 异步的原因：拉弹幕要几秒，不能挡在播放前面。
    var danmaku: (@MainActor () async -> [DanmakuItem]?)? = nil
    let onClose: () -> Void

    @StateObject private var model = CatVodVLCPlayerModel()
    @State private var clock = PlaybackClock()
    @State private var danmakuController = DanmakuController()
    @State private var showsControls = true
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoSurface(view: model.drawable)
                .ignoresSafeArea()
            // 弹幕压在画面上、控制条下面，且不接管触摸——否则点不到进度条。
            if danmakuController.enabled, let track = danmakuController.track {
                DanmakuOverlay(clock: clock, track: track,
                               opacity: danmakuController.opacity,
                               area: danmakuController.area,
                               fontSize: danmakuController.fontSize,
                               speed: danmakuController.speed)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
            if model.isPreparing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
            if let failure = model.failure {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34, weight: .light))
                    Text(failure)
                        .font(.system(size: 15))
                        .multilineTextAlignment(.center)
                    Button("返回") { onClose() }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(28)
            }
            if showsControls {
                controls
            } else {
                // 控制条收起后，点画面任何地方把它叫回来。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showsControls = true
                        scheduleHide()
                    }
            }
        }
        .statusBarHidden()
        .task {
            model.open(url: url, headers: headers, startAt: startAt)
            clock.attach { [model] in (model.rawTime, model.isPlaying) }
            if let danmaku {
                // 画面先起来，弹幕到了再叠——红果取整集弹幕要十几秒。
                Task {
                    if let items = await danmaku(), !items.isEmpty {
                        danmakuController.adopt(items, title: title,
                                                sourceName: localized("片源自带"))
                    }
                }
            }
            scheduleHide()
        }
        .onDisappear {
            clock.detach()
            model.stop()
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 12) {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text("VLC")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 10) {
                if !model.isLive {
                    HStack(spacing: 10) {
                        Text(clock(scrubbing ?? model.time))
                            .monospacedDigit()
                        Slider(
                            value: Binding(
                                get: { scrubbing ?? model.time },
                                set: { scrubbing = $0 }
                            ),
                            in: 0...max(model.duration, 0.1),
                            onEditingChanged: { editing in
                                if !editing, let value = scrubbing {
                                    model.seek(to: value)
                                    scrubbing = nil
                                }
                            }
                        )
                        .tint(.white)
                        Text(clock(model.duration))
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                }
                HStack(spacing: 30) {
                    Button { model.togglePlayPause() } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                    }
                    Menu {
                        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { value in
                            Button(String(format: "%g×", value)) { model.setRate(Float(value)) }
                        }
                    } label: {
                        Text(String(format: "%g×", model.rate))
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 22)
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .contentShape(Rectangle())
        .onTapGesture {
            showsControls = false
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if model.isPlaying { showsControls = false }
        }
    }

    private func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

private struct VLCVideoSurface: UIViewRepresentable {
    let view: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
