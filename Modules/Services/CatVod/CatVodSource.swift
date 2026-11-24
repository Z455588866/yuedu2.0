import Foundation
import Combine

/// One imported CatVod node bundle (a `.js` / `.js.md5` spider interface, e.g. the
/// "二小 / 潇洒 / 豆儿" feeds). Only the address is stored; the bundle itself is downloaded,
/// md5-verified and cached by `CatVodGateway` when the source is first used.
///
/// Kept deliberately parallel to `DanmakuSource`: no sources are built in, the list starts
/// empty and is filled only by what the user imports. Import merges by id.
struct CatVodSource: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Full `.js.md5` (or `.js`) address. The gateway derives the companion `.js` URL.
    var url: String
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, url, enabled
    }

    init(id: String, name: String, url: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.url = url
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        guard !rawURL.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.url, .init(codingPath: decoder.codingPath,
                debugDescription: "catvod source needs a url"))
        }
        url = rawURL
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? Self.id(from: rawURL)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? Self.name(from: rawURL)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Stable id derived from the URL so re-importing the same link replaces rather than duplicates.
    ///
    /// Deliberately NOT `Hasher`: Swift seeds `Hasher` randomly per process, so the same
    /// address produced a different id on every launch. The id is persisted and compared
    /// across launches (selection, rename, delete), which made a freshly imported source
    /// look like a different row — and "import again" add a duplicate next to it.
    /// FNV-1a is byte-exact and stable forever.
    static func id(from url: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "catvod-%016llx", hash)
    }

    /// A readable default name from the URL host/path when the import has no explicit name.
    ///
    /// Two shapes have to be handled, because both are what people actually paste:
    ///   1. `https://host/path/index.js.md5`          — plain address
    ///   2. `https://ghfast.top/https://raw.github…`  — a mirror in front of the real address
    /// For (2) the outer host is just an accelerator (ghfast.top, gh-proxy.com, …), so naming
    /// the row after it turned every mirrored feed into "ghfast.top (2)", "ghfast.top (3)".
    /// The inner address is unwrapped first and the row is named after the repository the
    /// bundle lives in — "LeeCatPaw", "catvod/smdl", "xptv/jstv" — which is what a person
    /// recognises from the feed list they copied it out of.
    ///
    /// Deliberately short: the picker draws this in a menu row, and "host · index.js.md5"
    /// wrapped onto two lines and read as an address rather than a name.
    static func name(from url: String) -> String {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unwrap a mirror: the real address is everything from the second scheme on.
        var target = raw
        if raw.count > 1,
           let second = raw.range(of: "https?://", options: .regularExpression,
                                  range: raw.index(after: raw.startIndex)..<raw.endIndex) {
            target = String(raw[second.lowerBound...])
        }
        guard let components = URLComponents(string: target), var host = components.host else {
            return String(raw.suffix(24))
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = (components.path as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let last = parts.last ?? ""

        if host == "raw.githubusercontent.com" || host == "github.com" {
            // owner/repo/[refs/heads/branch]/[subdir]/file → repo[/subdir]
            let pieces = parts
            if pieces.count >= 2 {
                let repo = pieces[1]
                var rest = Array(pieces.dropFirst(2))
                if rest.count >= 3, rest[0] == "refs", rest[1] == "heads" {
                    rest = Array(rest.dropFirst(3))
                }
                if !rest.isEmpty { rest.removeLast() }  // drop the file name
                let tail = rest.filter { !$0.isEmpty && $0 != "main" && $0 != "master" }
                return tail.isEmpty ? repo : "\(repo)/\(tail.joined(separator: "/"))"
            }
        }

        let generic: Set<String> = ["index.js.md5", "index.js", "index.md5", "config.js", "api.js"]
        guard !last.isEmpty, !generic.contains(last.lowercased()) else { return host }
        return "\(host) · \(last)"
    }

    var checksumURL: String {
        url.hasSuffix(".md5") ? url : url + ".md5"
    }
}

/// Persists the user's CatVod sources. Mirrors `DanmakuSourceStore`: empty by default,
/// import merges by id, UserDefaults-backed.
///
/// 用 `ObservableObject` 而不是 `@Observable`：这条链路上「导入成功但界面不刷新」
/// 是实际发生过的故障（设置页提示已导入、列表一行不变），而 `ObservableObject` +
/// `@Published` + `@ObservedObject` 是 SwiftUI 里最保守、不会漏通知的组合。
/// 列表正确性不押在宏的自动追踪上。
@MainActor
final class CatVodSourceStore: ObservableObject {
    static let shared = CatVodSourceStore()

    private static let storageKey = "yd_catvod_sources"

    @Published private(set) var sources: [CatVodSource]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CatVodSource].self, from: data) {
            sources = Self.dedupeNames(Self.refreshAutoNames(Self.renumber(decoded)))
            // 旧版本用 `Hasher` 生成 id（每次启动种子不同），存下来的 id 这次启动已经
            // 对不上了；名字也可能是 "ghfast.top (3)" 这种。算出来的和存的不一致就
            // 立刻回写一次，让下一轮启动不再重复计算。
            if sources != decoded { persist() }
        } else {
            sources = []
        }
    }

    /// 把“明显是自动生成的、且已经不可读”的名字换成新规则算出的名字。
    /// 只处理名字里带地址 host 的那一类（旧版自动名都是 `ghfast.top · index.js.md5`），
    /// 人手动改过的名字原样保留。
    private static func refreshAutoNames(_ list: [CatVodSource]) -> [CatVodSource] {
        list.map { source in
            guard let host = URLComponents(string: source.url)?.host, !host.isEmpty,
                  source.name.contains(host) else { return source }
            var updated = source
            updated.name = CatVodSource.name(from: source.url)
            return updated
        }
    }

    /// 用当前规则重算每条的 id，并按 id 合并。老版本留下的 id 与本次启动算出的
    /// 不一致，选择/改名/删除都会“找不到这一条”，表现为点了没反应。
    private static func renumber(_ list: [CatVodSource]) -> [CatVodSource] {
        var result: [CatVodSource] = []
        var indexByID: [String: Int] = [:]
        for var source in list {
            source.id = CatVodSource.id(from: source.url)
            if let existing = indexByID[source.id] {
                result[existing] = source
            } else {
                indexByID[source.id] = result.count
                result.append(source)
            }
        }
        return result
    }

    /// Suffixes duplicated display names so every row in the picker is distinguishable.
    /// Names are what the person reads; ids stay untouched.
    private static func dedupeNames(_ list: [CatVodSource]) -> [CatVodSource] {
        var result: [CatVodSource] = []
        var taken = Set<String>()
        for var source in list {
            let base = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty {
                source.name = CatVodSource.name(from: source.url)
            }
            var candidate = source.name
            if taken.contains(candidate) {
                var index = 2
                while taken.contains("\(candidate) (\(index))") { index += 1 }
                candidate = "\(candidate) (\(index))"
            }
            source.name = candidate
            taken.insert(candidate)
            result.append(source)
        }
        return result
    }

    var enabledSources: [CatVodSource] { sources.filter(\.enabled) }

    func source(id: String) -> CatVodSource? { sources.first { $0.id == id } }

    func removeAll() {
        sources = []
        persist()
    }

    func reloadFromDisk() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CatVodSource].self, from: data) {
            sources = decoded
        }
    }

    /// Outcome of one import. Kept separate from `Int` because "已导入 1 个" on a
    /// link that already existed is indistinguishable from a no-op: the list does
    /// not grow, and the person concludes the import silently failed.
    struct ImportResult: Sendable {
        let added: Int
        let updated: Int
        /// 判为“已存在”的那几条当前显示名。导入后提示里点名，人才知道是
        /// 哪一行重复了——只说「已导入 1 个」而列表不动，会被当成没生效。
        var updatedNames: [String] = []
        var total: Int { added + updated }
    }

    /// Imports one or more sources. Accepts a bare array, `{"sources":[…]}`, a single object,
    /// or a plain-text list of URLs (one per line, `#` comments). Returns what changed.
    @discardableResult
    func `import`(_ data: Data) throws -> ImportResult {
        let incoming = try Self.decodeSources(data)
        guard !incoming.isEmpty else { return ImportResult(added: 0, updated: 0) }
        var next = sources
        var added = 0, updated = 0
        // 新导入的放在最上面：列表长了以后追加到末尾要滚半天，人往往只看到
        // 「已导入 1 个」却找不到那一行，就以为导入没生效。批量粘贴时按原顺序插。
        var prepend: [CatVodSource] = []
        var updatedNames: [String] = []
        for var source in incoming {
            let defaultName = CatVodSource.name(from: source.url)
            if let index = next.firstIndex(where: { $0.id == source.id || $0.url == source.url }) {
                // Re-importing the same address must not wipe a name the person typed.
                if source.name == defaultName { source.name = next[index].name }
                next[index] = source
                updatedNames.append(next[index].name)
                updated += 1
            } else {
                if source.name == defaultName {
                    source.name = uniqueName(defaultName, in: next + prepend)
                }
                prepend.append(source)
                added += 1
            }
        }
        sources = prepend + next
        persist()
        return ImportResult(added: added, updated: updated, updatedNames: updatedNames)
    }

    /// Convenience for a URL typed/pasted on its own.
    @discardableResult
    func add(url: String, name: String? = nil) -> CatVodSource {
        var source = CatVodSource(id: CatVodSource.id(from: url),
                                  name: name ?? CatVodSource.name(from: url), url: url)
        if let index = sources.firstIndex(where: { $0.id == source.id || $0.url == source.url }) {
            sources[index] = source
        } else {
            source.name = uniqueName(source.name, in: sources)
            sources.append(source)
        }
        persist()
        return source
    }

    /// Appends " (2)", " (3)"… when another interface already owns this display name, so
    /// the picker never renders two rows that read identically.
    private func uniqueName(_ base: String, in list: [CatVodSource]) -> String {
        let taken = Set(list.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) (\(index))") { index += 1 }
        return "\(base) (\(index))"
    }

    func setEnabled(id: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled = enabled
        persist()
    }

    func rename(id: String, to name: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].name = name
        persist()
    }

    func remove(id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources.remove(at: index)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func decodeSources(_ data: Data) throws -> [CatVodSource] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([CatVodSource].self, from: data) { return list }
        if let wrapped = try? decoder.decode(SourceWrapper.self, from: data) { return wrapped.sources }
        if let single = try? decoder.decode(CatVodSource.self, from: data) { return [single] }
        // Plain text. Real-world pastes look like any of these:
        //   #二小接口# https://…/index.js.md5        ← 名字和地址同一行
        //   狸猫\nhttps://…/index.js.md5             ← 名字一行、地址一行
        //   https://…/index.js                          ← 只有地址
        // The old parser treated every line starting with `#` as a comment and
        // dropped it — including the whole address on lines like `#二小接口#
        // https://…`. Import then reported "已导入 1 个猫源" while the list stayed
        // empty, which the person reads as "导入没生效".
        if let text = String(data: data, encoding: .utf8) {
            var result: [CatVodSource] = []
            var pendingName: String?
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                // A line carrying an address is always a source, whatever its prefix.
                if let range = line.range(of: "https?://", options: .regularExpression) {
                    let url = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let head = line[line.startIndex..<range.lowerBound]
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#＃ 　\t"))
                    let name = head.isEmpty ? (pendingName ?? CatVodSource.name(from: url)) : String(head)
                    result.append(CatVodSource(id: CatVodSource.id(from: url), name: name, url: url))
                    pendingName = nil
                    continue
                }
                if line.hasPrefix("#") || line.hasPrefix("＃") {
                    let candidate = line.trimmingCharacters(in: CharacterSet(charactersIn: "#＃ 　\t"))
                    pendingName = candidate.isEmpty ? nil : candidate
                    continue
                }
                // A short bare line with no address is the name for the next one.
                if line.count <= 24 { pendingName = line }
            }
            if !result.isEmpty { return result }
        }
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription:
            "unrecognized catvod source file"))
    }

    private struct SourceWrapper: Decodable {
        let sources: [CatVodSource]
    }
}
