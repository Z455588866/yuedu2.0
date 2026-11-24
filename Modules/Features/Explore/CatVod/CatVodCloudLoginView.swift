import SwiftUI
import WebKit
import Combine

/// 「一键登录」网盘账号：在 App 内打开网盘**官方网页版**，用户用扫码、短信验证码
/// 或账号密码照常登录（就是官方页面自己支持的那些方式），点「完成」后自动把
/// Cookie（或 token）抓出来回填。
///
/// 为什么不自己画扫码界面：夸克 / UC / 百度的登录接口都没有公开 API，逆向它们的
/// 轮询接口会随时失效、还带着风控封号的风险；内置官方网页既合法，也不会因为接口
/// 变更而挂掉。
///
/// 只抓该网盘自身域名下的 Cookie；凭据留在本机，不会发给第三方猫源脚本。
struct CatVodCloudLoginView: View {
    let provider: CatVodCloudProvider
    /// 抓取成功后的回调：(主凭据, 次凭据)。
    let onCapture: (_ primary: String, _ secondary: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = CloudLoginBridge()
    @State private var isCapturing = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let url = provider.webLoginURL {
                    CloudLoginWebView(url: url, bridge: bridge)
                        .overlay(alignment: .top) {
                            if bridge.progress > 0 && bridge.progress < 1 {
                                ProgressView(value: bridge.progress)
                                    .progressViewStyle(.linear)
                                    .tint(DSColor.accent)
                                    .transition(.opacity)
                            }
                        }
                } else {
                    unavailable
                }
            }
            .navigationTitle(String(format: localized("登录%@"), provider.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(localized("取消")) { dismiss() }
                        .disabled(isCapturing)
                }
                if provider.webLoginURL != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        if isCapturing {
                            ProgressView().scaleEffect(0.85)
                        } else {
                            Button(localized("完成")) { capture() }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let failure {
                    Text(failure)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                }
            }
        }
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 34))
                .foregroundStyle(DSColor.textSecondary)
            Text(localized("该网盘没有可用的网页版登录"))
                .font(DSFont.headline)
                .foregroundStyle(DSColor.textPrimary)
            Text(localized("请返回手动填写凭据。"))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 抓取发生在点「完成」的这一刻，而不是页面加载完的那一刻——登录之后才下发的
    /// Cookie（以及验证码挑战过后才写入的 Cookie）只有这时才存在。
    private func capture() {
        guard !isCapturing, let collect = bridge.collect else { return }
        failure = nil
        isCapturing = true
        collect(provider) { cookieString in
            if let script = provider.tokenExtractionScript, let fetchToken = bridge.fetchToken {
                fetchToken(script) { token in
                    finish(cookie: cookieString, token: token)
                }
            } else {
                finish(cookie: cookieString, token: "")
            }
        }
    }

    private func finish(cookie: String, token: String) {
        isCapturing = false
        let value = provider.prefersToken ? (token.isEmpty ? cookie : token) : cookie
        guard !value.isEmpty else {
            failure = localized("没有检测到登录状态。请先在网页里完成登录，再点「完成」。")
            return
        }
        onCapture(value, "")
        dismiss()
    }
}

// MARK: - Bridge

/// 让 SwiftUI 的「完成」按钮能触发 WKWebView 内部的 Cookie / token 抓取。
@MainActor
final class CloudLoginBridge: ObservableObject {
    /// 抓 Cookie：(provider, 结果回调)。
    var collect: ((CatVodCloudProvider, @escaping (String) -> Void) -> Void)?
    /// 跑一段 JS 取 localStorage 里的 token：(脚本, 结果回调)。
    var fetchToken: ((String, @escaping (String) -> Void) -> Void)?
    /// 0…1，页面加载进度。
    @Published var progress: Double = 0
}

// MARK: - WebView

private struct CloudLoginWebView: UIViewRepresentable {
    let url: URL
    let bridge: CloudLoginBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences
        // 扫码 / 验证码常以新窗口弹出，不开这个自动打开会被拦掉。
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.observe(webView, bridge: bridge)

        // 与 SourceLoginWebView 相同的模式：闭包注入到 bridge，抓取逻辑留在 Coordinator，
        // 避免把 View 的 @State 捕获进 WebKit 的 @Sendable 回调里。
        let coordinator = context.coordinator
        bridge.collect = { provider, completion in
            guard let webView = coordinator.webView else { completion(""); return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let pairs = cookies.map {
                    CloudCookiePair(domain: $0.domain, name: $0.name, value: $0.value)
                }
                completion(CloudCredentialBuilder.cookieString(pairs, provider: provider))
            }
        }
        bridge.fetchToken = { script, completion in
            guard let webView = coordinator.webView else { completion(""); return }
            webView.evaluateJavaScript(script) { value, _ in
                completion((value as? String) ?? "")
            }
        }

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var observation: NSKeyValueObservation?

        func observe(_ webView: WKWebView, bridge: CloudLoginBridge) {
            observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak bridge] webView, _ in
                Task { @MainActor in
                    bridge?.progress = webView.estimatedProgress
                }
            }
        }
    }
}

// MARK: - Credential extraction

/// 一条 Cookie 的 Sendable 快照。
struct CloudCookiePair: Sendable {
    let domain: String
    let name: String
    let value: String
}

enum CloudCredentialBuilder {
    /// 按 provider 的域名白名单筛选 Cookie，优先保留该网盘真正读取的字段。
    /// 关键字段一个都没抓到，就退回该域名下的全部 Cookie——宁可多带，不要漏带。
    static func cookieString(_ pairs: [CloudCookiePair], provider: CatVodCloudProvider) -> String {
        let domains = provider.cookieDomains
        guard !domains.isEmpty else { return "" }
        let scoped = pairs.filter { pair in
            domains.contains { pair.domain.hasSuffix($0) || pair.domain.contains($0) }
        }
        guard !scoped.isEmpty else { return "" }

        var selected = scoped
        let essential = provider.essentialCookieNames
        if !essential.isEmpty {
            let filtered = scoped.filter { essential.contains($0.name) }
            if !filtered.isEmpty { selected = filtered }
        }

        var seen = Set<String>()
        var parts: [String] = []
        for pair in selected where !seen.contains(pair.name) {
            seen.insert(pair.name)
            parts.append("\(pair.name)=\(pair.value)")
        }
        return parts.joined(separator: "; ")
    }
}

// MARK: - Provider web-login metadata

extension CatVodCloudProvider {
    /// 官方网页版登录地址；`nil` 表示该网盘没有可用的网页登录。
    var webLoginURL: URL? {
        switch self {
        case .quark: return URL(string: "https://pan.quark.cn/")
        case .uc: return URL(string: "https://drive.uc.cn/")
        case .aliyun: return URL(string: "https://www.alipan.com/")
        case .baidu: return URL(string: "https://pan.baidu.com/")
        case .pan115: return URL(string: "https://115.com/")
        case .tianyi: return URL(string: "https://cloud.189.cn/")
        case .pan123: return URL(string: "https://www.123pan.com/")
        case .guangya: return nil
        case .xunlei: return URL(string: "https://pan.xunlei.com/")
        }
    }

    /// 只在这个范围里找 Cookie，避免把无关站点的凭据一起塞进去。
    var cookieDomains: [String] {
        switch self {
        case .quark: return ["quark.cn"]
        case .uc: return ["uc.cn"]
        case .aliyun: return ["aliyundrive.com", "alipan.com"]
        case .baidu: return ["baidu.com"]
        case .pan115: return ["115.com"]
        case .tianyi: return ["189.cn"]
        case .pan123: return ["123pan.com"]
        case .guangya: return []
        case .xunlei: return ["xunlei.com"]
        }
    }

    /// 该网盘爬虫真正读取的字段。抓到一个以上就只带这些；一个都没有就带上全部。
    var essentialCookieNames: Set<String> {
        switch self {
        case .quark: return ["__pus", "__puus", "__kp", "__uid"]
        case .uc: return ["__pus", "__puus", "__uid"]
        case .aliyun: return []
        case .baidu: return ["BDUSS", "BDUSS_BFESS", "STOKEN", "PTOKEN", "SAPI", "BAIDUID", "BAIDUID_BFESS", "PANWEB"]
        case .pan115: return ["UID", "CID", "SEID", "KID"]
        case .tianyi: return []
        case .pan123: return []
        case .guangya: return []
        case .xunlei: return ["sub", "uid", "deviceid"]
        }
    }

    /// 阿里云盘 / 天翼 / 123 的凭据不在 Cookie 里，而在网页的 localStorage。
    /// 读得到 JSON 就从中挑出 token，读不到就退回 Cookie。
    var tokenExtractionScript: String? {
        switch self {
        case .aliyun:
            return """
            (function(){
              try {
                var keys = ['token','TOKEN','aliyun_token','aliyundrive_token'];
                for (var i = 0; i < keys.length; i++) {
                  var raw = localStorage.getItem(keys[i]);
                  if (!raw) continue;
                  try {
                    var obj = JSON.parse(raw);
                    var t = obj.refresh_token || obj.refreshToken || obj.access_token || obj.accessToken;
                    if (t) return String(t);
                  } catch (e) {
                    if (raw.length >= 24) return raw;
                  }
                }
              } catch (e) {}
              return '';
            })()
            """
        case .tianyi:
            // 189 网页版的登录态是 cookie 里的 `sessionKey`（很多版本还同步写进
            // localStorage）。只读 localStorage 时经常拿到空串，于是「登录了但分类
            // 没有内容」——所以先宽范围找键名，再退回 document.cookie。
            return """
            (function(){
              try {
                var keys = ['sessionKey','SESSIONKEY','sessionkey','token','accessToken','access_token'];
                for (var i = 0; i < keys.length; i++) {
                  var v = localStorage.getItem(keys[i]);
                  if (v && v.length >= 16) {
                    try {
                      var o = JSON.parse(v);
                      var t = o.sessionKey || o.token || o.accessToken || o.access_token;
                      if (t) return String(t);
                    } catch (e) {}
                    return String(v);
                  }
                }
              } catch (e) {}
              try {
                var parts = String(document.cookie || '').split(';');
                for (var j = 0; j < parts.length; j++) {
                  var cut = parts[j].indexOf('=');
                  if (cut < 0) continue;
                  var name = parts[j].slice(0, cut).trim().toLowerCase();
                  var value = parts[j].slice(cut + 1).trim();
                  if ((name === 'sessionkey' || name === 'session_key') && value.length >= 16) return value;
                }
              } catch (e) {}
              return '';
            })()
            """
        case .pan123:
            return """
            (function(){
              try {
                var keys = ['token','TOKEN','userToken'];
                for (var i = 0; i < keys.length; i++) {
                  var v = localStorage.getItem(keys[i]);
                  if (v && v.length >= 16) return v;
                }
              } catch (e) {}
              return '';
            })()
            """
        default:
            return nil
        }
    }

    /// 该网盘的凭据形态是 token 而不是 Cookie。
    var prefersToken: Bool {
        switch self {
        case .aliyun, .tianyi, .pan123: return true
        default: return false
        }
    }
}
