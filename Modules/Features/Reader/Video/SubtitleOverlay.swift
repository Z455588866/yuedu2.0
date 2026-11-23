import AVFoundation
import SwiftUI

/// Draws the active subtitle cue at the bottom of the picture. Driven from the shared
/// `PlaybackClock` (a display-rate time observer on the main queue) so text tracks playback and
/// seeks exactly without the freeze a bare `TimelineView` + `player.currentTime()` can hit.
/// Never intercepts touches.
struct SubtitleOverlay: View {
    let clock: PlaybackClock
    let entry: SubtitleEntry
    let opacity: Double
    /// Blank the video's burned-in subtitle area so our external track replaces it instead of
    /// showing two lines stacked (common in short dramas that bake Chinese/English subs in).
    let coverBuiltin: Bool

    var body: some View {
        let now = clock.time
        return GeometryReader { geo in
            let visible = cues(at: now)
            let inset = bottomInset(geo.size.height)
            ZStack(alignment: .bottom) {
                // An opaque strip across the bottom covers the burn-in subtitle behind it. It is
                // tall enough to clear the two burn-in lines and the inset our own text sits at.
                // Drawn whenever coverBuiltin is on, even between cues, so the burn-in never
                // flickers back through while a gap plays.
                if coverBuiltin {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: geo.size.width, height: coverHeight(inset))
                }
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
                    // Opaque backing so even with coverBuiltin off the text stays legible.
                    .background(Color.black.opacity(coverBuiltin ? 1 : 0.55),
                                in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, inset)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .allowsHitTesting(false)
            .opacity(opacity)
        }
        .allowsHitTesting(false)
    }

    /// Height of the black strip that hides the burn-in: from the screen bottom up past where our
    /// own text sits, plus room for the two burn-in lines it replaces.
    private func coverHeight(_ inset: Double) -> Double {
        inset + 96
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

/// Controls for the subtitle layer. A native `Menu` crams a toggle, a status label, a picker and
/// buttons into one compact popover that cannot scroll — with many sources, dragging down just
/// dismisses it ("下滑自动返回"). Instead this is a button that opens a real, scrollable `sheet`
/// with a `List`, so every option stays reachable no matter how many there are.
struct SubtitleControls: View {
    @Binding var enabled: Bool
    @Binding var selectedEntryID: String
    let entries: [SubtitleEntry]
    let sources: [OnlineSubtitleSource]
    let status: String
    let matched: Bool
    @Binding var coverBuiltin: Bool
    let onSelect: () -> Void
    let onRetry: () -> Void

    @State private var showsPanel = false

    private static let sourcePrefix = "src:"

    var body: some View {
        Button { showsPanel = true } label: {
            Image(systemName: enabled ? "captions.bubble.fill" : "captions.bubble")
                .font(DSFont.toolbarIcon)
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                .foregroundStyle(enabled ? (matched ? Color.accentColor : Color.orange) : .primary)
        }
        .accessibilityLabel(localized("字幕设置"))
        .sheet(isPresented: $showsPanel) { panel }
    }

    private var panel: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $enabled) {
                        Label(localized("字幕"), systemImage: enabled ? "captions.bubble.fill" : "captions.bubble")
                    }
                    Label(matched ? localized("已匹配到字幕") : localized("未匹配到字幕"),
                          systemImage: matched ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(matched ? Color.green : Color.secondary)
                    if !status.isEmpty {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: $coverBuiltin) {
                        Label(localized("遮盖原字幕"), systemImage: "rectangle.bottomthird.inset.filled")
                    }
                    Button {
                        onRetry()
                    } label: {
                        Label(localized("重新匹配"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                if enabled {
                    Section(localized("选择字幕")) {
                        selectRow(title: localized("自动匹配"), tag: "", systemImage: "sparkles")
                        if !sources.isEmpty {
                            ForEach(sources) { source in
                                selectRow(title: source.name,
                                          tag: Self.sourcePrefix + source.id,
                                          systemImage: "globe")
                            }
                        }
                        if !entries.isEmpty {
                            ForEach(entries) { entry in
                                selectRow(title: entry.name, tag: entry.id, systemImage: "captions.bubble")
                            }
                        }
                    }
                }
            }
            .navigationTitle(localized("字幕设置"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { showsPanel = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func selectRow(title: String, tag: String, systemImage: String) -> some View {
        Button {
            selectedEntryID = tag
            onSelect()
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if selectedEntryID == tag {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DSColor.textPrimary)
    }
}
