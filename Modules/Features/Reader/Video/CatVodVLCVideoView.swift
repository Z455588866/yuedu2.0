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
import Dispatch
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
    /// 片源的像素尺寸。弹幕/字幕层要按它算「画面实际矩形」，画面放大后才知道跟到哪。
    /// 解析出元数据前是 `.zero`，此时按整窗摆放，不会闪。
    @Published private(set) var videoSize: CGSize = .zero

    /// 画面容器。VLC 把像素直接画进这个 UIView，SwiftUI 只负责摆放它。
    let drawable = UIView(frame: .zero)


    private var player: VLCMediaPlayer?
    private var tickTask: Task<Void, Never>?
    private var pendingSeek: Double = 0
    /// 「拉伸」档要覆盖的宽高比，nil 表示按片源原始比例。
    /// libvlc 的 aspect 语义就是「按这个比例渲染」，设成窗口比例即非等比拉伸铺满。
    private var aspectOverride: String?
    /// 播完之后要能重来一遍：VLC 停在 `.ended` 时再调 `play()` 不会动，
    /// 必须换一个新的 media 对象。
    private var sourceURL: URL?
    private var sourceHeaders: [String: String] = [:]
    /// 照 tvbox-Swift 的解码容错：默认硬解优先，硬解解不出画面时切软解重播一次。
    private var useSoftwareDecode = false
    private var hasAttemptedSoftDecodeFallback = false
    /// 纯音频（m4a/mp3/aac…）没有视频轨，videoSize 恒为 .zero。若不排除，
    /// 下面的"硬解无画面"判据会在播到 2 秒时误判，切软解重开流把音频打断
    /// （日志里喜马拉雅 m4a 就中过招）。打开时按扩展名标记，跳过画面降级。
    private var isAudioOnly = false
    /// 音轨修正只做一次，且只在 VLC 默认选择无效时做（见 selectAudioTrackIfNeeded）。
    private var didResolveAudioTrack = false
    /// 这些格式没有视频轨，videoSize 恒为 .zero，不能触发「硬解无画面」降级。
    /// 代理后扩展名丢失，用路由层从代理 spec 里还原的原始格式判断。
    private static let audioOnlyExtensions: Set<String> = [
        "m4a", "m4b", "mp3", "aac", "wav", "flac", "ogg", "opus", "wma", "ape",
    ]

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
        // 每次开新流都从「硬解优先」重新试起，软解降级只针对当前这一次播放。
        useSoftwareDecode = false
        hasAttemptedSoftDecodeFallback = false
        didResolveAudioTrack = false
        // 纯音频没有视频轨：按原始格式（代理后从 ?s= 还原）标记，跳过画面降级，
        // 否则播到 2 秒会被当成「硬解无画面」切软解重开，把音频打断。
        let originalExt = CatVodPlaybackRoute.originalExtension(of: url) ?? ""
        isAudioOnly = Self.audioOnlyExtensions.contains(originalExt)

        // 照 tvbox-Swift 的 stablePlaybackOptions：少丢帧之外，还关掉 libvlc 的
        // 时钟纠偏（clock-synchro/jitter），网盘流忽快忽慢时画面不抖、音画不错位。
        let player = VLCMediaPlayer(options: [
            "--no-drop-late-frames", "--no-skip-frames",
            "--clock-synchro=0", "--clock-jitter=0",
        ])
        player.delegate = self
        player.drawable = drawable
        // MobileVLCKit 的语义：scaleFactor 只有在 0（自动）时才会跟随 drawable 的尺寸变化。
        // 写死成别的值，之后改 drawable 的 frame 画面不会重排 —— 这也是「填满萤幕后画面没变」
        // 这类问题的常见根因。宽高比按当前档位应用（「拉伸」才需要覆盖）。
        player.scaleFactor = 0
        self.player = player
        applyAspectRatio(aspectOverride)

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
            // 照 tvbox-Swift：显式声明硬解策略。默认 any（硬解优先），
            // 降级后用 none（软解）。此前完全没设，libvlc 默认行为在部分
            // 设备/编码上解不出视频轨——音频正常、画面全黑（用户反馈的
            // 「只听到声音看不到画面」）。
            "avcodec-hw": useSoftwareDecode ? "none" : "any",
            "avcodec-hurry-up": 0,
            "clock-synchro": 0,
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

    /// 失败页的「重试」：同一地址/请求头再开一次，解码与选轨状态全部重置。
    /// 复用 replay() 的换 media 方式，不在 error 状态下先 stop()（异步收尾会把新 media 清掉）。
    func retry() {
        guard player != nil, sourceURL != nil else { return }
        useSoftwareDecode = false
        hasAttemptedSoftDecodeFallback = false
        didResolveAudioTrack = false
        replay()
    }

    /// 硬解无画面时切软解重来，保留当前播放进度（照 tvbox 的
    /// attemptSoftDecodeFallbackIfNeeded：resumePosition 用当前时间，别从头播）。
    /// 调用前需先把 useSoftwareDecode 置 true，makeMedia 才会写 avcodec-hw=none。
    private func replayWithSoftwareDecode(resume seconds: Double) {
        guard let player, let url = sourceURL else { return }
        failure = nil
        isPreparing = true
        pendingSeek = max(0, seconds)
        time = seconds
        // 与 replay() 同样：不先 stop()，ended/playing 下直接换 media 再 play 才是
        // VLCKit 认的用法，先 stop 会因异步收尾把新 media 一起清掉导致黑屏。
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

    /// 画面档位里只有「拉伸」需要瓶子自己出力：VLC 默认永远保持片源比例，
    /// 想非等比铺满只能把 `videoAspectRatio` 设成窗口比例 = W:H。
    /// 语义与 libvlc 的 `libvlc_video_set_aspect_ratio` 一致（内部会拷贝字符串）；
    /// 传 nil 恢复片源原始比例。这是 VLC 系播放器做「拉伸」的通用做法。
    func applyAspectRatio(_ value: String?) {
        aspectOverride = value
        guard let player else { return }
        if let value {
            value.withCString { player.videoAspectRatio = UnsafeMutablePointer(mutating: $0) }
        } else {
            player.videoAspectRatio = nil
        }
    }

    /// 多轨源若 VLC 默认落在禁用轨（-1）或不在轨表里的 id 上，表现是「有画面没声音」。
    /// MobileVLCKit 是二进制 framework，Swift 属性签名无法编译期校验，这里用 KVC
    /// 按 Objective-C selector 读写（二进制中确认 audioTrackIndexes /
    /// currentAudioTrackIndex 的 getter/setter 都在），避免留下可能编译失败的代码。
    /// 只在默认选择无效时纠一次，不覆盖 VLC 已经选好的有效轨。
    private func selectAudioTrackIfNeeded() {
        guard let player else { return }
        // value(forKey:) 遇到不存在的 key 会抛 NSUnknownKeyException（ObjC 异常，
        // Swift 的 try? 接不住）。二进制 strings 只能证明字符串存在、不能证明 KVC
        // 合规，所以先用 responds(to:) 确认 getter/setter selector 真的存在再读写，
        // 让这个"锦上添花"的修正绝无可能把能播的片子搞崩。
        guard player.responds(to: Selector("audioTrackIndexes")),
              player.responds(to: Selector("currentAudioTrackIndex")),
              player.responds(to: Selector("setCurrentAudioTrackIndex:")) else { return }
        guard let tracks = player.value(forKey: "audioTrackIndexes") as? [NSNumber] else { return }
        let valid = tracks.map(\.intValue).filter { $0 >= 0 }
        guard let first = valid.first else { return }
        let selected = (player.value(forKey: "currentAudioTrackIndex") as? NSNumber)?.intValue ?? -1
        guard !valid.contains(selected) else { return }
        // 显式包成 NSNumber：KVC 走 Objective-C，Int 的隐式桥接不保证在所有
        // Swift 版本都成立，包一层杜绝 setValue 因类型不符抛异常。
        player.setValue(NSNumber(value: first), forKey: "currentAudioTrackIndex")
        AppLogger.info("[CatVod][VLC] 默认音轨无效，改选 id=\(first) 轨数=\(valid.count)", level: .notice)
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        guard let old = player else { return }
        player = nil
        // libvlc_media_player_destroy 会同步等解码线程收尾。MetricKit 实测它在主线程
        // 卡 2.1s（23:39 的 hang），表现就是"点了关闭/返回，界面几秒什么都点不动"。
        // 把 player 的 stop + 释放整段挪到后台队列：主线程只把属性置 nil 立刻返回，
        // 局部强引用 old 跟着闭包活到销毁结束，再自然释放、触发 deinit。
        // nonisolated(unsafe) 是 Swift 6 下把非 Sendable 对象跨并发域携带的标准写法。
        nonisolated(unsafe) let playerToRelease = old
        DispatchQueue.global(qos: .userInitiated).async {
            playerToRelease.stop()
            // 闭包结束时 playerToRelease 释放 → libvlc_media_player_destroy 在后台完成，
            // drawable 的引用随之断开，不必在主线程手动置 nil（那也会带来 UIKit 线程问题）。
        }
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
        // 片源尺寸到手后弹幕/字幕才有参照；只在真的变了才发，避免每 500ms 触发重排。
        let size = player.videoSize
        if size.width > 0, size.height > 0, size != videoSize {
            videoSize = size
            // 诊断：尺寸决定弹幕矩形和字号，首次解析到时打一条，便于定位「弹幕不显示」。
            AppLogger.info("[CatVod][VLC] videoSize=\(Int(size.width))x\(Int(size.height)) t=\(Int(current))s state=\(String(describing: player.state))", level: .notice)
        }
        if pendingSeek > 0, current > 0.5 {
            let target = pendingSeek
            pendingSeek = 0
            seek(to: target)
        }
        // 照成熟项目 tvbox-Swift 的 refreshPlaybackFlags：部分源会长时间停留在
        // opening/buffering 回调，但实际画面已经在渲染。state 回调单独决定
        // isPreparing 会让转圈永远不消失（用户反馈「播着播着一直转圈」）。
        // 用底层 player.isPlaying 兜底：真在出画面就按播放中处理，清掉转圈。
        if player.isPlaying {
            isPreparing = false
            isPlaying = true
        } else {
            isPlaying = false
            // 没在播、时间也没前进、又等过了首包，才确实还在缓冲。
            switch player.state {
            case .opening, .buffering:
                isPreparing = true
            default:
                isPreparing = false
            }
        }

        // 音轨信息要在 open 之后、媒体装载一会儿才解析得出来；到 1.5 秒只尝试
        // 一次，避免每 500ms 反复读写。此刻轨表若还没解析出来，就保持 VLC 默认选择。
        if !didResolveAudioTrack, current >= 1.5 {
            didResolveAudioTrack = true
            selectAudioTrackIfNeeded()
        }

        // 照 tvbox-Swift 的硬解容错：默认硬解优先，但部分设备/编码（如 H.265 10bit、
        // AV1）硬解解不出视频轨，音频照常走——用户看到的就是「有声音没画面」。
        // 判据：已在播放、时间推进超过阈值、但始终拿不到 videoSize（视频轨没出画面），
        // 且还没降级过。命中则换软解重播一次。只降一次，避免死循环。
        // 纯音频（m4a/mp3/…）根本没有视频轨，videoSize 恒为 .zero，必须排除，
        // 否则播到 2 秒就会切软解重开流，把正在播的音频打断。
        if !isAudioOnly, !hasAttemptedSoftDecodeFallback, !useSoftwareDecode,
           player.isPlaying, current > 2.0, videoSize == .zero {
            AppLogger.info("[CatVod][VLC] 硬解无画面→切软解重播 t=\(Int(current))s", level: .notice)
            hasAttemptedSoftDecodeFallback = true
            useSoftwareDecode = true
            replayWithSoftwareDecode(resume: current)
        }
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
            // VLCKit 3.6 没有 mediaDidParse 回调（委托里只有 StateChanged / MediaChanged /
            // TimeChanged 等），而 libvlc 在装载媒体时会把之前设的缩放参数重置掉。
            // 社区通行做法就是在进入 playing 之后再设一次——首帧之前设的常被忽略。
            player.scaleFactor = 0
            applyAspectRatio(aspectOverride)
            let size = player.videoSize
            if size.width > 0, size.height > 0, size != videoSize { videoSize = size }
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
    /// 画面上左右拖动进度：与系统播放器共用 VideoPan / VideoGestureSurface。
    @State private var pan: VideoPan?
    /// 左边缘上滑调亮度、右边缘上滑调音量（与系统播放器同一套 VideoSystemControls）。
    @State private var systemControls = VideoSystemControls()
    /// 锁定后手势层禁用拖动/双指，只留点击唤出解锁按钮。
    @State private var isLocked = false
    /// 锁屏点击反馈：点画面只让中央锁图标短暂高亮（对齐 B站/腾讯/GSYVideoPlayer），
    /// 绝不弹出控制条——控制条里的按钮在锁屏时应完全不可触及。
    @State private var lockHint = false
    @State private var lockHintTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    /// 片源弹幕的加载任务：退出/切集时取消，别让十几秒后才到的弹幕 adopt 到已销毁的视图。
    @State private var danmakuLoadTask: Task<Void, Never>?
    /// 本播放器所在窗口。横竖屏请求必须发给它的 scene（iPad 多窗口/外接屏时不是 keyWindow）。
    @State private var window = ReaderWindowReference()
    /// 用户显式的横/竖选择；nil 表示跟随设备方向。
    @State private var orientationOverride: FixedLayoutOrientation?
    /// 面板由播放器持有而不是按钮：控制条会在空闲后自动隐藏，
    /// 面板若挂在按钮上，会在用户还在调整时被一起从视图树里摘掉。
    @State private var showsDanmakuPanel = false
    @State private var showsSubtitlePanel = false
    /// 画面摆放方式：适应 / 铺满（裁剪）/ 拉伸 / 原始尺寸，与系统播放器同一套档位。
    @State private var scalingMode: VideoScalingMode = .fit
    /// 手动四分之一转，修正横置编码的片源（0/1/2/3），与系统播放器同一个按钮。
    @State private var pictureRotation = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // 画面、弹幕、字幕放进同一个「画面矩形」里，而不是各自铺满整窗：
            // 画面怎么缩放、怎么裁剪，弹幕和字幕就跟着怎么动。
            // 这是成熟引擎的通行做法——字节 DanmakuRenderEngine 要求弹幕视图的尺寸
            // 与视频画面尺寸一致；CommentCoreLibrary 则是拉伸弹幕容器、字号同步放大。
            GeometryReader { geo in
                let size = geo.size
                // 旋转 90/270° 时片源的宽高对调，与系统播放器的 rotatedPictureSize 一致。
                // 用无副作用的表达式而非 swap(&...)：ViewBuilder 里不能放返回 () 的语句，
                // 否则编译报 "type '()' cannot conform to 'View'"（build ed515cc 的失败原因）。
                let picture = model.videoSize
                let native = pictureRotation % 2 == 1
                    ? CGSize(width: picture.height, height: picture.width)
                    : picture
                // 旋转时强制按「适应」算矩形和字号，与 VideoPlayerLayerView 的判断一致，
                // 避免画面转了、弹幕矩形却还按铺满算导致的错位。
                let mode: VideoScalingMode = pictureRotation % 2 == 1 ? .fit : scalingMode
                // 画面层用「片源完整矩形」：铺满档是放大矩形，超出窗口的部分由外层
                // clipped 裁掉，从而实现等比铺满裁剪；弹幕/字幕层用「可见矩形」：
                // 铺满/拉伸档是整窗。这正是 tvbox-silicon 分离 videoRect / pictureRect
                // 的目的——两者严格对应各自 gravity，弹幕不会再跑到屏幕外。
                let pictureBounds = mode.videoRect(native: native, in: size)
                let visibleRect = mode.pictureRect(native: native, in: size)
                // 「拉伸」档要靠 VLC 的 aspect 实现，其余档位恢复片源原始比例。
                let aspect = mode == .stretch && size.width > 0 && size.height > 0
                    ? "\(Int(size.width.rounded())):\(Int(size.height.rounded()))"
                    : nil
                ZStack {
                    VLCVideoSurface(view: model.drawable, rotation: pictureRotation)
                        .frame(width: max(1, pictureBounds.width),
                               height: max(1, pictureBounds.height))
                        .position(x: pictureBounds.midX, y: pictureBounds.midY)
                    ZStack {
                        // 弹幕压在画面上、控制条下面，且不接管触摸——否则点不到进度条。
                        if danmakuController.enabled, let track = danmakuController.track {
                            // 与系统播放器一致：字号交给引擎按「画面矩形」短边自适应（含下限），
                            // 传用户在设置里选的点数，避免外部再乘画面缩放造成双重缩放。
                            DanmakuOverlay(clock: clock, track: track,
                                           opacity: danmakuController.opacity,
                                           area: danmakuController.area,
                                           fontSize: danmakuController.fontSize,
                                           speed: danmakuController.speed)
                                .allowsHitTesting(false)
                        }
                        // 外挂字幕压在弹幕之上、控制条之下；时钟与系统播放器共用，
                        // 因此 VLC 解码的画面里拖动进度后字幕照样逐句跟随。
                        if subtitle.enabled, let entry = subtitle.activeEntry {
                            SubtitleOverlay(clock: clock, entry: entry, opacity: 1,
                                            coverBuiltin: subtitle.coverBuiltin)
                        }
                    }
                    .frame(width: max(1, visibleRect.width), height: max(1, visibleRect.height))
                    .position(x: visibleRect.midX, y: visibleRect.midY)
                }
                .clipped()
                .task(id: aspect) {
                    model.applyAspectRatio(aspect)
                }
            }
            .ignoresSafeArea()
            // 画面手势在控制条之下：控制条显示时它拦自己的触摸，其余区域透过手势层。
            gestureSurface
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
                    // 与系统播放器失败页一致：给一次就地重试，不用退出重进这一集。
                    HStack(spacing: DSSpacing.md) {
                        Button(localized("重试")) { model.retry() }
                            .buttonStyle(.bordered)
                        Button("返回") { onClose() }
                            .buttonStyle(.borderedProminent)
                    }
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
            if let pan, pan.kind == .seek {
                VideoSeekBadge(time: pan.value, end: max(model.duration, 0.1),
                               delta: pan.value - pan.origin)
            }
            if let pan, pan.kind == .brightness {
                VideoAdjustBadge(kind: .brightness, value: pan.value)
            }
            if let pan, pan.kind == .volume {
                VideoAdjustBadge(kind: .volume, value: pan.value)
            }
            // 锁屏语义对齐 B站 / 腾讯 / GSYVideoPlayer：锁屏后画面干净，中央**不常驻**
            // 任何锁图标。点击屏幕时才让锁图标短暂闪现一下（lockHint 驱动），提示
            // "已锁定，点此解锁"，随后自动消失；点这个闪现的图标才解锁。
            if isLocked {
                Button {
                    isLocked = false
                    lockHint = false
                    lockHintTask?.cancel()
                    showsControls = true
                    scheduleHide()
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.55), in: Circle())
                }
                // 默认完全隐藏、不占命中；只有 flashLockHint 期间短暂出现且可点。
                .opacity(lockHint ? 1 : 0)
                .allowsHitTesting(lockHint)
                .accessibilityHidden(!lockHint)
                .animation(DSAnimation.fast, value: lockHint)
                .accessibilityLabel(localized("解锁屏幕"))
            }
            // 左上角常驻退出键：控制条几秒后就会自动收起，顶栏那个 X 会跟着消失，
            // 竖屏窄屏又没有系统返回手势，用户就没法退出这一集。这个 X 不依赖
            // showsControls——控制条显示时常驻键也在（与控制条顶栏的 X 同位置、同
            // 功能，由这一层负责点击），控制条收起后更不会消失。锁屏时隐藏，交给
            // 中央解锁按钮，与 B站/腾讯视频的锁屏语义一致。
            if !isLocked {
                // 用容器 + Spacer 贴到左上角，而不是给 Button 加 infinity frame——
                // 后者会把整块屏幕都变成按钮的点击区，点画面任意处都会误关。
                // SwiftUI 中 VStack/HStack/Spacer 的空白区本就不拦截点击，事件照常穿透到手势层，
                // 只有圆形按钮自身可点。
                //
                // 关键：绝不能给容器加 `.allowsHitTesting(false)`——父视图设 false 会让整棵
                // 子树（含子按钮）都退出命中测试，子按钮写 true 也无法恢复，X 就点不动了。
                VStack {
                    HStack {
                        Button { onClose() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .contentShape(Circle())
                        .accessibilityLabel(localized("关闭"))
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.leading, 14)
                .padding(.top, 8)
            }
        }
        .readerWindowProbe(window)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(.hidden)
        // 与系统播放器同样把整棵视图（含弹幕/字幕的 sheet）设为深色环境。
        // 少了这一行，sheet 用系统浅色环境、文字却又继承顶栏的 .white，
        // 就成了「白底白字、看起来一片空白但其实有内容」。
        .environment(\.colorScheme, .dark)
        .task {
            model.open(url: url, headers: headers, startAt: startAt)
            clock.attach { [model] in (model.rawTime, model.isPlaying) }
            if let danmaku {
                // 画面先起来，弹幕到了再叠——红果取整集弹幕要十几秒。
                // 存句柄并加取消保护：退出/重进这一集时取消，避免迟到的弹幕写回已销毁视图。
                danmakuLoadTask?.cancel()
                danmakuLoadTask = Task {
                    if let items = await danmaku(), !items.isEmpty {
                        guard !Task.isCancelled else { return }
                        danmakuController.adopt(items, title: title,
                                                sourceName: localized("片源自带"))
                    } else {
                        guard !Task.isCancelled else { return }
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
        .background {
            // 亮度/音量手势依赖它常驻：MPVolumeView 必须在视图树里才能改系统音量。
            VideoVolumeHost(controls: systemControls).frame(width: 1, height: 1)
        }
        // 照系统播放器 VideoPlayerView：画面尺寸到手后按宽高比自动转向——
        // 用户明确要的「像系统那样自动识别横屏竖屏」。manual 横/竖选择优先，
        // 未手动选过时跟随片源比例（高>宽→竖屏，否则横屏）。
        .onChange(of: model.videoSize) { _, size in
            guard size.width > 0, size.height > 0 else { return }
            if let override = orientationOverride { turn(to: override) }
            else { turn(to: size.height > size.width ? .portrait : .landscape) }
        }
        .onDisappear {
            clock.detach()
            lockHintTask?.cancel()
            danmakuLoadTask?.cancel()
            model.stop()
            danmakuController.stop()
            subtitle.stop()
            // 还原用户调过的屏幕亮度，别让其他页面跟着变暗。
            systemControls.restoreBrightness()
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

    // MARK: Gestures

    /// 画面手势层：点按唤出/收起控制条，左右拖进度、左边缘调亮度、右边缘调音量。
    /// 与系统播放器共用 VideoGestureSurface / VideoPan，锁屏时只留点击。
    private var gestureSurface: some View {
        VideoGestureSurface(
            isLocked: isLocked,
            onTap: {
                // 对齐 B站/腾讯/GSYVideoPlayer 的锁屏语义：锁屏时点画面只让中央锁图标
                // 短暂高亮，提示"已锁定，请点锁图标解锁"，绝不弹出控制条。控制条里的
                // 按钮在锁屏时必须完全不可触及。拖动/双指已被 VideoGestureSurface 禁用。
                guard !isLocked else { flashLockHint(); return }
                showsControls.toggle()
                scheduleHide()
            },
            onPan: { panned($0) },
            onPinch: { _ in }
        )
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func panned(_ event: VideoGestureSurface.PanEvent) {
        switch event {
        case .began(let start, let translation, let size):
            let kind = VideoPanKind(start: start, translation: translation, in: size)
            let seekable = !model.isLive && model.duration > 0
            guard kind != .seek || seekable else { return }
            let origin: Double = {
                switch kind {
                case .seek: return model.time
                case .brightness: return systemControls.brightness
                case .volume: return systemControls.volume
                case .episodes: return 0
                }
            }()
            pan = VideoPan(kind: kind, origin: origin, value: origin)
            scheduleHide()
        case .changed(let translation, let size):
            guard var current = pan else { return }
            switch current.kind {
            case .seek:
                guard !model.isLive, model.duration > 0 else { return }
                let range = 0...model.duration
                current.value = VideoPan.seekTime(origin: current.origin, translation: translation.width,
                                                  width: size.width, in: range)
                pan = current
                scrubbing = current.value
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
        case .ended(_, _):
            guard let finished = pan else { return }
            pan = nil
            if finished.kind == .seek {
                model.seek(to: finished.value)
                scrubbing = nil
            }
            scheduleHide()
        case .cancelled:
            pan = nil
            scrubbing = nil
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: DSSpacing.md) {
                // 关闭键改由 body 层的常驻 X 统一提供：它不随控制条收起而消失，
                // 竖屏窄屏也始终可点。这里留等宽占位，保持标题位置不变、避免两个 X 重叠。
                Color.clear
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                Text(title)
                    .font(DSFont.headline)
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
                // 画面摆放：四档照搬 ijkplayer 的 IJKMPMovieScalingMode。
                Menu {
                    Picker(localized("画面"), selection: $scalingMode) {
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
                // 旋转画面 90°：与系统播放器同一个 arrow.clockwise 按钮、同一语义。
                Button {
                    pictureRotation = (pictureRotation + 1) % 4
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(DSFont.toolbarIcon)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                }
                .accessibilityLabel(localized("旋转画面"))
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
                        .font(DSFont.toolbarIcon)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                }
                .accessibilityLabel(localized("横屏/竖屏切换"))
                // 锁定播放器：锁住后画面手势不再响应拖动/亮度/音量，点屏幕只短暂闪现解锁图标。
                Button {
                    isLocked.toggle()
                    // 锁上就立刻收起控制条，画面干净；解锁图标只在点屏幕时短暂闪现。
                    if isLocked { showsControls = false; lockHint = false; lockHintTask?.cancel() }
                    scheduleHide()
                } label: {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open")
                        .font(DSFont.toolbarIcon)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                }
                .accessibilityLabel(isLocked ? localized("解锁屏幕") : localized("锁定屏幕"))
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
                        // 与系统播放器同款 ScrubSlider（FB-175）：SwiftUI Slider 在 iOS 上
                        // 编辑会话不关闭、onEditingChanged(false) 永不触发，表现为拖了不 seek。
                        ScrubSlider(
                            value: scrubbing ?? model.time,
                            bounds: 0...max(model.duration, 0.1),
                            tint: .white,
                            onScrub: { scrubbing = $0 },
                            onCommit: { value in
                                model.seek(to: value)
                                scrubbing = nil
                            }
                        )
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
            // 面板开着、正在拖动（进度/亮度/音量）或没在播放时都保持控制条可见。
            if model.isPlaying, !showsDanmakuPanel, !showsSubtitlePanel,
               scrubbing == nil, pan == nil, !isLocked {
                showsControls = false
            }
        }
    }

    /// 锁屏时点画面的反馈：让中央锁图标短暂闪现一下就消失（对齐 B站 / 腾讯 /
    /// GSYVideoPlayer 的锁屏提示语义），给一个"已锁定，点此解锁"的提示，
    /// 但绝不常驻、也不唤出控制条。约 2 秒足以让人看见并点击。
    private func flashLockHint() {
        lockHint = true
        lockHintTask?.cancel()
        lockHintTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2000))
            guard !Task.isCancelled else { return }
            lockHint = false
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
    /// 四分之一转，语义与系统播放器的 VideoPlayerLayerView 一致。
    let rotation: Int

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 与 AVPlayerLayer 同样把 transform 加在 backing view 上：UIKit 布局会重写
        // frame/bounds，但不会碰 transform，所以旋转在尺寸变化后依然成立。
        let angle = CGFloat(rotation) * .pi / 2
        uiView.transform = CGAffineTransform(rotationAngle: angle)
    }
}
#endif
