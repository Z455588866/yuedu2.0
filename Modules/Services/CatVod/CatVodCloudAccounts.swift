import Foundation
import Observation

/// Cloud-drive credentials used by the embedded spider gateway to play netdisk
/// sources (Quark / UC / Aliyun / Baidu / 115 / Tianyi / 123 / Guangya / Xunlei).
///
/// Ported from tvbox-silicon's `CloudDriveAccounts`: the same field names are
/// kept so existing plugin cookies/tokens can be pasted verbatim. Credentials
/// stay in the trusted app process and are handed to the gateway through
/// `cloudConfig`; third-party spider bundles never receive them.
struct CatVodCloudAccounts: Codable, Sendable, Equatable {
    var quarkCookie = ""
    var quarkServiceTicket = ""
    var ucCookie = ""
    var ucToken = ""
    /// Aliyun Drive refresh token (32 chars); spiders read it as `token`.
    var aliyunToken = ""
    var baiduCookie = ""
    var pan115Cookie = ""
    var tianyiToken = ""
    var pan123Token = ""
    var guangyaToken = ""
    var xunleiCookie = ""

    enum CodingKeys: String, CodingKey {
        case quarkCookie, quarkServiceTicket, ucCookie, ucToken
        case aliyunToken, baiduCookie, pan115Cookie, tianyiToken
        case pan123Token, guangyaToken, xunleiCookie
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        quarkCookie = try c.decodeIfPresent(String.self, forKey: .quarkCookie) ?? ""
        quarkServiceTicket = try c.decodeIfPresent(String.self, forKey: .quarkServiceTicket) ?? ""
        ucCookie = try c.decodeIfPresent(String.self, forKey: .ucCookie) ?? ""
        ucToken = try c.decodeIfPresent(String.self, forKey: .ucToken) ?? ""
        aliyunToken = try c.decodeIfPresent(String.self, forKey: .aliyunToken) ?? ""
        baiduCookie = try c.decodeIfPresent(String.self, forKey: .baiduCookie) ?? ""
        pan115Cookie = try c.decodeIfPresent(String.self, forKey: .pan115Cookie) ?? ""
        tianyiToken = try c.decodeIfPresent(String.self, forKey: .tianyiToken) ?? ""
        pan123Token = try c.decodeIfPresent(String.self, forKey: .pan123Token) ?? ""
        guangyaToken = try c.decodeIfPresent(String.self, forKey: .guangyaToken) ?? ""
        xunleiCookie = try c.decodeIfPresent(String.self, forKey: .xunleiCookie) ?? ""
    }

    /// Shape consumed by the gateway's `config.cloudConfig`. Spiders and the
    /// built-in cloud actions read these exact keys.
    var gatewayConfig: [String: String] {
        var result: [String: String] = [:]
        func put(_ key: String, _ value: String) { if !value.isEmpty { result[key] = value } }
        put("quarkCookie", quarkCookie)
        put("quarkServiceTicket", quarkServiceTicket)
        put("ucCookie", ucCookie)
        put("ucToken", ucToken)
        // The plugin protocol calls the Aliyun refresh token simply `token`.
        put("token", aliyunToken)
        put("baiduCookie", baiduCookie)
        put("pan115Cookie", pan115Cookie)
        put("tianyiToken", tianyiToken)
        put("pan123Token", pan123Token)
        put("guangyaToken", guangyaToken)
        put("xunleiCookie", xunleiCookie)
        return result
    }

    var hasAnyCredential: Bool { !gatewayConfig.isEmpty }
}

/// Categories used by the account-configuration UI.
enum CatVodCloudProvider: String, CaseIterable, Identifiable, Sendable {
    case quark, uc, aliyun, baidu, pan115, tianyi, pan123, guangya, xunlei

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quark: return localized("夸克网盘")
        case .uc: return localized("UC网盘")
        case .aliyun: return localized("阿里云盘")
        case .baidu: return localized("百度网盘")
        case .pan115: return localized("115网盘")
        case .tianyi: return localized("天翼云盘")
        case .pan123: return localized("123云盘")
        case .guangya: return localized("光年/广雅")
        case .xunlei: return localized("迅雷云盘")
        }
    }

    /// Short hint describing what to paste for this provider.
    var credentialHint: String {
        switch self {
        case .quark: return localized("Cookie（含 __pus=），可选 Service Ticket")
        case .uc: return localized("Cookie（含 __pus=）")
        case .aliyun: return localized("Refresh Token（32 位）")
        case .baidu: return localized("Cookie（BDUSS / STOKEN / PTOKEN）")
        case .pan115: return localized("Cookie（UID / CID / SEID / KID）")
        case .tianyi: return localized("Access Token")
        case .pan123: return localized("Bearer Token")
        case .guangya: return localized("Token")
        case .xunlei: return localized("Cookie")
        }
    }
}

/// Persists cloud-drive credentials and pushes them live into the Node gateway.
@MainActor
@Observable
final class CatVodCloudAccountStore {
    static let shared = CatVodCloudAccountStore()

    private static let storageKey = "yd_catvod_cloud_accounts"
    private let defaults: UserDefaults

    private(set) var accounts: CatVodCloudAccounts

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(CatVodCloudAccounts.self, from: data) {
            accounts = decoded
        } else {
            accounts = CatVodCloudAccounts()
        }
    }

    /// Updates one provider's credential(s) and refreshes the live gateway config.
    func set(provider: CatVodCloudProvider, primary: String, secondary: String = "") {
        switch provider {
        case .quark:
            accounts.quarkCookie = primary
            if !secondary.isEmpty { accounts.quarkServiceTicket = secondary }
        case .uc:
            accounts.ucCookie = primary
            if !secondary.isEmpty { accounts.ucToken = secondary }
        case .aliyun: accounts.aliyunToken = primary
        case .baidu: accounts.baiduCookie = primary
        case .pan115: accounts.pan115Cookie = primary
        case .tianyi: accounts.tianyiToken = primary
        case .pan123: accounts.pan123Token = primary
        case .guangya: accounts.guangyaToken = primary
        case .xunlei: accounts.xunleiCookie = primary
        }
        persist()
        refreshGateway()
    }

    func credential(for provider: CatVodCloudProvider) -> (primary: String, secondary: String) {
        switch provider {
        case .quark: return (accounts.quarkCookie, accounts.quarkServiceTicket)
        case .uc: return (accounts.ucCookie, accounts.ucToken)
        case .aliyun: return (accounts.aliyunToken, "")
        case .baidu: return (accounts.baiduCookie, "")
        case .pan115: return (accounts.pan115Cookie, "")
        case .tianyi: return (accounts.tianyiToken, "")
        case .pan123: return (accounts.pan123Token, "")
        case .guangya: return (accounts.guangyaToken, "")
        case .xunlei: return (accounts.xunleiCookie, "")
        }
    }

    func clear(provider: CatVodCloudProvider) { set(provider: provider, primary: "", secondary: "") }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Pushes the latest cloudConfig into the running engine. Safe before the
    /// engine starts (it is applied on the next `ensureStarted` as well).
    func refreshGateway() {
        CatVodGateway.shared.applyCloudConfig(accounts.gatewayConfig)
    }
}
