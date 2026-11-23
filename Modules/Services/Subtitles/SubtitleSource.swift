import Foundation
import Observation

/// One subtitle cue with its playback window, resolved from an SRT/VTT timecode.
struct SubtitleCue: Codable, Hashable, Sendable {
    var start: Double   // seconds
    var end: Double
    var text: String    // may contain \n line breaks; HTML/VTT tags already stripped
}

/// A subtitle track imported by the user. Nothing is built in — the library starts empty and is
/// filled only by import. One entry typically covers one episode; `title` + `episode` drive the
/// automatic match against the currently playing video.
struct SubtitleEntry: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Series / movie name used for matching. Compared loosely against the playing video's title.
    var title: String
    /// Episode number, when the file name carried one. nil means a movie / single-episode work.
    var episode: Int?
    var cues: [SubtitleCue]
    var enabled: Bool = true

    var cueCount: Int { cues.count }

    enum CodingKeys: String, CodingKey {
        case id, name, title, episode, cues, enabled
    }

    init(id: String, name: String, title: String, episode: Int?, cues: [SubtitleCue], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.title = title
        self.episode = episode
        self.cues = cues
        self.enabled = enabled
    }
}

/// Persists the user's imported subtitles. `@Observable` so the manager page and the player's
/// picker refresh when an import/delete happens on another screen.
@MainActor
@Observable
final class SubtitleStore {
    static let shared = SubtitleStore()

    private static let storageKey = "yd_subtitles"

    private(set) var entries: [SubtitleEntry]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([SubtitleEntry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    var enabledEntries: [SubtitleEntry] { entries.filter(\.enabled) }

    func entry(id: String) -> SubtitleEntry? { entries.first { $0.id == id } }

    /// Replaces the whole library with imported entries (import is additive against what is
    /// already there: same id replaces, new ids append). Returns the number accepted.
    @discardableResult
    func `import`(_ incoming: [SubtitleEntry]) -> Int {
        guard !incoming.isEmpty else { return 0 }
        var next = entries
        for entry in incoming {
            if let index = next.firstIndex(where: { $0.id == entry.id }) {
                next[index] = entry
            } else {
                next.append(entry)
            }
        }
        entries = next
        persist()
        return incoming.count
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].enabled = enabled
        persist()
    }

    func remove(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        persist()
    }

    func removeAll() {
        entries = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
