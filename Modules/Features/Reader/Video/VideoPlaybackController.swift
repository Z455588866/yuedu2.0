import AVFoundation
import AVKit
import MediaPlayer
import Observation
import UIKit

/// One video book's playback: which episode plays, where it is, and what comes next.
///
/// The position lives in the audiobook fields (`audioChapterIndex`, `audioTimeSeconds`) — one
/// position scheme for both timed kinds. A book that is not on the shelf keeps it in memory
/// only, as the audiobook player's transient books do. A source script's single link
/// (`java.openVideoPlayer`) plays as a video of one episode, its position kept per link.
@MainActor
@Observable
final class VideoPlaybackController {
    enum Phase: Equatable {
        case loading
        case playing
        case paused
        /// The last episode of the last 线路 has finished.
        case ended
        case failed(String)
    }

    /// Speeds the speed menu offers (legado-E / MD3: 0.5–3.0).
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    let player = AVPlayer()
    let guide: VideoEpisodeGuide
    private(set) var book: ReadingBook
    private(set) var chapterIndex: Int
    private(set) var phase: Phase = .loading
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    /// The span the timeline and a swipe across the picture can seek in; `nil` while the stream
    /// has no seekable span (still loading, or live with no window to go back in).
    private(set) var seekableRange: ClosedRange<Double>?
    /// The speed the player keeps, chosen from the speed menu.
    private(set) var rate: Float = 1
    /// The picture's size once the stream reports it; the player turns to match it.
    private(set) var pictureSize: CGSize?
    /// 插件/网关随播放结果给出的线路元信息；不参与播放决策，只用于信息面板。
    private(set) var streamInfo: VideoStreamInfo?
    /// AVPlayer accessLog 的当前视频码率；未知时为 nil。
    private(set) var measuredVideoBitrate: Int?

    /// 内核兜底：系统内核播起来却解不出视频轨（有声音没画面）时，让上层把这一集
    /// 原样交给 VLC 软解重播。上层只在猫源链路设置它，书源视频会是 nil，行为不变。
    /// 传回当前流的副本和进度秒数，VLC 侧据此从同一位置接着播。
    var onNoVideoTrack: (@MainActor (VideoStream, Double) -> Void)?
    private var didRequestKernelFallback = false

    private enum Source {
        /// A book's episodes, resolved through the chapter cache; `persists` for a shelf book.
        case book(BookStore, persists: Bool)
        /// A script's link, played as it is.
        case link(VideoStream)
    }

    private let source: Source
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var timelineObservations: [NSKeyValueObservation] = []
    /// Where the episode being loaded opens, applied once it is ready to play.
    private var pendingSeek: Double = 0
    /// The episode whose link was already resolved again after failing to play: legado
    /// refreshes a failed link once (`retryOnPlayError`), then reports the failure.
    private var refetchedChapter: Int?
    /// 本次失败是否属于「链接无访问权限」（403 / contentIsNotAuthorized）。这类失败
    /// 用同一个死链重试没有意义——尤其是猫源/书源的 .link 源无法重新解析——只能退出
    /// 换一条线路。视图据此把「重试」换成「返回换线路」。
    private(set) var failedNeedsRelink = false
    private var lastSavedTime: Double = 0
    /// 断流自动重开：网络抖动导致这一集被 AVPlayer 结束，就等几秒在原位置重来。
    private var dropRecovery = VideoDropRecovery()
    private var recoveryTask: Task<Void, Never>?
    private var nowPlayingSession: MPNowPlayingSession?
    /// Not state the screen shows; set while the picture's layer is made.
    @ObservationIgnored private var pictureInPicture: AVPictureInPictureController?
    private let pictureInPictureDelegate = VideoPictureInPictureDelegate()

    /// `book` must carry its table of contents (`BookStore.readingBook(id:)`).
    init(book: ReadingBook, store: BookStore, persists: Bool) {
        self.book = book
        self.source = .book(store, persists: persists)
        self.guide = VideoEpisodeGuide(chapters: book.onlineChapters ?? [])
        self.chapterIndex = guide.resumeEpisode(saved: book.audioChapterIndex) ?? 0
        player.automaticallyWaitsToMinimizeStalling = true
    }

    /// A script's link, opening where it was left (`VideoLinkPositions`).
    init(link: VideoStream, title: String) {
        var book = ReadingBook(title: title, author: "", contentFilename: "")
        book.onlineChapters = [OnlineChapterRef(index: 0, title: title, url: link.url.absoluteString)]
        book.audioChapterIndex = 0
        book.audioTimeSeconds = VideoLinkPositions.time(for: link.url) ?? 0
        self.book = book
        self.source = .link(link)
        self.streamInfo = link.info
        self.guide = VideoEpisodeGuide(chapters: book.onlineChapters ?? [])
        self.chapterIndex = 0
        player.automaticallyWaitsToMinimizeStalling = true
    }

    var route: VideoEpisodeGuide.Route? { guide.route(containing: chapterIndex) }
    var hasNext: Bool { guide.episode(after: chapterIndex) != nil }
    var hasPrevious: Bool { guide.episode(before: chapterIndex) != nil }

    /// The episode's title as the source names it.
    var episodeTitle: String { title(of: chapterIndex) }

    func title(of chapterIndex: Int) -> String {
        guard let chapters = book.onlineChapters, chapters.indices.contains(chapterIndex) else { return "" }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: chapters[chapterIndex].title)
    }

    // MARK: Lifecycle

    /// Opens the saved episode at its saved time.
    func start() {
        guard !guide.isEmpty else {
            phase = .failed(localized("这部影片没有可播放的集数"))
            return
        }
        AudioSessionActivator.activate(category: .playback, mode: .moviePlayback)
        NowPlayingHub.shared.yieldToVideo()
        observePlayer()
        let resumesSaved = chapterIndex == book.audioChapterIndex
        play(chapterIndex: chapterIndex, at: resumesSaved ? book.audioTimeSeconds : 0)
    }

    /// Saves where it is and lets the player go.
    func close() {
        saveProgress(force: true)
        loadTask?.cancel()
        recoveryTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        statusObservation = nil
        sizeObservation = nil
        timelineObservations = []
        nowPlayingSession = nil
        pictureInPicture = nil
    }

    /// Lets the picture go on in Picture in Picture when the app leaves the foreground while it
    /// plays. Only then: the player lives as long as its screen, so a window started from a
    /// button would end with the screen it floats over.
    func attachPictureInPicture(to layer: AVPlayerLayer) {
        guard pictureInPicture == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            AppLogger.info("[Video] Picture in Picture unavailable for this layer", level: .notice)
            return
        }
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = pictureInPictureDelegate
        pictureInPicture = controller
    }

    // MARK: Episodes

    func play(chapterIndex: Int, at time: Double = 0) {
        guard guide.route(containing: chapterIndex) != nil else { return }
        let switchingEpisode = chapterIndex != self.chapterIndex
        if switchingEpisode { saveProgress(force: true) }
        // 换集是人主动做的，断流计数不该带到下一集。
        recoveryTask?.cancel()
        dropRecovery.reset()
        self.chapterIndex = chapterIndex
        if refetchedChapter != chapterIndex { refetchedChapter = nil }
        if switchingEpisode {
            // The save above wrote the outgoing episode's tail. Commit the incoming
            // episode's opening position immediately: the five-second throttle would
            // otherwise leave the old 集=片尾 position on disk until the new one has
            // played that long, so quitting early reopened at the wrong place.
            currentTime = time
            saveProgress(force: true, chapterProgress: 0)
        }
        load(at: time)
    }

    func playNext() {
        if let next = guide.episode(after: chapterIndex) { play(chapterIndex: next) }
    }

    func playPrevious() {
        if let previous = guide.episode(before: chapterIndex) { play(chapterIndex: previous) }
    }

    private func load(at time: Double) {
        loadTask?.cancel()
        didRequestKernelFallback = false
        failedNeedsRelink = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        sizeObservation = nil
        timelineObservations = []
        pictureSize = nil
        measuredVideoBitrate = nil
        phase = .loading
        currentTime = time
        duration = 0
        seekableRange = nil
        pendingSeek = time
        lastSavedTime = time
        let store: BookStore
        switch source {
        case .link(let stream):
            begin(stream)
            return
        case .book(let bookStore, _):
            store = bookStore
        }
        let book = book
        let chapterIndex = chapterIndex
        loadTask = Task { [weak self] in
            do {
                let stream = try await VideoChapterLinks.stream(
                    for: book, chapterIndex: chapterIndex, priority: .immediate, store: store
                )
                try Task.checkCancellation()
                self?.begin(stream)
            } catch is CancellationError {
                return
            } catch VideoChapterLinkError.notALink(let preview) {
                guard let self else { return }
                // A chapter cached before the book was known as a video — read in the text
                // reader, whose fetch shows a source's note and lets its script open a player
                // or a page — holds that note, not the episode. It is fetched again once, as
                // the episode being played, the same single retry a link that fails to play
                // gets. Delete with that retry once no copy can hold a chapter cached by a
                // build before 2026-11-01's handover (`LegadoJSBridge.videoEpisodeHandover`).
                if self.refetchedChapter != chapterIndex {
                    self.refetchedChapter = chapterIndex
                    AppLogger.info("[Video] cached episode is not a link; fetching it again", level: .notice)
                    VideoChapterLinks.discardResolvedLink(for: book, chapterIndex: chapterIndex, store: store)
                    self.load(at: time)
                } else {
                    AppLogger.info("[Video] episode is not a link: \(preview)", level: .error)
                    self.phase = .failed(VideoChapterLinkError.notALink(preview: preview).localizedDescription)
                }
            } catch {
                AppLogger.error("[Video] episode link failed", error: error,
                                context: ["book": book.id.uuidString, "chapter": "\(chapterIndex)"])
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func begin(_ stream: VideoStream) {
        let item = AVPlayerItem(asset: HeaderedMediaAsset.make(url: stream.url, headers: stream.headers))
        item.externalMetadata = nowPlayingMetadata()
        let identity = ObjectIdentifier(item)
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, error: message, of: identity) }
        }
        sizeObservation = item.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 0, size.height > 0 else { return }
            Task { @MainActor in
                guard self?.player.currentItem.map(ObjectIdentifier.init) == identity else { return }
                self?.pictureSize = size
            }
        }
        // Both change after `readyToPlay`: an HLS playlist without `#EXT-X-ENDLIST` plays as
        // live, its duration indefinite while its seekable span grows with every reload.
        let timelineChanged: @Sendable (AVPlayerItem) -> Void = { [weak self] item in
            let timeline = VideoTimeline(duration: item.duration.seconds,
                                         seekable: item.seekableTimeRanges.map(\.timeRangeValue))
            Task { @MainActor in self?.timelineChanged(timeline, of: identity) }
        }
        timelineObservations = [
            item.observe(\.duration, options: [.new]) { item, _ in timelineChanged(item) },
            item.observe(\.seekableTimeRanges, options: [.new]) { item, _ in timelineChanged(item) },
        ]
        player.replaceCurrentItem(with: item)
    }

    /// 系统内核的固有盲区：`CatVodPlaybackRoute.decide` 只看容器和扩展名，看不到容器里
    /// 视频轨的编码。HLS/MP4 这些 AVPlayer 强项容器里也可能装着它解不出的视频轨
    /// （HEVC 10bit / AV1 等），这时 `status` 照样是 readyToPlay、音频正常播，只有画面
    /// 全黑，也不会进 `.failed` 分支——正是用户看到的「有声音没画面」。
    ///
    /// 判据与 VLC 内核的「硬解无画面→软解」完全同构（照 tvbox-Swift）：播放中、时间
    /// 推进超过 2 秒、却始终拿不到画面尺寸。命中就请上层换 VLC 软解重播一次，只做
    /// 一次避免来回切。纯音频按扩展名排除；上层没设回调（普通书源视频）时直接返回。
    private func checkMissingVideoTrack(at seconds: Double, stream: VideoStream) {
        guard !didRequestKernelFallback, seconds > 2, phase == .playing else { return }
        guard let fallback = onNoVideoTrack else { return }
        let ext = (CatVodPlaybackRoute.originalExtension(of: stream.url)
                   ?? stream.info?.sourceExtension ?? "").lowercased()
        guard !CatVodPlaybackRoute.audioOnlyExtensions.contains(ext) else { return }
        // 解不出视频轨时 presentationSize 恒为 .zero，画面层 KVO 不会写入 pictureSize。
        // 不能用 accessLog 码率代替：indicatedBitrate 兜底连纯音频都有值，判据会失效。
        let hasPicture = (pictureSize?.width ?? 0) > 0 && (pictureSize?.height ?? 0) > 0
        guard !hasPicture else { return }
        didRequestKernelFallback = true
        AppLogger.info("[Video] 系统内核无视频轨，切 VLC 软解重播（\(Int(seconds))s）", level: .notice)
        player.pause()
        fallback(stream, seconds)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?, of item: ObjectIdentifier) {
        // A change can arrive after the next episode has replaced the item it was about.
        guard player.currentItem.map(ObjectIdentifier.init) == item else { return }
        switch status {
        case .readyToPlay:
            guard phase == .loading, let item = player.currentItem else { return }
            apply(VideoTimeline(duration: item.duration.seconds,
                                seekable: item.seekableTimeRanges.map(\.timeRangeValue)))
            let seek = pendingSeek
            pendingSeek = 0
            if seek > 0, duration == 0 || seek < duration - 1 {
                player.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
            }
            resume()
            activateNowPlaying()
        case .failed:
            // A script's link has nothing to resolve it again from.
            if case .book(let store, _) = source, refetchedChapter != chapterIndex {
                refetchedChapter = chapterIndex
                AppLogger.info("[Video] link failed to play; resolving it again", level: .notice)
                VideoChapterLinks.discardResolvedLink(for: book, chapterIndex: chapterIndex, store: store)
                load(at: currentTime)
            } else if recoverIfDropped(player.currentItem?.error) {
                // 连接断了，已经在重开，错误先不显示给人看。
            } else {
                // 「资源无访问权限」（403 / contentIsNotAuthorized）用同一个链接重试无效。
                // 猫源/书源的 .link 源无法重新解析，只能退出换线路——给出准确文案并
                // 让失败页把「重试」换成「返回换线路」。识别按错误码 + 文案兜底。
                let underlying = player.currentItem?.error
                // 403 无权限与 404 死链都不该给用户「重试」：同一个失效链接重试不会成功。
                let notFound = (underlying?.localizedDescription ?? "")
                    .localizedCaseInsensitiveContains("not found")
                let missing = (underlying?.localizedDescription ?? "")
                    .contains("找不到")
                let missingURL = (underlying?.localizedDescription ?? "")
                    .contains("找不到所请求的 URL")
                failedNeedsRelink = Self.isNotAuthorized(underlying) || notFound || missing || missingURL
                let message = failedNeedsRelink
                    ? localized("这个视频链接已失效（403/404 或需要登录），请返回换一条线路")
                    : (error ?? localized("无法播放这一集"))
                AppLogger.info("[Video] episode failed to play: \(error ?? "-")", level: .error)
                phase = .failed(message)
            }
        default:
            break
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        switch phase {
        case .playing: pause()
        case .paused: resume()
        case .ended: play(chapterIndex: guide.firstEpisode ?? chapterIndex)
        case .failed: retry()
        case .loading: break
        }
    }

    func pause() {
        guard phase == .playing else { return }
        player.pause()
        phase = .paused
        saveProgress(force: true)
    }

    private func timelineChanged(_ timeline: VideoTimeline, of item: ObjectIdentifier) {
        guard player.currentItem.map(ObjectIdentifier.init) == item else { return }
        apply(timeline)
    }

    private func apply(_ timeline: VideoTimeline) {
        duration = timeline.duration
        seekableRange = timeline.seekableRange
    }

    func resume() {
        player.playImmediately(atRate: rate)
        phase = .playing
    }

    func retry() {
        refetchedChapter = nil
        load(at: currentTime)
    }

    /// Does nothing while nothing is seekable: a live stream with no window, or one still loading.
    func seek(to seconds: Double) {
        guard let range = seekableRange else { return }
        let target = min(max(seconds, range.lowerBound), range.upperBound)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            // A later seek or the next episode cuts one short; a seek that never lands while the
            // picture plays on is what FB-175 looked like from outside, so it is on record.
            if !finished { AppLogger.info("[Video] seek to \(Int(target)) s did not finish", level: .notice) }
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        player.defaultRate = rate
        if phase == .playing { player.rate = rate }
    }

    // MARK: Observation

    private func observePlayer() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.timeAdvanced(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item != nil, item === self.player.currentItem else { return }
                self.episodeEnded()
            }
        }
        // 连接断掉时 AVPlayer 结束这一集的回调。它和 `.failed` 都会来，先到的那个
        // 触发重开，另一个看到 phase 已经变了就不再动作。
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, item != nil, item === self.player.currentItem else { return }
                self.recoverIfDropped(error)
            }
        }
    }

    /// 是否为「资源无访问权限」失败：AVFoundation 的 contentIsNotAuthorized(-11835)，
    /// 或错误链里带 403 / not authorized / 许可 字样。后者是文案兜底——403→-11835
    /// 的映射不是苹果文档承诺，中文系统还会给出「没有访问…许可」的本地化描述。
    /// 沿 underlyingErrors 递归，因为 AVPlayerItem.error 常把真实原因包在底层。
    private static func isNotAuthorized(_ error: Error?) -> Bool {
        guard let error else { return false }
        // 用显式栈递归错误链，不用嵌套函数：underlyingErrors 是 [Error]，
        // 传 @MainActor 的嵌套函数给 contains(where:) 会触发 Swift 6 隔离/类型错误。
        var pending: [Error] = [error]
        var inspected = 0
        while let current = pending.popLast(), inspected < 32 {
            inspected += 1
            let nsError = current as NSError
            if nsError.domain == AVFoundationErrorDomain,
               nsError.code == AVError.Code.contentIsNotAuthorized.rawValue { return true }
            let text = (nsError.localizedDescription + " " + (nsError.localizedFailureReason ?? ""))
                .lowercased()
            if text.contains("403") || text.contains("not authorized") || text.contains("许可") {
                return true
            }
            pending.append(contentsOf: nsError.underlyingErrors)
        }
        return false
    }

    /// 连接类错误：按 1s/3s/8s 在原位置重开。真正的失败（403、解码不了）仍然报错。
    @discardableResult
    private func recoverIfDropped(_ error: Error?) -> Bool {
        guard phase == .playing || phase == .loading else { return false }
        guard let delay = dropRecovery.delay(after: error, position: currentTime) else { return false }
        AppLogger.info("[Video] 连接中断，\(delay) 后在原位置重开", level: .notice)
        phase = .loading
        recoveryTask?.cancel()
        let resumeAt = currentTime
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.load(at: resumeAt)
        }
        return true
    }

    private func timeAdvanced(_ seconds: Double) {
        guard seconds.isFinite, phase == .playing else { return }
        currentTime = seconds
        refreshPlaybackBitrate()
        if abs(seconds - lastSavedTime) >= 5 { saveProgress(force: false) }
        // 猫源链路：系统内核解不出视频轨（有声音没画面）时切 VLC 软解重播。
        // 挂在这里而不是独立定时器，和 VLC 内核的每秒采样判据完全同构。
        if case .link(let stream) = source {
            checkMissingVideoTrack(at: seconds, stream: stream)
        }
    }

    /// Apple 文档：accessLog 的 averageVideoBitrate / indicatedAverageBitrate 是
    /// 当前播放流的视频码率；它们比从文件名猜 4K 可靠。未知时保持 nil。
    private func refreshPlaybackBitrate() {
        let event = player.currentItem?.accessLog()?.events.last
        let candidates = [event?.averageVideoBitrate ?? -1,
                          event?.indicatedAverageBitrate ?? -1,
                          event?.indicatedBitrate ?? -1]
        let value = candidates.first { $0 > 0 }.map { Int($0) }
        guard measuredVideoBitrate != value else { return }
        measuredVideoBitrate = value
    }

    /// 信息面板文本：静态线路信息 + 内核实测分辨率/码率。
    var playbackInfoLines: [String] {
        let info = streamInfo ?? VideoStreamInfo()
        return info.lines(pictureSize: pictureSize, measuredBitrate: measuredVideoBitrate)
    }

    private func episodeEnded() {
        if let next = guide.episode(after: chapterIndex) {
            play(chapterIndex: next)
        } else {
            phase = .ended
            currentTime = 0
            saveProgress(force: true)
        }
    }

    // MARK: Progress

    func saveProgress(force: Bool, chapterProgress: Double? = nil) {
        lastSavedTime = currentTime
        book.audioChapterIndex = chapterIndex
        book.audioTimeSeconds = currentTime
        switch source {
        case .link(let stream):
            VideoLinkPositions.save(currentTime, for: stream.url)
            return
        case .book(_, persists: false):
            return
        case .book(let store, persists: true):
            // The player knows this episode's duration; the shelf's progress fraction
            // should move inside a chapter too. On a live stream (duration 0) pass nil
            // and keep the chapter-count behaviour.
            let fraction: Double? = chapterProgress ?? (duration > 0 ? currentTime / duration : nil)
            store.updateAudioPosition(
                bookId: book.id, chapter: chapterIndex, time: currentTime,
                totalChapters: book.onlineChapters?.count ?? 0,
                chapterProgress: fraction, forceSave: force
            )
        }
    }

    // MARK: Now Playing

    /// The lock screen and Control Center through the player's own session, so the audiobook
    /// player's handlers on the shared command center are left as they are.
    private func activateNowPlaying() {
        if nowPlayingSession == nil {
            let session = MPNowPlayingSession(players: [player])
            session.automaticallyPublishesNowPlayingInfo = true
            let commands = session.remoteCommandCenter
            commands.playCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.resume() }
                return .success
            }
            commands.pauseCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.pause() }
                return .success
            }
            commands.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.togglePlayPause() }
                return .success
            }
            commands.nextTrackCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.playNext() }
                return .success
            }
            commands.previousTrackCommand.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in self?.playPrevious() }
                return .success
            }
            commands.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let position = event.positionTime
                Task { @MainActor in self?.seek(to: position) }
                return .success
            }
            nowPlayingSession = session
        }
        nowPlayingSession?.remoteCommandCenter.nextTrackCommand.isEnabled = hasNext
        nowPlayingSession?.remoteCommandCenter.previousTrackCommand.isEnabled = hasPrevious
        nowPlayingSession?.becomeActiveIfPossible { _ in }
    }

    private func nowPlayingMetadata() -> [AVMetadataItem] {
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = episodeTitle as NSString
        title.extendedLanguageTag = "und"
        let album = AVMutableMetadataItem()
        album.identifier = .commonIdentifierAlbumName
        album.value = book.title as NSString
        album.extendedLanguageTag = "und"
        return [title, album]
    }
}

/// How far an episode reaches and where it can be sought, from what its item reports.
///
/// An MP4 or a finished HLS playlist reports its duration, and is seekable from 0 to there. An
/// HLS playlist without `#EXT-X-ENDLIST` plays as live: its duration is indefinite (NaN), yet its
/// seekable ranges still cover the segments listed so far (measured 2026-11-10 against a 60 s
/// playlist with the tag removed: duration NaN, seekable 0–30 s) — the timeline is those ranges.
/// A live stream with no window to go back in has none, and nothing to seek.
struct VideoTimeline: Equatable, Sendable {
    /// 0 when the item does not know it.
    let duration: Double
    let seekableRange: ClosedRange<Double>?

    init(duration seconds: Double, seekable: [CMTimeRange]) {
        if seconds.isFinite, seconds > 0 {
            duration = seconds
            seekableRange = 0...seconds
            return
        }
        duration = 0
        let spans = seekable.filter { $0.start.isNumeric && $0.end.isNumeric }
        guard let lower = spans.map(\.start.seconds).min(),
              let upper = spans.map(\.end.seconds).max(), upper > lower else {
            seekableRange = nil
            return
        }
        seekableRange = lower...upper
    }
}

/// The interface stays on screen under Picture in Picture, so there is nothing to bring back.
private final class VideoPictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
