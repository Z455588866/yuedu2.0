import SwiftUI

/// 站点选择器（只显示在线站点）。
///
/// Python 源已经移到独立的「Python 源」面板（见 CatVodPythonSheet），不再和
/// 在线站点混在这一个列表里——混在一起时 py 源的显示依赖网关实时请求
/// `/v1/pyspider/sites`，服务冷启动那 1.5 秒会返回空，表现就是「一会显示一会
/// 不显示」，而且失效站点沉底后 py 会被顶到奇怪的位置。
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

    /// 过滤掉 py 源——它们有自己的固定面板。
    private var filtered: [CatVodSite] {
        let online = sites.filter { !Self.isPython($0) }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return online }
        return online.filter { $0.name.localizedCaseInsensitiveContains(term)
            || $0.key.localizedCaseInsensitiveContains(term) }
    }

    @ViewBuilder
    private func row(_ site: CatVodSite) -> some View {
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

    var body: some View {
        NavigationStack {
            List {
                if !filtered.isEmpty {
                    Section {
                        ForEach(filtered) { site in row(site) }
                    } header: {
                        Text(localized("在线站点"))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: localized("搜索站点名"))
            .navigationTitle(String(format: localized("站点（%ld）"), filtered.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("关闭")) { dismiss() }
                }
            }
        }
    }
}

/// 独立的 Python 源面板——固定、稳定，和在线站点完全分开。
///
/// 数据源是本地磁盘上的 `PythonSourceStore.sources`（manifest），不经过网关
/// `/v1/pyspider/sites` 那个 1.5 秒超时的实时请求，所以导入后立即显示、不会
/// 「一会显示一会不显示」。每个源构造 `py-<token>` 站点，网关靠这个前缀路由到
/// Python 服务，不依赖 catalog 是否碰巧返回了它。
struct CatVodPythonSheet: View {
    /// 点击某个 py 源后回调，交给主页选中并加载。
    let onSelect: (CatVodSite) -> Void
    let selectedKey: String?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pyStore = PythonSourceStore.shared
    @State private var query = ""

    /// 所有启用的源（不过滤），用来区分「一个源都没有」和「搜索没结果」两种空态。
    private var allEnabledSources: [PythonSourceInfo] {
        pyStore.sources.filter(\.enabled)
    }

    /// 列表数据：和上面的在线站点选择器同款过滤——按名称或文件名不区分大小写匹配。
    private var enabledSources: [PythonSourceInfo] {
        let all = allEnabledSources
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(term)
            || $0.file.localizedCaseInsensitiveContains(term) }
    }

    private func site(for source: PythonSourceInfo) -> CatVodSite {
        let key = "py-" + source.token
        return CatVodSite(key: key, name: source.name, type: 4,
                          api: "/spider/\(key)/4", searchable: true)
    }

    var body: some View {
        NavigationStack {
            List {
                if enabledSources.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: query.isEmpty
                                  ? "chevron.left.forwardslash.chevron.right" : "magnifyingglass")
                                .font(.system(size: 34))
                                .foregroundStyle(DSColor.textSecondary)
                            if allEnabledSources.isEmpty {
                                Text(localized("还没有启用的 Python 源"))
                                    .font(DSFont.headline)
                                Text(localized("到「管理猫源 → Python 源」导入 .py 文件，或把已关闭的源打开。"))
                                    .font(DSFont.caption)
                                    .foregroundStyle(DSColor.textSecondary)
                                    .multilineTextAlignment(.center)
                            } else {
                                Text(localized("没有匹配的 Python 源"))
                                    .font(DSFont.headline)
                                Button(localized("清除搜索")) { query = "" }
                                    .font(DSFont.caption)
                            }
                        }
                        .padding(.vertical, 24)
                    }
                } else {
                    Section {
                        ForEach(enabledSources) { source in
                            let item = site(for: source)
                            Button {
                                onSelect(item)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                                        .font(DSFont.caption)
                                        .foregroundStyle(DSColor.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.name)
                                            .font(DSFont.body)
                                            .foregroundStyle(DSColor.textPrimary)
                                        Text(source.file)
                                            .font(DSFont.caption2)
                                            .foregroundStyle(DSColor.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    if item.key == selectedKey {
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
                    } header: {
                        Text(localized("Python 源"))
                    } footer: {
                        Text(localized("这些是导入的 .py 脚本，独立于在线站点。选中后即可浏览、搜索和播放。"))
                            .dsSectionFooter()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: localized("搜索源名称或文件名"))
            .navigationTitle(String(format: localized("Python 源（%ld）"), enabledSources.count))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("关闭")) { dismiss() }
                }
            }
            .task { pyStore.refresh() }
        }
    }
}
