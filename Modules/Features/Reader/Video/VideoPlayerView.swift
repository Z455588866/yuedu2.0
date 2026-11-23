import AVFoundation
import AVKit
import SwiftUI

/// The video player, laid out as Swiftfin and plezy lay theirs out (maintainer, 2026-11-01:
/// 「照开源的emby player」, 「plezy 这个也算吧」): the picture full screen, and over it a top
/// bar (close, title, actions), previous / play-pause / next in the centre (plezy), and the
/// timeline at the bottom. A tap shows and hides them; the episodes open in a sheet.
///
/// On an iPhone it opens in landscape and turns to portrait for a portrait picture, as the
/// picture reports its size (maintainer, 2026-11-01: 「依影片比例」).
struct VideoPlayerView: View {
    enum Content {
        /// A shelf book: its position is saved to the shelf.
        case shelf(UUID)
        /// A book played from its detail page without being shelved: position in memory only.
        case transient(ReadingBook)
        /// A source script's one link (`java.openVideoPlayer`).
        case link(VideoStream, title: String)
    }

    let content: Content
    let onClose: () -> Void

    @EnvironmentObject private var store: BookStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var controller: VideoPlaybackController?
    /// Display-rate playback clock shared by the danmaku and subtitle overlays. A periodic time
    /// observer publishes the player time on the main queue so overlays redraw every frame.
    @State private var clock = PlaybackClock()
    @State private var showsControls = true
    /// Bumped by every interaction; the controls hide a while after the last one.
    @State private var interaction = 0
    @State private var showsEpisodes = false
    /// Danmaku state: source, toggle, loaded track. Driven by the playing video's title.
    @State private var danmaku = DanmakuController()
    @State private var danmakuSources = DanmakuSourceStore.shared
    /// Subtitle state: toggle, active local entry or online source. Driven by the video's title.
    @State private var subtitle = SubtitleController()
    @State private var subtitleStore = SubtitleStore.shared
    @State private var onlineSubtitleSources = OnlineSubtitleSourceStore.shared
    /// The time under the finger while the timeline is dragged.
    @State private var scrubTime: Double?
    /// A drag on the picture in progress.
    @State private var pan: VideoPan?
    @State private var fillsScreen = false
    /// Manual quarter-turn correction for sideways-encoded streams (0/1/2/3).
    @State private var pictureRotation = 0
    /// The person's explicit window orientation wish; `nil` follows the picture.
    @State private var orientationOverride: FixedLayoutOrientation?
    @State private var window = ReaderWindowReference()

    var body: some View {
        ZStack {
            DSColor.videoPlayerBackground.ignoresSafeArea()
            if let controller {
                VideoPlayerLayerView(player: controller.player, fillsScreen: fillsScreen,
                                     rotation: pictureRotation,
                                     onLayer: controller.attachPictureInPicture(to:))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                gestureSurface(controller)
                // Danmaku sits above the picture and gestures but below the control chrome. It
                // never takes touches, so seek/long-press/tap gestures keep working underneath.
                if danmaku.enabled, let track = danmaku.track {
                    DanmakuOverlay(clock: clock, track: track, opacity: danmaku.opacity,
                                   area: danmaku.area, fontSize: danmaku.fontSize, speed: danmaku.speed)
                        .ignoresSafeArea()
                }
                // Subtitles sit just above the danmaku, still below the control chrome.
                if subtitle.enabled, let entry = subtitle.activeEntry {
                    SubtitleOverlay(clock: clock, entry: entry, opacity: 1,
                                    coverBuiltin: subtitle.coverBuiltin)
                        .ignoresSafeArea()
                }
                if showsControls {
                    controls(controller)
                        .transition(.opacity)
                }
                if let pan, pan.kind == .seek, let range = controller.seekableRange {
                    VideoSeekBadge(time: pan.value, end: range.upperBound, delta: pan.value - pan.origin)
                }
            } else {
                ProgressView()
                    .tint(DSColor.textOnFixedFill)
            }
        }
        .readerWindowProbe(window)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(.hidden)
        .environment(\.colorScheme, .dark)
        .animation(DSAnimation.fast, value: showsControls)
        .task {
            guard controller == nil, let controller = makeController() else { return }
            self.controller = controller
            // Don't force landscape up front: let the picture (or the person's
            // explicit choice) decide, so a vertical clip opens upright.
            controller.start()
            clock.attach(to: controller.player)
            attachDanmaku(controller)
            attachSubtitle(controller)
        }
        // Re-match when the episode changes (auto-advance, or picking from the episode sheet).
        .onChange(of: controller?.chapterIndex) { _, _ in
            guard let controller else { return }
            clock.attach(to: controller.player)
            attachDanmaku(controller)
            attachSubtitle(controller)
        }
        .onChange(of: controller?.phase) { _, phase in
            if phase == nil {
                clock.detach()
                danmaku.stop()
                subtitle.stop()
            }
        }
        // Pick up subtitles or online sources imported while the player was open.
        .onChange(of: subtitleStore.entries) { _, _ in
            subtitle.libraryDidChange()
        }
        .onChange(of: onlineSubtitleSources.sources) { _, _ in
            subtitle.libraryDidChange()
        }
        .onChange(of: controller?.pictureSize) { _, size in
            guard let size else { return }
            // A manual 横/竖 choice wins; otherwise follow the reported aspect.
            if let override = orientationOverride { turn(to: override) }
            else { turn(to: size.height > size.width ? .portrait : .landscape) }
        }
        // An inactivity timeout, not a wait for state: the controls get out of the picture's
        // way, as every video player's do. VoiceOver keeps them, as it cannot find a hidden one.
        .task(id: interaction) {
            guard showsControls, !voiceOverEnabled, controller?.phase == .playing else { return }
            try? await Task.sleep(for: DSAnimation.videoControlsAutoHide)
            guard !Task.isCancelled, scrubTime == nil, !showsEpisodes else { return }
            showsControls = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller?.saveProgress(force: true) }
        }
        // The picture's gesture surface is hidden from VoiceOver; the controls are all it can
        // reach, so they come back when it turns on over hidden ones.
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled { showsControls = true }
        }
        .onDisappear {
            clock.detach()
            controller?.close()
            if turnsWindow { ReaderOrientationController.shared.restoreDefault(in: window.windowScene) }
        }
        .sheet(isPresented: $showsEpisodes) {
            if let controller {
                VideoEpisodeSheet(
                    guide: controller.guide,
                    current: controller.chapterIndex,
                    title: controller.title(of:),
                    onSelect: { chapterIndex in
                        showsEpisodes = false
                        controller.play(chapterIndex: chapterIndex)
                    }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func makeController() -> VideoPlaybackController? {
        switch content {
        case .shelf(let id):
            store.readingBook(id: id).map { VideoPlaybackController(book: $0, store: store, persists: true) }
        case .transient(let book):
            VideoPlaybackController(book: book, store: store, persists: false)
        case .link(let stream, let title):
            VideoPlaybackController(link: stream, title: title)
        }
    }

    /// Feeds the danmaku matcher the current video's name and episode number.
    private func attachDanmaku(_ controller: VideoPlaybackController) {
        let number = DanmakuEpisodeNumber.from(controller.episodeTitle)
        danmaku.attach(title: controller.book.title, episodeNumber: number)
    }

    /// Feeds the subtitle matcher the same title and episode number (as an Int).
    private func attachSubtitle(_ controller: VideoPlaybackController) {
        let number = DanmakuEpisodeNumber.from(controller.episodeTitle).flatMap(Int.init)
        subtitle.attach(title: controller.book.title, episodeNumber: number)
    }

    /// Whether the player turns its window: an iPhone's only. An iPad's window is the size the
    /// person made it, and turning the device is theirs.
    private var turnsWindow: Bool {
        window.windowScene?.traitCollection.userInterfaceIdiom == .phone
    }

    private func turn(to orientation: FixedLayoutOrientation) {
        window.withWindow { uiWindow in
            guard let scene = uiWindow.windowScene, scene.traitCollection.userInterfaceIdiom == .phone else { return }
            ReaderOrientationController.shared.request(orientation, in: scene)
        }
    }

    private func touched() {
        interaction += 1
    }

    // MARK: Gestures

    /// Under the controls: a tap shows or hides them, a long press plays faster while held
    /// (legado-E), a swipe across seeks (FB-144), and a swipe up opens the episodes (plezy). Each
    /// has a control too: VoiceOver, which cannot reach the surface, keeps the labeled timeline.
    private func gestureSurface(_ controller: VideoPlaybackController) -> some View {
        VideoGestureSurface(
            isLocked: false,
            onTap: {
                showsControls.toggle()
                touched()
            },
            onPan: { panned($0, controller) },
            // Pinching is not wired in yet (0ac5df7a's pieces); a pinch does nothing.
            onPinch: { _ in }
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func panned(_ event: VideoGestureSurface.PanEvent, _ controller: VideoPlaybackController) {
        switch event {
        case .began(let start, let translation, let size):
            let kind = VideoPanKind(start: start, translation: translation, in: size)
            // A stream with nothing to seek in (live, or still loading) ignores a swipe across.
            guard kind != .seek || controller.seekableRange != nil else { return }
            pan = VideoPan(kind: kind, origin: controller.currentTime, value: controller.currentTime)
            touched()
        case .changed(let translation, let size):
            guard var current = pan, current.kind == .seek, let range = controller.seekableRange else { return }
            current.value = VideoPan.seekTime(origin: current.origin, translation: translation.width,
                                              width: size.width, in: range)
            pan = current
            scrubTime = current.value
        case .ended(let translation, _):
            guard let finished = pan else { return }
            pan = nil
            switch finished.kind {
            case .seek:
                controller.seek(to: finished.value)
                scrubTime = nil
            // The edges' brightness and volume are not wired in yet: an up-down drag anywhere
            // keeps opening the episodes, as it did before the seek.
            case .episodes, .brightness, .volume:
                if hasEpisodes(controller), translation.height < -DSLayout.videoSwipeThreshold {
                    showsEpisodes = true
                }
            }
            touched()
        case .cancelled:
            pan = nil
            scrubTime = nil
        }
    }

    // MARK: Controls

    private func controls(_ controller: VideoPlaybackController) -> some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: DSColor.videoControlScrim, location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.7),
                    .init(color: DSColor.videoControlScrim, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
            VStack(spacing: 0) {
                topBar(controller)
                Spacer()
                bottomBar(controller)
            }
            .padding(.horizontal, DSSpacing.lg)
            .padding(.vertical, DSSpacing.sm)
            // A swipe across puts its time badge where the transport row sits.
            if pan?.kind != .seek {
                centerControls(controller)
            }
        }
        .foregroundStyle(DSColor.textOnFixedFill)
    }

    private func topBar(_ controller: VideoPlaybackController) -> some View {
        HStack(spacing: DSSpacing.md) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(DSFont.toolbarIconLarge)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(localized("关闭"))
            VStack(alignment: .leading, spacing: DSSpacing.xxs) {
                Text(controller.book.title)
                    .font(DSFont.headline)
                    .lineLimit(1)
                Text(subtitle(controller))
                    .font(DSFont.caption)
                    .opacity(DSLayout.cardSecondaryTextOpacity)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            DanmakuControls(
                enabled: Binding(get: { danmaku.enabled }, set: { danmaku.setEnabled($0) }),
                selectedSourceID: Binding(
                    get: { danmaku.selectedSourceID },
                    set: { danmaku.selectedSourceID = $0; danmaku.reload() }
                ),
                area: Binding(get: { danmaku.area }, set: { danmaku.area = $0 }),
                fontSize: Binding(get: { danmaku.fontSize }, set: { danmaku.fontSize = $0 }),
                speed: Binding(get: { danmaku.speed }, set: { danmaku.speed = $0 }),
                sources: danmakuSources.enabledSources,
                status: danmaku.status
            )
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
                onSelect: { subtitle.resolve() },
                onRetry: { subtitle.resolve() }
            )
            speedMenu(controller)
            // The system's button names itself to VoiceOver.
            AirPlayButton()
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            Button {
                fillsScreen.toggle()
                touched()
            } label: {
                Image(systemName: fillsScreen
                      ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(DSFont.toolbarIcon)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(fillsScreen ? localized("完整画面") : localized("填满萤幕"))
            // Rotate the picture a quarter-turn: fixes sideways-encoded streams.
            Button {
                pictureRotation = (pictureRotation + 1) % 4
                touched()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(DSFont.toolbarIcon)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(localized("旋转画面"))
            // Lock the window to 横屏 or 竖屏 (or tap again to return to auto).
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
                touched()
            } label: {
                Image(systemName: orientationOverride == .portrait
                      ? "rectangle.portrait" : "rectangle.landscape")
                    .font(DSFont.toolbarIcon)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(localized("横屏/竖屏切换"))
            if hasEpisodes(controller) {
                Button {
                    showsEpisodes = true
                } label: {
                    Image(systemName: "list.bullet")
                        .font(DSFont.toolbarIcon)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                }
                .accessibilityLabel(localized("选集"))
            }
        }
    }

    /// A script's single link has no episodes to choose from.
    private func hasEpisodes(_ controller: VideoPlaybackController) -> Bool {
        controller.hasNext || controller.hasPrevious
    }

    private func subtitle(_ controller: VideoPlaybackController) -> String {
        let episode = controller.episodeTitle
        let base: String
        if let route = controller.route?.title, controller.guide.routes.count > 1 {
            base = "\(route) · \(episode)"
        } else {
            base = episode
        }
        // Surface the subtitle match right under the title so the user can tell at a glance
        // whether matching worked, without opening the subtitle menu.
        guard subtitle.enabled else { return base }
        let state: String
        if subtitle.activeEntry != nil {
            state = localized("字幕已加载")
        } else if subtitle.status.isEmpty {
            state = localized("字幕匹配中…")
        } else {
            state = subtitle.status
        }
        return "\(base) · \(state)"
    }

    private func speedMenu(_ controller: VideoPlaybackController) -> some View {
        Menu {
            Picker(localized("倍速"), selection: Binding(
                get: { controller.rate },
                set: { controller.setRate($0); touched() }
            )) {
                ForEach(VideoPlaybackController.rates, id: \.self) { rate in
                    Text(VideoPlayerFormat.rate(rate)).tag(rate)
                }
            }
        } label: {
            Text(VideoPlayerFormat.rate(controller.rate))
                .font(DSFont.subheadline.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: DSLayout.minimumTapTarget, minHeight: DSLayout.minimumTapTarget)
        }
        .accessibilityLabel(localized("倍速"))
        .accessibilityValue(VideoPlayerFormat.rate(controller.rate))
    }

    private func centerControls(_ controller: VideoPlaybackController) -> some View {
        HStack(spacing: DSSpacing.xxl) {
            Button(action: { controller.playPrevious(); touched() }) {
                Image(systemName: "backward.end.fill")
                    .font(DSFont.title2)
                    .frame(width: DSLayout.videoCenterControlSide, height: DSLayout.videoCenterControlSide)
            }
            .disabled(!controller.hasPrevious)
            .accessibilityLabel(localized("上一集"))
            playPauseButton(controller)
            Button(action: { controller.playNext(); touched() }) {
                Image(systemName: "forward.end.fill")
                    .font(DSFont.title2)
                    .frame(width: DSLayout.videoCenterControlSide, height: DSLayout.videoCenterControlSide)
            }
            .disabled(!controller.hasNext)
            .accessibilityLabel(localized("下一集"))
        }
    }

    @ViewBuilder
    private func playPauseButton(_ controller: VideoPlaybackController) -> some View {
        switch controller.phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(DSColor.textOnFixedFill)
                .frame(width: DSLayout.videoCenterControlSide, height: DSLayout.videoCenterControlSide)
        case .failed(let message):
            VStack(spacing: DSSpacing.sm) {
                Text(message)
                    .font(DSFont.subheadline)
                    .multilineTextAlignment(.center)
                Button(localized("重试")) { controller.retry() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: DSLayout.readableListWidth)
        default:
            Button(action: { controller.togglePlayPause(); touched() }) {
                Image(systemName: playSymbol(controller.phase))
                    .font(DSFont.largeTitle)
                    .frame(width: DSLayout.videoCenterControlSide, height: DSLayout.videoCenterControlSide)
            }
            .accessibilityLabel(controller.phase == .playing ? localized("暂停") : localized("播放"))
        }
    }

    private func playSymbol(_ phase: VideoPlaybackController.Phase) -> String {
        switch phase {
        case .playing: "pause.fill"
        case .ended: "arrow.counterclockwise"
        default: "play.fill"
        }
    }

    private func bottomBar(_ controller: VideoPlaybackController) -> some View {
        VideoTimelineBar(
            shown: scrubTime ?? controller.currentTime,
            end: controller.seekableRange?.upperBound ?? controller.duration,
            range: controller.seekableRange,
            onScrub: { time in
                if scrubTime == nil || time == nil { touched() }
                scrubTime = time
            },
            onSeek: { time in
                controller.seek(to: time)
                scrubTime = nil
                touched()
            },
            onSkip: { seconds in
                controller.skip(by: seconds)
                touched()
            }
        )
    }
}

// MARK: - Timeline

/// 播放进度 under the picture: the timeline and its two times.
///
/// A `ScrubSlider`, not SwiftUI's `Slider` (FB-175): on iOS 27.2 the `Slider` opened one editing
/// session on the first drag and never closed it, so `onEditingChanged(false)` never came and no
/// drag ever sought — the times showed the finger's while the picture played on.
struct VideoTimelineBar: View {
    /// The thumb's time: the finger's while it drags, the player's otherwise.
    let shown: Double
    let end: Double
    /// Where the timeline can seek; nil while nothing is seekable.
    let range: ClosedRange<Double>?
    /// The time under the finger; nil once the drag is cancelled.
    let onScrub: (Double?) -> Void
    /// The time the finger was lifted at.
    let onSeek: (Double) -> Void
    /// VoiceOver's swipe up / down: seconds to move by.
    let onSkip: (Double) -> Void

    var body: some View {
        VStack(spacing: DSSpacing.xxs) {
            ScrubSlider(
                value: shown,
                bounds: range ?? 0...max(shown, 1),
                tint: DSColor.accent,
                onScrub: onScrub,
                onCommit: onSeek,
                onIncrement: { onSkip(VideoPan.jumpSeconds) },
                onDecrement: { onSkip(-VideoPan.jumpSeconds) }
            )
            // Disabled only while nothing is seekable — a live stream with no window, or one
            // still loading. A playlist with no duration still seeks in its seekable ranges.
            .disabled(range == nil)
            .accessibilityLabel(localized("播放进度"))
            .accessibilityValue(VideoPlayerFormat.position(shown, of: end))
            HStack {
                Text(VideoPlayerFormat.time(shown))
                Spacer()
                Text(VideoPlayerFormat.time(end))
            }
            .font(DSFont.caption.monospacedDigit())
            .opacity(DSLayout.cardSecondaryTextOpacity)
            .accessibilityHidden(true)
        }
    }
}

#Preview {
    var book = ReadingBook(title: "示范短剧", author: "", contentFilename: "")
    book.isOnline = true
    book.contentPipelineKind = .video
    book.onlineChapters = [
        OnlineChapterRef(index: 0, title: "第1集", url: "https://example.com/1.m3u8"),
        OnlineChapterRef(index: 1, title: "第2集", url: "https://example.com/2.m3u8"),
    ]
    return VideoPlayerView(content: .transient(book), onClose: {})
        .environmentObject(BookStore())
}

// MARK: - Seek badge

/// Where a swipe across the picture will land: 「12:34 / 45:00」 over how far it moves.
struct VideoSeekBadge: View {
    let time: Double
    let end: Double
    let delta: Double

    var body: some View {
        VStack(spacing: DSSpacing.xxs) {
            Text("\(VideoPlayerFormat.time(time)) / \(VideoPlayerFormat.time(end))")
                .font(DSFont.title3.weight(.semibold))
            Text(VideoPlayerFormat.delta(delta))
                .font(DSFont.subheadline)
                .opacity(DSLayout.cardSecondaryTextOpacity)
        }
        .monospacedDigit()
        .foregroundStyle(DSColor.textOnFixedFill)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .background(DSColor.videoControlScrim, in: RoundedRectangle(cornerRadius: DSRadius.md))
        .allowsHitTesting(false)
        // The surface that drives it is hidden from VoiceOver, whose timeline announces itself.
        .accessibilityHidden(true)
    }
}

// MARK: - Formatting

@MainActor
enum VideoPlayerFormat {
    static func time(_ seconds: Double) -> String {
        AudiobookReaderView.formatTime(seconds)
    }

    /// How far a swipe moves: 「+1:05」, 「−0:30」.
    static func delta(_ seconds: Double) -> String {
        (seconds < 0 ? "−" : "+") + time(abs(seconds))
    }

    static func rate(_ rate: Float) -> String {
        AudiobookReaderView.rateLabel(rate)
    }

    /// The timeline's VoiceOver value: where it is, of how long.
    static func position(_ seconds: Double, of duration: Double) -> String {
        guard duration > 0 else { return time(seconds) }
        return String(format: localized("%1$@，共 %2$@"), time(seconds), time(duration))
    }
}

// MARK: - Picture

/// The picture: an `AVPlayerLayer`, so the controls over it are ours (弹幕 and the episode
/// list have no place in `AVPlayerViewController`).
struct VideoPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fillsScreen: Bool
    /// Quarter-turns to rotate the picture. 0 = as the stream reports it. A
    /// stream whose pixels are stored sideways (common with re-encoded vertical
    /// clips) renders "lying down"; the person rotates it here until upright.
    let rotation: Int
    /// Hands over the layer once, for Picture in Picture.
    var onLayer: @MainActor (AVPlayerLayer) -> Void = { _ in }

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = UIColor(DSColor.videoPlayerBackground)
        view.playerLayer.player = player
        onLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        // A quarter-turn is applied to the backing layer's transform, which
        // UIKit leaves alone (unlike frame/bounds, which it rewrites on layout).
        // Use aspect-fit while rotated so nothing is cropped; the person can
        // still tap 填满萤幕 if they prefer edge-to-edge.
        view.playerLayer.videoGravity = (fillsScreen && rotation % 2 == 0) ? .resizeAspectFill : .resizeAspect
        let angle = CGFloat(rotation) * .pi / 2
        view.playerLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
    }
}

/// The system's AirPlay route button.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor(DSColor.textOnFixedFill)
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
