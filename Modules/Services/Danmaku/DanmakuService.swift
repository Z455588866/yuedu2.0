import Foundation

// MARK: - Wire models (弹弹play / dandanplay compatible API)

/// Minimal shapes for the `/api/v2/*` endpoints. Unknown keys are ignored so the models survive
/// extra fields different deployments add.
struct DanmakuAnime: Sendable, Hashable {
    var animeId: Int
    var title: String
    var episodeCount: Int
    var type: String
    var imageURL: String?
}

struct DanmakuEpisode: Sendable, Hashable {
    var episodeId: Int
    var title: String
    var number: String
}

/// One comment with its playback time resolved from the `p` field.
struct DanmakuItem: Sendable, Hashable {
    var time: Double          // seconds from the start
    var text: String
    var mode: Int             // 1 = scrolling, 4 = bottom, 5 = top (弹弹play modes)
    var color: UInt32         // 0xRRGGBB
    var cid: Int

    var isScrolling: Bool { mode != 4 && mode != 5 }
}

/// A loaded danmaku track for one episode.
struct DanmakuTrack: Sendable {
    var items: [DanmakuItem]
    var episodeTitle: String
    var animeTitle: String
    var sourceName: String
}

enum DanmakuAPIError: Error, LocalizedError {
    case badSource
    case http(Int)
    case api(Int, String)
    case malformed

    var errorDescription: String? {
        switch self {
        case .badSource: return "弹幕源地址无效"
        case .http(let code): return "HTTP \(code)"
        case .api(let code, let msg): return "接口错误 \(code): \(msg)"
        case .malformed: return "返回数据格式错误"
        }
    }
}

/// Fetches danmaku from a 弹弹play-compatible service. All calls are plain GETs returning JSON;
/// they go through the App's `WebFetcher` like every other outbound request, so hooks and the
/// network debugger still see them.
enum DanmakuService {
    private static let headers: [String: String] = [
        "Accept": "application/json, text/plain, */*",
        "User-Agent": "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36",
    ]

    // MARK: Search / episodes / comments

    static func search(keyword: String, in source: DanmakuSource) async throws -> [DanmakuAnime] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let data = try await get("\(source.baseURL)/api/v2/search/anime?keyword=\(encoded)")
        let env = try decodeEnvelope(data)
        guard let list = env["animes"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let id = dict.int("animeId") else { return nil }
            return DanmakuAnime(
                animeId: id,
                title: dict.string("animeTitle") ?? "",
                episodeCount: dict.int("episodeCount") ?? 0,
                type: dict.string("typeDescription") ?? dict.string("type") ?? "",
                imageURL: dict.string("imageUrl")
            )
        }
    }

    static func episodes(animeId: Int, in source: DanmakuSource) async throws -> [DanmakuEpisode] {
        let data = try await get("\(source.baseURL)/api/v2/bangumi/\(animeId)")
        let env = try decodeEnvelope(data)
        guard let bangumi = env["bangumi"] as? [String: Any],
              let list = bangumi["episodes"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict in
            guard let id = dict.int("episodeId") else { return nil }
            return DanmakuEpisode(
                episodeId: id,
                title: dict.string("episodeTitle") ?? "",
                number: dict.string("episodeNumber") ?? ""
            )
        }
    }

    static func comments(episodeId: Int, in source: DanmakuSource) async throws -> DanmakuTrack {
        let data = try await get("\(source.baseURL)/api/v2/comment/\(episodeId)?format=json")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["comments"] as? [[String: Any]] else {
            throw DanmakuAPIError.malformed
        }
        var items: [DanmakuItem] = []
        items.reserveCapacity(list.count)
        for dict in list {
            guard let raw = dict.string("p"),
                  let text = dict.string("m"), !text.isEmpty else { continue }
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = parts.first, let time = Double(first), time >= 0 else { continue }
            let mode = (parts.count > 1 ? Int(parts[1]) : nil) ?? 1
            let color = (parts.count > 2 ? UInt32(parts[2]) : nil) ?? 0xFFFFFF
            items.append(DanmakuItem(
                time: time, text: text, mode: mode, color: color,
                cid: dict.int("cid") ?? items.count + 1
            ))
        }
        // The overlay walks items in time order and stops past its window, so guarantee order.
        items.sort { $0.time < $1.time }
        return DanmakuTrack(items: items, episodeTitle: "", animeTitle: "", sourceName: source.name)
    }

    // MARK: Auto match

    /// Finds the best anime for a video title, then the episode matching `episodeNumber`, and
    /// loads its danmaku. Falls back to the first anime / episode index when nothing matches.
    static func autoMatch(title: String, episodeNumber: String?,
                          in source: DanmakuSource) async throws -> DanmakuTrack {
        var query = cleanTitle(title)
        var animes = try await search(keyword: query, in: source)
        // A full title with episode markers often finds nothing; retry on the leading name.
        if animes.isEmpty, let shorter = primaryName(of: query), shorter != query {
            query = shorter
            animes = try await search(keyword: query, in: source)
        }
        guard let anime = bestMatch(for: query, among: animes) else { throw DanmakuAPIError.malformed }

        let eps = try await episodes(animeId: anime.animeId, in: source)
        guard !eps.isEmpty else { throw DanmakuAPIError.malformed }

        let episode = pickEpisode(number: episodeNumber, among: eps)
        var track = try await comments(episodeId: episode.episodeId, in: source)
        track.episodeTitle = episode.title
        track.animeTitle = anime.title
        track.sourceName = source.name
        return track
    }

    // MARK: Helpers

    /// The video title is often `剧名 第1集`, a filename with extension, or a source suffix.
    /// Keep the part useful for a danmaku search.
    static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a file extension and common release tags after the name.
        if let ext = s.lastIndex(of: "."), s.distance(from: ext, to: s.endIndex) <= 5 {
            s = String(s[..<ext])
        }
        let separators = CharacterSet(charactersIn: "【[（(／/")
        if let cut = s.firstIndex(where: { $0.unicodeScalars.contains { separators.contains($0) } }) {
            let head = String(s[..<cut]).trimmingCharacters(in: .whitespaces)
            if head.count >= 2 { s = head }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Leading name before an episode/season marker, used as a looser retry query.
    private static func primaryName(of title: String) -> String? {
        let patterns = [#"(S\d{1,2})"#, #"第\s?\d+\s?[集话話]"#, #"\bE\d{1,3}\b"#, #"\d{1,2}x\d{1,3}"#]
        for pattern in patterns {
            if let range = title.range(of: pattern, options: .regularExpression) {
                let head = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if head.count >= 2 { return head }
            }
        }
        return nil
    }

    private static func bestMatch(for query: String, among animes: [DanmakuAnime]) -> DanmakuAnime? {
        guard !animes.isEmpty else { return nil }
        let needle = cleanTitle(query)
        // Prefer a title whose cleaned name starts with the query (same series, different season).
        if let exact = animes.first(where: {
            cleanTitle($0.title) == needle || cleanTitle($0.title).hasPrefix(needle)
        }) {
            return exact
        }
        if let contains = animes.first(where: { $0.title.contains(needle) || needle.contains(cleanTitle($0.title)) }) {
            return contains
        }
        return animes.first
    }

    private static func pickEpisode(number: String?, among episodes: [DanmakuEpisode]) -> DanmakuEpisode {
        if let number, !number.isEmpty {
            if let match = episodes.first(where: { $0.number == number }) { return match }
            // "01" vs "1"
            let normalized = Int(number)
            if let match = episodes.first(where: { Int($0.number) == normalized }) { return match }
        }
        return episodes[0]
    }

    // MARK: Transport

    private static func get(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw DanmakuAPIError.badSource }
        let page = try await WebFetcher.shared.fetchPage(
            url: url, method: "GET", body: nil, headers: headers, baseURL: ""
        )
        guard (200...299).contains(page.statusCode) else { throw DanmakuAPIError.http(page.statusCode) }
        return page.data
    }

    private static func decodeEnvelope(_ data: Data) throws -> [String: Any] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DanmakuAPIError.malformed
        }
        if let code = json["errorCode"] as? Int, code != 0 {
            let msg = json["errorMessage"] as? String ?? ""
            throw DanmakuAPIError.api(code, msg)
        }
        return json
    }
}

// MARK: - Small JSON accessors

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        self[key] as? String
    }
    func int(_ key: String) -> Int? {
        if let n = self[key] as? Int { return n }
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
}

/// Resolves an episode number from a video's chapter title, e.g. "第12集" -> "12".
enum DanmakuEpisodeNumber {
    static func from(_ title: String) -> String? {
        let patterns = [#"第\s*(\d+)\s*[集话話]"#, #"\bE(?:P)?\s?(\d{1,3})\b"#, #"(\d{1,2})x(\d{1,3})"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(title.startIndex..., in: title)
            if let match = regex.firstMatch(in: title, range: range), match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: title) {
                if pattern.contains("x"), match.numberOfRanges >= 3,
                   let r2 = Range(match.range(at: 2), in: title) {
                    return String(title[r2])
                }
                return String(title[r])
            }
        }
        return nil
    }
}
