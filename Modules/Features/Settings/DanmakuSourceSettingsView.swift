import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Manages the danmaku sources used by the video player. Nothing is built in — the list starts
/// empty and is filled only by import (file or clipboard). Import merges by id: a matching id is
/// replaced, new ids are appended. Accepted shapes: a bare array, `{"sources": [...]}`, or a
/// single object.
struct DanmakuSourceSettingsView: View {
    @State private var store = DanmakuSourceStore.shared
    @State private var showsImporter = false
    @State private var showsPaste = false
    @State private var pasteText = ""
    @State private var importMessage: String?

    var body: some View {
        List {
            if store.sources.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 34))
                            .foregroundStyle(DSColor.textSecondary)
                        Text(localized("还没有弹幕源"))
                            .font(DSFont.headline)
                            .foregroundStyle(DSColor.textPrimary)
                        Text(localized("导入弹幕源后，播放视频会按片名自动匹配弹幕。"))
                            .font(DSFont.caption)
                            .foregroundStyle(DSColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }

            Section {
                ForEach(store.sources) { source in
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { source.enabled },
                            set: { store.setEnabled(id: source.id, enabled: $0) }
                        )) {
                            EmptyView()
                        }
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name)
                                .font(DSFont.subheadline.weight(.semibold))
                                .foregroundStyle(DSColor.textPrimary)
                            Text(source.baseURL)
                                .font(DSFont.caption2)
                                .foregroundStyle(DSColor.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .onDelete(perform: delete)
            } header: {
                Text(localized("弹幕源列表"))
            }

            Section {
                Button {
                    showsImporter = true
                } label: {
                    Label(localized("从文件导入"), systemImage: "square.and.arrow.down")
                }
                Button {
                    pasteText = UIPasteboard.general.string ?? ""
                    showsPaste = true
                } label: {
                    Label(localized("从剪贴板导入"), systemImage: "doc.on.clipboard")
                }
                if !store.sources.isEmpty {
                    Button(role: .destructive) {
                        store.removeAll()
                        importMessage = localized("已清空弹幕源")
                    } label: {
                        Label(localized("清空全部"), systemImage: "trash")
                    }
                }
                if let importMessage {
                    Text(importMessage)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
            } header: {
                Text(localized("导入"))
            } footer: {
                Text(localized("弹幕源为弹弹play兼容接口地址，导入格式：JSON 数组，每项含 id、name、baseUrl。"))
            }
        }
        .navigationTitle(localized("弹幕源"))
        .navigationBarTitleDisplayMode(.inline)
        .copiedFileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.json, .plainText]
        ) { result in
            handleImport(result)
        }
        .sheet(isPresented: $showsPaste) {
            pasteSheet
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextEditor(text: $pasteText)
                    .font(.system(size: 13, design: .monospaced))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DSColor.separator.opacity(0.5), lineWidth: 1)
                    )
                Text(localized("粘贴弹幕源 JSON（数组 / {\"sources\":[...]} / 单个对象）"))
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
                        applyImport(pasteText.data(using: .utf8) ?? Data())
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
            guard store.sources.indices.contains(index) else { continue }
            store.remove(id: store.sources[index].id)
        }
    }

    private func handleImport(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            applyImport(try Data(contentsOf: url))
        } catch {
            importMessage = "\(localized("导入失败")): \(error.localizedDescription)"
        }
    }

    private func applyImport(_ data: Data) {
        do {
            let count = try store.import(data)
            importMessage = count > 0
                ? String(format: localized("已导入 %d 个弹幕源"), count)
                : localized("未找到有效弹幕源")
        } catch {
            importMessage = "\(localized("导入失败")): \(error.localizedDescription)"
        }
    }
}
