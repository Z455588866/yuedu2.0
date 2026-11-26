import CryptoKit
import Foundation
import YueduNodeRuntime
import YueduPythonRuntime

/// Owns the single in-process Node.js engine that runs CatVod spider bundles.
/// Adapted from the mobile gateway validated in tvbox-Swift iOS build 28: the engine listens on
/// 127.0.0.1 on a random port with a per-launch token; all spider work happens in V8 workers.
@MainActor
final class CatVodGateway {
    static let shared = CatVodGateway()

    private let resourcesDirectory: URL
    private let entryPoint: URL
    private let cacheDirectory: URL
    /// 内嵌 Python 服务的端口；0 表示这个包没有 Python 运行时（构建时没链框架）。
    private var pythonSpiderPort = 0
    /// 只尝试启动一次：失败后每次进猫源都重试会白白多等几秒。
    private var pythonStartupAttempted = false
    /// 引擎启动进行中。并发的 ensureStarted 只应该有一个真正去 start。
    private var startInFlight = false

    /// 用户放进来的 .py 源。Documents 已对「文件」App 开放，拖进去就能用。
    private var pythonSourcesDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("PythonSources", isDirectory: true)
    }

    /// Per-launch token the Node gateway requires on every spider request.
    /// Read by `CatVodService` to build the `Authorization: Bearer` header.
    let authenticationToken = UUID().uuidString + UUID().uuidString
    private var activeAllowedURLs: Set<String> = []
    /// Credentials for netdisk sources. Kept here so both the initial launch
    /// config and live updates after the engine started see the same value.
    private var cloudConfig: [String: String] = [:]
    /// Loopback base the engine reported. Playback URLs are rewritten against it.
    private(set) var baseURL: URL?

    init(resourcesDirectory: URL? = nil, entryPoint: URL? = nil, cacheDirectory: URL? = nil) {
        let bundle = Bundle.main.bundleURL
        let fileManager = FileManager.default
        let nested = bundle.appendingPathComponent("SpiderGateway", isDirectory: true)
        let nestedEntry = nested.appendingPathComponent("mobile-entry.mjs")
        let flatEntry = bundle.appendingPathComponent("mobile-entry.mjs")

        // Xcode 既可能把 SpiderGateway 作为文件夹引用整目录拷入，也可能把里面的
        // .mjs 平铺到 .app 根目录（实际签名 IPA 就是后者）。两种布局都接受，避免
        // 因为找不到子目录而误报“手机内置脚本组件不完整”。
        let resolvedResources: URL
        let resolvedEntry: URL
        if let resourcesDirectory {
            resolvedResources = resourcesDirectory
            resolvedEntry = entryPoint ?? resourcesDirectory.appendingPathComponent("mobile-entry.mjs")
        } else if let entryPoint {
            resolvedEntry = entryPoint
            resolvedResources = entryPoint.deletingLastPathComponent()
        } else if fileManager.fileExists(atPath: nestedEntry.path) {
            resolvedResources = nested
            resolvedEntry = nestedEntry
        } else {
            resolvedResources = bundle
            resolvedEntry = flatEntry
        }

        self.resourcesDirectory = resolvedResources
        self.entryPoint = resolvedEntry
        self.cacheDirectory = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Yuedu/CatVod", isDirectory: true)
    }

    /// Builds the full configuration JSON the engine reads through its bridge.
    /// Reused on launch and whenever cloud credentials change, so a live update
    /// never drops the token, cache path or bundle allowlist.
    private func configurationJSON() throws -> String {
        let config: [String: Any] = [
            "token": authenticationToken,
            "cloudConfig": cloudConfig,
            "cacheRoot": cacheDirectory.path,
            "nodeBundleAllowedURLs": activeAllowedURLs.sorted(),
            "nodeBundleAllowChecksumRedirects": true,
            // Python 源由本机 Python 服务答话；没起 Python 时网关不会并进目录。
            "pythonSpiderPort": pythonSpiderPort
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        guard data.count <= 64 * 1024, let json = String(data: data, encoding: .utf8) else {
            throw CatVodError.invalidConfiguration
        }
        return json
    }

    /// 拉起内嵌 Python。它和 Node 引擎一样是"启动一次就一直在"，
    /// 失败只会让 Python 源不出现，不影响其它源。
    private func startPythonRuntimeIfNeeded() async {
        guard pythonSpiderPort == 0, !pythonStartupAttempted else { return }
        pythonStartupAttempted = true
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: pythonSourcesDirectory, withIntermediateDirectories: true)
        let root = Bundle.main.bundleURL.path
        let cache = cacheDirectory.appendingPathComponent("Python", isDirectory: true).path
        try? fileManager.createDirectory(atPath: cache, withIntermediateDirectories: true)
        let scan = pythonSourcesDirectory.path
        // 解释器初始化要一两秒（解压标准库 + 起本地服务），而这个类是 @MainActor，
        // 同步调用会把启动画面卡住。丢到后台，等它好了再回来写端口。
        let port = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: YueduPythonRuntime.start(root: root, cache: cache, scan: scan))
            }
        }
        pythonSpiderPort = port
        if port > 0 {
            AppLogger.info("[CatVod] Python 源服务已启动，端口 \(port)", level: .notice)
        } else if let reason = YueduPythonRuntime.startupError() {
            AppLogger.info("[CatVod] Python 源不可用：\(reason)", level: .notice)
        }
    }

    /// 把用户选中的 .py 拷进扫描目录，返回成功个数。
    ///
    /// 只做文件拷贝，不碰会话：解释器可能还没起来（`pythonSpiderPort == 0`），
    /// 那种情况下文件先躺在那儿，等 `reloadPythonSources()` 或下次冷启动再扫。
    func importPythonSources(from urls: [URL]) -> Int {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: pythonSourcesDirectory, withIntermediateDirectories: true)
        var copied = 0
        for url in urls where url.pathExtension.lowercased() == "py" {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let target = pythonSourcesDirectory.appendingPathComponent(url.lastPathComponent)
            do {
                // 同名覆盖：先删再拷，避免 copyItem 遇到已存在文件直接失败。
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: url, to: target)
                copied += 1
            } catch {
                AppLogger.info("[CatVod] 导入 Python 源失败 \(url.lastPathComponent)：\(error)", level: .error)
            }
        }
        return copied
    }

    /// 让 Python 运行时重扫目录，返回扫描后的源总数；`-1` 表示解释器还没起来。
    ///
    /// 有这个就不必让用户"导入完杀掉 App 重开"——那是最容易被当成导入失败的操作。
    func reloadPythonSources() async -> Int {
        guard pythonSpiderPort > 0 else { return -1 }
        guard let url = URL(string: "http://127.0.0.1:\(pythonSpiderPort)/v1/pyspider/reload") else {
            return -1
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = object["count"] as? Int else {
            return -1
        }
        return count
    }

    /// Pushes updated netdisk credentials into the already-running engine. The
    /// node side re-reads `bridge.configuration()` before every request, so this
    /// takes effect immediately without a restart. Safe to call before launch.
    func applyCloudConfig(_ config: [String: String]) {
        cloudConfig = config
        guard let json = try? configurationJSON() else { return }
        YueduNodeRuntime.updateConfiguration(json)
    }

    /// Starts the engine (once per process) and returns its loopback base URL.
    /// `bundleURL` is the interface the user imported, added to the download allowlist.
    func ensureStarted(allowedBundleURL: String? = nil, replacingAllowlist: Bool = false) async throws -> URL {
        guard FileManager.default.fileExists(atPath: entryPoint.path) else {
            throw CatVodError.missingResources
        }
        // Restore persisted credentials if they have not been applied this session
        // (e.g. right after launch before the settings screen was opened).
        if cloudConfig.isEmpty {
            let saved = CatVodCloudAccountStore.shared.accounts.gatewayConfig
            if !saved.isEmpty { cloudConfig = saved }
        }
        let requested = Set(Self.allowedBundleURLs(for: allowedBundleURL))
        activeAllowedURLs = replacingAllowlist ? requested : activeAllowedURLs.union(requested)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Python 与 Node 互不阻塞：Python 慢或挂住，代价只能是"少几个 .py 源"，
        // 不该把整个网关拖到 20 秒超时（那样连 JS 源一起用不了）。
        // 先在后台起它，起来了再把端口推给已经跑着的引擎。
        Task { [weak self] in
            guard let self else { return }
            await self.startPythonRuntimeIfNeeded()
            guard self.pythonSpiderPort > 0, let json = try? self.configurationJSON() else { return }
            YueduNodeRuntime.updateConfiguration(json)
        }

        // 引擎已经在跑：把更新后的 allowlist 无条件推一次再返回。
        // 以前把推送全押在下面那个 guard pythonSpiderPort>0 的后台 Task 上——没装
        // Python 源或 Python 启动失败时端口恒为 0，推送永不发生，新导入的猫源被
        // node 侧白名单挡成 403。allowlist 与 Python 无关，不该被它连坐。
        // 不要重复 start（那会把正在服务的引擎重启、断了在跑的请求）。
        if let ready = baseURL, YueduNodeRuntime.listeningURL() != nil {
            if let json = try? configurationJSON() {
                YueduNodeRuntime.updateConfiguration(json)
            }
            return ready
        }
        // 另一个调用方正在启动中：跟它一起等，不抢着重启。
        if startInFlight {
            return try await waitUntilListening()
        }
        startInFlight = true
        defer { startInFlight = false }

        let json = try configurationJSON()

        YueduNodeRuntime.start(script: entryPoint.path,
                               assetsDirectory: resourcesDirectory.path,
                               runtimeDirectory: cacheDirectory.path,
                               configuration: json)

        return try await waitUntilListening()
    }

    /// 等引擎报出监听地址。抽出来是因为「首次启动」和「跟在别人后面等」
    /// 必须用同一套判据（startupError 优先、20 秒上限、可取消）。
    private func waitUntilListening() async throws -> URL {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let message = YueduNodeRuntime.startupError() {
                throw CatVodError.startupFailed(message)
            }
            if let urlString = YueduNodeRuntime.listeningURL(), let url = URL(string: urlString) {
                baseURL = url
                return url
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CatVodError.startupTimedOut
    }

    /// Turns a resolved stream into a URL the built-in player can actually open.
    ///
    /// Every CatVod bundle answers `player` with a URL on **its own** loopback
    /// server, bound to a temporary port that dies with the session (idle sweep,
    /// switching 猫源, the 4-session cap). Handing that URL to AVPlayer produced
    /// "在此服务器上找不到所请求的 URL" (404) and, after a redirect, 403 — the
    /// source's Referer/Cookie were lost. The gateway's stable `/v1/media` proxy
    /// keeps the bundle identity instead of the dead port, re-attaches headers on
    /// every hop and rewrites HLS playlists. Mature CatVod hosts do the same.
    func playbackProxyURL(for url: URL, bundleURL: String, headers: [String: String]) -> URL? {
        let host = url.host?.lowercased() ?? ""
        let isLoopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        // 回环上不止网关一个服务：Python bridge 是一个端口，每个 .py 源还会
        // 再起一个随机端口的 localProxy（`/py-proxy?do=py`）。只有网关自己的
        // 端口才该走 /v1/media 转发，其余端口在网关里根本不存在，转过去只会
        // 404——原样交给播放器。
        if isLoopback, let port = url.port {
            if pythonSpiderPort > 0, port == pythonSpiderPort { return url }
            let gatewayPort = (baseURL ?? YueduNodeRuntime.listeningURL().flatMap(URL.init(string:)))?.port
            if let gatewayPort, port != gatewayPort { return url }
        }
        let base = baseURL ?? YueduNodeRuntime.listeningURL().flatMap(URL.init(string:))
        return Self.proxyURL(for: url, bundleURL: bundleURL, headers: headers,
                             forceLoopback: isLoopback, token: authenticationToken, base: base)
    }

    /// 弹幕走网关代理：插件进程里的 loopback 地址（网盘源的弹幕路由）临时端口
    /// 会随 spider 会话回收，直连必 404。这里不按端口过滤，强制用 `bundleURL`
    /// 让网关按当前活端口重建目标，再取回弹幕 XML。
    func danmakuProxyURL(for url: URL, bundleURL: String) -> URL? {
        let host = url.host?.lowercased() ?? ""
        let isLoopback = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
        guard isLoopback else { return url }
        let base = baseURL ?? YueduNodeRuntime.listeningURL().flatMap(URL.init(string:))
        return Self.proxyURL(for: url, bundleURL: bundleURL, headers: [:],
                             forceLoopback: true, token: authenticationToken, base: base) ?? url
    }

    /// 代理 spec 的公共构造，播放与弹幕共用，避免两处漂移。
    private static func proxyURL(for url: URL, bundleURL: String, headers: [String: String],
                                 forceLoopback: Bool, token: String, base: URL?) -> URL? {
        guard let base else { return nil }
        var spec: [String: Any]
        if forceLoopback {
            var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
                ?? url.path
            if let query = url.query, !query.isEmpty { path += "?" + query }
            spec = ["j": bundleURL, "p": path.isEmpty ? "/" : path]
        } else if headers.isEmpty {
            spec = ["u": url.absoluteString]
        } else {
            spec = ["u": url.absoluteString, "h": headers]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]),
              var components = URLComponents(url: base.appendingPathComponent("v1/media"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        components.queryItems = [URLQueryItem(name: "k", value: mediaKey(for: token)),
                                 URLQueryItem(name: "s", value: encoded)]
        return components.url
    }

    /// 把 App 内 WebView 的登录态灌进这个 bundle 的 Cookie 池。
    ///
    /// Android 侧是 OkHttp 的全局 CookieJar：用户在 WebView 里登录/过完挑战，
    /// 之后 spider 的每一个请求自动带上。iOS 没有这层，插件就等于每次都从
    /// 游客态起步，于是「明明登录过了」仍然 403/缺少凭证。这里补的就是那一层。
    @discardableResult
    func pushCookies(bundleURL: String, items: [[String: String]]) async -> Int {
        guard !items.isEmpty else { return 0 }
        guard let base = baseURL ?? YueduNodeRuntime.listeningURL().flatMap(URL.init(string:)) else {
            return 0
        }
        var request = URLRequest(url: base.appendingPathComponent("v1/cookies"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authenticationToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8
        let body: [String: Any] = ["bundle": bundleURL, "items": items]
        guard let payload = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            return 0
        }
        request.httpBody = payload
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            return 0
        }
        return object["imported"] as? Int ?? 0
    }

    /// Mirrors `playbackMediaKey` in `playback-proxy.mjs`: the media route cannot
    /// carry an Authorization header, so it accepts this derived value instead.
    private static func mediaKey(for token: String) -> String {
        let digest = SHA256.hash(data: Data("media:\(token)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// Adds a newly imported bundle URL to the allowlist and restarts with the widened set.
    /// The engine reads configuration live via the native bridge before each request, so usually
    /// no restart is needed — but the first launch after adding a source must include it.
    nonisolated static func allowedBundleURLs(for reference: String?) -> [String] {
        var values: [String] = []
        guard let reference,
              var components = URLComponents(string: reference.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            return values
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let value = components.url?.absoluteString { values.append(value) }
        // 粘贴的地址带尾斜杠（`…/index.js.md5/`）时 node 侧会先规范化再下载，
        // 规范化后的字符串也必须登记，否则会被白名单挡成 403。
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path.isEmpty ? "/" : path
        if let value = components.url?.absoluteString { values.append(value) }
        let lowerPath = components.percentEncodedPath.lowercased()
        if lowerPath.hasSuffix(".js.md5") {
            components.percentEncodedPath = String(components.percentEncodedPath.dropLast(4))
            if let value = components.url?.absoluteString { values.append(value) }
        } else if !lowerPath.hasSuffix(".js") {
            // Python / Java 源原样保留：给 `x.py` 补成 `x.py/index.js` 会变成一个
            // 根本不存在的地址，报错只会更难懂。
            if lowerPath.hasSuffix(".py") || lowerPath.hasSuffix(".jar") {
                return Array(Set(values)).sorted()
            }
            // 只给了目录（如 `https://host/cat`）时按 index.js 补全，与 node
            // 侧的兜底规则保持一致。
            let base = components.percentEncodedPath
            components.percentEncodedPath = (base.hasSuffix("/") ? base : base + "/") + "index.js"
            if let value = components.url?.absoluteString { values.append(value) }
        }
        return Array(Set(values)).sorted()
    }
}

enum CatVodError: LocalizedError {
    case missingResources
    case invalidConfiguration
    case startupFailed(String)
    case startupTimedOut
    case http(Int, String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingResources: return localized("手机内置脚本组件不完整，请安装新版 App")
        case .invalidConfiguration: return localized("手机内置脚本配置过大或无效")
        case .startupFailed(let message): return message
        case .startupTimedOut: return localized("手机内置脚本引擎启动超时，请重新启动 App")
        case .http(let code, let message): return Self.describeHTTP(code: code, message: message)
        case .emptyResponse: return localized("猫源返回空数据")
        }
    }

    /// Upstream trouble reaches the app as a 5xx carrying the source's own
    /// wording — "站源不存在", "红果上游暂时无法连接". Printed raw next to a
    /// number, it reads like *our* bug and tells the person nothing they can act
    /// on. These are source-side failures: name the side, say whether retrying
    /// is worth it, and keep the original text only when it is genuinely useful.
    private static func describeHTTP(code: Int, message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        // 负数是 App 自己造的语义错误码（网盘不支持、磁力链、片单合集…），
        // 文案已经写成人话，不该再包一层「猫源请求失败（-4）」。
        if code < 0 { return text.isEmpty ? localized("播放失败") : text }
        // 网盘类线路：没登录时源站提示的是「请先在 TVBox 设置 → 网盘设置中保存 Cookie」，
        // 我们 App 没有那个菜单，照着找永远找不到——这种才翻成我们自己的路径。
        //
        // 关键：只有「LoginRequired/登录态缺失」才引导去登录。网关对具体失败已经写好
        // 精准中文（提取码不对、分享失效、没找到文件、没返回播放地址），这些 message
        // 里也带「网盘」二字，若一律翻成「还没登录」就会误导已经登录的人。所以命中
        // 具体业务词时原样保留网关原文。
        if text.contains("网盘") || text.contains("登录") || text.contains("未配置")
            || lower.contains("cookie 未") || lower.contains("cookie未") {
            let specificFailure = ["提取码", "分享已失效", "分享已过期", "分享地址", "没有找到",
                                   "播放地址", "分享里", "errno"].contains(where: { text.contains($0) })
            if specificFailure || (code >= 400 && code != 401 && code != 403) {
                return text
            }
            if text.contains("失效") || text.contains("过期") || text.contains("重新登录") {
                return localized("网盘登录已失效。去「管理 → 网盘账号」重新网页登录一次，再点这一集")
            }
            return localized("这条是网盘资源，还没登录。去「管理 → 网盘账号」用网页登录一次即可播放")
        }
        // 少数站点用到了运行时不提供的接口（典型是 fetch），这不是网络问题，
        // 换线路/换源才有用，原样抛出去只会让人以为是 App 坏了。
        if lower.hasSuffix("is not defined") || lower.contains("is not a function") {
            return String(format: localized("这个站点的播放组件依赖当前运行时不提供的接口（%@）。换一条线路，或换一个源"), text)
        }
        if text.contains("站源不存在") || lower.contains("site not found") || lower.contains("no such site") {
            return localized("这个站点不在当前接口里了。换一个站点，或者更新接口后再试")
        }
        if code == 408 || code == 504 || text.contains("timed out") || text.contains("timeout")
            || text.contains("超时") {
            return localized("源站响应超时（源自己的问题）。稍后重试，或者换一个站点")
        }
        if code >= 500 {
            // 站点自身风控/反爬的两种典型形态。原文是英文（axios 的
            // "Request failed with status code 403"、node 的
            // "Client network socket disconnected…"），直接摊在「暂无内容」下面，
            // 用户只能读出一串它看不懂的报错。这里按原因说清楚「是源的问题、能做什么」。
            if lower.contains("status code 403") || lower.contains("403 forbidden")
                || text.contains("请求失败 403") {
                return localized("源站拒绝访问（403：站点开了风控，或需要登录/Cookie）。换一个站点，或者稍后再试")
            }
            if lower.contains("client network socket disconnected")
                || lower.contains("before secure tls connection") || lower.contains("econnreset") {
                return localized("源站断开了连接（站点拦截了当前网络）。换一个网络或站点再试")
            }
            if lower.contains("status code 502") || lower.contains("status code 520")
                || lower.contains("status code 521") || lower.contains("status code 522") {
                return localized("源站自己故障了（网关 5xx）。这不是 App 的问题，晚点再试或换站点")
            }
            if text.contains("无法连接") || text.contains("连接失败") || text.contains("请稍后重试")
                || lower.contains("econnrefused") || lower.contains("etimedout")
                || lower.contains("socket hang up") || lower.contains("enotfound")
                || lower.contains("getaddrinfo")
                || lower.contains("unavailable") {
                return localized("源站连不上（源自己的问题，不是 App 坏了）。稍后重试，或者换一个站点")
            }
            // `fetch failed ← certificate has expired ← …` 这类错误链：前半截是运行时
            // 的包装，真正的原因在最后一段。只留原因，避免把英文栈甩给用户。
            if text.contains(" ← ") {
                let cause = text.split(separator: "←").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
                return String(format: localized("源站返回错误：%@"), cause.isEmpty ? localized("未知原因") : cause)
            }
            return String(format: localized("源站返回错误：%@"), text.isEmpty ? localized("未知原因") : text)
        }
        // 地址本身不是猫源脚本：这是导入时粘错了，不是网络问题。原样抛出网关
        // 已经写好的中文说明，再补一句该去哪儿改，否则「请求失败（400）」只会
        // 让人以为软件坏了。
        if text.contains("不是猫源脚本") || text.contains("没有找到猫源脚本") {
            return "\(text)。JS 源请用以 .js / .js.md5 结尾的地址；.jar（Java）和 .py（Python）源需要各自的运行时，当前宿主只内置了 JS。"
        }
        if code == 401 || code == 403 {
            return String(format: localized("源站拒绝访问（%ld），可能需要登录或 Cookie 已失效：%@"), code, text)
        }
        return String(format: localized("猫源请求失败（%ld）：%@"), code, text)
    }
}
