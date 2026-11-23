import AVFoundation
import Foundation
import Observation

/// Owns the subtitle state for one playing video: whether subtitles are on, which entry/source is
/// active (pinned or auto-matched), and the cues to draw. Subtitles can come from a locally
/// imported .srt/.vtt file or, like danmaku, from an imported online subtitle source that is
/// fetched on demand — so resolving is asynchronous for the online case.
@MainActor
@Observable
final class SubtitleController {
    private enum Keys {
        static let enabled = "yd_subtitle_enabled"
        /// "" = auto-match, "src:<id>" = pinned online source, otherwise a local entry id.
        static let selection = "yd_subtitle_entry"
        /// Whether to blank the video's burn-in/built-in subtitle area before drawing ours.
        static let coverBuiltin = "yd_subtitle_cover_builtin"
    }
    private static let sourcePrefix = "src:"

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    /// Draw an opaque bar over the video's own (burned-in) subtitle so our external track replaces
    /// it instead of stacking two lines. Defaults to on; users can switch it off for videos with
    /// no built-in subtitles.
    var coverBuiltin: Bool {
        didSet { defaults.set(coverBuiltin, forKey: Keys.coverBuiltin) }
    }
    /// The user's pick. Empty means "auto-match"; a `src:` value pins an online source; any other
    /// value pins one imported local entry. Reuses the old key so existing preferences survive.
    var selectedEntryID: String {
        didSet { defaults.set(selectedEntryID, forKey: Keys.selection) }
    }

    private(set) var activeEntry: SubtitleEntry?
    private(set) var status: String = ""

    private let store = SubtitleStore.shared
    private let onlineStore = OnlineSubtitleSourceStore.shared
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
    private var title: String = ""
    private var episodeNumber: Int?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Keys.enabled)
        self.selectedEntryID = defaults.string(forKey: Keys.selection) ?? ""
        // Default on: most short dramas carry a burn-in subtitle that the external track should
        // replace. `object(forKey:)` distinguishes "never set" from an explicit false.
        if defaults.object(forKey: Keys.coverBuiltin) == nil {
            self.coverBuiltin = true
        } else {
            self.coverBuiltin = defaults.bool(forKey: Keys.coverBuiltin)
        }
    }

    /// Starts matching for a video. The title may arrive before chapters are ready, so the caller
    /// can call again; only a changed title/episode triggers a reload.
    func attach(title: String, episodeNumber: Int?) {
        let changed = title != self.title || episodeNumber != self.episodeNumber
        self.title = title
        self.episodeNumber = episodeNumber
        if changed { resolve() }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value { resolve() } else { stop() }
    }

    /// Re-resolves which subtitle is active. A pinned pick wins; auto mode prefers a local match
    /// and falls back to the first enabled online source. Auto never re-pins itself, so switching
    /// episodes always re-matches (unlike a manual pick, which is intentionally stable).
    func resolve() {
        loadTask?.cancel()
        guard enabled, !title.isEmpty else { clear(); return }
        let selection = selectedEntryID
        let title = self.title
        let number = self.episodeNumber

        // Pinned online source: (re)fetch on every resolve so a new episode gets its own track.
        if selection.hasPrefix(Self.sourcePrefix) {
            let id = String(selection.dropFirst(Self.sourcePrefix.count))
            guard let source = onlineStore.source(id: id), source.enabled else {
                activeEntry = nil
                status = localized("字幕源不可用")
                return
            }
            loadOnline(source: source, title: title, number: number)
            return
        }

        // Pinned local entry.
        if !selection.isEmpty {
            if let pinned = store.entry(id: selection), pinned.enabled {
                activeEntry = pinned
                status = "\(pinned.name) · \(pinned.cueCount) 条"
            } else {
                activeEntry = nil
                status = localized("没有匹配的字幕")
            }
            return
        }

        // Auto: a local match first.
        if let local = SubtitleService.match(title: title, episodeNumber: number,
                                             among: store.enabledEntries) {
            activeEntry = local
            status = "\(local.name) · \(local.cueCount) 条"
            return
        }
        // Otherwise fall back to the first enabled online source.
        if let source = onlineStore.enabledSources.first {
            loadOnline(source: source, title: title, number: number)
        } else {
            activeEntry = nil
            status = store.entries.isEmpty && onlineStore.sources.isEmpty
                ? localized("请先导入字幕或在线字幕源")
                : localized("没有匹配的字幕")
        }
    }

    /// Call after either library changes on another screen so the player picks up new imports.
    func libraryDidChange() { resolve() }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        clear()
    }

    // MARK: - Online fetch

    private func loadOnline(source: OnlineSubtitleSource, title: String, number: Int?) {
        activeEntry = nil
        status = "\(source.name) · 匹配中…"
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let entry = try await OnlineSubtitleService.autoMatch(
                    title: title, episodeNumber: number, in: source
                )
                guard !Task.isCancelled else { return }
                self.activeEntry = entry
                self.status = "\(entry.name) · \(entry.cueCount) 条"
            } catch {
                guard !Task.isCancelled else { return }
                self.activeEntry = nil
                self.status = "\(source.name) · \(error.localizedDescription)"
            }
        }
    }

    private func clear() {
        activeEntry = nil
        status = ""
    }
}
