import SwiftUI
import UIKit

/// Route for the CatVod standalone home, pushed from 探索's 猫元 button. Separate from
/// `ExploreNavigationRoute` so the complex hand-written ==/hash there need not change.
struct CatVodHomeRoute: Hashable {}

/// The "猫元" page: picks an imported interface + one of its sites, then browses categories,
/// search and detail, reusing the app's full-screen player for playback.
struct CatVodHomeView: View {
    @State private var store = CatVodSourceStore.shared
    @State private var selectedSourceID: String?
    @State private var sites: [CatVodSite] = []
    @State private var selectedSite: CatVodSite?
    @State private var list: CatVodList = CatVodList(categories: [], media: [], page: 1, pageCount: 1)
    @State private var currentCategory: CatVodCategory?
    @State private var keyword = ""
    @State private var isLoading = false
    @State private var message: String?
    @State private var detailItem: CatVodMedia?
    @State private var detailGroups: [CatVodGroup] = []

    private var sources: [CatVodSource] { store.enabledSources }

    var body: some View {
        Group {
            if sources.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationTitle(localized("猫元"))
        .navigationBarTitleDisplayMode(.inline)
        .themedAppSurface(for: .explore)
        .task { if selectedSourceID == nil { selectedSourceID = sources.first?.id } }
        .sheet(item: $detailItem) { item in
            detailSheet(item)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tv.and.hifispeaker.fill")
                .font(.system(size: 44))
                .foregroundStyle(DSColor.textSecondary)
            Text(localized("还没有可用的猫源"))
                .font(DSFont.headline)
            Text(localized("到「模组 → 猫源」导入接口后，就能在这里浏览。"))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var content: some View {
        List {
            Section {
                Picker(localized("接口"), selection: Binding(
                    get: { selectedSourceID ?? sources.first?.id ?? "" },
                    set: { selectedSourceID = $0 }
                )) {
                    ForEach(sources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .onChange(of: selectedSourceID) { _, _ in Task { await loadCatalogAndHome() } }

                if sites.count > 1 {
                    Picker(localized("站点"), selection: Binding(
                        get: { selectedSite?.key ?? sites.first?.key ?? "" },
                        set: { key in selectedSite = sites.first { $0.key == key } }
                    )) {
                        ForEach(sites) { site in Text(site.name).tag(site.key) }
                    }
                    .onChange(of: selectedSite?.key) { _, _ in Task { await loadHome() } }
                }
            }

            Section {
                HStack {
                    TextField(localized("搜索片名"), text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await search() } }
                    Button { Task { await search() } } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }

            if !list.categories.isEmpty && currentCategory == nil {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(list.categories) { category in
                                Button {
                                    currentCategory = category
                                    Task { await loadCategory(category) }
                                } label: {
                                    Text(category.name).font(DSFont.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                } header: { Text(localized("分类")) }
            }

            if let category = currentCategory {
                Section {
                    Button { currentCategory = nil; Task { await loadHome() } } label: {
                        Label(String(format: localized("返回推荐（%@）"), category.name),
                              systemImage: "arrow.left")
                    }
                }
            }

            Section {
                ForEach(list.media) { item in
                    Button { Task { await openDetail(item) } } label: {
                        CatVodMediaRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text(currentCategory?.name ?? localized("推荐"))
            }

            if let message {
                Section { Text(message).foregroundStyle(DSColor.textSecondary) }
            }
        }
        .softScrollEdges()
        .task { await loadCatalogAndHome() }
        .refreshable { await loadHome() }
    }

    // MARK: - Data

    private var currentBundleURL: String? {
        guard let id = selectedSourceID, let source = store.source(id: id) else { return nil }
        return source.url
    }

    private func loadCatalogAndHome() async {
        guard let bundle = currentBundleURL else { return }
        isLoading = true; message = nil
        do {
            let loaded = try await CatVodService.shared.catalog(bundleURL: bundle)
            await MainActor.run {
                sites = loaded
                selectedSite = loaded.first
                currentCategory = nil
            }
            await loadHome()
        } catch {
            await MainActor.run { message = error.localizedDescription; isLoading = false }
        }
    }

    private func loadHome() async {
        guard let bundle = currentBundleURL, let site = selectedSite else { return }
        isLoading = true; message = nil
        do {
            let result = try await CatVodService.shared.home(bundleURL: bundle, site: site)
            await MainActor.run { list = result; isLoading = false }
        } catch {
            await MainActor.run { message = error.localizedDescription; isLoading = false }
        }
    }

    private func loadCategory(_ category: CatVodCategory) async {
        guard let bundle = currentBundleURL, let site = selectedSite else { return }
        isLoading = true; message = nil
        do {
            let result = try await CatVodService.shared.category(bundleURL: bundle, site: site,
                                                                categoryID: category.id, page: 1)
            await MainActor.run { list = result; isLoading = false }
        } catch {
            await MainActor.run { message = error.localizedDescription; isLoading = false }
        }
    }

    private func search() async {
        guard let bundle = currentBundleURL, let site = selectedSite else { return }
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isLoading = true; message = nil
        do {
            let result = try await CatVodService.shared.search(bundleURL: bundle, site: site, keyword: term)
            await MainActor.run { list = result; currentCategory = nil; isLoading = false }
        } catch {
            await MainActor.run { message = error.localizedDescription; isLoading = false }
        }
    }

    private func openDetail(_ item: CatVodMedia) async {
        guard let bundle = currentBundleURL, let site = selectedSite else { return }
        do {
            let (_, groups) = try await CatVodService.shared.detail(bundleURL: bundle, site: site, id: item.id)
            await MainActor.run { detailGroups = groups; detailItem = item }
        } catch {
            await MainActor.run { message = error.localizedDescription }
        }
    }

    private func play(_ episode: CatVodEpisode, title: String) async {
        guard let bundle = currentBundleURL, let site = selectedSite else { return }
        do {
            let playback = try await CatVodService.shared.player(bundleURL: bundle, site: site, episode: episode)
            guard let url = URL(string: playback.url) else { return }
            await MainActor.run {
                let headers = playback.header ?? [:]
                CatVodPlayerPresenter.present(url: url, headers: headers,
                                              title: "\(title) · \(episode.title)")
            }
        } catch {
            await MainActor.run { message = error.localizedDescription }
        }
    }

    private func detailSheet(_ item: CatVodMedia) -> some View {
        NavigationStack {
            List {
                if !item.detail.isEmpty {
                    Section { Text(item.detail).font(DSFont.caption) }
                }
                ForEach(detailGroups) { group in
                    Section {
                        ForEach(group.episodes) { episode in
                            Button { Task { await play(episode, title: item.name) } } label: {
                                HStack {
                                    Text(episode.title).foregroundStyle(DSColor.textPrimary)
                                    Spacer()
                                    Image(systemName: "play.circle").foregroundStyle(.tint)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: { Text(group.name) }
                }
                if detailGroups.isEmpty {
                    Section { Text(localized("没有可播放的剧集")).foregroundStyle(DSColor.textSecondary) }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { detailItem = nil }
                }
            }
            .themedAppSurface(for: .explore)
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CatVodMediaRow: View {
    let item: CatVodMedia
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: item.cover)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(width: 64, height: 88)
            .clipped()
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(DSFont.subheadline.weight(.semibold))
                    .foregroundStyle(DSColor.textPrimary)
                    .lineLimit(2)
                if !item.remark.isEmpty {
                    Text(item.remark).font(DSFont.caption).foregroundStyle(DSColor.textSecondary)
                }
                if !item.typeName.isEmpty {
                    Text(item.typeName).font(DSFont.caption2).foregroundStyle(DSColor.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
