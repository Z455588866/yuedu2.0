import AVFoundation
import SwiftUI

/// Draws the active subtitle cue at the bottom of the picture. Driven from the shared
/// `PlaybackClock` (a display-rate time observer on the main queue) so text tracks playback and
/// seeks exactly without the freeze a bare `TimelineView` + `player.currentTime()` can hit.
/// Never intercepts touches.
///
/// Layout follows the mature approach used by production AVPlayer players (BMPlayer,
/// github.com/BrikerMan/BMPlayer — 2000★): the cue pill is bottom-aligned and its height comes
/// from its own text, never from the picture's bounds.
///
/// WHY THERE IS NO `GeometryReader` HERE: the earlier version read `geo.size` and then pinned the
/// whole overlay with `.frame(width: geo.size.width, height: geo.size.height)`. After Picture in
/// Picture restored, the layer briefly reports a stale/small geometry; that value got frozen into
/// the frame and the black cover band stretched over half the screen ("开字幕变半屏"). Turning
/// subtitles off removed the overlay from the view tree entirely, which is why it recovered — a
/// tell-tale sign the overlay itself was pinning a bad size. A content-sized, bottom-aligned
/// overlay cannot lock onto a stale geometry, so it stays correct across PiP, rotation and resize.
struct SubtitleOverlay: View {
    let clock: PlaybackClock
    let entry: SubtitleEntry
    let opacity: Double
    /// Blank the video's burned-in subtitle area so our external track replaces it instead of
    /// showing two lines stacked (common in short dramas that bake Chinese/English subs in).
    let coverBuiltin: Bool

    /// Scaled with Dynamic Type instead of being derived from the picture width — readable in
    /// full-screen landscape without ever reading the layer's (possibly stale) bounds.
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 22
    /// Height of the opaque band that hides burn-in subtitles. A fixed, scaled point value —
    /// large enough to clear two burned-in lines, never a fraction of a stale geometry.
    @ScaledMetric(relativeTo: .body) private var coverHeight: CGFloat = 96
    /// Keeps our text above the timeline/control chrome that slides up on tap.
    @ScaledMetric(relativeTo: .body) private var bottomInset: CGFloat = 64

    var body: some View {
        let visible = cues(at: clock.time)
        ZStack(alignment: .bottom) {
            // Opaque band covering the burn-in. It is bottom-aligned with a content height, so it
            // can never inflate to a half-screen black block when PiP restores a stale geometry.
            // Drawn between cues too, so the burn-in never flickers back through during a gap.
            if coverBuiltin {
                Color.black
                    .frame(height: coverHeight)
                    .frame(maxWidth: .infinity)
            }
            if !visible.isEmpty {
                VStack(spacing: 2) {
                    ForEach(visible, id: \.start) { cue in
                        Text(cue.text)
                            .font(.system(size: fontSize, weight: .semibold))
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
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, bottomInset)
            }
        }
        // Fill the available space but do not pin any absolute width/height read from the layer.
        // With no GeometryReader feedback, PiP restore / rotation / resize cannot distort it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .opacity(opacity)
    }

    /// Cues whose window contains `now`. Normally one is active, but overlapping cues (e.g.
    /// bilingual lines) are all shown. Imported files may be unsorted, so scan linearly rather
    /// than assuming an order — with a few hundred cues this is negligible, and the time observer
    /// already fixed the old "frozen subtitle" stall. The ±0.02 s tolerance keeps a cue on screen
    /// across observer ticks and at seek boundaries.
    private func cues(at now: Double) -> [SubtitleCue] {
        guard now.isFinite else { return [] }
        return entry.cues.filter { $0.start <= now + 0.02 && $0.end >= now - 0.02 }
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
