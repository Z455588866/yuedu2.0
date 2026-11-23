import AVFoundation
import SwiftUI
import UIKit

/// A single danmaku currently on screen, with its resolved lane and travel. Kept in one struct so
/// `TimelineView` can rebuild the visible set cheaply every frame.
private struct FlyingDanmaku: Identifiable {
    let id: Int
    let item: DanmakuItem
    let lane: Int
    let born: Double      // seconds when this comment enters
    let duration: Double  // seconds it stays travelling
}

/// Drives danmaku straight from `AVPlayer.currentTime()` inside a `TimelineView`, rather than from
/// the controller's once-a-second `currentTime` — that would make text jump once per second and
/// freeze on seek. The overlay never intercepts touches; gestures and controls sit above it.
struct DanmakuOverlay: View {
    let player: AVPlayer
    let track: DanmakuTrack
    let opacity: Double
    /// Fraction of the picture height the danmaku may occupy, from the top (0.25 ... 1.0).
    let area: Double
    /// Glyph size in points.
    let fontSize: Double
    /// Seconds a scrolling comment takes to cross the picture (smaller = faster).
    let speed: Double

    // Spacing. Lane height and count are derived from `area` and `fontSize` so the controls can
    // change how much of the screen is covered without recompiling constants.
    private let topInset: Double = 46       // stay below the top bar

    var body: some View {
        TimelineView(.animation) { _ in
            GeometryReader { geo in
                let now = player.currentTime().seconds
                let width = geo.size.width
                let layout = laneLayout(height: geo.size.height)
                let flying = visible(at: now, width: width, layout: layout)
                ZStack(alignment: .topLeading) {
                    ForEach(flying) { fly in
                        danmakuView(fly, now: now, width: width, layout: layout)
                    }
                }
                .frame(width: width, height: geo.size.height, alignment: .topLeading)
                .allowsHitTesting(false)
                .opacity(opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private struct LaneLayout {
        let count: Int
        let height: Double
        let bottom: Double      // highest y a lane may occupy
    }

    private func laneLayout(height screenHeight: Double) -> LaneLayout {
        let usable = max(0, screenHeight * area - topInset - 24)
        let row = max(24, fontSize + 14)
        let count = max(1, min(20, Int(usable / row)))
        return LaneLayout(count: count, height: row, bottom: topInset + usable)
    }

    /// Comments whose time window contains `now`. Scrolling comments enter at `item.time` and
    /// travel for `speed` seconds; the same comment always takes the same lane (stable by cid).
    /// Top/bottom fixed comments get a couple of dedicated rows. A hard cap keeps the picture
    /// readable and the frame budget low even for tracks with tens of thousands of comments.
    private func visible(at now: Double, width: Double, layout: LaneLayout) -> [FlyingDanmaku] {
        guard now.isFinite else { return [] }
        let lower = now - speed - 0.5
        var scroll: [FlyingDanmaku] = []
        var fixed: [FlyingDanmaku] = []
        // One pass over the track; the where-clause skips almost all items cheaply.
        for item in track.items where item.time >= lower && item.time <= now + 0.05 {
            let f = FlyingDanmaku(
                id: item.cid, item: item,
                lane: abs(item.cid) % max(1, layout.count - 2),
                born: item.time,
                duration: item.isScrolling ? speed : 4.5
            )
            if item.isScrolling { scroll.append(f) } else { fixed.append(f) }
        }
        // Cap scrolling comments: at most two per lane keeps overlapping rare while still dense.
        let scrollCap = max(6, layout.count * 2)
        if scroll.count > scrollCap {
            // Keep the newest ones — they are mid-flight; older ones are about to exit anyway.
            scroll = Array(scroll.suffix(scrollCap))
        }
        // Fixed comments: only the most recent few, so they don't stack into a wall.
        if fixed.count > 4 { fixed = Array(fixed.suffix(4)) }
        return scroll + fixed
    }

    @ViewBuilder
    private func danmakuView(_ fly: FlyingDanmaku, now: Double, width: Double,
                             layout: LaneLayout) -> some View {
        let age = now - fly.born
        let progress = max(0, min(1, age / fly.duration))
        let text = Text(fly.item.text)
            .font(.system(size: CGFloat(fontSize), weight: .semibold))
            .foregroundColor(Color(uiColor: UIColor(rgb: fly.item.color)))
            .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 1)
            .fixedSize()

        if fly.item.isScrolling {
            // Right edge -> fully off the left edge.
            let startX = width
            let endX = -estimateWidth(fly.item.text)
            let x = startX + (endX - startX) * progress
            let y = topInset + Double(fly.lane) * layout.height
            text.offset(x: x, y: y)
        } else {
            // mode 5 = top, mode 4 = bottom; fixed and centred.
            let y = fly.item.mode == 5
                ? topInset + Double(fly.lane % 2) * layout.height
                : max(topInset, layout.bottom - 2 * layout.height)
            text.frame(maxWidth: .infinity, alignment: .center)
                .offset(y: y)
        }
    }

    private func estimateWidth(_ text: String) -> Double {
        // CJK glyphs are ~1em, latin ~0.55em.
        var points: Double = 0
        for ch in text {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            points += (scalar > 0x2E80) ? fontSize : fontSize * 0.55
        }
        return points + 16
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

/// Controls for the danmaku layer: on/off, source picker, plus display tuning — how much of the
/// picture the comments cover, their size and their scroll speed. Rendered in the player's top bar.
struct DanmakuControls: View {
    @Binding var enabled: Bool
    @Binding var selectedSourceID: String
    @Binding var area: Double
    @Binding var fontSize: Double
    @Binding var speed: Double
    let sources: [DanmakuSource]
    let status: String

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
        Menu {
            Toggle(isOn: $enabled) {
                Label(localized("弹幕"), systemImage: enabled ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
            }
            if enabled {
                Divider()
                Picker(localized("弹幕源"), selection: $selectedSourceID) {
                    ForEach(sources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                Divider()
                Picker(localized("占屏"), selection: $area) {
                    ForEach(Self.areaLevels) { level in
                        Text(level.label).tag(level.value)
                    }
                }
                Picker(localized("字号"), selection: $fontSize) {
                    ForEach(Self.sizeLevels) { level in
                        Text(level.label).tag(level.value)
                    }
                }
                Picker(localized("速度"), selection: $speed) {
                    ForEach(Self.speedLevels) { level in
                        Text(level.label).tag(level.value)
                    }
                }
                if !status.isEmpty {
                    Divider()
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            Image(systemName: enabled ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                .font(DSFont.toolbarIcon)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .foregroundStyle(enabled ? Color.accentColor : .primary)
        }
        .accessibilityLabel(localized("弹幕设置"))
    }
}
