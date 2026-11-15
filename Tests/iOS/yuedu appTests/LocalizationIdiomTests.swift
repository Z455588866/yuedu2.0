import Foundation
import Testing
@testable import yuedu_app

/// The idiomatic localization review (2026-10-12, `docs/localization/glossary.md`): each
/// language reads like its Apple apps, counts agree in English, and no language says 书源.
struct LocalizationIdiomTests {
    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private func text(_ key: String, _ language: String) throws -> String {
        NSLocalizedString(key, bundle: try bundle(language), comment: "")
    }

    @Test func detailActionsReadLikeAppleBooks() throws {
        #expect(try text("开始阅读", "en") == "Read")
        #expect(try text("加入书架", "en") == "Add to Library")
        #expect(try text("加入书架", "ja") == "本棚に追加")
        #expect(try text("加入书架", "ko") == "서재에 추가")
    }

    /// Simplified Chinese is not a character conversion of Taiwan wording.
    @Test func simplifiedChineseUsesMainlandWording() throws {
        #expect(try text("设定", "zh-Hans") == "设置")
        #expect(try text("汇入", "zh-Hans") == "导入")
    }

    @Test func traditionalChineseUsesTaiwanWording() throws {
        #expect(try text("搜索", "zh-Hant") == "搜寻")
        #expect(try text("默认", "zh-Hant") == "预设")
    }

    /// The reader's cover opens a menu (Emby's in-player ⋯), one of whose items is 作品详情;
    /// VoiceOver must not hear both as the same name.
    @Test func readerBookMenuIsNotTheDetailPage() throws {
        for language in ["zh-Hant", "zh-Hans", "en", "ja", "ko"] {
            #expect(try text("书本选单", language) != text("作品详情", language), "\(language)")
        }
        #expect(try text("书本选单", "en") == "Book Menu")
    }

    /// The plural rule is the formatting locale's: the app formats in its own language, and the
    /// test host runs in zh-Hant, whose only category is "other" — so the test names English.
    @Test func englishCountsAgree() throws {
        let english = Locale(identifier: "en")
        let format = try text("%d 章", "en")
        #expect(String(format: format, locale: english, 1) == "1 chapter")
        #expect(String(format: format, locale: english, 3) == "3 chapters")
        let mixed = try text("%1$@ · %2$d 个来源配置", "en")
        #expect(String(format: mixed, locale: english, "Gutenberg", 1) == "Gutenberg · 1 source")
        #expect(String(format: mixed, locale: english, "Gutenberg", 2) == "Gutenberg · 2 sources")
    }

    /// One Chinese word, two meanings (关闭 a sheet / a setting that is 关闭): the second meaning
    /// has its own key, 「情境：原字」, so English, Japanese and Korean can say each. Traditional
    /// Chinese reads the same either way.
    @Test func splitKeysSayTheOtherMeaning() throws {
        let splits: [(base: String, split: String, english: String)] = [
            ("关闭", "状态：关闭", "Off"),
            ("开启", "动作：开启", "Open"),
            ("新增", "动作：新增", "Add"),
            ("启用", "动作：启用", "Enable"),
            ("隐藏", "动作：隐藏", "Hide"),
            ("显示", "状态：显示", "Shown"),
            ("复制", "动作：建立副本", "Duplicate"),
            ("继续", "播放：继续", "Resume"),
            ("重新整理", "网页：重新整理", "Reload"),
            ("重新验证", "会员：重新验证", "Verify Again"),
            ("编辑规则", "提示：编辑规则", "Edits the rule."),
            ("作品详情", "提示：作品详情", "Opens Book Details."),
            // 设定's groups: 阅读 alone is the app's name, 一般 is "Regular" and 资源 "Assets".
            ("一般", "设定分组：一般", "General"),
            ("资源", "设定分组：资源", "Resources"),
            ("阅读", "设定分组：阅读", "Reading"),
            // 类型清单's section: 类型 alone is "Type".
            ("类型", "栏目：类型", "Genres"),
        ]
        for pair in splits {
            #expect(try text(pair.split, "en") == pair.english, "\(pair.split)")
            #expect(try text(pair.split, "en") != text(pair.base, "en"), "\(pair.split)")
            #expect(try text(pair.split, "zh-Hant") == text(pair.base, "zh-Hant"), "\(pair.split)")
        }
        #expect(try text("简介：更多", "ja") == "続きを読む")
        #expect(try text("值：是", "ja") == "あり")
        #expect(try text("值：否", "ko") == "없음")
        #expect(String(format: try text("章节 %d", "en"), 3) == "Chapter 3")
        #expect(try text("标题：章节", "en") == "Chapter")
    }

    /// A count and its unit were glued from fragments (`"\(n) \(localized("分钟"))"`), so English
    /// said "1 min" beside "3 books" and could never agree in number; each is one format now.
    @Test func countsAreWholeSentences() throws {
        let english = Locale(identifier: "en")
        func en(_ key: String, _ args: CVarArg...) throws -> String {
            String(format: try text(key, "en"), locale: english, arguments: args)
        }
        #expect(try en("%d 分钟", 1) == "1 minute")
        #expect(try en("%d 分钟", 30) == "30 minutes")
        #expect(try en("已选取 %d 个书签", 1) == "1 Bookmark Selected")
        #expect(try en("已选取 %d 个重点", 2) == "2 Highlights Selected")
        #expect(try en("「%1$@」%2$d 本", "Dune", 1) == "“Dune”: 1 book")
        #expect(try en("抓取 %d 字", 2) == "Fetched 2 characters")
        #expect(try en("%@ 解除连结", "Google") == "Unlink Google")
        #expect(try text("，", "en") == ", ")
        #expect(try text("%d 段落", "ja") == "%d段落", "the overlay's segment count had no key in any table")
        #expect(try text("全选(%1$d/%2$d)", "zh-Hant") == "全选(%1$d/%2$d)")
    }

    /// 「来源配置」 stands in for 书源 on purpose: no language may say it.
    @Test func noLanguageSaysBookSource() throws {
        for language in ["zh-Hant", "zh-Hans", "en", "ja", "ko"] {
            let url = try #require(try bundle(language).url(forResource: "Localizable", withExtension: "strings"))
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            let offending = table.values.filter { $0.range(of: "书源|书源|Book Source|ブックソース|책 소스", options: [.regularExpression, .caseInsensitive]) != nil }
            #expect(offending.isEmpty, "\(language): \(offending.prefix(3))")
        }
    }
}
