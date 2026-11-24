import Foundation
import SwiftUI

/// 直播页：把当前猫源声明的 `lives` 拉下来、解析成频道，按分组建列表。
///
/// 列表内容不经过插件，直接读 M3U/TXT，所以源站挂了也不影响已经拿到的频道名；
/// 播放复用 App 自己的播放器（HLS 交给 AVPlayer，个别 TS/FLV 由 VLC 兜底）。
@MainActor
@Observable
final class CatVodLiveModel {
    private(set) var isLoading = true
    private(set) var channels: [CatVodLiveChannel] = []
    private(set) var groups: [String] = []
    private(set) var error: String?
    /// 拉到了几个播放列表、其中几个没解析出频道，用来解释"为什么只有这么几个台"。
    private(set) var loadedSources = 0

    var query = ""
    var selectedGroup: String?
    var favorites: Set<String> = []

    private static let favoritesKey = "yd_catvod_live_favorites"

    var visibleChannels: [CatVodLiveChannel] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return channels.filter { channel in
            if let selectedGroup, channel.group != selectedGroup { return false }
            guard !keyword.isEmpty else { return true }
            return channel.name.lowercased().contains(keyword)
                || channel.group.lowercased().contains(keyword)
        }
    }

    var favoriteChannels: [CatVodLiveChannel] {
        channels.filter { favorites.contains(Self.key(of: $0)) }
    }

    static func key(of channel: CatVodLiveChannel) -> String {
        "\(channel.group)|\(channel.name)"
    }

    func load(bundleURL: String) async {
        favorites = Set(UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [])
        isLoading = channels.isEmpty
        error = nil
        do {
            let sources = try await CatVodService.shared.liveSources(bundleURL: bundleURL)
            guard !sources.isEmpty else {
                channels = []
                groups = []
                error = "这个接口没有声明直播源"
                isLoading = false
                return
            }
            let parsed = await Self.fetchAll(sources)
            loadedSources = parsed.count
            channels = CatVodLivePlaylist.merge(parsed.flatMap { $0 })
            groups = Self.uniqueGroups(channels)
            if selectedGroup == nil { selectedGroup = groups.first }
            if channels.isEmpty {
                error = "直播列表能下载，但没解析出频道（列表可能是空的或格式不认识）"
            }
        } catch {
            // 网关没起来时还有上一轮存下来的源地址，至少能看到频道名。
            if let cached = CatVodService.shared.cachedLiveSources(bundleURL: bundleURL), !cached.isEmpty {
                let parsed = await Self.fetchAll(cached)
                channels = CatVodLivePlaylist.merge(parsed.flatMap { $0 })
                groups = Self.uniqueGroups(channels)
                if selectedGroup == nil { selectedGroup = groups.first }
                self.error = channels.isEmpty ? nil : "接口暂时连不上，显示的是上次的直播列表"
            } else {
                self.error = error.localizedDescription
            }
        }
        isLoading = false
    }

    private static func uniqueGroups(_ channels: [CatVodLiveChannel]) -> [String] {
        var seen = Set<String>()
        return channels.map(\.group).filter { seen.insert($0).inserted }
    }

    func toggleFavorite(_ channel: CatVodLiveChannel) {
        let key = Self.key(of: channel)
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
        UserDefaults.standard.set(Array(favorites), forKey: Self.favoritesKey)
    }

    func isFavorite(_ channel: CatVodLiveChannel) -> Bool {
        favorites.contains(Self.key(of: channel))
    }

    /// 每个播放列表一个请求，最多四个同时；列表本身可能几 MB，超时给足 20 秒。
    private nonisolated static func fetchAll(_ sources: [CatVodLiveSource]) async -> [[CatVodLiveChannel]] {
        await withTaskGroup(of: (Int, [CatVodLiveChannel]).self) { group in
            var results: [Int: [CatVodLiveChannel]] = [:]
            var iterator = sources.enumerated().makeIterator()
            var running = 0
            while running < 4, let (index, source) = iterator.next() {
                group.addTask { (index, await fetch(source)) }
                running += 1
            }
            while let (index, channels) = await group.next() {
                results[index] = channels
                if let (nextIndex, source) = iterator.next() {
                    group.addTask { (nextIndex, await fetch(source)) }
                }
            }
            return sources.indices.compactMap { results[$0] }
        }
    }

    private nonisolated static func fetch(_ source: CatVodLiveSource) async -> [CatVodLiveChannel] {
        guard let url = URL(string: source.url) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if !source.ua.isEmpty { request.setValue(source.ua, forHTTPHeaderField: "User-Agent") }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = Self.decode(data) else { return [] }
        return CatVodLivePlaylist.parse(text, source: source)
    }

    /// IPTV 列表经常是 GBK：直接按 UTF-8 解会得到空串或问号，频道名全废。
    private nonisolated static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030), !text.isEmpty { return text }
        return String(data: data, encoding: .isoLatin1)
    }
}

@MainActor
struct CatVodLiveView: View {
    let bundleURL: String
    let title: String

    @State private var model = CatVodLiveModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView(localized("正在读取直播列表…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.channels.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle(title.isEmpty ? localized("直播") : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("完成")) { dismiss() }
                }
            }
            .searchable(text: $model.query, prompt: localized("搜索频道"))
        }
        .task { await model.load(bundleURL: bundleURL) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(localized("没有直播"), systemImage: "tv.slash")
        } description: {
            Text(model.error ?? localized("这个接口没有直播源。直播一般由接口的 lives 字段提供，多数 JS 猫源没有。"))
        }
    }

    private var list: some View {
        List {
            if model.selectedGroup == nil, !model.favoriteChannels.isEmpty {
                Section(localized("收藏")) {
                    ForEach(model.favoriteChannels) { channel in row(channel) }
                }
            }
            Section {
                ForEach(model.visibleChannels) { channel in row(channel) }
            } header: {
                Text(model.selectedGroup ?? localized("全部频道"))
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) { groupBar }
    }

    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.groups, id: \.self) { group in
                    Button {
                        model.selectedGroup = group
                    } label: {
                        Text(group)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                group == model.selectedGroup
                                    ? DSColor.accent.opacity(0.18)
                                    : DSColor.surfaceTertiary,
                                in: Capsule()
                            )
                            .foregroundStyle(group == model.selectedGroup ? DSColor.accent : DSColor.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func row(_ channel: CatVodLiveChannel) -> some View {
        HStack(spacing: 10) {
            if !channel.logo.isEmpty, let url = URL(string: channel.logo) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 34, height: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.system(size: 15))
                    .foregroundStyle(DSColor.textPrimary)
                Text(channel.group)
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
            }
            Spacer()
            if channel.urls.count > 1 {
                Text("\(channel.urls.count) 条线路")
                    .font(.system(size: 11))
                    .foregroundStyle(DSColor.textSecondary)
            }
            Button {
                model.toggleFavorite(channel)
            } label: {
                Image(systemName: model.isFavorite(channel) ? "star.fill" : "star")
                    .foregroundStyle(model.isFavorite(channel) ? DSColor.accent : DSColor.textSecondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { play(channel) }
    }

    private func play(_ channel: CatVodLiveChannel) {
        guard let url = channel.address else { return }
        CatVodPlayerPresenter.present(url: url, headers: channel.headers, title: channel.name)
    }
}
