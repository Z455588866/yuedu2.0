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
@MainActor
@Observable
final class PlaybackClock {
    private(set) var time: Double = 0
    private var observer: Any?
    private weak var player: AVPlayer?

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

    func detach() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player = nil
    }
}

// MARK: - Layout model

/// One comment after track allocation. Produced once per parameter change, then read-only while
/// playing. `uid` is the source index so `ForEach` identity is stable even if two comments share
/// a `cid`.
struct LaidOutDanmaku: Identifiable {
    let uid: Int
    let item: DanmakuItem
    let lane: Int
    let appear: Double
    let duration: Double
    let width: Double
    let isScroll: Bool
    var id: Int { uid }
}

/// Track scheduler ported from DanmakuKit (github.com/qyz777/DanmakuKit, MIT) — the same engine
/// used by many production players. It replaces the old `cid % laneCount` scheme, which had no
/// collision check at all and piled every comment arriving together into one corner.
///
/// Three ideas are taken verbatim from that engine and adapted to a *seekable* video timeline:
///   1. Track count is derived from the available height, not a fixed number, and tracks fill
///      from the top. (`DanmakuView.recalculateTracks`)
///   2. A new scrolling comment may use a track only if it will never catch the previous comment
///      on that track — the classic pursuit calculation in `DanmakuFloatingTrack.canShoot`.
///      If no track is free, the comment is dropped, exactly as the mature engine does.
///   3. Allocation happens ONCE (cached by a key), not per frame. Re-deriving lanes from a sliding
///      window every frame is what made comments jump and overlap.
///
/// Unlike DanmakuKit's self-driven `CAAnimation` clock, positions here are a pure function of the
/// video time, so seeking and rate changes stay perfectly in sync.
/// A plain cache, not an observable object: redraws are driven by `PlaybackClock.time`
/// (an `@Observable`), and `layout` mutates only derived data read in the same `body`.
///
/// It must NOT be `@Observable`: `layout` writes `key`/`items` while SwiftUI is
/// evaluating the body, and an observable write during a view update is exactly the
/// "modifying state during view update" pattern that intermittently crashes a view
/// mid-playback. Nothing here needs to publish — the clock already drives the redraw —
/// so a bare class is both correct and safe under Swift 6.
@MainActor
final class DanmakuLayoutStore {
    private var key = ""
    private(set) var items: [LaidOutDanmaku] = []
    private var lookback: Double = 12
    private var laneHeight: Double = 28

    /// Returns the cached layout, recomputing only when the inputs actually change.
    func layout(track: DanmakuTrack, width: Double, height: Double,
                area: Double, fontSize: Double, speed: Double,
                topInset: Double) -> [LaidOutDanmaku] {
        let key = "\(track.items.count)|\(track.items.first?.time ?? -1)|\(track.items.last?.time ?? -1)|\(width)|\(height)|\(area)|\(fontSize)|\(speed)"
        if key == self.key { return items }
        self.key = key

        let usable = max(0, height * area - topInset - 8)
        let row = max(24, fontSize + 12)
        laneHeight = row
        let laneCount = max(1, min(30, Int(usable / row)))
        lookback = max(speed, 5) + 1

        items = Self.allocate(track.items, width: width, fontSize: fontSize,
                              laneCount: laneCount, displayTime: speed)
        return items
    }

    /// Half-open range of comments still on screen at time `now`. `items` is sorted by `appear`,
    /// so a binary search skips all expired comments and we only walk the live window.
    func visibleRange(at now: Double) -> Range<Int> {
        let target = now - lookback
        var lo = 0
        var hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].appear < target { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < items.count, items[end].appear <= now { end += 1 }
        return lo..<end
    }

    // MARK: allocation

    private static func estimatedWidth(_ text: String, fontSize size: Double) -> Double {
        // CJK glyphs are ~1em, latin ~0.55em — enough for collision spacing without UI texture.
        var points: Double = 0
        for ch in text {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            points += (scalar > 0x2E80) ? size : size * 0.55
        }
        return points + 12
    }

    /// Port of `DanmakuFloatingTrack.canShoot` to a timestamped model. Given the previous comment
    /// on a track (its appear time and width) and the new one, decide whether the new comment
    /// would ever catch the previous one before it leaves the screen.
    private static func canShoot(prevWidth: Double, prevAppear: Double,
                                 newWidth: Double, newAppear: Double,
                                 screenWidth: Double, displayTime: Double) -> Bool {
        let gap = 10.0
        let prevV = (screenWidth + prevWidth) / displayTime
        let elapsed = max(0, newAppear - prevAppear)
        // Right edge of the previous comment at the instant the new one is emitted.
        let preRight = screenWidth - prevV * elapsed + prevWidth
        if preRight <= 0 { return true }            // previous has fully left the screen
        let preCellTime = preRight / prevV           // time left before it leaves
        let distance = screenWidth - preRight - gap
        guard distance >= 0 else { return false }    // previous was just emitted — too tight
        let nextV = (screenWidth + newWidth) / displayTime
        if nextV - prevV <= 0 { return true }        // never catches up (not faster)
        let catchTime = distance / (nextV - prevV)
        return catchTime >= preCellTime              // only safe if previous is gone by then
    }

    private static func allocate(_ source: [DanmakuItem], width: Double, fontSize: Double,
                                 laneCount: Int, displayTime: Double) -> [LaidOutDanmaku] {
        guard !source.isEmpty, width > 0 else { return [] }
        let sorted = source.sorted { $0.time < $1.time }
        var result: [LaidOutDanmaku] = []
        result.reserveCapacity(sorted.count)

        // Last scrolling comment on each track: (appear, width).
        var lastScroll: [(appear: Double, width: Double)?] = Array(repeating: nil, count: laneCount)
        // Top/bottom comments use their own small track pools, one live comment per track.
        let fixedLanes = max(2, laneCount / 3)
        let fixedDuration = 4.0
        var lastTopEnd = [Double](repeating: -.infinity, count: fixedLanes)
        var lastBottomEnd = [Double](repeating: -.infinity, count: fixedLanes)

        for (idx, item) in sorted.enumerated() {
            let w = estimatedWidth(item.text, fontSize: fontSize)
            if item.isScrolling {
                var chosen: Int? = nil
                for lane in 0..<laneCount {
                    let free: Bool
                    if let prev = lastScroll[lane] {
                        free = canShoot(prevWidth: prev.width, prevAppear: prev.appear,
                                        newWidth: w, newAppear: item.time,
                                        screenWidth: width, displayTime: displayTime)
                    } else {
                        free = true
                    }
                    if free { chosen = lane; break }
                }
                guard let lane = chosen else { continue }   // no room: drop it (mature engines do)
                lastScroll[lane] = (item.time, w)
                result.append(LaidOutDanmaku(uid: idx, item: item, lane: lane,
                                             appear: item.time, duration: displayTime,
                                             width: w, isScroll: true))
            } else {
                let isTop = item.mode == 5
                var chosen: Int? = nil
                if isTop {
                    for lane in 0..<fixedLanes where lastTopEnd[lane] <= item.time {
                        chosen = lane; break
                    }
                } else {
                    for lane in 0..<fixedLanes where lastBottomEnd[lane] <= item.time {
                        chosen = lane; break
                    }
                }
                guard let lane = chosen else { continue }
                if isTop { lastTopEnd[lane] = item.time + fixedDuration }
                else { lastBottomEnd[lane] = item.time + fixedDuration }
                result.append(LaidOutDanmaku(uid: idx, item: item, lane: lane,
                                             appear: item.time, duration: fixedDuration,
                                             width: w, isScroll: false))
            }
        }
        return result
    }
}

/// The danmaku layer, driven by `PlaybackClock` and laid out by `DanmakuLayoutStore`.
struct DanmakuOverlay: View {
    let clock: PlaybackClock
    let track: DanmakuTrack
    let opacity: Double
    /// Fraction of the picture height the danmaku may occupy, from the top (0.25 ... 1.0).
    let area: Double
    /// Glyph size in points.
    let fontSize: Double
    /// Seconds a scrolling comment takes to cross the picture (smaller = faster).
    let speed: Double

    /// Keep clear of the player's top control bar. The layer now only spans the picture,
    /// which already sits below the chrome, so this is a small breathing margin.
    private let topInset: Double = 10

    @State private var store = DanmakuLayoutStore()

    var body: some View {
        let now = clock.time
        GeometryReader { geo in
            let size = geo.size
            let laid = store.layout(track: track, width: Double(max(1, size.width)),
                                    height: Double(max(1, size.height)),
                                    area: area, fontSize: fontSize, speed: speed,
                                    topInset: topInset)
            let range = store.visibleRange(at: now)
            ZStack(alignment: .topLeading) {
                ForEach(range, id: \.self) { i in
                    laidOutView(laid[i], now: now, screenW: Double(size.width),
                                screenH: Double(size.height))
                }
            }
            // Fill the available space instead of pinning to `size` read above. `size` is used
            // only for coordinate math; freezing it into the frame can capture a stale geometry
            // after Picture in Picture restores. maxWidth/maxHeight always track the real layer.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
            .opacity(opacity)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func laidOutView(_ laid: LaidOutDanmaku, now: Double,
                             screenW: Double, screenH: Double) -> some View {
        let age = now - laid.appear
        if age >= 0, age <= laid.duration {
            let text = Text(laid.item.text)
                .font(.system(size: CGFloat(fontSize), weight: .semibold))
                .foregroundColor(Color(uiColor: UIColor(rgb: laid.item.color)))
                .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 1)
                .fixedSize()
            let row = max(24, fontSize + 12)
            if laid.isScroll {
                // Constant crossing time: speed depends on width, matching DanmakuKit. The left
                // edge starts at the right border and exits fully past the left border at duration.
                let v = (screenW + laid.width) / laid.duration
                let x = screenW - v * age
                let y = topInset + Double(laid.lane) * row
                text.offset(x: CGFloat(x), y: CGFloat(y))
            } else {
                let isTop = laid.item.mode == 5
                let y: Double = isTop
                    ? topInset + Double(laid.lane) * row
                    : max(topInset, screenH - screenH * 0.18 - Double(laid.lane) * row)
                text.frame(width: CGFloat(screenW), alignment: .center).offset(y: CGFloat(y))
            }
        }
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255
        let g = CGFloat((rgb >> 8) & 0xFF) / 255
        let b = CGFloat(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}

/// Controls for the danmaku layer. A native `Menu` packed with four pickers and a source list
/// cannot scroll — dragging down dismisses it instead of reaching the lower options. This is a
/// button that opens a real, scrollable `sheet` with a `List`, so every setting stays reachable.
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
                    Section(localized("占屏")) {
                        Picker(localized("占屏"), selection: $area) {
                            ForEach(Self.areaLevels) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section(localized("字号")) {
                        Picker(localized("字号"), selection: $fontSize) {
                            ForEach(Self.sizeLevels) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section(localized("速度")) {
                        Picker(localized("速度"), selection: $speed) {
                            ForEach(Self.speedLevels) { Text($0.label).tag($0.value) }
                        }
                        .pickerStyle(.segmented)
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
