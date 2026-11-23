import Foundation

/// Talks to the embedded spider gateway over loopback HTTP and decodes the CatVod JSON into the
/// small view models in `CatVodModels`. Independent of the book-source engine on purpose: the
/// gateway owns the Node runtime and the spider protocol; this is a thin typed client.
final class CatVodService {
    static let shared = CatVodService()

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Loads the site catalog exposed by a CatVod bundle. Starts the engine with this bundle
    /// allowlisted, then asks the gateway for its sites.
    func catalog(bundleURL: String) async throws -> [CatVodSite] {
        let base = try await CatVodGateway.shared.ensureStarted(allowedBundleURL: bundleURL)
        let endpoint = base.appendingPathComponent("/v1/catvod/catalog")
        let object = try await post(endpoint, body: ["bundle": bundleURL])
        guard let sites = object["sites"] as? [[String: Any]] else { return [] }
        return sites.compactMap { dict in
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let site = try? decoder.decode(CatVodSite.self, from: data) else { return nil }
            return site
        }
    }

    /// Home categories and recommended media for a site.
    func home(bundleURL: String, site: CatVodSite) async throws -> CatVodList {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "home",
                                      arguments: ["filter": true])
        return Self.parseList(object)
    }

    func category(bundleURL: String, site: CatVodSite, categoryID: String, page: Int) async throws -> CatVodList {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "category",
                                      arguments: ["tid": categoryID, "page": String(page), "filter": false])
        return Self.parseList(object)
    }

    func search(bundleURL: String, site: CatVodSite, keyword: String, page: Int = 1) async throws -> CatVodList {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "search",
                                      arguments: ["keyword": keyword, "page": String(page)])
        return Self.parseList(object)
    }

    /// Full detail incl. play groups for one media id.
    func detail(bundleURL: String, site: CatVodSite, id: String) async throws -> (CatVodMedia, [CatVodGroup]) {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "detail",
                                      arguments: ["ids": [id]])
        guard let first = (object["list"] as? [[String: Any]])?.first,
              let data = try? JSONSerialization.data(withJSONObject: first),
              let media = try? decoder.decode(CatVodMedia.self, from: data) else {
            throw CatVodError.emptyResponse
        }
        let from = first["vod_play_from"] as? String ?? ""
        let playURL = first["vod_play_url"] as? String ?? ""
        return (media, CatVodPlaylistParser.groups(from: from, playURL: playURL))
    }

    /// Resolves a spider episode id to a direct stream URL + headers, or fails clearly if the
    /// source needs an external parser (`parse/jx == 1`).
    func player(bundleURL: String, site: CatVodSite, episode: CatVodEpisode) async throws -> CatVodPlayback {
        let object = try await invoke(bundleURL: bundleURL, site: site, action: "player",
                                      arguments: [
                                        "flag": episode.groupName,
                                        "id": episode.playID,
                                        "vipFlags": [String]()
                                      ])
        let parse = Self.flexibleInt(object["parse"])
        let jx = Self.flexibleInt(object["jx"])
        guard parse != 1, jx != 1 else { throw CatVodError.parseUnsupported }
        let url: String
        if let s = object["url"] as? String { url = s }
        else if let arr = object["url"] as? [String] { url = arr.first ?? "" }
        else { url = "" }
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatVodError.emptyPlayerURL
        }
        var headers: [String: String] = [:]
        if let header = object["header"] as? [String: Any] {
            for (k, v) in header {
                if let s = v as? String { headers[k] = s }
                else { headers[k] = "\(v)" }
            }
        }
        return CatVodPlayback(parse: parse, url: url, header: headers)
    }

    // MARK: - Low level

    private func invoke(bundleURL: String, site: CatVodSite, action: String,
                        arguments: [String: Any]) async throws -> [String: Any] {
        let base = try await CatVodGateway.shared.ensureStarted(allowedBundleURL: bundleURL)
        let endpoint = base.appendingPathComponent("/v1/spider/invoke")
        let body: [String: Any] = [
            "version": 1,
            "action": action,
            "site": [
                "key": site.key,
                "api": site.api ?? "/spider/\(site.key)/3",
                "jar": bundleURL,
                "ext": "",
                "quickSearch": site.quickSearch ?? false
            ],
            "arguments": arguments
        ]
        return try await post(endpoint, body: body)
    }

    private func post(_ endpoint: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.timeoutInterval = 45

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                ?? String(data: data, encoding: .utf8)?.prefix(120) ?? ""
            throw CatVodError.http(status, String(message))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatVodError.emptyResponse
        }
        return object
    }

    static func parseList(_ object: [String: Any]) -> CatVodList {
        var categories: [CatVodCategory] = []
        if let classes = object["class"] as? [[String: Any]] {
            for dict in classes {
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let category = try? JSONDecoder().decode(CatVodCategory.self, from: data) else { continue }
                categories.append(category)
            }
        }
        var media: [CatVodMedia] = []
        if let list = object["list"] as? [[String: Any]] {
            for dict in list {
                guard let data = try? JSONSerialization.data(withJSONObject: dict),
                      let item = try? JSONDecoder().decode(CatVodMedia.self, from: data) else { continue }
                media.append(item)
            }
        }
        return CatVodList(categories: categories, media: media,
                          page: flexibleInt(object["page"]), pageCount: flexibleInt(object["pagecount"]))
    }

    static func flexibleInt(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let s = value as? String, let i = Int(s) { return i }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }
}

extension CatVodError {
    static let parseUnsupported = CatVodError.http(-1, "该片源需要外部解析器，暂不支持")
    static let emptyPlayerURL = CatVodError.http(-2, "该片源没有返回可播放地址")
}
