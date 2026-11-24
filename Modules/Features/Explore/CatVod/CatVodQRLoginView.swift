import CoreImage.CIFilterBuiltins
import SwiftUI

/// 扫码登录一只网盘：拿官方二维码 → 用户用手机 App 扫 → 拿到 Cookie/Token →
/// 直接写进 `CatVodCloudAccountStore`，网盘线路立刻能播。
///
/// 这条链路对应影匣的 `CloudDriveQRLogin`：比「打开网页抓 Cookie」稳，因为
/// 不需要 WebView 的 Cookie 池，也不会被跨域/HttpOnly 拦掉。
@MainActor
struct CatVodQRLoginView: View {
    let provider: CatVodCloudProvider

    @State private var store = CatVodCloudAccountStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var login: CatVodQRLogin?
    @State private var phase: Phase = .loading
    @State private var message = ""
    @State private var attempt = 0

    private enum Phase: Equatable {
        case loading
        case waiting
        /// 已扫码，等手机确认。
        case scanned
        case done
        case failed
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 8)

                codeArea
                    .frame(width: 240, height: 240)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(DSColor.separator, lineWidth: 1)
                    }

                VStack(spacing: 8) {
                    Text(title)
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.textPrimary)
                    Text(hint)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                }

                if !message.isEmpty {
                    Text(message)
                        .font(DSFont.caption)
                        .foregroundStyle(phase == .failed ? Color.red : DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 8)

                if phase == .failed {
                    Button {
                        reload()
                    } label: {
                        Label(localized("重新获取二维码"), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .navigationTitle(localized("扫码登录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { dismiss() }
                }
            }
            .task(id: attempt) { await run() }
        }
    }

    // MARK: 二维码

    @ViewBuilder
    private var codeArea: some View {
        if phase == .done {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 76))
                .foregroundStyle(.green)
        } else if let image = login?.image {
            // 百度把二维码当图片给。
            AsyncImage(url: image) { state in
                switch state {
                case .success(let image):
                    image.resizable().scaledToFit().padding(10)
                default:
                    ProgressView()
                }
            }
        } else if let code = login?.code, let rendered = QRCodeRenderer.image(code) {
            Image(uiImage: rendered)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
        } else {
            ProgressView()
        }
    }

    private var title: String {
        switch phase {
        case .loading: return localized("正在获取二维码…")
        case .waiting: return String(format: localized("请用「%@」App 扫码"), provider.displayName)
        case .scanned: return localized("已扫码，请在手机上确认")
        case .done: return localized("登录成功")
        case .failed: return localized("二维码已失效")
        }
    }

    private var hint: String {
        switch phase {
        case .loading, .failed: return ""
        case .done: return localized("已经写入本机，网盘线路可以直接播放了。")
        case .scanned: return localized("确认后会自动完成登录，不用再点任何按钮。")
        case .waiting:
            return provider == .guangya
                ? localized("用光雅 App 扫码并确认，或直接打开二维码里的链接。")
                : localized("扫码后请在手机上点确认；全程在官方页面完成，App 不接触密码。")
        }
    }

    // MARK: 登录流程

    private func reload() {
        message = ""
        phase = .loading
        attempt += 1
    }

    private func run() async {
        phase = .loading
        message = ""
        do {
            let started = try await CatVodQRLogin.start(provider)
            guard !Task.isCancelled else { return }
            login = started
            phase = .waiting
            await poll(started)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func poll(_ started: CatVodQRLogin) async {
        let deadline = Date().addingTimeInterval(provider == .guangya ? 130 : 300)
        while !Task.isCancelled, Date() < deadline {
            // 百度的状态请求本身会挂住三十秒，所以间隔可以短。
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            do {
                switch try await started.poll() {
                case .waiting:
                    if phase == .loading { phase = .waiting }
                case .expired:
                    phase = .failed
                    message = localized("二维码已过期，请重新获取。")
                    return
                case .signedIn(let credentials):
                    finish(credentials)
                    return
                }
            } catch {
                // 单次轮询失败（网络抖动）不结束流程，等下一次。
                if let failure = error as? CatVodQRLoginError, !failure.message.isEmpty,
                   failure.message.localizedCaseInsensitiveContains("HTTP 4") {
                    phase = .failed
                    message = failure.message
                    return
                }
            }
        }
        guard !Task.isCancelled, phase != .done else { return }
        if phase != .failed {
            phase = .failed
            message = localized("二维码已过期，请重新获取。")
        }
    }

    private func finish(_ credentials: CatVodQRLogin.Credentials) {
        let values = Self.storeValues(for: provider, credentials)
        store.set(provider: provider, primary: values.primary, secondary: values.secondary)
        phase = .done
        message = ""
        // 留一眼「登录成功」，然后自己关掉。
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            dismiss()
        }
    }

    static func storeValues(for provider: CatVodCloudProvider,
                            _ credentials: CatVodQRLogin.Credentials) -> (primary: String, secondary: String) {
        switch provider {
        case .quark: return (credentials.cookie, credentials.serviceTicket ?? "")
        case .uc: return (credentials.cookie, "")
        case .baidu: return (credentials.cookie, "")
        case .aliyun: return (credentials.refreshToken ?? "", "")
        case .pan115: return (credentials.cookie, "")
        case .tianyi: return (credentials.accessToken ?? "", "")
        case .pan123: return (credentials.accessToken ?? "", "")
        case .guangya: return (credentials.accessToken ?? credentials.refreshToken ?? "", "")
        case .xunlei: return (credentials.cookie, "")
        }
    }
}

/// 二维码渲染（CoreImage）。`CIContext` 不是 Sendable，固定在主线程用。
@MainActor
enum QRCodeRenderer {
    private static let context = CIContext()
    private static let filter = CIFilter.qrCodeGenerator()

    static func image(_ code: String, scale: CGFloat = 10) -> UIImage? {
        guard !code.isEmpty else { return nil }
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
