import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Manages subtitles for the video player. Two kinds, both user-imported — nothing is built in:
///   1. Online subtitle sources (thesubtitledb / wyzie, imported JSON) — fetched on demand,
///      auto-matched by series name / episode, exactly like danmaku sources.
///   2. Local subtitle files (.srt/.vtt) — parsed on import, series title & episode from file name.
struct SubtitleSourceSettingsView: View {
    @State private var store = SubtitleStore.shared
    @State private var onlineStore = OnlineSubtitleSourceStore.shared
    @State private var showsImporter = false
    @State private var showsPaste = false
    @State private var pasteText = ""
    @State private var pasteName = ""
    @State private var showsOnlineImporter = false
    @State private var showsOnlinePaste = false
    @State private var onlinePasteText = ""
    @State private var importMessage: String?

    private var allowedTypes: [UTType] {
        var types: [UTType] = [.plainText, .data]
        for ext in ["srt", "vtt", "ass", "ssa"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    var body: some View {
        List {
            if store.entries.isEmpty && onlineStore.sources.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "captions.bubble")
                            .font(.system(size: 34))
                            .foregroundStyle(DSColor.textSecondary)
                        Text(localized("还没有字幕"))
                            .font(DSFont.headline)
                            .foregroundStyle(DSColor.textPrimary)
                        Text(localized("导入在线字幕源或 .srt / .vtt 字幕文件后，播放视频按片名自动匹配。"))
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }

            if !onlineStore.sources.isEmpty {
                Section {
                    ForEach(onlineStore.sources) { source in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(
                                get: { source.enabled },
                                set: { onlineStore.setEnabled(id: source.id, enabled: $0) }
                            )) {
                                EmptyView()
                            }
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.name)
                                    .font(DSFont.subheadline.weight(.semibold))
                                    .foregroundStyle(DSColor.textPrimary)
                                Text("\(source.apiType.rawValue) · \(source.language)\(source.apiType == .wyzie && !source.apiKey.isEmpty ? " · key ✓" : "")")
                                    .font(DSFont.caption2)
                                    .foregroundStyle(DSColor.textSecondary)
                                    .lineLimit(1)
                                Text(source.baseURL)
                                    .font(DSFont.caption2)
                                    .foregroundStyle(DSColor.textSecondary.opacity(0.7))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .onDelete(perform: deleteOnline)
                } header: {
                    Text(localized("在线字幕源"))
                } footer: {
                    Text(localized("支持两种协议：thesubtitledb（免密钥，中文剧集覆盖好）与 wyzie（聚合 OpenSubtitles/SubDL，需在配置里填自己申请的免费 key）。导入 JSON 数组，每项含 id、name、baseUrl、可选 language、apiType（thesubtitledb/wyzie）、apiKey。"))
                }
            }

            if !store.entries.isEmpty {
                Section {
                    ForEach(store.entries) { entry in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(
                                get: { entry.enabled },
                                set: { store.setEnabled(id: entry.id, enabled: $0) }
                            )) {
                                EmptyView()
                            }
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name)
                                    .font(DSFont.subheadline.weight(.semibold))
                                    .foregroundStyle(DSColor.textPrimary)
                                Text(subtitle(of: entry))
                                    .font(DSFont.caption2)
                                    .foregroundStyle(DSColor.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text(localized("本地字幕"))
                }
            }

            Section {
                Button {
                    showsOnlineImporter = true
                } label: {
                    Label(localized("导入在线字幕源（文件）"), systemImage: "square.and.arrow.down")
                }
                Button {
                    onlinePasteText = UIPasteboard.general.string ?? ""
                    showsOnlinePaste = true
                } label: {
                    Label(localized("导入在线字幕源（剪贴板）"), systemImage: "doc.on.clipboard")
                }
                Button {
                    showsImporter = true
                } label: {
                    Label(localized("导入本地字幕文件"), systemImage: "captions.bubble")
                }
                Button {
                    pasteText = UIPasteboard.general.string ?? ""
                    showsPaste = true
                } label: {
                    Label(localized("从剪贴板导入字幕文本"), systemImage: "doc.on.clipboard")
                }
            } header: {
                Text(localized("导入"))
            } footer: {
                Text(localized("在线源导入 JSON；本地字幕支持 .srt / .vtt（GBK 或 UTF-8）。片名与集号从文件名自动识别，播放时按片名匹配。"))
            }

            if !store.entries.isEmpty || !onlineStore.sources.isEmpty {
                Section {
                    Button(role: .destructive) {
                        onlineStore.removeAll()
                        store.removeAll()
                        importMessage = localized("已清空字幕与在线字幕源")
                    } label: {
                        Label(localized("清空全部"), systemImage: "trash")
                    }
                }
            }

            if let importMessage {
                Section {
                    Text(importMessage)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .navigationTitle(localized("字幕"))
        .navigationBarTitleDisplayMode(.inline)
        .copiedFileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: allowedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
        .copiedFileImporter(
            isPresented: $showsOnlineImporter,
            allowedContentTypes: [.json, .plainText]
        ) { result in
            handleOnlineImport(result)
        }
        .sheet(isPresented: $showsPaste) {
            pasteSheet
        }
        .sheet(isPresented: $showsOnlinePaste) {
            onlinePasteSheet
        }
    }

    private func subtitle(of entry: SubtitleEntry) -> String {
        let ep = entry.episode.map { String(format: localized("第 %d 集"), $0) }
        return [entry.title, ep, String(format: localized("%d 条"), entry.cueCount)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Local subtitle import

    private var pasteSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField(localized("片名（可留空，从剪贴板文本推断）"), text: $pasteName)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $pasteText)
                    .font(.system(size: 13, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DSColor.separator.opacity(0.5), lineWidth: 1)
                    )
                Text(localized("粘贴 SRT / VTT 字幕文本"))
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
                Spacer()
            }
            .padding()
            .navigationTitle(localized("从剪贴板导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { showsPaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("导入")) {
                        applyPaste()
                        showsPaste = false
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            guard store.entries.indices.contains(index) else { continue }
            store.remove(id: store.entries[index].id)
        }
    }

    private func handleImport(_ result: Result<[URL], any Error>) {
        do {
            let urls = try result.get()
            var accepted = 0
            for url in urls {
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let cues = try? SubtitleService.parse(data: data), !cues.isEmpty else { continue }
                let meta = SubtitleService.metadata(fromFileName: url.lastPathComponent)
                let entry = SubtitleEntry(
                    id: UUID().uuidString,
                    name: url.lastPathComponent,
                    title: meta.title,
                    episode: meta.episode,
                    cues: cues
                )
                store.import([entry])
                accepted += 1
            }
            importMessage = accepted > 0
                ? String(format: localized("已导入 %d 个字幕"), accepted)
                : localized("未找到有效字幕")
        } catch {
            importMessage = "\(localized("导入失败")): \(error.localizedDescription)"
        }
    }

    private func applyPaste() {
        guard let data = pasteText.data(using: .utf8),
              let cues = try? SubtitleService.parse(data: data), !cues.isEmpty else {
            importMessage = localized("未找到有效字幕")
            return
        }
        let title = pasteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = SubtitleEntry(
            id: UUID().uuidString,
            name: title.isEmpty ? localized("剪贴板字幕") : title,
            title: title.isEmpty ? localized("剪贴板字幕") : title,
            episode: nil,
            cues: cues
        )
        store.import([entry])
        importMessage = String(format: localized("已导入 %d 个字幕"), 1)
    }

    // MARK: - Online source import

    private var onlinePasteSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $onlinePasteText)
                    .font(.system(size: 13, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DSColor.separator.opacity(0.5), lineWidth: 1)
                    )
                Text(localized("粘贴在线字幕源 JSON（数组 / {\"sources\":[...]} / 单个对象）"))
                    .font(DSFont.caption2)
                    .foregroundStyle(DSColor.textSecondary)
                Spacer()
            }
            .padding()
            .navigationTitle(localized("从剪贴板导入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localized("取消")) { showsOnlinePaste = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("导入")) {
                        applyOnlineImport(onlinePasteText.data(using: .utf8) ?? Data())
                        showsOnlinePaste = false
                    }
                    .disabled(onlinePasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func deleteOnline(at offsets: IndexSet) {
        for index in offsets {
            guard onlineStore.sources.indices.contains(index) else { continue }
            onlineStore.remove(id: onlineStore.sources[index].id)
        }
    }

    private func handleOnlineImport(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            applyOnlineImport(try Data(contentsOf: url))
        } catch {
            importMessage = "\(localized("导入失败")): \(error.localizedDescription)"
        }
    }

    private func applyOnlineImport(_ data: Data) {
        do {
            let count = try onlineStore.import(data)
            importMessage = count > 0
                ? String(format: localized("已导入 %d 个在线字幕源"), count)
                : localized("未找到有效在线字幕源")
        } catch {
            importMessage = "\(localized("导入失败")): \(error.localizedDescription)"
        }
    }
}
