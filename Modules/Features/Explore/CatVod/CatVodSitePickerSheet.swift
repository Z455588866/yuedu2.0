import SwiftUI

/// 站点选择器。
///
/// 一个接口动辄几十上百个站点（实测 niuer 99 个），`Picker(.menu)` 会退化成一个
/// 几十行的滚动菜单：没有搜索、看不出哪个最近连不上、名字一长就被截断。这里换成
/// 一个带搜索的列表，并把健康状态直接标在行上——和沉底排序是同一份数据。
struct CatVodSitePickerSheet: View {
    let sites: [CatVodSite]
    let selected: CatVodSite?
    let bundleURL: String
    let onSelect: (CatVodSite) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private static func isPython(_ site: CatVodSite) -> Bool {
        site.key.hasPrefix("py-")
    }

    private var filtered: [CatVodSite] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return sites }
        return sites.filter { $0.name.localizedCaseInsensitiveContains(term)
            || $0.key.localizedCaseInsensitiveContains(term) }
    }

    /// Python 源单独成组并置顶——它们是用户自己导入的 .py 脚本，和接口的在线
    /// 站点不是一回事。放在一个独立 Section 里，导入后一眼就能找到、直接选播。
    private var pythonSites: [CatVodSite] { filtered.filter { Self.isPython($0) } }
    private var regularSites: [CatVodSite] { filtered.filter { !Self.isPython($0) } }

    @ViewBuilder
    private func row(_ site: CatVodSite) -> some View {
        Button {
            onSelect(site)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if Self.isPython(site) {
                            Text("PY")
                                .font(DSFont.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(DSColor.accent, in: Capsule())
                        }
                        Text(site.name)
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.textPrimary)
                            .lineLimit(2)
                    }
                    if CatVodSourceHealth.shared.isDown(bundleURL: bundleURL, siteKey: site.key) {
                        Text(localized("最近连接失败，已排到后面"))
                            .font(DSFont.caption2)
                            .foregroundStyle(DSColor.textSecondary)
                    }
                }
                Spacer(minLength: 8)
                if site.key == selected?.key {
                    Image(systemName: "checkmark")
                        .font(DSFont.caption.weight(.semibold))
                        .foregroundStyle(DSColor.accent)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationStack {
            List {
                if !pythonSites.isEmpty {
                    Section {
                        ForEach(pythonSites) { site in row(site) }
                    } header: {
                        Text(localized("Python 源（已导入）"))
                    }
                }
                if !regularSites.isEmpty {
                    Section {
                        ForEach(regularSites) { site in row(site) }
                    } header: {
                        Text(localized("在线站点"))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: localized("搜索站点名"))
            .navigationTitle(String(format: localized("站点（%ld）"), sites.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("关闭")) { dismiss() }
                }
            }
        }
    }
}
