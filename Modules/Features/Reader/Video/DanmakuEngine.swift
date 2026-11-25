import CoreGraphics
import CoreText
import Foundation
import UIKit

// MARK: - Style / filters
//
// Ported from the mature danmaku engine in tvbox-Swift (TVCore/Danmaku.swift). Everything here is
// self-contained: no TVCore, L10n or Diagnostics dependency. Settings are read straight from
// UserDefaults so both player kernels (system AVPlayer and VLC) draw with the same preferences.

/// How much of the picture comments may use, from the top. One/two/three line choices keep comments
/// to that many rows; the rest are a share of the picture. Mirrors the mature engine's DanmakuArea.
enum YDDanmakuArea: Int, CaseIterable, Sendable {
    case oneLine = 0, twoLines = 2, threeLines = 3, quarter = 25, half = 50, threeQuarters = 75, full = 100

    static let key = "danmakuArea"
    static var standard: YDDanmakuArea { .threeQuarters }

    static func from(share: Double) -> YDDanmakuArea {
        guard share.isFinite else { return standard }
        // The player passes 0.25 / 0.5 / 0.75 / 1.0 from its existing picker.
        let percent = Int((min(1, max(0, share)) * 100).rounded())
        return YDDanmakuArea(rawValue: percent) ?? standard
    }

    var lines: Int? {
        switch self {
        case .oneLine: return 1
        case .twoLines: return 2
        case .threeLines: return 3
        default: return nil
        }
    }
    var share: Double { lines == nil ? Double(rawValue) / 100 : 0 }

    var title: String {
        switch self {
        case .oneLine: return localized("一行")
        case .twoLines: return localized("两行")
        case .threeLines: return localized("三行")
        case .quarter: return localized("四分之一屏")
        case .half: return localized("半屏")
        case .threeQuarters: return localized("大半屏")
        case .full: return localized("全屏")
        }
    }
    static var titles: [String] { YDDanmakuArea.allCases.map(\.title) }
}

/// Display settings shared by every comment track. The keys match the mature engine so imported
/// preferences carry over. Speed is a multiplier (1 = the usual 9-second crossing).
enum YDDanmakuStyle {
    static let fontSizeKey = "danmakuFontSize", opacityKey = "danmakuOpacity", speedKey = "danmakuSpeed"
    static let scrollKey = "danmakuScroll", topKey = "danmakuTop", bottomKey = "danmakuBottom"
    static let colorsKey = "danmakuShowsColors", wordsKey = "danmakuBlockedWords"
    static let spacingKey = "danmakuLineSpacing", densityKey = "danmakuDensity"

    static let standardFontSize = 22.0, standardOpacity = 0.85, standardSpeed = 1.0
    static let standardSpacing = 1.35

    static func clampedSpeed(_ speed: Double) -> Double {
        speed.isFinite ? min(2, max(0.5, speed)) : standardSpeed
    }
    static func lineSpacing(_ stored: Double) -> Double {
        guard stored.isFinite else { return standardSpacing }
        let choices = [1.15, 1.35, 1.7, 2.1]
        return choices.min { abs($0 - stored) < abs($1 - stored) } ?? standardSpacing
    }
    /// The player's font size is in points (15/19/24/30). Convert to a scale relative to 22pt, the
    /// size the mature engine treats as 100%, so glyphs stay proportional to the picture.
    static func textScale(fontPoints: Double) -> Double {
        fontPoints.isFinite ? min(2.0, max(0.6, fontPoints / standardFontSize)) : 1
    }
    /// The player's speed picker is a crossing duration in seconds (6/8/11/15). Nine seconds is 1×.
    static func speedMultiplier(seconds: Double) -> Double {
        guard seconds.isFinite, seconds > 0 else { return standardSpeed }
        return min(2, max(0.5, 9 / seconds))
    }
}

/// How many comments reach the lanes. Standard keeps all; fewer/fewest also hide recently repeated
/// words and cap starts per second, which is what stops a wall of identical comments.
enum YDDanmakuDensity: Int, CaseIterable, Sendable {
    case standard = 0, fewer = 1, fewest = 2

    static func from(_ raw: Int) -> YDDanmakuDensity {
        YDDanmakuDensity(rawValue: raw) ?? .standard
    }

    var repeatWindow: Double {
        switch self {
        case .standard: return 0
        case .fewer: return 5
        case .fewest: return 10
        }
    }
    var perSecond: Int {
        switch self {
        case .standard: return .max
        case .fewer: return 4
        case .fewest: return 2
        }
    }

    func thin(_ comments: [DanmakuItem]) -> [DanmakuItem] {
        guard self != .standard else { return comments }
        var shown: [String: Double] = [:]
        var starts: [Double] = []
        var oldest = 0
        var kept: [DanmakuItem] = []
        kept.reserveCapacity(comments.count)
        for comment in comments {
            let words = comment.text.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = shown[words], comment.time - last < repeatWindow { continue }
            if comment.isScrolling {
                while oldest < starts.count, comment.time - starts[oldest] >= 1 { oldest += 1 }
                guard starts.count - oldest < perSecond else { continue }
                starts.append(comment.time)
            }
            shown[words] = comment.time
            kept.append(comment)
        }
        return kept
    }
}

struct YDDanmakuFilter: Hashable, Sendable {
    var colors: Bool
    var words: [String]
    var density: YDDanmakuDensity

    static func words(_ stored: String) -> [String] {
        stored.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func isPattern(_ word: String) -> Bool {
        word.count > 2 && word.hasPrefix("/") && word.hasSuffix("/")
    }

    func apply(_ comments: [DanmakuItem]) -> [DanmakuItem] {
        let blocked: [(String) -> Bool] = words.map { word in
            if Self.isPattern(word), let pattern = try? NSRegularExpression(pattern: String(word.dropFirst().dropLast())) {
                return { text in pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
            }
            return { text in text.range(of: word, options: [.caseInsensitive, .widthInsensitive]) != nil }
        }
        let shown: [DanmakuItem] = colors && blocked.isEmpty ? comments : comments.compactMap { comment -> DanmakuItem? in
            guard !blocked.contains(where: { $0(comment.text) }) else { return nil }
            guard !colors, comment.color != 0xFFFFFF else { return comment }
            var copy = comment
            copy.color = 0xFFFFFF
            return copy
        }
        return density.thin(shown)
    }
}

// MARK: - Text rasterisation (CoreText, Bilibili-style stroke)

/// Comment text drawn once into a CGImage and reused. A thin contrasting outline (a light outline
/// for dark comments) keeps text readable over any picture — a plain SwiftUI shadow does not.
enum YDDanmakuText {
    nonisolated(unsafe) private static let fonts = NSCache<NSNumber, CTFont>()

    private static func font(_ size: CGFloat) -> CTFont {
        if let cached = fonts.object(forKey: size as NSNumber) { return cached }
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let font = CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
        fonts.setObject(font, forKey: size as NSNumber)
        return font
    }
    private static func line(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }
    private static let padding: CGFloat = 3

    static func width(_ text: String, size: CGFloat) -> Double {
        let l = line(text, [NSAttributedString.Key(kCTFontAttributeName as String): font(size)])
        return Double(CTLineGetTypographicBounds(l, nil, nil, nil)) + Double(padding * 2)
    }

    static func image(_ text: String, color: UInt32, size: CGFloat, scale: CGFloat) -> CGImage? {
        let f = font(size)
        let red = CGFloat(color >> 16 & 0xFF) / 255
        let green = CGFloat(color >> 8 & 0xFF) / 255
        let blue = CGFloat(color & 0xFF) / 255
        let dark = 0.299 * red + 0.587 * green + 0.114 * blue < 0.25
        let fill = line(text, [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: red, green: green, blue: blue, alpha: 1),
        ])
        let outline = line(text, [
            NSAttributedString.Key(kCTFontAttributeName as String): f,
            NSAttributedString.Key(kCTStrokeWidthAttributeName as String): 6,
            NSAttributedString.Key(kCTStrokeColorAttributeName as String): CGColor(gray: dark ? 1 : 0, alpha: dark ? 0.8 : 0.7),
        ])
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(fill, &ascent, &descent, nil)
        let pixelsWide = Int(((width + padding * 2) * scale).rounded(.up))
        let pixelsHigh = Int(((ascent + descent + padding * 2) * scale).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineJoin(.round)
        for drawn in [outline, fill] {
            ctx.textPosition = CGPoint(x: padding, y: padding + descent)
            CTLineDraw(drawn, ctx)
        }
        return ctx.makeImage()
    }
}

// MARK: - Lane placement

/// Places comments into lanes as their time comes so none overlap. Scrolling comments take a lane
/// only once the previous one has fully entered and cannot be caught; fixed comments take a free
/// lane, keeping clear of scrolling ones crossing the centre. Comments with no lane are dropped —
/// that is how dense moments thin out. Ported verbatim from the mature engine.
struct YDDanmakuLayout {
    struct Placement: Sendable {
        let comment: DanmakuItem
        let start: Double
        let width: Double
        let lane: Int
        /// Points per second; zero for fixed comments.
        let speed: Double
    }
    let width: Double
    let laneHeight: Double
    let scrollLanes: Int
    let fixedLanes: Int
    let scrollDuration: Double
    let fixedDuration: Double
    private var scrolling: [[Placement]]
    private var top: [Placement?]
    private var bottom: [Placement?]
    /// With one counted row there is no separate foot, so bottom comments take turns with top ones.
    let bottomSharesTop: Bool

    init(width: Double, height: Double, laneHeight: Double, scrollArea: Double = 0.75,
         lines: Int? = nil, scrollDuration: Double = 9, fixedDuration: Double = 4) {
        self.width = width
        self.laneHeight = laneHeight
        self.scrollDuration = scrollDuration
        self.fixedDuration = fixedDuration
        if let lines {
            scrollLanes = max(1, min(lines, Int(height / laneHeight)))
            fixedLanes = scrollLanes
        } else {
            scrollLanes = max(1, Int(height * scrollArea / laneHeight))
            fixedLanes = max(1, Int(height * min(0.3, scrollArea) / laneHeight))
        }
        scrolling = Array(repeating: [], count: scrollLanes)
        top = Array(repeating: nil, count: fixedLanes)
        bottom = Array(repeating: nil, count: fixedLanes)
        bottomSharesTop = lines != nil || scrollLanes == 1
    }

    func duration(_ placement: Placement) -> Double {
        placement.speed > 0 ? (width + placement.width) / placement.speed : fixedDuration
    }

    mutating func place(_ comment: DanmakuItem, width textWidth: Double, at time: Double) -> Placement? {
        let expired = time - scrollDuration
        for lane in scrolling.indices { scrolling[lane].removeAll { $0.start <= expired } }
        if comment.isScrolling {
            let speed = (width + textWidth) / scrollDuration
            let gap = laneHeight
            for lane in scrolling.indices {
                if let last = scrolling[lane].last {
                    let elapsed = time - last.start
                    // The previous comment's tail must be on screen with a gap behind it.
                    let tail = width - elapsed * last.speed + last.width
                    guard tail <= width - gap else { continue }
                    // The new one must not reach the left edge before that tail has left.
                    let leaves = last.start + (width + last.width) / last.speed
                    guard time + width / speed >= leaves else { continue }
                }
                // Top comments share these rows; skip a row still pinned by one.
                if lane < top.count, let pinned = top[lane], time - pinned.start < fixedDuration {
                    let right = (width + pinned.width) / 2
                    guard time + (width - right) / speed >= pinned.start + fixedDuration else { continue }
                }
                let placement = Placement(comment: comment, start: time, width: textWidth, lane: lane, speed: speed)
                scrolling[lane].append(placement)
                return placement
            }
            return nil
        } else {
            let pinsToTop = comment.mode == 5 || bottomSharesTop
            let lanes = pinsToTop ? top : bottom
            guard let lane = lanes.indices.first(where: { index in
                guard lanes[index].map({ time - $0.start >= fixedDuration }) ?? true else { return false }
                guard pinsToTop, index < scrolling.count else { return true }
                let left = (width - textWidth) / 2, right = left + textWidth
                return scrolling[index].allSatisfy { moving in
                    let passed = width - (time - moving.start) * moving.speed + moving.width <= left
                    let arrives = width - (time + fixedDuration - moving.start) * moving.speed < right
                    return passed || !arrives
                }
            }) else { return nil }
            let placement = Placement(comment: comment, start: time, width: textWidth, lane: lane, speed: 0)
            if pinsToTop { top[lane] = placement } else { bottom[lane] = placement }
            return placement
        }
    }
}

// MARK: - Frame engine

/// Turns a time-ordered comment track into the sprites visible at a given playback time. State is
/// protected by a lock and driven by the player's clock (injected as `time` each frame), so seeking,
/// pausing and rate changes stay in sync on both kernels.
final class YDDanmakuEngine: @unchecked Sendable {
    struct Sprite { let image: CGImage; let frame: CGRect }
    private struct Active { let placement: YDDanmakuLayout.Placement; let image: CGImage; let size: CGSize }

    private let lock = NSLock()
    private var comments: [DanmakuItem] = []
    private var revision = ""
    private var layout: YDDanmakuLayout?
    private var size = CGSize.zero
    private var area = YDDanmakuArea.standard
    private var textScale = 1.0
    private var spacing = YDDanmakuStyle.standardSpacing
    private var speed = YDDanmakuStyle.standardSpeed
    private var scroll = true, top = true, bottom = true
    private var fontSize: CGFloat = 24
    private var next = 0
    private var active: [Active] = []
    private var lastTime = -1.0
    private var lastStep = -Double.infinity
    private static let step = 0.25
    /// Rendered text, reused: busy tracks repeat the same words, and drawing text is the costly part.
    private var images: [String: CGImage] = [:]
    private static let perFrame = 4, onScreen = 150

    func load(_ comments: [DanmakuItem], revision: String = "") {
        lock.withLock {
            if revision == self.revision, !self.comments.isEmpty, comments.count > self.comments.count,
               comments.first == self.comments.first, comments[self.comments.count - 1] == self.comments.last {
                self.comments = comments
                return
            }
            self.comments = comments
            self.revision = revision
            layout = nil
        }
    }

    /// Reset placements after a seek. The clock reports big jumps by itself; a small seek that looks
    /// like an ordinary frame is caught by the `time < lastTime - 0.3` check inside `frame`.
    func jumped(to time: Double) {
        lock.withLock {
            let moved = !time.isFinite || abs(time - lastTime) > Self.step
                || ProcessInfo.processInfo.systemUptime - lastStep < 0.5
            if moved { layout = nil }
        }
    }

    func frame(time: Double, size: CGSize, scale: CGFloat, area: YDDanmakuArea, textScale: Double,
               spacing: Double, speed: Double, scroll: Bool, top: Bool, bottom: Bool) -> [Sprite] {
        lock.withLock {
            guard time.isFinite, !comments.isEmpty, size.width > 0, size.height > 0 else { return [] }
            let speed = YDDanmakuStyle.clampedSpeed(speed)
            let spacing = YDDanmakuStyle.lineSpacing(spacing)
            let restarted = layout == nil || size != self.size || area != self.area
                || textScale != self.textScale || spacing != self.spacing || speed != self.speed
                || scroll != self.scroll || top != self.top || bottom != self.bottom
                || time < lastTime - 0.3 || time > lastTime + 2
            if restarted {
                restart(at: time, size: size, area: area, textScale: textScale, spacing: spacing,
                        speed: speed, scroll: scroll, top: top, bottom: bottom)
            }
            let advances = restarted || time > lastTime
            if !advances, next < comments.count, comments[next].time <= time {
                next = comments.partitioningIndex { $0.time > time }
            }
            if abs(time - lastTime) > Self.step { lastStep = ProcessInfo.processInfo.systemUptime }
            lastTime = time
            var budget = Self.perFrame
            while advances, next < comments.count, comments[next].time <= time {
                let comment = comments[next]
                let shown: Bool
                if comment.isScrolling { shown = scroll }
                else if comment.mode == 5 { shown = top }
                else { shown = bottom }
                guard shown, time - comment.time < 1, active.count < Self.onScreen, var layout else {
                    next += 1
                    continue
                }
                guard budget > 0 else { break }
                budget -= 1
                next += 1
                let font = fontSize
                let width = YDDanmakuText.width(comment.text, size: font)
                guard let placement = layout.place(comment, width: width, at: time),
                      let image = image(comment, size: font, scale: scale) else {
                    self.layout = layout
                    continue
                }
                self.layout = layout
                active.append(Active(placement: placement, image: image,
                                     size: CGSize(width: CGFloat(image.width) / scale,
                                                  height: CGFloat(image.height) / scale)))
            }
            guard let layout else { return [] }
            active.removeAll { time - $0.placement.start > layout.duration($0.placement) }
            let lane = layout.laneHeight
            let topInset = size.height * 0.04
            let bottomInset = area.share < YDDanmakuArea.threeQuarters.share
                ? topInset + max(lane, size.height * 0.96 * area.share)
                : size.height * 0.92
            return active.map { item in
                let placement = item.placement
                let x: Double, y: Double
                if commentIsScroll(placement.comment) {
                    x = layout.width - (time - placement.start) * placement.speed
                    y = topInset + Double(placement.lane) * lane
                } else if placement.comment.mode == 4 && !layout.bottomSharesTop {
                    x = (layout.width - item.size.width) / 2
                    y = bottomInset - Double(placement.lane + 1) * lane
                } else {
                    x = (layout.width - item.size.width) / 2
                    y = topInset + Double(placement.lane) * lane
                }
                return Sprite(image: item.image,
                              frame: CGRect(x: x, y: y + (lane - item.size.height) / 2,
                                            width: item.size.width, height: item.size.height))
            }
        }
    }

    private func commentIsScroll(_ comment: DanmakuItem) -> Bool { comment.isScrolling }

    private func image(_ comment: DanmakuItem, size: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(comment.color):\(size):\(scale):\(comment.text)"
        if let cached = images[key] { return cached }
        guard let made = YDDanmakuText.image(comment.text, color: comment.color, size: size, scale: scale) else { return nil }
        if images.count >= 400 { images.removeAll(keepingCapacity: true) }
        images[key] = made
        return made
    }

    /// Font size scales with the shorter picture side (as the mature engine does) but is capped so
    /// a short, wide clip does not get enormous text. The chosen size also scales the lanes.
    static func fontSize(in size: CGSize, textScale: Double) -> CGFloat {
        min(44, max(15, min(size.width, size.height) * 0.04)) * textScale
    }

    private func restart(at time: Double, size: CGSize, area: YDDanmakuArea, textScale: Double,
                         spacing: Double, speed: Double, scroll: Bool, top: Bool, bottom: Bool) {
        self.size = size
        self.area = area
        self.textScale = textScale
        self.spacing = spacing
        self.speed = speed
        self.scroll = scroll
        self.top = top
        self.bottom = bottom
        fontSize = Self.fontSize(in: size, textScale: textScale)
        layout = YDDanmakuLayout(width: size.width, height: size.height * 0.96,
                                laneHeight: fontSize * spacing, scrollArea: area.share,
                                lines: area.lines, scrollDuration: 9 / speed)
        active = []
        var low = 0, high = comments.count
        while low < high {
            let mid = (low + high) / 2
            if comments[mid].time < time { low = mid + 1 } else { high = mid }
        }
        next = low
    }
}

private extension Array {
    /// First index where `belongs` becomes true, for an array sorted by it.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if belongs(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
