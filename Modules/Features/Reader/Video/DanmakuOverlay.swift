import AVFoundation
import Observation
import SwiftUI
import UIKit

/// A playback clock that ticks at display rate from an `AVPlayer` periodic time observer.
///
/// Reading `player.currentTime()` directly inside `TimelineView(.animation)` is unreliable: the
/// timeline can keep firing while `currentTime()` stays pinned to one value. Publishing the time
/// through an `@Observable` object on the main queue guarantees a redraw on every tick, so
/// scrolling stays smooth and tracks seeks and rate changes.
///
/// VLC 内核走另一条路：`VLCMediaPlayer.time` 只有 250–500ms 的粒度，直接拿来画弹幕会
/// 一跳一跳。`attach(ticker:)` 每帧采样一次，用两次采样之间的墙钟时间补差值。
@MainActor
@Observable
final class PlaybackClock {
    private(set) var time: Double = 0
    private var observer: Any?
    private weak var player: AVPlayer?
    private var displayLink: CADisplayLink?
    private var ticker: ClockTicker?
    private var provider: (@MainActor () -> (time: Double, playing: Bool))?
    private var lastRaw: Double = -1
    private var lastWall: CFTimeInterval = 0

    func attach(to player: AVPlayer) {
        guard self.player !== player || observer == nil else { return }
        detach()
        self.player = player
        time = player.currentTime().seconds
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] cmt in
            let seconds = cmt.seconds
            MainActor.assumeIsolated {
                guard let self, seconds.isFinite else { return }
                self.time = seconds
            }
        }
    }

    /// 非 AVPlayer 内核（VLC）。闭包每帧被调用一次，返回播放器当前报告的时间和是否在播。
    /// 时间向前跳超过一个采样周期（seek、片头 loading）就重新锚定，避免预测值越跑越远。
    func attach(ticker provider: @escaping @MainActor () -> (time: Double, playing: Bool)) {
        detach()
        self.provider = provider
        lastRaw = -1
        // 用 CADisplayLink + selector 而不是 Timer 的闭包：Swift 6 的 `@Sendable`
        // 闭包里捕获 `@MainActor` 的 self 会直接编译失败，selector 没有这个限制。
        let helper = ClockTicker(clock: self)
        let link = CADisplayLink(target: helper, selector: #selector(ClockTicker.step))
        // .common：拖动进度条时 runloop 进 tracking 模式，默认模式下屏幕刷新回调会停，
        // 弹幕就会卡住不动。
        link.add(to: .main, forMode: .common)
        ticker = helper
        displayLink = link
        step()
    }

    fileprivate func step() {
        guard let provider else { return }
        let sample = provider()
        let now = CACurrentMediaTime()
        let raw = sample.time
        guard raw.isFinite, raw >= 0 else { return }
        if abs(raw - lastRaw) > 0.01 {
            lastRaw = raw
            lastWall = now
        }
        guard sample.playing else {
            time = raw
            return
        }
        // 补偿最多 0.6s：VLC 卡住不报新时间时，弹幕也不该无限往前跑。
        let extra = min(max(0, now - lastWall), 0.6)
        time = raw + extra
    }

    func detach() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player = nil
        displayLink?.invalidate()
        displayLink = nil
        ticker = nil
        provider = nil
        lastRaw = -1
    }
}

/// CADisplayLink 的 target 必须是 NSObject 子类；`PlaybackClock` 是 `@Observable`，
/// 挂不了 `@objc` 方法。
private final class ClockTicker: NSObject {
    weak var clock: PlaybackClock?

    init(clock: PlaybackClock) { self.clock = clock }

    @objc func step() {
        // 先在闭包外取出弱引用：把 self（非 Sendable 的 NSObject）送进 @Sendable
        // 闭包会触发 Swift 6 的 "sending self risks causing data races"。
        let target = clock
        MainActor.assumeIsolated { target?.step() }
    }
}

// MARK: - Overlay

/// The danmaku layer, driven by `PlaybackClock` and drawn by `YDDanmakuEngine` — the mature
/// CoreText engine ported from tvbox-Swift. Comments are rasterised once into CGImages with a
/// Bilibili-style stroke, placed into non-overlapping lanes, and drawn every frame. Both player
/// kernels use this same view, so behaviour is identical whether the picture comes from AVPlayer
/// or VLC.
struct DanmakuOverlay: View {
    let clock: PlaybackClock
    let track: DanmakuTrack
    let opacity: Double
    /// Fraction of the picture height the danmaku may occupy, from the top (0.25 ... 1.0).
    let area: Double
    /// The person's base glyph size in points; the engine derives a scale from it and sizes text
    /// relative to the picture, so the same clip looks right in portrait and landscape.
    let fontSize: Double
    /// Seconds a scrolling comment takes to cross the picture (smaller = faster).
    let speed: Double

    @Environment(\.displayScale) private var scale
    @State private var engine = YDDanmakuEngine()
    @AppStorage(YDDanmakuStyle.scrollKey) private var scroll = true
    @AppStorage(YDDanmakuStyle.topKey) private var top = true
    @AppStorage(YDDanmakuStyle.bottomKey) private var bottom = true
    @AppStorage(YDDanmakuStyle.colorsKey) private var colors = true
    @AppStorage(YDDanmakuStyle.spacingKey) private var spacing = YDDanmakuStyle.standardSpacing
    @AppStorage(YDDanmakuStyle.densityKey) private var densityRaw = 0
    @AppStorage(YDDanmakuStyle.wordsKey) private var blockedWords = ""

    private var filter: YDDanmakuFilter {
        YDDanmakuFilter(colors: colors,
                        words: YDDanmakuFilter.words(blockedWords),
                        density: YDDanmakuDensity.from(densityRaw))
    }

    /// Stable identity for a loaded track. A new episode (different count or time span) reloads;
    /// a filter change includes its values so blocked words and density take effect immediately.
    private var loadID: String {
        "\(track.episodeTitle)|\(track.items.count)|\(track.items.first?.time ?? -1)|\(track.items.last?.time ?? -1)|\(colors)|\(densityRaw)|\(blockedWords)"
    }

    var body: some View {
        let now = clock.time
        let textScale = YDDanmakuStyle.textScale(fontPoints: fontSize)
        let multiplier = YDDanmakuStyle.speedMultiplier(seconds: speed)
        let dmArea = YDDanmakuArea.from(share: area)
        Canvas { context, size in
            let sprites = engine.frame(
                time: now, size: size, scale: scale, area: dmArea,
                textScale: textScale, spacing: spacing, speed: multiplier,
                scroll: scroll, top: top, bottom: bottom)
            for sprite in sprites {
                context.draw(Image(decorative: sprite.image, scale: scale), in: sprite.frame)
            }
        }
        // Reading `now` above makes the body (and the Canvas) re-evaluate on every clock tick:
        // the AVPlayer observer publishes at 60 Hz, and the VLC ticker once per display frame.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .opacity(opacity)
        .task(id: loadID) {
            engine.load(filter.apply(track.items), revision: loadID)
        }
    }
}

/// Controls for the danmaku layer. A native `Menu` packed with pickers cannot scroll — dragging
/// down dismisses it instead of reaching the lower options. This is a button that opens a real,
/// scrollable `sheet` with a `List`, matching the mature player's settings layout.
struct DanmakuControls: View {
    @Binding var enabled: Bool
    @Binding var selectedSourceID: String
    @Binding var area: Double
    @Binding var fontSize: Double
    @Binding var speed: Double
    /// Owned by the player, not by this button: the button lives inside the chrome,
    /// which hides itself after a few idle seconds, and a panel whose presentation
    /// state dies with the chrome closes itself while the person is still adjusting it.
    @Binding var showsPanel: Bool
    let sources: [DanmakuSource]
    let status: String
    /// The playing video's title, pre-filled into manual search.
    let videoTitle: String
    /// Called when the person picks an episode by hand.
    let onManualPick: (DanmakuSource, DanmakuEpisode, String) -> Void

    @State private var manualSource: DanmakuSource?
    @AppStorage(YDDanmakuStyle.scrollKey) private var scroll = true
    @AppStorage(YDDanmakuStyle.topKey) private var top = true
    @AppStorage(YDDanmakuStyle.bottomKey) private var bottom = true
    @AppStorage(YDDanmakuStyle.colorsKey) private var colors = true
    @AppStorage(YDDanmakuStyle.spacingKey) private var spacing = YDDanmakuStyle.standardSpacing
    @AppStorage(YDDanmakuStyle.densityKey) private var densityRaw = 0
    @AppStorage(YDDanmakuStyle.wordsKey) private var blockedWords = ""

    private struct Level: Identifiable {
        let label: String
        let value: Double
        var id: Double { value }
    }
    private static let areaLevels: [Level] = [
        Level(label: localized("四分之一屏"), value: 0.25),
        Level(label: localized("半屏"), value: 0.5),
        Level(label: localized("大半屏"), value: 0.75),
        Level(label: localized("全屏"), value: 1.0),
    ]
    private static let sizeLevels: [Level] = [
        Level(label: localized("小"), value: 15),
        Level(label: localized("中"), value: 19),
        Level(label: localized("大"), value: 24),
        Level(label: localized("特大"), value: 30),
    ]
    private static let speedLevels: [Level] = [
        Level(label: localized("快"), value: 6),
        Level(label: localized("较快"), value: 8),
        Level(label: localized("中"), value: 11),
        Level(label: localized("慢"), value: 15),
    ]
    private static let spacingLevels: [Level] = [
        Level(label: localized("紧凑"), value: 1.15),
        Level(label: localized("标准"), value: 1.35),
        Level(label: localized("宽松"), value: 1.7),
        Level(label: localized("很宽"), value: 2.1),
    ]
    private static let densityLevels: [Level] = [
        Level(label: localized("全部"), value: 0),
        Level(label: localized("较少"), value: 1),
        Level(label: localized("最少"), value: 2),
    ]

    var body: some View {
        Button { showsPanel = true } label: {
            Image(systemName: enabled ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .font(DSFont.toolbarIcon)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .foregroundStyle(enabled ? Color.accentColor : .primary)
        }
        .accessibilityLabel(localized("弹幕设置"))
        .sheet(isPresented: $showsPanel) { panel }
    }

    private var panel: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $enabled) {
                        Label(localized("弹幕"), systemImage: enabled ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    }
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if enabled {
                    Section(localized("弹幕源")) {
                        if sources.isEmpty {
                            Text(localized("请先导入弹幕源")).foregroundStyle(.secondary)
                        } else {
                            ForEach(sources) { source in
                                selectRow(title: source.name, tag: source.id)
                                    // Right swipe → search this source by hand. The automatic
                                    // matcher works off the video title, and one season tag or
                                    // fansub prefix is enough to miss.
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            manualSource = source
                                        } label: {
                                            Label(localized("搜索剧名"), systemImage: "magnifyingglass")
                                        }
                                        .tint(Color.accentColor)
                                    }
                            }
                        }
                    }
                    Section(localized("显示")) {
                        Picker(localized("占屏"), selection: $area) {
                            ForEach(Self.areaLevels) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                        Picker(localized("字号"), selection: $fontSize) {
                            ForEach(Self.sizeLevels) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                        Picker(localized("速度"), selection: $speed) {
                            ForEach(Self.speedLevels) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section(localized("弹幕类型")) {
                        Toggle(localized("滚动"), isOn: $scroll)
                        Toggle(localized("顶部"), isOn: $top)
                        Toggle(localized("底部"), isOn: $bottom)
                        Toggle(localized("彩色弹幕"), isOn: $colors)
                    }
                    Section(localized("密度与行距")) {
                        Picker(localized("密度"), selection: $densityRaw) {
                            ForEach(Self.densityLevels) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                        Picker(localized("行距"), selection: $spacing) {
                            ForEach(Self.spacingLevels) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section {
                        TextField(localized("屏蔽词，每行一个；/正则/ 也可"), text: $blockedWords, axis: .vertical)
                            .lineLimit(2...4)
                            .autocorrectionDisabled()
                        Text(localized("包含这些词的弹幕将不显示。"))
                            .font(.caption).foregroundStyle(.secondary)
                    } header: {
                        Text(localized("屏蔽词"))
                    }
                }
            }
            .navigationTitle(localized("弹幕设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { showsPanel = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Nested on purpose: this sheet lives inside the settings sheet, so cancelling
        // the search returns to the source list instead of dismissing everything.
        .sheet(item: $manualSource) { source in
            DanmakuManualSearchView(source: source, initialKeyword: videoTitle) { episode, animeTitle in
                onManualPick(source, episode, animeTitle)
            }
        }
    }

    @ViewBuilder
    private func selectRow(title: String, tag: String) -> some View {
        Button {
            selectedSourceID = tag
        } label: {
            HStack {
                Text(title)
                Spacer()
                if selectedSourceID == tag {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DSColor.textPrimary)
    }
}
