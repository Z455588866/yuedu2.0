import Foundation
import Testing
@testable import yuedu_app

/// 「调试」复制到剪贴板的内容：整场日志的纯文本，能直接交给别人——或者交给 AI。
struct BookSourceDebugLogTextTests {
    private let longSummary = String(repeating: "很长的摘要，画面上只显示两行。", count: 40)
    private let longDetail = (1...200).map { "<p>第 \($0) 段正文</p>" }.joined(separator: "\n")

    @Test func oneEntryCarriesItsWholeSummaryAndDetail() {
        let entry = DebugLogEntry(level: .success, step: "正文", summary: longSummary, detail: longDetail)

        let text = entry.plainText

        #expect(text.contains("正文"))
        #expect(text.contains(longSummary))
        #expect(text.contains(longDetail))
    }

    @Test func anEntryWithoutDetailEndsAtItsSummary() {
        let entry = DebugLogEntry(level: .info, step: "请求", summary: "GET https://example.com/1.html")

        #expect(entry.plainText.hasSuffix("GET https://example.com/1.html"))
    }

    @Test func theLevelIsWrittenInWords() {
        // 列表里等级是颜色加一个图标，粘到别处就什么都看不出来。
        let entry = DebugLogEntry(level: .error, step: "正文", summary: "规则没有取到内容")

        #expect(entry.plainText.contains("[error]"))
    }

    @Test func theWholeLogKeepsItsOrder() throws {
        let entries = [
            DebugLogEntry(level: .info, step: "请求", summary: "第一笔"),
            DebugLogEntry(level: .pipeline, step: "规则", summary: "第二笔", detail: "div#content@html"),
            DebugLogEntry(level: .warning, step: "净化", summary: "第三笔"),
            DebugLogEntry(level: .success, step: "正文", summary: "第四笔", detail: longDetail),
        ]

        let text = DebugLogEntry.plainText(of: entries)

        let positions = try ["第一笔", "第二笔", "第三笔", "第四笔"].map { marker in
            try #require(text.range(of: marker)).lowerBound
        }
        #expect(positions == positions.sorted())
        #expect(text.contains("div#content@html"))
        #expect(text.contains(longDetail))
        // 条目之间用一个空行分开。
        #expect(text.components(separatedBy: "\n\n").count == entries.count)
    }

    @Test func anEmptyLogIsEmptyText() {
        #expect(DebugLogEntry.plainText(of: []).isEmpty)
    }
}
