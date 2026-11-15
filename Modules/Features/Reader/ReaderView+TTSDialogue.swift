import Foundation
import SwiftUI

/// AI 多角色朗读 —— 本地适配版。
///
/// 上游把 AI 对话分析直接接进了它自己的朗读单元（`speakerAttributions`）与
/// `TTSCoordinator.setPreparationNotice`。本地阅读器走的是另一条链路：
/// `TTSSpeakerAnnotator` 从正文推断说话人，`AISpeakerRosterStore` 提供别名表，
/// `TTSRoleVoiceCast` 提供角色到音色的映射。所以这里不改动 `ReaderView` 主体，
/// 而是把 `AIDialogueCastService` 的分析结果桥接进本地已有的名册与自动选角，
/// 让云端语音与 AI 对白真正被本机的多角色朗读消费。
extension ReaderView {

    /// 一章的 AI 分析请求；多角色关闭、AI 对白关闭或没有正文时返回 nil。
    /// - Parameter whenEnabledOnly: 角色指派页传 `false`，让读者在打开开关前也能先分析本章。
    func ttsDialogueRequest(chapterIndex: Int, text: String, whenEnabledOnly: Bool = true) -> AIDialogueCastService.Request? {
        let settings = GlobalSettings.shared
        guard !whenEnabledOnly || (settings.ttsMultiRoleEnabled && settings.ttsAIDialogueEnabled),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let family = TTSVoiceFamily.active()
        guard !whenEnabledOnly || family.supportsMultiRole() else { return nil }
        // 只有能按文字演出语气的音色才值得让模型多输出一段指令：否则只是拖长每章开头的等待。
        let takesInstructions = family.takesInstructions
            || (family == .bookSource && CustomHTTPProvider.templateTakesDelivery(settings.httpTtsUrlTemplate))
        return AIDialogueCastService.Request(
            bookID: bookId,
            chapterIndex: chapterIndex,
            text: text,
            includeInstruct: takesInstructions && settings.ttsEmotionEnabled
        )
    }

    /// 分析一章。失败不影响收听：服务会记住这次失败，播放时回退到从正文推断说话人。
    func analyzeTTSDialogue(_ request: AIDialogueCastService.Request) async {
        do {
            try await AIDialogueCastService.shared.analyze(request, knownAliases: activeTTSRoleAliases())
        } catch is CancellationError {
            return
        } catch {
            AppLogger.error(
                "[TTS] AI 多角色分析失败，本章改用叙述判断说话人",
                error: error,
                context: ["chapter": request.chapterIndex],
                level: .warning
            )
        }
        syncAIDialogueRoster()
    }

    /// 把 AI 名册里的「别名 → 正名」合并进本地 `AISpeakerRosterStore`。
    ///
    /// 这是桥接的关键一步：本地 `TTSSpeakerAnnotator` 与角色指派页都读这张表，
    /// 所以模型判定出的「若尘 / 尘哥 → 张若尘」会立刻让这些称呼共用同一个音色，
    /// 模型排除掉的「试探」之类误判也不会再从别的入口冒出来。
    @MainActor
    func syncAIDialogueRoster() {
        let roster = AIDialogueCastService.shared.roster(forBook: bookId)
        guard !roster.aliasMap.isEmpty else { return }
        let store = AISpeakerRosterStore.shared
        let boundary = aiBookAdapter().boundary()
        var merged = store.safeRoster(forBook: bookId, boundary: boundary)
        merged.merge(roster.aliasMap) { _, ai in ai }
        store.save(merged, forBook: bookId, boundary: boundary)
    }

    /// 预先分析当前章与后续 `count` 章，边听边备好下一章。
    func preAnalyzeTTSChapters(count: Int) {
        let base = ttsChapterIndex ?? currentChapterIndex
        let upper = min(spineChapters.count, base + count + 1)
        guard upper > base else { return }
        let aliases = activeTTSRoleAliases()
        for index in base..<upper {
            let text = narrationForTTSChapter(index).text
            guard let request = ttsDialogueRequest(chapterIndex: index, text: text) else { continue }
            AIDialogueCastService.shared.prefetch(request, knownAliases: aliases)
        }
    }

    /// 给没有手动指派音色的角色自动配音，再交给朗读协调器。
    func refreshTTSRoleCast(sampleText: String) {
        let settings = GlobalSettings.shared
        if settings.ttsMultiRoleEnabled, settings.ttsAutoCastEnabled {
            let family = TTSVoiceFamily.active()
            if family == .azure { AzureTTSVoiceCatalog.shared.loadIfNeeded() }
            AIDialogueCastService.shared.assignAutoVoices(
                forBook: bookId,
                family: family,
                explicit: TTSRoleVoiceCast.cast(forBook: bookId, in: settings.ttsRoleVoices),
                pool: TTSVoiceCandidates.make(family: family, sampleText: sampleText)
            )
        }
        ttsCoordinator.roleVoices = activeTTSRoleVoices()
        ttsCoordinator.roleAliases = activeTTSRoleAliases()
    }

    /// 角色指派页需要的上下文，章节切换时重算。
    func makeTTSRoleCastContext() -> TTSRoleCastContext {
        let chapterIndex = ttsChapterIndex ?? currentChapterIndex
        let text = spineChapters.indices.contains(chapterIndex) ? narrationForTTSChapter(chapterIndex).text : ""
        return TTSRoleCastContext(
            chapterIndex: chapterIndex,
            request: ttsDialogueRequest(chapterIndex: chapterIndex, text: text, whenEnabledOnly: false),
            heuristicSpeakers: detectedTTSSpeakers(),
            knownAliases: activeTTSRoleAliases()
        )
    }
}

/// 角色指派页从阅读器取用的数据。
struct TTSRoleCastContext: Equatable {
    let chapterIndex: Int
    /// 本章的分析请求；没有正文时为 nil。
    let request: AIDialogueCastService.Request?
    /// 未分析时从正文读出的说话人。
    let heuristicSpeakers: [String]
    let knownAliases: [String: String]

    static let empty = TTSRoleCastContext(chapterIndex: 0, request: nil, heuristicSpeakers: [], knownAliases: [:])
}
