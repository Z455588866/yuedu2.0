import Foundation

/// 记住哪些站点最近反复失败，让它们沉到选择列表底部，并让「整站为空就换下一个」
/// 的兜底逻辑跳过它们。
///
/// 为什么需要：源站质量差异极大，一个接口里几十个站点，坏的那几个每次点进去都要
/// 走完整个超时预算（12s）才报错。人看到的是「这个 App 好慢」，实际是同一个坏站点
/// 被反复撞。这里不猜原因、不降级功能，只做一件事：失败过的排后面，冷却期过后
/// 自动恢复候选资格——源站修好了不需要用户手动清缓存。
@MainActor
final class CatVodSourceHealth {
    static let shared = CatVodSourceHealth()

    /// 连续失败多少次才判定为「坏」。一次超时可能只是当下弱网，不该影响排序。
    private static let failuresBeforePenalty = 2
    /// 冷却时长。20 分钟后重新给机会，失败一次就再次沉底。
    private static let cooldown: TimeInterval = 20 * 60
    private static let storageKey = "CatVodSourceHealth.v1"

    private struct Record: Codable {
        var failures: Int
        var downSince: Date?
    }

    private var records: [String: Record] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        }
    }

    /// 站点在某个接口下的稳定标识：同一个 key 在不同接口里是两回事。
    private func id(bundleURL: String, siteKey: String) -> String {
        "\(bundleURL)|\(siteKey)"
    }

    /// 当前是否处于「刚失败过」的冷却期。
    func isDown(bundleURL: String, siteKey: String) -> Bool {
        guard let record = records[id(bundleURL: bundleURL, siteKey: siteKey)],
              record.failures >= Self.failuresBeforePenalty,
              let since = record.downSince else { return false }
        return Date().timeIntervalSince(since) < Self.cooldown
    }

    /// 把一次失败归类：只有「源站这条请求没做成」才算站点有问题。
    ///
    /// 空响应不算——豆瓣类聚合条目本来就没有剧集，把它记成坏站会让一个正常的
    /// 站点被永久沉底。参数错误、脚本引擎启动失败也不算，那些跟站点无关。
    func note(error: Error, bundleURL: String, siteKey: String) {
        guard let catError = error as? CatVodError else { return }
        switch catError {
        case .http(let code, _) where (500...599).contains(code) || code == 408:
            recordFailure(bundleURL: bundleURL, siteKey: siteKey)
        default:
            return
        }
    }

    func recordSuccess(bundleURL: String, siteKey: String) {
        let key = id(bundleURL: bundleURL, siteKey: siteKey)
        guard records[key] != nil else { return }
        records.removeValue(forKey: key)
        persist()
    }

    func recordFailure(bundleURL: String, siteKey: String) {        let key = id(bundleURL: bundleURL, siteKey: siteKey)
        var record = records[key] ?? Record(failures: 0, downSince: nil)
        // 冷却期已过还失败：重新计数，让它再拿一次机会而不是永久沉底。
        if let since = record.downSince, Date().timeIntervalSince(since) >= Self.cooldown {
            record = Record(failures: 0, downSince: nil)
        }
        record.failures += 1
        if record.failures >= Self.failuresBeforePenalty, record.downSince == nil {
            record.downSince = Date()
        }
        records[key] = record
        persist()
    }

    /// 把健康的站点排在前面，顺序其余部分保持接口声明顺序——站点顺序是源作者排的，
    /// 只有在明确失败过的情况下才值得打乱。
    func arranged(_ sites: [CatVodSite], bundleURL: String) -> [CatVodSite] {
        let down = sites.map { isDown(bundleURL: bundleURL, siteKey: $0.key) }
        guard down.contains(true) else { return sites }
        let healthy = sites.indices.filter { !down[$0] }.map { sites[$0] }
        let failing = sites.indices.filter { down[$0] }.map { sites[$0] }
        return healthy + failing
    }

    /// 冷却进程结束后清掉过期的记录，避免长期使用后文件无限增长。
    func prune(bundleURL: String) {
        let prefix = "\(bundleURL)|"
        let before = records.count
        records = records.filter { key, record in
            guard key.hasPrefix(prefix) else { return true }
            guard let since = record.downSince else { return true }
            return Date().timeIntervalSince(since) < Self.cooldown
        }
        if records.count != before { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
