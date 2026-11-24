import AVFoundation
import Foundation
import Observation

/// Owns the danmaku state for one playing video: which source is active, the loaded track, and the
/// auto-match lifecycle. Created alongside the playback controller, driven by the book's title.
@MainActor
@Observable
final class DanmakuController {
    private enum Keys {
        static let enabled = "yd_danmaku_enabled"
        static let source = "yd_danmaku_source"
        static let opacity = "yd_danmaku_opacity"
        static let area = "yd_danmaku_area"
        static let fontSize = "yd_danmaku_fontSize"
        static let speed = "yd_danmaku_speed"
    }

    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    var selectedSourceID: String {
        didSet { defaults.set(selectedSourceID, forKey: Keys.source) }
    }
    var opacity: Double {
        didSet { defaults.set(opacity, forKey: Keys.opacity) }
    }
    /// Fraction of the picture height danmaku may cover (0.25 ... 1).
    var area: Double {
        didSet { defaults.set(area, forKey: Keys.area) }
    }
    /// Danmaku glyph size in points.
    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }
    /// Seconds a scrolling comment takes to cross the picture.
    var speed: Double {
        didSet { defaults.set(speed, forKey: Keys.speed) }
    }

    private(set) var track: DanmakuTrack?
    private(set) var status: String = ""

    private let store = DanmakuSourceStore.shared
    private let defaults: UserDefaults
    private var loadTask: Task<Void, Never>?
    private var title: String = ""
    private var episodeNumber: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Keys.enabled)
        // No built-in sources: an empty id means "use the first imported source".
        self.selectedSourceID = defaults.string(forKey: Keys.source) ?? ""
        self.opacity = {
            let raw = defaults.double(forKey: Keys.opacity)
            return raw == 0 ? 0.9 : raw
        }()
        self.area = {
            let raw = defaults.double(forKey: Keys.area)
            return raw == 0 ? 0.75 : raw
        }()
        self.fontSize = {
            let raw = defaults.double(forKey: Keys.fontSize)
            return raw == 0 ? 19 : raw
        }()
        self.speed = {
            let raw = defaults.double(forKey: Keys.speed)
            return raw == 0 ? 11 : raw
        }()
    }

    /// Starts auto-matching for a video. The title may arrive before chapters are ready, so the
    /// caller can call this again; only a changed title/number triggers a reload.
    func attach(title: String, episodeNumber: String?) {
        let changed = title != self.title || episodeNumber != self.episodeNumber
        self.title = title
        self.episodeNumber = episodeNumber
        if changed && enabled { reload() }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value {
            reload()
        } else {
            loadTask?.cancel()
            track = nil
            status = ""
        }
    }

    func reload() {
        loadTask?.cancel()
        guard enabled, !title.isEmpty else { return }
        // Snapshot the inputs before awaiting so a rapid episode switch cannot mix titles.
        let title = self.title
        let number = self.episodeNumber
        let sourceID = self.selectedSourceID
        loadTask = Task { [weak self] in
            guard let self else { return }
            let source = self.store.source(id: sourceID) ?? self.store.enabledSources.first
            guard let source else {
                self.status = localized("请先导入弹幕源")
                return
            }
            // Keep the picker in sync when we fell back to the first imported source.
            if self.selectedSourceID != source.id { self.selectedSourceID = source.id }
            self.status = "\(source.name) · 匹配中…"
            do {
                let loaded = try await DanmakuService.autoMatch(
                    title: title, episodeNumber: number, in: source
                )
                guard !Task.isCancelled else { return }
                self.track = loaded
                self.status = "\(source.name) · \(loaded.items.count) 条"
            } catch {
                guard !Task.isCancelled else { return }
                self.status = "\(source.name) · \(error.localizedDescription)"
            }
        }
    }

    /// 采用片源自带的弹幕，跳过在线匹配。
    ///
    /// 猫源（红果那类）在 `playerContent` 里直接带整集弹幕，标题还未必能在弹幕站搜到，
    /// 走 `attach` 只会白跑一次搜索再显示「没匹配到」。这里直接落地。
    ///
    /// 开关只在**从未设置过**时自动打开：用户手动关过弹幕，就不能因为换了个源又替他打开。
    func adopt(_ items: [DanmakuItem], title: String, sourceName: String) {
        loadTask?.cancel()
        guard !items.isEmpty else { return }
        track = DanmakuTrack(items: items.sorted { $0.time < $1.time },
                             episodeTitle: title,
                             animeTitle: title,
                             sourceName: sourceName)
        status = "\(sourceName) · \(items.count) 条"
        if defaults.object(forKey: Keys.enabled) == nil {
            enabled = true
        }
    }

    /// Loads an episode the person picked by hand, bypassing title matching.
    ///
    /// Auto-match is a guess; this is what replaces the guess when it is wrong. The chosen
    /// source also becomes the active one, and danmaku turn on — picking an episode is an
    /// unambiguous request to show them.
    func loadManual(source: DanmakuSource, episode: DanmakuEpisode, animeTitle: String) {
        loadTask?.cancel()
        if selectedSourceID != source.id { selectedSourceID = source.id }
        if !enabled { enabled = true }
        status = "\(source.name) · 载入中…"
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                var loaded = try await DanmakuService.comments(episodeId: episode.episodeId, in: source)
                guard !Task.isCancelled else { return }
                loaded.episodeTitle = episode.title
                loaded.animeTitle = animeTitle
                loaded.sourceName = source.name
                guard !loaded.items.isEmpty else {
                    self.status = "\(source.name) · 这一集还没有弹幕"
                    return
                }
                self.track = loaded
                self.status = "\(source.name) · \(loaded.items.count) 条"
            } catch {
                guard !Task.isCancelled else { return }
                self.status = "\(source.name) · \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        track = nil
        status = ""
    }
}
