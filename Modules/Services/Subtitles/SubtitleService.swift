import Foundation

/// Parses subtitle files (SRT / WebVTT) and matches an imported entry to the playing video.
/// Everything is local: no network, no external service — the user imports the subtitle files.
enum SubtitleService {
    // MARK: - File parsing

    /// Decodes a subtitle file with a UTF-8-first, GBK-fallback strategy (most Chinese subtitle
    /// files are one of those two). BOM is stripped before parsing.
    static func parse(data: Data) throws -> [SubtitleCue] {
        let text = decodeText(data)
        let cues = parseSRT(text)
        return cues.isEmpty ? parseVTT(text) : cues
    }

    private static func decodeText(_ data: Data) -> String {
        if let s = String(data: data, encoding: .utf8), !s.isEmpty {
            return stripBOM(s)
        }
        // GB_2312 / GBK is the common encoding for Chinese .srt files.
        let gbk = String.Encoding(rawValue: UInt(CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GBK_Encoding.rawValue))))
        if let s = String(data: data, encoding: gbk), !s.isEmpty {
            return stripBOM(s)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func stripBOM(_ s: String) -> String {
        s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    /// SRT: `index` / `00:00:01,000 --> 00:00:04,000` / text lines, blank-line separated.
    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let arrow = lines.firstIndex(where: { $0.contains("-->") }), arrow > 0 else { continue }
            let timing = lines[arrow]
            let parts = timing.split(separator: "-->", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let start = parseTimecode(String(parts[0])),
                  let end = parseTimecode(String(parts[1])) else { continue }
            let body = lines[(arrow + 1)...].joined(separator: "\n")
            let cleaned = clean(body)
            guard !cleaned.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues
    }

    /// WebVTT: optional `WEBVTT` header, cue identifiers, `00:00:01.000 --> ...` with settings.
    private static func parseVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let arrow = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[arrow]
            // VTT timings may carry cue settings after the end time ("align:start line:0").
            let parts = timing.split(separator: "-->", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let endPart = String(parts[1]).split(whereSeparator: { $0 == " " }).first.map(String.init) ?? String(parts[1])
            guard let start = parseTimecode(String(parts[0])), let end = parseTimecode(endPart) else { continue }
            let body = lines[(arrow + 1)...].joined(separator: "\n")
            let cleaned = clean(body)
            guard !cleaned.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: cleaned))
        }
        return cues
    }

    /// Accepts `hh:mm:ss,mmm`, `hh:mm:ss.mmm`, `mm:ss.mmm`, and comma/decimal variants.
    private static func parseTimecode(_ raw: String) -> Double? {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let fields = s.split(separator: ":").map(String.init)
        guard !fields.isEmpty, fields.count <= 3 else { return nil }
        var seconds: Double = 0
        for field in fields {
            guard let value = Double(field) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }

    /// Removes inline markup and decodes the common HTML entities found in subtitle text.
    private static func clean(_ raw: String) -> String {
        var s = raw
        // WebVTT / ASS / HTML style tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\{[^{}]*\\}", with: "", options: .regularExpression)
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ]
        for (key, value) in entities { s = s.replacingOccurrences(of: key, with: value) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - File name → entry metadata

    /// Derives a display name, series title and optional episode number from a subtitle file name,
    /// e.g. `庆余年 第二季.S02E03.zh.srt` → title `庆余年 第二季`, episode 3.
    static func metadata(fromFileName name: String) -> (title: String, episode: Int?) {
        var base = name
        if let dot = base.lastIndex(of: ".") { base = String(base[..<dot]) }
        let episode = episodeNumber(in: base)
        // Drop a trailing resolution/source/language tag chunk after a dot or bracket.
        var title = base
        let separators = CharacterSet(charactersIn: "【[（(")
        if let cut = title.firstIndex(where: { separators.contains($0) }) {
            let head = String(title[..<cut]).trimmingCharacters(in: .whitespaces)
            if head.count >= 2 { title = head }
        }
        title = title.replacingOccurrences(of: "[Ss]\\d{1,2}", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "[Ee][Pp]?\\s?\\d{1,3}", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "第\\s?\\d+\\s?[集话話]", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "[._]", with: " ")
        // Drop trailing language/source tags (zh, en, WEB-DL, 1080p …) left after the name.
        let knownTags: Set<String> = ["zh", "en", "chs", "cht", "sc", "tc", "简体", "繁体", "简", "繁",
                                      "web", "web-dl", "webrip", "bluray", "bdrip", "hdtv", "x264", "x265",
                                      "1080p", "720p", "2160p", "4k", "aac"]
        var words = title.split(separator: " ").map(String.init)
        while let last = words.last, knownTags.contains(last.lowercased()) { words.removeLast() }
        title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if title.isEmpty { title = base }
        return (title, episode)
    }

    private static func episodeNumber(in text: String) -> Int? {
        let patterns = [#"第\s*(\d+)\s*[集话話]"#, #"[Ss]\d{1,2}[Ee][Pp]?\s?(\d{1,3})"#,
                        #"\b[Ee][Pp]?\s?(\d{1,3})\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2,
               let r = Range(match.range(at: 1), in: text), let value = Int(text[r]) {
                return value
            }
        }
        return nil
    }

    // MARK: - Matching

    /// Picks the subtitle entry best matching the playing video. Prefers a title match plus an
    /// equal episode number; falls back to title-only, then to the first enabled entry.
    static func match(title videoTitle: String, episodeNumber: Int?, among entries: [SubtitleEntry]) -> SubtitleEntry? {
        guard !entries.isEmpty else { return nil }
        let video = normalize(videoTitle)

        var best: (entry: SubtitleEntry, score: Int)?
        for entry in entries {
            let candidate = normalize(entry.title)
            var score = 0
            if !video.isEmpty && !candidate.isEmpty {
                if video == candidate { score += 100 }
                else if video.contains(candidate) || candidate.contains(video) { score += 60 }
                else if commonPrefix(video, candidate) >= 2 { score += 30 }
            }
            if let episodeNumber, let entryEpisode = entry.episode {
                score += entryEpisode == episodeNumber ? 40 : -30
            }
            if let best, score <= best.score { continue }
            best = (entry, score)
        }
        // No signal at all (score 0 and no episode): don't guess across unrelated subtitles.
        guard let best, best.score > 0 else { return nil }
        return best.entry
    }

    private static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let allowed = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar.value > 0x2E80
        }
        return String(String.UnicodeScalarView(allowed))
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        var count = 0
        for (x, y) in zip(a, b) {
            if x == y { count += 1 } else { break }
        }
        return count
    }
}
