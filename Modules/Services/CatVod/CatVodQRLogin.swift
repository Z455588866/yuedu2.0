import CryptoKit
import Foundation

/// 网盘扫码登录（移植自 tvbox-silicon 的 `CloudDriveQRLogin`）。
///
/// 猫源里的网盘线路能不能播，取决于宿主有没有对应网盘的登录态。手工粘贴
/// Cookie 对普通用户几乎不可能，所以这里照搬影匣的做法：App 自己发起官方
/// 的扫码登录，拿到与网页版同一套 Cookie / Token，写进 `CatVodCloudAccountStore`，
/// 再由网关注入给插件。
///
/// - 夸克 / UC：扫码通过后用小票换 service ticket，再走账号页拿 Cookie。
/// - 百度：passport 二维码，回传 BDUSS / STOKEN / PTOKEN。
/// - 阿里云盘：二维码通过后 `bizExt` 里带 refreshToken。
/// - 115：客户端二维码，回传 UID / CID / SEID / KID。
/// - 天翼云盘：TV 端二维码，回传 e189AccessToken。
/// - 123 云盘：网页二维码（也支持微信扫码），回传 Bearer token。
/// - 光雅云盘：设备码（OAuth 2 device flow），回传 access + refresh。
struct CatVodQRLogin: Sendable {
    struct Credentials: Sendable, Equatable {
        var cookie = ""
        var serviceTicket: String?
        var refreshToken: String?
        var accessToken: String?
    }

    enum Status: Sendable, Equatable {
        case waiting
        case expired
        case signedIn(Credentials)
    }

    let provider: CatVodCloudProvider
    /// 二维码里的文本；百度把二维码当图片给。
    let code: String
    /// 百度专用：二维码图片地址。
    let image: URL?

    private let token: String
    private let state: [String: String]
    /// 百度的登录跨多个请求，要共用 Cookie。
    private let session: URLSession?

    private init(provider: CatVodCloudProvider, code: String, image: URL? = nil,
                 token: String, state: [String: String] = [:], session: URLSession? = nil) {
        self.provider = provider
        self.code = code
        self.image = image
        self.token = token
        self.state = state
        self.session = session
    }

    /// 迅雷没有扫码登录接口，只能粘贴 Cookie。
    static func supports(_ provider: CatVodCloudProvider) -> Bool { provider != .xunlei }

    static func start(_ provider: CatVodCloudProvider) async throws -> CatVodQRLogin {
        switch provider {
        case .baidu: return try await startBaidu()
        case .aliyun: return try await startAliyun()
        case .pan115: return try await start115()
        case .tianyi: return try await startTianyi()
        case .pan123: return try await start123()
        case .guangya: return try await startGuangya()
        case .xunlei: throw CatVodQRLoginError("迅雷网盘没有扫码登录，请在网页登录后粘贴 Cookie")
        case .quark, .uc: break
        }
        let members = try await quarkFamilyMembers(provider, "getTokenForQrcodeLogin", [:])
        guard let token = members?["token"] as? String, !token.isEmpty else {
            throw CatVodQRLoginError("获取登录二维码失败，请重试")
        }
        return CatVodQRLogin(provider: provider, code: quarkFamilyPage(provider, token), token: token)
    }

    func poll() async throws -> Status {
        switch provider {
        case .baidu: return try await pollBaidu()
        case .aliyun: return try await pollAliyun()
        case .pan115: return try await poll115()
        case .tianyi: return try await pollTianyi()
        case .pan123: return try await poll123()
        case .guangya: return try await pollGuangya()
        case .quark, .uc, .xunlei: break
        }
        let (status, members) = try await Self.quarkFamilyCall(provider, "getServiceTicketByQrcodeToken", ["token": token])
        switch status {
        case 2_000_000:
            guard let ticket = members?["service_ticket"] as? String else { return .expired }
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            return .signedIn(try await Self.completeQuarkFamily(provider, ticket: ticket, session: session))
        case 50_004_001: return .waiting
        default: return .expired
        }
    }

    // MARK: 夸克 / UC

    private static func quarkFamilyMembers(_ provider: CatVodCloudProvider, _ action: String,
                                           _ query: [String: String]) async throws -> [String: Any]? {
        let (status, members) = try await quarkFamilyCall(provider, action, query)
        guard status == 2_000_000 else { throw CatVodQRLoginError("获取登录二维码失败，请重试") }
        return members
    }

    private static func quarkFamilyCall(_ provider: CatVodCloudProvider, _ action: String,
                                        _ query: [String: String]) async throws -> (Int, [String: Any]?) {
        var components = URLComponents(string: quarkFamilyHost(provider) + "/cas/ajax/" + action)!
        components.queryItems = (["client_id": quarkFamilyClientID(provider), "v": "1.2",
                                   "request_id": UUID().uuidString.lowercased()]
            .merging(query) { $1 })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, _) = try await URLSession.shared.data(for: quarkFamilyRequest(components.url!, provider))
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let status = (object?["status"] as? NSNumber)?.intValue ?? 0
        return (status, (object?["data"] as? [String: Any])?["members"] as? [String: Any])
    }

    /// 小票换 Cookie。夸克还要一个移动端 service ticket：只带网页 Cookie 时
    /// 播放器会再次要求扫码。
    static func completeQuarkFamily(_ provider: CatVodCloudProvider, ticket: String,
                                    session: URLSession) async throws -> Credentials {
        var components = URLComponents(string: quarkFamilyAccountPage(provider))!
        components.queryItems = [URLQueryItem(name: "st", value: ticket), URLQueryItem(name: "lw", value: "scan")]
        let (_, response) = try await session.data(for: quarkFamilyRequest(components.url!, provider))
        try check(response)
        let serviceTicket = provider == .quark ? try await quarkMobileTicket(ticket, session: session) : nil
        var fields: [String: String] = [:]
        for cookie in session.configuration.httpCookieStorage?.cookies ?? [] {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if domain == quarkFamilyDomain(provider) || domain.hasSuffix("." + quarkFamilyDomain(provider)) {
                fields[cookie.name] = cookie.value
            }
        }
        guard fields["__pus"]?.isEmpty == false else {
            throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
        }
        let cookie = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return Credentials(cookie: cookie, serviceTicket: serviceTicket)
    }

    /// 夸克的移动端 service ticket。这里手工编码：用 URLComponents 拼查询会把
    /// `+` 和 `/` 原样留下，夸克那边就把 `+` 当空格了。
    static func quarkMobileTicket(_ ticket: String, session: URLSession = .shared,
                                  cookie: String? = nil) async throws -> String {
        let encoded = ticket.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))) ?? ticket
        for client in ["h5", "pc"] {
            guard let url = URL(string: "https://pan.quark.cn/account/mobileinfo?pr=ucpro&fr=\(client)&st=\(encoded)") else { continue }
            var info = quarkFamilyRequest(url, .quark)
            if let cookie { info.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let (data, response) = try await session.data(for: info)
            try check(response)
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if object?["success"] as? Bool == true,
               let serviceTicket = (object?["data"] as? [String: Any])?["serviceTicket"] as? String,
               !serviceTicket.isEmpty {
                return serviceTicket
            }
        }
        throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
    }

    // MARK: 百度网盘

    private static func startBaidu() async throws -> CatVodQRLogin {
        let configuration = URLSessionConfiguration.ephemeral
        // 状态请求会被挂住，最长约 30 秒。
        configuration.timeoutIntervalForRequest = 45
        let session = URLSession(configuration: configuration)
        let gid = UUID().uuidString.uppercased(), time = milliseconds()
        var components = URLComponents(string: "https://passport.baidu.com/v2/api/getqrcode")!
        components.queryItems = [("lp", "pc"), ("qrloginfrom", "pc"), ("gid", gid),
                                 ("callback", "tangram_guid_\(time)"), ("apiver", "v3"),
                                 ("tt", "\(time)"), ("tpl", "netdisk"),
                                 ("logPage", "traceId:pc_loginv5_\(time),logPage:loginv5"), ("_", "\(time)")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        let object = try await jsonp(session, components.url!)
        guard let address = object["imgurl"] as? String, let sign = object["sign"] as? String, !sign.isEmpty,
              let image = URL(string: address.hasPrefix("http") ? address : "https://" + address) else {
            throw CatVodQRLoginError("获取登录二维码失败，请重试")
        }
        return CatVodQRLogin(provider: .baidu, code: "", image: image, token: sign,
                             state: ["gid": gid], session: session)
    }

    private func pollBaidu() async throws -> Status {
        guard let session, let gid = state["gid"] else { return .expired }
        let time = Self.milliseconds()
        var components = URLComponents(string: "https://passport.baidu.com/channel/unicast")!
        components.queryItems = [("channel_id", token), ("gid", gid), ("tpl", "netdisk"), ("_sdkFrom", "1"),
                                 ("callback", "tangram_guid_\(time)"), ("apiver", "v3"), ("tt", "\(time)"), ("_", "\(time)")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        let object = try await Self.jsonp(session, components.url!)
        // errno 1：请求挂住期间没有任何动作。
        let errno = (object["errno"] as? NSNumber)?.intValue ?? -1
        if errno == 1 { return .waiting }
        guard errno == 0, let channel = (object["channel_v"] as? String)?.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: channel) as? [String: Any] else { return .expired }
        switch (value["status"] as? NSNumber)?.intValue {
        case 1: return .waiting  // 已扫码，未确认
        case 0:
            guard let temporary = value["v"] as? String, !temporary.isEmpty else { return .expired }
            return .signedIn(try await completeBaidu(temporary, session: session))
        default: return .expired
        }
    }

    private func completeBaidu(_ temporary: String, session: URLSession) async throws -> Credentials {
        let time = Self.milliseconds()
        var components = URLComponents(string: "https://passport.baidu.com/v3/login/main/qrbdusslogin")!
        components.queryItems = [("v", "\(time)"), ("bduss", temporary), ("u", "https://pan.baidu.com/disk/home"),
                                 ("loginVersion", "v4"), ("qrcode", "1"), ("tpl", "netdisk"), ("apiver", "v3"),
                                 ("tt", "\(time)"), ("traceid", ""), ("time", "\(time / 1000)"), ("alg", "v3"),
                                 ("callback", "bd__cbs__\(Int.random(in: 100_000...999_999))")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        let (_, response) = try await session.data(for: Self.baiduRequest(components.url!))
        try Self.check(response)
        var fields: [String: String] = [:]
        for cookie in session.configuration.httpCookieStorage?.cookies ?? [] where cookie.domain.hasSuffix("baidu.com") {
            if ["BDUSS", "STOKEN", "PTOKEN"].contains(cookie.name), !cookie.value.isEmpty {
                fields[cookie.name] = cookie.value
            }
        }
        guard fields["BDUSS"] != nil else {
            throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
        }
        let cookie = fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return Credentials(cookie: cookie)
    }

    private static func jsonp(_ session: URLSession, _ url: URL) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: baiduRequest(url))
        try check(response)
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else {
            throw CatVodQRLoginError("获取登录二维码失败，请重试")
        }
        return object
    }

    private static func baiduRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue(browser, forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
        return request
    }

    // MARK: 阿里云盘

    private static let aliyunQuery: [(String, String)] = [("appName", "aliyun_drive"), ("fromSite", "52"), ("_bx-v", "2.2.3")]

    private static func startAliyun() async throws -> CatVodQRLogin {
        var components = URLComponents(string: "https://passport.aliyundrive.com/newlogin/qrcode/generate.do")!
        components.queryItems = (aliyunQuery + [("appEntrance", "web"), ("isMobile", "false"), ("lang", "zh_CN"),
                                                ("returnUrl", ""), ("bizParams", "")])
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        let (data, response) = try await URLSession.shared.data(for: aliyunRequest(components.url!))
        try check(response)
        let content = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [String: Any])?["data"] as? [String: Any]
        guard let code = content?["codeContent"] as? String, let ck = content?["ck"] as? String, let time = content?["t"] else {
            throw CatVodQRLoginError("获取登录二维码失败，请重试")
        }
        return CatVodQRLogin(provider: .aliyun, code: code, token: ck, state: ["t": "\(time)"])
    }

    private func pollAliyun() async throws -> Status {
        var components = URLComponents(string: "https://passport.aliyundrive.com/newlogin/qrcode/query.do")!
        components.queryItems = Self.aliyunQuery.map { URLQueryItem(name: $0.0, value: $0.1) }
        var request = Self.aliyunRequest(components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [("t", state["t"] ?? ""), ("ck", token), ("appName", "aliyun_drive"),
                           ("appEntrance", "web"), ("isMobile", "false"), ("lang", "zh_CN"), ("returnUrl", ""),
                           ("fromSite", "52"), ("bizParams", ""), ("navlanguage", "zh-CN"), ("navPlatform", "MacIntel")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response)
        let content = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["content"] as? [String: Any])?["data"] as? [String: Any]
        switch content?["qrCodeStatus"] as? String {
        case "NEW", "SCANED": return .waiting
        case "CONFIRMED":
            guard let token = (content?["bizExt"] as? String).flatMap(Self.aliyunRefreshToken) else {
                throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
            }
            return .signedIn(Credentials(refreshToken: token))
        default: return .expired
        }
    }

    /// `bizExt` 是 JSON 的 base64（原文可能是 GBK）；只取其中的 ASCII refresh token。
    static func aliyunRefreshToken(_ bizExt: String) -> String? {
        guard let data = Data(base64Encoded: bizExt) else { return nil }
        let text = String(decoding: data.map { $0 < 0x80 ? $0 : 0x20 }, as: UTF8.self)
        guard let match = text.firstMatch(of: /"refreshToken"\s*:\s*"([0-9A-Za-z]+)"/) else { return nil }
        return String(match.1)
    }

    private static func aliyunRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(browser, forHTTPHeaderField: "User-Agent")
        request.setValue("https://passport.aliyundrive.com/", forHTTPHeaderField: "Referer")
        return request
    }

    // MARK: 115

    private static let pan115App = "tv"
    private static let pan115UserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 115Browser/27.0.5.7"

    private static func start115() async throws -> CatVodQRLogin {
        let (data, response) = try await URLSession.shared.data(for: pan115Request(URL(string: "https://qrcodeapi.115.com/api/1.0/web/1.0/token/")!))
        try check(response)
        let session = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]
        guard let uid = session?["uid"] as? String, let sign = session?["sign"] as? String,
              let time = session?["time"] as? NSNumber, let code = session?["qrcode"] as? String,
              !uid.isEmpty, !code.isEmpty else {
            throw CatVodQRLoginError("获取登录二维码失败，请重试")
        }
        return CatVodQRLogin(provider: .pan115, code: code, token: uid,
                             state: ["time": time.stringValue, "sign": sign])
    }

    private func poll115() async throws -> Status {
        var components = URLComponents(string: "https://qrcodeapi.115.com/get/status/")!
        components.queryItems = [("uid", token), ("time", state["time"] ?? ""), ("sign", state["sign"] ?? ""),
                                 ("_", "\(Self.milliseconds())")]
            .map { URLQueryItem(name: $0.0, value: $0.1) }
        // 状态请求会被挂住，最长约 30 秒。
        let (data, response) = try await URLSession.shared.data(for: Self.pan115Request(components.url!, timeout: 45))
        try Self.check(response)
        switch Self.pan115Status(data) {
        case .some(2): return .signedIn(try await Self.complete115(token))
        case .some(let status) where status < 0: return .expired
        default: return .waiting
        }
    }

    /// 二维码状态：还没动静（nil）、0 等待、1 已扫、2 已通过、-1 过期、-2 取消。
    static func pan115Status(_ data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard (object["state"] as? NSNumber)?.intValue == 1 else { return -1 }
        return ((object["data"] as? [String: Any])?["status"] as? NSNumber)?.intValue
    }

    private static func complete115(_ uid: String) async throws -> Credentials {
        var request = pan115Request(URL(string: "https://passportapi.115.com/app/1.0/\(pan115App)/1.0/login/qrcode/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("account=\(uid)&app=\(pan115App)".utf8)
        // 返回的 Cookie 属于账号，要存进登录态，不能留在 App 的 Cookie 池里。
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try check(response)
        guard let cookie = pan115Cookie(data) else {
            throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
        }
        return Credentials(cookie: cookie)
    }

    /// `{"data": {"cookie": {"UID": …}}}` → "UID=…; CID=…; SEID=…; KID=…"。
    static func pan115Cookie(_ data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cookie = (object?["data"] as? [String: Any])?["cookie"] as? [String: Any] ?? [:]
        let fields = ["UID", "CID", "SEID", "KID"].compactMap { name in
            (cookie[name] as? String).flatMap { $0.isEmpty ? nil : (name, $0) }
        }
        guard Set(fields.map { $0.0 }).isSuperset(of: ["UID", "CID", "SEID"]) else { return nil }
        return fields.map { "\($0.0)=\($0.1)" }.joined(separator: "; ")
    }

    private static func pan115Request(_ url: URL, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(pan115UserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://115.com/", forHTTPHeaderField: "Referer")
        return request
    }

    // MARK: 天翼云盘（TV 端）

    private static let tianyiAPI = "https://api.cloud.189.cn"
    private static let tianyiAppKey = "600100885"
    private static let tianyiAppSecret = "fe5734c74c2f96a38157f420b32dc995"
    private static let tianyiUserAgent = "EcloudTV/6.5.5 (PJX110; unknown; home02) Android/35"
    private static let tianyiClient: [(String, String)] = [
        ("clientType", "FAMILY_TV"), ("version", "6.5.5"), ("channelId", "home02"), ("clientSn", "unknown"),
        ("model", "PJX110"), ("osFamily", "Android"), ("osVersion", "35"), ("networkAccessMode", "WIFI"),
        ("telecomsOperator", "46011"),
    ]

    private static func startTianyi() async throws -> CatVodQRLogin {
        let (data, _) = try await URLSession.shared.data(for: tianyiAppRequest("/family/manage/getQrCodeUUID.action", []))
        guard let uuid = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["uuid"] as? String,
              !uuid.isEmpty else {
            throw CatVodQRLoginError("获取登录二维码失败，请重试")
        }
        return CatVodQRLogin(provider: .tianyi, code: uuid, token: uuid,
                             state: ["started": "\(Date().timeIntervalSince1970)"])
    }

    private func pollTianyi() async throws -> Status {
        let (data, _) = try await URLSession.shared.data(for: Self.tianyiAppRequest("/family/manage/qrcodeLoginResult.action", [("uuid", token)]))
        switch Self.tianyiStatus(data) {
        case .signedIn(let credentials):
            // token 只有能开出会话才算数。
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            guard try await Self.tianyiSession(for: credentials.accessToken ?? "", using: session) else {
                throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
            }
            return .signedIn(credentials)
        case .expired: return .expired
        case .waiting:
            // 二维码有效期几分钟；服务端只说过没过。
            let started = Double(state["started"] ?? "") ?? Date().timeIntervalSince1970
            return Date().timeIntervalSince1970 - started > 300 ? .expired : .waiting
        }
    }

    /// 通过的小票返回 `{"accessToken": "…", "expiresIn": …}`；之前是 HTTP 400 + `res_code` "QrCodeRollLoginFail"。
    static func tianyiStatus(_ data: Data) -> Status {
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let token = answer["accessToken"] as? String, !token.isEmpty {
            return .signedIn(Credentials(accessToken: token))
        }
        let code = "\(answer["res_code"] ?? "")"
        if ["expire", "invalid", "notexist", "timeout"].contains(where: code.lowercased().contains) { return .expired }
        return .waiting
    }

    private static func tianyiAppRequest(_ path: String, _ query: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: tianyiAddress(path, query), timeoutInterval: 20)
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        request.setValue(timestamp, forHTTPHeaderField: "Timestamp")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-ID")
        request.setValue(tianyiAppKey, forHTTPHeaderField: "AppKey")
        request.setValue(tianyiSignature(tianyiAppSecret,
                                         "AppKey=\(tianyiAppKey)&Operate=GET&RequestURI=\(path)&Timestamp=\(timestamp)"),
                         forHTTPHeaderField: "AppSignature")
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
        request.setValue(tianyiUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// 用 access token 换 sessionKey / sessionSecret；失败返回 false。
    private static func tianyiSession(for token: String, using session: URLSession) async throws -> Bool {
        let path = "/family/manage/loginFamilyMerge.action"
        let (data, _) = try await session.data(for: tianyiAppRequest(path, [("e189AccessToken", token)]))
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let key = answer["sessionKey"] as? String ?? ""
        let secret = answer["sessionSecret"] as? String ?? ""
        return !key.isEmpty && !secret.isEmpty
    }

    private static func tianyiSignature(_ secret: String, _ text: String) -> String {
        HMAC<Insecure.SHA1>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: Data(secret.utf8)))
            .map { String(format: "%02X", $0) }.joined()
    }

    private static func tianyiAddress(_ path: String, _ query: [(String, String)]) -> URL {
        var components = URLComponents(string: tianyiAPI + path)!
        components.queryItems = (tianyiClient + query).map { URLQueryItem(name: $0.0, value: $0.1) }
        // `+` 会被当成空格。
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    // MARK: 123 云盘

    private static let pan123Login = "https://login.123pan.com/api"

    private static func start123() async throws -> CatVodQRLogin {
        let (data, response) = try await URLSession.shared.data(for: pan123Request(pan123Login + "/user/qr-code/generate"))
        try check(response)
        guard let (code, id) = pan123Code(data) else { throw CatVodQRLoginError("获取登录二维码失败，请重试") }
        return CatVodQRLogin(provider: .pan123, code: code, token: id)
    }

    /// 二维码文本：123 云盘 App（或微信）打开的页面，带二维码 id。
    static func pan123Code(_ data: Data) -> (code: String, id: String)? {
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let fields = answer?["data"] as? [String: Any]
        guard (answer?["code"] as? NSNumber)?.intValue == 0, let id = fields?["uniID"] as? String, !id.isEmpty,
              var page = URLComponents(string: (fields?["url"] as? String) ?? ""), page.scheme != nil else { return nil }
        page.queryItems = (page.queryItems ?? []).filter { !["env", "uniID", "source", "type"].contains($0.name) }
            + [("env", "production"), ("uniID", id), ("source", "123pan"), ("type", "login")].map { URLQueryItem(name: $0.0, value: $0.1) }
        return page.url.map { ($0.absoluteString, id) }
    }

    private func poll123() async throws -> Status {
        var components = URLComponents(string: Self.pan123Login + "/user/qr-code/result")!
        components.queryItems = [URLQueryItem(name: "uniID", value: token)]
        let (data, response) = try await URLSession.shared.data(for: Self.pan123Request(components.url!.absoluteString))
        try Self.check(response)
        switch Self.pan123Status(data) {
        case .some(.signedIn(let credentials)): return .signedIn(credentials)
        case .some(.expired): return .expired
        case .some(.waiting): return .waiting
        case nil:
            // 微信里通过：token 要从微信给的一次性 code 换。
            return .signedIn(try await Self.complete123WeChat(token))
        }
    }

    /// `{"code": 0, "data": {"loginStatus": 0 等待 / 1 已扫 / 2 拒绝 / 3 通过 / 4 过期}}`。
    /// 微信扫码通过（scanPlatform 4）时返回 nil，token 还要多一步。
    static func pan123Status(_ data: Data) -> Status? {
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let fields = answer["data"] as? [String: Any] ?? [:]
        if let token = pan123Token(fields) { return .signedIn(Credentials(accessToken: token)) }
        let code = (answer["code"] as? NSNumber)?.intValue ?? -1
        guard let status = (fields["loginStatus"] as? NSNumber)?.intValue else { return code == 0 ? .waiting : .expired }
        switch status {
        case 2, 4: return .expired
        case 3: return (fields["scanPlatform"] as? NSNumber)?.intValue == 4 ? nil : .expired
        default: return .waiting
        }
    }

    /// `token` 或 `accessToken`，去掉前面的 "Bearer "。
    static func pan123Token(_ fields: [String: Any]) -> String? {
        let token = ((fields["token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fields["accessToken"] as? String)?
            .replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespaces)
        return token?.isEmpty == false ? token : nil
    }

    private static func complete123WeChat(_ id: String) async throws -> Credentials {
        var request = pan123Request(pan123Login + "/user/qr-code/wx_code")
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["uniID": id])
        let (data, _) = try await URLSession.shared.data(for: request)
        let fields = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]) ?? [:]
        guard let code = ["wxCode", "WxCode", "code"].lazy.compactMap({ fields[$0] as? String }).first(where: { !$0.isEmpty }) else {
            throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
        }
        var signIn = pan123Request(pan123Login + "/user/sign_in")
        signIn.httpMethod = "POST"
        signIn.httpBody = try JSONSerialization.data(withJSONObject: ["from": "web", "wechat_code": code, "type": 4] as [String: Any])
        let (answer, _) = try await URLSession.shared.data(for: signIn)
        guard let token = (((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any])?["data"] as? [String: Any]).flatMap(pan123Token) else {
            throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
        }
        return Credentials(accessToken: token)
    }

    private static func pan123Request(_ address: String) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        for (field, value) in [("Content-Type", "application/json;charset=UTF-8"), ("platform", "web"),
                               ("app-version", "3"), ("Origin", "https://login.123pan.com"),
                               ("Referer", "https://login.123pan.com/"), ("User-Agent", browser)] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    // MARK: 光雅云盘

    private static let guangyaAccountAPI = "https://account.guangyapan.com"
    private static let guangyaClientID = "aMe-8VSlkrbQXpUR"
    private static let guangyaUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36"
    private static let guangyaReferer = "https://www.guangyapan.com/"

    /// 设备码：二维码里放的是地址，光雅 App 打开并确认；两分钟有效。
    private static func startGuangya() async throws -> CatVodQRLogin {
        let request = guangyaRequest(URL(string: guangyaAccountAPI + "/v1/auth/device/code")!,
                                     body: ["scope": "user", "client_id": guangyaClientID])
        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response)
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let device = answer?["device_code"] as? String,
              let code = answer?["verification_uri_complete"] as? String,
              !device.isEmpty, !code.isEmpty else {
            throw CatVodQRLoginError("获取登录二维码失败，请重试")
        }
        // 账号服务对过期的设备码仍在回 "authorization_pending"，所以自己记寿命。
        let lifetime = (answer?["expires_in"] as? NSNumber)?.doubleValue ?? 120
        return CatVodQRLogin(provider: .guangya, code: code, token: device,
                             state: ["expires": String(Date().timeIntervalSince1970 + lifetime)])
    }

    private func pollGuangya() async throws -> Status {
        if let expires = state["expires"].flatMap(Double.init), Date().timeIntervalSince1970 > expires { return .expired }
        let answer: [String: Any]
        do {
            answer = try await Self.guangyaToken(["grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                                                  "device_code": token])
        } catch let failure as CatVodQRLoginError {
            return Self.guangyaWaits(failure.message) ? .waiting : .expired
        }
        guard let access = answer["access_token"] as? String, let refresh = answer["refresh_token"] as? String,
              !refresh.isEmpty else {
            throw CatVodQRLoginError("扫码已通过，但网盘没有返回登录态，请重试")
        }
        // 网关认识 "access|refresh" 这一种写法。
        return .signedIn(Credentials(refreshToken: refresh, accessToken: "\(access)|\(refresh)"))
    }

    /// 设备码还在等确认；其它错误（"expired_token"、"access_denied"）就结束了。
    static func guangyaWaits(_ error: String) -> Bool {
        error == "authorization_pending" || error == "slow_down"
    }

    private static func guangyaToken(_ fields: [String: String]) async throws -> [String: Any] {
        let request = guangyaRequest(URL(string: guangyaAccountAPI + "/v1/auth/token")!,
                                     body: fields.merging(["client_id": guangyaClientID]) { $1 })
        let (data, _) = try await URLSession.shared.data(for: request)
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let access = answer["access_token"] as? String, !access.isEmpty { return answer }
        throw CatVodQRLoginError(answer["error"] as? String ?? "")
    }

    private static func guangyaRequest(_ url: URL, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(guangyaUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(guangyaReferer, forHTTPHeaderField: "Referer")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: 公共

    private static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private static func milliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private static func check(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatVodQRLoginError("登录服务返回 HTTP \(http.statusCode)，请稍后重试")
        }
    }

    private static func quarkFamilyRequest(_ url: URL, _ provider: CatVodCloudProvider) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(browser, forHTTPHeaderField: "User-Agent")
        request.setValue(provider == .quark ? "https://pan.quark.cn/" : "https://drive.uc.cn/",
                         forHTTPHeaderField: "Referer")
        return request
    }

    private static func quarkFamilyHost(_ provider: CatVodCloudProvider) -> String {
        provider == .quark ? "https://uop.quark.cn" : "https://api.open.uc.cn"
    }

    private static func quarkFamilyClientID(_ provider: CatVodCloudProvider) -> String {
        provider == .quark ? "532" : "381"
    }

    private static func quarkFamilyDomain(_ provider: CatVodCloudProvider) -> String {
        provider == .quark ? "quark.cn" : "uc.cn"
    }

    private static func quarkFamilyAccountPage(_ provider: CatVodCloudProvider) -> String {
        provider == .quark ? "https://pan.quark.cn/account/info" : "https://drive.uc.cn/account/info"
    }

    private static func quarkFamilyPage(_ provider: CatVodCloudProvider, _ token: String) -> String {
        provider == .quark
            ? "https://su.quark.cn/4_eMHBJ?token=\(token)&client_id=532&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
            : "https://su.uc.cn/1_n0ZCv?token=\(token)&client_id=381&uc_param_str=&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix"
    }
}

/// 登录失败的原因，`message` 直接给用户看。
struct CatVodQRLoginError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
