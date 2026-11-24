import CryptoKit
import Foundation

/// Python 猫源在管理界面里的一行。
///
/// 与 FongMi/TV 把站点 `name` 和 `key/api` 分开存放是同一个思路：`file` 是稳定
/// 标识（token 由它派生），`name` 是可以随意改的显示名。改名只动 manifest，
/// 文件名不变 → token、运行会话、历史收藏都不失效。
struct PythonSourceInfo: Identifiable, Equatable {
    /// Documents/PythonSources 里的文件名（含 .py）。
    let file: String
    /// sha256("file:" + 去扩展名)[:16]，与 bridge.py 的 Registry.token 一致。
    let token: String
    /// 显示名（可被用户改）。
    var name: String
    /// 是否启用；关闭的源不进影视页站点表。
    var enabled: Bool

    var id: String { file }
}

/// 管理用户导入的 .py 源：显示、改名、删除、开关。
///
/// 元数据写进 `Documents/PythonSources/.manifest.json`，Python 运行时重扫时读取：
/// 关闭的源被跳过，改名只覆盖显示名而不动文件名（文件名是 token 的来源）。
@MainActor
final class PythonSourceStore: ObservableObject {
    static let shared = PythonSourceStore()

    @Published private(set) var sources: [PythonSourceInfo] = []

    private let fileManager = FileManager.default

    private var directory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("PythonSources", isDirectory: true)
    }

    private var manifestURL: URL {
        directory.appendingPathComponent(".manifest.json")
    }

    private struct Manifest: Codable {
        struct Entry: Codable {
            var name: String?
            var enabled: Bool?
        }
        var sources: [String: Entry] = [:]
    }

    private func readManifest() -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let value = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return Manifest()
        }
        return value
    }

    private func writeManifest(_ value: Manifest) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// 与 bridge.py `Registry.token` 完全一致：sha256("file:" + 去扩展名) 的前 16 位十六进制。
    private func token(for file: String) -> String {
        let stem = (file as NSString).deletingPathExtension
        let digest = SHA256.hash(data: Data(("file:" + stem).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// 从目录 + manifest 重建列表。导入/删除/改名/开关后都要调用。
    func refresh() {
        let manifest = readManifest()
        let files = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var result: [PythonSourceInfo] = []
        for file in files where file.lowercased().hasSuffix(".py") && !file.hasPrefix(".") {
            let entry = manifest.sources[file]
            let stem = (file as NSString).deletingPathExtension
            let custom = entry?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(PythonSourceInfo(
                file: file,
                token: token(for: file),
                name: custom.isEmpty ? stem : custom,
                enabled: entry?.enabled ?? true
            ))
        }
        sources = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func rename(file: String, to name: String) {
        var manifest = readManifest()
        var entry = manifest.sources[file] ?? Manifest.Entry()
        entry.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        manifest.sources[file] = entry
        writeManifest(manifest)
        refresh()
    }

    func setEnabled(file: String, enabled: Bool) {
        var manifest = readManifest()
        var entry = manifest.sources[file] ?? Manifest.Entry()
        entry.enabled = enabled
        manifest.sources[file] = entry
        writeManifest(manifest)
        refresh()
    }

    func delete(files: [String]) {
        guard !files.isEmpty else { return }
        var manifest = readManifest()
        for file in files {
            try? fileManager.removeItem(at: directory.appendingPathComponent(file))
            manifest.sources.removeValue(forKey: file)
        }
        writeManifest(manifest)
        refresh()
    }

    /// manifest 改完后让 Python 运行时重扫，影视页站点表才会跟着变。
    func applyToRuntime() async {
        guard await CatVodGateway.shared.reloadPythonSources() >= 0 else { return }
        CatVodSourceStore.shared.notePythonSourcesChanged()
    }
}
