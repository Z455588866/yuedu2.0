import AVFoundation
import SwiftUI

/// Draws the active subtitle cue at the bottom of the picture. Driven straight from
/// `AVPlayer.currentTime()` inside a `TimelineView` so text tracks seeks and playback exactly,
/// rather than the controller's once-a-second `currentTime`. Never intercepts touches.
struct SubtitleOverlay: View {
    let player: AVPlayer
    let entry: SubtitleEntry
    let opacity: Double

    var body: some View {
        TimelineView(.animation) { _ in
            GeometryReader { geo in
                let now = player.currentTime().seconds
                let visible = cues(at: now)
                ZStack(alignment: .bottom) {
                    if !visible.isEmpty {
                        VStack(spacing: 2) {
                            ForEach(visible, id: \.start) { cue in
                                Text(cue.text)
                                    .font(.system(size: subtitleSize(geo.size.width), weight: .semibold))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .shadow(color: .black.opacity(0.95), radius: 2, x: 0, y: 1)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, bottomInset(geo.size.height))
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                .allowsHitTesting(false)
                .opacity(opacity)
            }
        }
        .allowsHitTesting(false)
    }

    /// Cues whose window contains `now`. Subtitles are sorted by time; normally one is active,
    /// but overlapping cues (e.g. bilingual lines) are all shown.
    private func cues(at now: Double) -> [SubtitleCue] {
        guard now.isFinite else { return [] }
        return entry.cues.filter { $0.start <= now + 0.02 && $0.end >= now - 0.02 }
    }

    private func subtitleSize(_ width: Double) -> CGFloat {
        // Scale with the picture so it stays readable in full-screen landscape.
        if width >= 900 { return 26 }
        if width >= 600 { return 22 }
        return 18
    }

    private func bottomInset(_ height: Double) -> Double {
        // Keep the subtitle above the timeline/control chrome that slides up on tap.
        min(120, max(64, height * 0.14))
    }
}

/// Controls for the subtitle layer: an on/off toggle and a picker over auto-match, imported local
/// entries, and imported online sources (tagged `src:<id>`). Rendered in the player's top bar.
struct SubtitleControls: View {
    @Binding var enabled: Bool
    @Binding var selectedEntryID: String
    let entries: [SubtitleEntry]
    let sources: [OnlineSubtitleSource]
    let status: String
    let onSelect: () -> Void

    private static let sourcePrefix = "src:"

    var body: some View {
        Menu {
            Toggle(isOn: $enabled) {
                Label(localized("字幕"), systemImage: enabled ? "captions.bubble.fill" : "captions.bubble")
            }
            if enabled {
                Divider()
                Picker(localized("字幕"), selection: $selectedEntryID) {
                    Text(localized("自动匹配")).tag("")
                    if !sources.isEmpty {
                        Section(localized("在线字幕源")) {
                            ForEach(sources) { source in
                                Text(source.name).tag(Self.sourcePrefix + source.id)
                            }
                        }
                    }
                    if !entries.isEmpty {
                        Section(localized("本地字幕")) {
                            ForEach(entries) { entry in
                                Text(entry.name).tag(entry.id)
                            }
                        }
                    }
                }
                .onChange(of: selectedEntryID) { _, _ in onSelect() }
                if !status.isEmpty {
                    Divider()
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
        } label: {
            Image(systemName: enabled ? "captions.bubble.fill" : "captions.bubble")
                .font(DSFont.toolbarIcon)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .foregroundStyle(enabled ? Color.accentColor : .primary)
        }
        .accessibilityLabel(localized("字幕设置"))
    }
}
