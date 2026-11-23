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
    private let authenticationToken = UUID().uuidString + UUID().uuidString
    private var activeAllowedURLs: Set<String> = []

    init(resourcesDirectory: URL? = nil, entryPoint: URL? = nil, cacheDirectory: URL? = nil) {
        let resources = resourcesDirectory
            ?? Bundle.main.bundleURL.appendingPathComponent("SpiderGateway", isDirectory: true)
        self.resourcesDirectory = resources
        self.entryPoint = entryPoint ?? resources.appendingPathComponent("mobile-entry.mjs")
        self.cacheDirectory = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Yuedu/CatVod", isDirectory: true)
    }

    /// Starts the engine (once per process) and returns its loopback base URL.
    /// `bundleURL` is the interface the user imported, added to the download allowlist.
    func ensureStarted(allowedBundleURL: String? = nil, replacingAllowlist: Bool = false) async throws -> URL {
        guard FileManager.default.fileExists(atPath: entryPoint.path) else {
            throw CatVodError.missingResources
        }
        let requested = Set(Self.allowedBundleURLs(for: allowedBundleURL))
        activeAllowedURLs = replacingAllowlist ? requested : activeAllowedURLs.union(requested)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let config: [String: Any] = [
            "token": authenticationToken,
            "cloudConfig": [String: String](),
            "cacheRoot": cacheDirectory.path,
            "nodeBundleAllowedURLs": activeAllowedURLs.sorted(),
            "nodeBundleAllowChecksumRedirects": true
        ]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        guard data.count <= 64 * 1024, let json = String(data: data, encoding: .utf8) else {
            throw CatVodError.invalidConfiguration
        }

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
        if components.percentEncodedPath.lowercased().hasSuffix(".js.md5") {
            components.percentEncodedPath = String(components.percentEncodedPath.dropLast(4))
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
        case .http(let code, let message): return String(format: localized("猫源请求失败（%ld）：%@"), code, message)
        case .emptyResponse: return localized("猫源返回空数据")
        }
    }
}
