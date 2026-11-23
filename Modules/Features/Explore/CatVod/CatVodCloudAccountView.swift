import SwiftUI

/// Netdisk account configuration for CatVod/cloud sources. Mirrors tvbox-silicon's
/// `CloudDriveView` credential entry: paste a cookie or token per provider; the
/// store pushes it into the trusted gateway so cloud-flavoured lines can play.
struct CatVodCloudAccountView: View {
    @State private var store = CatVodCloudAccountStore.shared
    @State private var editing: CatVodCloudProvider?

    var body: some View {
        List {
            Section {
                Text(localized("在此填写各网盘的 Cookie / Token，猫源中来自对应网盘的线路即可直接播放。凭据只保存在本机，不会发给第三方猫源脚本。"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
            }

            Section {
                ForEach(CatVodCloudProvider.allCases) { provider in
                    let credential = store.credential(for: provider)
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
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(DSColor.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(localized("网盘平台"))
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

    var body: some View {
        NavigationStack {
            List {
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
