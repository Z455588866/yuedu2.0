import Foundation

/// 猫源配置里的一条直播源（TVBox 的 `lives` 字段）。
///
/// 形状各家不同，网关只做基础规整，这里保持宽松：`url` 指向一个 M3U 或 TXT 播放列表，
/// `type` 0 表示远程地址；`ua`/`epg` 可能缺。
struct CatVodLiveSource: Codable, Identifiable, Hashable, Sendable {
    var name: String
    var url: String
    var type: Int = 0
    var epg: String = ""
    var ua: String = ""
    var playerType: Int = 0

    var id: String { url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "直播"
        type = try c.decodeIfPresent(Int.self, forKey: .type) ?? 0
        epg = try c.decodeIfPresent(String.self, forKey: .epg) ?? ""
        ua = try c.decodeIfPresent(String.self, forKey: .ua) ?? ""
        playerType = try c.decodeIfPresent(Int.self, forKey: .playerType) ?? 0
    }

    init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

/// 一个频道：同一个频道名可能有多条线路（`#` 分隔或重复条目），播放时按顺序试。
struct CatVodLiveChannel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let group: String
    let logo: String
    let urls: [String]
    let headers: [String: String]

    var address: URL? { urls.first.flatMap(URL.init(string:)) }
}

/// M3U / TXT 播放列表解析。
///
/// TVBox 生态里这两种格式混着用，同一个 `lives` 地址可能今天给 M3U、明天换成 TXT，
/// 所以按内容判断而不是按扩展名：
/// - 含 `#EXTINF` / `#EXTM3U` → M3U
/// - 含 `,#genre#` 或 `名称,地址` → TXT
///
/// 解析是纯函数，离线可测，不依赖网络。
enum CatVodLivePlaylist {
    static func parse(_ text: String, source: CatVodLiveSource) -> [CatVodLiveChannel] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains("#EXTINF") || trimmed.contains("#EXTM3U") {
            return parseM3U(trimmed, source: source)
        }
        return parseTXT(trimmed, source: source)
    }

    // MARK: M3U

    private static func parseM3U(_ text: String, source: CatVodLiveSource) -> [CatVodLiveChannel] {
        var channels: [CatVodLiveChannel] = []
        var pending: (name: String, group: String, logo: String, headers: [String: String])?
        var order = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTINF") {
                let attributes = attributes(in: line)
                var headers = baseHeaders(source)
                // 有些列表把 UA/Referer 挂在 EXTINF 自己的属性上。
                if let referer = attributes["referrer"] ?? attributes["referer"] { headers["Referer"] = referer }
                if let agent = attributes["user-agent"] ?? attributes["useragent"] { headers["User-Agent"] = agent }
                pending = (
                    name: displayName(of: line),
                    group: attributes["group-title"] ?? source.name,
                    logo: attributes["tvg-logo"] ?? "",
                    headers: headers
                )
            } else if line.hasPrefix("#EXTVLCOPT") {
                // #EXTVLCOPT:http-user-agent=… / #EXTVLCOPT:http-referrer=…
                guard var current = pending else { continue }
                let body = line.replacingOccurrences(of: "#EXTVLCOPT:", with: "")
                if let value = value(of: "http-user-agent", in: body) { current.headers["User-Agent"] = value }
                if let value = value(of: "http-referrer", in: body) { current.headers["Referer"] = value }
                if let value = value(of: "http-cookie", in: body) { current.headers["Cookie"] = value }
                pending = current
            } else if line.hasPrefix("#EXTGRP:") {
                // 国内 IPTV 列表常用 `#EXTGRP:央视` 单独给下一批频道分组
                // （而不是写在 EXTINF 的 group-title 上）。
                guard var current = pending else { continue }
                let value = String(line.dropFirst("#EXTGRP:".count))
                    .trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { current.group = value }
                pending = current
            } else if line.hasPrefix("#") {
                continue
            } else if let current = pending {
                channels.append(CatVodLiveChannel(
                    id: "\(current.group)|\(current.name)|\(order)",
                    name: current.name,
                    group: current.group,
                    logo: current.logo,
                    urls: [line],
                    headers: current.headers
                ))
                order += 1
                pending = nil
            }
        }
        return channels
    }

    /// `#EXTINF:-1 tvg-name="CCTV1" group-title="央视",CCTV-1` → CCTV-1
    private static func displayName(of line: String) -> String {
        guard let comma = line.lastIndex(of: ",") else { return "" }
        let name = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        return attributes(in: line)["tvg-name"] ?? ""
    }

    private static func attributes(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([A-Za-z0-9_-]+)\s*=\s*"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        for match in regex.matches(in: line, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { continue }
            result[String(line[keyRange]).lowercased()] = String(line[valueRange])
        }
        return result
    }

    private static func value(of key: String, in body: String) -> String? {
        guard body.hasPrefix(key + "=") else { return nil }
        let value = String(body.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    // MARK: TXT

    private static func parseTXT(_ text: String, source: CatVodLiveSource) -> [CatVodLiveChannel] {
        var channels: [CatVodLiveChannel] = []
        var group = source.name
        var order = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.contains(",#genre#") {
                group = line.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? group
                continue
            }
            guard let comma = line.firstIndex(of: ",") else { continue }
            let name = String(line[..<comma]).trimmingCharacters(in: .whitespaces)
            let rest = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !rest.isEmpty else { continue }
            // 多线路：`CCTV1,http://a#http://b`。地址里本身带 # 的情况极少，按 # 切后
            // 只保留看起来像地址的片段。
            let urls = rest.components(separatedBy: "#")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("://") }
            guard !urls.isEmpty else { continue }
            channels.append(CatVodLiveChannel(
                id: "\(group)|\(name)|\(order)",
                name: name,
                group: group,
                logo: "",
                urls: urls,
                headers: baseHeaders(source)
            ))
            order += 1
        }
        return channels
    }

    /// 同一分组里重名的频道合并线路：IPTV 列表经常一个频道列两遍给两条线路。
    static func merge(_ channels: [CatVodLiveChannel]) -> [CatVodLiveChannel] {
        var merged: [CatVodLiveChannel] = []
        var index: [String: Int] = [:]
        for channel in channels {
            let key = "\(channel.group)|\(channel.name)"
            if let existing = index[key] {
                let previous = merged[existing]
                merged[existing] = CatVodLiveChannel(
                    id: previous.id,
                    name: previous.name,
                    group: previous.group,
                    logo: previous.logo.isEmpty ? channel.logo : previous.logo,
                    urls: previous.urls + channel.urls.filter { !previous.urls.contains($0) },
                    headers: previous.headers
                )
            } else {
                index[key] = merged.count
                merged.append(channel)
            }
        }
        return merged
    }

    private static func baseHeaders(_ source: CatVodLiveSource) -> [String: String] {
        var headers: [String: String] = [:]
        if !source.ua.isEmpty { headers["User-Agent"] = source.ua }
        return headers
    }
}
