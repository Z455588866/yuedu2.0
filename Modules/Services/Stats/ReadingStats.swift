import Foundation
import Combine

// MARK: - ReadingSession

struct ReadingSession: Codable, Identifiable {
    let id: UUID
    let bookId: String
    let bookTitle: String
    let startDate: Date
    let duration: TimeInterval
    let charactersRead: Int
}

// MARK: - ReadingStatsSessionTracker

struct ReadingStatsTrackingPosition: Equatable, Sendable {
    enum CharacterScope: Equatable, Sendable {
        case global
        case spine(Int)
    }

    let characterScope: CharacterScope
    let characterOffset: Int
    let globalContentUnitOffset: Int?

    static func spine(
        _ spineIndex: Int,
        characterOffset: Int,
        globalContentUnitOffset: Int? = nil
    ) -> Self {
        Self(
            characterScope: .spine(spineIndex),
            characterOffset: characterOffset,
            globalContentUnitOffset: globalContentUnitOffset
        )
    }

    static func global(
        characterOffset: Int,
        globalContentUnitOffset: Int? = nil
    ) -> Self {
        Self(
            characterScope: .global,
            characterOffset: characterOffset,
            globalContentUnitOffset: globalContentUnitOffset
        )
    }
}

struct ReadingStatsSessionTracker {
    static let maximumContinuousAdvance = 50_000

    let bookId: String
    let bookTitle: String
    let startDate: Date
    private var baselinePosition: ReadingStatsTrackingPosition?
    private var baselineContentUnitOffset: Int?
    private var accumulatedCharactersRead = 0
    private var accumulatedContentUnitsRead = 0

    init(
        bookId: String,
        bookTitle: String,
        startDate: Date = Date(),
        startPosition: ReadingStatsTrackingPosition? = nil
    ) {
        self.bookId = bookId
        self.bookTitle = bookTitle
        self.startDate = startDate
        self.baselinePosition = startPosition
        self.baselineContentUnitOffset = startPosition?.globalContentUnitOffset
    }

    mutating func updateVisiblePosition(_ position: ReadingStatsTrackingPosition?) {
        guard let position else { return }
        guard position.characterOffset >= 0 else {
            baselinePosition = nil
            baselineContentUnitOffset = nil
            return
        }

        let priorPosition = baselinePosition
        baselinePosition = position
        if let priorPosition,
           priorPosition.characterScope == position.characterScope {
            accumulatedCharactersRead = Self.accumulating(
                from: priorPosition.characterOffset,
                to: position.characterOffset,
                onto: accumulatedCharactersRead
            )
        }

        let priorContentUnitOffset = baselineContentUnitOffset
        baselineContentUnitOffset = position.globalContentUnitOffset
        if let priorContentUnitOffset,
           let contentUnitOffset = position.globalContentUnitOffset {
            accumulatedContentUnitsRead = Self.accumulating(
                from: priorContentUnitOffset,
                to: contentUnitOffset,
                onto: accumulatedContentUnitsRead
            )
        }
    }

    mutating func relocate(to position: ReadingStatsTrackingPosition?) {
        guard let position, position.characterOffset >= 0 else {
            baselinePosition = nil
            baselineContentUnitOffset = nil
            return
        }
        baselinePosition = position
        baselineContentUnitOffset = position.globalContentUnitOffset
    }

    func currentMetrics(at date: Date = Date()) -> (elapsed: TimeInterval, charactersRead: Int) {
        let rawElapsed = date.timeIntervalSince(startDate)
        let elapsed = rawElapsed.isFinite ? max(0, rawElapsed) : 0
        return (elapsed, accumulatedCharactersRead)
    }

    func currentPaceMetrics(
        at date: Date = Date()
    ) -> (elapsed: TimeInterval, contentUnitsRead: Int) {
        let rawElapsed = date.timeIntervalSince(startDate)
        let elapsed = rawElapsed.isFinite ? max(0, rawElapsed) : 0
        return (elapsed, accumulatedContentUnitsRead)
    }

    func finish(at endDate: Date = Date()) -> ReadingSession? {
        let duration = endDate.timeIntervalSince(startDate)
        guard duration > 0 else { return nil }

        return ReadingSession(
            id: UUID(),
            bookId: bookId,
            bookTitle: bookTitle,
            startDate: startDate,
            duration: duration,
            charactersRead: accumulatedCharactersRead
        )
    }

    private static func accumulating(
        from baseline: Int,
        to offset: Int,
        onto total: Int
    ) -> Int {
        let (delta, overflow) = offset.subtractingReportingOverflow(baseline)
        guard !overflow,
              delta > 0,
              delta <= Self.maximumContinuousAdvance
        else {
            return total
        }

        let (next, totalOverflow) = total.addingReportingOverflow(delta)
        return totalOverflow ? .max : next
    }
}

// MARK: - ReadingStatsStore

/// File-scope so the nonisolated `Codable` decoder below can bound an old or
/// hand-edited goal without crossing into the store's MainActor isolation.
private func boundedReadingGoal(_ minutes: Int) -> Int {
    min(ReadingStatsStore.maximumDailyGoalMinutes,
        max(ReadingStatsStore.minimumDailyGoalMinutes, minutes))
}

@MainActor
class ReadingStatsStore: ObservableObject {
    static let shared = ReadingStatsStore()

    @Published var sessions: [ReadingSession] = []

    // MARK: - Daily goal & streak

    /// Reader-settable daily target, in whole minutes. The bounds keep a mistyped
    /// value from making the goal impossible or the progress bar meaningless.
    static let minimumDailyGoalMinutes = 5
    static let maximumDailyGoalMinutes = 240
    static let defaultDailyGoalMinutes = 30

    @Published var dailyGoalMinutes: Int = ReadingStatsStore.defaultDailyGoalMinutes {
        didSet {
            let bounded = boundedReadingGoal(dailyGoalMinutes)
            if bounded != dailyGoalMinutes { dailyGoalMinutes = bounded }
        }
    }

    private static let defaultFileURL: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return lib.appendingPathComponent("reading_stats.json")
    }()

    private let fileURL: URL

    init(fileURL: URL = ReadingStatsStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: - Public API

    func recordSession(_ session: ReadingSession) {
        sessions.append(session)
        save()
    }

    func startSession(bookId: String, bookTitle: String) -> Date {
        return Date()
    }

    func endSession(startTime: Date, bookId: String, bookTitle: String, charactersRead: Int) {
        let duration = Date().timeIntervalSince(startTime)
        let session = ReadingSession(
            id: UUID(),
            bookId: bookId,
            bookTitle: bookTitle,
            startDate: startTime,
            duration: duration,
            charactersRead: charactersRead
        )
        recordSession(session)
    }

    /// Sessions starting in the half-open interval `[from, to)`. The upper bound is
    /// exclusive so a session at exactly `00:00:00` belongs to the next day only,
    /// never to both — `readingMinutes(on:)` passes the following day's start as `to`.
    func sessionsInRange(from: Date, to: Date) -> [ReadingSession] {
        sessions.filter { $0.startDate >= from && $0.startDate < to }
    }

    func totalDuration(in sessions: [ReadingSession]) -> TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    func totalCharacters(in sessions: [ReadingSession]) -> Int {
        sessions.reduce(0) { $0 + $1.charactersRead }
    }

    func topBooks(limit: Int, sessions: [ReadingSession]) -> [(bookTitle: String, duration: TimeInterval)] {
        var durationByTitle: [String: TimeInterval] = [:]
        for session in sessions {
            durationByTitle[session.bookTitle, default: 0] += session.duration
        }
        return durationByTitle
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (bookTitle: $0.key, duration: $0.value) }
    }

    /// Persists a new daily target alongside the sessions. Local file only.
    func setDailyGoalMinutes(_ minutes: Int) {
        let bounded = boundedReadingGoal(minutes)
        guard bounded != dailyGoalMinutes else { return }
        dailyGoalMinutes = bounded
        save()
    }

    /// Whole minutes read on `date` in the device's current calendar.
    func readingMinutes(on date: Date = Date(), calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)
            ?? start.addingTimeInterval(24 * 60 * 60)
        let seconds = sessionsInRange(from: start, to: end).reduce(0) { $0 + $1.duration }
        return seconds.isFinite ? max(0, Int(seconds / 60)) : 0
    }

    /// Consecutive days with at least one recorded session, ending today — or,
    /// before today's first session, yesterday. A day without reading breaks it.
    func currentStreakDays(now: Date = Date(), calendar: Calendar = .current) -> Int {
        var activeDays = Set<Date>()
        for session in sessions where session.duration > 0 {
            activeDays.insert(calendar.startOfDay(for: session.startDate))
        }
        guard !activeDays.isEmpty else { return 0 }

        var cursor = calendar.startOfDay(for: now)
        if !activeDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                  activeDays.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor),
                  previous < cursor else { break }
            cursor = previous
        }
        return streak
    }

    // MARK: - Persistence

    /// One local file holds sessions and the reader's target. Files written by older
    /// builds are a bare `[ReadingSession]` array and are still accepted below.
    private struct ReadingStatsFile: Codable {
        var sessions: [ReadingSession] = []
        var dailyGoalMinutes: Int = ReadingStatsStore.defaultDailyGoalMinutes

        private enum CodingKeys: String, CodingKey {
            case sessions, dailyGoalMinutes
        }

        init(sessions: [ReadingSession], dailyGoalMinutes: Int) {
            self.sessions = sessions
            self.dailyGoalMinutes = boundedReadingGoal(dailyGoalMinutes)
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sessions = try values.decodeIfPresent([ReadingSession].self, forKey: .sessions) ?? []
            dailyGoalMinutes = boundedReadingGoal(
                try values.decodeIfPresent(Int.self, forKey: .dailyGoalMinutes)
                    ?? ReadingStatsStore.defaultDailyGoalMinutes
            )
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            do {
                let file = try JSONDecoder().decode(ReadingStatsFile.self, from: data)
                sessions = file.sessions
                dailyGoalMinutes = file.dailyGoalMinutes
            } catch {
                // Legacy format: a bare array of sessions, written before the goal existed.
                sessions = try JSONDecoder().decode([ReadingSession].self, from: data)
            }
        } catch {
            // A missing or damaged stats file must not interrupt reading, but the
            // failure is no longer invisible in the exported diagnostic log.
            AppLogger.error(
                "[ReadingStats] 读取统计失败",
                error: error,
                context: ["file": fileURL.lastPathComponent],
                level: .error
            )
        }
    }

    private func save() {
        let file = ReadingStatsFile(sessions: sessions, dailyGoalMinutes: dailyGoalMinutes)
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.error(
                "[ReadingStats] 写入统计失败",
                error: error,
                context: ["file": fileURL.lastPathComponent],
                level: .error
            )
        }
    }
}
