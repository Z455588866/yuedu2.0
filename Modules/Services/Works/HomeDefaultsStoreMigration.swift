import Foundation

/// The 2026-11-14 defaults, the home after Apple Books' store, for a saved 预设 (maintainer,
/// 2026-11-14, by option: 「没改过的才换」; `Technotes/AppleBooksHomeLayouts-2026-10-25.md` §10).
/// New installs and 预设配置 have them from `HomePageDefaults`; this gives them to a 预设 made
/// before, whole: the new page adds sections, takes some out and reorders the rest, so it cannot
/// be laid over a home the reader arranged.
///
/// A saved 预设 holds no mark of whether the reader changed it, so it is recognised by what it
/// holds: its sections, in order, are exactly those `previousDefaults` makes for some mode,
/// region and reading languages — the defaults from 2026-10-25 to 2026-11-14, which
/// `HomeDefaultsRhythmMigration` has already brought an older untouched 预设 to — each drawn as
/// they drew it, shown, with no title, subtitle or parameters of the reader's. Any other 预设 is
/// the reader's own and stays as it is: one with a section added, removed, moved, hidden,
/// renamed or drawn another way.
///
/// `HomePageStore` runs it once, on 预设 only: the reader's own 首页配置, those made from 预设配置
/// included, are theirs. When 分组书架 and 类型清单 join the defaults, a 预设 still as this page
/// will need a migration of its own.
enum HomeDefaultsStoreMigration {
    /// Whether `sections` are the defaults of 2026-10-25 to 2026-11-14, untouched.
    static func recognises(_ sections: [HomeSection]) -> Bool {
        HomeDefaultsRhythmMigration.contexts.contains { context in
            let previous = previousDefaults(for: context)
            return previous.count == sections.count && zip(previous, sections).allSatisfy(isAsMade)
        }
    }

    /// As the defaults made it. By the layout it is drawn in, not the value stored: the band,
    /// the home's 顶部轮播图 until 2026-11-12, is drawn as 大型封面书架, and a reader who picked
    /// that again left the section looking as it did.
    private static func isAsMade(_ made: HomeSection, _ saved: HomeSection) -> Bool {
        saved.binding == made.binding && saved.layout.style == made.layout.style && saved.isEnabled
            && saved.title.isEmpty && saved.subtitle.isEmpty && saved.parameters.isEmpty
    }

    /// `HomePageDefaults.page` from 2026-10-25 to 2026-11-14, frozen so it still recognises those
    /// homes now that the defaults have changed: 继续阅读 and 系列下一本, each language's lists a
    /// section of its own (`HomePageDefaults.officialModuleLists`, the first with covers on the
    /// band), 古腾堡热门 ranked, 精选书单 as 分类卡片, and 最新 last, or third where 来源配置 come
    /// first. `HomeDefaultsRhythmMigration` reads the layouts it gives from here too.
    static func previousDefaults(for context: HomePageDefaults.Context, makeID: () -> UUID = UUID.init) -> [HomeSection] {
        let continueReading = HomeSection(id: makeID(), layout: .compactReadingCard, binding: .continueReading)
        let nextInSeries = HomeSection(id: makeID(), layout: .row, binding: .nextInSeries)
        let latest = HomeSection(id: makeID(), layout: .row, binding: .latest)
        let popular = context.publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .rankedRow, binding: .gutenbergShelf(id: "popular"))]
            : []
        let featured = context.publicLibrariesAvailable
            ? [HomeSection(id: makeID(), layout: .categoryCards, binding: .gutenbergLists)]
            : []
        let modules = HomePageDefaults.officialModuleLists(languages: context.languages,
                                                           publicLibrariesAvailable: context.publicLibrariesAvailable)
            .map { HomeSection(id: makeID(), layout: $0.layout, binding: $0.binding) }
        switch context.mode {
        case .bookSources:
            return [continueReading, nextInSeries, latest] + modules + popular + featured
        case .publicLibraries:
            return [continueReading, nextInSeries] + modules + popular + featured + [latest]
        }
    }
}
