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

    private var filtered: [CatVodSite] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return sites }
        return sites.filter { $0.name.localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { site in
                Button {
                    onSelect(site)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name)
                                .font(DSFont.body)
                                .foregroundStyle(DSColor.textPrimary)
                                .lineLimit(2)
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
            .listStyle(.plain)
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
