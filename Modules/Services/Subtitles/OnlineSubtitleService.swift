import Foundation

/// One subtitle file resolved from an online provider.
struct OnlineSubtitleItem: Sendable, Hashable {
    var id: Int
    var language: String
    var releaseName: String
    var downloadURL: String
    var format: String
}

enum OnlineSubtitleAPIError: Error, LocalizedError {
    case badSource
    case http(Int)
    case malformed
    case noSubtitles

    var errorDescription: String? {
        switch self {
        case .badSource: return "字幕源地址无效"
        case .http(let code): return "HTTP \(code)"
        case .malformed: return "返回数据格式错误"
        case .noSubtitles: return "没有匹配的字幕"
        }
    }
}

/// Fetches subtitles from a thesubtitledb-compatible service. One `by-title` request returns the
/// matched work, its season/episode tree, and the subtitle items; the best item (episode + language)
/// is downloaded and parsed with the same `SubtitleService` used for local files, then handed to
/// the player as a normal `SubtitleEntry`. All traffic goes through `WebFetcher` like danmaku.
enum OnlineSubtitleService {
    private static let headers: [String: String] = [
        "Accept": "application/json, text/plain, */*",
        "User-Agent": "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0 Mobile Safari/537.36",
    ]

    private struct Candidate {
        var item: OnlineSubtitleItem
        var episode: Int?
    }

    /// Entry point: dispatches to the protocol the imported source declares. Unknown/old configs
    /// arrive as `.thesubtitledb`, so existing imports keep working unchanged.
    static func autoMatch(title: String, episodeNumber: Int?,
                          in source: OnlineSubtitleSource) async throws -> SubtitleEntry {
        switch source.apiType {
        case .wyzie:
            return try await autoMatchWyzie(title: title, episodeNumber: episodeNumber, in: source)
        case .thesubtitledb:
            return try await autoMatchTheSubtitleDB(title: title, episodeNumber: episodeNumber, in: source)
        }
    }

    /// theSubtitleDB: search by the cleaned series name, pick the item matching episode + language.
    private static func autoMatchTheSubtitleDB(title: String, episodeNumber: Int?,
                          in source: OnlineSubtitleSource) async throws -> SubtitleEntry {
        let query = primaryName(of: cleanTitle(title))
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let base = source.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let data = try await get("\(base)/v1/by-title?q=\(encoded)")
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OnlineSubtitleAPIError.malformed
        }
        let resolvedName = ((json["match"] as? [String: Any])?["name"] as? String)
            ?? ((json["title"] as? [String: Any])?["name"] as? String)
            ?? query

        var candidates: [Candidate] = []

        // Season/episode tree carries an exact episode number — the most reliable signal.
        if let seasons = json["seasons"] as? [[String: Any]] {
            for season in seasons {
                guard let episodes = season["episodes"] as? [[String: Any]] else { continue }
                for episode in episodes {
                    let number = episode.int("episode")
                    guard let items = (episode["subtitles"] as? [String: Any])?["items"] as? [[String: Any]]
                    else { continue }
                    for dict in items {
                        if let item = parseItem(dict) {
                            candidates.append(Candidate(item: item, episode: number))
                        }
                    }
                }
            }
        }

        // Top-level items often carry "E04" in the release name; treat as additional candidates.
        if let items = (json["subtitles"] as? [String: Any])?["items"] as? [[String: Any]] {
            for dict in items {
                if let item = parseItem(dict) {
                    candidates.append(Candidate(item: item, episode: episodeInRelease(item.releaseName)))
                }
            }
        }

        guard !candidates.isEmpty else { throw OnlineSubtitleAPIError.noSubtitles }

        let preferred = source.language.lowercased()
        func rank(_ candidate: Candidate) -> Int {
            var score = 0
            if let number = episodeNumber, let episode = candidate.episode {
                score += (episode == number) ? 100 : -60
            }
            if language(candidate.item.language, matches: preferred) {
                score += 40
            } else if preferred != "zh" && language(candidate.item.language, matches: "en") {
                score += 10
            }
            return score
        }
        let sorted = candidates.sorted { rank($0) > rank($1) }
        guard let chosen = sorted.first else { throw OnlineSubtitleAPIError.noSubtitles }

        let srtData = try await get(chosen.item.downloadURL)
        let cues = try SubtitleService.parse(data: srtData)
        guard !cues.isEmpty else { throw OnlineSubtitleAPIError.noSubtitles }

        let episodeText = chosen.episode.map { String(format: "第 %d 集", $0) }
        let name = [resolvedName, episodeText, chosen.item.language.uppercased()]
            .compactMap { $0 }.joined(separator: " · ")
        return SubtitleEntry(
            id: "online:\(source.id):\(chosen.item.id)",
            name: name,
            title: resolvedName,
            episode: chosen.episode ?? episodeNumber,
            cues: cues
        )
    }

    // MARK: Parsing helpers

    private static func parseItem(_ dict: [String: Any]) -> OnlineSubtitleItem? {
        guard let id = dict.int("id"),
              let url = dict.string("download_url"), !url.isEmpty else { return nil }
        return OnlineSubtitleItem(
            id: id,
            language: dict.string("language") ?? "",
            releaseName: dict.string("release_name") ?? "",
            downloadURL: url,
            format: dict.string("format") ?? "srt"
        )
    }

    // MARK: - Wyzie protocol

    /// Wyzie (open source, aggregates OpenSubtitles/SubDL/Subscene) searches by IMDB id, not title.
    /// Bridge a (possibly Chinese) title to an IMDB id via theSubtitleDB's keyless `by-title`, then
    /// query the source's wyzie base URL with the user-supplied free key. The returned array items
    /// carry a ready `url`; we rank by language + format and download through the same transport.
    private static func autoMatchWyzie(title: String, episodeNumber: Int?,
                                       in source: OnlineSubtitleSource) async throws -> SubtitleEntry {
        let query = primaryName(of: cleanTitle(title))
        let base = source.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = source.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OnlineSubtitleAPIError.badSource }

        // 1) title -> IMDB id. theSubtitleDB handles Chinese names well and is keyless.
        let imdb = try await imdbID(for: query)
        guard let imdb, !imdb.isEmpty else { throw OnlineSubtitleAPIError.noSubtitles }

        // 2) build wyzie search. season+episode must be passed together (its API rejects one alone).
        guard var components = URLComponents(string: "\(base)/search") else {
            throw OnlineSubtitleAPIError.badSource
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "id", value: imdb),
            URLQueryItem(name: "language", value: normalizedLanguage(source.language)),
            URLQueryItem(name: "format", value: "srt"),
            URLQueryItem(name: "key", value: key),
        ]
        if let episodeNumber {
            items.append(URLQueryItem(name: "season", value: "1"))
            items.append(URLQueryItem(name: "episode", value: String(episodeNumber)))
        }
        components.queryItems = items
        guard let searchURL = components.url else { throw OnlineSubtitleAPIError.badSource }
        let data = try await get(searchURL.absoluteString)

        // 3) wyzie returns a JSON array of tracks.
        guard let tracks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw OnlineSubtitleAPIError.malformed
        }
        let preferred = source.language.lowercased()
        func trackLanguage(_ t: [String: Any]) -> String {
            t.string("language") ?? t.string("lang") ?? ""
        }
        func score(_ t: [String: Any]) -> Int {
            var s = 0
            if language(trackLanguage(t), matches: preferred) { s += 40 }
            let fmt = (t.string("format") ?? "srt").lowercased()
            if fmt == "srt" { s += 20 } else if fmt == "vtt" { s += 10 }
            if t.string("url")?.isEmpty == false { s += 1 }
            return s
        }
        guard let best = tracks.max(by: { score($0) < score($1) }),
              let url = best.string("url"), !url.isEmpty else {
            throw OnlineSubtitleAPIError.noSubtitles
        }

        // 4) download (wyzie download URLs are public; if a key query is needed, append it).
        let srtData: Data
        if url.contains("key=") {
            srtData = try await get(url)
        } else {
            srtData = try await getWithFallback(url, key: key)
        }
        let cues = try SubtitleService.parse(data: srtData)
        guard !cues.isEmpty else { throw OnlineSubtitleAPIError.noSubtitles }

        let resolvedName = best.string("media") ?? query
        let trackLang = trackLanguage(best).uppercased()
        let episodeText = episodeNumber.map { String(format: "第 %d 集", $0) }
        let name = [resolvedName, episodeText, trackLang].compactMap { $0 }.joined(separator: " · ")
        let trackID = best.string("id") ?? (url as NSString).lastPathComponent
        return SubtitleEntry(
            id: "online:\(source.id):\(trackID)",
            name: name,
            title: resolvedName,
            episode: episodeNumber,
            cues: cues
        )
    }

    /// Resolve a series title to an IMDB id. theSubtitleDB is keyless and covers Chinese titles;
    /// its response exposes `match.imdb` / `title.imdb`. IMDb's public suggest JSON is the fallback
    /// for Latin titles when theSubtitleDB has no match.
    private static func imdbID(for query: String) async throws -> String? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let data = try? await get("https://api.thesubtitledb.org/v1/by-title?q=\(encoded)"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let imdb = ((json["match"] as? [String: Any])?["imdb"] as? String)
                ?? ((json["title"] as? [String: Any])?["imdb"] as? String)
            if let imdb, imdb.hasPrefix("tt") { return imdb }
        }
        // Fallback: IMDb suggest endpoint, keyed by the first letter of the query.
        let first = String(query.prefix(1)).lowercased()
        let path = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
        if let data = try? await get("https://v2.sg.media-imdb.com/suggestion/\(first)/\(path).json"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["d"] as? [[String: Any]] {
            for item in list {
                if let id = item["id"] as? String, id.hasPrefix("tt") { return id }
            }
        }
        return nil
    }

    /// Normalize our language codes to wyzie's ISO-639-1 form (ZH -> zh, etc.).
    private static func normalizedLanguage(_ code: String) -> String {
        let c = code.lowercased()
        if c.hasPrefix("zh") || c == "cn" { return "zh" }
        return c
    }

    /// Download a wyzie URL directly; on 401/403 retry with the key appended as a query param.
    private static func getWithFallback(_ address: String, key: String) async throws -> Data {
        do {
            return try await get(address)
        } catch OnlineSubtitleAPIError.http(let code) where code == 401 || code == 403 {
            let separator = address.contains("?") ? "&" : "?"
            return try await get("\(address)\(separator)key=\(key)")
        }
    }

    /// A video title is often `剧名 第3集` or a file name. Keep only the leading series name for
    /// the search query; episode selection happens against the returned season tree.
    static func cleanTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func primaryName(of title: String) -> String {
        var s = title
        let patterns = [#"(S\d{1,2})"#, #"第\s?\d+\s?[集话話]"#, #"\bE\d{1,3}\b"#, #"\d{1,2}x\d{1,3}"#]
        for pattern in patterns {
            if let range = s.range(of: pattern, options: .regularExpression) {
                let head = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if head.count >= 2 { s = head }
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func episodeInRelease(_ name: String) -> Int? {
        let patterns = [#"S\d{1,2}E(\d{1,3})"#, #"(?:^|[^A-Za-z])E(\d{1,3})(?:[^0-9]|$)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            else { continue }
            let range = NSRange(name.startIndex..., in: name)
            if let match = regex.firstMatch(in: name, range: range), match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: name), let value = Int(name[r]) {
                return value
            }
        }
        return nil
    }

    /// Chinese tracks appear under several codes (zh / ze / zt …); treat them as one family so a
    /// source configured as `zh` still picks a simplified track labelled `ze`.
    private static func language(_ code: String, matches requested: String) -> Bool {
        let c = code.lowercased()
        let r = requested.lowercased()
        if r == "zh" || r == "zh-cn" || r == "cn" {
            return ["zh", "ze", "zt", "chs", "cht", "sc", "tc", "hans", "hant", "zh-cn", "zh-tw"]
                .contains(c)
        }
        return c == r || c.hasPrefix(r)
    }

    // MARK: Transport

    private static func get(_ address: String) async throws -> Data {
        guard let url = URL(string: address) else { throw OnlineSubtitleAPIError.badSource }
        let page = try await WebFetcher.shared.fetchPage(
            url: url, method: "GET", body: nil, headers: headers, baseURL: ""
        )
        guard (200...299).contains(page.statusCode) else { throw OnlineSubtitleAPIError.http(page.statusCode) }
        return page.data
    }
}

// MARK: - Small JSON accessors

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? {
        if let n = self[key] as? Int { return n }
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
}
