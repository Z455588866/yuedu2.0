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
    @State private var danmakuSources = DanmakuSourceStore.shared
    /// 字幕层与系统播放器共用同一套控制器/覆盖层/导入库。VLC 只负责解码画面，
    /// 外挂字幕（本地 .srt/.vtt 或在线字幕源）仍由 SwiftUI 叠在画面上。
    @State private var subtitle = SubtitleController()
    @State private var subtitleStore = SubtitleStore.shared
    @State private var onlineSubtitleSources = OnlineSubtitleSourceStore.shared
    @State private var showsControls = true
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?
    /// 本播放器所在窗口。横竖屏请求必须发给它的 scene（iPad 多窗口/外接屏时不是 keyWindow）。
    @State private var window = ReaderWindowReference()
    /// 用户显式的横/竖选择；nil 表示跟随设备方向。
    @State private var orientationOverride: FixedLayoutOrientation?
    /// 面板由播放器持有而不是按钮：控制条会在空闲后自动隐藏，
    /// 面板若挂在按钮上，会在用户还在调整时被一起从视图树里摘掉。
    @State private var showsDanmakuPanel = false
    @State private var showsSubtitlePanel = false

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
            // 外挂字幕压在弹幕之上、控制条之下；时钟与系统播放器共用，
            // 因此 VLC 解码的画面里拖动进度后字幕照样逐句跟随。
            if subtitle.enabled, let entry = subtitle.activeEntry {
                SubtitleOverlay(clock: clock, entry: entry, opacity: 1,
                                coverBuiltin: subtitle.coverBuiltin)
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
            // 控制条常驻视图树，只切透明度/命中：弹幕、字幕设置面板挂在它的按钮上，
            // 若用 if 摘掉子树，面板会在用户还在调整时被一起关闭。
            controls
                .opacity(showsControls ? 1 : 0)
                .allowsHitTesting(showsControls)
                .accessibilityHidden(!showsControls)
            if !showsControls {
                // 控制条收起后，点画面任何地方把它叫回来。
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showsControls = true
                        scheduleHide()
                    }
            }
        }
        .readerWindowProbe(window)
        .statusBarHidden(!showsControls)
        .task {
            model.open(url: url, headers: headers, startAt: startAt)
            clock.attach { [model] in (model.rawTime, model.isPlaying) }
            if let danmaku {
                // 画面先起来，弹幕到了再叠——红果取整集弹幕要十几秒。
                Task {
                    if let items = await danmaku(), !items.isEmpty {
                        danmakuController.adopt(items, title: title,
                                                sourceName: localized("片源自带"))
                    } else {
                        // 片源没给弹幕（接口挂了/这集没有）时退回按标题在线匹配，
                        // 与系统播放器行为一致，而不是让 VLC 内核一条弹幕都没有。
                        danmakuController.attach(title: title, episodeNumber: nil)
                    }
                }
            } else {
                danmakuController.attach(title: title, episodeNumber: nil)
            }
            // 字幕按片名匹配本地/在线字幕源——这块与用哪个解码内核无关。
            subtitle.attach(title: title, episodeNumber: nil)
            scheduleHide()
        }
        .onDisappear {
            clock.detach()
            model.stop()
            danmakuController.stop()
            subtitle.stop()
            if turnsWindow { ReaderOrientationController.shared.restoreDefault(in: window.windowScene) }
        }
    }

    /// 是否由本播放器接管窗口方向：仅 iPhone。iPad 的窗口尺寸由用户决定，转设备是用户的事。
    private var turnsWindow: Bool {
        window.windowScene?.traitCollection.userInterfaceIdiom == .phone
    }

    /// 请求窗口转到指定方向；与系统播放器走同一个控制器，行为一致。
    private func turn(to orientation: FixedLayoutOrientation) {
        window.withWindow { uiWindow in
            guard let scene = uiWindow.windowScene,
                  scene.traitCollection.userInterfaceIdiom == .phone else { return }
            ReaderOrientationController.shared.request(orientation, in: scene)
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
                // 弹幕设置：与系统播放器同一控件，可开关、选源、手动搜剧。
                DanmakuControls(
                    enabled: Binding(get: { danmakuController.enabled },
                                     set: { danmakuController.setEnabled($0) }),
                    selectedSourceID: Binding(
                        get: { danmakuController.selectedSourceID },
                        set: { danmakuController.selectedSourceID = $0; danmakuController.reload() }
                    ),
                    area: Binding(get: { danmakuController.area }, set: { danmakuController.area = $0 }),
                    fontSize: Binding(get: { danmakuController.fontSize }, set: { danmakuController.fontSize = $0 }),
                    speed: Binding(get: { danmakuController.speed }, set: { danmakuController.speed = $0 }),
                    showsPanel: $showsDanmakuPanel,
                    sources: danmakuSources.enabledSources,
                    status: danmakuController.status,
                    videoTitle: title,
                    onManualPick: { source, episode, animeTitle in
                        danmakuController.loadManual(source: source, episode: episode, animeTitle: animeTitle)
                    }
                )
                // 字幕设置：VLC 内核同样支持外挂字幕（本地/在线），不再缺字幕能力。
                SubtitleControls(
                    enabled: Binding(get: { subtitle.enabled }, set: { subtitle.setEnabled($0) }),
                    selectedEntryID: Binding(
                        get: { subtitle.selectedEntryID },
                        set: { subtitle.selectedEntryID = $0 }
                    ),
                    entries: subtitleStore.enabledEntries,
                    sources: onlineSubtitleSources.enabledSources,
                    status: subtitle.status,
                    matched: subtitle.activeEntry != nil,
                    coverBuiltin: Binding(
                        get: { subtitle.coverBuiltin },
                        set: { subtitle.coverBuiltin = $0 }
                    ),
                    showsPanel: $showsSubtitlePanel,
                    onSelect: { subtitle.resolve() },
                    onRetry: { subtitle.resolve() }
                )
                // 横/竖屏切换：用户反馈的痛点——VLC 内核此前竖屏无法转横屏。
                Button {
                    let next: FixedLayoutOrientation = {
                        switch orientationOverride {
                        case .landscape: return .portrait
                        case .portrait: return .auto
                        default: return .landscape
                        }
                    }()
                    orientationOverride = (next == .auto) ? nil : next
                    if let override = orientationOverride { turn(to: override) }
                    else { turn(to: .auto) }
                } label: {
                    Image(systemName: orientationOverride == .portrait
                          ? "rectangle.portrait" : "rectangle.landscape")
                        .font(.system(size: 16))
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel(localized("横屏/竖屏切换"))
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
            // 面板打开时不收控制条——否则正在调整的弹幕/字幕面板会被一起摘掉。
            guard !showsDanmakuPanel, !showsSubtitlePanel else { return }
            showsControls = false
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            // 面板开着、正在拖动进度或没在播放时都保持控制条可见。
            if model.isPlaying, !showsDanmakuPanel, !showsSubtitlePanel, scrubbing == nil {
                showsControls = false
            }
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
