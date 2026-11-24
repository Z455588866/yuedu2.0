import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pushed from 模组 → 猫源: the user's imported CatVod interfaces. Nothing is built in; the list
/// fills only by import (file / clipboard). Mirrors `DanmakuSourceSettingsView` in layout.
struct CatVodSourceSettingsView: View {
    @ObservedObject private var store = CatVodSourceStore.shared
    /// 渲染用快照，唯一真相仍在上面的 store。
    ///
    /// 直接 `ForEach(store.sources)` 依赖 SwiftUI 对 @Observable 的自动追踪；一旦
    /// 某次赋值没被登记（跨隔离域写入、List 复用等），表现就是「提示已导入 N 个、
    /// 列表一行不变」，重进页面才对。这里改成显式同步，导入/删除后立刻重算，
    /// 不把正确性押在追踪机制上。
    @State private var rows: [CatVodSource] = []
    @State private var showsImporter = false
    @State private var showsPaste = false
    @State private var pasteText = ""
    @State private var importMessage: String?
    @State private var renamingSource: CatVodSource?
    @State private var renameText = ""

    var body: some View {
        List {
            if rows.isEmpty {
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
                        // 空态就是起点：把导入动作直接放在这里，不要让人先
                        // 读完一段说明再往下滚去找按钮。
                        VStack(spacing: 8) {
                            Button {
                                showsImporter = true
                            } label: {
                                Label(localized("从文件导入"), systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                pasteText = UIPasteboard.general.string ?? ""
                                showsPaste = true
                            } label: {
                                Label(localized("从剪贴板导入"), systemImage: "doc.on.clipboard")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }

            Section {
                ForEach(rows) { source in
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
                if !rows.isEmpty {
                    Button(role: .destructive) {
                        store.removeAll()
                        rows = store.sources
                        importMessage = localized("已清空猫源")
                    } label: {
                        Label(localized("清空猫源"), systemImage: "trash")
                    }
                }
            } footer: {
                Text(localized("支持 .js.md5 / .js 接口地址和 .py 脚本：地址可整段粘贴、每行一个（# 后写名字）；.py 从文件导入后立即生效。点猫源名称或右侧铅笔可改名。"))
                    .dsSectionFooter()
            }

            if let message = importMessage {
                Section {
                    Text(message).foregroundStyle(DSColor.textSecondary)
                }
            }
        }
        .softScrollEdges()
        .task { rows = store.sources }
        // 兜底：其它入口（文件导入、猫元页、改名弹窗）改了 store 时也让列表跟上。
        .onChange(of: store.sources) { _, next in rows = next }
        .navigationTitle(localized("猫源"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
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
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(localized("导入猫源"))
            }
        }
        .themedAppSurface(for: .settings)
        .fileImporter(isPresented: $showsImporter,
                      allowedContentTypes: [.plainText, .json, .sourceCode],
                      allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result, !urls.isEmpty else { return }
            // .js 接口是一个文本文件，进 store；.py 是脚本，落点是
            // Documents/PythonSources，由内嵌解释器扫描，两条路不能混。
            let scripts = urls.filter { $0.pathExtension.lowercased() == "py" }
            if !scripts.isEmpty { importPython(scripts) }
            if let textURL = urls.first(where: { $0.pathExtension.lowercased() != "py" }) {
                guard textURL.startAccessingSecurityScopedResource() else { return }
                defer { textURL.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: textURL) { applyImport(data) }
            }
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
                rows = store.sources
                renamingSource = nil
            }
        }
    }

    /// .py 走内嵌 Python 运行时：拷进 Documents/PythonSources，再让运行时重扫。
    /// 它们不进 `store`（那存的是 .js 接口地址），所以不能按导入接口那条路处理。
    @MainActor
    private func importPython(_ urls: [URL]) {
        let copied = CatVodGateway.shared.importPythonSources(from: urls)
        guard copied > 0 else {
            importMessage = localized("没有读到可用的 .py 文件")
            return
        }
        Task { @MainActor in
            let total = await CatVodGateway.shared.reloadPythonSources()
            store.notePythonSourcesChanged()
            // Python 源不在这张列表里（它存的是 .js 接口地址），所以必须说清去哪儿看，
            // 否则「导入成功、列表没变」会被当成没生效。
            if total >= 0 {
                importMessage = String(format: localized("已导入 %d 个 Python 源（共 %d 个），在「影视」页的源列表里可以看到。"), copied, total)
            } else {
                importMessage = String(format: localized("已导入 %d 个 Python 源，重启 App 后生效。"), copied)
            }
        }
    }

    private func applyImport(_ data: Data) {
        let before = Set(store.sources.map(\.id))
        do {
            let result = try store.import(data)
            rows = store.sources
            let total = store.sources.count
            if result.added == 0, result.updated > 0 {
                // 点名是「哪几行」。只说「已导入 1 个」而列表不动，人只会得出
                // 「导入没生效」；名字一亮出来，就能判断是自己早就导过、还是
                // 地址认错了。
                let names = result.updatedNames.joined(separator: "、")
                importMessage = String(format: localized("这 %d 个地址已经在列表里：%@（已刷新，共 %d 个）"),
                                       result.updated, names, total)
            } else if result.updated > 0 {
                importMessage = String(format: localized("已导入 %d 个猫源，%d 个已存在并更新（共 %d 个）"), result.added, result.updated, total)
            } else {
                importMessage = String(format: localized("已导入 %d 个猫源（共 %d 个）"), result.added, total)
            }
            // 导入完成后立刻在后台把脚本拉下来、启动一次、解析站点表。
            // 一个接口的脚本常有 5–10MB，第一步走完要几秒；不等它，
            // 人点进「影视」时看到的就是这几秒的转圈。只预热第一个新源：
            // 一次导入七八个接口时，把全部流量都提前打出去并不划算。
            if let first = store.sources.first(where: { !before.contains($0.id) }) {
                let url = first.url
                Task(priority: .utility) {
                    _ = try? await CatVodService.shared.catalog(bundleURL: url)
                }
            }
        } catch {
            importMessage = localized("导入失败：格式无法识别")
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard index < rows.count else { continue }
            store.remove(id: rows[index].id)
        }
        rows = store.sources
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
