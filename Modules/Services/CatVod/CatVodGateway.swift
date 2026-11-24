import Foundation
import YueduNodeRuntime

/// Owns the single in-process Node.js engine that runs CatVod spider bundles.
/// Adapted from the mobile gateway validated in tvbox-Swift iOS build 28: the engine listens on
/// 127.0.0.1 on a random port with a per-launch token; all spider work happens in V8 workers.
@MainActor
final class CatVodGateway {
    static let shared = CatVodGateway()

    private let resourcesDirectory: URL
    private let entryPoint: URL
    private let cacheDirectory: URL
    /// Per-launch token the Node gateway requires on every spider request.
    /// Read by `CatVodService` to build the `Authorization: Bearer` header.
    let authenticationToken = UUID().uuidString + UUID().uuidString
    private var activeAllowedURLs: Set<String> = []
    /// Credentials for netdisk sources. Kept here so both the initial launch
    /// config and live updates after the engine started see the same value.
    private var cloudConfig: [String: String] = [:]

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
            "nodeBundleAllowChecksumRedirects": true
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        guard data.count <= 64 * 1024, let json = String(data: data, encoding: .utf8) else {
            throw CatVodError.invalidConfiguration
        }
        return json
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

        let json = try configurationJSON()

        YueduNodeRuntime.start(script: entryPoint.path,
                               assetsDirectory: resourcesDirectory.path,
                               runtimeDirectory: cacheDirectory.path,
                               configuration: json)

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let message = YueduNodeRuntime.startupError() {
                throw CatVodError.startupFailed(message)
            }
            if let urlString = YueduNodeRuntime.listeningURL(), let url = URL(string: urlString) {
                return url
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CatVodError.startupTimedOut
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
        // 网盘类线路：没登录时的提示原本是「请先在 TVBox 设置 → 网盘设置中保存
        // 夸克 Cookie」——我们的 App 里没有那个菜单，照着找永远找不到。
        if text.contains("网盘") || text.contains("登录") || text.contains("未配置")
            || lower.contains("cookie 未") || lower.contains("cookie未") {
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
            if text.contains("无法连接") || text.contains("连接失败") || text.contains("请稍后重试")
                || lower.contains("econnrefused") || lower.contains("etimedout")
                || lower.contains("socket hang up") || lower.contains("enotfound")
                || lower.contains("unavailable") {
                return localized("源站连不上（源自己的问题，不是 App 坏了）。稍后重试，或者换一个站点")
            }
            return String(format: localized("源站返回错误：%@"), text.isEmpty ? localized("未知原因") : text)
        }
        // 地址本身不是猫源脚本：这是导入时粘错了，不是网络问题。原样抛出网关
        // 已经写好的中文说明，再补一句该去哪儿改，否则「请求失败（400）」只会
        // 让人以为软件坏了。
        if text.contains("不是猫源脚本") || text.contains("没有找到猫源脚本") {
            return "\(text)。去「管理猫源」删掉这条，或换成以 .js / .js.md5 结尾的地址"
        }
        if code == 401 || code == 403 {
            return String(format: localized("源站拒绝访问（%ld），可能需要登录或 Cookie 已失效：%@"), code, text)
        }
        return String(format: localized("猫源请求失败（%ld）：%@"), code, text)
    }
}
