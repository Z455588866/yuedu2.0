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

    // Speed / spacing tuned for a full-screen landscape picture.
    private let travel: Double = 9          // seconds for a scroll danmaku to cross
    private let laneHeight: Double = 34
    private let topInset: Double = 54       // stay below the top bar
    private let maxLanes = 7

    var body: some View {
        TimelineView(.animation) { _ in
            GeometryReader { geo in
                let now = player.currentTime().seconds
                let width = geo.size.width
                let lanes = min(maxLanes, max(1, Int((geo.size.height - topInset - 90) / laneHeight)))
                let flying = visible(at: now, width: width, lanes: lanes)
                ZStack(alignment: .topLeading) {
                    ForEach(flying) { fly in
                        danmakuView(fly, now: now, width: width, lanes: lanes)
                    }
                }
                .frame(width: width, height: geo.size.height, alignment: .topLeading)
                .allowsHitTesting(false)
                .opacity(opacity)
            }
        }
        .allowsHitTesting(false)
    }

    /// Comments whose time window contains `now`. Rolling comments are scheduled deterministically
    /// from their cid so the same comment always takes the same lane; a small time-based offset
    /// spreads comments that share a second across lanes to avoid stacking.
    private func visible(at now: Double, width: Double, lanes: Int) -> [FlyingDanmaku] {
        guard now.isFinite else { return [] }
        var result: [FlyingDanmaku] = []
        // Only a short window matters: scroll danmaku from `travel` seconds ago up to now.
        let lower = now - travel - 0.5
        for item in track.items where item.time >= lower && item.time <= now + 0.05 {
            let lane = abs(item.cid) % lanes
            let born = item.time
            result.append(FlyingDanmaku(
                id: item.cid, item: item, lane: lane, born: born,
                duration: item.isScrolling ? travel : 4.5
            ))
        }
        // Fixed (top/bottom) comments should not all pile up; keep the most recent few.
        return result
    }

    @ViewBuilder
    private func danmakuView(_ fly: FlyingDanmaku, now: Double, width: Double, lanes: Int) -> some View {
        let age = now - fly.born
        let progress = max(0, min(1, age / fly.duration))
        let text = Text(fly.item.text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundColor(Color(uiColor: UIColor(rgb: fly.item.color)))
            .shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 1)
            .fixedSize()

        if fly.item.isScrolling {
            // From just off the right edge to fully off the left edge.
            let startX = width
            let endX = -estimateWidth(fly.item.text)
            let x = startX + (endX - startX) * progress
            let y = topInset + Double(fly.lane) * laneHeight
            text.offset(x: x, y: y)
        } else {
            // mode 5 = top, mode 4 = bottom; fixed and centred.
            let y = fly.item.mode == 5
                ? topInset + Double(fly.lane % 2) * laneHeight
                : estimateScreenBottom(lanes: lanes, fly: fly)
            text.frame(maxWidth: .infinity, alignment: .center)
                .offset(y: y)
        }
    }

    private func estimateScreenBottom(lanes: Int, fly: FlyingDanmaku) -> Double {
        // Bottom row, above the timeline controls.
        let row = 2 - (fly.lane % 2)
        return 560 - Double(row * Int(laneHeight))
    }

    private func estimateWidth(_ text: String) -> Double {
        // CJK glyphs are ~1em, latin ~0.55em at size 20.
        var points: Double = 0
        for ch in text {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            points += (scalar > 0x2E80) ? 20 : 11
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

/// Controls for the danmaku layer: an on/off toggle and a source picker. Rendered in the player's
/// top bar. Kept separate from the overlay so it participates in the control chrome only.
struct DanmakuControls: View {
    @Binding var enabled: Bool
    @Binding var selectedSourceID: String
    let sources: [DanmakuSource]
    let status: String

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
