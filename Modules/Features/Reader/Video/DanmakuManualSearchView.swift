import SwiftUI

/// Manual danmaku picking for a title the automatic matcher could not find.
///
/// Auto-match works from the video's own title, and a season tag, a fansub prefix or a
/// 「·HD」 suffix is enough to miss. This sheet opens from a right swipe on a source row,
/// pre-fills the video's title, and lets the person search the source by name, pick the
/// show, then pick the episode — the same steps the web UI of these services takes.
struct DanmakuManualSearchView: View {
    let source: DanmakuSource
    let onPick: (DanmakuEpisode, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyword: String
    @State private var animes: [DanmakuAnime] = []
    @State private var episodes: [DanmakuEpisode] = []
    @State private var expandedAnime: DanmakuAnime?
    @State private var isSearching = false
    @State private var isLoadingEpisodes = false
    @State private var message: String?

    init(source: DanmakuSource, initialKeyword: String,
         onPick: @escaping (DanmakuEpisode, String) -> Void) {
        self.source = source
        self.onPick = onPick
        _keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField(localized("剧名"), text: $keyword)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { Task { await runSearch() } }
                            .autocorrectionDisabled()
                        Button {
                            Task { await runSearch() }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .frame(width: 34, height: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    Text(localized("搜到之后先点剧，再点要播的那一集。"))
                }

                if let message {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isSearching {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }

                Section(localized("剧集")) {
                    ForEach(animes, id: \.animeId) { anime in
                        animeRow(anime)
                    }
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { dismiss() }
                }
            }
            .task {
                // The video title is already a good guess; searching on open saves a tap.
                if animes.isEmpty { await runSearch() }
            }
        }
    }

    @ViewBuilder
    private func animeRow(_ anime: DanmakuAnime) -> some View {
        let isOpen = expandedAnime?.animeId == anime.animeId
        Button {
            Task { await toggle(anime) }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(anime.title)
                        .font(.subheadline)
                        .foregroundStyle(DSColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        if !anime.type.isEmpty { Text(anime.type) }
                        if anime.episodeCount > 0 {
                            Text(String(format: localized("%d 集"), anime.episodeCount))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isOpen {
            if isLoadingEpisodes {
                HStack {
                    ProgressView().scaleEffect(0.7)
                    Text(localized("正在读取分集…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(episodes, id: \.episodeId) { episode in
                Button {
                    onPick(episode, anime.title)
                    dismiss()
                } label: {
                    HStack {
                        Text(episodeLabel(episode))
                            .font(.callout)
                            .foregroundStyle(DSColor.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(Color.accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func episodeLabel(_ episode: DanmakuEpisode) -> String {
        if episode.title.isEmpty { return "EP \(episode.number)" }
        if episode.number.isEmpty { return episode.title }
        return "\(episode.number) · \(episode.title)"
    }

    private func runSearch() async {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearching = true
        message = nil
        episodes = []
        expandedAnime = nil
        do {
            animes = try await DanmakuService.search(keyword: query, in: source)
            if animes.isEmpty {
                message = localized("这个源里没有搜到，换个名字或换一部试试。")
            }
        } catch {
            animes = []
            message = error.localizedDescription
        }
        isSearching = false
    }

    private func toggle(_ anime: DanmakuAnime) async {
        if expandedAnime?.animeId == anime.animeId {
            expandedAnime = nil
            episodes = []
            return
        }
        expandedAnime = anime
        episodes = []
        isLoadingEpisodes = true
        message = nil
        do {
            episodes = try await DanmakuService.episodes(animeId: anime.animeId, in: source)
            if episodes.isEmpty { message = localized("这部剧在源里还没有分集。") }
        } catch {
            message = error.localizedDescription
        }
        isLoadingEpisodes = false
    }
}
