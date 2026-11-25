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
    /// 片源自带弹幕的加载器（猫源 `playerContent.danmaku`）。有就优先用它，
    /// 没有才按标题去弹幕站搜——两者不能同时跑，否则同一条弹幕会叠两遍。
    ///
    /// 做成异步闭包而不是现成的数组：拉弹幕要几秒到十几秒，不能在播放前等。
    private let sourceDanmaku: (@MainActor () async -> [DanmakuItem]?)?

    init(content: Content,
         danmaku: (@MainActor () async -> [DanmakuItem]?)? = nil,
         onClose: @escaping () -> Void) {
        self.content = content
        self.sourceDanmaku = danmaku
        self.onClose = onClose
    }

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
    /// 片源弹幕的加载任务：同一集只拉一次，切集要能取消。
    @State private var danmakuLoadTask: Task<Void, Never>?
    @State private var danmakuSources = DanmakuSourceStore.shared
    /// Subtitle state: toggle, active local entry or online source. Driven by the video's title.
    @State private var subtitle = SubtitleController()
    @State private var subtitleStore = SubtitleStore.shared
    @State private var onlineSubtitleSources = OnlineSubtitleSourceStore.shared
    /// The time under the finger while the timeline is dragged.
    @State private var scrubTime: Double?
    /// A drag on the picture in progress.
    @State private var pan: VideoPan?
    /// 屏幕亮度/系统音量（左边缘上滑调亮度、右边缘上滑调音量）。
    /// 系统音量无公开 API，借 MPVolumeView 的 slider 设置，须常驻在视图树里。
    @State private var systemControls = VideoSystemControls()
    /// 锁定后手势层只剩点击（唤出/隐藏解锁按钮），拖动/双指都禁用。
    @State private var isLocked = false
    /// 画面摆放方式：适应 / 铺满（裁剪）/ 拉伸 / 原始尺寸，四档与 ijkplayer 一致。
    @State private var scalingMode: VideoScalingMode = .fit
    /// Manual quarter-turn correction for sideways-encoded streams (0/1/2/3).
    @State private var pictureRotation = 0
    /// The person's explicit window orientation wish; `nil` follows the picture.
    @State private var orientationOverride: FixedLayoutOrientation?
    @State private var window = ReaderWindowReference()
    /// Overlay settings panels live here, not inside their buttons. The buttons are part
    /// of the chrome, and the chrome is removed from the tree when it auto-hides — a panel
    /// owned by that subtree closed itself a few seconds after opening.
    @State private var showsDanmakuPanel = false
    @State private var showsSubtitlePanel = false

    var body: some View {
        ZStack {
            DSColor.videoPlayerBackground.ignoresSafeArea()
            if let controller {
                VideoPlayerLayerView(player: controller.player, scalingMode: scalingMode,
                                     rotation: pictureRotation,
                                     onLayer: controller.attachPictureInPicture(to:))
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                gestureSurface(controller)
                // Danmaku sits above the picture and gestures but below the control chrome. It
                // never takes touches, so seek/long-press/tap gestures keep working underneath.
                //
                // The layer is constrained to the picture rectangle instead of the whole
                // window: on a 16:9 clip in a portrait window the window includes two large
                // black bars, and comments laid out over them read as a wall of text floating
                // outside the video.
                // 弹幕和字幕都放进「画面矩形」，而不是各自铺满整窗：画面怎么缩放、裁剪，
                // 它们就跟着怎么动。这是成熟引擎的通行做法——字节 DanmakuRenderEngine 要求
                // 弹幕视图尺寸与视频画面尺寸一致，CommentCoreLibrary 则是拉伸弹幕容器、
                // 让字号随之等比放大（"弹幕大了自然速度就慢了，没必要继续降低速度"）。
                GeometryReader { geo in
                    let rect = pictureRect(in: geo.size)
                    ZStack {
                        if danmaku.enabled, let track = danmaku.track {
                            // 弹幕字号交给引擎按「画面矩形」短边自适应（含 15pt 下限），
                            // 不再在此乘画面缩放——Canvas 的尺寸已经是缩放后的画面矩形，
                            // 再乘一次会双重缩放。传入的是用户在设置里选的字号点数。
                            DanmakuOverlay(clock: clock, track: track, opacity: danmaku.opacity,
                                           area: danmaku.area,
                                           fontSize: danmaku.fontSize,
                                           speed: danmaku.speed)
                        }
                        // SubtitleOverlay 自己按内容定高、底部对齐，从不读 bounds（那样会锁住
                        // PiP 恢复时的过期尺寸），所以放进这个容器只会跟着画面移动，不会变形。
                        if subtitle.enabled, let entry = subtitle.activeEntry {
                            SubtitleOverlay(clock: clock, entry: entry, opacity: 1,
                                            coverBuiltin: subtitle.coverBuiltin)
                        }
                    }
                    .frame(width: max(1, rect.width), height: max(1, rect.height))
                    .position(x: rect.midX, y: rect.midY)
                }
                .ignoresSafeArea()
                // Kept in the tree and faded out instead of being removed: the overlay
                // settings panels are presented from these buttons, and tearing the
                // subtree down would dismiss a panel that is still being used.
                controls(controller)
                    .opacity(showsControls ? 1 : 0)
                    .allowsHitTesting(showsControls)
                    .accessibilityHidden(!showsControls)
                if let pan, pan.kind == .seek, let range = controller.seekableRange {
                    VideoSeekBadge(time: pan.value, end: range.upperBound, delta: pan.value - pan.origin)
                }
                // 亮度/音量调节浮层，照 tvbox 的 indicator（图标 + 百分比）。
                if let pan, pan.kind == .brightness {
                    VideoAdjustBadge(kind: .brightness, value: pan.value)
                }
                if let pan, pan.kind == .volume {
                    VideoAdjustBadge(kind: .volume, value: pan.value)
                }
                // 锁屏后控制条淡出，中央只留一个解锁按钮（点画面先叫出控制条也可以）。
                if isLocked {
                    Button {
                        isLocked = false
                        showsControls = true
                        touched()
                    } label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(16)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .accessibilityLabel(localized("解锁屏幕"))
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
        .background {
            // 亮度/音量手势依赖它常驻：MPVolumeView 必须在视图树里，其 slider 才能改系统音量。
            VideoVolumeHost(controls: systemControls).frame(width: 1, height: 1)
        }
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
                danmakuLoadTask?.cancel()
                danmakuLoadTask = nil
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
            // An open settings panel keeps the chrome alive: hiding it would tear the
            // panel down mid-adjustment.
            guard !Task.isCancelled, scrubTime == nil, !showsEpisodes,
                  !showsDanmakuPanel, !showsSubtitlePanel else { return }
            showsControls = false
        }
        // Closing a panel counts as activity, so the chrome gets a fresh idle window
        // instead of vanishing the instant the sheet goes away.
        .onChange(of: showsDanmakuPanel) { _, open in if !open { touched() } }
        .onChange(of: showsSubtitlePanel) { _, open in if !open { touched() } }
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
            // 退出播放器把用户调过的屏幕亮度还原，别让阅读页也跟着变暗。
            systemControls.restoreBrightness()
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
        // 片源自带弹幕优先：猫源的标题常常搜不到条目，走在线匹配只会显示「没匹配到」。
        if let sourceDanmaku {
            guard danmakuLoadTask == nil else { return }
            danmakuLoadTask = Task { [weak controller] in
                let items = await sourceDanmaku()
                guard !Task.isCancelled else { return }
                if let items, !items.isEmpty {
                    let title = controller?.book.title ?? ""
                    danmaku.adopt(items, title: title, sourceName: localized("片源自带"))
                } else if let controller {
                    // 源那边没取到（接口挂了 / 这集没弹幕），退回按标题搜，
                    // 至少不会因为「片源没给」就一条都没有。
                    let number = DanmakuEpisodeNumber.from(controller.episodeTitle)
                    danmaku.attach(title: controller.book.title, episodeNumber: number)
                }
            }
            return
        }
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

    /// 片源尺寸，按当前的画面旋转把宽高换过来。
    private var rotatedPictureSize: CGSize {
        guard let picture = controller?.pictureSize, picture.width > 0, picture.height > 0 else {
            return .zero
        }
        return pictureRotation % 2 == 1
            ? CGSize(width: picture.height, height: picture.width)
            : picture
    }

    /// 画面被转了 90°/270° 时一律按「适应」算：转过来的画面若用铺满，会裁掉大半。
    /// 与 `VideoPlayerLayerView` 里对 `videoGravity` 的判断保持一致，否则弹幕会和画面对不上。
    private var effectiveScalingMode: VideoScalingMode {
        pictureRotation % 2 == 1 ? .fit : scalingMode
    }

    /// The rectangle the picture actually occupies inside the player, in the coordinate
    /// space of a full-window `GeometryReader`. Falls back to the whole window until the
    /// stream has reported its size, so the first frames do not blank the danmaku layer.
    private func pictureRect(in size: CGSize) -> CGRect {
        let native = rotatedPictureSize
        guard native.width > 0, native.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        return effectiveScalingMode.pictureRect(native: native, in: size)
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
            isLocked: isLocked,
            onTap: {
                // 锁屏时点击只把控制条叫回来（里面有解锁按钮）；拖动/双指已被
                // VideoGestureSurface 禁用，避免误触改进度或亮度。
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
            // 起点按手势类型取当前值：横向从播放进度、左边缘从亮度、右边缘从系统音量。
            let origin: Double = {
                switch kind {
                case .seek: return controller.currentTime
                case .brightness: return systemControls.brightness
                case .volume: return systemControls.volume
                case .episodes: return 0
                }
            }()
            pan = VideoPan(kind: kind, origin: origin, value: origin)
            touched()
        case .changed(let translation, let size):
            guard var current = pan else { return }
            switch current.kind {
            case .seek:
                guard let range = controller.seekableRange else { return }
                current.value = VideoPan.seekTime(origin: current.origin, translation: translation.width,
                                                  width: size.width, in: range)
                pan = current
                scrubTime = current.value
            case .brightness:
                current.value = VideoPan.level(origin: current.origin, translation: translation.height,
                                               height: size.height)
                pan = current
                systemControls.setBrightness(current.value)
            case .volume:
                current.value = VideoPan.level(origin: current.origin, translation: translation.height,
                                               height: size.height)
                pan = current
                systemControls.setVolume(current.value)
            case .episodes:
                break
            }
        case .ended(let translation, _):
            guard let finished = pan else { return }
            pan = nil
            switch finished.kind {
            case .seek:
                controller.seek(to: finished.value)
                scrubTime = nil
            case .brightness, .volume:
                // 值已在 .changed 逐帧写入系统，松手无需再做动作。
                break
            case .episodes:
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
                showsPanel: $showsDanmakuPanel,
                sources: danmakuSources.enabledSources,
                status: danmaku.status,
                videoTitle: controller.book.title,
                onManualPick: { source, episode, animeTitle in
                    danmaku.loadManual(source: source, episode: episode, animeTitle: animeTitle)
                }
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
                showsPanel: $showsSubtitlePanel,
                onSelect: { subtitle.resolve() },
                onRetry: { subtitle.resolve() }
            )
            speedMenu(controller)
            // The system's button names itself to VoiceOver.
            AirPlayButton()
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            // 画面摆放：适应 / 铺满（裁剪）/ 拉伸 / 原始尺寸。
            // 四档定义照搬 Bilibili ijkplayer 的 IJKMPMovieScalingMode，不用自己发明。
            Menu {
                Picker(localized("画面"), selection: Binding(
                    get: { scalingMode },
                    set: { scalingMode = $0; touched() }
                )) {
                    ForEach(VideoScalingMode.allCases) { mode in
                        Label(localized(mode.labelKey), systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: scalingMode.systemImage)
                    .font(DSFont.toolbarIcon)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(String(format: localized("画面缩放：%1$@"), localized(scalingMode.labelKey)))
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
            // 锁定播放器：锁住后画面手势不再响应拖动/亮度/音量，只留点击唤出解锁按钮，
            // 防止握持时误触。与 B站/腾讯视频的「锁屏」同一个功能。
            Button {
                isLocked.toggle()
                // 锁上就立刻收起控制条，只留中央解锁按钮。
                if isLocked { showsControls = false }
                touched()
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .font(DSFont.toolbarIcon)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(isLocked ? localized("解锁屏幕") : localized("锁定屏幕"))
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

/// 亮度/音量调节时的居中提示，照 tvbox-Swift 的 PlayerGestureLayer indicator：
/// 上半图标（太阳/喇叭）、下半百分比，毛玻璃圆角底。与 VideoSeekBadge 一样不接管触摸。
struct VideoAdjustBadge: View {
    enum Kind { case brightness, volume }
    let kind: Kind
    let value: Double  // 0...1

    var body: some View {
        VStack(spacing: DSSpacing.xxs) {
            Image(systemName: kind == .brightness ? "sun.max.fill" : "speaker.wave.2.fill")
                .font(.title2)
                .foregroundStyle(kind == .brightness ? .yellow : DSColor.textOnFixedFill)
            Text("\(Int((value * 100).rounded()))%")
                .font(DSFont.subheadline)
                .monospacedDigit()
        }
        .foregroundStyle(DSColor.textOnFixedFill)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DSRadius.md))
        .allowsHitTesting(false)
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
    let scalingMode: VideoScalingMode
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
        // still pick 铺满（裁剪） if they prefer edge-to-edge.
        let mode: VideoScalingMode = rotation % 2 == 0 ? scalingMode : .fit
        view.playerLayer.videoGravity = mode.videoGravity
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
