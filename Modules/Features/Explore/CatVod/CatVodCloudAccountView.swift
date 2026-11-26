import SwiftUI

/// Netdisk account configuration for CatVod/cloud sources. Mirrors tvbox-silicon's
/// `CloudDriveView` credential entry: paste a cookie or token per provider; the
/// store pushes it into the trusted gateway so cloud-flavoured lines can play.
struct CatVodCloudAccountView: View {
    @State private var store = CatVodCloudAccountStore.shared
    @State private var editing: CatVodCloudProvider?
    @State private var scanning: CatVodCloudProvider?
    @State private var editingAList = false
    @State private var forceHighest = CatVodQualityPreference.forceHighest

    var body: some View {
        List {
            Section {
                Text(localized("在此填写各网盘的 Cookie / Token，猫源中来自对应网盘的线路即可直接播放。凭据只保存在本机，不会发给第三方猫源脚本。"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }

            Section {
                Toggle(localized("强制最高画质 / 原画"), isOn: $forceHighest)
                    .onChange(of: forceHighest) { _, value in
                        CatVodQualityPreference.forceHighest = value
                    }
            } footer: {
                Text(localized("开启后，猫源/网盘给出多档清晰度或 HLS 多档码率时，播放器自动选最高档；只给转码流时仍需要对应网盘会员才能拿到原画。"))
                    .dsSectionFooter()
            }

            Section {
                ForEach(CatVodCloudProvider.allCases) { provider in
                    let credential = store.credential(for: provider)
                    HStack(spacing: 8) {
                        Button {
                            editing = provider
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: provider.icon)
                                    .foregroundStyle(credential.primary.isEmpty ? DSColor.textSecondary : Color.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider.displayName)
                                        .font(DSFont.subheadline.weight(.semibold))
                                        .foregroundStyle(DSColor.textPrimary)
                                    Text(credential.primary.isEmpty
                                         ? localized("未配置")
                                         : String(format: localized("已配置 · %@"), masked(credential.primary)))
                                        .font(DSFont.caption2)
                                        .foregroundStyle(DSColor.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if CatVodQRLogin.supports(provider) {
                            Button {
                                scanning = provider
                            } label: {
                                Label(localized("扫码"), systemImage: "qrcode.viewfinder")
                                    .labelStyle(.iconOnly)
                                    .font(.system(size: 17))
                                    .frame(width: 34, height: 30)
                            }
                            .buttonStyle(.borderless)
                            .tint(Color.accentColor)
                            .accessibilityLabel(String(format: localized("扫描二维码登录%@"), provider.displayName))
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
            } header: {
                Text(localized("网盘平台"))
            }

            Section {
                Button {
                    editingAList = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(store.alistServers.isEmpty ? DSColor.textSecondary : Color.accentColor)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(localized("AList / OpenList 服务器"))
                                .font(DSFont.subheadline.weight(.semibold))
                                .foregroundStyle(DSColor.textPrimary)
                            Text(store.alistServers.isEmpty
                                 ? localized("未配置")
                                 : localized("已配置 · 点按管理服务器列表"))
                                .font(DSFont.caption2)
                                .foregroundStyle(DSColor.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text(localized("填 AList / OpenList 的 TVBox 配置数组，可在「我的网盘」里浏览并按原画质播放服务器里的视频。"))
                    .dsSectionFooter()
            }

            if store.accounts.hasAnyCredential {
                Section {
                    Button(role: .destructive) {
                        clearAll()
                    } label: {
                        Label(localized("清空全部账号"), systemImage: "trash")
                    }
                }
            }
        }
        .softScrollEdges()
        .navigationTitle(localized("网盘账号"))
        .navigationBarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .sheet(item: $editing) { provider in
            credentialSheet(provider)
        }
        .sheet(item: $scanning) { provider in
            CatVodQRLoginView(provider: provider)
        }
        .sheet(isPresented: $editingAList) {
            AListConfigView()
        }
    }

    private func masked(_ value: String) -> String {
        guard value.count > 8 else { return "••••" }
        return String(value.prefix(4)) + "••••" + String(value.suffix(4))
    }

    private func clearAll() {
        for provider in CatVodCloudProvider.allCases {
            store.clear(provider: provider)
        }
    }

    private func credentialSheet(_ provider: CatVodCloudProvider) -> some View {
        CredentialEditView(provider: provider)
    }
}

/// Two-field credential editor (primary cookie/token + optional secondary,
/// used by Quark's Service Ticket and UC's token).
private struct CredentialEditView: View {
    let provider: CatVodCloudProvider
    @State private var store = CatVodCloudAccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var primary = ""
    @State private var secondary = ""
    @State private var showsWebLogin = false
    @State private var showsQRLogin = false

    var body: some View {
        NavigationStack {
            List {
                if CatVodQRLogin.supports(provider) {
                    Section {
                        Button {
                            showsQRLogin = true
                        } label: {
                            Label(localized("扫码登录（推荐）"), systemImage: "qrcode.viewfinder")
                        }
                    } footer: {
                        Text(localized("用手机上的网盘 App 扫二维码并确认，登录态自动写入，不用复制 Cookie。"))
                            .dsSectionFooter()
                    }
                }

                if provider.webLoginURL != nil {
                    Section {
                        Button {
                            showsWebLogin = true
                        } label: {
                            Label(localized("打开网页登录"), systemImage: "person.badge.key")
                        }
                    } footer: {
                        Text(localized("打开网盘官方网页，扫码、短信验证码或账号密码登录后点「完成」，会自动填入凭据，不用手动复制 Cookie。"))
                            .dsSectionFooter()
                    }
                }

                Section {
                    Text(provider.credentialHint)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
                Section {
                    TextEditor(text: $primary)
                        .font(DSFont.footnote)
                        .frame(minHeight: 100)
                    TextEditor(text: $secondary)
                        .font(DSFont.footnote)
                        .frame(minHeight: 60)
                } header: {
                    Text(localized("凭据（Cookie / Token）"))
                } footer: {
                    if provider == .quark || provider == .uc {
                        Text(localized("第二个输入框可选，用于 Service Ticket / Token。"))
                            .dsSectionFooter()
                    }
                }
                if !store.credential(for: provider).primary.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            store.clear(provider: provider)
                            dismiss()
                        } label: {
                            Label(localized("清除此网盘凭据"), systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("保存")) {
                        store.set(provider: provider,
                                  primary: primary.trimmingCharacters(in: .whitespacesAndNewlines),
                                  secondary: secondary.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
            .themedAppSurface(for: .settings)
        }
        .task {
            let existing = store.credential(for: provider)
            primary = existing.primary
            secondary = existing.secondary
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showsWebLogin) {
            CatVodCloudLoginView(provider: provider) { value, secondaryValue in
                primary = value
                if !secondaryValue.isEmpty { secondary = secondaryValue }
                // 登录拿到就立即落盘并推给网关，少一步手动保存。
                store.set(provider: provider, primary: value, secondary: secondaryValue)
            }
        }
        .sheet(isPresented: $showsQRLogin) {
            CatVodQRLoginView(provider: provider)
                .onDisappear {
                    // 扫码结果由登录页直接写进 store，这里把输入框对齐到最新值。
                    let latest = store.credential(for: provider)
                    primary = latest.primary
                    secondary = latest.secondary
                }
        }
    }
}

extension CatVodCloudProvider {
    var icon: String {
        switch self {
        case .quark: return "q.circle"
        case .uc: return "u.circle"
        case .aliyun: return "cloud"
        case .baidu: return "b.circle"
        case .pan115: return "number.circle"
        case .tianyi: return "cloud.fill"
        case .pan123: return "1.circle"
        case .guangya: return "g.circle"
        case .xunlei: return "x.circle"
        }
    }
}

/// Edits the AList / OpenList server list as one JSON document, matching the
/// TVBox AList configuration shape the gateway reads. Kept independent of the
/// per-provider credential editor so adding a server type needs no enum change.
private struct AListConfigView: View {
    @State private var store = CatVodCloudAccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init() {
        _text = State(initialValue: CatVodCloudAccountStore.shared.alistServers)
    }

    private var looksValidJSON: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let object = try? JSONSerialization.jsonObject(with: data)
        return object is [Any] || (object as? [String: Any])?["drives"] != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(localized("粘贴 AList / OpenList 的 TVBox 配置数组。填写后即可在「我的网盘」里浏览服务器，并按原画质播放。凭据只保存在本机。"))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
                Section {
                    TextEditor(text: $text)
                        .font(DSFont.footnote)
                        .frame(minHeight: 220)
                } header: {
                    Text(localized("服务器配置（JSON）"))
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("[{\"name\":\"我的AList\",\"server\":\"https://alist.example.com\",\"path\":\"/\",\"password\":\"\",\"login\":{\"username\":\"user\",\"password\":\"pass\"}}]")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DSColor.textSecondary)
                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !looksValidJSON {
                            Text(localized("格式看起来不是有效的服务器数组，保存后可能无法加载。"))
                                .font(DSFont.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .dsSectionFooter()
                }
                if !store.alistServers.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            store.setAListServers("")
                            text = ""
                        } label: {
                            Label(localized("清除 AList 配置"), systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(localized("AList 服务器"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("保存")) {
                        store.setAListServers(text)
                        dismiss()
                    }
                }
            }
            .themedAppSurface(for: .settings)
        }
        .presentationDetents([.medium, .large])
    }
}
