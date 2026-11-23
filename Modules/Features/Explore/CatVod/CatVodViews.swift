import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pushed from 模组 → 猫源: the user's imported CatVod interfaces. Nothing is built in; the list
/// fills only by import (file / clipboard). Mirrors `DanmakuSourceSettingsView` in layout.
struct CatVodSourceSettingsView: View {
    @State private var store = CatVodSourceStore.shared
    @State private var showsImporter = false
    @State private var showsPaste = false
    @State private var pasteText = ""
    @State private var importMessage: String?
    @State private var renamingSource: CatVodSource?
    @State private var renameText = ""

    var body: some View {
        List {
            if store.sources.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "tv.and.hifispeaker.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(DSColor.textSecondary)
                        Text(localized("还没有猫源"))
                            .font(DSFont.headline)
                            .foregroundStyle(DSColor.textPrimary)
                        Text(localized("导入猫源接口后，在首页的「猫元」切换页浏览、搜索和播放。"))
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
                            Text(source.url)
                                .font(DSFont.caption2)
                                .foregroundStyle(DSColor.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            renameText = source.name
                            renamingSource = source
                        }

                        // 点名称也能改名，但没人猜得到。给一个看得见的入口。
                        Button {
                            renameText = source.name
                            renamingSource = source
                        } label: {
                            Image(systemName: "pencil.circle")
                                .font(.system(size: 20))
                                .foregroundStyle(DSColor.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(localized("改名"))
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            renameText = source.name
                            renamingSource = source
                        } label: {
                            Label(localized("改名"), systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                }
                .onDelete(perform: delete)
            } header: {
                Text(localized("猫源列表"))
            }

            Section {
                NavigationLink {
                    CatVodCloudAccountView()
                } label: {
                    Label(localized("网盘账号配置"), systemImage: "keychain")
                }

                Button { showsImporter = true } label: {
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
                        importMessage = localized("已清空猫源")
                    } label: {
                        Label(localized("清空猫源"), systemImage: "trash")
                    }
                }
            } footer: {
                Text(localized("支持 .js.md5 / .js 接口地址，可整段粘贴带 # 注释的列表；每行一个地址。点猫源名称或右侧铅笔可改名。"))
                    .dsSectionFooter()
            }

            if let message = importMessage {
                Section {
                    Text(message).foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .softScrollEdges()
        .navigationTitle(localized("猫源"))
        .navigationBarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.plainText, .json]) { result in
            guard let url = try? result.get(), url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) { applyImport(data) }
        }
        .sheet(isPresented: $showsPaste) { pasteSheet }
        .alert(localized("重命名猫源"), isPresented: Binding(
            get: { renamingSource != nil },
            set: { if !$0 { renamingSource = nil } }
        )) {
            TextField(localized("名称"), text: $renameText)
            Button(localized("取消"), role: .cancel) { renamingSource = nil }
            Button(localized("保存")) {
                if let source = renamingSource {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { store.rename(id: source.id, to: name) }
                }
                renamingSource = nil
            }
        }
    }

    private func applyImport(_ data: Data) {
        do {
            let count = try store.import(data)
            importMessage = String(format: localized("已导入 %d 个猫源"), count)
        } catch {
            importMessage = localized("导入失败：格式无法识别")
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets.reversed() {
            guard index < store.sources.count else { continue }
            store.remove(id: store.sources[index].id)
        }
    }

    private var pasteSheet: some View {
        NavigationStack {
            VStack(spacing: DSSpacing.md) {
                TextEditor(text: $pasteText)
                    .font(DSFont.footnote)
                    .overlay {
                        if pasteText.isEmpty {
                            Text(localized("粘贴猫源地址，每行一个，可用 # 注释命名"))
                                .font(DSFont.footnote)
                                .foregroundStyle(DSColor.textSecondary)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(8)
                    .background(DSColor.surfaceTertiary, in: RoundedRectangle(cornerRadius: 10))
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
                        applyImport(Data(pasteText.utf8))
                        showsPaste = false
                    }
                    .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
