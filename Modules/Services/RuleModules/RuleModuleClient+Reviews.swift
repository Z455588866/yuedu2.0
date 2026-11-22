import Foundation

/// A work's reviews as one module's site gave them, as the module's cache keeps them.
struct RuleModuleReviewPage: Codable, Equatable, Sendable {
    var reviews: [WorkReview]
    var rating: WorkRating?
    var fetchedAt: Date
    /// The module version whose rules read it, as `RuleModulePage.version`.
    var version: String?
}

extension RuleModuleClient {
    /// The cache name of a work's reviews. `~` is in no entry id (`RuleModuleValidator.isFileSafe`),
    /// so it is never an entry's own page.
    static let reviewsCacheName = "~reviews"
    /// Reviews kept per record. Two hundred: a paged module (one that names the reserved
    /// `{{page}}`) reads ten pages of twenty, and the whole recent discussion fits.
    nonisolated static let reviewLimit = 200
    /// Pages read per record when the module's reviews request names `{{page}}`.
    nonisolated static let pageLimit = 10

    /// A work's reviews as last read, if this version of the module read them within the
    /// block's `cacheDuration`. `key` names the work as the module was asked about it.
    func cachedReviews(_ reviews: RuleModule.Reviews, key: [String: String], in module: RuleModule) -> RuleModuleReviewPage? {
        let duration = TimeInterval(max(reviews.cacheDuration ?? 0, 0))
        guard duration > 0,
              let cached = cached(RuleModuleReviewPage.self, at: cacheFile(module: module.id, entry: Self.reviewsCacheName, values: Self.reviewsCacheKey(key, in: module))),
              cached.version == module.version, now().timeIntervalSince(cached.fetchedAt) < duration else { return nil }
        return cached
    }

    /// Keeps a work's reviews, an empty answer too (a book nobody reviewed is not asked about at
    /// every opening), when the block sets a `cacheDuration`.
    func saveReviews(_ found: [WorkReview], rating: WorkRating?, by reviews: RuleModule.Reviews, key: [String: String],
                     in module: RuleModule) {
        guard (reviews.cacheDuration ?? 0) > 0 else { return }
        save(RuleModuleReviewPage(reviews: found, rating: rating, fetchedAt: now(), version: module.version),
             to: cacheFile(module: module.id, entry: Self.reviewsCacheName, values: Self.reviewsCacheKey(key, in: module)))
    }

    /// The work's key with the module's global values, which change what the site answers.
    nonisolated static func reviewsCacheKey(_ key: [String: String], in module: RuleModule) -> [String: String] {
        module.globalValues(language: nil).reduce(into: key) { $0["global.\($1.key)"] = $1.value }
    }

    /// Whether `item` has every key the request names: a record without its `id` is not asked.
    nonisolated static func canAskReviews(of item: RuleListItem, by reviews: RuleModule.Reviews) -> Bool {
        let request = reviews.request
        let names = Set(RuleModuleValidator.templateNames(
            in: request.url + (request.body ?? "") + (request.headers ?? [:]).values.joined()))
        func has(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (!names.contains("id") || has(item.id)) && (!names.contains("url") || has(item.bookUrl))
    }

    /// One record's reviews: the block's request with the record's `{{id}}` and `{{url}}`, then
    /// its rules on a bare engine. `{{url}}` is as it is at the start of the address,
    /// percent-encoded anywhere else, as `detail` has it. A `page` is filled for `{{page}}`,
    /// the reserved placeholder a paged request reads one round at a time (`allReviews`).
    func reviews(of item: RuleListItem, by reviews: RuleModule.Reviews, page: String? = nil,
                 in module: RuleModule) async throws -> (reviews: [WorkReview], rating: WorkRating?) {
        var keys = ["id": item.id ?? "", "url": item.bookUrl]
        if let page { keys["page"] = page }
        let values = module.withGlobalValues(keys, language: nil)
        let started = SourcePerfTrace.now
        let page = try await perform(reviews.request, values: values, ofRecord: true, in: module)
        let read = await Self.readReviews(page.text, baseURL: page.baseURL, by: reviews, scripts: module.scripts)
        SourcePerfTrace.record("module.reviews", "module=\(module.id) reviews=\(read.reviews.count)", since: started, thresholdMs: 0)
        return read
    }

    /// A record's reviews, paged through when the module's request names the reserved `{{page}}`:
    /// one page per round until an empty page or `pageLimit`, so a site that answers twenty
    /// posts a page gives the whole recent discussion instead of its first page. A request
    /// without `{{page}}` is asked once, as before.
    func allReviews(of item: RuleListItem, by reviews: RuleModule.Reviews,
                    in module: RuleModule) async throws -> (reviews: [WorkReview], rating: WorkRating?) {
        guard reviews.request.url.contains("{{page}}") || (reviews.request.body ?? "").contains("{{page}}") else {
            return try await self.reviews(of: item, by: reviews, in: module)
        }
        var found: [WorkReview] = []
        var rating: WorkRating?
        for page in 1...Self.pageLimit {
            let read: (reviews: [WorkReview], rating: WorkRating?)
            do {
                read = try await self.reviews(of: item, by: reviews, page: String(page), in: module)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A page that fails ends the run, not the whole record: the pages read so far
                // are still the site's answer (some sites rate-limit after a few rounds).
                break
            }
            if rating == nil { rating = read.rating }
            guard !read.reviews.isEmpty else { break }
            found += read.reviews
            guard found.count < Self.reviewLimit else { break }
        }
        // The last page's rows can repeat in an answer that arrived twice: one reader, one review.
        var seen = Set<String>()
        found = found.filter { seen.insert("\($0.author ?? "")\u{1F}\($0.text)").inserted }
        return (Array(found.prefix(Self.reviewLimit)), rating)
    }

    /// The page's reviews and rating. Off the caller's actor: a page of a hundred reviews is a
    /// hundred HTML-to-text passes.
    @concurrent
    nonisolated static func readReviews(_ text: String, baseURL: String, by reviews: RuleModule.Reviews,
                                        scripts: RuleModuleScriptRuntime? = nil) async -> (reviews: [WorkReview], rating: WorkRating?) {
        let engine = RuleModuleScriptRuntime.engine(scripts)
        let scale = reviews.ratingScale ?? Double(WorkRating.stars)
        let found = readList(reviews.list, in: text, baseURL: baseURL, scale: scale, engine: engine)
        var rating: WorkRating?
        if let summary = reviews.rating {
            engine.setContent(text, baseUrl: baseURL)
            if let score = stars(engine.getString(ruleStr: summary.score), outOf: scale) {
                let count = summary.count.flatMap { Int(engine.getString(ruleStr: $0).trimmingCharacters(in: .whitespaces)) }
                let bars = summary.distribution.map { engine.getStringList(ruleStr: $0).map { Int($0.trimmingCharacters(in: .whitespaces)) } } ?? []
                // A bar per star, or none: a site's four or ten buckets are not five stars'.
                let distribution = bars.count == WorkRating.stars ? bars.compactMap { $0 }.filter { $0 >= 0 } : []
                rating = WorkRating(score: score, count: count.flatMap { $0 > 0 ? $0 : nil },
                                    distribution: distribution.count == WorkRating.stars ? distribution : nil)
            }
        }
        return (found, rating)
    }

    /// The page's reviews, or a chapter's comments (`comments.chapter.list`): one rule set reads both.
    nonisolated static func readList(_ rules: RuleModule.ReviewRules, in text: String, baseURL: String, scale: Double,
                                     engine: ModernRuleEngine) -> [WorkReview] {
        engine.setContent(text, baseUrl: baseURL)
        var found: [WorkReview] = []
        for element in engine.getElements(ruleStr: rules.items) {
            guard found.count < reviewLimit else { break }
            engine.setContent(element, baseUrl: baseURL)
            let body = plainText(engine.getString(ruleStr: rules.text), limit: WorkReview.textLimit)
            guard !body.isEmpty else { continue }
            func line(_ rule: String?, limit: Int) -> String? {
                guard let rule, !rule.isEmpty else { return nil }
                let value = OPDSClient.plainMetadata(engine.getString(ruleStr: rule), limit: limit)
                return value.isEmpty ? nil : value
            }
            found.append(WorkReview(
                title: line(rules.title, limit: WorkReview.titleLimit),
                text: body,
                author: line(rules.author, limit: WorkReview.authorLimit),
                date: line(rules.date, limit: 40).flatMap(date(from:)),
                rating: line(rules.rating, limit: 20).flatMap { stars($0, outOf: scale) },
                likes: line(rules.likes, limit: 20).flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
                avatar: line(rules.avatar, limit: 400),
                images: Self.imageURLs(rules.images, engine: engine)))
        }
        return found
    }

    /// Attached image URLs. A rule may yield one URL, several URLs (one per line), or a JSON
    /// array string (what an `@js:` rule returns). Blank values become nil so an image-less
    /// review keeps the card layout it always had.
    nonisolated static func imageURLs(_ rule: String?, engine: ModernRuleEngine) -> [String]? {
        guard let rule, !rule.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let raw = engine.getString(ruleStr: rule).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        var urls: [String] = []
        if let data = raw.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            urls = array.compactMap { $0 as? String }
        }
        if urls.isEmpty {
            urls = raw.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == " " })
                .map(String.init)
        }
        urls = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        return urls.isEmpty ? nil : urls
    }

    /// A site's number as stars out of `WorkRating.stars`; nil for no number, zero (unrated), or
    /// one outside the scale.
    nonisolated static func stars(_ text: String, outOf scale: Double) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value > 0,
              scale > 0, value <= scale else { return nil }
        return value / scale * Double(WorkRating.stars)
    }

    /// `[fn=N]` face codes in review text, mapped to the emoji the source site shows.
    /// Taken from the comment server's own page script so the module panel matches its
    /// web panel exactly. Text without these codes (every other module) is untouched.
    nonisolated static let reviewFaceCodes: [Int: String] = [
            1: "👏",
            2: "🌹",
            3: "🤝",
            4: "😁",
            5: "😄",
            6: "🥺",
            7: "🙂",
            8: "😏",
            9: "😙",
            10: " 👆🏻🐽 ",
            11: "🙄",
            12: "😭",
            13: "😵",
            14: "😥",
            15: "🖕🏻",
            16: "🥵",
            17: "😓",
            18: "🤫",
            19: "😂",
            20: "😢",
            21: "😍",
            22: " 🤕🔨 ",
            23: "😑",
            24: "😫",
            25: "🤗",
            26: "🤪",
            27: "🙏",
            28: "😣",
            29: "💪",
            30: "💀",
            31: "😳",
            32: "😎",
            33: "🤭",
            34: " 😄👏 ",
            35: "👍🏻",
            36: "🤓",
            37: "😡",
            38: "🙁",
            39: " 😄❓ ",
            40: "😞",
            41: "😧",
            42: "💋",
            43: "☺️",
            44: "🤬",
            45: "😴",
            46: " 🤠🚬 ",
            47: "😱",
            48: "🐷",
            49: "😪",
            50: "🤐",
            51: "🥴",
            52: "🌙",
            53: "❤️",
            54: "🔪",
            55: "🎁",
            56: "💔",
            57: "👊🏻",
            58: "😒",
            59: "✌🏻️",
            60: "😮",
            61: "🤨",
            62: "😴",
            63: "👏🏻",
            64: "🐲",
    ]

    /// Replace `[fn=N]` face codes with their emoji; unknown codes stay literal.
    nonisolated static func replaceReviewFaceCodes(_ text: String) -> String {
        guard text.contains("[fn=") else { return text }
        let pattern = "\\[fn=(\\d+)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            out += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            if let code = Int(ns.substring(with: match.range(at: 1))), let face = reviewFaceCodes[code] {
                out += face
            } else {
                out += ns.substring(with: range)
            }
            cursor = range.location + range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Plain text, one line per paragraph: the site's HTML blocks and its own line breaks.
    nonisolated static func plainText(_ raw: String, limit: Int) -> String {
        let broken = replaceReviewFaceCodes(raw)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: OPDSClient.paragraphBreak)
        return OPDSClient.plainParagraphs(broken, limit: limit)
    }

    /// A date as sites write one: seconds (or milliseconds) since 1970, ISO 8601, or
    /// `yyyy-MM-dd[ HH:mm:ss]`, read as UTC. Only its day is shown, so a site's own zone moves it
    /// a day at most.
    nonisolated static func date(from text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Double(text) {
            switch text.count {
            case 9...10: return Date(timeIntervalSince1970: number)
            case 12...13: return Date(timeIntervalSince1970: number / 1_000)
            default: return nil
            }
        }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
